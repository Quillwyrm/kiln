package kiln

import "core:fmt"
import "core:os"


// Runtime entry points ===========================================================================

// Runtime state lifecycle for host embedding.
new_state :: proc() -> ^State {
    return new(State)
}

// delete_state currently frees the State shell only.
// Heap-backed runtime objects are not walked until Kiln has heap tracking or GC.
delete_state :: proc(state: ^State) {
    free(state)
}

// run_source is the main host entry for source execution on one state.
// It selects Active_State, clears previous error, compiles, then executes VM.
// When err != nil, result is undefined and should be ignored.
run_source :: proc(state: ^State, source, source_name: string) -> (result: Value, err: ^Error) {
    Active_State = state
    state.has_error = false
    state.error = Error{}

    compile_error := compile_source(source, source_name)
    if compile_error != nil {
        result := Value{}
        return result, compile_error
    }

    vm_result, vm_error := run_vm(state)
    if vm_error != nil {
        return vm_result, vm_error
    }

    return vm_result, nil
}

// run_file loads source text from disk and forwards to run_source.
// File read errors use line=0, column=0 because no source location exists yet.
// When err != nil, result is undefined and should be ignored.
run_file :: proc(state: ^State, path: string) -> (result: Value, err: ^Error) {
    Active_State = state

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        result := Value{}
        location := SourceLocation{source_name = path, line = 0, column = 0}
        return result, set_error(location, fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)
    return run_source(state, string(source_bytes), path)
}

// debug_run_file is a host-facing debug path that prints source and output.
// When err != nil, result is undefined and should be ignored.
debug_run_file :: proc(state: ^State, path: string) -> (result: Value, err: ^Error) {
    Active_State = state

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        result := Value{}
        location := SourceLocation{source_name = path, line = 0, column = 0}
        return result, set_error(location, fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)

    fmt.println("source in:")
    fmt.println(string(source_bytes))

    fmt.println("kiln out:")
    return run_source(state, string(source_bytes), path)
}
