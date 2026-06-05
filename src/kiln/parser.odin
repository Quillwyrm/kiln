package kiln

import "core:fmt"
import "core:os"
import filepath "core:path/filepath"

// Parser state ===================================================================================
// Token cursor and error latch for one compile operation.

Parser := struct {
    current_token: Token,
    failed:        bool, // mutating parser operations set this, callers check and return immediately
}{}


// ExprDesc types ==================================================================================
// Expression descriptors decouple parsing from slot emission.
// parse_expr returns an ExprDesc; surrounding context emits or adjusts it.
// Binding variants carry binding indexes. ExprSlot is already materialized.
// ExprCall references emitted CALL bytecode whose result count remains adjustable.
// ExprIndex carries evaluated container and key slots.

// ExprInvalid only unwinds after Parser.failed already holds the real error.
ExprInvalid :: struct {}
ExprNil     :: struct {}

ExprUnresolvedBinding :: distinct Token
ExprLocalBinding      :: distinct int
ExprMainBinding       :: distinct int
ExprGlobalBinding     :: distinct int
ExprSlot              :: distinct int

// Main/module bindings are bare current-file top-level bindings.
// Imported bindings are exported bindings accessed through a namespace.
ExprModuleBinding :: struct {
    module_index:  int,
    binding_index: int,
}

ExprImportedBinding :: struct {
    module_index:  int,
    binding_index: int,
}

ExprCall :: struct {
    base_slot:  int,
    call_index: int,
}

ExprIndex :: struct {
    container_slot: int,
    key_slot:       int,
}

ExprDesc :: union {
    ExprInvalid,
    ExprNil,
    bool,
    i64,
    f64,
    string,
    ExprUnresolvedBinding,
    ExprLocalBinding,
    ExprMainBinding,
    ExprGlobalBinding,
    ExprModuleBinding,
    ExprImportedBinding,
    ExprSlot,
    ExprCall,
    ExprIndex,
}

// Token cursor ===================================================================================


advance_token :: proc() -> Token {
    token := Parser.current_token
    Parser.current_token = scan_next_token()

    if Parser.current_token.kind == .ERROR {
        message := Parser.current_token.value.(string)
        set_error(SourceLocation{
            source_name = Scanner.source_name,
            line        = Parser.current_token.line,
            column      = Parser.current_token.column,
        }, message)
        Parser.failed = true
    }

    return token
}


// Parser errors ==================================================================================

error_token_text :: proc(token: Token) -> string {
    if token.kind == .EOF {
        return "end of file"
    }
    return token.source_text
}

parser_error :: proc(proto_state: ^ProtoState, token: Token, message: string) {
    set_error(SourceLocation{
        source_name = proto_state.origin.source_name,
        line        = token.line,
        column      = token.column,
    }, message)
    Parser.failed = true
}

// On mismatch records an error and returns zero token value.
consume_token :: proc(proto_state: ^ProtoState, kind: TokenKind, message: string) -> Token {
    if Parser.current_token.kind == kind {
        return advance_token()
    }

    token := Parser.current_token
    parser_error(proto_state, token, message)
    return Token{}
}


// Slots and locals ===============================================================================

// Temp slots are bounded by MAX_FRAME_SLOTS due to u8 slot encoding.
// next_temp_slot is the allocation cursor. frame_slot_count is the high-water mark
// (max slot touched + 1), maintained by record_slots. These are separate:
// next_temp_slot can be saved/restored to free temps (e.g. condition slots),
// while frame_slot_count only grows.
claim_temp_slot :: proc(proto_state: ^ProtoState) -> int {
    if proto_state.next_temp_slot >= MAX_FRAME_SLOTS {
        parser_error(proto_state, Parser.current_token, "function uses too many values")
        return 0
    }

    slot := proto_state.next_temp_slot
    proto_state.next_temp_slot += 1
    return slot
}

// reserve_slots_until ensures next_temp_slot is past a given slot boundary,
// preventing temp reuse of slots that hold live expression results.
reserve_slots_until :: proc(proto_state: ^ProtoState, slot_after_last: int) {
    if slot_after_last > MAX_FRAME_SLOTS {
        parser_error(proto_state, Parser.current_token, "function uses too many values")
        return
    }

    if proto_state.next_temp_slot < slot_after_last {
        proto_state.next_temp_slot = slot_after_last
    }
}

// Records the local-count mark so end_scope can discard this scope's locals.
begin_scope :: proc(proto_state: ^ProtoState) {
    append(&proto_state.scope_local_marks, proto_state.local_count)
}

// Restores the saved local-count mark, discarding locals declared in this scope.
end_scope :: proc(proto_state: ^ProtoState) {
    proto_state.local_count = pop(&proto_state.scope_local_marks)
    proto_state.next_temp_slot = proto_state.local_count
}

// local_binding_append appends a name to the next local frame slot.
// Caller must have already validated: no duplicate in scope, capacity available.
local_binding_append :: proc(proto_state: ^ProtoState, name: string, is_mutable: bool) -> int {
    slot := proto_state.local_count
    proto_state.local_bindings[slot] = LocalBinding{
        name       = name,
        frame_slot = slot,
        is_mutable = is_mutable,
    }
    proto_state.local_count += 1
    proto_state.next_temp_slot = proto_state.local_count
    return slot
}

// local_binding_find returns the most recently declared matching local index, or -1 if absent.
local_binding_find :: proc(proto_state: ^ProtoState, ident_name: string) -> int {
    for idx := proto_state.local_count - 1; idx >= 0; idx -= 1 {
        if proto_state.local_bindings[idx].name == ident_name {
            return idx
        }
    }
    return -1
}

import_namespace_find :: proc(proto_state: ^ProtoState, name: string) -> int {
    for import_index := 0; import_index < proto_state.import_count; import_index += 1 {
        if proto_state.import_names[import_index] == name {
            return import_index
        }
    }
    return -1
}

module_namespace_from_path :: proc(path: string) -> string {
    start := 0
    for index := 0; index < len(path); index += 1 {
        if path[index] == '/' || path[index] == '\\' {
            start = index + 1
        }
    }

    end := len(path)
    if end - start > 5 && path[end - 5:] == ".kiln" {
        end -= 5
    }

    return path[start:end]
}

module_namespace_is_valid :: proc(name: string) -> bool {
    if name == "" {
        return false
    }

    first := name[0]
    if !is_alpha(first) && first != '_' {
        return false
    }

    for index := 1; index < len(name); index += 1 {
        if !is_ident_char(name[index]) {
            return false
        }
    }

    if ident_token_kind(name) != .IDENT {
        return false
    }

    return true
}

// Source modules resolve relative to the importing file's directory.
// The returned path is absolute and owned by the caller when found is true.
resolve_import_source_path :: proc(proto_state: ^ProtoState, path_token: Token, module_path: string) -> (resolved_path: string, found: bool) {
    source_path := module_path
    if !filepath.is_abs(module_path) && filepath.ext(module_path) == "" {
        source_path = fmt.tprintf("%s.kiln", module_path)
    }

    candidate_path := source_path
    joined_path := ""
    if !filepath.is_abs(source_path) {
        importer_dir := filepath.dir(proto_state.origin.source_name)
        defer delete(importer_dir)

        join_parts := [?]string{importer_dir, source_path}
        path, join_error := filepath.join(join_parts[:], context.allocator)
        if join_error != nil {
            parser_error(proto_state, path_token, fmt.tprintf("failed to resolve module path `%s`", module_path))
            return "", false
        }

        joined_path = path
        candidate_path = joined_path
    }

    absolute_path, abs_error := filepath.abs(candidate_path, context.allocator)
    if joined_path != "" {
        delete(joined_path)
    }

    if abs_error != nil {
        parser_error(proto_state, path_token, fmt.tprintf("failed to resolve module path `%s`", module_path))
        return "", false
    }

    if !os.is_file(absolute_path) {
        delete(absolute_path)
        return "", false
    }

    return absolute_path, true
}


// ExprDesc lowering =======================================================================
// These translate descriptors into concrete bytecode.

