package kiln

import "core:fmt"

// Parser state ===================================================================================
// Token cursor and failure latch for one compile operation.

Parser := struct {
    current:       Token,
    lookahead:     Token,
    has_lookahead: bool,
    failed:        bool, // global error latch — every mutating operation sets it, callers check and return immediately
}{}


// ExprDesc types ==================================================================================
// Expression descriptors decouple parsing from slot emission.
// parse_expr returns an ExprDesc; surrounding context emits or adjusts it.

ExprInvalid :: struct {}
ExprNil     :: struct {}

ExprBool :: struct {
    value: bool,
}

ExprInt :: struct {
    value: i64,
}

ExprFloat :: struct {
    value: f64,
}

ExprString :: struct {
    value: string,
}

ExprLocal :: struct {
    local_index: int,
}

ExprGlobal :: struct {
    binding_id: BindingId,
}

ExprSlot :: struct {
    slot: int,
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
    ExprBool,
    ExprInt,
    ExprFloat,
    ExprString,
    ExprLocal,
    ExprGlobal,
    ExprSlot,
    ExprCall,
    ExprIndex,
}

// Token cursor ===================================================================================

current_token :: proc() -> Token {
    return Parser.current
}

peek_token :: proc() -> Token {
    if !Parser.has_lookahead {
        Parser.lookahead = scan_next_token()
        Parser.has_lookahead = true

        if Parser.lookahead.kind == .ERROR {
            error_token_to_parser_error(Parser.lookahead)
        }
    }

    return Parser.lookahead
}

at_token :: proc(kind: TokenKind) -> bool {
    return current_token().kind == kind
}

advance_token :: proc() -> Token {
    token := Parser.current

    if Parser.has_lookahead {
        Parser.current = Parser.lookahead
        Parser.lookahead = Token{}
        Parser.has_lookahead = false
    } else {
        Parser.current = scan_next_token()
    }

    if Parser.current.kind == .ERROR {
        error_token_to_parser_error(Parser.current)
    }

    return token
}


// Parser errors ==================================================================================

token_text_for_error :: proc(token: Token) -> string {
    if token.kind == .EOF {
        return "end of file"
    }
    return token.source_text
}

// Covers grammar errors and codegen limits found while the parser drives bytecode generation.
parser_error :: proc(proto_state: ^ProtoState, token: Token, message: string) {
    set_error(SourceLocation{
        source_name = proto_state.origin.source_name,
        line        = token.line,
        column      = token.column,
    }, message)
    Parser.failed = true
}

// Converts a scanner ERROR token into a Kiln Error. Owns the full invariant:
// ERROR token -> host-facing error + Parser.failed. Idempotent.
error_token_to_parser_error :: proc(token: Token) {
    if Parser.failed { return }

    message := token.value.(string)
    set_error(SourceLocation{
        source_name = Scanner.source_name,
        line        = token.line,
        column      = token.column,
    }, message)

    Parser.failed = true
}

// On mismatch records an error and returns zero token value.
consume_token :: proc(proto_state: ^ProtoState, kind: TokenKind, message: string) -> Token {
    if at_token(kind) {
        return advance_token()
    }

    token := current_token()
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
        parser_error(proto_state, current_token(), "function uses too many values")
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
        parser_error(proto_state, current_token(), "function uses too many values")
        return
    }

    if proto_state.next_temp_slot < slot_after_last {
        proto_state.next_temp_slot = slot_after_last
    }
}

// Records the local-count mark so end_scope can discard this scope's locals.
begin_scope :: proc(proto_state: ^ProtoState) {
    if proto_state.scope_depth >= MAX_FRAME_SLOTS {
        parser_error(proto_state, current_token(), "too many nested scopes")
        return
    }

    proto_state.scope_local_counts[proto_state.scope_depth] = proto_state.local_count
    proto_state.scope_depth += 1
}

// Restores the saved local-count mark, discarding locals declared in this scope.
end_scope :: proc(proto_state: ^ProtoState) {
    proto_state.scope_depth -= 1
    proto_state.local_count = proto_state.scope_local_counts[proto_state.scope_depth]
    proto_state.next_temp_slot = proto_state.local_count
}

// add_local_binding commits a name to the next local frame slot.
// Caller must have already validated: no duplicate in scope, capacity available.
add_local_binding :: proc(proto_state: ^ProtoState, name: string) -> int {
    slot := proto_state.local_count
    proto_state.local_bindings[slot] = LocalBinding{
        name       = name,
        frame_slot = slot,
    }
    proto_state.local_count += 1
    proto_state.next_temp_slot = proto_state.local_count
    return slot
}

