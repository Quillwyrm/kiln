package kiln

import "core:fmt"
import "core:strconv"


// Token model ====================================================================================

// TokenKind is the set of token types emitted by the scanner.
// The parser reads this token stream directly.
TokenKind :: enum {
    // Stream Markers
    ERROR,  // Scanner error; message in TokenValue(string)
    EOF,

    // Literals
    IDENT,
    INT,
    FLOAT,
    STRING,

    // Literal Keywords
    TRUE,
    FALSE,
    NIL,

    // Control Flow
    IF,
    ELSE,
    FOR,
    BREAK,
    FUNCTION,
    RETURN,
    SWITCH,
    CASE,

    // Binding / Construction Keywords
    GLOBAL,
    MAP,
    IMPORT,
    EXPORT,

    // Binding Operators
    DECL,           // :=
    IMMUTABLE_DECL, // ::
    ASSIGN,         // =
    PLUS_ASSIGN,    // +=
    MINUS_ASSIGN,   // -=
    STAR_ASSIGN,    // *=
    SLASH_ASSIGN,   // /=
    MOD_ASSIGN,     // %=

    // Arithmetic Operators
    PLUS,
    MINUS,
    STAR,
    SLASH,
    MOD,

    // Comparison / Logical Operators
    EQUAL,
    NOT,
    AND,
    OR,
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

    // Separators / Access
    COMMA,
    DOT,
    COLON,
    SEMICOLON,
}

// TokenValue stores payload data for IDENT/INT/FLOAT/STRING tokens.
// Other token kinds leave Token.value empty.
TokenValue :: union {
    i64,
    f64,
    string,
}

// Token is one scanned unit plus its source location.
// line and column start at 1 to match printed error locations.
Token :: struct {
    kind:        TokenKind,
    value:       TokenValue,
    source_text: string,

    line:   int, // 1-based source line where this token begins
    column: int, // 1-based source column where this token begins
}

// Scanner state ==================================================================================

// Scanner runs one active scan at a time — it is a package-level singleton.
// The = {} on the struct value instantiates it as the package singleton immediately.
Scanner := struct {
    source: string,
    source_name: string,

    index:  int,
    line:   int,
    column: int,

    token_start:  int,
    token_line:   int,
    token_column: int,

    failed: bool,
}{}

// Cursor helpers =================================================================================

// Also updates line/column tracking. Newline resets column to 1.
advance_char :: proc() -> u8 {
    ch := Scanner.source[Scanner.index]
    Scanner.index += 1

    if ch == '\n' {
        Scanner.line += 1
        Scanner.column = 1
    } else {
        Scanner.column += 1
    }

    return ch
}

begin_token :: proc() {
    Scanner.token_start = Scanner.index
    Scanner.token_line = Scanner.line
    Scanner.token_column = Scanner.column
}

// match_next conditionally consumes one exact following byte.
match_next :: proc(expected: u8) -> bool {
    if Scanner.index >= len(Scanner.source) { return false }

    if Scanner.source[Scanner.index] != expected { return false }

    advance_char()
    return true
}


// Scanner errors =================================================================================

// Latch Scanner.failed and return ERROR token. Does not call set_error — parser handles that.
scanner_error :: proc(message: string) -> Token {
    Scanner.failed = true
    return make_error_token(message)
}


// Token emission =================================================================================

// Uses the current token-start snapshot for position data.
make_token :: proc(kind: TokenKind, value: TokenValue = {}) -> Token {
    return Token {
        kind        = kind,
        value       = value,
        source_text = Scanner.source[Scanner.token_start:Scanner.index],
        line        = Scanner.token_line,
        column      = Scanner.token_column,
    }
}

// Constructs an ERROR token. Does not set Scanner.failed — scanner_error owns that.
make_error_token :: proc(message: string) -> Token {
    return Token {
        kind        = .ERROR,
        value       = TokenValue(message),
        source_text = Scanner.source[Scanner.token_start:Scanner.index],
        line        = Scanner.token_line,
        column      = Scanner.token_column,
    }
}


// Character classes ==============================================================================
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

