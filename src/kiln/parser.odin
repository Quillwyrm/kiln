package kiln

import "core:fmt"
import "core:os"
import "core:strings"
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
ExprFileBinding       :: distinct int
ExprGlobalBinding     :: distinct int
ExprSlot              :: distinct int
ExprMergeSlot         :: distinct int

// File bindings are bare current-file top-level bindings.
// Imported bindings are exported bindings accessed through a namespace.
ExprImportedBinding :: struct {
    env_index:     int,
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

ExprArrayIndexConst :: struct {
    array_slot: int,
    key_const:  int,
}

ExprMapIndexConst :: struct {
    map_slot:   int,
    key_const:  int,
}

// Parser/lowering handles. These are not all runtime values.
ExprDesc :: union {
    ExprInvalid, // parse failed; Parser.failed already owns the real error
    ExprNil,

    bool,
    i64,
    f64,
    string,

    // Binding references. Context decides whether to read, write, or reject.
    ExprUnresolvedBinding,
    ExprLocalBinding,
    ExprFileBinding,
    ExprGlobalBinding,
    ExprImportedBinding,

    // Materialized slots. ExprMergeSlot is a control-flow merge result from
    // `and`, `or`, or fallback `else`; lower it with MOVE only, never retarget.
    ExprSlot,
    ExprMergeSlot,

    // Call already emitted; result count may still be adjusted by context.
    ExprCall,

    // Deferred indexed access. Context decides read vs write.
    ExprIndex,
    ExprArrayIndexConst,
    ExprMapIndexConst,
}

// Token cursor ===================================================================================


advance_token :: proc() -> Token {
    token := Parser.current_token
    Parser.current_token = scan_next_token()

    if Parser.current_token.kind == .ERROR {
        message := Parser.current_token.value.(string)
        compile_error(Parser.current_token, message)
    }

    return token
}


// Parser errors ==================================================================================

// Scanner.index remains the end of Parser.current_token until advance_token scans again.
current_token_text :: proc() -> string {
    if Parser.current_token.kind == .EOF {
        return "end of file"
    }
    return Scanner.source[Parser.current_token.start:Scanner.index]
}

token_text_for_error :: proc(token: Token) -> string {
    if token.kind == .EOF {
        return "end of file"
    }

    if token.kind == Parser.current_token.kind && token.start == Parser.current_token.start {
        return current_token_text()
    }

    #partial switch token.kind {
    case .IDENT, .STRING, .ERROR:
        return token.value.(string)
    }

    return current_token_text()
}

compile_error :: proc(token: Token, message: string) {
    line, column := source_line_col_at(Scanner.source, token.start)
    set_error(fmt.tprintf("%s[%d:%d] Error: %s", Scanner.source_name, line, column, message))
    Parser.failed = true
}

compile_error_near :: proc(token: Token, message: string) {
    line, column := source_line_col_at(Scanner.source, token.start)
    set_error(fmt.tprintf("%s[%d:%d] Error near %s: %s", Scanner.source_name, line, column, token_text_for_error(token), message))
    Parser.failed = true
}


// Slots and locals ===============================================================================

// Temp slots are bounded by MAX_FRAME_SLOTS due to u8 slot encoding.
// next_temp_slot is the allocation cursor. frame_slot_count is the high-water mark
// (max slot touched + 1), maintained by record_slots. These are separate:
// next_temp_slot can be saved/restored to free temps (e.g. condition slots),
// while frame_slot_count only grows.
claim_temp_slot :: proc(proto_state: ^ProtoState) -> int {
    if proto_state.next_temp_slot >= MAX_FRAME_SLOTS {
        compile_error(Parser.current_token, "function uses too many values")
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
        compile_error(Parser.current_token, "function uses too many values")
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
local_binding_append :: proc(proto_state: ^ProtoState, name: string, is_mutable: bool) {
    slot := proto_state.local_count
    proto_state.local_bindings[slot] = LocalBinding{
        name       = name,
        is_mutable = is_mutable,
    }
    proto_state.local_count += 1
    proto_state.next_temp_slot = proto_state.local_count
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
        importer_dir := filepath.dir(proto_state.source_name)
        defer delete(importer_dir)

        join_parts := [?]string{importer_dir, source_path}
        path, join_error := filepath.join(join_parts[:], context.allocator)
        if join_error != nil {
            compile_error(path_token, fmt.tprintf("failed to resolve module path `%s`", module_path))
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
        compile_error(path_token, fmt.tprintf("failed to resolve module path `%s`", module_path))
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
            if local_index != dst_slot {
                emit_move(proto_state, dst_slot, local_index)
            }
            return
        }

        env := &Active_State.envs[proto_state.env_index]
        binding_index := binding_env_find(env, ident_name)
        if binding_index >= 0 {
            emit_get_file_bind(proto_state, dst_slot, binding_index)
            return
        }

        import_index := import_namespace_find(proto_state, ident_name)
        if import_index >= 0 {
            compile_error(Token(desc), fmt.tprintf("namespace `%s` cannot be used as a value; access an exported binding with '.'", ident_name))
            return
        }

        global_index := binding_env_find(&Active_State.global_env, ident_name)
        if global_index < 0 {
            if proto_state.is_function {
                compile_error(Token(desc), fmt.tprintf("binding `%s` is not declared in this function; Kiln does not support closures or upvalues", ident_name))
            } else {
                compile_error(Token(desc), fmt.tprintf("binding `%s` is not declared", ident_name))
            }
            return
        }

        emit_get_global_bind(proto_state, dst_slot, global_index)

    case ExprLocalBinding:
        local_slot := int(desc)
        if local_slot != dst_slot {
            emit_move(proto_state, dst_slot, local_slot)
        }

    case ExprFileBinding:
        emit_get_file_bind(proto_state, dst_slot, int(desc))

    case ExprGlobalBinding:
        emit_get_global_bind(proto_state, dst_slot, int(desc))

    case ExprImportedBinding:
        emit_get_module_bind(proto_state, dst_slot, desc.env_index, desc.binding_index)

    case ExprSlot:
        src_slot := int(desc)
        if src_slot != dst_slot {
            if retarget_last_result(proto_state, src_slot, dst_slot) {
                return
            }

            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprMergeSlot:
        src_slot := int(desc)
        if src_slot != dst_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprCall:
        set_call_requested_results(proto_state, desc.call_index, 1)
        if desc.base_slot != dst_slot {
            emit_move(proto_state, dst_slot, desc.base_slot)
        }

    case ExprIndex:
        emit_index_get(proto_state, dst_slot, desc.container_slot, desc.key_slot)

    case ExprArrayIndexConst:
        emit_array_get_const(proto_state, dst_slot, desc.array_slot, desc.key_const)

    case ExprMapIndexConst:
        emit_map_get_const(proto_state, dst_slot, desc.map_slot, desc.key_const)

    }
}

expr_read_slot :: proc(proto_state: ^ProtoState, expr: ExprDesc) -> int {
    #partial switch desc in expr {
    case ExprInvalid:
        return 0

    case ExprLocalBinding:
        return int(desc)

    case ExprSlot:
        return int(desc)

    case ExprMergeSlot:
        return int(desc)

    case ExprCall:
        set_call_requested_results(proto_state, desc.call_index, 1)
        return desc.base_slot

    case ExprUnresolvedBinding:
        ident_name := desc.value.(string)
        local_index := local_binding_find(proto_state, ident_name)
        if local_index >= 0 {
            return local_index
        }

        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        lower_expr_desc(proto_state, expr, dst_slot)
        return dst_slot

    case ExprIndex:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_index_get(proto_state, dst_slot, desc.container_slot, desc.key_slot)
        return dst_slot

    case ExprArrayIndexConst:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_array_get_const(proto_state, dst_slot, desc.array_slot, desc.key_const)
        return dst_slot

    case ExprMapIndexConst:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_map_get_const(proto_state, dst_slot, desc.map_slot, desc.key_const)
        return dst_slot

    case:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        lower_expr_desc(proto_state, expr, dst_slot)
        return dst_slot
    }
}

expr_writable_slot :: proc(proto_state: ^ProtoState, expr: ExprDesc) -> int {
    #partial switch desc in expr {
    case ExprInvalid:
        return 0

    case ExprSlot:
        return int(desc)

    case ExprCall:
        set_call_requested_results(proto_state, desc.call_index, 1)
        return desc.base_slot

    case ExprIndex:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_index_get(proto_state, dst_slot, desc.container_slot, desc.key_slot)
        return dst_slot

    case ExprArrayIndexConst:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_array_get_const(proto_state, dst_slot, desc.array_slot, desc.key_const)
        return dst_slot

    case ExprMapIndexConst:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        emit_map_get_const(proto_state, dst_slot, desc.map_slot, desc.key_const)
        return dst_slot

    case:
        dst_slot := claim_temp_slot(proto_state)
        if Parser.failed { return 0 }

        lower_expr_desc(proto_state, expr, dst_slot)
        return dst_slot
    }
}

