package compiler

TokenKind :: enum {
	EOF,
	IDENT,
	INT,
	FLOAT,
	STRING,

	TRUE,
	FALSE,
	NIL,

	IF,
	ELSE,
	FOR,
	FUNCTION,
	RETURN,

	DECLARE,       // :=
	ASSIGN,        // =

	PLUS,
	MINUS,
	STAR,
	SLASH,

	EQUAL,
	NOT_EQUAL,
	LESS,
	LESS_EQUAL,
	GREATER,
	GREATER_EQUAL,

	LEFT_PAREN,
	RIGHT_PAREN,
	LEFT_BRACE,
	RIGHT_BRACE,
	LEFT_BRACKET,
	RIGHT_BRACKET,

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
}