// lower_expr_desc lowers an expression descriptor so that the value lands
// in dst_slot at runtime.
lower_expr_desc :: proc(proto_state: ^ProtoState, expr: ExprDesc, dst_slot: int) {
    switch desc in expr {
    case ExprInvalid:
        return

    case ExprNil:
        emit_load_nil(proto_state, dst_slot)

    case bool:
        if desc {
            emit_load_true(proto_state, dst_slot)
        } else {
            emit_load_false(proto_state, dst_slot)
        }

    case i64:
        const_index := const_int(proto_state, desc)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case f64:
        const_index := const_float(proto_state, desc)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case string:
        const_index := const_string(proto_state, desc)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case ExprUnresolvedBinding:
        // Resolve bare identifier reads at the point they become values.
        ident_name := desc.value.(string)
        local_index := local_binding_find(proto_state, ident_name)
        if local_index >= 0 {
            src_slot := proto_state.local_bindings[local_index].frame_slot
            if src_slot != dst_slot {
                emit_move(proto_state, dst_slot, src_slot)
            }
            return
        }

        if proto_state.is_module {
            module_index := proto_state.module_index
            binding_index := binding_table_find(&Active_State.module_envs[module_index], ident_name)
            if binding_index >= 0 {
                emit_get_module_bind(proto_state, dst_slot, module_index, binding_index)
                return
            }
        } else {
            main_index := binding_table_find(&Active_State.main_env, ident_name)
            if main_index >= 0 {
                emit_get_main_bind(proto_state, dst_slot, main_index)
                return
            }
        }

        import_index := import_namespace_find(proto_state, ident_name)
        if import_index >= 0 {
            parser_error(proto_state, Token(desc), fmt.tprintf("namespace `%s` cannot be used as a value; access an exported binding with '.'", ident_name))
            return
        }

        global_index := binding_table_find(&Active_State.global_env, ident_name)
        if global_index < 0 {
            if proto_state.function_depth > 0 {
                parser_error(proto_state, Token(desc), fmt.tprintf("binding `%s` is not declared in this function; Kiln does not support closures or upvalues", ident_name))
            } else {
                parser_error(proto_state, Token(desc), fmt.tprintf("binding `%s` is not declared", ident_name))
            }
            return
        }

        emit_get_global_bind(proto_state, dst_slot, global_index)

    case ExprLocalBinding:
        src_slot := proto_state.local_bindings[int(desc)].frame_slot
        if src_slot != dst_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprMainBinding:
        emit_get_main_bind(proto_state, dst_slot, int(desc))

    case ExprGlobalBinding:
        emit_get_global_bind(proto_state, dst_slot, int(desc))

    case ExprModuleBinding:
        emit_get_module_bind(proto_state, dst_slot, desc.module_index, desc.binding_index)

    case ExprImportedBinding:
        emit_get_module_bind(proto_state, dst_slot, desc.module_index, desc.binding_index)

    case ExprSlot:
        if int(desc) != dst_slot {
            emit_move(proto_state, dst_slot, int(desc))
        }

    case ExprCall:
        set_call_requested_results(proto_state, desc.call_index, 1)
        if desc.base_slot != dst_slot {
            emit_move(proto_state, dst_slot, desc.base_slot)
        }

    case ExprIndex:
        emit_index_get(proto_state, dst_slot, desc.container_slot, desc.key_slot)

    }
}


// Expression roots and chains =====================================================================

// arrayLiteral = "[" [exprList [","]] "]".
parse_array_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .LEFT_BRACKET, "expected '[' to start array literal")
    if Parser.failed { return ExprInvalid{} }

    array_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    emit_new_array(proto_state, array_slot)

    if Parser.current_token.kind != .RIGHT_BRACKET {
        for {
            value_slot := claim_temp_slot(proto_state)
            if Parser.failed { return ExprInvalid{} }

            value_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            lower_expr_desc(proto_state, value_expr, value_slot)
            if Parser.failed { return ExprInvalid{} }

            emit_array_push(proto_state, array_slot, value_slot)
            proto_state.next_temp_slot = array_slot + 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.current_token.kind == .RIGHT_BRACKET {
                break
            }
        }
    }

    consume_token(proto_state, .RIGHT_BRACKET, "expected ']' after array literal")
    if Parser.failed { return ExprInvalid{} }

    return ExprSlot(array_slot)
}

// mapLiteral = "map" "{" [mapEntryList [","]] "}".
parse_map_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .MAP, "expected 'map' to start map literal")
    if Parser.failed { return ExprInvalid{} }

    consume_token(proto_state, .LEFT_BRACE, "expected '{' after map")
    if Parser.failed { return ExprInvalid{} }

    map_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    emit_new_map(proto_state, map_slot)

    key_texts := make([dynamic]string)
    defer delete(key_texts)

    if Parser.current_token.kind != .RIGHT_BRACE {
        for {
            key_token := Parser.current_token
            key_text: string

            #partial switch key_token.kind {
            case .IDENT:
                key_text = key_token.value.(string)
                advance_token()

                if Parser.current_token.kind == .LEFT_PAREN {
                    parser_error(proto_state, Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got call expression")
                    return ExprInvalid{}
                }

                if Parser.current_token.kind == .LEFT_BRACKET {
                    parser_error(proto_state, Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got indexed expression")
                    return ExprInvalid{}
                }

                if Parser.current_token.kind == .DOT {
                    parser_error(proto_state, Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got field or namespace expression")
                    return ExprInvalid{}
                }

            case .STRING:
                key_text = key_token.value.(string)
                advance_token()

            case:
                parser_error(proto_state, key_token, "map key invalid; expected identifier shorthand or string literal")
                return ExprInvalid{}
            }

            for existing_key in key_texts {
                if existing_key == key_text {
                    parser_error(proto_state, key_token, fmt.tprintf("duplicate map key `%s`", key_text))
                    return ExprInvalid{}
                }
            }
            append(&key_texts, key_text)

            consume_token(proto_state, .COLON, "map entry invalid; expected ':' after map key")
            if Parser.failed { return ExprInvalid{} }

            key_slot := claim_temp_slot(proto_state)
            if Parser.failed { return ExprInvalid{} }

            key_const := const_string(proto_state, key_text)
            if Parser.failed { return ExprInvalid{} }

            emit_load_const(proto_state, key_slot, key_const)

            value_slot := claim_temp_slot(proto_state)
            if Parser.failed { return ExprInvalid{} }

            value_token := Parser.current_token
            if value_token.kind == .NIL {
                parser_error(proto_state, value_token, fmt.tprintf("invalid value for key `%s` in map literal; nil literals are not valid in map literals", key_text))
                return ExprInvalid{}
            }

            value_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            lower_expr_desc(proto_state, value_expr, value_slot)
            if Parser.failed { return ExprInvalid{} }

            emit_index_set(proto_state, map_slot, key_slot, value_slot)
            proto_state.next_temp_slot = map_slot + 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.current_token.kind == .RIGHT_BRACE {
                break
            }
        }
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        parser_error(proto_state, Parser.current_token, "map entry invalid; expected ',' or '}' after map value")
        return ExprInvalid{}
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' after map literal")
    if Parser.failed { return ExprInvalid{} }

    return ExprSlot(map_slot)
}

// groupedExpr = "(" expr ")".
parse_grouped_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .LEFT_PAREN, "expected '(' to start grouped expression")
    if Parser.failed { return ExprInvalid{} }

    expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    consume_token(proto_state, .RIGHT_PAREN, "expected ')' after grouped expression")
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind == .LEFT_PAREN || Parser.current_token.kind == .LEFT_BRACKET || Parser.current_token.kind == .DOT {
        parser_error(proto_state, Parser.current_token, "grouped expression cannot be used as a chain root")
        return ExprInvalid{}
    }

    return expr
}

// rootExpr = ident | functionLiteral | arrayLiteral | mapLiteral.
parse_root_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind == .IDENT {
        return ExprUnresolvedBinding(advance_token())
    }

    if Parser.current_token.kind == .FUNCTION {
        slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        parse_function_literal(proto_state, slot, "<function>", Parser.current_token)
        if Parser.failed { return ExprInvalid{} }
        return ExprSlot(slot)
    }

    if Parser.current_token.kind == .LEFT_BRACKET {
        return parse_array_literal(proto_state)
    }

    if Parser.current_token.kind == .MAP {
        return parse_map_literal(proto_state)
    }

    token := Parser.current_token
    parser_error(proto_state, token, fmt.tprintf("expected chain expression, got `%s`", error_token_text(token)))
    return ExprInvalid{}
}

// callPostfix = "(" [exprList [","]] ")".
// Layout: callee_slot, arg0, arg1, ...
// Arguments are single-valued; call expansion only happens in return/assignment lists.
parse_call_postfix :: proc(proto_state: ^ProtoState, callee: ExprDesc) -> ExprDesc {
    consume_token(proto_state, .LEFT_PAREN, "expected '(' to start call arguments")
    if Parser.failed { return ExprInvalid{} }

    base_slot: int
    slot_expr, callee_is_slot := callee.(ExprSlot)
    if callee_is_slot {
        base_slot = int(slot_expr)
        reserve_slots_until(proto_state, base_slot + 1)
        if Parser.failed { return ExprInvalid{} }
    } else {
        base_slot = claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, callee, base_slot)
        if Parser.failed { return ExprInvalid{} }
    }

    arg_count := 0
    if Parser.current_token.kind != .RIGHT_PAREN {
        for {
            arg_slot := base_slot + 1 + arg_count
            if arg_slot >= MAX_FRAME_SLOTS {
                parser_error(proto_state, Parser.current_token, "call uses too many values")
                return ExprInvalid{}
            }

            arg_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            lower_expr_desc(proto_state, arg_expr, arg_slot)
            if Parser.failed { return ExprInvalid{} }

            reserve_slots_until(proto_state, arg_slot + 1)
            if Parser.failed { return ExprInvalid{} }

            arg_count += 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.current_token.kind == .RIGHT_PAREN {
                break
            }
        }
    }

    consume_token(proto_state, .RIGHT_PAREN, "expected ')' after call arguments")
    if Parser.failed { return ExprInvalid{} }

    call_index := emit_call(proto_state, base_slot, arg_count, 1)
    return ExprCall{base_slot, call_index}
}