// Reverse scan returns the index of the most recently declared matching local, or -1 if not found.
resolve_local_index :: proc(proto_state: ^ProtoState, ident_name: string) -> int {
    for idx := proto_state.local_count - 1; idx >= 0; idx -= 1 {
        if proto_state.local_bindings[idx].name == ident_name {
            return idx
        }
    }
    return -1
}


// ExprDesc lowering =======================================================================
// These translate descriptors into concrete bytecode.

// lower_expr_to_slot lowers an expression descriptor so that the value lands
// in dst_slot at runtime.
lower_expr_to_slot :: proc(proto_state: ^ProtoState, expr: ExprDesc, dst_slot: int) {
    switch e in expr {
    case ExprInvalid:
        return

    case ExprNil:
        emit_load_nil(proto_state, dst_slot)

    case ExprBool:
        if e.value {
            emit_load_true(proto_state, dst_slot)
        } else {
            emit_load_false(proto_state, dst_slot)
        }

    case ExprInt:
        const_index := const_int(proto_state, e.value)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case ExprFloat:
        const_index := const_float(proto_state, e.value)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case ExprString:
        const_index := const_string(proto_state, e.value)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case ExprLocal:
        src_slot := proto_state.local_bindings[e.local_index].frame_slot
        if src_slot != dst_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprGlobal:
        emit_get_global(proto_state, dst_slot, e.binding_id)

    case ExprSlot:
        if e.slot != dst_slot {
            emit_move(proto_state, dst_slot, e.slot)
        }

    case ExprCall:
        set_call_requested_results(proto_state, e.call_index, 1)
        if Parser.failed { return }
        if e.base_slot != dst_slot {
            emit_move(proto_state, dst_slot, e.base_slot)
        }

    case ExprIndex:
        emit_index_get(proto_state, dst_slot, e.container_slot, e.key_slot)
    }
}

// lower_slot_to_assignment_target writes the value in src_slot into an assignable
// expression descriptor.
lower_slot_to_assignment_target :: proc(proto_state: ^ProtoState, src_slot: int, target: ExprDesc) {
    #partial switch t in target {
    case ExprLocal:
        dst_slot := proto_state.local_bindings[t.local_index].frame_slot
        if dst_slot != src_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprIndex:
        emit_index_set(proto_state, t.container_slot, t.key_slot, src_slot)

    case:
        parser_error(proto_state, current_token(), "expected assignment target")
    }
}


// Function literals ==============================================================================

// Function bodies consume braces but do not create an extra root scope.
// Parameters and top-level body locals live together in the function's root scope.
// Blocks inside the body still create scopes through normal statement parsing.
parse_function_body :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start function body")
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if at_token(.EOF) {
        parser_error(proto_state, current_token(), "expected '}' to close function body")
        return
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close function body")
}