// Expression roots and chains =====================================================================

// arrayLiteral = "[" [exprList [","]] "]".
parse_array_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind != .LEFT_BRACKET {
        compile_error_near(Parser.current_token, "expected '[' to start array literal")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    array_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    new_array_inst := emit_new_array(proto_state, array_slot, 0)
    element_count := 0

    if Parser.current_token.kind != .RIGHT_BRACKET {
        for {
            value_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            value_slot := expr_read_slot(proto_state, value_expr)
            if Parser.failed { return ExprInvalid{} }

            emit_array_push(proto_state, array_slot, value_slot)
            element_count += 1

            // Element temps are dead after push; keep the array itself.
            proto_state.next_temp_slot = array_slot + 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.failed { return ExprInvalid{} }
            if Parser.current_token.kind == .RIGHT_BRACKET {
                break
            }
        }
    }

    if Parser.current_token.kind != .RIGHT_BRACKET {
        compile_error_near(Parser.current_token, "expected ']' after array literal")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    if element_count < 65536 {
        patch_new_array_capacity(proto_state, new_array_inst, element_count)
    }

    return ExprSlot(array_slot)
}

// mapLiteral = "map" "{" [mapEntryList [","]] "}".
parse_map_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind != .MAP {
        compile_error_near(Parser.current_token, "expected 'map' to start map literal")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind != .LEFT_BRACE {
        compile_error_near(Parser.current_token, "expected '{' after map")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    map_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    new_map_inst := emit_new_map(proto_state, map_slot, 0)
    entry_count := 0

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
                if Parser.failed { return ExprInvalid{} }

                if Parser.current_token.kind == .LEFT_PAREN {
                    compile_error_near(Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got call expression")
                    return ExprInvalid{}
                }

                if Parser.current_token.kind == .LEFT_BRACKET {
                    compile_error_near(Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got indexed expression")
                    return ExprInvalid{}
                }

                if Parser.current_token.kind == .DOT {
                    compile_error_near(Parser.current_token, "map key invalid; expected identifier shorthand or string literal, got field or namespace expression")
                    return ExprInvalid{}
                }

            case .STRING:
                key_text = key_token.value.(string)
                advance_token()
                if Parser.failed { return ExprInvalid{} }

            case:
                compile_error_near(key_token, "map key invalid; expected identifier shorthand or string literal")
                return ExprInvalid{}
            }

            for existing_key in key_texts {
                if existing_key == key_text {
                    compile_error(key_token, fmt.tprintf("duplicate map key `%s`", key_text))
                    return ExprInvalid{}
                }
            }
            append(&key_texts, key_text)

            if Parser.current_token.kind != .COLON {
                compile_error_near(Parser.current_token, "map entry invalid; expected ':' after map key")
                return ExprInvalid{}
            }
            advance_token()
            if Parser.failed { return ExprInvalid{} }

            key_const := const_string(proto_state, key_text)
            if Parser.failed { return ExprInvalid{} }

            value_token := Parser.current_token
            if value_token.kind == .NIL {
                compile_error(value_token, fmt.tprintf("invalid value for key `%s` in map literal; nil literals are not valid in map literals", key_text))
                return ExprInvalid{}
            }

            if key_const < 256 {
                value_expr := parse_expr(proto_state)
                if Parser.failed { return ExprInvalid{} }

                value_slot := expr_read_slot(proto_state, value_expr)
                if Parser.failed { return ExprInvalid{} }

                emit_map_set_const(proto_state, map_slot, key_const, value_slot)
            } else {
                key_slot := claim_temp_slot(proto_state)
                if Parser.failed { return ExprInvalid{} }

                emit_load_const(proto_state, key_slot, key_const)

                value_expr := parse_expr(proto_state)
                if Parser.failed { return ExprInvalid{} }

                value_slot := expr_read_slot(proto_state, value_expr)
                if Parser.failed { return ExprInvalid{} }

                emit_index_set(proto_state, map_slot, key_slot, value_slot)
            }

            entry_count += 1

            // Key/value temps are dead after set; keep the map itself.
            proto_state.next_temp_slot = map_slot + 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.failed { return ExprInvalid{} }
            if Parser.current_token.kind == .RIGHT_BRACE {
                break
            }
        }
    }

    if entry_count < 65536 {
        patch_new_map_capacity(proto_state, new_map_inst, entry_count)
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "map entry invalid; expected ',' or '}' after map value")
        return ExprInvalid{}
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected '}' after map literal")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    return ExprSlot(map_slot)
}

// groupedExpr = "(" expr ")".
parse_grouped_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind != .LEFT_PAREN {
        compile_error_near(Parser.current_token, "expected '(' to start grouped expression")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind != .RIGHT_PAREN {
        compile_error_near(Parser.current_token, "expected ')' after grouped expression")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind == .LEFT_PAREN || Parser.current_token.kind == .LEFT_BRACKET || Parser.current_token.kind == .DOT {
        compile_error(Parser.current_token, "grouped expression cannot be used as a chain root")
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

        parse_function_literal(proto_state, slot, "function", Parser.current_token)
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
    compile_error_near(token, fmt.tprintf("expected chain expression, got `%s`", current_token_text()))
    return ExprInvalid{}
}

// callPostfix = "(" [exprList [","]] ")".
// Layout: callee_slot, arg0, arg1, ...
// Arguments are single-valued; call expansion only happens in return/assignment lists.
parse_call_postfix :: proc(proto_state: ^ProtoState, callee: ExprDesc) -> ExprDesc {
    if Parser.current_token.kind != .LEFT_PAREN {
        compile_error_near(Parser.current_token, "expected '(' to start call arguments")
        return ExprInvalid{}
    }
    advance_token()
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
                compile_error(Parser.current_token, "call uses too many values")
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
            if Parser.failed { return ExprInvalid{} }
            if Parser.current_token.kind == .RIGHT_PAREN {
                break
            }
        }
    }

    if Parser.current_token.kind != .RIGHT_PAREN {
        compile_error_near(Parser.current_token, "expected ')' after call arguments")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    call_index := emit_call(proto_state, base_slot, arg_count, 1)
    return ExprCall{base_slot, call_index}
}

// indexPostfix = "[" expr "]".
parse_index_postfix :: proc(proto_state: ^ProtoState, container: ExprDesc) -> ExprDesc {
    if Parser.current_token.kind != .LEFT_BRACKET {
        compile_error_near(Parser.current_token, "expected '[' to start index expression")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    // Preserve evaluation order:
    //   1. materialize/read the container
    //   2. evaluate the key expression
    //   3. either use a const-pool key directly (literal) or materialize/read the key
    //
    // INDEX_GET / INDEX_SET can read container/key from any slots, so locals and
    // already-materialized temps do not need fake MOVE copies.
    container_slot := expr_read_slot(proto_state, container)
    if Parser.failed { return ExprInvalid{} }

    reserve_slots_until(proto_state, container_slot + 1)
    if Parser.failed { return ExprInvalid{} }

    key_expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind != .RIGHT_BRACKET {
        compile_error_near(Parser.current_token, "expected ']' after index expression")
        return ExprInvalid{}
    }
    advance_token()
    if Parser.failed { return ExprInvalid{} }

    // If the key expression is an i64 or string literal, encode it as a typed
    // const-pool reference to skip a LOAD_CONST + INDEX_GET/INDEX_SET pair.
    #partial switch key in key_expr {
    case i64:
        key_const := const_int(proto_state, key)
        if Parser.failed { return ExprInvalid{} }

        if key_const < 256 {
            return ExprArrayIndexConst{container_slot, key_const}
        }

    case string:
        key_const := const_string(proto_state, key)
        if Parser.failed { return ExprInvalid{} }

        if key_const < 256 {
            return ExprMapIndexConst{container_slot, key_const}
        }
    }

    key_slot := expr_read_slot(proto_state, key_expr)
    if Parser.failed { return ExprInvalid{} }

    reserve_slots_until(proto_state, key_slot + 1)
    if Parser.failed { return ExprInvalid{} }

    return ExprIndex{container_slot, key_slot}
}

// fieldPostfix = "." ident.
// Current implementation supports imported module namespace access only.
parse_field_postfix :: proc(proto_state: ^ProtoState, left: ExprDesc) -> ExprDesc {
    if Parser.current_token.kind != .DOT {
        compile_error_near(Parser.current_token, "expected '.' to start access expression")
        return ExprInvalid{}
    }
    dot_token := advance_token()
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind != .IDENT {
        compile_error_near(Parser.current_token, "expected identifier after '.'")
        return ExprInvalid{}
    }
    member_token := advance_token()
    if Parser.failed { return ExprInvalid{} }

    namespace_token, is_namespace_candidate := left.(ExprUnresolvedBinding)
    if !is_namespace_candidate {
        compile_error(dot_token, "invalid access expression; expected imported namespace before '.'")
        return ExprInvalid{}
    }

    namespace_name := namespace_token.value.(string)
    import_index := import_namespace_find(proto_state, namespace_name)
    local_index := local_binding_find(proto_state, namespace_name)
    if local_index >= 0 {
        if import_index >= 0 {
            compile_error(Token(namespace_token), fmt.tprintf("invalid access expression; local binding `%s` shadows imported namespace", namespace_name))
        } else {
            compile_error(Token(namespace_token), fmt.tprintf("invalid access expression; local binding `%s` is not an imported namespace", namespace_name))
        }
        return ExprInvalid{}
    }

    if import_index < 0 {
        compile_error(Token(namespace_token), fmt.tprintf("invalid access expression; namespace `%s` not found", namespace_name))
        return ExprInvalid{}
    }

    env_index := proto_state.import_env_indexes[import_index]
    member_name := member_token.value.(string)
    env := &Active_State.envs[env_index]
    binding_index := binding_env_find(env, member_name)
    if binding_index < 0 {
        compile_error(member_token, fmt.tprintf("invalid access expression; module `%s` has no binding `%s`", namespace_name, member_name))
        return ExprInvalid{}
    }

    if !(.EXPORTED in env.flags[binding_index]) {
        compile_error(member_token, fmt.tprintf("module `%s` does not export binding `%s`", namespace_name, member_name))
        return ExprInvalid{}
    }

    return ExprImportedBinding{env_index, binding_index}
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
        compile_error_near(token, fmt.tprintf("expected expression, got `%s`", current_token_text()))
        return ExprInvalid{}
    }
}

// unaryExpr = unaryOp unaryExpr | primaryExpr.
parse_unary_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if Parser.current_token.kind == .NOT {
        advance_token()
        if Parser.failed { return ExprInvalid{} }

        operand := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        operand_slot := expr_read_slot(proto_state, operand)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        emit_not(proto_state, result_slot, operand_slot)
        return ExprSlot(result_slot)
    }

    if Parser.current_token.kind == .MINUS {
        advance_token()
        if Parser.failed { return ExprInvalid{} }

        operand := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        operand_slot := expr_read_slot(proto_state, operand)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        emit_neg(proto_state, result_slot, operand_slot)
        return ExprSlot(result_slot)
    }

    return parse_primary_expr(proto_state)
}

