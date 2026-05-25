package kiln

import "core:fmt"
import "core:os"
import "../compiler"
import "../vm"


// Runtime entry points ===========================================================================

run_source :: proc(source, source_name: string) {
    compiler.reset_state()
    bind_default_globals()

    state := compiler.compile_source(source)
    vm.run_vm(&state)
}

run_file :: proc(path: string) {
    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        panic(fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)
    run_source(string(source_bytes), path)
}

debug_run_file :: proc(path: string) {
    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        panic(fmt.tprintf("failed to read %s", path))
    }
    defer delete(source_bytes)

    fmt.println("source in:")
    fmt.println(string(source_bytes))

    fmt.println("kiln out:")
    run_source(string(source_bytes), path)
}
