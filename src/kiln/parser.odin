package kiln

import "core:fmt"

// Parser state ===================================================================================
// Token cursor and error latch for one compile operation.

Parser := struct {
    current_token: Token,
    failed:        bool, // mutating parser operations set this, callers check and return immediately
}{}


// ExprDesc types ==================================================================================
// Expression descriptors decouple parsing from slot emission.
// parse_expr returns an ExprDesc; surrounding context emits or adjusts it.

ExprInvalid :: struct {}
ExprNil     :: struct {}

ExprUnresolvedBinding :: struct {
    token: Token,
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
    bool,
    i64,
    f64,
    string,
    ExprUnresolvedBinding,
    ExprLocal,
    ExprGlobal,
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
    if proto_state.scope_depth >= MAX_FRAME_SLOTS {
        parser_error(proto_state, Parser.current_token, "too many nested scopes")
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


// ExprDesc lowering =======================================================================
// These translate descriptors into concrete bytecode.

// lower_expr_desc lowers an expression descriptor so that the value lands
// in dst_slot at runtime.
lower_expr_desc :: proc(proto_state: ^ProtoState, expr: ExprDesc, dst_slot: int) {
    switch e in expr {
    case ExprInvalid:
        return

    case ExprNil:
        emit_load_nil(proto_state, dst_slot)

    case bool:
        if e {
            emit_load_true(proto_state, dst_slot)
        } else {
            emit_load_false(proto_state, dst_slot)
        }

    case i64:
        const_index := const_int(proto_state, e)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case f64:
        const_index := const_float(proto_state, e)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case string:
        const_index := const_string(proto_state, e)
        if Parser.failed { return }
        emit_load_const(proto_state, dst_slot, const_index)

    case ExprUnresolvedBinding:
        // Resolve bare identifier reads at the point they become values.
        ident_name := e.token.value.(string)
        local_index := local_binding_find(proto_state, ident_name)
        if local_index >= 0 {
            src_slot := proto_state.local_bindings[local_index].frame_slot
            if src_slot != dst_slot {
                emit_move(proto_state, dst_slot, src_slot)
            }
            return
        }

        binding_index := binding_table_find(&Active_State.global_env, ident_name)
        if binding_index < 0 {
            parser_error(proto_state, e.token, fmt.tprintf("unknown name `%s`", ident_name))
            return
        }

        emit_get_global(proto_state, dst_slot, BindingId(binding_index))

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


// Expression roots and chains =====================================================================

// arrayLiteral = "[" [exprList [","]] "]".
parse_array_literal :: proc(proto_state: ^ProtoState) -> ExprDesc {
    consume_token(proto_state, .LEFT_BRACKET, "expected '[' to start array literal")
    if Parser.failed { return ExprInvalid{} }

    array_slot := claim_temp_slot(proto_state)
    if Parser.failed { return ExprInvalid{} }

    emit_new_array(proto_state, array_slot, 0)
    reserve_slots_until(proto_state, array_slot + 1)
    if Parser.failed { return ExprInvalid{} }

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

    return ExprSlot{array_slot}
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
    reserve_slots_until(proto_state, map_slot + 1)
    if Parser.failed { return ExprInvalid{} }

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

    return ExprSlot{map_slot}
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
        return ExprUnresolvedBinding{advance_token()}
    }

    if Parser.current_token.kind == .FUNCTION {
        slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        parse_function_literal(proto_state, slot, "<function>", Parser.current_token)
        if Parser.failed { return ExprInvalid{} }
        return ExprSlot{slot}
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
        base_slot = slot_expr.slot
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
        container_slot = slot_expr.slot
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
            parser_error(proto_state, Parser.current_token, "field access is not implemented yet")
            return ExprInvalid{}
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
        return ExprSlot{result_slot}
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
        return ExprSlot{result_slot}
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
        left = ExprSlot{lhs_slot}
    }

    return left
}

// addExpr = mulExpr {addOp mulExpr}.
parse_add_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    left := parse_mul_expr(proto_state)
    if Parser.failed { return ExprInvalid{} }

    // addOp = "+" | "-".
    for Parser.current_token.kind == .PLUS || Parser.current_token.kind == .MINUS {
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
        } else {
            emit_sub(proto_state, lhs_slot, lhs_slot, rhs_slot)
        }

        // Only the accumulated left result remains live after the binary op.
        proto_state.next_temp_slot = lhs_slot + 1
        left = ExprSlot{lhs_slot}
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
        left = ExprSlot{lhs_slot}

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
        if Parser.failed { return ExprInvalid{} }

        right := parse_compare_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        right_false_jump := emit_jump_false(proto_state, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        emit_load_true(proto_state, result_slot)
        end_jump := emit_jump(proto_state)
        if Parser.failed { return ExprInvalid{} }

        patch_jump(proto_state, left_false_jump)
        if Parser.failed { return ExprInvalid{} }
        patch_jump(proto_state, right_false_jump)
        if Parser.failed { return ExprInvalid{} }
        emit_load_false(proto_state, result_slot)

        patch_jump(proto_state, end_jump)
        if Parser.failed { return ExprInvalid{} }

        // Only the accumulated bool result remains live after the logical op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot{result_slot}
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
        if Parser.failed { return ExprInvalid{} }

        emit_load_true(proto_state, result_slot)
        end_jump := emit_jump(proto_state)
        if Parser.failed { return ExprInvalid{} }

        patch_jump(proto_state, left_false_jump)
        if Parser.failed { return ExprInvalid{} }

        right := parse_and_expr(proto_state)
        if Parser.failed { return ExprInvalid{} }

        rhs_slot := claim_temp_slot(proto_state)
        if Parser.failed { return ExprInvalid{} }

        lower_expr_desc(proto_state, right, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        right_false_jump := emit_jump_false(proto_state, rhs_slot)
        if Parser.failed { return ExprInvalid{} }

        emit_load_true(proto_state, result_slot)
        end_jump_from_right := emit_jump(proto_state)
        if Parser.failed { return ExprInvalid{} }

        patch_jump(proto_state, right_false_jump)
        if Parser.failed { return ExprInvalid{} }
        emit_load_false(proto_state, result_slot)

        patch_jump(proto_state, end_jump)
        if Parser.failed { return ExprInvalid{} }
        patch_jump(proto_state, end_jump_from_right)
        if Parser.failed { return ExprInvalid{} }

        // Only the accumulated bool result remains live after the logical op.
        proto_state.next_temp_slot = result_slot + 1
        left = ExprSlot{result_slot}
    }

    return left
}

// expr = orExpr.
// fallbackExpr belongs above orExpr when implemented.
parse_expr :: proc(proto_state: ^ProtoState) -> ExprDesc {
    return parse_or_expr(proto_state)
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
    param_tokens: [MAX_FRAME_SLOTS]Token
    param_count := 0
    if Parser.current_token.kind != .RIGHT_PAREN {
        for {
            if param_count >= MAX_FRAME_SLOTS {
                parser_error(parent_proto_state, Parser.current_token, "too many function parameters")
                return
            }

            param_tokens[param_count] = consume_token(parent_proto_state, .IDENT, "expected parameter name")
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
                parser_error(&child_proto_state, param_tokens[param_index], fmt.tprintf("parameter `%s` is already declared in this function", param_name))
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

    if proto_state.loop_depth >= MAX_LOOP_DEPTH {
        parser_error(proto_state, Parser.current_token, "too many nested loops")
        return
    }
    // Break fixups added after this point belong to this loop.
    proto_state.loop_break_fixup_base[proto_state.loop_depth] = proto_state.break_fixup_count
    proto_state.loop_depth += 1

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

    proto_state.loop_depth -= 1
    break_fixup_base := proto_state.loop_break_fixup_base[proto_state.loop_depth]
    // Patch breaks from this loop body only.
    for fixup_index := break_fixup_base; fixup_index < proto_state.break_fixup_count; fixup_index += 1 {
        patch_jump(proto_state, proto_state.break_fixups[fixup_index])
        if Parser.failed { return }
    }
    proto_state.break_fixup_count = break_fixup_base
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
    end_jumps: [256]int
    end_jump_count := 0

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
        if Parser.failed { return }

        parse_switch_arm_body(proto_state)
        if Parser.failed { return }

        if end_jump_count >= len(end_jumps) {
            parser_error(proto_state, Parser.current_token, "switch has too many arms")
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

    for i in 0 ..< end_jump_count {
        patch_jump(proto_state, end_jumps[i])
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

    expr = ExprUnresolvedBinding{ident_token}

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
            parser_error(proto_state, Parser.current_token, "field/namespace access is not implemented yet")
            return
        }

        break
    }

    return
}

// declStmt = ["global"] identList declOp exprList.
finish_decl_stmt :: proc(proto_state: ^ProtoState, lhs_tokens: []Token, is_mutable: bool) {
    advance_token()

    lhs_count := len(lhs_tokens)

    // Validate all declaration names before RHS emission.
    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("duplicate declaration name `%s`", check_name))
                return
            }
        }

        global_index := binding_table_find(&Active_State.global_env, check_name)
        if global_index >= 0 {
            parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("local variable `%s` cannot shadow global binding", check_name))
            return
        }

        scope_start := 0
        if proto_state.scope_depth > 0 {
            scope_start = proto_state.scope_local_counts[proto_state.scope_depth - 1]
        }

        for local_index := scope_start; local_index < proto_state.local_count; local_index += 1 {
            if proto_state.local_bindings[local_index].name == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("local variable `%s` is already declared in this scope", check_name))
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

    // Commit names to the slots that already hold the RHS values.
    for target_index := 0; target_index < lhs_count; target_index += 1 {
        local_binding_append(proto_state, lhs_tokens[target_index].value.(string), is_mutable)
    }
}

// assignTarget = ident | ident {postfix} accessPostfix.
resolve_assign_target :: proc(proto_state: ^ProtoState, source_token: Token, target: ExprDesc) -> ExprDesc {
    // Assignment target resolution checks mutability; normal expression reads do not.
    #partial switch t in target {
    case ExprUnresolvedBinding:
        ident_text := t.token.value.(string)

        local_index := local_binding_find(proto_state, ident_text)
        if local_index >= 0 {
            if !proto_state.local_bindings[local_index].is_mutable {
                parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
                return ExprInvalid{}
            }

            return ExprLocal{local_index}
        }

        global_index := binding_table_find(&Active_State.global_env, ident_text)
        if global_index < 0 {
            parser_error(proto_state, source_token, fmt.tprintf("assignment target `%s` is not a declared binding", ident_text))
            return ExprInvalid{}
        }

        if !Active_State.global_env.is_mutable[global_index] {
            parser_error(proto_state, source_token, fmt.tprintf("cannot assign to immutable binding `%s`", ident_text))
            return ExprInvalid{}
        }

        return ExprGlobal{BindingId(global_index)}

    case ExprLocal, ExprGlobal, ExprIndex:
        return target

    case ExprCall:
        parser_error(proto_state, source_token, fmt.tprintf("call expression `%s` is not an assignment target; expected identifier or indexed expression", source_token.value.(string)))
        return ExprInvalid{}
    }

    panic("assignment target resolution reached non-assignable expression descriptor")
}