// const_index_from_numeric_literal checks if an expression is a numeric literal
// (i64 or f64) suitable for a const arithmetic opcode. Returns the const pool index
// and true if the literal fits in 8-bit C field (< 256).
const_index_from_numeric_literal :: proc(proto_state: ^ProtoState, expr: ExprDesc) -> (int, bool) {
    #partial switch v in expr {
    case i64:
        idx := const_int(proto_state, v)
        if Parser.failed { return 0, false }
        return idx, idx < 256

    case f64:
        idx := const_float(proto_state, v)
        if Parser.failed { return 0, false }
        return idx, idx < 256
    }

    return 0, false
}

// mulExpr = unaryExpr {mulOp unaryExpr}.
parse_mul_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_unary_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    // mulOp = "*" | "/" | "%".
    for Parser.current_token.kind == .STAR || Parser.current_token.kind == .SLASH || Parser.current_token.kind == .MOD {
        op_token := advance_token()
        if Parser.failed { return ExprInvalid{} }

        // Materialize the left side before parsing the right side.
        // This preserves Kiln's left-to-right evaluation order for non-local reads.
        lhs_slot := expr_read_slot(proto_state, left)
        if Parser.failed { return ExprInvalid{} }

        right := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        if rhs_const, rhs_ok := const_index_from_numeric_literal(proto_state, right); rhs_ok {
            if op_token.kind == .STAR {
                emit_mul_const(proto_state, result_slot, lhs_slot, rhs_const)
            } else if op_token.kind == .SLASH {
                emit_div_const(proto_state, result_slot, lhs_slot, rhs_const)
            } else {
                emit_mod_const(proto_state, result_slot, lhs_slot, rhs_const)
            }
        } else {
            rhs_slot := expr_read_slot(proto_state, right)
            if Parser.failed { return ExprInvalid{} }

            if op_token.kind == .STAR {
                emit_mul(proto_state, result_slot, lhs_slot, rhs_slot)
            } else if op_token.kind == .SLASH {
                emit_div(proto_state, result_slot, lhs_slot, rhs_slot)
            } else {
                emit_mod(proto_state, result_slot, lhs_slot, rhs_slot)
            }
        }

        // Only the accumulated result remains live after the binary op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot(result_slot)
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
        if Parser.failed { return ExprInvalid{} }

        // Materialize the left side before parsing the right side.
        // This preserves Kiln's left-to-right evaluation order for non-local reads.
        lhs_slot := expr_read_slot(proto_state, left)
        if Parser.failed { return ExprInvalid{} }

        right := parse_mul_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        if op_token.kind == .CONCAT {
            rhs_slot := expr_read_slot(proto_state, right)
            if Parser.failed { return ExprInvalid{} }

            emit_concat(proto_state, result_slot, lhs_slot, rhs_slot)
        } else if rhs_const, rhs_ok := const_index_from_numeric_literal(proto_state, right); rhs_ok {
            if op_token.kind == .PLUS {
                emit_add_const(proto_state, result_slot, lhs_slot, rhs_const)
            } else {
                emit_sub_const(proto_state, result_slot, lhs_slot, rhs_const)
            }
        } else {
            rhs_slot := expr_read_slot(proto_state, right)
            if Parser.failed { return ExprInvalid{} }

            if op_token.kind == .PLUS {
                emit_add(proto_state, result_slot, lhs_slot, rhs_slot)
            } else {
                emit_sub(proto_state, result_slot, lhs_slot, rhs_slot)
            }
        }

        // Only the accumulated result remains live after the binary op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot(result_slot)
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
        if Parser.failed { return ExprInvalid{} }

        // Materialize the left side before parsing the right side.
        // This preserves Kiln's left-to-right evaluation order for non-local reads.
        lhs_slot := expr_read_slot(proto_state, left)
        if Parser.failed { return ExprInvalid{} }

        right := parse_add_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := expr_read_slot(proto_state, right)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        #partial switch op_token.kind {
        case .EQUAL:
            emit_equal(proto_state, result_slot, lhs_slot, rhs_slot)

        case .NOT_EQUAL:
            emit_equal(proto_state, result_slot, lhs_slot, rhs_slot)
            emit_not(proto_state, result_slot, result_slot)

        case .LESS:
            emit_less(proto_state, result_slot, lhs_slot, rhs_slot)

        case .LESS_OR_EQUAL:
            emit_less_or_equal(proto_state, result_slot, lhs_slot, rhs_slot)

        case .GREATER:
            // a > b is emitted as b < a because the VM has LESS, not GREATER.
            emit_less(proto_state, result_slot, rhs_slot, lhs_slot)

        case .GREATER_OR_EQUAL:
            emit_less_or_equal(proto_state, result_slot, rhs_slot, lhs_slot)
        }

        // Only the comparison result remains live after the binary op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot(result_slot)

        // compareExpr allows one compareOp, not a chain.
        #partial switch Parser.current_token.kind {
        case .EQUAL, .NOT_EQUAL, .LESS, .LESS_OR_EQUAL, .GREATER, .GREATER_OR_EQUAL:
            compile_error(Parser.current_token, "comparison chaining is not valid; use parentheses or split the expression")
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
        if Parser.failed { return ExprInvalid{} }

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
        left = ExprMergeSlot(result_slot)
    }

    return left
}


