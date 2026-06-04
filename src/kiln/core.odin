package kiln

import "core:fmt"

// Core environment ===============================================================================

bind_core_env :: proc(state: ^State) {
    Active_State = state
    bind_native_global("print", native_print)
    bind_native_global("type", native_type)
    bind_native_global("length", native_length)
    bind_native_global("assert", native_assert)
    bind_native_global("to_string", native_to_string)
    bind_native_global("to_number", native_to_number)
}

bind_core_modules :: proc(state: ^State) {
    debug_module := bind_native_module(state, "debug")
    bind_native_module_function(state, debug_module, "echo", native_debug_echo)

    array_module := bind_native_module(state, "array")
    bind_native_module_function(state, array_module, "push", native_array_push)
    bind_native_module_function(state, array_module, "pop", native_array_pop)
}


// Debug module ===================================================================================

native_debug_echo :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count == 0 {
        kiln_state.slots[return_slot_base] = Value{}
        return 1
    }

    kiln_state.slots[return_slot_base] = kiln_state.slots[args_base]
    return 1
}


// Array module ===================================================================================

native_array_push :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count != 2 {
        runtime_error(fmt.tprintf("`array.push()` expected 2 arguments, got %d", arg_count))
        return 0
    }

    array_value := kiln_state.slots[args_base]
    array_header, is_object := array_value.(^Object)
    if !is_object || array_header.kind != .ARRAY {
        runtime_error(fmt.tprintf("`array.push()` called with invalid first argument; expected `array`, got `%s`", value_type_to_string(array_value)))
        return 0
    }

    array_object := cast(^ArrayObject)array_header
    value := kiln_state.slots[args_base + 1]
    append(&array_object.data, value)
    return 0
}

native_array_pop :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count != 1 {
        runtime_error(fmt.tprintf("`array.pop()` expected 1 argument, got %d", arg_count))
        return 0
    }

    array_value := kiln_state.slots[args_base]
    array_header, is_object := array_value.(^Object)
    if !is_object || array_header.kind != .ARRAY {
        runtime_error(fmt.tprintf("`array.pop()` called with invalid first argument; expected `array`, got `%s`", value_type_to_string(array_value)))
        return 0
    }

    array_object := cast(^ArrayObject)array_header
    if len(array_object.data) == 0 {
        runtime_error("`array.pop()` called on empty array")
        return 0
    }

    kiln_state.slots[return_slot_base] = pop(&array_object.data)
    return 1
}