set_assign_target :: proc(proto_state: ^ProtoState, src_slot: int, target: ExprDesc) {
    #partial switch t in target {
    case ExprLocal:
        dst_slot := proto_state.local_bindings[t.local_index].frame_slot
        if dst_slot != src_slot {
            emit_move(proto_state, dst_slot, src_slot)
        }

    case ExprGlobal:
        emit_set_global(proto_state, src_slot, t.binding_id)

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
    binding_ids: [MAX_BINDINGS]BindingId
    lhs_count := 0

    for {
        if lhs_count >= MAX_BINDINGS {
            parser_error(proto_state, Parser.current_token, "too many global declaration names")
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
        parser_error(proto_state, Parser.current_token, "expected ':=' or '::' after global declaration name list")
        return
    }
    advance_token()

    for check_index := 0; check_index < lhs_count; check_index += 1 {
        check_name := lhs_tokens[check_index].value.(string)

        for prev_index := 0; prev_index < check_index; prev_index += 1 {
            if lhs_tokens[prev_index].value.(string) == check_name {
                parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("duplicate global declaration name `%s`", check_name))
                return
            }
        }

        global_index := binding_table_find(&Active_State.global_env, check_name)
        if global_index >= 0 {
            parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("global binding `%s` is already declared", check_name))
            return
        }

        local_index := local_binding_find(proto_state, check_name)
        if local_index >= 0 {
            parser_error(proto_state, lhs_tokens[check_index], fmt.tprintf("global binding `%s` conflicts with local variable", check_name))
            return
        }
    }

    if Active_State.global_env.count + lhs_count > MAX_BINDINGS {
        parser_error(proto_state, global_token, "too many global bindings")
        return
    }

    global_count_before := Active_State.global_env.count
    for target_index := 0; target_index < lhs_count; target_index += 1 {
        binding_ids[target_index] = binding_table_append(&Active_State.global_env, lhs_tokens[target_index].value.(string), is_mutable)
    }

    rhs_base := proto_state.next_temp_slot

    if lhs_count == 1 && Parser.current_token.kind == .FUNCTION {
        ident_text := lhs_tokens[0].value.(string)
        parse_function_literal(proto_state, rhs_base, ident_text, lhs_tokens[0])
        if Parser.failed {
            Active_State.global_env.count = global_count_before
            return
        }
    } else {
        expr_count, last_expr := parse_expr_list(proto_state, rhs_base)
        if Parser.failed {
            Active_State.global_env.count = global_count_before
            return
        }

        if expr_count > lhs_count {
            Active_State.global_env.count = global_count_before
            parser_error(proto_state, Parser.current_token, fmt.tprintf("too many values in global declaration: expected %d", lhs_count))
            return
        }

        finish_expr_list_to_slots(proto_state, rhs_base, expr_count, last_expr, lhs_count)
        if Parser.failed {
            Active_State.global_env.count = global_count_before
            return
        }
    }

    for target_index := 0; target_index < lhs_count; target_index += 1 {
        emit_set_global(proto_state, rhs_base + target_index, binding_ids[target_index])
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

    // Dispatch in decreasing specificity: declare (:=), imm declare (::),
    // assign (=), compound assign (+= etc), then call or error.
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
            parser_error(proto_state, Parser.current_token, "compound assignment expects one target")
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

    if Parser.current_token.kind == .IDENT || Parser.current_token.kind == .FUNCTION || Parser.current_token.kind == .LEFT_BRACKET || Parser.current_token.kind == .MAP {
        parse_simple_stmt(proto_state)
        return
    }

    token := Parser.current_token
    parser_error(proto_state, token, fmt.tprintf("expected statement, got `%s`", error_token_text(token)))
}

// sourceFile = {stmt} EOF.
// Top-level statement temps die at statement end.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
    for !Parser.failed && Parser.current_token.kind != .EOF {
        parse_stmt(proto_state)
        if Parser.failed { return }
        proto_state.next_temp_slot = proto_state.local_count
    }
}


// Source compilation =============================================================================

// On success installs Active_State.entry_function for VM execution.
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
