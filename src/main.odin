package main

import "core:fmt"
import "core:os"
import "compiler"
import "vm"

main :: proc() {
	source_bytes, read_error := os.read_entire_file("test.kiln", context.allocator)
	if read_error != nil {
		panic("failed to read test.kiln")
	}
	defer delete(source_bytes)

	fmt.println("source in:")
	fmt.println(string(source_bytes))

	fmt.println("kiln out:")
	state := compiler.compile_source(string(source_bytes))
	result := vm.run_vm(&state)
}
