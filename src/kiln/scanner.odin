package kiln

import "core:fmt"
import "core:strconv"


// Tokens =========================================================================================

TokenKind :: enum {
	// Stream markers
	EOF,

	// Literals
	IDENT,
	INT,
	FLOAT,
	STRING,

	// Literal keywords
	TRUE,
	FALSE,
	NIL,

	// Control flow
	IF,
	ELSE,
	FOR,
	FUNCTION,
	RETURN,

	// Binding / construction keywords
	GLOBAL,
	MAP,

	// Binding operators
	DECL,       // :=
	CONST_DECL, // ::
	ASSIGN,     // =

	// Arithmetic operators
	PLUS,
	MINUS,
	STAR,
	SLASH,

	// Comparison / logical operators
	EQUAL,
	NOT,
	NOT_EQUAL,
	LESS,
	LESS_OR_EQUAL,
	GREATER,
	GREATER_OR_EQUAL,

	// Delimiters
	LEFT_PAREN,
	RIGHT_PAREN,
	LEFT_BRACE,
	RIGHT_BRACE,
	LEFT_BRACKET,
	RIGHT_BRACKET,

	// Separators / access
	COMMA,
	DOT,
	COLON,
	SEMICOLON,
}

TokenValue :: union {
	i64,
	f64,
	string,
}

Token :: struct {
	kind:  TokenKind,
	value: TokenValue,

	offset: int, // byte index where this token begins in source
	line:   int, // 1-based source line where this token begins
	column: int, // 1-based source column where this token begins
}


// Source state ===================================================================================

Source_State := struct {
	source: string,
	source_name: string,

	// Moving scanner cursor. `index` is a byte index into `source`.
	index:  int,
	line:   int,
	column: int,

	// Start position of the token currently being scanned.
	token_start:  int,
	token_line:   int,
	token_column: int,

	tokens: [dynamic]Token,
	token_index: int,
	failed: bool,
}{}


// Cursor =========================================================================================

advance :: proc() -> u8 {
	ch := Source_State.source[Source_State.index]
	Source_State.index += 1

	if ch == '\n' {
		Source_State.line += 1
		Source_State.column = 1
	} else {
		Source_State.column += 1
	}

	return ch
}

begin_token :: proc() {
	Source_State.token_start = Source_State.index
	Source_State.token_line = Source_State.line
	Source_State.token_column = Source_State.column
}

match_next :: proc(expected: u8) -> bool {
	if Source_State.index >= len(Source_State.source) {
		return false
	}

	if Source_State.source[Source_State.index] != expected {
		return false
	}

	advance()
	return true
}


// Emit ===========================================================================================

scanner_error :: proc(message: string) {
	set_error(Source_State.source_name, Source_State.token_line, Source_State.token_column, message)
	Source_State.failed = true
}

emit_token :: proc(kind: TokenKind, value: TokenValue = {}) {
	append(&Source_State.tokens, Token {
		kind   = kind,
		value  = value,
		offset = Source_State.token_start,
		line   = Source_State.token_line,
		column = Source_State.token_column,
	})
}


// Character classes =============================================================================

is_alpha :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_ident_char :: proc(ch: u8) -> bool {
	return is_alpha(ch) || is_digit(ch) || ch == '_'
}


// Token scans ====================================================================================

scan_ident_or_keyword :: proc() {
	// Identifiers and keywords share the same character rule.
	for Source_State.index < len(Source_State.source) {
		ch := Source_State.source[Source_State.index]
		if !is_ident_char(ch) {
			break
		}
		advance()
	}

	text := Source_State.source[Source_State.token_start:Source_State.index]

	switch text {
	case "true":
		emit_token(.TRUE)
	case "false":
		emit_token(.FALSE)
	case "nil":
		emit_token(.NIL)
	case "if":
		emit_token(.IF)
	case "else":
		emit_token(.ELSE)
	case "for":
		emit_token(.FOR)
	case "function":
		emit_token(.FUNCTION)
	case "return":
		emit_token(.RETURN)
	case "global":
		emit_token(.GLOBAL)
	case "map":
		emit_token(.MAP)
	case:
		emit_token(.IDENT, TokenValue(text))
	}
}