// orExpr = andExpr {"or" andExpr}.
parse_or_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_and_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    for Parser.current_token.kind == .OR {
        advance_token()
        if Parser.failed { return ExprInvalid{} }

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
        left = ExprMergeSlot(result_slot)
    }

    return left
}


// fallbackExpr = orExpr ["else" fallbackExpr].
parse_fallback_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_or_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    if Parser.current_token.kind == .ELSE {
        saved_index := Scanner.index
        saved_token_start := Scanner.token_start
        saved_failed := Scanner.failed

        next_token := scan_next_token()

        Scanner.index = saved_index
        Scanner.token_start = saved_token_start
        Scanner.failed = saved_failed

        if next_token.kind == .COLON {
            return left
        }

        advance_token()
        if Parser.failed { return ExprInvalid{} }

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
        return ExprMergeSlot(result_slot)
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
        if Parser.failed { return }

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
        set_call_requested_results(proto_state, call_expr.call_index, wanted_from_last)
        if Parser.failed { return }

        if call_expr.base_slot == last_dst {
            if wanted_from_last > 1 {
                record_slots(proto_state, last_dst + wanted_from_last - 1)
            }
            return
        }

        if last_dst < call_expr.base_slot {
            for move_index := 0; move_index < wanted_from_last; move_index += 1 {
                emit_move(proto_state, last_dst + move_index, call_expr.base_slot + move_index)
            }
        } else {
            for move_index := wanted_from_last - 1; move_index >= 0; move_index -= 1 {
                emit_move(proto_state, last_dst + move_index, call_expr.base_slot + move_index)
            }
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
    if Parser.current_token.kind != .LEFT_BRACE {
        compile_error_near(Parser.current_token, "expected '{' to start function body")
        return
    }
    advance_token()
    if Parser.failed { return }

    for !Parser.failed && Parser.current_token.kind != .RIGHT_BRACE && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if Parser.current_token.kind == .EOF {
        compile_error_near(Parser.current_token, "expected '}' to close function body")
        return
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected '}' to close function body")
        return
    }
    advance_token()
}

// functionLiteral = "function" "(" [paramList [","]] ")" block.
// The compiled child proto is stored on the parent and loaded by LOAD_FUNC at runtime.
parse_function_literal :: proc(parent_proto_state: ^ProtoState, dst: int, function_name: string, origin_token: Token) {
    if Parser.current_token.kind != .FUNCTION {
        compile_error_near(Parser.current_token, "expected 'function'")
        return
    }
    advance_token()
    if Parser.failed { return }

    if Parser.current_token.kind != .LEFT_PAREN {
        compile_error_near(Parser.current_token, "expected '(' after function")
        return
    }
    advance_token()
    if Parser.failed { return }

    // Parameters are collected before creating the child proto so its arity is known.
    param_tokens: [MAX_CALL_ARGS]Token
    param_count := 0
    if Parser.current_token.kind != .RIGHT_PAREN {
        for {
            if param_count >= MAX_CALL_ARGS {
                compile_error(Parser.current_token, "too many function parameters")
                return
            }

            if Parser.current_token.kind != .IDENT {
                compile_error_near(Parser.current_token, "expected parameter identifier")
                return
            }
            param_tokens[param_count] = advance_token()
            if Parser.failed {
                return
            }
            param_count += 1

            if Parser.current_token.kind != .COMMA {
                break
            }

            advance_token()
            if Parser.failed { return }
            if Parser.current_token.kind == .RIGHT_PAREN {
                break
            }
        }
    }

    if Parser.current_token.kind != .RIGHT_PAREN {
        compile_error_near(Parser.current_token, "expected ')' after function parameters")
        return
    }
    advance_token()
    if Parser.failed { return }

    child_line, _ := source_line_col_at(Scanner.source, origin_token.start)
    child_proto_state := begin_proto(parent_proto_state.source_name, child_line, function_name, param_count, true, parent_proto_state.env_index)

    for import_index := 0; import_index < parent_proto_state.import_count; import_index += 1 {
        child_proto_state.import_names[import_index] = parent_proto_state.import_names[import_index]
        child_proto_state.import_env_indexes[import_index] = parent_proto_state.import_env_indexes[import_index]
    }
    child_proto_state.import_count = parent_proto_state.import_count

    // Parameters are local slots starting at slot 0.
    // The VM call path places arguments directly into those slots.
    for param_index := 0; param_index < param_count; param_index += 1 {
        param_name := param_tokens[param_index].value.(string)

        for prev_index := 0; prev_index < param_index; prev_index += 1 {
            if param_tokens[prev_index].value.(string) == param_name {
                compile_error(param_tokens[param_index], fmt.tprintf("parameter binding `%s` is already declared in this function", param_name))
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
        compile_error(origin_token, "too many functions in function")
        return
    }

    child_proto := end_proto(&child_proto_state)
    child_proto_index := len(parent_proto_state.child_protos)
    append(&parent_proto_state.child_protos, child_proto)
    emit_load_func(parent_proto_state, dst, child_proto_index)
}

try_label_function :: proc(proto_state: ^ProtoState, rhs_expr: ExprDesc, label: string) -> bool {
    rhs_slot, is_slot := rhs_expr.(ExprSlot)
    if !is_slot {
        return false
    }

    if len(proto_state.bytecode) == 0 {
        return false
    }

    word := proto_state.bytecode[len(proto_state.bytecode) - 1]
    if decode_op(word) != .LOAD_FUNC {
        return false
    }

    inst := InstABx(word)
    if int(inst.a) != int(rhs_slot) {
        return false
    }

    child_proto_index := int(inst.b)
    if child_proto_index >= len(proto_state.child_protos) {
        panic("LOAD_FUNC child proto index out of range")
    }

    child_proto := proto_state.child_protos[child_proto_index]
    if !child_proto.is_function || child_proto.proto_label != "function" {
        return false
    }

    delete(child_proto.proto_label)
    child_proto.proto_label = strings.clone(label)
    return true
}


// Statements =====================================================================================

// importStmt = "import" [ident] stringLiteral.
parse_import_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .IMPORT {
        compile_error_near(Parser.current_token, "expected 'import'")
        return
    }
    import_token := advance_token()
    if Parser.failed { return }

    alias_token := Token{}
    has_alias := false
    if Parser.current_token.kind == .IDENT {
        alias_token = advance_token()
        if Parser.failed { return }
        has_alias = true
    }

    if Parser.current_token.kind != .STRING {
        compile_error_near(Parser.current_token, "expected module path string after import")
        return
    }
    path_token := advance_token()
    if Parser.failed { return }

    module_path := path_token.value.(string)
    namespace_name := module_namespace_from_path(module_path)
    namespace_token := path_token
    if has_alias {
        namespace_name = alias_token.value.(string)
        namespace_token = alias_token
    }

    if namespace_name == "" {
        compile_error(path_token, "import namespace invalid; expected non-empty module name or explicit alias")
        return
    }

    if !module_namespace_is_valid(namespace_name) {
        compile_error(namespace_token, fmt.tprintf("import namespace `%s` invalid; expected identifier", namespace_name))
        return
    }

    if proto_state.import_count >= MAX_ENVS {
        compile_error(import_token, "too many imports")
        return
    }

    import_index := import_namespace_find(proto_state, namespace_name)
    if import_index >= 0 {
        compile_error(namespace_token, fmt.tprintf("import namespace `%s` is already declared", namespace_name))
        return
    }

    current_env := &Active_State.envs[proto_state.env_index]
    current_top_level_index := binding_env_find(current_env, namespace_name)
    if current_top_level_index >= 0 {
        compile_error(namespace_token, fmt.tprintf("import namespace `%s` conflicts with top-level binding", namespace_name))
        return
    }

    env_index := -1
    resolved_source_path, source_found := resolve_import_source_path(proto_state, path_token, module_path)
    if Parser.failed { return }

    if source_found {
        env_index = env_find(resolved_source_path)
        if env_index >= 0 {
            // Check loading stack for cycle detection.
            for loading_i := 0; loading_i < Active_State.loading_env_count; loading_i += 1 {
                if Active_State.loading_env_indexes[loading_i] == env_index {
                    delete(resolved_source_path)
                    compile_error(path_token, fmt.tprintf("cyclic import detected for module `%s`", module_path))
                    return
                }
            }
            delete(resolved_source_path)
        } else {
            source_bytes, read_error := os.read_entire_file(resolved_source_path, context.allocator)
            if read_error != nil {
                delete(resolved_source_path)
                compile_error(path_token, fmt.tprintf("failed to read module `%s`", module_path))
                return
            }

            if Active_State.env_count >= MAX_ENVS {
                delete(source_bytes)
                delete(resolved_source_path)
                compile_error(path_token, "too many modules")
                return
            }

            env_index = bind_env(resolved_source_path)

            // Push to loading stack for cycle detection.
            Active_State.loading_env_indexes[Active_State.loading_env_count] = env_index
            Active_State.loading_env_count += 1

            // Module compilation reuses the package-level scanner/parser.
            // Save the importing cursor so import loading can return to this file.
            outer_parser := Parser
            outer_scanner := Scanner
            module_proto, compile_error := compile_imported_source(string(source_bytes), Active_State.envs[env_index].id, env_index)
            Parser = outer_parser
            Scanner = outer_scanner
            delete(source_bytes)
            delete(resolved_source_path)

            if compile_error != "" {
                Parser.failed = true
                return
            }

            // Run the imported module after compilation, before the importer continues.
            module_result, run_error := run_proto(Active_State, module_proto)
            // Pop after module init. Error paths leave State disposable.
            Active_State.loading_env_count -= 1

            if run_error != "" {
                Parser.failed = true
                return
            }
        }
    } else {
        env_index = env_find(module_path)
        if env_index < 0 {
            compile_error(path_token, fmt.tprintf("module `%s` not found", module_path))
            return
        }
    }

    for existing_import := 0; existing_import < proto_state.import_count; existing_import += 1 {
        if proto_state.import_env_indexes[existing_import] == env_index {
            existing_namespace := proto_state.import_names[existing_import]
            compile_error(path_token, fmt.tprintf("module `%s` is already imported as `%s`", module_path, existing_namespace))
            return
        }
    }

    proto_state.import_names[proto_state.import_count] = namespace_name
    proto_state.import_env_indexes[proto_state.import_count] = env_index
    proto_state.import_count += 1
}

// exportStmt = "export" | "export" "{" ident {"," ident} [","] "}".
parse_export_stmt :: proc(proto_state: ^ProtoState, allow_export: bool) {
    if Parser.current_token.kind != .EXPORT {
        compile_error_near(Parser.current_token, "expected 'export'")
        return
    }
    export_token := advance_token()
    if Parser.failed { return }

    if !allow_export {
        compile_error(export_token, "export is only valid in module files")
        return
    }

    env := &Active_State.envs[proto_state.env_index]

    if Parser.current_token.kind != .LEFT_BRACE {
        for binding_index := 0; binding_index < env.count; binding_index += 1 {
            env.flags[binding_index] += {.EXPORTED}
        }
        return
    }

    if Parser.current_token.kind != .LEFT_BRACE {
        compile_error_near(Parser.current_token, "expected '{' after export")
        return
    }
    advance_token()
    if Parser.failed { return }

    if Parser.current_token.kind == .RIGHT_BRACE {
        compile_error(Parser.current_token, "export manifest invalid; expected at least one binding name")
        return
    }

    export_tokens: [MAX_BINDINGS]Token
    export_binding_indexes: [MAX_BINDINGS]int
    export_count := 0

    for {
        if export_count >= MAX_BINDINGS {
            compile_error(Parser.current_token, "too many bindings in export manifest")
            return
        }

        if Parser.current_token.kind != .IDENT {
            compile_error_near(Parser.current_token, "expected binding name in export manifest")
            return
        }
        name_token := advance_token()
        if Parser.failed { return }

        name := name_token.value.(string)
        for prev_index := 0; prev_index < export_count; prev_index += 1 {
            if export_tokens[prev_index].value.(string) == name {
                compile_error(name_token, fmt.tprintf("duplicate export binding `%s`", name))
                return
            }
        }

        binding_index := binding_env_find(env, name)
        if binding_index < 0 {
            compile_error(name_token, fmt.tprintf("export binding `%s` is not declared in this module", name))
            return
        }

        export_tokens[export_count] = name_token
        export_binding_indexes[export_count] = binding_index
        export_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
        if Parser.failed { return }
        if Parser.current_token.kind == .RIGHT_BRACE {
            break
        }
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected '}' after export manifest")
        return
    }
    advance_token()
    if Parser.failed { return }

    for export_index := 0; export_index < export_count; export_index += 1 {
        binding_index := export_binding_indexes[export_index]
        env.flags[binding_index] += {.EXPORTED}
    }
}

// block = "{" {stmt} "}".
parse_block_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .LEFT_BRACE {
        compile_error_near(Parser.current_token, "expected '{' to start block")
        return
    }
    advance_token()
    if Parser.failed { return }

    begin_scope(proto_state)
    if Parser.failed { return }

    for !Parser.failed && Parser.current_token.kind != .RIGHT_BRACE && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if Parser.current_token.kind == .EOF {
        compile_error_near(Parser.current_token, "expected '}' to close block")
        return
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected '}' to close block")
        return
    }
    advance_token()
    if Parser.failed { return }

    end_scope(proto_state)
}

// ifStmt = "if" expr block ["else" (ifStmt | block)].
parse_if_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .IF {
        compile_error_near(Parser.current_token, "expected 'if'")
        return
    }
    advance_token()
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot

    expr := parse_expr(proto_state)
    if Parser.failed { return }

    condition_slot := expr_read_slot(proto_state, expr)
    if Parser.failed { return }

    false_jump := emit_jump_false(proto_state, condition_slot)

    // Condition is dead after the branch; reclaim its temp slots.
    proto_state.next_temp_slot = temp_save

    parse_block_stmt(proto_state)
    if Parser.failed { return }

    if Parser.current_token.kind == .ELSE {
        advance_token()
        if Parser.failed { return }

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
    if Parser.current_token.kind != .FOR {
        compile_error_near(Parser.current_token, "expected 'for'")
        return
    }
    advance_token()
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

        expr := parse_expr(proto_state)
        if Parser.failed { return }

        condition_slot := expr_read_slot(proto_state, expr)
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
    if Parser.current_token.kind != .SWITCH {
        compile_error_near(Parser.current_token, "expected 'switch'")
        return
    }
    advance_token()
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

    if Parser.current_token.kind != .LEFT_BRACE {
        compile_error_near(Parser.current_token, "expected '{' after switch subject")
        return
    }
    advance_token()
    if Parser.failed { return }

    // Empty switch bodies are valid; any other first token must start an arm.
    if Parser.current_token.kind != .CASE && Parser.current_token.kind != .ELSE && Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected 'case', 'else', or '}' in switch")
        return
    }
    end_jumps := make([dynamic]int)
    defer delete(end_jumps)

    for Parser.current_token.kind == .CASE {
        advance_token()
        if Parser.failed { return }

        case_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        case_expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_desc(proto_state, case_expr, case_slot)
        if Parser.failed { return }

        if Parser.current_token.kind != .COLON {
            compile_error_near(Parser.current_token, "expected ':' after switch case")
            return
        }
        advance_token()
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
        if Parser.failed { return }
        if Parser.current_token.kind != .COLON {
            compile_error_near(Parser.current_token, "expected ':' after switch else")
            return
        }
        advance_token()
        if Parser.failed { return }
        parse_switch_arm_body(proto_state)
        if Parser.failed { return }
        if Parser.current_token.kind == .CASE {
            compile_error(Parser.current_token, "case cannot appear after else")
            return
        }
    }

    if Parser.current_token.kind != .RIGHT_BRACE {
        compile_error_near(Parser.current_token, "expected '}' to close switch")
        return
    }
    advance_token()
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
        compile_error(Parser.current_token, "switch arm must have at least one statement")
        return
    }

    end_scope(proto_state)
}