// indexPostfix = "[" expr "]".
parse_index_postfix :: proc(proto_state: ^ProtoState, container: ExprDesc) -> ExprDesc {
    consume_token(proto_state, .LEFT_BRACKET, "expected '[' to start index expression")
    if Parser.failed { return ExprInvalid{} }

    container_slot: int
    slot_expr, container_is_slot := container.(ExprSlot)
    if container_is_slot {
        container_slot = int(slot_expr)
        reserve_slots_until(proto_state, container_slot + 1)
        if Parser.failed { return ExprInvalid{} }
    } else {
        container_slot = claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, container, container_slot)
        if Parser.failed { return ExprInvalid{} }
    }

    key_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    key_expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    lower_expr_desc(proto_state, key_expr, key_slot)
    if Parser.failed { return ExprInvalid{} }

    consume_token(proto_state, .RIGHT_BRACKET, "expected ']' after index expression")
    if Parser.failed { return ExprInvalid{} }

    return ExprIndex{container_slot, key_slot}
}

// fieldPostfix = "." ident.
// Current implementation supports imported module namespace access only.
parse_field_postfix :: proc(proto_state: ^ProtoState, left: ExprDesc) -> ExprDesc {
    dot_token := consume_token(proto_state, .DOT, "expected '.' to start access expression")
    if Parser.failed { return ExprInvalid{} }

    member_token := consume_token(proto_state, .IDENT, "expected identifier after '.'")
    if Parser.failed { return ExprInvalid{} }

    namespace_token, is_namespace_candidate := left.(ExprUnresolvedBinding)
    if !is_namespace_candidate {
        parser_error(proto_state, dot_token, "invalid access expression; expected imported namespace before '.'")
        return ExprInvalid{}
    }

    namespace_name := namespace_token.value.(string)
    import_index := import_namespace_find(proto_state, namespace_name)
    local_index := local_binding_find(proto_state, namespace_name)
    if local_index >= 0 {
        if import_index >= 0 {
            parser_error(proto_state, Token(namespace_token), fmt.tprintf("invalid access expression; local binding `%s` shadows imported namespace", namespace_name))
        } else {
            parser_error(proto_state, Token(namespace_token), fmt.tprintf("invalid access expression; local binding `%s` is not an imported namespace", namespace_name))
        }
        return ExprInvalid{}
    }

    if import_index < 0 {
        parser_error(proto_state, Token(namespace_token), fmt.tprintf("invalid access expression; namespace `%s` not found", namespace_name))
        return ExprInvalid{}
    }

    module_index := proto_state.import_module_indexes[import_index]
    member_name := member_token.value.(string)
    binding_index := binding_table_find(&Active_State.module_envs[module_index], member_name)
    if binding_index < 0 {
        parser_error(proto_state, member_token, fmt.tprintf("invalid access expression; module `%s` has no binding `%s`", namespace_name, member_name))
        return ExprInvalid{}
    }

    if !Active_State.module_exports[module_index][binding_index] {
        parser_error(proto_state, member_token, fmt.tprintf("module `%s` does not export binding `%s`", namespace_name, member_name))
        return ExprInvalid{}
    }

    return ExprImportedBinding{module_index, binding_index}
}

// chainExpr = rootExpr {postfix}.
parse_chain_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    expr := parse_root_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    for {
        if Parser.current_token.kind == .LEFT_PAREN {
            expr = parse_call_postfix(proto_state, expr)
            if Parser.failed { return ExprInvalid{} }
            continue
        }

        if Parser.current_token.kind == .LEFT_BRACKET {
            expr = parse_index_postfix(proto_state, expr)
            if Parser.failed { return ExprInvalid{} }
            continue
        }

        if Parser.current_token.kind == .DOT {
            expr = parse_field_postfix(proto_state, expr)
            if Parser.failed { return ExprInvalid{} }
            continue
        }

        break
    }

    return expr
}

// Expression parsers ==============================================================================
// Each returns an ExprDesc. No slot destination is passed in.

// primaryExpr = chainExpr | basicLiteral | groupedExpr.
parse_primary_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    #partial switch Parser.current_token.kind {
    case .INT:
        token := advance_token()
        return token.value.(i64)
    case .FLOAT:
        token := advance_token()
        return token.value.(f64)
    case .STRING:
        token := advance_token()
        return token.value.(string)
    case .TRUE:
        advance_token()
        return true
    case .FALSE:
        advance_token()
        return false
    case .NIL:
        advance_token()
        return ExprNil{}
    case .LEFT_PAREN:
        return parse_grouped_expr(proto_state)
    case .IDENT, .FUNCTION, .LEFT_BRACKET, .MAP:
        return parse_chain_expr(proto_state)
    case:
        token := Parser.current_token
        parser_error(proto_state, token, fmt.tprintf("expected expression, got `%s`", error_token_text(token)))
        return ExprInvalid{}
    }
}

// unaryExpr = unaryOp unaryExpr | primaryExpr.
parse_unary_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind == .NOT {
        advance_token()

        operand := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        operand_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, operand, operand_slot)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        emit_not(proto_state, result_slot, operand_slot)
        return ExprSlot(result_slot)
    }

    if Parser.current_token.kind == .MINUS {
        advance_token()

        operand := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        operand_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, operand, operand_slot)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        emit_neg(proto_state, result_slot, operand_slot)
        return ExprSlot(result_slot)
    }

    return parse_primary_expr(proto_state)
}

// mulExpr = unaryExpr {mulOp unaryExpr}.
parse_mul_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_unary_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    // mulOp = "*" | "/" | "%".
    for Parser.current_token.kind == .STAR || Parser.current_token.kind == .SLASH || Parser.current_token.kind == .MOD {
        op_token := advance_token()

        right := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, lhs_slot)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        if op_token.kind == .STAR {
            emit_mul(proto_state, lhs_slot, lhs_slot, rhs_slot)
        } else if op_token.kind == .SLASH {
            emit_div(proto_state, lhs_slot, lhs_slot, rhs_slot)
        } else {
            emit_mod(proto_state, lhs_slot, lhs_slot, rhs_slot)
        }

        // Only the accumulated left result remains live after the binary op.
        proto_state.next_temp_slot = lhs_slot + 1
        left = ExprSlot(lhs_slot)
    }

    return left
}

// addExpr = mulExpr {addOp mulExpr}.
parse_add_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_mul_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    // addOp = "+" | "-" | "..".
    for Parser.current_token.kind == .PLUS ||
        Parser.current_token.kind == .MINUS ||
        Parser.current_token.kind == .CONCAT {
        op_token := advance_token()

        right := parse_mul_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, lhs_slot)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        if op_token.kind == .PLUS {
            emit_add(proto_state, lhs_slot, lhs_slot, rhs_slot)
        } else if op_token.kind == .MINUS {
            emit_sub(proto_state, lhs_slot, lhs_slot, rhs_slot)
        } else {
            emit_concat(proto_state, lhs_slot, lhs_slot, rhs_slot)
        }

        // Only the accumulated left result remains live after the binary op.
        proto_state.next_temp_slot = lhs_slot + 1
        left = ExprSlot(lhs_slot)
    }

    return left
}

// compareExpr = addExpr [compareOp addExpr].
parse_compare_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_add_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    // compareOp = "==" | "!=" | "<" | "<=" | ">" | ">=".
    #partial switch Parser.current_token.kind {
    case .EQUAL, .NOT_EQUAL, .LESS, .LESS_OR_EQUAL, .GREATER, .GREATER_OR_EQUAL:
        op_token := advance_token()

        right := parse_add_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, lhs_slot)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        #partial switch op_token.kind {
        case .EQUAL:
            emit_equal(proto_state, lhs_slot, lhs_slot, rhs_slot)

        case .NOT_EQUAL:
            emit_equal(proto_state, lhs_slot, lhs_slot, rhs_slot)
            emit_not(proto_state, lhs_slot, lhs_slot)

        case .LESS:
            emit_less(proto_state, lhs_slot, lhs_slot, rhs_slot)

        case .LESS_OR_EQUAL:
            emit_less_or_equal(proto_state, lhs_slot, lhs_slot, rhs_slot)

        case .GREATER:
            // a > b is emitted as b < a because the VM has LESS, not GREATER.
            emit_less(proto_state, lhs_slot, rhs_slot, lhs_slot)

        case .GREATER_OR_EQUAL:
            emit_less_or_equal(proto_state, lhs_slot, rhs_slot, lhs_slot)
        }

        // Only the accumulated left result remains live after the binary op.
        proto_state.next_temp_slot = lhs_slot + 1
        left = ExprSlot(lhs_slot)

        // compareExpr allows one compareOp, not a chain.
        #partial switch Parser.current_token.kind {
        case .EQUAL, .NOT_EQUAL, .LESS, .LESS_OR_EQUAL, .GREATER, .GREATER_OR_EQUAL:
            parser_error(proto_state, Parser.current_token, "comparison chaining is not valid; use parentheses or split the expression")
            return ExprInvalid{}
        }
    }

    return left
}