scan_number :: proc() {
	// First pass numbers are decimal integers, hex integers, or decimal floats. No octal or exponent form yet.
	if Source_State.index + 1 < len(Source_State.source) &&
	   Source_State.source[Source_State.index] == '0' &&
	   Source_State.source[Source_State.index + 1] == 'x' {
		advance()
		advance()

		hex_start := Source_State.index
		for Source_State.index < len(Source_State.source) {
			ch := Source_State.source[Source_State.index]
			is_hex_digit := ('0' <= ch && ch <= '9') ||
			                ('a' <= ch && ch <= 'f') ||
			                ('A' <= ch && ch <= 'F')
			if !is_hex_digit {
				break
			}
			advance()
		}

		if Source_State.index == hex_start {
			scanner_error("expected hex digits after 0x")
			return
		}

		if Source_State.index < len(Source_State.source) && is_ident_char(Source_State.source[Source_State.index]) {
			scanner_error("number literal cannot be followed by identifier characters")
			return
		}

		text := Source_State.source[hex_start:Source_State.index]
		value, ok := strconv.parse_i64_of_base(text, 16)
		if !ok {
			scanner_error(fmt.tprintf("failed to parse hex literal %q", text))
			return
		}
		emit_token(.INT, TokenValue(value))
		return
	}

	is_float := false
	if Source_State.source[Source_State.index] == '.' {
		is_float = true
		advance()
	}

	for Source_State.index < len(Source_State.source) {
		ch := Source_State.source[Source_State.index]
		if !is_digit(ch) {
			break
		}
		advance()
	}

	// Treat `123.foo` as INT DOT IDENT, not a malformed float.
	if Source_State.index + 1 < len(Source_State.source) &&
	   Source_State.source[Source_State.index] == '.' &&
	   is_digit(Source_State.source[Source_State.index + 1]) {
		is_float = true
		advance()

		for Source_State.index < len(Source_State.source) {
			ch := Source_State.source[Source_State.index]
			if !is_digit(ch) {
				break
			}
			advance()
		}
	}

	text := Source_State.source[Source_State.token_start:Source_State.index]
	if Source_State.index < len(Source_State.source) && is_ident_char(Source_State.source[Source_State.index]) {
		scanner_error("number literal cannot be followed by identifier characters")
		return
	}

	if is_float {
		value, ok := strconv.parse_f64(text)
		if !ok {
			scanner_error(fmt.tprintf("failed to parse float literal %q", text))
			return
		}
		emit_token(.FLOAT, TokenValue(value))
		return
	}

	value, ok := strconv.parse_i64(text)
	if !ok {
		scanner_error(fmt.tprintf("failed to parse int literal %q", text))
		return
	}
	emit_token(.INT, TokenValue(value))
}

scan_string :: proc() {
	// First pass strings are plain quoted source slices. Escapes are not interpreted yet.
	advance()
	string_start := Source_State.index

	for Source_State.index < len(Source_State.source) && Source_State.source[Source_State.index] != '"' {
		if Source_State.source[Source_State.index] == '\n' {
			scanner_error("unterminated string")
			return
		}
		advance()
	}

	if Source_State.index >= len(Source_State.source) {
		scanner_error("unterminated string")
		return
	}

	text := Source_State.source[string_start:Source_State.index]
	advance()
	emit_token(.STRING, TokenValue(text))
}

skip_line_comment :: proc() {
	// Comments are source trivia for the compiler path, so they emit no token.
	for Source_State.index < len(Source_State.source) && Source_State.source[Source_State.index] != '\n' {
		advance()
	}
}

scan_symbol :: proc() {
	ch := advance()

	switch ch {
	case ':':
		if match_next('=') {
			emit_token(.DECL)
		} else if match_next(':') {
			emit_token(.CONST_DECL)
		} else {
			emit_token(.COLON)
		}

	case '=':
		if match_next('=') {
			emit_token(.EQUAL)
		} else {
			emit_token(.ASSIGN)
		}

	case '!':
		if match_next('=') {
			emit_token(.NOT_EQUAL)
		} else {
			emit_token(.NOT)
		}

	case '<':
		if match_next('=') {
			emit_token(.LESS_OR_EQUAL)
		} else {
			emit_token(.LESS)
		}

	case '>':
		if match_next('=') {
			emit_token(.GREATER_OR_EQUAL)
		} else {
			emit_token(.GREATER)
		}

	case '+':
		emit_token(.PLUS)
	case '-':
		emit_token(.MINUS)
	case '*':
		emit_token(.STAR)
	case '/':
		if match_next('/') {
			skip_line_comment()
		} else {
			emit_token(.SLASH)
		}

	case '(':
		emit_token(.LEFT_PAREN)
	case ')':
		emit_token(.RIGHT_PAREN)
	case '{':
		emit_token(.LEFT_BRACE)
	case '}':
		emit_token(.RIGHT_BRACE)
	case '[':
		emit_token(.LEFT_BRACKET)
	case ']':
		emit_token(.RIGHT_BRACKET)

	case ',':
		emit_token(.COMMA)
	case '.':
		emit_token(.DOT)
	case ';':
		emit_token(.SEMICOLON)

	case:
		scanner_error(fmt.tprintf("unexpected character %q", rune(ch)))
	}
}


// Source scanning =================================================================================

scan_source :: proc(source, source_name: string) -> (tokens: [dynamic]Token, error: ^Error) {
	// Each scan call starts from fresh source/cursor state.
	Source_State.source = source
	Source_State.source_name = source_name
	Source_State.index = 0
	Source_State.line = 1
	Source_State.column = 1
	Source_State.token_start = 0
	Source_State.token_line = 1
	Source_State.token_column = 1
	Source_State.tokens = make([dynamic]Token, 0, len(source) / 4)
	Source_State.token_index = 0
	Source_State.failed = false

	for Source_State.index < len(Source_State.source) && !Source_State.failed {
		ch := Source_State.source[Source_State.index]

		// Whitespace is non-semantic in Kiln source.
		if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
			advance()
			continue
		}

		begin_token()

		if is_alpha(ch) || ch == '_' {
			scan_ident_or_keyword()
			continue
		}

		if is_digit(ch) {
			scan_number()
			continue
		}

		if ch == '.' && Source_State.index + 1 < len(Source_State.source) && is_digit(Source_State.source[Source_State.index + 1]) {
			scan_number()
			continue
		}

		if ch == '"' {
			scan_string()
			continue
		}

		scan_symbol()
	}

	if Source_State.failed {
		return Source_State.tokens, &Active_State.error
	}

	begin_token()
	emit_token(.EOF)

	return Source_State.tokens, nil
}
