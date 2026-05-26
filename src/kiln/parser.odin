package kiln

import "core:fmt"


// Proto-local bindings ===========================================================================
MAX_FRAME_SLOTS :: 256

Local_Binding :: struct {
	name: string,
	slot: int,
}


// Token cursor ===================================================================================

current_token :: proc() -> Token {
	return Source_State.tokens[Source_State.token_index]
}

peek_token :: proc() -> Token {
	return Source_State.tokens[Source_State.token_index + 1]
}

at_token :: proc(kind: TokenKind) -> bool {
	return current_token().kind == kind
}

advance_token :: proc() -> Token {
	token := current_token()
	Source_State.token_index += 1
	return token
}

parser_error :: proc(token: Token, message: string) {
	set_error(Source_State.source_name, token.line, token.column, message)
	Source_State.failed = true
}

consume_token :: proc(kind: TokenKind, message: string) -> Token {
	if at_token(kind) {
		return advance_token()
	}

	token := current_token()
	parser_error(token, message)
	return Token{}
}


// Slots and locals ===============================================================================

claim_temp_slot :: proc(proto_state: ^ProtoState) -> int {
	if proto_state.next_temp_slot >= MAX_FRAME_SLOTS {
		parser_error(current_token(), "too many slots in proto")
		return 0
	}

	slot := proto_state.next_temp_slot
	proto_state.next_temp_slot += 1
	return slot
}

declare_local :: proc(proto_state: ^ProtoState, name_token: Token) -> int {
	name := name_token.value.(string)

	for local_index := 0; local_index < proto_state.local_count; local_index += 1 {
		if proto_state.locals[local_index].name == name {
			parser_error(name_token, fmt.tprintf("local already declared: %s", name))
			return 0
		}
	}

	if proto_state.local_count >= MAX_FRAME_SLOTS {
		parser_error(name_token, "too many local bindings")
		return 0
	}

	slot := proto_state.local_count
	proto_state.locals[proto_state.local_count] = Local_Binding{name = name, slot = slot}
	proto_state.local_count += 1
	proto_state.next_temp_slot = proto_state.local_count
	return slot
}

resolve_local :: proc(proto_state: ^ProtoState, name: string) -> (slot: int, found: bool) {
	for local_index := proto_state.local_count - 1; local_index >= 0; local_index -= 1 {
		if proto_state.locals[local_index].name == name {
			return proto_state.locals[local_index].slot, true
		}
	}

	return 0, false
}


// Expressions ====================================================================================

parse_primary :: proc(proto_state: ^ProtoState, dst: int) {
	token := advance_token()

	#partial switch token.kind {
	case .INT:
		value := token.value.(i64)
		const_index := const_int(proto_state, value)
		emit_load_const(proto_state, dst, const_index)

	case .FLOAT:
		value := token.value.(f64)
		const_index := const_float(proto_state, value)
		emit_load_const(proto_state, dst, const_index)

	case .STRING:
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
		name := token.value.(string)
		local_slot, is_local := resolve_local(proto_state, name)
		if is_local {
			emit_move(proto_state, dst, local_slot)
		} else {
			binding_id, found_global := resolve_global(name)
			if !found_global {
				parser_error(token, fmt.tprintf("unknown name: %s", name))
				return
			}
			emit_get_global(proto_state, dst, binding_id)
		}

	case:
		parser_error(token, "expected expression")
	}
}

parse_call :: proc(proto_state: ^ProtoState, callee_slot, requested_results: int) {
	consume_token(.LEFT_PAREN, "expected '(' to start call arguments")
	if Source_State.failed {
		return
	}

	arg_count := 0
	if !at_token(.RIGHT_PAREN) {
		for {
			arg_slot := callee_slot + 1 + arg_count
			if arg_slot >= MAX_FRAME_SLOTS {
				parser_error(current_token(), "too many call arguments or temporary slots")
				return
			}

			parse_expression(proto_state, arg_slot)
			if Source_State.failed {
				return
			}
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

	consume_token(.RIGHT_PAREN, "expected ')' after call arguments")
	if Source_State.failed {
		return
	}
	emit_call(proto_state, callee_slot, arg_count, requested_results)
}

parse_expression :: proc(proto_state: ^ProtoState, dst: int) {
	parse_primary(proto_state, dst)
	if Source_State.failed {
		return
	}

	if at_token(.LEFT_PAREN) {
		parse_call(proto_state, dst, 1)
	}
}


// Statements =====================================================================================

parse_statement :: proc(proto_state: ^ProtoState) {
	if !at_token(.IDENT) {
		parser_error(current_token(), "expected statement")
		return
	}

	next_kind := peek_token().kind
	if next_kind == .LEFT_PAREN {
		callee_slot := claim_temp_slot(proto_state)
		if Source_State.failed {
			return
		}

		parse_primary(proto_state, callee_slot)
		if Source_State.failed {
			return
		}

		parse_call(proto_state, callee_slot, 0)
		return
	}

	ident_token := advance_token()
	ident_text := ident_token.value.(string)

	if next_kind == .DECL {
		advance_token()

		slot := declare_local(proto_state, ident_token)
		if Source_State.failed {
			return
		}

		parse_expression(proto_state, slot)
		return
	}

	if next_kind == .ASSIGN {
		slot, is_local := resolve_local(proto_state, ident_text)
		if !is_local {
			parser_error(ident_token, "assignment target is not a local")
			return
		}

		advance_token()
		parse_expression(proto_state, slot)
		return
	}

	parser_error(
		ident_token,
		fmt.tprintf("invalid bare expression `%s`; expected declaration, assignment, or call statement", ident_text),
	)
}

parse_top_level_statements :: proc(proto_state: ^ProtoState) {
	for !Source_State.failed && !at_token(.EOF) {
		parse_statement(proto_state)
		if Source_State.failed {
			return
		}
		proto_state.next_temp_slot = proto_state.local_count
	}
}


// Source compilation =============================================================================

compile_source :: proc(state: ^State, source, source_name: string) -> ^Error {
	tokens, scan_error := scan_source(source, source_name)
	defer delete(tokens)
	if scan_error != nil {
		return scan_error
	}

	entry_proto_state := begin_proto("entry", 0)
	parse_top_level_statements(&entry_proto_state)
	if Source_State.failed {
		return &state.error
	}

	return_slot := claim_temp_slot(&entry_proto_state)
	if Source_State.failed {
		return &state.error
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
	state.entry_function = entry_function
	return nil
}
