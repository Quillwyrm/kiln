package kiln

import "core:fmt"
import "core:strconv"


// Token model ====================================================================================

// TokenKind is the set of token types emitted by the scanner.
// The parser reads this token stream directly.
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
    BREAK,
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

// TokenValue stores payload data for IDENT/INT/FLOAT/STRING tokens.
// Other token kinds leave Token.value empty.
TokenValue :: union {
    i64,
    f64,
    string,
}

// Token is one scanned unit plus its source location.
// offset is a byte index in source text.
// line and column start at 1 to match printed error locations.
Token :: struct {
    kind:  TokenKind,
    value: TokenValue,

    offset: int, // byte index where this token begins in source
    line:   int, // 1-based source line where this token begins
    column: int, // 1-based source column where this token begins
}

// Scanner state ==================================================================================

// Scanner is the working state used while scanning one source string.
// It stores source text, position, and emitted tokens.
// Current design runs one active scan at a time.
Scanner := struct {
    source: string,
    source_name: string,

    index:  int,
    line:   int,
    column: int,

    token_start:  int,
    token_line:   int,
    token_column: int,

    tokens: [dynamic]Token,
    failed: bool,
}{}

// Cursor helpers =================================================================================

// advance consumes one source byte and updates line/column.
// Newline increments line and resets column to 1.
advance :: proc() -> u8 {
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

// begin_token snapshots the source position where the next token starts.
begin_token :: proc() {
    Scanner.token_start = Scanner.index
    Scanner.token_line = Scanner.line
    Scanner.token_column = Scanner.column
}

// match_next conditionally consumes one exact following byte.
match_next :: proc(expected: u8) -> bool {
    if Scanner.index >= len(Scanner.source) {
        return false
    }

    if Scanner.source[Scanner.index] != expected {
        return false
    }

    advance()
    return true
}


// Token emission =================================================================================

// scanner_error records a compile error at the current token start location.
// Scanner.failed stops scanning after the current step.
scanner_error :: proc(message: string) {
    set_error(Scanner.source_name, Scanner.token_line, Scanner.token_column, message)
    Scanner.failed = true
}

// emit_token appends one token using the current token-start snapshot.
emit_token :: proc(kind: TokenKind, value: TokenValue = {}) {
    append(&Scanner.tokens, Token {
        kind   = kind,
        value  = value,
        offset = Scanner.token_start,
        line   = Scanner.token_line,
        column = Scanner.token_column,
    })
}


// Character classes ==============================================================================

// Character classifiers for first-pass ASCII identifier/number rules.
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
scan_ident_or_keyword :: proc() {
    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]
        if !is_ident_char(ch) {
            break
        }
        advance()
    }

    text := Scanner.source[Scanner.token_start:Scanner.index]

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
    case "break":
        emit_token(.BREAK)
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

// scan_number supports:
// - decimal ints
// - hex ints with 0x prefix
// - decimal floats with optional leading dot (.5)
// Rejected here: exponent forms (1e3), octal, and identifier-suffixed numerics.
scan_number :: proc() {
    if Scanner.index + 1 < len(Scanner.source) &&
       Scanner.source[Scanner.index] == '0' &&
       Scanner.source[Scanner.index + 1] == 'x' {
        advance()
        advance()

        hex_start := Scanner.index
        for Scanner.index < len(Scanner.source) {
            ch := Scanner.source[Scanner.index]
            is_hex_digit := ('0' <= ch && ch <= '9') ||
                            ('a' <= ch && ch <= 'f') ||
                            ('A' <= ch && ch <= 'F')
            if !is_hex_digit {
                break
            }
            advance()
        }

        if Scanner.index == hex_start {
            scanner_error("expected hex digits after 0x")
            return
        }

        if Scanner.index < len(Scanner.source) && is_ident_char(Scanner.source[Scanner.index]) {
            scanner_error("number literal cannot be followed by identifier characters")
            return
        }

        text := Scanner.source[hex_start:Scanner.index]
        value, ok := strconv.parse_i64_of_base(text, 16)
        if !ok {
            scanner_error(fmt.tprintf("failed to parse hex literal %q", text))
            return
        }
        emit_token(.INT, TokenValue(value))
        return
    }

    is_float := false
    if Scanner.source[Scanner.index] == '.' {
        is_float = true
        advance()
    }

    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]
        if !is_digit(ch) {
            break
        }
        advance()
    }

    // Keep 123.foo tokenized as INT DOT IDENT.
    if Scanner.index + 1 < len(Scanner.source) &&
       Scanner.source[Scanner.index] == '.' &&
       is_digit(Scanner.source[Scanner.index + 1]) {
        is_float = true
        advance()

        for Scanner.index < len(Scanner.source) {
            ch := Scanner.source[Scanner.index]
            if !is_digit(ch) {
                break
            }
            advance()
        }
    }

    text := Scanner.source[Scanner.token_start:Scanner.index]
    if Scanner.index < len(Scanner.source) && is_ident_char(Scanner.source[Scanner.index]) {
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

// scan_string consumes a single-line quoted string with no escape decoding.
scan_string :: proc() {
    advance()
    string_start := Scanner.index

    for Scanner.index < len(Scanner.source) && Scanner.source[Scanner.index] != '"' {
        if Scanner.source[Scanner.index] == '\n' {
            scanner_error("unterminated string")
            return
        }
        advance()
    }

    if Scanner.index >= len(Scanner.source) {
        scanner_error("unterminated string")
        return
    }

    text := Scanner.source[string_start:Scanner.index]
    advance()
    emit_token(.STRING, TokenValue(text))
}

// skip_line_comment consumes //... until newline and emits no token.
skip_line_comment :: proc() {
    for Scanner.index < len(Scanner.source) && Scanner.source[Scanner.index] != '\n' {
        advance()
    }
}

// scan_symbol emits punctuation/operators and handles two-character forms.
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


// Source scanning ================================================================================

// scan_source resets Scanner state, emits a full token stream, then EOF.
// Caller owns the returned [dynamic]Token and must delete it.
scan_source :: proc(source, source_name: string) -> (tokens: [dynamic]Token, error: ^Error) {
    Scanner.source = source
    Scanner.source_name = source_name
    Scanner.index = 0
    Scanner.line = 1
    Scanner.column = 1
    Scanner.token_start = 0
    Scanner.token_line = 1
    Scanner.token_column = 1
    Scanner.tokens = make([dynamic]Token, 0, len(source) / 4)
    Scanner.failed = false

    for Scanner.index < len(Scanner.source) && !Scanner.failed {
        ch := Scanner.source[Scanner.index]

        // Whitespace does not emit tokens.
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

        if ch == '.' && Scanner.index + 1 < len(Scanner.source) && is_digit(Scanner.source[Scanner.index + 1]) {
            scan_number()
            continue
        }

        if ch == '"' {
            scan_string()
            continue
        }

        scan_symbol()
    }

    if Scanner.failed {
        return Scanner.tokens, &Active_State.error
    }

    begin_token()
    emit_token(.EOF)

    return Scanner.tokens, nil
}