// The compiled child proto is stored on the parent and loaded by LOAD_FUNC at runtime.
parse_function_literal :: proc(parent_proto_state: ^ProtoState, dst: int, function_name: string, origin_token: Token) {
    consume_token(parent_proto_state, .FUNCTION, "expected 'function'")
    if Parser.failed { return }

    consume_token(parent_proto_state, .LEFT_PAREN, "expected '(' after function")
    if Parser.failed { return }

    // Parse parameters first while still compiling the parent.
    // The child proto is not created until the function signature is known.
    param_tokens: [MAX_FRAME_SLOTS]Token
    param_count := 0
    if !at_token(.RIGHT_PAREN) {
        for {
            if param_count >= MAX_FRAME_SLOTS {
                parser_error(parent_proto_state, current_token(), "too many function parameters")
                return
            }

            param_tokens[param_count] = consume_token(parent_proto_state, .IDENT, "expected parameter name")
            if Parser.failed {
                return
            }
            param_count += 1

            if !at_token(.COMMA) {
                break
            }

            advance_token()
            if at_token(.RIGHT_PAREN) {
                break
            }
        }
    }

    consume_token(parent_proto_state, .RIGHT_PAREN, "expected ')' after function parameters")
    if Parser.failed { return }

    // Build a fresh proto state for the function body.
    // Parent proto state stays alive so the finished child can be appended to it.
    child_origin := SourceLocation{
        source_name = parent_proto_state.origin.source_name,
        line        = origin_token.line,
        column      = origin_token.column,
    }
    child_proto_state := begin_proto(child_origin, function_name, param_count)

    // Parameters are local slots starting at slot 0.
    // The VM call path places arguments directly into those slots.
    for param_index := 0; param_index < param_count; param_index += 1 {
        param_name := param_tokens[param_index].value.(string)

        for prev_index := 0; prev_index < param_index; prev_index += 1 {
            if param_tokens[prev_index].value.(string) == param_name {
                parser_error(
                    &child_proto_state,
                    param_tokens[param_index],
                    fmt.tprintf("parameter `%s` is already declared in this function", param_name),
                )
                delete_proto_state(&child_proto_state)
                return
            }
        }

        add_local_binding(&child_proto_state, param_name)
    }

    parse_function_body(&child_proto_state)
    if Parser.failed {
        delete_proto_state(&child_proto_state)
        return
    }

    // A function that reaches the closing brace returns nil.
    return_slot := claim_temp_slot(&child_proto_state)
    if Parser.failed {
        delete_proto_state(&child_proto_state)
        return
    }
    emit_load_nil(&child_proto_state, return_slot)
    emit_return(&child_proto_state, return_slot, 1)

    // Store the compiled child proto on the parent, then emit LOAD_FUNC.
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


// Expression parsers ==============================================================================
// Each returns an ExprDesc. No slot destination is passed in.

resolve_ident_expr :: proc(proto_state: ^ProtoState, token: Token) -> ExprDesc {
    ident_name := token.value.(string)
    local_index := resolve_local_index(proto_state, ident_name)
    if local_index >= 0 {
        return ExprLocal{local_index}
    }

    binding_id, found_global := resolve_global(ident_name)
    if !found_global {
        parser_error(proto_state, token, fmt.tprintf("unknown name `%s`", ident_name))
        return ExprInvalid{}
    }

    return ExprGlobal{binding_id}
}

parse_basic_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    token := advance_token()

    #partial switch token.kind {
    case .INT:
        return ExprInt{token.value.(i64)}
    case .FLOAT:
        return ExprFloat{token.value.(f64)}
    case .STRING:
        return ExprString{token.value.(string)}
    case .TRUE:
        return ExprBool{true}
    case .FALSE:
        return ExprBool{false}
    case .NIL:
        return ExprNil{}
    case:
        parser_error(proto_state, token, fmt.tprintf("expected literal, got `%s`", token_text_for_error(token)))
        return ExprInvalid{}
    }
}

parse_array_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .LEFT_BRACKET, "expected '[' to start array literal")
    if Parser.failed { return ExprInvalid{} }

    array_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    emit_new_array(proto_state, array_slot, 0)
    reserve_slots_until(proto_state, array_slot + 1)
    if Parser.failed { return ExprInvalid{} }

    if !at_token(.RIGHT_BRACKET) {
        for {
            value_slot := claim_temp_slot(proto_state)
            if Parser.failed { return ExprInvalid{} }

            value_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            lower_expr_to_slot(proto_state, value_expr, value_slot)
            if Parser.failed { return ExprInvalid{} }

            emit_array_push(proto_state, array_slot, value_slot)
            proto_state.next_temp_slot = array_slot + 1

            if !at_token(.COMMA) {
                break
            }

            advance_token()
            if at_token(.RIGHT_BRACKET) {
                break
            }
        }
    }

    consume_token(proto_state, .RIGHT_BRACKET, "expected ']' after array literal")
    if Parser.failed { return ExprInvalid{} }

    return ExprSlot{array_slot}
}

parse_grouped_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .LEFT_PAREN, "expected '(' to start grouped expression")
    if Parser.failed { return ExprInvalid{} }

    expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    consume_token(proto_state, .RIGHT_PAREN, "expected ')' after grouped expression")
    if Parser.failed { return ExprInvalid{} }

    if at_token(.LEFT_PAREN) || at_token(.LEFT_BRACKET) || at_token(.DOT) {
        parser_error(proto_state, current_token(), "grouped expression cannot be used as a chain root")
        return ExprInvalid{}
    }

    return expr
}

parse_root_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if at_token(.IDENT) {
        token := advance_token()
        return resolve_ident_expr(proto_state, token)
    }

    if at_token(.FUNCTION) {
        slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        parse_function_literal(proto_state, slot, "<function>", current_token())
        if Parser.failed { return ExprInvalid{} }
        return ExprSlot{slot}
    }

    if at_token(.LEFT_BRACKET) {
        return parse_array_literal(proto_state)
    }

    if at_token(.MAP) {
        parser_error(proto_state, current_token(), "map literals are not implemented yet")
        return ExprInvalid{}
    }

    token := current_token()
    parser_error(proto_state, token, fmt.tprintf("expected chain expression, got `%s`", token_text_for_error(token)))
    return ExprInvalid{}
}

