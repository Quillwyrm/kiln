package kiln


// Error state ====================================================================================

// Kiln reports scanner, parser, file-load, and user-facing runtime failures through Error.
// The host owns presentation; Kiln only fills the error payload.
//
// Compile errors usually point at an exact token location.
// Runtime errors currently point at the origin of the running proto/function.
// Exact runtime instruction locations can be added later with bytecode debug tables.
//
// SourceLocation is a durable source position.
// Tokens store line/column directly because a token stream already belongs to one source.
// Errors and protos need the full source name because they can outlive the scanner.
SourceLocation :: struct {
	source_name: string,
	line:        int,
	column:      int,
}

// Error is the current compile/load error payload surfaced to the host.
Error :: struct {
	location:    SourceLocation,
	context_text: string,
	message:     string,
}



// set_error overwrites Active_State.error and returns its address.
// This runtime keeps one active error slot per state.
set_error :: proc(location: SourceLocation, message: string, context_text: string = "") -> ^Error {
	Active_State.has_error = true
	Active_State.error = Error{
		location    = location,
		context_text = context_text,
		message      = message,
	}
	return &Active_State.error
}