// scan_ident_or_keyword consumes [A-Za-z_][A-Za-z0-9_]* and maps keywords.
scan_ident_or_keyword :: proc() -> Token {
    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]
        if !is_ident_char(ch) {
            break
        }
        advance_char()
    }

    token_text := Scanner.source[Scanner.token_start:Scanner.index]

    switch token_text {
    case "true":
        return make_token(.TRUE)
    case "false":
        return make_token(.FALSE)
    case "nil":
        return make_token(.NIL)
    case "and":
        return make_token(.AND)
    case "or":
        return make_token(.OR)
    case "if":
        return make_token(.IF)
    case "else":
        return make_token(.ELSE)
    case "for":
        return make_token(.FOR)
    case "break":
        return make_token(.BREAK)
    case "function":
        return make_token(.FUNCTION)
    case "return":
        return make_token(.RETURN)
    case "switch":
        return make_token(.SWITCH)
    case "case":
        return make_token(.CASE)
    case "global":
        return make_token(.GLOBAL)
    case "map":
        return make_token(.MAP)
    case "import":
        return make_token(.IMPORT)
    case "export":
        return make_token(.EXPORT)
    case:
        return make_token(.IDENT, TokenValue(token_text))
    }
}

// scan_number supports:
// - decimal ints
// - hex ints with 0x prefix
// - decimal floats with optional leading dot (.5)
// Rejected here: exponent forms (1e3), octal, and identifier-suffixed numerics.
scan_number :: proc() -> Token {
    if Scanner.index + 1 < len(Scanner.source) &&
       Scanner.source[Scanner.index] == '0' &&
       Scanner.source[Scanner.index + 1] == 'x' {
        advance_char()
        advance_char()

        hex_start := Scanner.index
        for Scanner.index < len(Scanner.source) {
            ch := Scanner.source[Scanner.index]
            is_hex_digit := ('0' <= ch && ch <= '9') ||
                            ('a' <= ch && ch <= 'f') ||
                            ('A' <= ch && ch <= 'F')
            if !is_hex_digit {
                break
            }
            advance_char()
        }

        if Scanner.index == hex_start {
            return scanner_error("expected hex digits after 0x")
        }

        if Scanner.index < len(Scanner.source) && is_ident_char(Scanner.source[Scanner.index]) {
            return scanner_error("number literal must be separated from following identifier")
        }

        hex_digits := Scanner.source[hex_start:Scanner.index]
        value, ok := strconv.parse_i64_of_base(hex_digits, 16)
        if !ok {
            return scanner_error(fmt.tprintf("failed to parse hex literal '%s'", hex_digits))
        }
        return make_token(.INT, TokenValue(value))
    }

    is_float := false
    if Scanner.source[Scanner.index] == '.' {
        is_float = true
        advance_char()
    }

    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]
        if !is_digit(ch) {
            break
        }
        advance_char()
    }

    // Reject bare leading zeros on decimal literals (e.g. 042).
    if Scanner.source[Scanner.token_start] == '0' && Scanner.index - Scanner.token_start > 1 {
        token_text := Scanner.source[Scanner.token_start:Scanner.index]
        return scanner_error(fmt.tprintf("integer literal '%s' has leading zeros", token_text))
    }

    // Keep 123.foo tokenized as INT DOT IDENT.
    if Scanner.index + 1 < len(Scanner.source) &&
       Scanner.source[Scanner.index] == '.' &&
       is_digit(Scanner.source[Scanner.index + 1]) {
        is_float = true
        advance_char()

        for Scanner.index < len(Scanner.source) {
            ch := Scanner.source[Scanner.index]
            if !is_digit(ch) {
                break
            }
            advance_char()
        }
    }

    if Scanner.index < len(Scanner.source) && is_ident_char(Scanner.source[Scanner.index]) {
        return scanner_error("number literal must be separated from following identifier")
    }

    if is_float {
        token_text := Scanner.source[Scanner.token_start:Scanner.index]
        value, ok := strconv.parse_f64(token_text)
        if !ok {
            return scanner_error(fmt.tprintf("failed to parse float literal '%s'", token_text))
        }
        return make_token(.FLOAT, TokenValue(value))
    }

    token_text := Scanner.source[Scanner.token_start:Scanner.index]
    value, ok := strconv.parse_i64(token_text)
    if !ok {
        return scanner_error(fmt.tprintf("failed to parse int literal '%s'", token_text))
    }
    return make_token(.INT, TokenValue(value))
}

