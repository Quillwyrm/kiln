package kiln


// Error state ====================================================================================

// Error is the current compile/load error payload surfaced to the host.
Error :: struct {
    source_name: string,
    line:        int,
    column:      int,
    message:     string,
}



// set_error overwrites Active_State.error and returns its address.
// This runtime keeps one active error slot per state.
set_error :: proc(source_name: string, line, column: int, message: string) -> ^Error {
    Active_State.error = Error{
        source_name = source_name,
        line        = line,
        column      = column,
        message     = message,
    }
    return &Active_State.error
}
