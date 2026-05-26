package kiln


// Error state ====================================================================================

Error :: struct {
	source_name: string,
	line:        int,
	column:      int,
	message:     string,
}



set_error :: proc(source_name: string, line, column: int, message: string) -> ^Error {
	Active_State.error = Error{
		source_name = source_name,
		line        = line,
		column      = column,
		message     = message,
	}
	return &Active_State.error
}
