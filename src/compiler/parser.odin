package compiler

import "core:fmt"
import "../vm"


// Parser state ===================================================================================

MAX_LOCALS :: 256

Local_Binding :: struct {
	name: string,
	slot: int,
}

Parser := struct {
	tokens: []Token,
	index:  int,

	// First-pass locals live in stable frame slots starting at 0.
	// Temporary expression/call slots are reused after each statement.
	locals:      [MAX_LOCALS]Local_Binding,
	local_count: int,
	temp_slot:   int,
}{}


// Token cursor ===================================================================================

current_token :: proc() -> Token {
	return Parser.tokens[Parser.index]
}

peek_token :: proc() -> Token {
	return Parser.tokens[Parser.index + 1]
}

at_token :: proc(kind: TokenKind) -> bool {
	return current_token().kind == kind
}

advance_token :: proc() -> Token {
	token := current_token()
	Parser.index += 1
	return token
}

consume_token :: proc(kind: TokenKind, message: string) -> Token {
	if at_token(kind) {
		return advance_token()
	}

	token := current_token()
	panic(fmt.tprintf(
		"parser error at %d:%d offset %d: %s",
		token.line,
		token.column,
		token.offset,
		message,
	))
}


// Slots and locals ===============================================================================

alloc_temp :: proc() -> int {
	slot := Parser.temp_slot
	Parser.temp_slot += 1
	return slot
}

reset_temps :: proc() {
	Parser.temp_slot = Parser.local_count
}

declare_local :: proc(name: string) -> int {
	slot := Parser.local_count
	Parser.locals[Parser.local_count] = Local_Binding{name = name, slot = slot}
	Parser.local_count += 1
	Parser.temp_slot = Parser.local_count
	return slot
}

resolve_local :: proc(name: string) -> (slot: int, ok: bool) {
	for local_index := Parser.local_count - 1; local_index >= 0; local_index -= 1 {
		if Parser.locals[local_index].name == name {
			return Parser.locals[local_index].slot, true
		}
	}

	return 0, false
}


// Expressions ====================================================================================

parse_primary_into :: proc(dst: int) {
	token := advance_token()

	#partial switch token.kind {
	case .INT:
		value, _ := token.value.(i64)
		const_index := const_int(value)
		emit_load_const(dst, const_index)

	case .STRING:
		value, _ := token.value.(string)
		const_index := const_string(value)
		emit_load_const(dst, const_index)

	case .TRUE:
		emit_load_true(dst)

	case .FALSE:
		emit_load_false(dst)

	case .NIL:
		emit_load_nil(dst)

	case .IDENT:
		name, _ := token.value.(string)
		local_slot, is_local := resolve_local(name)
		if is_local {
			emit_move(dst, local_slot)
		} else {
			binding_id := bind_global(name)
			emit_get_global(dst, binding_id)
		}

	case:
		panic(fmt.tprintf(
			"parser error at %d:%d offset %d: expected expression",
			token.line,
			token.column,
			token.offset,
		))
	}
}

parse_call :: proc(callee_slot, requested_results: int) {
	consume_token(.LEFT_PAREN, "expected '(' to start call arguments")

	// VM call layout is slot-contiguous:
	//     callee, arg0, arg1, ...
	// The parser emits each argument directly into the slot after the previous one.
	// Commas are the required argument separators. A trailing comma before `)` is accepted.
	arg_count := 0
	if !at_token(.RIGHT_PAREN) {
		for {
			parse_expression_into(callee_slot + 1 + arg_count, 1)
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
	emit_call(callee_slot, arg_count, requested_results)
}

parse_expression_into :: proc(dst: int, requested_results: int = 1) {
	parse_primary_into(dst)

	if at_token(.LEFT_PAREN) {
		parse_call(dst, requested_results)
	}
}


// Statements =====================================================================================

parse_local_declaration :: proc() {
	name_token := consume_token(.IDENT, "expected local name")
	name, _ := name_token.value.(string)

	consume_token(.DECL, "expected ':=' after local name")

	slot := declare_local(name)
	parse_expression_into(slot)
}

parse_assignment :: proc() {
	name_token := consume_token(.IDENT, "expected assignment name")
	name, _ := name_token.value.(string)

	slot, is_local := resolve_local(name)
	if !is_local {
		panic(fmt.tprintf(
			"parser error at %d:%d offset %d: assignment target is not a local",
			name_token.line,
			name_token.column,
			name_token.offset,
		))
	}

	consume_token(.ASSIGN, "expected '=' after assignment name")
	parse_expression_into(slot)
}

parse_expression_statement :: proc() {
	slot := alloc_temp()
	parse_expression_into(slot, 0)
}

parse_statement :: proc() {
	if at_token(.IDENT) && peek_token().kind == .DECL {
		parse_local_declaration()
		return
	}

	if at_token(.IDENT) && peek_token().kind == .ASSIGN {
		parse_assignment()
		return
	}

	parse_expression_statement()
}

parse_top_level_statements :: proc() {
	for !at_token(.EOF) {
		parse_statement()
		reset_temps()
	}
}


// Source compilation =============================================================================

compile_source :: proc(source: string) -> vm.State {
	tokens := scan_source(source)
	defer delete(tokens)

	Parser.tokens = tokens[:]
	Parser.index = 0
	Parser.local_count = 0
	Parser.temp_slot = 0

	begin_proto("entry", 0)
	parse_top_level_statements()

	result_slot := alloc_temp()
	emit_load_nil(result_slot)
	emit_return(result_slot, 1)

	end_proto()
	return build_vm_state()
}