// andExpr = compareExpr {"and" compareExpr}.
parse_and_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_compare_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    for Parser.current_token.kind == .AND {
        advance_token()

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, result_slot)
        if Parser.failed { return ExprInvalid{} }

        left_false_jump := emit_jump_false(proto_state, result_slot)

        right := parse_compare_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        right_false_jump := emit_jump_false(proto_state, rhs_slot)

        emit_load_true(proto_state, result_slot)
        end_jump := emit_jump(proto_state)

        patch_jump(proto_state, left_false_jump)
        if Parser.failed { return ExprInvalid{} }
        patch_jump(proto_state, right_false_jump)
        if Parser.failed { return ExprInvalid{} }
        emit_load_false(proto_state, result_slot)

        patch_jump(proto_state, end_jump)
        if Parser.failed { return ExprInvalid{} }

        // Only the accumulated bool result remains live after the logical op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot(result_slot)
    }

    return left
}

// orExpr = andExpr {"or" andExpr}.
parse_or_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_and_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    for Parser.current_token.kind == .OR {
        advance_token()

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, result_slot)
        if Parser.failed { return ExprInvalid{} }

        left_false_jump := emit_jump_false(proto_state, result_slot)

        emit_load_true(proto_state, result_slot)
        end_jump := emit_jump(proto_state)

        patch_jump(proto_state, left_false_jump)
        if Parser.failed { return ExprInvalid{} }

        right := parse_and_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        right_false_jump := emit_jump_false(proto_state, rhs_slot)

        emit_load_true(proto_state, result_slot)
        end_jump_from_right := emit_jump(proto_state)

        patch_jump(proto_state, right_false_jump)
        if Parser.failed { return ExprInvalid{} }
        emit_load_false(proto_state, result_slot)

        patch_jump(proto_state, end_jump)
        if Parser.failed { return ExprInvalid{} }
        patch_jump(proto_state, end_jump_from_right)
        if Parser.failed { return ExprInvalid{} }

        // Only the accumulated bool result remains live after the logical op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot(result_slot)
    }

    return left
}

// fallbackExpr = orExpr ["else" fallbackExpr].
parse_fallback_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_or_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind == .ELSE {
        advance_token()

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, left, result_slot)
        if Parser.failed { return ExprInvalid{} }

        end_jump := emit_jump_not_nil(proto_state, result_slot)

        right := parse_fallback_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, result_slot)
        if Parser.failed { return ExprInvalid{} }

        patch_jump(proto_state, end_jump)
        if Parser.failed { return ExprInvalid{} }

        // Only the fallback result remains live after the nil test.
        proto_state.next_temp_slot = result_slot + 1
        return ExprSlot(result_slot)
    }

    return left
}

// expr = fallbackExpr.
parse_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    return parse_fallback_expr(proto_state)
}


// Expression lists ================================================================================

// exprList = expr {"," expr}.
// Every expression before the final one is emitted as one value,
// starting at base_slot. The final expression stays as ExprDesc so
// callers can choose fixed results or final-call expansion.
// Invariant: base_slot must equal proto_state.next_temp_slot at entry.
parse_expr_list :: proc(proto_state: ^ProtoState, base_slot: int) -> (expr_count: int, last_expr: ExprDesc) {
    expr_count = 1
    last_expr = parse_expr(proto_state)
    if Parser.failed { return }

    for Parser.current_token.kind == .COMMA {
        dst_slot := base_slot + expr_count - 1

        reserve_slots_until(proto_state, dst_slot + 1)
        if Parser.failed { return }

        lower_expr_desc(proto_state, last_expr, dst_slot)
        if Parser.failed { return }

        advance_token()

        last_expr = parse_expr(proto_state)
        if Parser.failed { return }

        expr_count += 1
    }

    return
}

// Finishes an expression list so it fills exactly wanted_count result slots.
//
// Expressions before the final one are already emitted at
// base_slot .. base_slot + expr_count - 2.
// The final expression is emitted or expanded to cover
// base_slot .. base_slot + wanted_count - 1.
//
// Caller must validate expr_count <= wanted_count before calling.
finish_expr_list_to_slots :: proc(proto_state: ^ProtoState, base_slot: int, expr_count: int, last_expr: ExprDesc, wanted_count: int) {
    previous_count := expr_count - 1
    last_dst := base_slot + previous_count
    wanted_from_last := wanted_count - previous_count

    if wanted_from_last <= 0 {
        return
    }

    reserve_slots_until(proto_state, base_slot + wanted_count)
    if Parser.failed { return }

    call_expr, final_is_call := last_expr.(ExprCall)
    if final_is_call {
        if call_expr.base_slot != last_dst {
            panic("call result base does not match expression-list destination")
        }

        set_call_requested_results(proto_state, call_expr.call_index, wanted_from_last)
        if Parser.failed { return }

        if wanted_from_last > 1 {
            record_slots(proto_state, last_dst + wanted_from_last - 1)
        }

        return
    }

    lower_expr_desc(proto_state, last_expr, last_dst)
    if Parser.failed { return }

    for fill_index := previous_count + 1; fill_index < wanted_count; fill_index += 1 {
        emit_load_nil(proto_state, base_slot + fill_index)
    }
}


// Function literals ==============================================================================

// functionBody = "{" {stmt} "}".
// Parameters and body-root locals share the function root scope.
// Nested blocks still create scopes through normal statement parsing.
parse_function_body :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start function body")
    if Parser.failed { return }

    for !Parser.failed && Parser.current_token.kind != .RIGHT_BRACE && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if Parser.current_token.kind == .EOF {
        parser_error(proto_state, Parser.current_token, "expected '}' to close function body")
        return
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close function body")
}

// functionLiteral = "function" "(" [paramList [","]] ")" block.
// The compiled child proto is stored on the parent and loaded by LOAD_FUNC at runtime.
parse_function_literal :: proc(parent_proto_state: ^ProtoState, dst: int, function_name: string, origin_token: Token) {
    consume_token(parent_proto_state, .FUNCTION, "expected 'function'")
    if Parser.failed { return }

    consume_token(parent_proto_state, .LEFT_PAREN, "expected '(' after function")
    if Parser.failed { return }

    // Parameters are collected before creating the child proto so its arity is known.
    param_tokens: [MAX_CALL_ARGS]Token
    param_count := 0
    if Parser.current_token.kind != .RIGHT_PAREN {
        for {
            if param_count >= MAX_CALL_ARGS {
                parser_error(parent_proto_state, Parser.current_token, "too many function parameters")
                return
            }

            param_tokens[param_count] = consume_token(parent_proto_state, .IDENT, "expected parameter identifier")
            if Parser.failed {
                return
            }
            param_count += 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.current_token.kind == .RIGHT_PAREN {
                break
            }
        }
    }

    consume_token(parent_proto_state, .RIGHT_PAREN, "expected ')' after function parameters")
    if Parser.failed { return }

    child_origin := SourceLocation{
        source_name = parent_proto_state.origin.source_name,
        line        = origin_token.line,
        column      = origin_token.column,
    }
    child_proto_state := begin_proto(child_origin, function_name, param_count, parent_proto_state.function_depth + 1)
    child_proto_state.is_module = parent_proto_state.is_module
    child_proto_state.module_index = parent_proto_state.module_index

    for import_index := 0; import_index < parent_proto_state.import_count; import_index += 1 {
        child_proto_state.import_names[import_index] = parent_proto_state.import_names[import_index]
        child_proto_state.import_module_indexes[import_index] = parent_proto_state.import_module_indexes[import_index]
    }
    child_proto_state.import_count = parent_proto_state.import_count

    // Parameters are local slots starting at slot 0.
    // The VM call path places arguments directly into those slots.
    for param_index := 0; param_index < param_count; param_index += 1 {
        param_name := param_tokens[param_index].value.(string)

        for prev_index := 0; prev_index < param_index; prev_index += 1 {
            if param_tokens[prev_index].value.(string) == param_name {
                parser_error(&child_proto_state, param_tokens[param_index], fmt.tprintf("parameter binding `%s` is already declared in this function", param_name))
                delete_proto_state(&child_proto_state)
                return
            }
        }

        local_binding_append(&child_proto_state, param_name, true)
    }

    parse_function_body(&child_proto_state)
    if Parser.failed {
        delete_proto_state(&child_proto_state)
        return
    }

    // Function fallthrough is an implicit nil return.
    return_slot := claim_temp_slot(&child_proto_state)
    if Parser.failed {
        delete_proto_state(&child_proto_state)
        return
    }
    emit_load_nil(&child_proto_state, return_slot)
    emit_return(&child_proto_state, return_slot, 1)

    // LOAD_FUNC creates the runtime function object when the parent executes.
    if len(parent_proto_state.child_protos) >= MAX_CHILD_PROTOS {
        delete_proto_state(&child_proto_state)
        parser_error(parent_proto_state, origin_token, "too many functions in function")
        return
    }

    child_proto := end_proto(&child_proto_state)
    child_proto_index := len(parent_proto_state.child_protos)
    append(&parent_proto_state.child_protos, child_proto)
    emit_load_func(parent_proto_state, dst, child_proto_index)
}


// Statements =====================================================================================