// breakStmt = "break".
parse_break_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .BREAK {
        compile_error_near(Parser.current_token, "expected 'break'")
        return
    }
    break_token := advance_token()
    if Parser.failed { return }

    if len(proto_state.loop_break_fixup_bases) == 0 {
        compile_error(break_token, "break is only valid inside loops")
        return
    }

    break_jump := emit_jump(proto_state)
    append(&proto_state.break_jump_fixups, break_jump)
}

// returnStmt = "return" [exprList].
parse_return_stmt :: proc(proto_state: ^ProtoState) {
    if Parser.current_token.kind != .RETURN {
        compile_error_near(Parser.current_token, "expected 'return'")
        return
    }
    advance_token()
    if Parser.failed { return }

    if Parser.current_token.kind == .EOF || Parser.current_token.kind == .RIGHT_BRACE {
        emit_return(proto_state, 0, 0)
        return
    }

    base_slot := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, base_slot)
    if Parser.failed { return }

    if expr_count > MAX_FRAME_SLOTS {
        compile_error(Parser.current_token, "return has too many values")
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

    if expr_count == 1 {
        return_slot := expr_read_slot(proto_state, last_expr)
        if Parser.failed { return }

        emit_return(proto_state, return_slot, 1)
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
    if Parser.current_token.kind != .IDENT {
        compile_error_near(Parser.current_token, "expected identifier")
        return
    }
    ident_token = advance_token()
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
    if Parser.failed { return }

    lhs_count := len(lhs_tokens)

    if !proto_state.is_function && len(proto_state.scope_local_marks) == 0 {
        current_top_level_env := &Active_State.envs[proto_state.env_index]
        binding_indexes: [MAX_BINDINGS]int

        for check_index := 0; check_index < lhs_count; check_index += 1 {
            check_name := lhs_tokens[check_index].value.(string)

            for prev_index := 0; prev_index < check_index; prev_index += 1 {
                if lhs_tokens[prev_index].value.(string) == check_name {
                    compile_error(lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in top-level declaration", check_name))
                    return
                }
            }

            current_top_level_index := binding_env_find(current_top_level_env, check_name)
            if current_top_level_index >= 0 {
                compile_error(lhs_tokens[check_index], fmt.tprintf("top-level binding `%s` is already declared", check_name))
                return
            }

            import_index := import_namespace_find(proto_state, check_name)
            if import_index >= 0 {
                compile_error(lhs_tokens[check_index], fmt.tprintf("top-level binding `%s` conflicts with imported namespace", check_name))
                return
            }
        }

        if current_top_level_env.count + lhs_count > MAX_BINDINGS {
            compile_error(lhs_tokens[0], "too many top-level bindings")
            return
        }

        for target_index := 0; target_index < lhs_count; target_index += 1 {
            binding_indexes[target_index] = binding_env_append(current_top_level_env, lhs_tokens[target_index].value.(string), is_mutable)
        }

        rhs_base := proto_state.next_temp_slot

        expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
        if Parser.failed { return }

        if expr_count > lhs_count {
            compile_error(Parser.current_token, fmt.tprintf("too many values in declaration: expected %d", lhs_count))
            return
        }

        if lhs_count == 1 && expr_count == 1 {
            binding_name := lhs_tokens[0].value.(string)
            label := binding_name
            if proto_state.env_index != 0 {
                module_name := module_namespace_from_path(Active_State.envs[proto_state.env_index].id)
                label = fmt.tprintf("%s.%s", module_name, binding_name)
            }
            try_label_function(proto_state, last_expr, label)

            _, final_is_call := last_expr.(ExprCall)
            if !final_is_call {
                src_slot := expr_read_slot(proto_state, last_expr)
                if Parser.failed { return }

                emit_set_file_bind(proto_state, src_slot, binding_indexes[0])
                return
            }
        }

        finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
        if Parser.failed { return }

        for target_index := 0; target_index < lhs_count; target_index += 1 {
            emit_set_file_bind(proto_state, rhs_base + target_index, binding_indexes[target_index])
        }
        return
    }

    // Validate all declared bindings before RHS emission.
    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                compile_error(lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in local declaration", check_name))
                return
            }
        }

        scope_start := 0
        if len(proto_state.scope_local_marks) > 0 {
            scope_start = proto_state.scope_local_marks[len(proto_state.scope_local_marks) - 1]
        }

        for local_index := scope_start; local_index < proto_state.local_count; local_index += 1 {
            if proto_state.local_bindings[local_index].name == check_name {
                compile_error(lhs_tokens[check_index], fmt.tprintf("local binding `%s` is already declared in this scope", check_name))
                return
            }
        }
    }

    if proto_state.local_count + lhs_count > MAX_FRAME_SLOTS {
        compile_error(lhs_tokens[0], "too many local bindings in function")
        return
    }

    // Reserve future local slots for RHS.
    rhs_base := proto_state.local_count
    proto_state.next_temp_slot = rhs_base

    expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
    if Parser.failed { return }

    if expr_count > lhs_count {
        compile_error(Parser.current_token, fmt.tprintf("too many values in declaration: expected %d", lhs_count))
        return
    }

    if lhs_count == 1 && expr_count == 1 {
        label := lhs_tokens[0].value.(string)
        try_label_function(proto_state, last_expr, label)
    }

    finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
    if Parser.failed { return }

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
                compile_error(source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                return ExprInvalid{}
            }

            return ExprLocalBinding(local_index)
        }

        env := &Active_State.envs[proto_state.env_index]
        binding_index := binding_env_find(env, ident_text)
        if binding_index >= 0 {
            if !(.MUTABLE in env.flags[binding_index]) {
                compile_error(source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                return ExprInvalid{}
            }

            return ExprFileBinding(binding_index)
        }

        import_index := import_namespace_find(proto_state, ident_text)
        if import_index >= 0 {
            compile_error(source_token, fmt.tprintf("assignment target `%s` is an imported namespace; namespace names are not assignable", ident_text))
            return ExprInvalid{}
        }

        global_index := binding_env_find(&Active_State.global_env, ident_text)
        if global_index < 0 {
            if proto_state.is_function {
                compile_error(source_token, fmt.tprintf("assignment target `%s` is not a declared binding in this function; Kiln does not support closures or upvalues", ident_text))
            } else {
                compile_error(source_token, fmt.tprintf("assignment target `%s` is not a declared binding", ident_text))
            }
            return ExprInvalid{}
        }

        if !(.MUTABLE in Active_State.global_env.flags[global_index]) {
            compile_error(source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
            return ExprInvalid{}
        }

        return ExprGlobalBinding(global_index)

    case ExprLocalBinding, ExprFileBinding, ExprGlobalBinding, ExprIndex, ExprArrayIndexConst, ExprMapIndexConst:
        return target

    case ExprCall:
        compile_error(source_token, fmt.tprintf("call expression `%s` is not an assignment target; expected identifier or indexed expression", source_token.value.(string)))
        return ExprInvalid{}

    case ExprImportedBinding:
        env := &Active_State.envs[t.env_index]
        if !(.EXPORTED in env.flags[t.binding_index]) {
            compile_error(source_token, fmt.tprintf("module does not export binding `%s`", env.names[t.binding_index]))
            return ExprInvalid{}
        }
        if !(.MUTABLE in env.flags[t.binding_index]) {
            compile_error(source_token, fmt.tprintf("cannot assign to immutable binding `%s`", env.names[t.binding_index]))
            return ExprInvalid{}
        }

        return target
    }

    panic("assignment target resolution reached non-assignable expression descriptor")
}