// Layout: callee_slot, arg0, arg1, ...
// Arguments are single-valued (no call expansion in call args).
parse_call_postfix :: proc(proto_state: ^ProtoState, callee: ExprDesc) -> ExprDesc {
    consume_token(proto_state, .LEFT_PAREN, "expected '(' to start call arguments")
    if Parser.failed { return ExprInvalid{} }

    base_slot: int
    slot_expr, callee_is_slot := callee.(ExprSlot)
    if callee_is_slot {
        base_slot = slot_expr.slot
        reserve_slots_until(proto_state, base_slot + 1)
        if Parser.failed { return ExprInvalid{} }
    } else {
        base_slot = claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_to_slot(proto_state, callee, base_slot)
        if Parser.failed { return ExprInvalid{} }
    }

    arg_count := 0
    if !at_token(.RIGHT_PAREN) {
        for {
            arg_slot := base_slot + 1 + arg_count
            if arg_slot >= MAX_FRAME_SLOTS {
                parser_error(proto_state, current_token(), "call uses too many values")
                return ExprInvalid{}
            }

            arg_expr := parse_expr(proto_state)
            if Parser.failed { return ExprInvalid{} }

            lower_expr_to_slot(proto_state, arg_expr, arg_slot)
            if Parser.failed { return ExprInvalid{} }

            reserve_slots_until(proto_state, arg_slot + 1)
            if Parser.failed { return ExprInvalid{} }

            arg_count += 1

            if !at_token(.COMMA) {
                break
            }

            advance_token()
            if at_token(.RIGHT_PAREN) {
                break
            }
        }
    }

    consume_token(proto_state, .RIGHT_PAREN, "expected ')' after call arguments")
    if Parser.failed { return ExprInvalid{} }

    call_index := emit_call(proto_state, base_slot, arg_count, 1)
    return ExprCall{base_slot, call_index}
}

parse_index_postfix :: proc(proto_state: ^ProtoState, container: ExprDesc) -> ExprDesc {
    consume_token(proto_state, .LEFT_BRACKET, "expected '[' to start index expression")
    if Parser.failed { return ExprInvalid{} }

    container_slot: int
    slot_expr, container_is_slot := container.(ExprSlot)
    if container_is_slot {
        container_slot = slot_expr.slot
        reserve_slots_until(proto_state, container_slot + 1)
        if Parser.failed { return ExprInvalid{} }
    } else {
        container_slot = claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_to_slot(proto_state, container, container_slot)
        if Parser.failed { return ExprInvalid{} }
    }

    key_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    key_expr := parse_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    lower_expr_to_slot(proto_state, key_expr, key_slot)
    if Parser.failed { return ExprInvalid{} }

    consume_token(proto_state, .RIGHT_BRACKET, "expected ']' after index expression")
    if Parser.failed { return ExprInvalid{} }

    return ExprIndex{container_slot, key_slot}
}

parse_chain_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    expr := parse_root_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    for {
        if at_token(.LEFT_PAREN) {
            expr = parse_call_postfix(proto_state, expr)
            if Parser.failed { return ExprInvalid{} }
            continue
        }

        if at_token(.LEFT_BRACKET) {
            expr = parse_index_postfix(proto_state, expr)
            if Parser.failed { return ExprInvalid{} }
            continue
        }

        if at_token(.DOT) {
            parser_error(proto_state, current_token(), "field access is not implemented yet")
            return ExprInvalid{}
        }

        break
    }

    return expr
}

parse_primary_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    #partial switch current_token().kind {
    case .INT, .FLOAT, .STRING, .TRUE, .FALSE, .NIL:
        return parse_basic_literal(proto_state)
    case .LEFT_PAREN:
        return parse_grouped_expr(proto_state)
    case .IDENT, .FUNCTION, .LEFT_BRACKET, .MAP:
        return parse_chain_expr(proto_state)
    case:
        token := current_token()
        parser_error(proto_state, token, fmt.tprintf("expected expression, got `%s`", token_text_for_error(token)))
        return ExprInvalid{}
    }
}

parse_unary_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    if at_token(.NOT) {
        advance_token()

        operand := parse_unary_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        operand_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_to_slot(proto_state, operand, operand_slot)
        if Parser.failed { return ExprInvalid{} }

        result_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        emit_not(proto_state, result_slot, operand_slot)
        return ExprSlot{result_slot}
    }

    return parse_primary_expr(proto_state)
}

// Operator precedence parsing is not in this stage yet.
parse_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    return parse_unary_expr(proto_state)
}


// Expression lists ================================================================================