// importStmt = "import" [ident] stringLiteral.
parse_import_stmt :: proc(proto_state: ^ProtoState) {
    import_token := consume_token(proto_state, .IMPORT, "expected 'import'")
    if Parser.failed { return }

    alias_token := Token{}
    has_alias := false
    if Parser.current_token.kind == .IDENT {
        alias_token = advance_token()
        has_alias = true
    }

    path_token := consume_token(proto_state, .STRING, "expected module path string after import")
    if Parser.failed { return }

    module_path := path_token.value.(string)
    namespace_name := module_namespace_from_path(module_path)
    namespace_token := path_token
    if has_alias {
        namespace_name = alias_token.value.(string)
        namespace_token = alias_token
    }

    if namespace_name == "" {
        parser_error(proto_state, path_token, "import namespace invalid; expected non-empty module name or explicit alias")
        return
    }

    if !module_namespace_is_valid(namespace_name) {
        parser_error(proto_state, namespace_token, fmt.tprintf("import namespace `%s` invalid; expected identifier", namespace_name))
        return
    }

    if proto_state.import_count >= MAX_MODULES {
        parser_error(proto_state, import_token, "too many imports")
        return
    }

    import_index := import_namespace_find(proto_state, namespace_name)
    if import_index >= 0 {
        parser_error(proto_state, namespace_token, fmt.tprintf("import namespace `%s` is already declared", namespace_name))
        return
    }

    current_top_level_table := &Active_State.main_env
    if proto_state.is_module {
        current_top_level_table = &Active_State.module_envs[proto_state.module_index]
    }

    current_top_level_index := binding_table_find(current_top_level_table, namespace_name)
    if current_top_level_index >= 0 {
        parser_error(proto_state, namespace_token, fmt.tprintf("import namespace `%s` conflicts with top-level binding", namespace_name))
        return
    }

    module_index := -1
    resolved_source_path, source_found := resolve_import_source_path(proto_state, path_token, module_path)
    if Parser.failed { return }

    if source_found {
        module_index = module_find(resolved_source_path)
        if module_index >= 0 {
            if Active_State.module_loading[module_index] {
                delete(resolved_source_path)
                parser_error(proto_state, path_token, fmt.tprintf("cyclic import detected for module `%s`", module_path))
                return
            }
            delete(resolved_source_path)
        } else {
            source_bytes, read_error := os.read_entire_file(resolved_source_path, context.allocator)
            if read_error != nil {
                delete(resolved_source_path)
                parser_error(proto_state, path_token, fmt.tprintf("failed to read module `%s`", module_path))
                return
            }

            if Active_State.module_count >= MAX_MODULES {
                delete(source_bytes)
                delete(resolved_source_path)
                parser_error(proto_state, path_token, "too many modules")
                return
            }

            module_index = bind_module(resolved_source_path)
            Active_State.module_loading[module_index] = true
            defer Active_State.module_loading[module_index] = false

            // Module compilation reuses the package-level scanner/parser.
            // Save the importing cursor so import loading can return to this file.
            outer_parser := Parser
            outer_scanner := Scanner
            module_proto, compile_error := compile_module_source(string(source_bytes), Active_State.module_ids[module_index], module_index)
            Parser = outer_parser
            Scanner = outer_scanner
            delete(source_bytes)
            delete(resolved_source_path)

            if compile_error != nil {
                Parser.failed = true
                return
            }

            // Run the imported module after compilation, before the importer continues.
            module_result, run_error := run_proto(Active_State, module_proto)
            if run_error != nil {
                Parser.failed = true
                return
            }
        }
    } else {
        module_index = module_find(module_path)
        if module_index < 0 {
            parser_error(proto_state, path_token, fmt.tprintf("module `%s` not found", module_path))
            return
        }
    }

    for existing_import := 0; existing_import < proto_state.import_count; existing_import += 1 {
        if proto_state.import_module_indexes[existing_import] == module_index {
            existing_namespace := proto_state.import_names[existing_import]
            parser_error(proto_state, path_token, fmt.tprintf("module `%s` is already imported as `%s`", module_path, existing_namespace))
            return
        }
    }

    proto_state.import_names[proto_state.import_count] = namespace_name
    proto_state.import_module_indexes[proto_state.import_count] = module_index
    proto_state.import_count += 1
}

// exportStmt = "export" | "export" "{" ident {"," ident} [","] "}".
parse_export_stmt :: proc(proto_state: ^ProtoState) {
    export_token := consume_token(proto_state, .EXPORT, "expected 'export'")
    if Parser.failed { return }

    if !proto_state.is_module {
        parser_error(proto_state, export_token, "export is only valid in module files")
        return
    }

    module_index := proto_state.module_index
    module_table := &Active_State.module_envs[module_index]

    if Parser.current_token.kind != .LEFT_BRACE {
        for binding_index := 0; binding_index < module_table.count; binding_index += 1 {
            Active_State.module_exports[module_index][binding_index] = true
        }
        return
    }

    consume_token(proto_state, .LEFT_BRACE, "expected '{' after export")
    if Parser.failed { return }

    if Parser.current_token.kind == .RIGHT_BRACE {
        parser_error(proto_state, Parser.current_token, "export manifest invalid; expected at least one binding name")
        return
    }

    export_tokens: [MAX_BINDINGS]Token
    export_binding_indexes: [MAX_BINDINGS]int
    export_count := 0

    for {
        if export_count >= MAX_BINDINGS {
            parser_error(proto_state, Parser.current_token, "too many bindings in export manifest")
            return
        }

        name_token := consume_token(proto_state, .IDENT, "expected binding name in export manifest")
        if Parser.failed { return }

        name := name_token.value.(string)
        for prev_index := 0; prev_index < export_count; prev_index += 1 {
            if export_tokens[prev_index].value.(string) == name {
                parser_error(proto_state, name_token, fmt.tprintf("duplicate export binding `%s`", name))
                return
            }
        }

        binding_index := binding_table_find(module_table, name)
        if binding_index < 0 {
            parser_error(proto_state, name_token, fmt.tprintf("export binding `%s` is not declared in this module", name))
            return
        }

        export_tokens[export_count] = name_token
        export_binding_indexes[export_count] = binding_index
        export_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
        if Parser.current_token.kind == .RIGHT_BRACE {
            break
        }
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' after export manifest")
    if Parser.failed { return }

    for export_index := 0; export_index < export_count; export_index += 1 {
        binding_index := export_binding_indexes[export_index]
        Active_State.module_exports[module_index][binding_index] = true
    }
}

// block = "{" {stmt} "}".
parse_block_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start block")
    if Parser.failed { return }

    begin_scope(proto_state)
    if Parser.failed { return }

    for !Parser.failed && Parser.current_token.kind != .RIGHT_BRACE && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if Parser.current_token.kind == .EOF {
        parser_error(proto_state, Parser.current_token, "expected '}' to close block")
        return
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close block")
    if Parser.failed { return }

    end_scope(proto_state)
}

// ifStmt = "if" expr block ["else" (ifStmt | block)].
parse_if_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .IF, "expected 'if'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    condition_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    expr := parse_expr(proto_state)
    if Parser.failed { return }

    lower_expr_desc(proto_state, expr, condition_slot)
    if Parser.failed { return }

    false_jump := emit_jump_false(proto_state, condition_slot)
    // Condition is dead after the branch; reclaim its temp slots.
    proto_state.next_temp_slot = temp_save
    parse_block_stmt(proto_state)
    if Parser.failed { return }

    if Parser.current_token.kind == .ELSE {
        advance_token()

        end_jump := emit_jump(proto_state)
        patch_jump(proto_state, false_jump)
        if Parser.failed { return }

        if Parser.current_token.kind == .IF {
            parse_if_stmt(proto_state)
        } else {
            parse_block_stmt(proto_state)
        }
        if Parser.failed { return }

        patch_jump(proto_state, end_jump)
        if Parser.failed { return }
        return
    }

    patch_jump(proto_state, false_jump)
    if Parser.failed { return }
}

// forStmt = "for" expr block | "for" block.
parse_for_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .FOR, "expected 'for'")
    if Parser.failed { return }

    // Break fixups added after this point belong to this loop.
    append(&proto_state.loop_break_fixup_bases, len(proto_state.break_jump_fixups))

    loop_start := next_inst_index(proto_state)
    has_exit_jump := false
    exit_jump := 0

    // `for { ... }` has no condition expression.
    // It loops until `break`, `return`, or runtime termination.
    if Parser.current_token.kind != .LEFT_BRACE {
        temp_save := proto_state.next_temp_slot
        condition_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_desc(proto_state, expr, condition_slot)
        if Parser.failed { return }

        exit_jump = emit_jump_false(proto_state, condition_slot)
        // Condition is dead after the branch; reclaim its temp slots.
        proto_state.next_temp_slot = temp_save
        has_exit_jump = true
    }

    parse_block_stmt(proto_state)
    if Parser.failed { return }

    emit_jump(proto_state, loop_start)
    if Parser.failed { return }

    if has_exit_jump {
        patch_jump(proto_state, exit_jump)
        if Parser.failed { return }
    }

    break_fixup_base := pop(&proto_state.loop_break_fixup_bases)
    // Patch breaks from this loop body only.
    for fixup_index := break_fixup_base; fixup_index < len(proto_state.break_jump_fixups); fixup_index += 1 {
        patch_jump(proto_state, proto_state.break_jump_fixups[fixup_index])
        if Parser.failed { return }
    }
    resize(&proto_state.break_jump_fixups, break_fixup_base)
}

