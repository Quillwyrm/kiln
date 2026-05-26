package kiln

import "core:fmt"

// Parser state ===================================================================================

// Parser is the working state for token-stream parsing.
// It tracks parse position and parse failure state for one compile operation.
Parser := struct {
	tokens: []Token,
	token_index: int,
	failed: bool,
}{}

// Token cursor ===================================================================================

// Token cursor helpers over Parser.tokens.
// Parser.token_index points to the current token being parsed.
current_token :: proc() -> Token {
	return Parser.tokens[Parser.token_index]
}

peek_token :: proc() -> Token {
	return Parser.tokens[Parser.token_index + 1]
}

at_token :: proc(kind: TokenKind) -> bool {
	return current_token().kind == kind
}

advance_token :: proc() -> Token {
	token := current_token()
	Parser.token_index += 1
	return token
}

// parser_error records a source-positioned compile error and stops parse flow.
// source_name comes from the current ProtoState being compiled.
parser_error :: proc(proto_state: ^ProtoState, token: Token, message: string) {
	set_error(proto_state.source_name, token.line, token.column, message)
	Parser.failed = true
}

// consume_token enforces required grammar tokens.
// On mismatch it records an error and returns zero token value.
consume_token :: proc(proto_state: ^ProtoState, kind: TokenKind, message: string) -> Token {
	if at_token(kind) {
		return advance_token()
	}

	token := current_token()
	parser_error(proto_state, token, message)
	return Token{}
}


// Slots and locals ===============================================================================

// claim_temp_slot reserves one temporary frame slot for expression/call work.
// Temp slots are bounded by MAX_FRAME_SLOTS due to u8 slot encoding.
claim_temp_slot :: proc(proto_state: ^ProtoState) -> int {
	if proto_state.next_temp_slot >= MAX_FRAME_SLOTS {
		parser_error(proto_state, current_token(), "too many slots in proto")
		return 0
	}

	slot := proto_state.next_temp_slot
	proto_state.next_temp_slot += 1
	return slot
}

// declare_local binds one identifier to the next local frame slot.
// Current parser stage is flat-scope: duplicate local names are rejected.
declare_local :: proc(proto_state: ^ProtoState, ident_token: Token) -> int {
	ident_name := ident_token.value.(string)

	for local_index := 0; local_index < proto_state.local_count; local_index += 1 {
		if proto_state.local_bindings[local_index].name == ident_name {
			parser_error(proto_state, ident_token, fmt.tprintf("local already declared: %s", ident_name))
			return 0
		}
	}

	if proto_state.local_count >= MAX_FRAME_SLOTS {
		parser_error(proto_state, ident_token, "too many local bindings")
		return 0
	}

	slot := proto_state.local_count
	proto_state.local_bindings[proto_state.local_count] = LocalBinding{name = ident_name, frame_slot = slot}
	proto_state.local_count += 1
	proto_state.next_temp_slot = proto_state.local_count
	return slot
}

// resolve_local finds the nearest local binding by identifier name.
// Reverse scan returns the most recently declared matching local.
resolve_local :: proc(proto_state: ^ProtoState, ident_name: string) -> (slot: int, found: bool) {
	for local_index := proto_state.local_count - 1; local_index >= 0; local_index -= 1 {
		if proto_state.local_bindings[local_index].name == ident_name {
			return proto_state.local_bindings[local_index].frame_slot, true
		}
	}

	return 0, false
}


// Expressions ====================================================================================

// parse_primary emits one primary expression value into dst.
// IDENT resolves local first, then global binding table by name.
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
		ident_name := token.value.(string)
		local_slot, is_local := resolve_local(proto_state, ident_name)
		if is_local {
			emit_move(proto_state, dst, local_slot)
		} else {
			binding_id, found_global := resolve_global(ident_name)
			if !found_global {
				parser_error(proto_state, token, fmt.tprintf("unknown name: %s", ident_name))
				return
			}
			emit_get_global(proto_state, dst, binding_id)
		}

	case:
		parser_error(proto_state, token, "expected expression")
	}
}

// parse_call lowers callee(args...) using contiguous call slots:
// callee_slot, arg0, arg1, ...
// requested_results controls VM CALL result shaping (0 for statements, 1 for expressions).
parse_call :: proc(proto_state: ^ProtoState, callee_slot, requested_results: int) {
	consume_token(proto_state, .LEFT_PAREN, "expected '(' to start call arguments")
	if Parser.failed {
		return
	}

	arg_count := 0
	if !at_token(.RIGHT_PAREN) {
		for {
			arg_slot := callee_slot + 1 + arg_count
			if arg_slot >= MAX_FRAME_SLOTS {
				parser_error(proto_state, current_token(), "too many call arguments or temporary slots")
				return
			}

			parse_expression(proto_state, arg_slot)
			if Parser.failed {
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

	consume_token(proto_state, .RIGHT_PAREN, "expected ')' after call arguments")
	if Parser.failed {
		return
	}
	emit_call(proto_state, callee_slot, arg_count, requested_results)
}

// parse_expression currently supports primary expressions plus call suffix.
// Operator precedence parsing is not in this stage yet.
parse_expression :: proc(proto_state: ^ProtoState, dst: int) {
	parse_primary(proto_state, dst)
	if Parser.failed {
		return
	}

	if at_token(.LEFT_PAREN) {
		parse_call(proto_state, dst, 1)
	}
}


// Statements =====================================================================================

// parse_statement supports three top-level statement forms:
// - ident := expression
// - ident = expression (local-only assignment)
// - call statement
parse_statement :: proc(proto_state: ^ProtoState) {
	if !at_token(.IDENT) {
		parser_error(proto_state, current_token(), "expected statement")
		return
	}

	next_kind := peek_token().kind
	if next_kind == .LEFT_PAREN {
		callee_slot := claim_temp_slot(proto_state)
		if Parser.failed {
			return
		}

		parse_primary(proto_state, callee_slot)
		if Parser.failed {
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
		if Parser.failed {
			return
		}

		parse_expression(proto_state, slot)
		return
	}

	if next_kind == .ASSIGN {
		slot, is_local := resolve_local(proto_state, ident_text)
		if !is_local {
			parser_error(proto_state, ident_token, "assignment target is not a local")
			return
		}

		advance_token()
		parse_expression(proto_state, slot)
		return
	}

	parser_error(
		proto_state,
		ident_token,
		fmt.tprintf("invalid bare expression `%s`; expected declaration, assignment, or call statement", ident_text),
	)
}

// parse_top_level_statements parses until EOF or first parse failure.
// After each statement, next_temp_slot resets to local_count so temporary slots are reused.
parse_top_level_statements :: proc(proto_state: ^ProtoState) {
	for !Parser.failed && !at_token(.EOF) {
		parse_statement(proto_state)
		if Parser.failed {
			return
		}
		proto_state.next_temp_slot = proto_state.local_count
	}
}


// Source compilation =============================================================================

// compile_source scans source, parses top-level forms, and builds entry proto.
// On success it installs Active_State.entry_function for VM execution.
compile_source :: proc(source, source_name: string) -> ^Error {
	tokens, scan_error := scan_source(source, source_name)
	defer delete(tokens)
	if scan_error != nil {
		return scan_error
	}

	Parser.tokens = tokens[:]
	Parser.token_index = 0
	Parser.failed = false

	entry_proto_state := begin_proto(source_name, "entry", 0)
	parse_top_level_statements(&entry_proto_state)
	if Parser.failed {
		return &Active_State.error
	}

	return_slot := claim_temp_slot(&entry_proto_state)
	if Parser.failed {
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