// Parses: expr { "," expr }
//
// Every expression before the final one is emitted as one value,
// starting at base_slot. The final expression is returned as ExprDesc
// so the caller can expand a final call or materialize it normally.
//
// Invariant: base_slot must equal proto_state.next_temp_slot at entry.
parse_expr_list :: proc(proto_state: ^ProtoState, base_slot: int) -> (expr_count: int, last_expr: ExprDesc) {
    expr_count = 1
    last_expr = parse_expr(proto_state)
    if Parser.failed { return }

    for at_token(.COMMA) {
        dst_slot := base_slot + expr_count - 1

        reserve_slots_until(proto_state, dst_slot + 1)
        if Parser.failed { return }

        lower_expr_to_slot(proto_state, last_expr, dst_slot)
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
finish_expr_list_to_slots :: proc(
    proto_state: ^ProtoState,
    base_slot: int,
    expr_count: int,
    last_expr: ExprDesc,
    wanted_count: int,
) {
    previous_count := expr_count - 1
    last_dst := base_slot + previous_count
    wanted_from_last := wanted_count - previous_count

    if wanted_from_last <= 0 {
        return
    }

    reserve_slots_until(proto_state, base_slot + wanted_count)
    if Parser.failed { return }

    #partial switch e in last_expr {
    case ExprCall:
        if e.base_slot != last_dst {
            parser_error(proto_state, current_token(), "internal error: call result base does not match expression-list destination")
            return
        }

        set_call_requested_results(proto_state, e.call_index, wanted_from_last)
        if Parser.failed { return }

        if wanted_from_last > 1 {
            record_slots(proto_state, last_dst + wanted_from_last - 1)
        }

    case:
        lower_expr_to_slot(proto_state, last_expr, last_dst)
        if Parser.failed { return }

        for fill_index := previous_count + 1; fill_index < wanted_count; fill_index += 1 {
            emit_load_nil(proto_state, base_slot + fill_index)
        }
    }
}


// Statements =====================================================================================

// Parses a braced block { ... } with a new lexical scope.
parse_block_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start block")
    if Parser.failed { return }

    begin_scope(proto_state)
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }

    if at_token(.EOF) {
        parser_error(proto_state, current_token(), "expected '}' to close block")
        return
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close block")
    if Parser.failed { return }

    end_scope(proto_state)
}

