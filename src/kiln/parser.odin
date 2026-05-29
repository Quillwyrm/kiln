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

// Duplicate names are rejected within the current lexical scope only.
declare_local :: proc(proto_state: ^ProtoState, ident_token: Token) -> int {
    ident_name := ident_token.value.(string)

    scope_start := 0
    if proto_state.scope_depth > 0 {
        scope_start = proto_state.scope_local_counts[proto_state.scope_depth - 1]
    }

    for local_index := scope_start; local_index < proto_state.local_count; local_index += 1 {
        if proto_state.local_bindings[local_index].name == ident_name {
            parser_error(
                proto_state,
                ident_token,
                fmt.tprintf("local variable `%s` is already declared in this scope", ident_name),
            )
            return 0
        }
    }

    if proto_state.local_count >= MAX_FRAME_SLOTS {
        parser_error(proto_state, ident_token, "too many local variables in function")
        return 0
    }

    slot := proto_state.local_count
    proto_state.local_bindings[proto_state.local_count] = LocalBinding{name = ident_name, frame_slot = slot}
    proto_state.local_count += 1
    proto_state.next_temp_slot = proto_state.local_count
    return slot
}

// Reverse scan returns the most recently declared matching local.
resolve_local :: proc(proto_state: ^ProtoState, ident_name: string) -> (slot: int, found: bool) {
    for local_index := proto_state.local_count - 1; local_index >= 0; local_index -= 1 {
        if proto_state.local_bindings[local_index].name == ident_name {
            return proto_state.local_bindings[local_index].frame_slot, true
        }
    }

    return 0, false
}


// Function literals ==============================================================================

// Function bodies consume braces but do not create an extra root scope.
// Parameters and top-level body locals live together in the function's root scope.
// Blocks inside the body still create scopes through normal statement parsing.
parse_function_body :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start function body")
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_statement(proto_state)
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
        declare_local(&child_proto_state, param_tokens[param_index])
        if Parser.failed {
            delete_proto_state(&child_proto_state)
            return
        }
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