// No escape decoding — backslash sequences are literal.
scan_string :: proc() -> Token {
    advance_char()
    string_start := Scanner.index

    for Scanner.index < len(Scanner.source) && Scanner.source[Scanner.index] != '"' {
        if Scanner.source[Scanner.index] == '\n' {
            return scanner_error("unterminated string")
        }
        advance_char()
    }

    if Scanner.index >= len(Scanner.source) {
        return scanner_error("unterminated string")
    }

    str_content := Scanner.source[string_start:Scanner.index]
    advance_char()
    return make_token(.STRING, TokenValue(str_content))
}

// Emits no token — comments are not preserved in the token stream.
skip_line_comment :: proc() {
    for Scanner.index < len(Scanner.source) && Scanner.source[Scanner.index] != '\n' {
        advance_char()
    }
}

// Handles both single-character and two-character punctuation/operator forms.
scan_symbol :: proc() -> Token {
    ch := advance_char()

    switch ch {
    case ':':
        if match_next('=') {
            return make_token(.DECL)
        } else if match_next(':') {
            return make_token(.IMMUTABLE_DECL)
        } else {
            return make_token(.COLON)
        }

    case '=':
        if match_next('=') {
            return make_token(.EQUAL)
        } else {
            return make_token(.ASSIGN)
        }

    case '!':
        if match_next('=') {
            return make_token(.NOT_EQUAL)
        } else {
            return make_token(.NOT)
        }

    case '<':
        if match_next('=') {
            return make_token(.LESS_OR_EQUAL)
        } else {
            return make_token(.LESS)
        }

    case '>':
        if match_next('=') {
            return make_token(.GREATER_OR_EQUAL)
        } else {
            return make_token(.GREATER)
        }

    case '+':
        if match_next('=') {
            return make_token(.PLUS_ASSIGN)
        }
        return make_token(.PLUS)
    case '-':
        if match_next('=') {
            return make_token(.MINUS_ASSIGN)
        }
        return make_token(.MINUS)
    case '*':
        if match_next('=') {
            return make_token(.STAR_ASSIGN)
        }
        return make_token(.STAR)
    case '/':
        if match_next('=') {
            return make_token(.SLASH_ASSIGN)
        }
        return make_token(.SLASH)
    case '%':
        if match_next('=') {
            return make_token(.MOD_ASSIGN)
        }
        return make_token(.MOD)

    case '(':
        return make_token(.LEFT_PAREN)
    case ')':
        return make_token(.RIGHT_PAREN)
    case '{':
        return make_token(.LEFT_BRACE)
    case '}':
        return make_token(.RIGHT_BRACE)
    case '[':
        return make_token(.LEFT_BRACKET)
    case ']':
        return make_token(.RIGHT_BRACKET)

    case ',':
        return make_token(.COMMA)
    case '.':
        return make_token(.DOT)
    case ';':
        return make_token(.SEMICOLON)

    case:
        return scanner_error(fmt.tprintf("unexpected character '%c'", ch))
    }
}


// Source scanning ================================================================================

begin_scan :: proc(source, source_name: string) {
    Scanner.source = source
    Scanner.source_name = source_name
    Scanner.index = 0
    Scanner.line = 1
    Scanner.column = 1
    Scanner.token_start = 0
    Scanner.token_line = 1
    Scanner.token_column = 1
    Scanner.failed = false
}

scan_next_token :: proc() -> Token {
    if Scanner.failed {
        begin_token()
        return make_token(.EOF)
    }

    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]
        if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
            advance_char()
            continue
        }
        if ch == '/' && Scanner.index + 1 < len(Scanner.source) && Scanner.source[Scanner.index + 1] == '/' {
            skip_line_comment()
            continue
        }
        break
    }

    if Scanner.index >= len(Scanner.source) {
        begin_token()
        return make_token(.EOF)
    }

    begin_token()
    ch := Scanner.source[Scanner.index]

    if is_alpha(ch) || ch == '_' {
        return scan_ident_or_keyword()
    }

    if is_digit(ch) {
        return scan_number()
    }

    if ch == '.' && Scanner.index + 1 < len(Scanner.source) && is_digit(Scanner.source[Scanner.index + 1]) {
        return scan_number()
    }

    if ch == '"' {
        return scan_string()
    }

    return scan_symbol()
}