// if <expression> { <statements> } [else if ...] [else { <statements> }]
parse_if_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .IF, "expected 'if'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    condition_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    expr := parse_expr(proto_state)
    if Parser.failed { return }

    lower_expr_to_slot(proto_state, expr, condition_slot)
    if Parser.failed { return }

    false_jump := emit_jump_false(proto_state, condition_slot)
    proto_state.next_temp_slot = temp_save
    parse_block_stmt(proto_state)
    if Parser.failed { return }

    if at_token(.ELSE) {
        advance_token()

        end_jump := emit_jump(proto_state)
        patch_jump(proto_state, false_jump)
        if Parser.failed { return }

        if at_token(.IF) {
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

// Condition form evaluates each iteration.
// Braced form is infinite-loop sugar with no condition-exit jump.
parse_for_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .FOR, "expected 'for'")
    if Parser.failed { return }

    if proto_state.loop_depth >= MAX_LOOP_DEPTH {
        parser_error(proto_state, current_token(), "too many nested loops")
        return
    }
    proto_state.loop_break_fixup_base[proto_state.loop_depth] = proto_state.break_fixup_count
    proto_state.loop_depth += 1

    loop_start := next_inst_index(proto_state)
    has_exit_jump := false
    exit_jump := 0

    // `for { ... }` has no condition expression.
    // It loops until `break`, `return`, or runtime termination.
    if !at_token(.LEFT_BRACE) {
        temp_save := proto_state.next_temp_slot
        condition_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_to_slot(proto_state, expr, condition_slot)
        if Parser.failed { return }

        exit_jump = emit_jump_false(proto_state, condition_slot)
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

    proto_state.loop_depth -= 1
    break_fixup_base := proto_state.loop_break_fixup_base[proto_state.loop_depth]
    for fixup_index := break_fixup_base; fixup_index < proto_state.break_fixup_count; fixup_index += 1 {
        patch_jump(proto_state, proto_state.break_fixups[fixup_index])
        if Parser.failed { return }
    }
    proto_state.break_fixup_count = break_fixup_base
}

// Switch parsing ==================================================================================

// Subject or subjectless statement switch. Subject evaluated once. No fallthrough.
parse_switch_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .SWITCH, "expected 'switch'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    subject_slot := -1
    subject_live_cursor := temp_save

    // Subject switch: evaluate subject expression into a temp slot.
    if !at_token(.LEFT_BRACE) {
        subject_slot = claim_temp_slot(proto_state)
        if Parser.failed { return }

        subject_expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_to_slot(proto_state, subject_expr, subject_slot)
        if Parser.failed { return }

        subject_live_cursor = subject_slot + 1
        proto_state.next_temp_slot = subject_live_cursor
    }

    consume_token(proto_state, .LEFT_BRACE, "expected '{' after switch subject")
    if Parser.failed { return }

    // Reject empty switch body and unexpected tokens.
    if !at_token(.CASE) && !at_token(.ELSE) && !at_token(.RIGHT_BRACE) {
        parser_error(proto_state, current_token(), "expected 'case', 'else', or '}' in switch")
        return
    }
    if at_token(.RIGHT_BRACE) {
        parser_error(proto_state, current_token(), "switch body must have at least one arm")
        return
    }

    end_jumps: [256]int
    end_jump_count := 0

    for at_token(.CASE) {
        advance_token()

        // Compile the case expression.
        case_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        case_expr := parse_expr(proto_state)
        if Parser.failed { return }

        lower_expr_to_slot(proto_state, case_expr, case_slot)
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
        if Parser.failed { return }

        parse_switch_arm_body(proto_state)
        if Parser.failed { return }

        if end_jump_count >= len(end_jumps) {
            parser_error(proto_state, current_token(), "switch has too many arms")
            return
        }
        end_jumps[end_jump_count] = emit_jump(proto_state)
        end_jump_count += 1
        if Parser.failed { return }

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

    if at_token(.ELSE) {
        advance_token()
        consume_token(proto_state, .COLON, "expected ':' after switch else")
        if Parser.failed { return }
        parse_switch_arm_body(proto_state)
        if Parser.failed { return }
        if at_token(.CASE) {
            parser_error(proto_state, current_token(), "case cannot appear after else")
            return
        }
    }

    consume_token(proto_state, .RIGHT_BRACE, "expected '}' to close switch")
    if Parser.failed { return }

    for i in 0 ..< end_jump_count {
        patch_jump(proto_state, end_jumps[i])
        if Parser.failed { return }
    }

    proto_state.next_temp_slot = temp_save
}

// Parses a switch arm body as a scoped statement list terminated by case/else/}/EOF.
parse_switch_arm_body :: proc(proto_state: ^ProtoState) {
    begin_scope(proto_state)
    if Parser.failed { return }

    statement_count := 0
    for !at_token(.CASE) && !at_token(.ELSE) && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
        statement_count += 1
    }

    if statement_count == 0 {
        end_scope(proto_state)
        parser_error(proto_state, current_token(), "switch arm must have at least one statement")
        return
    }

    end_scope(proto_state)
}

// Only valid inside loop bodies.
parse_break_stmt :: proc(proto_state: ^ProtoState) {
    break_token := consume_token(proto_state, .BREAK, "expected 'break'")
    if Parser.failed { return }

    if proto_state.loop_depth == 0 {
        parser_error(proto_state, break_token, "break is only valid inside loops")
        return
    }

    if proto_state.break_fixup_count >= MAX_BREAK_FIXUPS {
        parser_error(proto_state, break_token, "function has too many break statements")
        return
    }

    break_jump := emit_jump(proto_state)
    proto_state.break_fixups[proto_state.break_fixup_count] = break_jump
    proto_state.break_fixup_count += 1
}

// return, return expr, or return a, b, c. Each value expression is lowered as a single-result expression.
// No return-call forwarding: return f() returns exactly one value (the first result of f()).
parse_return_stmt :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .RETURN, "expected 'return'")
    if Parser.failed { return }

    if at_token(.EOF) || at_token(.RIGHT_BRACE) {
        emit_return(proto_state, 0, 0)
        return
    }

    base_slot := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, base_slot)
    if Parser.failed { return }

    if expr_count > MAX_FRAME_SLOTS {
        parser_error(proto_state, current_token(), "return has too many values")
        return
    }

    finish_expr_list_to_slots(proto_state, base_slot, expr_count, last_expr, expr_count)
    if Parser.failed { return }

    emit_return(proto_state, base_slot, expr_count)
}

// Simple statements ==============================================================================
// simpleStmt = declStmt | assignStmt | compoundAssignStmt | callStmt.
// Identifier-started simple statements share a comma-separated prefix before
// the parser knows whether :=, =, or a call statement follows.

