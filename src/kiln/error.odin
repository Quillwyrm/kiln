package kiln


// Error state ====================================================================================

// Kiln reports one compile or runtime error per host operation.
// The error string is already the final printable diagnostic.

source_line_col_at :: proc(source: string, offset: int) -> (line: int, column: int) {
    line = 1
    column = 1

    for index := 0; index < offset; index += 1 {
        if source[index] == '\n' {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    return
}

set_error :: proc(text: string) -> string {
    if text == "" {
        panic("set_error called with empty error string")
    }

    Active_State.error_string = text
    return Active_State.error_string
}
