package main

import "core:fmt"
import "kiln"

main :: proc() {
	kstate := kiln.new_state()
	defer kiln.delete_state(kstate)

	kiln.bind_global_env(kstate)

	kiln_err := kiln.run_file(kstate, "test.kiln")
	if kiln_err != nil {
		fmt.eprintfln("%s[%d:%d] Error: %s", kiln_err.source_name, kiln_err.line, kiln_err.column, kiln_err.message)
	}
}