// Switch parsing ==================================================================================

// switchStmt = "switch" expr switchBody | "switch" switchBody.
parse_switch_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .SWITCH, "expected 'switch'")
    if Parser.failed { return }

    // Keep the subject slot live across arms. Arms restore next_temp_slot
    // to subject_live_cursor (past the subject), not to temp_save.
    temp_save := proto_state.next_temp_slot
    subject_slot := -1
    subject_live_cursor := temp_save

    // Subject switch: evaluate subject expression once.
    if Parser.current_token.kind != .LEFT_BRACE {
        subject_slot = claim_temp_slot(proto_state)
        if Parser.failed { return }

        subject_expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_desc(proto_state, subject_expr, subject_slot)
        if Parser.failed { return }

        subject_live_cursor = subject_slot + 1
        proto_state.next_temp_slot = subject_live_cursor
    }

    consume_token(proto_state, .LEFT_BRACE, "expected '{' after switch subject")
    if Parser.failed { return }

    // Empty switch bodies are valid; any other first token must start an arm.
    if Parser.current_token.kind != .CASE && Parser.current_token.kind != .ELSE && Parser.current_token.kind != .RIGHT_BRACE {
        parser_error(proto_state, Parser.current_token, "expected 'case', 'else', or '}' in switch")
        return
    }
    end_jumps := make([dynamic]int)
    defer delete(end_jumps)

    for Parser.current_token.kind == .CASE {
        advance_token()

        case_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        case_expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_desc(proto_state, case_expr, case_slot)
        if Parser.failed { return }

        consume_token(proto_state, .COLON, "expected ':' after switch case")
        if Parser.failed { return }

        cond_slot := case_slot

        if subject_slot >= 0 {
            cond_slot = claim_temp_slot(proto_state)
            if Parser.failed { return }
            emit_equal(proto_state, cond_slot, subject_slot, case_slot)
            // Reclaim case/cond temps; subject must stay alive.
            proto_state.next_temp_slot = subject_live_cursor
        } else {
            proto_state.next_temp_slot = temp_save
        }

        false_jump := emit_jump_false(proto_state, cond_slot)

        parse_switch_arm_body(proto_state)
        if Parser.failed { return }

        append(&end_jumps, emit_jump(proto_state))

        patch_jump(proto_state, false_jump)
        if Parser.failed { return }

        // Ensure subject slot survives arm body scoping.
        if subject_slot >= 0 {
            if proto_state.next_temp_slot < subject_live_cursor {
                proto_state.next_temp_slot = subject_live_cursor
            }
        } else {
            proto_state.next_temp_slot = temp_save
        }
    }

    if Parser.current_token.kind == .ELSE {
        advance_token()
        consume_token(proto_state, .COLON, "expected ':' after switch else")
        if Parser.failed { return }
        parse_switch_arm_body(proto_state)
        if Parser.failed { return }
        if Parser.current_token.kind == .CASE {
            parser_error(proto_state, Parser.current_token, "case cannot appear after else")
            return
        }
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close switch")
    if Parser.failed { return }

    for end_jump in end_jumps {
        patch_jump(proto_state, end_jump)
        if Parser.failed { return }
    }

    proto_state.next_temp_slot = temp_save
}

// switchArmBody = ":" {stmt}. Parsed until case/else/}/EOF.
parse_switch_arm_body :: proc(proto_state: ^ProtoState) {
    begin_scope(proto_state)
    if Parser.failed { return }

    statement_count := 0
    for Parser.current_token.kind != .CASE && Parser.current_token.kind != .ELSE && Parser.current_token.kind != .RIGHT_BRACE && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
        statement_count += 1
    }

    if statement_count == 0 {
        end_scope(proto_state)
        parser_error(proto_state, Parser.current_token, "switch arm must have at least one statement")
        return
    }

    end_scope(proto_state)
}

// breakStmt = "break".
parse_break_stmt :: proc(proto_state: ^ProtoState) {
    break_token := consume_token(proto_state, .BREAK, "expected 'break'")
    if Parser.failed { return }

    if len(proto_state.loop_break_fixup_bases) == 0 {
        parser_error(proto_state, break_token, "break is only valid inside loops")
        return
    }

    break_jump := emit_jump(proto_state)
    append(&proto_state.break_jump_fixups, break_jump)
}

// returnStmt = "return" [exprList].
parse_return_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .RETURN, "expected 'return'")
    if Parser.failed { return }

    if Parser.current_token.kind == .EOF || Parser.current_token.kind == .RIGHT_BRACE {
        emit_return(proto_state, 0, 0)
        return
    }

    base_slot := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, base_slot)
    if Parser.failed { return }

    if expr_count > MAX_FRAME_SLOTS {
        parser_error(proto_state, Parser.current_token, "return has too many values")
        return
    }

    call_expr, final_is_call := last_expr.(ExprCall)
    if final_is_call {
        prefix_count := expr_count - 1
        return_base := call_expr.base_slot - prefix_count
        if return_base < 0 {
            panic("open return call overlaps fixed return prefix")
        }

        // If evaluating the final callee used temp slots, compact the already
        // lowered fixed prefix so it sits directly before the open call results.
        if return_base != base_slot && prefix_count > 0 {
            for move_index := prefix_count - 1; move_index >= 0; move_index -= 1 {
                emit_move(proto_state, return_base + move_index, base_slot + move_index)
            }
        }

        set_call_open_results(proto_state, call_expr.call_index)
        emit_return(proto_state, return_base, RETURN_OPEN_RESULTS)
        return
    }

    finish_expr_list_to_slots(proto_state, base_slot, expr_count, last_expr, expr_count)
    if Parser.failed { return }

    emit_return(proto_state, base_slot, expr_count)
}

// Simple statements ==============================================================================
// simpleStmt = declStmt | assignStmt | compoundAssignStmt | callStmt.
// Identifier-started forms share a comma-separated prefix until the parser sees
// :=, ::, =, a compound assignment operator, or statement end.

// simpleStmtPrefix = ident {postfix}.
parse_simple_stmt_prefix :: proc(proto_state: ^ProtoState) -> (ident_token: Token, expr: ExprDesc) {
    ident_token = consume_token(proto_state, .IDENT, "expected identifier")
    if Parser.failed { return }

    expr = ExprUnresolvedBinding(ident_token)

    if Parser.current_token.kind != .LEFT_PAREN && Parser.current_token.kind != .LEFT_BRACKET && Parser.current_token.kind != .DOT {
        return
    }

    for {
        if Parser.current_token.kind == .LEFT_PAREN {
            expr = parse_call_postfix(proto_state, expr)
            if Parser.failed { return }
            continue
        }

        if Parser.current_token.kind == .LEFT_BRACKET {
            expr = parse_index_postfix(proto_state, expr)
            if Parser.failed { return }
            continue
        }

        if Parser.current_token.kind == .DOT {
            expr = parse_field_postfix(proto_state, expr)
            if Parser.failed { return }
            continue
        }

        break
    }

    return
}

// declStmt = ["global"] identList declOp exprList.
finish_decl_stmt :: proc(proto_state: ^ProtoState, lhs_tokens: []Token, is_mutable: bool) {
    advance_token()

    lhs_count := len(lhs_tokens)

    if proto_state.function_depth == 0 && len(proto_state.scope_local_marks) == 0 {
        binding_indexes: [MAX_BINDINGS]int
        current_top_level_table := &Active_State.main_env
        if proto_state.is_module {
            current_top_level_table = &Active_State.module_envs[proto_state.module_index]
        }

        for check_index := 0; check_index < lhs_count; check_index += 1 {
            check_name := lhs_tokens[check_index].value.(string)

            for prev_index := 0; prev_index < check_index; prev_index += 1 {
                if lhs_tokens[prev_index].value.(string) == check_name {
                    parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in top-level declaration", check_name))
                    return
                }
            }

            current_top_level_index := binding_table_find(current_top_level_table, check_name)
            if current_top_level_index >= 0 {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("top-level binding `%s` is already declared", check_name))
                return
            }

            import_index := import_namespace_find(proto_state, check_name)
            if import_index >= 0 {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("top-level binding `%s` conflicts with imported namespace", check_name))
                return
            }
        }

        if current_top_level_table.count + lhs_count > MAX_BINDINGS {
            parser_error(proto_state, lhs_tokens[0], "too many top-level bindings")
            return
        }

        for target_index := 0; target_index < lhs_count; target_index += 1 {
            binding_indexes[target_index] = binding_table_append(current_top_level_table, lhs_tokens[target_index].value.(string), is_mutable)
        }

        rhs_base := proto_state.next_temp_slot

        if lhs_count == 1 && Parser.current_token.kind == .FUNCTION {
            ident_text := lhs_tokens[0].value.(string)
            parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
            if Parser.failed { return }
        } else {
            expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
            if Parser.failed { return }

            if expr_count > lhs_count {
                parser_error(proto_state, Parser.current_token, fmt.tprintf("too many values in declaration: expected %d", lhs_count))
                return
            }

            finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
            if Parser.failed { return }
        }

        for target_index := 0; target_index < lhs_count; target_index += 1 {
            if proto_state.is_module {
                emit_set_module_bind(proto_state, rhs_base + target_index, proto_state.module_index, binding_indexes[target_index])
            } else {
                emit_set_main_bind(proto_state, rhs_base + target_index, binding_indexes[target_index])
            }
        }
        return
    }

    // Validate all declared bindings before RHS emission.
    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in local declaration", check_name))
                return
            }
        }

        scope_start := 0
        if len(proto_state.scope_local_marks) > 0 {
            scope_start = proto_state.scope_local_marks[len(proto_state.scope_local_marks) - 1]
        }

        for local_index := scope_start; local_index < proto_state.local_count; local_index += 1 {
            if proto_state.local_bindings[local_index].name == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("local binding `%s` is already declared in this scope", check_name))
                return
            }
        }
    }

    if proto_state.local_count + lhs_count > MAX_FRAME_SLOTS {
        parser_error(proto_state, lhs_tokens[0], "too many local bindings in function")
        return
    }

    // Reserve future local slots for RHS.
    rhs_base := proto_state.local_count
    proto_state.next_temp_slot = rhs_base

    if lhs_count == 1 && Parser.current_token.kind == .FUNCTION {
        ident_text := lhs_tokens[0].value.(string)
        parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
        if Parser.failed { return }
    } else {
        expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
        if Parser.failed { return }

        if expr_count > lhs_count {
            parser_error(proto_state, Parser.current_token, fmt.tprintf("too many values in declaration: expected %d", lhs_count))
            return
        }

        finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
        if Parser.failed { return }
    }

    // Commit local bindings to the slots that already hold the RHS values.
    for target_index := 0; target_index < lhs_count; target_index += 1 {
        local_binding_append(proto_state, lhs_tokens[target_index].value.(string), is_mutable)
    }
}