// IDENT resolves local first, then global binding table by name.
parse_primary :: proc(proto_state: ^ProtoState, dst: int) {
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
        local_slot, is_local := resolve_local(proto_state, ident_name)
        if is_local {
            emit_move(proto_state, dst, local_slot)
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
parse_unary :: proc(proto_state: ^ProtoState, dst: int) {
    if at_token(.NOT) {
        advance_token()

        operand_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        parse_unary(proto_state, operand_slot)
        if Parser.failed { return }

        emit_not(proto_state, dst, operand_slot)
        return
    }

    parse_primary(proto_state, dst)
    if Parser.failed { return }

    if at_token(.LEFT_PAREN) {
        parse_call(proto_state, dst, 1)
    }
}

// Layout: callee_slot, arg0, arg1, ...
// requested_results controls CALL's c operand:
//   0 = statement context — results follow the caller's return convention, not a specific slot
//   1 = expression context — expect exactly one result in dst
parse_call :: proc(proto_state: ^ProtoState, callee_slot, requested_results: int) {
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

            parse_expression(proto_state, arg_slot)
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
    emit_call(proto_state, callee_slot, arg_count, requested_results)
}

// parse_expression currently supports unary expressions and call suffix on primaries.
// Operator precedence parsing is not in this stage yet.
parse_expression :: proc(proto_state: ^ProtoState, dst: int) {
    parse_unary(proto_state, dst)
}


// Statements =====================================================================================

// Creates a new lexical local scope.
parse_block :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .LEFT_BRACE, "expected '{' to start block")
    if Parser.failed { return }

    begin_scope(proto_state)
    if Parser.failed { return }

    for !Parser.failed && !at_token(.RIGHT_BRACE) && !at_token(.EOF) {
        parse_statement(proto_state)
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
parse_if_statement :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .IF, "expected 'if'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    condition_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    parse_expression(proto_state, condition_slot)
    if Parser.failed { return }

    false_jump := emit_jump_false(proto_state, condition_slot)
    proto_state.next_temp_slot = temp_save
    parse_block(proto_state)
    if Parser.failed { return }

    if at_token(.ELSE) {
        advance_token()

        end_jump := emit_jump(proto_state)
        patch_jump(proto_state, false_jump)
        if Parser.failed { return }

        if at_token(.IF) {
            parse_if_statement(proto_state)
        } else {
            parse_block(proto_state)
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
parse_for_statement :: proc(proto_state: ^ProtoState) {
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

        parse_expression(proto_state, condition_slot)
        if Parser.failed { return }

        exit_jump = emit_jump_false(proto_state, condition_slot)
        proto_state.next_temp_slot = temp_save
        has_exit_jump = true
    }

    parse_block(proto_state)
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
parse_switch_statement :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .SWITCH, "expected 'switch'")
    if Parser.failed { return }

    temp_save := proto_state.next_temp_slot
    subject_slot := -1
    subject_live_cursor := temp_save

    // Subject switch: evaluate subject expression into a temp slot.
    if !at_token(.LEFT_BRACE) {
        subject_slot = claim_temp_slot(proto_state)
        if Parser.failed { return }
        parse_expression(proto_state, subject_slot)
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
        parse_expression(proto_state, case_slot)
        if Parser.failed { return }
        consume_token(proto_state, .COLON, "expected ':' after switch case")
        if Parser.failed { return }

        cond_slot := case_slot

        if subject_slot >= 0 {
            cond_slot = claim_temp_slot(proto_state)
            if Parser.failed { return }
            emit_equal(proto_state, cond_slot, subject_slot, case_slot)
            if Parser.failed { return }
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
        parse_statement(proto_state)
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
parse_break_statement :: proc(proto_state: ^ProtoState) {
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

// Each return expression is lowered as a single-result expression.
parse_return_statement :: proc(proto_state: ^ProtoState) {
    consume_token(proto_state, .RETURN, "expected 'return'")
    if Parser.failed { return }

    if at_token(.EOF) || at_token(.RIGHT_BRACE) {
        emit_return(proto_state, 0, 0)
        return
    }

    first_result_slot := claim_temp_slot(proto_state)
    if Parser.failed { return }

    parse_expression(proto_state, first_result_slot)
    if Parser.failed { return }

    result_count := 1
    for at_token(.COMMA) {
        advance_token()

        result_slot := first_result_slot + result_count
        if result_slot >= MAX_FRAME_SLOTS {
            parser_error(proto_state, current_token(), "return has too many values")
            return
        }

        parse_expression(proto_state, result_slot)
        if Parser.failed { return }
        result_count += 1
    }

    emit_return(proto_state, first_result_slot, result_count)
}

// Supported forms: if/for/break/return, decl, local assign, call.
parse_statement :: proc(proto_state: ^ProtoState) {
    if at_token(.RETURN) {
        parse_return_statement(proto_state)
        return
    }

    if at_token(.IF) {
        parse_if_statement(proto_state)
        return
    }

    if at_token(.FOR) {
        parse_for_statement(proto_state)
        return
    }

    if at_token(.BREAK) {
        parse_break_statement(proto_state)
        return
    }

    if at_token(.SWITCH) {
        parse_switch_statement(proto_state)
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

    if !at_token(.IDENT) {
        token := current_token()
        parser_error(proto_state, token, fmt.tprintf("expected statement, got `%s`", token_text_for_error(token)))
        return
    }

    next_token := peek_token()
    if Parser.failed { return }
    next_kind := next_token.kind
    if next_kind == .LEFT_PAREN {
        callee_slot := claim_temp_slot(proto_state)
        if Parser.failed { return }

        parse_primary(proto_state, callee_slot)
        if Parser.failed { return }

        parse_call(proto_state, callee_slot, 0)
        return
    }

    ident_token := advance_token()
    ident_text := ident_token.value.(string)

    if next_kind == .DECL {
        advance_token()

        slot := declare_local(proto_state, ident_token)
        if Parser.failed { return }

        // Declaration gives the function proto a useful name and origin.
        if at_token(.FUNCTION) {
            parse_function_literal(proto_state, slot, ident_text, ident_token)
            return
        }

        parse_expression(proto_state, slot)
        return
    }

    if next_kind == .ASSIGN {
        slot, is_local := resolve_local(proto_state, ident_text)
        if !is_local {
            parser_error(proto_state, ident_token, fmt.tprintf("assignment target `%s` is not a local variable", ident_text))
            return
        }

        advance_token()
        parse_expression(proto_state, slot)
        return
    }

    parser_error(
        proto_state,
        ident_token,
        fmt.tprintf("bare expression `%s` is not a statement; expected declaration, assignment, or call", ident_text),
    )
}

// After each statement, next_temp_slot resets to local_count so temporary slots are reused.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
    for !Parser.failed && !at_token(.EOF) {
        parse_statement(proto_state)
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