// Parses one identifier-rooted prefix from a simple statement.
// Bare identifiers stay unresolved until := or = decides declaration vs assignment.
parse_simple_stmt_prefix :: proc(proto_state: ^ProtoState) -> (
    ident_token: Token,
    expr: ExprDesc,
    plain_ident: bool,
) {
    ident_token = consume_token(proto_state, .IDENT, "expected identifier")
    if Parser.failed { return }

    plain_ident = true

    if !at_token(.LEFT_PAREN) && !at_token(.LEFT_BRACKET) && !at_token(.DOT) {
        return
    }

    plain_ident = false
    expr = resolve_ident_expr(proto_state, ident_token)
    if Parser.failed { return }

    for {
        if at_token(.LEFT_PAREN) {
            expr = parse_call_postfix(proto_state, expr)
            if Parser.failed { return }
            continue
        }

        if at_token(.LEFT_BRACKET) {
            expr = parse_index_postfix(proto_state, expr)
            if Parser.failed { return }
            continue
        }

        if at_token(.DOT) {
            parser_error(proto_state, current_token(), "field access is not implemented yet")
            return
        }

        break
    }

    return
}

finish_decl_stmt :: proc(proto_state: ^ProtoState, lhs_tokens: []Token) {
    advance_token()

    lhs_count := len(lhs_tokens)

    // Validate all declaration names before RHS emission.
    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                parser_error(
                    proto_state,
                    lhs_tokens[check_index],
                    fmt.tprintf("duplicate declaration name `%s`", check_name),
                )
                return
            }
        }

        scope_start := 0
        if proto_state.scope_depth > 0 {
            scope_start = proto_state.scope_local_counts[proto_state.scope_depth - 1]
        }

        for local_index := scope_start; local_index < proto_state.local_count; local_index += 1 {
            if proto_state.local_bindings[local_index].name == check_name {
                parser_error(
                    proto_state,
                    lhs_tokens[check_index],
                    fmt.tprintf("local variable `%s` is already declared in this scope", check_name),
                )
                return
            }
        }
    }

    if proto_state.local_count + lhs_count > MAX_FRAME_SLOTS {
        parser_error(proto_state, lhs_tokens[0], "too many local variables in function")
        return
    }

    // Reserve future local slots for RHS.
    rhs_base := proto_state.local_count
    proto_state.next_temp_slot = rhs_base

    if lhs_count == 1 && at_token(.FUNCTION) {
        ident_text := lhs_tokens[0].value.(string)
        parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
        if Parser.failed { return }
    } else {
        expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
        if Parser.failed { return }

        if expr_count > lhs_count {
            parser_error(
                proto_state,
                current_token(),
                fmt.tprintf("too many values in declaration: expected %d", lhs_count),
            )
            return
        }

        finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
        if Parser.failed { return }
    }

    // Commit names to the slots that already hold the RHS values.
    for target_index := 0; target_index < lhs_count; target_index += 1 {
        add_local_binding(proto_state, lhs_tokens[target_index].value.(string))
    }
}

finish_assign_stmt :: proc(
    proto_state: ^ProtoState,
    lhs_tokens: []Token,
    targets: []ExprDesc,
    is_plain_ident: []bool,
) {
    target_count := len(targets)

    for target_index := 0; target_index < target_count; target_index += 1 {
        if is_plain_ident[target_index] {
            ident_text := lhs_tokens[target_index].value.(string)

            local_index := resolve_local_index(proto_state, ident_text)
            if local_index < 0 {
                parser_error(
                    proto_state,
                    lhs_tokens[target_index],
                    fmt.tprintf("assignment target `%s` is not a local variable", ident_text),
                )
                return
            }

            targets[target_index] = ExprLocal{local_index}
            continue
        }

        #partial switch target in targets[target_index] {
        case ExprIndex:
        case:
            parser_error(proto_state, lhs_tokens[target_index], "expected assignment target")
            return
        }
    }

    advance_token()

    // RHS expression-list results start after any target-resolution temps.
    rhs_base := proto_state.next_temp_slot

    expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
    if Parser.failed { return }

    if expr_count > target_count {
        parser_error(
            proto_state,
            current_token(),
            fmt.tprintf("too many values in assignment: expected %d", target_count),
        )
        return
    }

    finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, target_count)
    if Parser.failed { return }

    // Write temps into targets after all RHS values are ready.
    for target_index := 0; target_index < target_count; target_index += 1 {
        lower_slot_to_assignment_target(proto_state, rhs_base + target_index, targets[target_index])
        if Parser.failed { return }
    }
}

parse_call_stmt :: proc(proto_state: ^ProtoState) {
    expr := parse_chain_expr(proto_state)
    if Parser.failed { return }

    call_expr, is_call := expr.(ExprCall)
    if !is_call {
        parser_error(proto_state, current_token(), "call statement must end in a call")
        return
    }

    set_call_requested_results(proto_state, call_expr.call_index, 0)
}