// assignTarget = ident | ident {postfix} accessPostfix.
resolve_assign_target :: proc(proto_state: ^ProtoState, source_token: Token, target: ExprDesc) -> ExprDesc {
    // Assignment target resolution checks mutability; normal expression reads do not.
    #partial switch t in target {
    case ExprUnresolvedBinding:
        ident_text := t.value.(string)

        local_index := local_binding_find(proto_state, ident_text)
        if local_index >= 0 {
            if !proto_state.local_bindings[local_index].is_mutable {
                parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                return ExprInvalid{}
            }

            return ExprLocalBinding(local_index)
        }

        if proto_state.is_module {
            module_index := proto_state.module_index
            binding_index := binding_table_find(&Active_State.module_envs[module_index], ident_text)
            if binding_index >= 0 {
                if !Active_State.module_envs[module_index].is_mutable[binding_index] {
                    parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                    return ExprInvalid{}
                }

                return ExprModuleBinding{module_index, binding_index}
            }
        } else {
            main_index := binding_table_find(&Active_State.main_env, ident_text)
            if main_index >= 0 {
                if !Active_State.main_env.is_mutable[main_index] {
                    parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                    return ExprInvalid{}
                }

                return ExprMainBinding(main_index)
            }
        }

        import_index := import_namespace_find(proto_state, ident_text)
        if import_index >= 0 {
            parser_error(proto_state, source_token, fmt.tprintf("assignment target `%s` is an imported namespace; namespace names are not assignable", ident_text))
            return ExprInvalid{}
        }

        global_index := binding_table_find(&Active_State.global_env, ident_text)
        if global_index < 0 {
            if proto_state.function_depth > 0 {
                parser_error(proto_state, source_token, fmt.tprintf("assignment target `%s` is not a declared binding in this function; Kiln does not support closures or upvalues", ident_text))
            } else {
                parser_error(proto_state, source_token, fmt.tprintf("assignment target `%s` is not a declared binding", ident_text))
            }
            return ExprInvalid{}
        }

        if !Active_State.global_env.is_mutable[global_index] {
            parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
            return ExprInvalid{}
        }

        return ExprGlobalBinding(global_index)

    case ExprLocalBinding, ExprMainBinding, ExprModuleBinding, ExprGlobalBinding, ExprIndex:
        return target

    case ExprCall:
        parser_error(proto_state, source_token, fmt.tprintf("call expression `%s` is not an assignment target; expected identifier or indexed expression", source_token.value.(string)))
        return ExprInvalid{}

    case ExprImportedBinding:
        module_table := &Active_State.module_envs[t.module_index]
        if !module_table.is_mutable[t.binding_index] {
            parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", module_table.names[t.binding_index]))
            return ExprInvalid{}
        }

        return target
    }

    panic("assignment target resolution reached non-assignable expression descriptor")
}

set_assign_target :: proc(proto_state: ^ProtoState, src_slot: int, target: ExprDesc) {
    #partial switch t in target {
    case ExprLocalBinding:
        dst_slot := proto_state.local_bindings[int(t)].frame_slot
        if dst_slot != src_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprMainBinding:
        emit_set_main_bind(proto_state, src_slot, int(t))

    case ExprModuleBinding:
        emit_set_module_bind(proto_state, src_slot, t.module_index, t.binding_index)

    case ExprImportedBinding:
        emit_set_module_bind(proto_state, src_slot, t.module_index, t.binding_index)

    case ExprGlobalBinding:
        emit_set_global_bind(proto_state, src_slot, int(t))

    case ExprIndex:
        emit_index_set(proto_state, t.container_slot, t.key_slot, src_slot)

    case:
        panic("assignment lowering reached non-assignable expression descriptor")
    }
}

// assignStmt = assignTarget {"," assignTarget} "=" exprList.
finish_assign_stmt :: proc(proto_state: ^ProtoState, lhs_tokens: []Token, targets: []ExprDesc) {
    target_count := len(targets)

    for target_index := 0; target_index < target_count; target_index += 1 {
        targets[target_index] = resolve_assign_target(proto_state, lhs_tokens[target_index], targets[target_index])
        if Parser.failed { return }
    }

    advance_token()

    // RHS expression-list results start after any target-resolution temps.
    rhs_base := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
    if Parser.failed { return }

    if expr_count > target_count {
        parser_error(proto_state, Parser.current_token, fmt.tprintf("too many values in assignment: expected %d", target_count))
        return
    }

    finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, target_count)
    if Parser.failed { return }

    // Write temps into targets after all RHS values are ready.
    for target_index := 0; target_index < target_count; target_index += 1 {
        src_slot := rhs_base + target_index
        set_assign_target(proto_state, src_slot, targets[target_index])
    }
}

// compoundAssignStmt = assignTarget compoundAssignOp expr.
finish_compound_assign_stmt :: proc(proto_state: ^ProtoState, lhs_token: Token, target: ExprDesc) {
    resolved_target := resolve_assign_target(proto_state, lhs_token, target)
    if Parser.failed { return }

    op_token := advance_token()

    value_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    // ExprIndex already holds the container and key slots, so arr[i] += rhs
    // reads and writes the same resolved target.
    lower_expr_desc(proto_state, resolved_target, value_slot)
    if Parser.failed { return }

    rhs_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    rhs_expr := parse_expr(proto_state)
    if Parser.failed { return }

    lower_expr_desc(proto_state, rhs_expr, rhs_slot)
    if Parser.failed { return }

    #partial switch op_token.kind {
    case .PLUS_ASSIGN:
        emit_add(proto_state, value_slot, value_slot, rhs_slot)

    case .MINUS_ASSIGN:
        emit_sub(proto_state, value_slot, value_slot, rhs_slot)

    case .STAR_ASSIGN:
        emit_mul(proto_state, value_slot, value_slot, rhs_slot)

    case .SLASH_ASSIGN:
        emit_div(proto_state, value_slot, value_slot, rhs_slot)

    case .MOD_ASSIGN:
        emit_mod(proto_state, value_slot, value_slot, rhs_slot)

    case:
        panic("compound assignment reached non-compound operator")
    }

    set_assign_target(proto_state, value_slot, resolved_target)
}

