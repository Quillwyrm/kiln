package kiln

import "core:fmt"
import "core:os"
import filepath "core:path/filepath"


// Runtime entry points ===========================================================================

new_state :: proc() -> ^State {
    state := new(State)
    state.env_count = 1
    return state
}

// Heap objects and cloned compile/runtime strings are not walked yet.
// delete_state only releases the State shell until heap tracking exists.
delete_state :: proc(state: ^State) {
    free(state)
}

// set_argv sets the raw invocation vector and where user script args begin.
set_argv :: proc(state: ^State, argv: []string, args_start: int) {
    state.argv = argv
    state.args_start = args_start
}

// run_source selects Active_State, clears previous error, compiles the import graph,
// then executes the entry proto. Imports initialize during compilation.
// When err != "", result is undefined.
run_source :: proc(state: ^State, source, source_name: string) -> (Value, string) {
    Active_State = state
    state.error_string = ""

    compile_error := compile_source(source, source_name)
    if compile_error != "" {
        return Value{}, compile_error
    }

    vm_result, vm_error := run_proto(state, state.entry_proto)
    if vm_error != "" {
        return vm_result, vm_error
    }

    return vm_result, ""
}

// run_file loads source text from disk and forwards to run_source.
// The path is resolved to canonical form so envs[0].id matches import resolution.
run_file :: proc(state: ^State, path: string) -> (result: Value, err: string) {
    Active_State = state

    resolved_path, abs_err := filepath.abs(path, context.allocator)
    if abs_err != nil {
        result := Value{}
        return result, set_error(fmt.tprintf("Error: failed to resolve path `%s`", path))
    }
    defer delete(resolved_path)

    source_bytes, read_error := os.read_entire_file(resolved_path, context.allocator)
    if read_error != nil {
        result := Value{}
        return result, set_error(fmt.tprintf("Error: failed to read `%s`", resolved_path))
    }
    defer delete(source_bytes)
    return run_source(state, string(source_bytes), resolved_path)
}


