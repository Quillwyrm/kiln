package main

import "core:fmt"
import compiler "compiler"
import "vm"

main :: proc() {
    // Pseudo-source:
    //
    // numbers = [10, 20, 30]
    // numbers[1] = nil
    //
    // player = {
    //     name: "kiln"
    //     hp: 99
    //     alive: true
    // }
    //
    // i = 0
    // sum = 0
    // while i < 5 {
    //     sum = sum + i
    //     i = i + 1
    // }
    //
    // print(numbers)
    // print(player)
    // print(sum)
    //
    // print(length(numbers))
    // print(length(player))
    // print(length("kiln"))
    //
    // print(type(nil))
    // print(type(true))
    // print(type(123))
    // print(type(3.5))
    // print(type("kiln"))
    // print(type(numbers))
    // print(type(player))
    // print(type(print))
    //
    // print(to_string(123))
    // print(to_string(numbers))
    //
    // print(to_number(123))
    // print(to_number(3.5))
    // print(to_number("42"))
    // print(to_number("4.5"))
    // print(to_number("wat"))
    //
    // assert(true, "should not fail")
    //
    // return length(numbers)

    compiler.begin_proto("builtin_surface", 0)

    c10 := compiler.const_int(10)
    c0 := compiler.const_int(0)
    c1 := compiler.const_int(1)
    c5 := compiler.const_int(5)
    c20 := compiler.const_int(20)
    c30 := compiler.const_int(30)
    c99 := compiler.const_int(99)
    c123 := compiler.const_int(123)
    c35 := compiler.const_float(3.5)

    print_binding := compiler.bind_global("print")
    length_binding := compiler.bind_global("length")
    type_binding := compiler.bind_global("type")
    assert_binding := compiler.bind_global("assert")
    to_string_binding := compiler.bind_global("to_string")
    to_number_binding := compiler.bind_global("to_number")

    name_key := compiler.const_string("name")
    hp_key := compiler.const_string("hp")
    alive_key := compiler.const_string("alive")

    kiln_string := compiler.const_string("kiln")
    text_42 := compiler.const_string("42")
    text_45 := compiler.const_string("4.5")
    text_wat := compiler.const_string("wat")
    assert_message := compiler.const_string("should not fail")

    // numbers = [10, 20, 30]
    compiler.emit_new_array(1, 3)
    compiler.emit_load_const(10, c10)
    compiler.emit_array_push(1, 10)
    compiler.emit_load_const(10, c20)
    compiler.emit_array_push(1, 10)
    compiler.emit_load_const(10, c30)
    compiler.emit_array_push(1, 10)
    compiler.emit_load_nil(10)
    compiler.emit_load_const(11, c1)
    compiler.emit_array_set(1, 10, 11)

    // player = { name: "kiln", hp: 99, alive: true }
    compiler.emit_new_map(2)
    compiler.emit_load_const(10, name_key)
    compiler.emit_load_const(11, kiln_string)
    compiler.emit_map_set(2, 10, 11)
    compiler.emit_load_const(10, hp_key)
    compiler.emit_load_const(11, c99)
    compiler.emit_map_set(2, 10, 11)
    compiler.emit_load_const(10, alive_key)
    compiler.emit_load_true(11)
    compiler.emit_map_set(2, 10, 11)

    // i = 0
    // sum = 0
    // while i < 5 {
    //     sum = sum + i
    //     i = i + 1
    // }
    compiler.emit_load_const(3, c0)
    compiler.emit_load_const(4, c0)
    compiler.emit_load_const(5, c5)
    compiler.emit_load_const(7, c1)

    loop_start := compiler.next_inst_index()
    compiler.emit_less(6, 3, 5)
    loop_exit := compiler.emit_jump_false(6)
    compiler.emit_add(4, 4, 3)
    compiler.emit_add(3, 3, 7)
    compiler.emit_jump(loop_start)
    compiler.patch_jump(loop_exit)

    // print(numbers)
    compiler.emit_get_global(20, print_binding)
    compiler.emit_move(21, 1)
    compiler.emit_call(20, 1, 0)

    // print(player)
    compiler.emit_get_global(20, print_binding)
    compiler.emit_move(21, 2)
    compiler.emit_call(20, 1, 0)

    // print(sum)
    compiler.emit_get_global(20, print_binding)
    compiler.emit_move(21, 4)
    compiler.emit_call(20, 1, 0)

    // print(length(numbers))
    compiler.emit_get_global(20, length_binding)
    compiler.emit_move(21, 1)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(length(player))
    compiler.emit_get_global(20, length_binding)
    compiler.emit_move(21, 2)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(length("kiln"))
    compiler.emit_get_global(20, length_binding)
    compiler.emit_load_const(21, kiln_string)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(nil))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_load_nil(21)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(true))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_load_true(21)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(123))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_load_const(21, c123)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(3.5))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_load_const(21, c35)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type("kiln"))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_load_const(21, kiln_string)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(numbers))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_move(21, 1)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(player))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_move(21, 2)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(type(print))
    compiler.emit_get_global(20, type_binding)
    compiler.emit_get_global(21, print_binding)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_string(123))
    compiler.emit_get_global(20, to_string_binding)
    compiler.emit_load_const(21, c123)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_string(numbers))
    compiler.emit_get_global(20, to_string_binding)
    compiler.emit_move(21, 1)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_number(123))
    compiler.emit_get_global(20, to_number_binding)
    compiler.emit_load_const(21, c123)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_number(3.5))
    compiler.emit_get_global(20, to_number_binding)
    compiler.emit_load_const(21, c35)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_number("42"))
    compiler.emit_get_global(20, to_number_binding)
    compiler.emit_load_const(21, text_42)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_number("4.5"))
    compiler.emit_get_global(20, to_number_binding)
    compiler.emit_load_const(21, text_45)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // print(to_number("wat"))
    compiler.emit_get_global(20, to_number_binding)
    compiler.emit_load_const(21, text_wat)
    compiler.emit_call(20, 1, 1)
    compiler.emit_get_global(30, print_binding)
    compiler.emit_move(31, 20)
    compiler.emit_call(30, 1, 0)

    // assert(true, "should not fail")
    compiler.emit_get_global(20, assert_binding)
    compiler.emit_load_true(21)
    compiler.emit_load_const(22, assert_message)
    compiler.emit_call(20, 2, 1)

    // return length(numbers)
    compiler.emit_get_global(20, length_binding)
    compiler.emit_move(21, 1)
    compiler.emit_call(20, 1, 1)
    compiler.emit_return(20, 1)

    compiler.end_proto()

    kiln_state := compiler.build_vm_state()

    result := vm.run_vm(&kiln_state)
    fmt.printf("builtin surface: %v\n", result)
}
