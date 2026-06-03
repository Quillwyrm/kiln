// Test host for development. Creates a state, binds builtins, runs test.kiln, prints errors or results.
// Not the general embedding API — see runtime.odin for the host-facing entry points.
package main

import "core:fmt"
import "kiln"

main :: proc() {

    kstate := kiln.new_state()
    defer kiln.delete_state(kstate)

    kiln.bind_global_env(kstate)

    result, err := kiln.run_file(kstate, "test.kiln")
    if err != nil {
        name    := err.location.source_name
        line    := err.location.line
        col     := err.location.column
        run_ctx := err.runtime_context
        msg     := err.message

        if err.runtime_context != "" {
            fmt.eprintfln("%s[%d:%d] Error %s: %s", name, line, col, run_ctx, msg)
        } else {
            fmt.eprintfln("%s[%d:%d] Error: %s", name, line, col, msg)
        }
        return
    }

    fmt.println("kiln returns:", kiln.value_to_string(result))
}