set_assign_target :: proc(proto_state: ^ProtoState, src_slot: int, target: ExprDesc) {
    #partial switch t in target {
    case ExprLocalBinding:
        dst_slot := int(t)
        if dst_slot != src_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprFileBinding:
        emit_set_file_bind(proto_state, src_slot, int(t))

    case ExprImportedBinding:
        emit_set_module_bind(proto_state, src_slot, t.env_index, t.binding_index)

    case ExprGlobalBinding:
        emit_set_global_bind(proto_state, src_slot, int(t))

    case ExprIndex:
        emit_index_set(proto_state, t.container_slot, t.key_slot, src_slot)

    case ExprArrayIndexConst:
        emit_array_set_const(proto_state, t.array_slot, t.key_const, src_slot)

    case ExprMapIndexConst:
        emit_map_set_const(proto_state, t.map_slot, t.key_const, src_slot)

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
    if Parser.failed { return }

    // RHS expression-list results start after any target-resolution temps.
    rhs_base := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
    if Parser.failed { return }

    if expr_count > target_count {
        compile_error(Parser.current_token, fmt.tprintf("too many values in assignment: expected %d", target_count))
        return
    }

    if target_count == 1 && expr_count == 1 {
        has_label := false
        label := ""

        #partial switch target in targets[0] {
        case ExprLocalBinding:
            label = proto_state.local_bindings[int(target)].name
            has_label = true

        case ExprFileBinding:
            binding_name := Active_State.envs[proto_state.env_index].names[int(target)]
            if proto_state.env_index != 0 {
                module_name := module_namespace_from_path(Active_State.envs[proto_state.env_index].id)
                label = fmt.tprintf("%s.%s", module_name, binding_name)
            } else {
                label = binding_name
            }
            has_label = true

        case ExprGlobalBinding:
            label = Active_State.global_env.names[int(target)]
            has_label = true

        case ExprImportedBinding:
            env := &Active_State.envs[target.env_index]
            module_name := module_namespace_from_path(env.id)
            binding_name := env.names[target.binding_index]
            label = fmt.tprintf("%s.%s", module_name, binding_name)
            has_label = true

        case:
        }

        if has_label {
            try_label_function(proto_state, last_expr, label)
        }
    }

    // Fast path for:
    //
    //     local = single_rhs_expr
    //
    // This preserves the current assignment model while avoiding:
    //
    //     OP temp, ...
    //     MOVE local, temp
    //
    // For source like:
    //
    //     sum = sum + i
    //
    // it can rewrite the already-emitted final op from:
    //
    //     ADD temp, sum, i
    //
    // to:
    //
    //     ADD sum, sum, i
    //
    // This path is intentionally local-only. File/global/module/indexed targets
    // still need their explicit SET/INDEX_SET storage operation.
    if target_count == 1 && expr_count == 1 {
        local_target, target_is_local := targets[0].(ExprLocalBinding)
        if target_is_local {
            _, final_is_call := last_expr.(ExprCall)
            if !final_is_call {
                target_slot := int(local_target)

                lower_expr_desc(proto_state, last_expr, target_slot)
                if Parser.failed { return }

                return
            }
        }

        // Fast path for one non-local target:
        //
        //     file/global/module/indexed = single_rhs_expr
        //
        // The target is already resolved before RHS parsing, so this still preserves
        // assignment target resolution order. The write itself still happens after RHS
        // evaluation through set_assign_target.
        if !target_is_local {
            src_slot := expr_read_slot(proto_state, last_expr)
            if Parser.failed { return }

            set_assign_target(proto_state, src_slot, targets[0])
            return
        }
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
    if Parser.failed { return }

    // Read current target value into value_slot.
    // Locals are safe to mutate in-place; non-locals need a temp + writeback.
    value_slot := -1
    needs_writeback := false

    local_target, target_is_local := resolved_target.(ExprLocalBinding)
    if target_is_local {
        value_slot = int(local_target)
        needs_writeback = false
    } else {
        value_slot = claim_temp_slot(proto_state)
        if Parser.failed { return }

        lower_expr_desc(proto_state, resolved_target, value_slot)
        if Parser.failed { return }

        needs_writeback = true
    }

    rhs_expr := parse_expr(proto_state)
    if Parser.failed { return }

    rhs_const, rhs_is_const := const_index_from_numeric_literal(proto_state, rhs_expr)
    rhs_slot := -1
    if !rhs_is_const {
        rhs_slot = expr_read_slot(proto_state, rhs_expr)
        if Parser.failed { return }
    }

    #partial switch op_token.kind {
    case .PLUS_ASSIGN:
        if rhs_is_const {
            emit_add_const(proto_state, value_slot, value_slot, rhs_const)
        } else {
            emit_add(proto_state, value_slot, value_slot, rhs_slot)
        }

    case .MINUS_ASSIGN:
        if rhs_is_const {
            emit_sub_const(proto_state, value_slot, value_slot, rhs_const)
        } else {
            emit_sub(proto_state, value_slot, value_slot, rhs_slot)
        }

    case .STAR_ASSIGN:
        if rhs_is_const {
            emit_mul_const(proto_state, value_slot, value_slot, rhs_const)
        } else {
            emit_mul(proto_state, value_slot, value_slot, rhs_slot)
        }

    case .SLASH_ASSIGN:
        if rhs_is_const {
            emit_div_const(proto_state, value_slot, value_slot, rhs_const)
        } else {
            emit_div(proto_state, value_slot, value_slot, rhs_slot)
        }

    case .MOD_ASSIGN:
        if rhs_is_const {
            emit_mod_const(proto_state, value_slot, value_slot, rhs_const)
        } else {
            emit_mod(proto_state, value_slot, value_slot, rhs_slot)
        }

    case:
        panic("compound assignment reached non-compound operator")
    }

    if needs_writeback {
        set_assign_target(proto_state, value_slot, resolved_target)
        if Parser.failed { return }
    }
}