parse_simple_stmt :: proc(proto_state: ^ProtoState) {
    if !at_token(.IDENT) {
        parse_call_stmt(proto_state)
        return
    }

    // These arrays are one local table: index i describes the same comma-separated
    // prefix entry in all three arrays. plain_ident delays name resolution until
    // the parser knows whether this is a declaration or assignment.
    lhs_tokens: [MAX_FRAME_SLOTS]Token
    targets: [MAX_FRAME_SLOTS]ExprDesc
    plain_ident: [MAX_FRAME_SLOTS]bool
    lhs_count := 0

    for {
        if lhs_count >= MAX_FRAME_SLOTS {
            parser_error(proto_state, current_token(), "too many assignment targets")
            return
        }

        lhs_tokens[lhs_count], targets[lhs_count], plain_ident[lhs_count] = parse_simple_stmt_prefix(proto_state)
        if Parser.failed { return }
        lhs_count += 1

        if !at_token(.COMMA) {
            break
        }

        advance_token()
    }

    if at_token(.DECL) {
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            if !plain_ident[target_index] {
                parser_error(proto_state, lhs_tokens[target_index], "declaration target must be an identifier")
                return
            }
        }

        finish_decl_stmt(proto_state, lhs_tokens[:lhs_count])
        return
    }

    if at_token(.CONST_DECL) {
        parser_error(proto_state, current_token(), "const declarations are not implemented yet")
        return
    }

    if at_token(.ASSIGN) {
        finish_assign_stmt(proto_state, lhs_tokens[:lhs_count], targets[:lhs_count], plain_ident[:lhs_count])
        return
    }

    if lhs_count == 1 {
        call_expr, is_call := targets[0].(ExprCall)
        if is_call {
            set_call_requested_results(proto_state, call_expr.call_index, 0)
            return
        }

        parser_error(
            proto_state,
            lhs_tokens[0],
            fmt.tprintf("expression starting with `%s` is not a statement; expected declaration, assignment, or call", lhs_tokens[0].value.(string)),
        )
        return
    }

    parser_error(proto_state, current_token(), "expected declaration or assignment after target list")
}

// Supported forms: block, if/for/break/return/switch, decl, assign, call.
parse_stmt :: proc(proto_state: ^ProtoState) {
    if at_token(.RETURN) {
        parse_return_stmt(proto_state)
        return
    }

    if at_token(.LEFT_BRACE) {
        parse_block_stmt(proto_state)
        return
    }

    if at_token(.IF) {
        parse_if_stmt(proto_state)
        return
    }

    if at_token(.FOR) {
        parse_for_stmt(proto_state)
        return
    }

    if at_token(.BREAK) {
        parse_break_stmt(proto_state)
        return
    }

    if at_token(.SWITCH) {
        parse_switch_stmt(proto_state)
        return
    }

    if at_token(.CASE) {
        parser_error(proto_state, current_token(), "case is only valid inside switch")
        return
    }
    if at_token(.ELSE) {
        parser_error(proto_state, current_token(), "else is only valid after if or inside switch")
        return
    }

    if at_token(.GLOBAL) {
        parser_error(proto_state, current_token(), "global declarations are not implemented yet")
        return
    }

    if at_token(.IDENT) || at_token(.FUNCTION) || at_token(.LEFT_BRACKET) || at_token(.MAP) {
        parse_simple_stmt(proto_state)
        return
    }

    token := current_token()
    parser_error(proto_state, token, fmt.tprintf("expected statement, got `%s`", token_text_for_error(token)))
}

// Parses top-level statements until EOF. After each statement, next_temp_slot resets to local_count so temp slots are reused across statements.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
    for !Parser.failed && !at_token(.EOF) {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }
}


// Source compilation =============================================================================

// On success installs Active_State.entry_function for VM execution.
compile_source :: proc(source, source_name: string) -> ^Error {
    begin_scan(source, source_name)

    Parser.current = Token{}
    Parser.lookahead = Token{}
    Parser.has_lookahead = false
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
    entry_proto_state := begin_proto(entry_origin, "entry", 0)
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

    entry_proto := end_proto(&entry_proto_state)
    entry_function := new(ProtoFunctionObject)
    entry_function^ = ProtoFunctionObject{
        header = Object{kind = .PROTO_FUNCTION},
        name   = entry_proto.name,
        impl   = entry_proto,
    }
    Active_State.entry_function = entry_function
    return nil
}
