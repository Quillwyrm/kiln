package kiln


// Error state ====================================================================================

// Kiln reports one compile or runtime error per host operation.

// SourceLocation identifies a source position. Errors and protos can outlive the
// scanner, so the full source name is stored rather than a token stream reference.
SourceLocation :: struct {
	source_name: string,
	line:        int,
	column:      int,
}

// Error is the current compile or runtime error payload surfaced to the host.
Error :: struct {
	location:     SourceLocation,
	context_text: string, // function context, e.g. "in helper()"
	message:      string,
}

// Each state keeps one active error slot — subsequent errors overwrite.
set_error :: proc(location: SourceLocation, message: string, context_text: string = "") -> ^Error {
	Active_State.has_error = true
	Active_State.error = Error{
		location    = location,
		context_text = context_text,
		message      = message,
	}
	return &Active_State.error
}