// globalDecl = "global" identList declOp exprList.
parse_global_decl_stmt :: proc(proto_state: ^ProtoState) {
    global_token := advance_token()
    if Parser.failed { return }

    lhs_tokens: [MAX_BINDINGS]Token
    binding_indexes: [MAX_BINDINGS]int
    lhs_count := 0

    for {
        if lhs_count >= MAX_BINDINGS {
            compile_error(Parser.current_token, "too many global bindings in declaration")
            return
        }

        if Parser.current_token.kind != .IDENT {
            compile_error_near(Parser.current_token, "expected identifier in global declaration")
            return
        }

        lhs_tokens[lhs_count] = advance_token()
        if Parser.failed { return }
        lhs_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
        if Parser.failed { return }
    }

    if Parser.current_token.kind == .ASSIGN {
        compile_error(Parser.current_token, "global declarations use ':=' or '::', not '='")
        return
    }

    is_mutable: bool
    if Parser.current_token.kind == .DECL {
        is_mutable = true
    } else if Parser.current_token.kind == .IMMUTABLE_DECL {
        is_mutable = false
    } else {
        compile_error_near(Parser.current_token, "expected ':=' or '::' after global binding list")
        return
    }
    advance_token()
    if Parser.failed { return }

    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                compile_error(lhs_tokens[check_index], fmt.tprintf("duplicate binding `%s` in global declaration", check_name))
                return
            }
        }

        global_index := binding_env_find(&Active_State.global_env, check_name)
        if global_index >= 0 {
            compile_error(lhs_tokens[check_index], fmt.tprintf("global binding `%s` is already declared", check_name))
            return
        }
    }

    if Active_State.global_env.count + lhs_count > MAX_BINDINGS {
        compile_error(global_token, "too many global bindings")
        return
    }

    for target_index := 0; target_index < lhs_count; target_index += 1 {
        binding_indexes[target_index] = binding_env_append(&Active_State.global_env, lhs_tokens[target_index].value.(string), is_mutable)
    }

    rhs_base := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
    if Parser.failed { return }

    if expr_count > lhs_count {
        compile_error(Parser.current_token, fmt.tprintf("too many values in global declaration: expected %d", lhs_count))
        return
    }

    if lhs_count == 1 && expr_count == 1 {
        label := lhs_tokens[0].value.(string)
        try_label_function(proto_state, last_expr, label)

        _, final_is_call := last_expr.(ExprCall)
        if !final_is_call {
            src_slot := expr_read_slot(proto_state, last_expr)
            if Parser.failed { return }

            emit_set_global_bind(proto_state, src_slot, binding_indexes[0])
            return
        }
    }

    finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
    if Parser.failed { return }

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
        compile_error(Parser.current_token, "call statement must end in a call")
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
            compile_error(Parser.current_token, "too many assignment targets")
            return
        }

        lhs_tokens[lhs_count], targets[lhs_count] = parse_simple_stmt_prefix(proto_state)
        if Parser.failed { return }
        lhs_count += 1

        if Parser.current_token.kind != .COMMA {
            break
        }

        advance_token()
        if Parser.failed { return }
    }

    // The operator after the shared target prefix determines the statement form.
    if Parser.current_token.kind == .DECL {
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            #partial switch target in targets[target_index] {
            case ExprUnresolvedBinding:
            case:
                compile_error(lhs_tokens[target_index], "declaration target must be an identifier")
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
                compile_error(lhs_tokens[target_index], "declaration target must be an identifier")
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
            compile_error(Parser.current_token, "compound assignment expects one assignment target")
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
            compile_error(lhs_tokens[0], fmt.tprintf("bare expression `%s` is not a statement; expected declaration, assignment, or call", lhs_tokens[0].value.(string)))
        case ExprIndex, ExprArrayIndexConst, ExprMapIndexConst:
            compile_error(lhs_tokens[0], fmt.tprintf("indexed expression `%s` is not a statement; expected assignment", lhs_tokens[0].value.(string)))
        case:
            compile_error(lhs_tokens[0], fmt.tprintf("expression starting with `%s` is not a statement; expected declaration, assignment, or call", lhs_tokens[0].value.(string)))
        }
        return
    }

    compile_error_near(Parser.current_token, "expected declaration or assignment after target list")
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
        compile_error(Parser.current_token, "case is only valid inside switch")
        return
    }
    if Parser.current_token.kind == .ELSE {
        compile_error(Parser.current_token, "else is only valid after if or inside switch")
        return
    }

    if Parser.current_token.kind == .GLOBAL {
        parse_global_decl_stmt(proto_state)
        return
    }

    if Parser.current_token.kind == .IMPORT {
        compile_error(Parser.current_token, "import statements must appear before other top-level statements")
        return
    }

    if Parser.current_token.kind == .EXPORT {
        compile_error(Parser.current_token, "export is only valid as final top-level module statement")
        return
    }

    if Parser.current_token.kind == .IDENT || Parser.current_token.kind == .FUNCTION || Parser.current_token.kind == .LEFT_BRACKET || Parser.current_token.kind == .MAP {
        parse_simple_stmt(proto_state)
        return
    }

    token := Parser.current_token
    compile_error_near(token, fmt.tprintf("expected statement, got `%s`", current_token_text()))
}

