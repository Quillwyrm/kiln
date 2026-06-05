package kiln


// Error state ====================================================================================

// Kiln reports one compile or runtime error per host operation.

// SourceLocation identifies one source position.
// source_name borrows the active source name or a persistent module id.
SourceLocation :: struct {
    source_name: string,
    line:        int,
    column:      int,
}

// Converts a source byte offset into persistent one-based diagnostic coordinates.
source_location_at :: proc(source_name, source: string, offset: int) -> SourceLocation {
    line := 1
    column := 1

    for index := 0; index < offset; index += 1 {
        if source[index] == '\n' {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    return SourceLocation{
        source_name = source_name,
        line        = line,
        column      = column,
    }
}

// Error is the current operation diagnostic surfaced to the host.
// Its strings are borrowed and remain valid for the current host operation.
Error :: struct {
    location:     SourceLocation,
    runtime_context: string, // function context, e.g. "in helper()"
    message:      string,
}

// Each state keeps one active error slot; subsequent errors overwrite.
set_error :: proc(location: SourceLocation, message: string, context_text: string = "") -> ^Error {
    Active_State.has_error = true
    Active_State.error = Error{
        location    = location,
        runtime_context = context_text,
        message      = message,
    }
    return &Active_State.error
}
