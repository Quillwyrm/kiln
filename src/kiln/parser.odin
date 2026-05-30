package kiln

import "core:fmt"

// Parser state ===================================================================================
// Token cursor and failure latch for one compile operation.

Parser := struct {
    current:       Token,
    lookahead:     Token,
    has_lookahead: bool,
    failed:        bool, // global error latch — every mutating operation sets it, callers check and return immediately

    // Scratch result from the last parsed expression.
    // parse_expr resets these. parse_expr_call_args sets them when the whole expression is a direct call.
    // RHS value-list lowering reads them immediately to expand a single-call RHS.
    last_expr_was_direct_call: bool,
    last_expr_call_index:      int,
}{}

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


// Function literals ==============================================================================

// Function bodies consume braces but do not create an extra root scope.
// Parameters and top-level body locals live together in the function's root scope.
// Blocks inside the body still create scopes through normal statement parsing.
parse_function_body :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start function body")
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_stat(proto_state)
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


// Expressions ====================================================================================

// Literals (int, float, string, bool, nil), identifiers (local-first then global), and function literals.
parse_expr_primary :: proc(proto_state: ^ProtoState, dst: int) {
    if at_token(.FUNCTION) {
        parse_function_literal(proto_state, dst, "<function>", current_token())
        return
    }

    token := advance_token()

    #partial switch token.kind {
    case .INT:
        if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
            parser_error(proto_state, token, "too many constants in function")
            return
        }

        value := token.value.(i64)
        const_index := const_int(proto_state, value)
        emit_load_const(proto_state, dst, const_index)

    case .FLOAT:
        if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
            parser_error(proto_state, token, "too many constants in function")
            return
        }

        value := token.value.(f64)
        const_index := const_float(proto_state, value)
        emit_load_const(proto_state, dst, const_index)

    case .STRING:
        if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
            parser_error(proto_state, token, "too many constants in function")
            return
        }

        text := token.value.(string)
        const_index := const_string(proto_state, text)
        emit_load_const(proto_state, dst, const_index)

    case .TRUE:
        emit_load_true(proto_state, dst)

    case .FALSE:
        emit_load_false(proto_state, dst)

    case .NIL:
        emit_load_nil(proto_state, dst)

    case .IDENT:
        ident_name := token.value.(string)
        local_index := resolve_local_index(proto_state, ident_name)
        if local_index >= 0 {
            emit_move(proto_state, dst, proto_state.local_bindings[local_index].frame_slot)
        } else {
            binding_id, found_global := resolve_global(ident_name)
            if !found_global {
                parser_error(proto_state, token, fmt.tprintf("unknown name `%s`", ident_name))
                return
            }
            emit_get_global(proto_state, dst, binding_id)
        }

    case:
        parser_error(proto_state, token, fmt.tprintf("expected expression, got `%s`", token_text_for_error(token)))
    }
}

// Prefix NOT lowers by evaluating the operand first, then emitting NOT into dst.
parse_expr_prefix :: proc(proto_state: ^ProtoState, dst: int) {
    if at_token(.NOT) {
        advance_token()

        operand_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        parse_expr_prefix(proto_state, operand_slot)
        if Parser.failed { return }

        emit_not(proto_state, dst, operand_slot)

        Parser.last_expr_was_direct_call = false
        Parser.last_expr_call_index = -1
        return
    }

    parse_expr_primary(proto_state, dst)
    if Parser.failed { return }

    if at_token(.LEFT_PAREN) {
        parse_expr_call_args(proto_state, dst, 1)
    }
}