// sourceFile = {importStmt} fileBody [exportStmt].
// Top-level statement temps die at statement end.
parse_top_level_statements :: proc(proto_state: ^ProtoState, allow_export: bool) {
    for !Parser.failed && Parser.current_token.kind == .IMPORT {
        parse_import_stmt(proto_state)
        if Parser.failed { return }
    }

    for !Parser.failed && Parser.current_token.kind != .EOF {
        if Parser.current_token.kind == .EXPORT {
            parse_export_stmt(proto_state, allow_export)
            if Parser.failed { return }

            if Parser.current_token.kind != .EOF {
                compile_error(Parser.current_token, "export must be final top-level statement")
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
compile_source :: proc(source, source_name: string) -> string {
    Active_State.envs[0].id = strings.clone(source_name)
    Active_State.envs[0].count = 0

    // Push entry env onto the loading stack for cycle detection.
    Active_State.loading_env_indexes[Active_State.loading_env_count] = 0
    Active_State.loading_env_count += 1

    begin_scan(source, source_name)

    Parser.current_token = Token{}
    Parser.failed = false

    advance_token()
    if Parser.failed {
        return Active_State.error_string
    }

    entry_proto_state := begin_proto(source_name, 1, "entry", 0, false, 0)
    parse_top_level_statements(&entry_proto_state, false)
    if Parser.failed {
        delete_proto_state(&entry_proto_state)
        return Active_State.error_string
    }

    // Source fallthrough is defined as implicit `return nil`.
    // This keeps entry completion on the same RETURN path as explicit source returns.
    return_slot := claim_temp_slot(&entry_proto_state)
    if Parser.failed {
        delete_proto_state(&entry_proto_state)
        return Active_State.error_string
    }
    emit_load_nil(&entry_proto_state, return_slot)
    emit_return(&entry_proto_state, return_slot, 1)

    Active_State.entry_proto = end_proto(&entry_proto_state)
    Active_State.loading_env_count -= 1
    return ""
}

// On success returns a runnable module proto.
compile_imported_source :: proc(source, source_name: string, env_index: int) -> (module_proto: ^Proto, err: string) {
    begin_scan(source, source_name)

    Parser.current_token = Token{}
    Parser.failed = false

    advance_token()
    if Parser.failed {
        return nil, Active_State.error_string
    }

    module_label := module_namespace_from_path(Active_State.envs[env_index].id)
    module_proto_state := begin_proto(source_name, 1, module_label, 0, false, env_index)

    parse_top_level_statements(&module_proto_state, true)
    if Parser.failed {
        delete_proto_state(&module_proto_state)
        return nil, Active_State.error_string
    }

    // Module fallthrough is defined as implicit `return nil`.
    return_slot := claim_temp_slot(&module_proto_state)
    if Parser.failed {
        delete_proto_state(&module_proto_state)
        return nil, Active_State.error_string
    }
    emit_load_nil(&module_proto_state, return_slot)
    emit_return(&module_proto_state, return_slot, 1)

    module_proto = end_proto(&module_proto_state)
    return module_proto, ""
}
