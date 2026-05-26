package kiln

import "core:fmt"
import "core:os"


// Runtime entry points ===========================================================================

new_state :: proc() -> ^State {
    return new(State)
}

delete_state :: proc(state: ^State) {
    free(state)
}

run_source :: proc(state: ^State, source, source_name: string) -> ^Error {
    Active_State = state
    reset_compile_state(state)

    compile_error := compile_source(state, source, source_name)
    if compile_error != nil {
        return compile_error
    }

    run_vm(state)
    return nil
}

run_file :: proc(state: ^State, path: string) -> ^Error {
    Active_State = state

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        return set_error(path, 0, 0, fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)
    return run_source(state, string(source_bytes), path)
}

debug_run_file :: proc(state: ^State, path: string) -> ^Error {
    Active_State = state

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        return set_error(path, 0, 0, fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)

    fmt.println("source in:")
    fmt.println(string(source_bytes))

    fmt.println("kiln out:")
    return run_source(state, string(source_bytes), path)
}
