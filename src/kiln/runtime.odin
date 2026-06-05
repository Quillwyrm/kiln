package kiln

import "core:fmt"
import "core:os"


// Runtime entry points ===========================================================================

new_state :: proc() -> ^State {
    return new(State)
}

// Heap objects and cloned compile/runtime strings are not walked yet.
// delete_state only releases the State shell until heap tracking exists.
delete_state :: proc(state: ^State) {
    free(state)
}

// run_source selects Active_State, clears previous error, compiles the import graph,
// then executes the entry proto. Imports initialize during compilation.
// When err != nil, result is undefined.
run_source :: proc(state: ^State, source, source_name: string) -> (Value, ^Error) {
    Active_State = state
    state.has_error = false
    state.error = Error{}

    compile_error := compile_source(source, source_name)
    if compile_error != nil {
        return Value{}, compile_error
    }

    vm_result, vm_error := run_proto(state, state.entry_proto)
    if vm_error != nil {
        return vm_result, vm_error
    }

    return vm_result, nil
}

// run_file loads source text from disk and forwards to run_source.
// File read errors use line=0, column=0 because no source location exists yet.
run_file :: proc(state: ^State, path: string) -> (result: Value, err: ^Error) {
    Active_State = state

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        result := Value{}
        location := SourceLocation{source_name = path, line = 0, column = 0}
        return result, set_error(location, fmt.tprintf("failed to read '%s'", path))
    }
    defer delete(source_bytes)
    return run_source(state, string(source_bytes), path)
}