// globalDecl = "global" identList declOp exprList.
parse_global_decl_stmt :: proc(proto_state: ^ProtoState) {
    global_token := advance_token()

    lhs_tokens: [MAX_BINDINGS]Token
    binding_indexes: [MAX_BINDINGS]int
    lhs_count := 0

    for {
        if lhs_count >= MAX_BINDINGS {
            parser_error(proto_state, Parser.current_token, "too many global bindings in declaration")
            return
        }

        if Parser.current_token.kind != .IDENT {
            parser_error(proto_state, Parser.current_token, "expected identifier in global declaration")
            return
        }

        lhs_tokens[lhs_count] = advance_token()
        lhs_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
    }

    if Parser.current_token.kind == .ASSIGN {
        parser_error(proto_state, Parser.current_token, "global declarations use ':=' or '::', not '='")
        return
    }

    is_mutable: bool
    if Parser.current_token.kind == .DECL {
        is_mutable = true
    } else if Parser.current_token.kind == .IMMUTABLE_DECL {
        is_mutable = false
    } else {
        parser_error(proto_state, Parser.current_token, "expected ':=' or '::' after global binding list")
        return
    }
    advance_token()

    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in global declaration", check_name))
                return
            }
        }

        global_index := binding_table_find(&Active_State.global_env, check_name)
        if global_index >= 0 {
            parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("global binding `%s` is already declared", check_name))
            return
        }

    }

    if Active_State.global_env.count + lhs_count > MAX_BINDINGS {
        parser_error(proto_state, global_token, "too many global bindings")
        return
    }

    for target_index := 0; target_index < lhs_count; target_index += 1 {
        binding_indexes[target_index] = binding_table_append(&Active_State.global_env, lhs_tokens[target_index].value.(string), is_mutable)
    }

    rhs_base := proto_state.next_temp_slot

    if lhs_count == 1 && Parser.current_token.kind == .FUNCTION {
        ident_text := lhs_tokens[0].value.(string)
        parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
        if Parser.failed { return }
    } else {
        expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
        if Parser.failed { return }

        if expr_count > lhs_count {
            parser_error(proto_state, Parser.current_token, fmt.tprintf("too many values in global declaration: expected %d", lhs_count))
            return
        }

        finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
        if Parser.failed { return }
    }

    for target_index := 0; target_index < lhs_count; target_index += 1 {
        emit_set_global_bind(proto_state, rhs_base + target_index, binding_indexes[target_index])
    }
}

// callStmt = rootExpr {postfix} callPostfix.
parse_call_stmt :: proc(proto_state: ^ProtoState) {
    expr := parse_chain_expr(proto_state)
    if Parser.failed { return }

    call_expr, is_call := expr.(ExprCall)
    if !is_call {
        parser_error(proto_state, Parser.current_token, "call statement must end in a call")
        return
    }

    set_call_requested_results(proto_state, call_expr.call_index, 0)
}

parse_simple_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .IDENT {
        parse_call_stmt(proto_state)
        return
    }

    // These arrays are one local table: index i describes the same comma-separated
    // prefix entry in both arrays. lhs_tokens keeps the source anchor; targets
    // carries the descriptor state.
    lhs_tokens: [MAX_FRAME_SLOTS]Token
    targets: [MAX_FRAME_SLOTS]ExprDesc
    lhs_count := 0

    for {
        if lhs_count >= MAX_FRAME_SLOTS {
            parser_error(proto_state, Parser.current_token, "too many assignment targets")
            return
        }

        lhs_tokens[lhs_count], targets[lhs_count] = parse_simple_stmt_prefix(proto_state)
        if Parser.failed { return }
        lhs_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
    }

    // The operator after the shared target prefix determines the statement form.
    if Parser.current_token.kind == .DECL {
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            #partial switch target in targets[target_index] {
            case ExprUnresolvedBinding:
            case:
                parser_error(proto_state, lhs_tokens[target_index], "declaration target must be an identifier")
                return
            }
        }

        finish_decl_stmt(proto_state, lhs_tokens[:lhs_count], true)
        return
    }

    if Parser.current_token.kind == .IMMUTABLE_DECL {
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            #partial switch target in targets[target_index] {
            case ExprUnresolvedBinding:
            case:
                parser_error(proto_state, lhs_tokens[target_index], "declaration target must be an identifier")
                return
            }
        }

        finish_decl_stmt(proto_state, lhs_tokens[:lhs_count], false)
        return
    }

    if Parser.current_token.kind == .ASSIGN {
        finish_assign_stmt(proto_state, lhs_tokens[:lhs_count], targets[:lhs_count])
        return
    }

    if Parser.current_token.kind == .PLUS_ASSIGN ||
       Parser.current_token.kind == .MINUS_ASSIGN ||
       Parser.current_token.kind == .STAR_ASSIGN ||
       Parser.current_token.kind == .SLASH_ASSIGN ||
       Parser.current_token.kind == .MOD_ASSIGN {
        if lhs_count != 1 {
            parser_error(proto_state, Parser.current_token, "compound assignment expects one assignment target")
            return
        }

        finish_compound_assign_stmt(proto_state, lhs_tokens[0], targets[0])
        return
    }

    if lhs_count == 1 {
        call_expr, is_call := targets[0].(ExprCall)
        if is_call {
            set_call_requested_results(proto_state, call_expr.call_index, 0)
            return
        }

        #partial switch target in targets[0] {
        case ExprUnresolvedBinding:
            parser_error(proto_state, lhs_tokens[0], fmt.tprintf("bare expression `%s` is not a statement; expected declaration, assignment, or call", lhs_tokens[0].value.(string)))
        case ExprIndex:
            parser_error(proto_state, lhs_tokens[0], fmt.tprintf("indexed expression `%s` is not a statement; expected assignment", lhs_tokens[0].value.(string)))
        case:
            parser_error(proto_state, lhs_tokens[0], fmt.tprintf("expression starting with `%s` is not a statement; expected declaration, assignment, or call", lhs_tokens[0].value.(string)))
        }
        return
    }

    parser_error(proto_state, Parser.current_token, "expected declaration or assignment after target list")
}

// stmt = block | simpleStmt | ifStmt | forStmt | switchStmt | returnStmt | breakStmt.
parse_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind == .RETURN {
        parse_return_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .LEFT_BRACE {
        parse_block_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .IF {
        parse_if_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .FOR {
        parse_for_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .BREAK {
        parse_break_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .SWITCH {
        parse_switch_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .CASE {
        parser_error(proto_state, Parser.current_token, "case is only valid inside switch")
        return
    }
    if Parser.current_token.kind == .ELSE {
        parser_error(proto_state, Parser.current_token, "else is only valid after if or inside switch")
        return
    }

    if Parser.current_token.kind == .GLOBAL {
        parse_global_decl_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .IMPORT {
        parser_error(proto_state, Parser.current_token, "import statements must appear before other top-level statements")
        return
    }

    if Parser.current_token.kind == .EXPORT {
        parser_error(proto_state, Parser.current_token, "export is only valid as final top-level module statement")
        return
    }

    if Parser.current_token.kind == .IDENT || Parser.current_token.kind == .FUNCTION || Parser.current_token.kind == .LEFT_BRACKET || Parser.current_token.kind == .MAP {
        parse_simple_stmt(proto_state)
        return
    }

    token := Parser.current_token
    parser_error(proto_state, token, fmt.tprintf("expected statement, got `%s`", error_token_text(token)))
}

// sourceFile = {importStmt} fileBody [exportStmt].
// Top-level statement temps die at statement end.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
    for !Parser.failed && Parser.current_token.kind == .IMPORT {
        parse_import_stmt(proto_state)
        if Parser.failed { return }
    }

    for !Parser.failed && Parser.current_token.kind != .EOF {
        if Parser.current_token.kind == .EXPORT {
            parse_export_stmt(proto_state)
            if Parser.failed { return }

            if Parser.current_token.kind != .EOF {
                parser_error(proto_state, Parser.current_token, "export must be final top-level statement")
                return
            }

            return
        }

        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }
}


// Source compilation =============================================================================

// On success installs Active_State.entry_proto for VM execution.
compile_source :: proc(source, source_name: string) -> ^Error {
    begin_scan(source, source_name)

    Parser.current_token = Token{}
    Parser.failed = false

    advance_token()
    if Parser.failed {
        return &Active_State.error
    }

    entry_origin := SourceLocation{
        source_name = source_name,
        line        = 1,
        column      = 1,
    }
    entry_proto_state := begin_proto(entry_origin, "entry", 0, 0)
    parse_top_level_statements(&entry_proto_state)
    if Parser.failed {
        delete_proto_state(&entry_proto_state)
        return &Active_State.error
    }

    // Source fallthrough is defined as implicit `return nil`.
    // This keeps entry completion on the same RETURN path as explicit source returns.
    return_slot := claim_temp_slot(&entry_proto_state)
    if Parser.failed {
        delete_proto_state(&entry_proto_state)
        return &Active_State.error
    }
    emit_load_nil(&entry_proto_state, return_slot)
    emit_return(&entry_proto_state, return_slot, 1)

    Active_State.entry_proto = end_proto(&entry_proto_state)
    return nil
}

// On success returns a runnable module proto for the selected module table.
compile_module_source :: proc(source, source_name: string, module_index: int) -> (module_proto: ^Proto, err: ^Error) {
    begin_scan(source, source_name)

    Parser.current_token = Token{}
    Parser.failed = false

    advance_token()
    if Parser.failed {
        return nil, &Active_State.error
    }

    module_origin := SourceLocation{
        source_name = source_name,
        line        = 1,
        column      = 1,
    }
    module_proto_state := begin_proto(module_origin, Active_State.module_ids[module_index], 0, 0)
    module_proto_state.is_module = true
    module_proto_state.module_index = module_index

    parse_top_level_statements(&module_proto_state)
    if Parser.failed {
        delete_proto_state(&module_proto_state)
        return nil, &Active_State.error
    }

    // Module fallthrough is defined as implicit `return nil`.
    return_slot := claim_temp_slot(&module_proto_state)
    if Parser.failed {
        delete_proto_state(&module_proto_state)
        return nil, &Active_State.error
    }
    emit_load_nil(&module_proto_state, return_slot)
    emit_return(&module_proto_state, return_slot, 1)

    module_proto = end_proto(&module_proto_state)
    return module_proto, nil
}
