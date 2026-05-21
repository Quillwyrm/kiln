package main

import "core:fmt"
import bcg "bytecode_gen"
import "vm"

main :: proc() {
    // Pseudo-source:
    //
    // numbers = []
    // push numbers, 10
    // push numbers, 3.5
    // push numbers, true
    //
    // data = {}
    // data["name"] = "kiln"
    // data["count"] = 2
    // data["ok"] = true
    // data["items"] = numbers
    //
    // print(len(numbers))
    // print(data["items"])
    // print(numbers[0])
    // print(numbers)
    // print(data)
    //
    // return len(numbers)

    bcg.begin_proto("bcg_surface", 0)

    c10 := bcg.const_int(10)
    c35 := bcg.const_float(3.5)
    c2 := bcg.const_int(2)
    c0 := bcg.const_int(0)
    print_name := bcg.const_string("print")
    name_key := bcg.const_string("name")
    count_key := bcg.const_string("count")
    ok_key := bcg.const_string("ok")
    items_key := bcg.const_string("items")
    name_value := bcg.const_string("kiln")

    bcg.new_array(1, 3)
    bcg.load_const(10, c10)
    bcg.array_push(1, 10)
    bcg.load_const(10, c35)
    bcg.array_push(1, 10)
    bcg.load_true(10)
    bcg.array_push(1, 10)

    bcg.new_map(3)
    bcg.load_const(10, name_key)
    bcg.load_const(11, name_value)
    bcg.map_set(3, 10, 11)
    bcg.load_const(10, count_key)
    bcg.load_const(11, c2)
    bcg.map_set(3, 10, 11)
    bcg.load_const(10, ok_key)
    bcg.load_true(11)
    bcg.map_set(3, 10, 11)
    bcg.load_const(10, items_key)
    bcg.map_set(3, 10, 1)

    bcg.array_len(5, 1)
    bcg.load_const(10, items_key)
    bcg.map_get(7, 3, 10)
    bcg.load_const(10, c0)
    bcg.array_get(9, 1, 10)

    bcg.get_global(20, print_name)
    bcg.move(21, 5)
    bcg.call(20, 1, 0)

    bcg.get_global(20, print_name)
    bcg.move(21, 7)
    bcg.call(20, 1, 0)

    bcg.get_global(20, print_name)
    bcg.move(21, 9)
    bcg.call(20, 1, 0)

    bcg.get_global(20, print_name)
    bcg.move(21, 1)
    bcg.call(20, 1, 0)

    bcg.get_global(20, print_name)
    bcg.move(21, 3)
    bcg.call(20, 1, 0)

    bcg.return_values(5, 1)

    bcg.end_proto()

    kiln_state := bcg.build_vm_state()

    result := vm.run_vm(&kiln_state)
    fmt.printf("bytecode_gen surface: %v\n", result)
}