// Layout: callee_slot, arg0, arg1, ...
// requested_results controls CALL's c operand:
//   0 = statement context — results follow the caller's return convention, not a specific slot
//   1 = expression context — expect exactly one result in dst
parse_expr_call_args :: proc(proto_state: ^ProtoState, callee_slot, requested_results: int) {
    consume_token(proto_state, .LEFT_PAREN, "expected '(' to start call arguments")
    if Parser.failed { return }

    arg_count := 0
    if !at_token(.RIGHT_PAREN) {
        for {
            arg_slot := callee_slot + 1 + arg_count
            if arg_slot >= MAX_FRAME_SLOTS {
                parser_error(proto_state, current_token(), "call uses too many values")
                return
            }

            parse_expr(proto_state, arg_slot)
            if Parser.failed { return }
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
    if Parser.failed { return }

    call_index := next_inst_index(proto_state)
    emit_call(proto_state, callee_slot, arg_count, requested_results)

    Parser.last_expr_was_direct_call = true
    Parser.last_expr_call_index = call_index
}

// parse_expr currently supports unary expressions and call suffix on primaries.
// Operator precedence parsing is not in this stage yet.
parse_expr :: proc(proto_state: ^ProtoState, dst: int) {
    Parser.last_expr_was_direct_call = false
    Parser.last_expr_call_index = -1

    parse_expr_prefix(proto_state, dst)
}

// Parses a comma-separated RHS value list into [first_slot, first_slot+slot_count). A single unparenthesized call expands to slot_count results. Fewer values than slots fills with nil; an explicit comma list exceeding slot_count is an error.
parse_rhs_value_list_into_slots :: proc(proto_state: ^ProtoState, first_slot: int, slot_count: int, form_name: string) {
    parse_expr(proto_state, first_slot)
    if Parser.failed { return }

    if !at_token(.COMMA) {
        if Parser.last_expr_was_direct_call {
            if slot_count > 255 {
                parser_error(proto_state, current_token(), "too many destinations for call result expansion")
                return
            }

            word := proto_state.bytecode[Parser.last_expr_call_index]
            inst := InstABC(word)
            inst.c = u8(slot_count)
            proto_state.bytecode[Parser.last_expr_call_index] = u32(inst)

            if slot_count > 1 {
                record_slots(proto_state, first_slot + slot_count - 1)
            }
        } else {
            for fill_index := 1; fill_index < slot_count; fill_index += 1 {
                emit_load_nil(proto_state, first_slot + fill_index)
            }
        }

        return
    }

    value_count := 1

    for at_token(.COMMA) {
        advance_token()

        if value_count >= slot_count {
            parser_error(
                proto_state,
                current_token(),
                fmt.tprintf("too many values in %s: expected %d", form_name, slot_count),
            )
            return
        }

        parse_expr(proto_state, first_slot + value_count)
        if Parser.failed { return }

        value_count += 1
    }

    for fill_index := value_count; fill_index < slot_count; fill_index += 1 {
        emit_load_nil(proto_state, first_slot + fill_index)
    }
}


// Statements =====================================================================================

// Parses a braced block { ... } with a new lexical scope.
parse_stat_block :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start block")
    if Parser.failed { return }

    begin_scope(proto_state)
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_stat(proto_state)
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
parse_stat_if :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .IF, "expected 'if'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    condition_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    parse_expr(proto_state, condition_slot)
    if Parser.failed { return }

    false_jump := emit_jump_false(proto_state, condition_slot)
    proto_state.next_temp_slot = temp_save
    parse_stat_block(proto_state)
    if Parser.failed { return }

    if at_token(.ELSE) {
        advance_token()

        end_jump := emit_jump(proto_state)
        patch_jump(proto_state, false_jump)
        if Parser.failed { return }

        if at_token(.IF) {
            parse_stat_if(proto_state)
        } else {
            parse_stat_block(proto_state)
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
parse_stat_for :: proc(proto_state: ^ProtoState) {
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

        parse_expr(proto_state, condition_slot)
        if Parser.failed { return }

        exit_jump = emit_jump_false(proto_state, condition_slot)
        proto_state.next_temp_slot = temp_save
        has_exit_jump = true
    }

    parse_stat_block(proto_state)
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
parse_stat_switch :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .SWITCH, "expected 'switch'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    subject_slot := -1
    subject_live_cursor := temp_save

    // Subject switch: evaluate subject expression into a temp slot.
    if !at_token(.LEFT_BRACE) {
        subject_slot = claim_temp_slot(proto_state)
        if Parser.failed { return }
        parse_expr(proto_state, subject_slot)
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
        parse_expr(proto_state, case_slot)
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
        parse_stat(proto_state)
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
parse_stat_break :: proc(proto_state: ^ProtoState) {
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
parse_stat_return :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .RETURN, "expected 'return'")
    if Parser.failed { return }

    if at_token(.EOF) || at_token(.RIGHT_BRACE) {
        emit_return(proto_state, 0, 0)
        return
    }

    first_result_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    parse_expr(proto_state, first_result_slot)
    if Parser.failed { return }

    result_count := 1
    for at_token(.COMMA) {
        advance_token()

        result_slot := first_result_slot + result_count
        if result_slot >= MAX_FRAME_SLOTS {
            parser_error(proto_state, current_token(), "return has too many values")
            return
        }

        parse_expr(proto_state, result_slot)
        if Parser.failed { return }
        result_count += 1
    }

    emit_return(proto_state, first_result_slot, result_count)
}

// Supported forms: if/for/break/return, decl, local assign, call.
parse_stat :: proc(proto_state: ^ProtoState) {
    if at_token(.RETURN) {
        parse_stat_return(proto_state)
        return
    }

    if at_token(.IF) {
        parse_stat_if(proto_state)
        return
    }

    if at_token(.FOR) {
        parse_stat_for(proto_state)
        return
    }

    if at_token(.BREAK) {
        parse_stat_break(proto_state)
        return
    }

    if at_token(.SWITCH) {
        parse_stat_switch(proto_state)
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

    if at_token(.IDENT) {
        parse_stat_identifier(proto_state)
        return
    }

    token := current_token()
    parser_error(proto_state, token, fmt.tprintf("expected statement, got `%s`", token_text_for_error(token)))
}

// Current token must be IDENT.
// Handles the three statement forms that start with an identifier or identifier list:
// call statement, declaration, assignment.
parse_stat_identifier :: proc(proto_state: ^ProtoState) {
    next_token := peek_token()
    if Parser.failed { return }

    // Call statement: foo()
    if next_token.kind == .LEFT_PAREN {
        callee_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        parse_expr_primary(proto_state, callee_slot)
        if Parser.failed { return }

        parse_expr_call_args(proto_state, callee_slot, 0)
        return
    }

    // Parse identifier list for declaration or assignment.
    lhs_tokens: [MAX_FRAME_SLOTS]Token
    lhs_count := 0

    lhs_tokens[lhs_count] = consume_token(proto_state, .IDENT, "expected identifier")
    if Parser.failed { return }
    lhs_count += 1

    for at_token(.COMMA) {
        advance_token()

        if lhs_count >= MAX_FRAME_SLOTS {
            parser_error(proto_state, current_token(), "too many assignment targets")
            return
        }

        lhs_tokens[lhs_count] = consume_token(proto_state, .IDENT, "expected identifier after ','")
        if Parser.failed { return }

        lhs_count += 1
    }

    // --- Declaration (:=) ---

    if at_token(.DECL) {
        advance_token()

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
        // RHS will be emitted directly into these slots.
        rhs_base := proto_state.next_temp_slot
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            claim_temp_slot(proto_state)
            if Parser.failed { return }
        }

        // Parse RHS into reserved slots (names not yet committed — invisible in own initializer).
        if lhs_count == 1 && at_token(.FUNCTION) {
            ident_text := lhs_tokens[0].value.(string)
            parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
            if Parser.failed { return }
        } else {
            parse_rhs_value_list_into_slots(proto_state, rhs_base, lhs_count, "declaration")
            if Parser.failed { return }
        }

        // Commit names to the slots that already hold the RHS values.
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            add_local_binding(proto_state, lhs_tokens[target_index].value.(string))
        }

        return
    }

    // --- Assignment (=) ---

    if at_token(.ASSIGN) {
        target_slots: [MAX_FRAME_SLOTS]int

        for target_index := 0; target_index < lhs_count; target_index += 1 {
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

            target_slots[target_index] = proto_state.local_bindings[local_index].frame_slot
        }

        advance_token()

        // Claim temp slots for RHS evaluation.
        rhs_base := proto_state.next_temp_slot
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            claim_temp_slot(proto_state)
            if Parser.failed { return }
        }

        // Parse RHS into temps.
        parse_rhs_value_list_into_slots(proto_state, rhs_base, lhs_count, "assignment")
        if Parser.failed { return }

        // MOVE temps into targets (swap safe).
        for target_index := 0; target_index < lhs_count; target_index += 1 {
            emit_move(proto_state, target_slots[target_index], rhs_base + target_index)
        }

        return
    }

    // --- No valid operator after identifier list ---

    first_name := lhs_tokens[0].value.(string)

    if lhs_count == 1 {
        parser_error(
            proto_state,
            lhs_tokens[0],
            fmt.tprintf("bare expression `%s` is not a statement; expected declaration, assignment, or call", first_name),
        )
        return
    }

    parser_error(proto_state, current_token(), "expected declaration or assignment after identifier list")
}

// Parses top-level statements until EOF. After each statement, next_temp_slot resets to local_count so temp slots are reused across statements.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
    for !Parser.failed && !at_token(.EOF) {
        parse_stat(proto_state)
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
