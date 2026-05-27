// Test host for development. Creates a state, binds builtins, runs test.kiln, prints errors or results.
// Not the general embedding API — see runtime.odin for the host-facing entry points.
package main

import "core:fmt"
import "kiln"

main :: proc() {
	kstate := kiln.new_state()
	defer kiln.delete_state(kstate)

	kiln.bind_global_env(kstate)

	kiln_result, kiln_err := kiln.run_file(kstate, "test.kiln")
	if kiln_err != nil {
		if kiln_err.context_text != "" {
			fmt.eprintfln(
				"%s[%d:%d] Error %s: %s",
				kiln_err.location.source_name,
				kiln_err.location.line,
				kiln_err.location.column,
				kiln_err.context_text,
				kiln_err.message,
			)
		} else {
			fmt.eprintfln(
				"%s[%d:%d] Error: %s",
				kiln_err.location.source_name,
				kiln_err.location.line,
				kiln_err.location.column,
				kiln_err.message,
			)
		}
		return
	}

	fmt.println("kiln returns:", kiln.value_to_string(kiln_result))
}
