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
    CONCAT,
    ELLIPSIS,
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

// TokenValue stores payload data for IDENT/INT/FLOAT/STRING/ERROR tokens.
// IDENT and ERROR use string. STRING uses ^StringObject.
// Other token kinds leave Token.value empty.
TokenValue :: union {
    i64,
    f64,
    string,
    ^StringObject,
}

// Token stores semantic scanner output and its source-start byte offset.
Token :: struct {
    kind:  TokenKind,
    value: TokenValue,
    start: int,
}

// Scanner state ==================================================================================

// Scanner runs one active scan at a time; it is a package-level singleton.
Scanner := struct {
    source: string,
    source_name: string,

    index:       int,
    token_start: int,

    failed: bool,
}{}

// Cursor helpers =================================================================================

advance_char :: proc() -> u8 {
    ch := Scanner.source[Scanner.index]
    Scanner.index += 1
    return ch
}

begin_token :: proc() {
    Scanner.token_start = Scanner.index
}

match_next :: proc(expected: u8) -> bool {
    if Scanner.index >= len(Scanner.source) { return false }

    if Scanner.source[Scanner.index] != expected { return false }

    advance_char()
    return true
}


// Scanner errors =================================================================================

// Latches scanner failure and returns an ERROR token for the parser to record.
scanner_error :: proc(message: string) -> Token {
    Scanner.failed = true
    return Token {
        kind  = .ERROR,
        value = TokenValue(message),
        start = Scanner.token_start,
    }
}


// Token emission =================================================================================

make_token :: proc(kind: TokenKind, value: TokenValue = {}) -> Token {
    return Token {
        kind  = kind,
        value = value,
        start = Scanner.token_start,
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

ident_token_kind :: proc(text: string) -> TokenKind {
    switch text {
    case "true":
        return .TRUE
    case "false":
        return .FALSE
    case "nil":
        return .NIL
    case "and":
        return .AND
    case "or":
        return .OR
    case "if":
        return .IF
    case "else":
        return .ELSE
    case "for":
        return .FOR
    case "break":
        return .BREAK
    case "function":
        return .FUNCTION
    case "return":
        return .RETURN
    case "switch":
        return .SWITCH
    case "case":
        return .CASE
    case "global":
        return .GLOBAL
    case "map":
        return .MAP
    case "import":
        return .IMPORT
    case "export":
        return .EXPORT
    }

    return .IDENT
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

    kind := ident_token_kind(token_text)
    if kind != .IDENT {
        return make_token(kind)
    }

    return make_token(.IDENT, TokenValue(token_text))
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
            return scanner_error("invalid number literal; unexpected identifier after number")
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
        return scanner_error("invalid number literal; unexpected identifier after number")
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

// Interpreted strings support: \n, \t, \r, \\, \".
// Literal newlines are rejected; use raw strings for multiline source text.
scan_string :: proc() -> Token {
    advance_char() // opening "
    string_start := Scanner.index

    has_escapes := false
    decoded: [dynamic]byte

    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]

        switch ch {
        case '"':
            if has_escapes {
                advance_char()

                decoded_text := string(decoded[:])
                string_object := new_string_object(decoded_text)

                delete(decoded)
                return make_token(.STRING, TokenValue(string_object))
            }

            str_content := Scanner.source[string_start:Scanner.index]
            advance_char()

            string_object := new_string_object(str_content)
            return make_token(.STRING, TokenValue(string_object))

        case '\n':
            if has_escapes {
                delete(decoded)
            }
            return scanner_error("unterminated string")

        case '\\':
            if !has_escapes {
                has_escapes = true
                decoded = make([dynamic]byte)

                // Copy the no-escape prefix before this first backslash.
                for i := string_start; i < Scanner.index; i += 1 {
                    append(&decoded, Scanner.source[i])
                }
            }

            advance_char() // consume backslash

            if Scanner.index >= len(Scanner.source) {
                delete(decoded)
                return scanner_error("unterminated string")
            }

            escaped := advance_char()
            if escaped == '\n' {
                delete(decoded)
                return scanner_error("unterminated string")
            }

            switch escaped {
            case 'n':
                append(&decoded, '\n')
            case 't':
                append(&decoded, '\t')
            case 'r':
                append(&decoded, '\r')
            case '\\':
                append(&decoded, '\\')
            case '"':
                append(&decoded, '"')
            case:
                delete(decoded)
                return scanner_error(fmt.tprintf("invalid escape sequence '\\%c'", escaped))
            }

        case:
            if has_escapes {
                append(&decoded, ch)
            }
            advance_char()
        }
    }

    if has_escapes {
        delete(decoded)
    }
    return scanner_error("unterminated string")
}

// Raw strings preserve source bytes between backticks.
// Backslashes, double quotes, and literal newlines are ordinary string bytes.
scan_raw_string :: proc() -> Token {
    advance_char() // opening `
    string_start := Scanner.index

    for Scanner.index < len(Scanner.source) {
        ch := Scanner.source[Scanner.index]

        if ch == '`' {
            str_content := Scanner.source[string_start:Scanner.index]
            advance_char()

            string_object := new_string_object(str_content)
            return make_token(.STRING, TokenValue(string_object))
        }

        advance_char()
    }

    return scanner_error("unterminated raw string")
}

// Emits no token; comments are not preserved in the token stream.
skip_line_comment :: proc() {
    for Scanner.index < len(Scanner.source) && Scanner.source[Scanner.index] != '\n' {
        advance_char()
    }
}

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
        if match_next('.') {
            if match_next('.') {
                return make_token(.ELLIPSIS)
            }
            return make_token(.CONCAT)
        }
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
    Scanner.token_start = 0
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

    if ch == '`' {
        return scan_raw_string()
    }

    return scan_symbol()
}
