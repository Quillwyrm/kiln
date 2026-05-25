package kiln

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../vm"

// Internal Helpers ========================================================================================

value_is_falsey :: proc(value: vm.Value) -> bool {
    bool_value, is_bool := value.(bool)
    if is_bool {
        return !bool_value
    }

    return value == nil
}

new_string_value :: proc(text: string) -> vm.Value {
    string_object := new(vm.StringObject)
    string_object.header.kind = .STRING
    string_object.data = text
    return vm.Value(cast(^vm.Object)string_object)
}

value_to_string :: proc(value: vm.Value) -> string {
    if value == nil {
        return "nil"
    }

    int_value, is_int := value.(i64)
    if is_int {
        return fmt.tprint(int_value)
    }

    float_value, is_float := value.(f64)
    if is_float {
        return fmt.tprint(float_value)
    }

    bool_value, is_bool := value.(bool)
    if is_bool {
        return fmt.tprint(bool_value)
    }

    object_header, is_object := value.(^vm.Object)
    if is_object {
        switch object_header.kind {
        case .STRING:
            string_object := cast(^vm.StringObject)object_header
            parts := [?]string{"\"", string_object.data, "\""}
            return strings.concatenate(parts[:])

        case .ARRAY:
            array_object := cast(^vm.ArrayObject)object_header
            parts := make([dynamic]string)
            append(&parts, "[")
            for item_index := 0; item_index < len(array_object.data); item_index += 1 {
                if item_index > 0 {
                    append(&parts, ", ")
                }
                append(&parts, value_to_string(array_object.data[item_index]))
            }
            append(&parts, "]")
            return strings.concatenate(parts[:])

        case .MAP:
            map_object := cast(^vm.MapObject)object_header
            parts := make([dynamic]string)
            append(&parts, "{")
            item_index := 0
            for key, item_value in map_object.data {
                if item_index > 0 {
                    append(&parts, ", ")
                }
                append(&parts, key)
                append(&parts, ": ")
                append(&parts, value_to_string(item_value))
                item_index += 1
            }
            append(&parts, "}")
            return strings.concatenate(parts[:])

        case .PROTO_FUNCTION:
            return "<object:PROTO_FUNCTION>"

        case .NATIVE_FUNCTION:
            return "<object:NATIVE_FUNCTION>"
        }
    }

    panic("unreachable: value must match one Value variant")
}


// Core builtins ==================================================================================

print_value :: proc(value: vm.Value) {
    if value == nil {
        fmt.print("nil")
        return
    }

    int_value, is_int := value.(i64)
    if is_int {
        fmt.print(int_value)
        return
    }

    float_value, is_float := value.(f64)
    if is_float {
        fmt.print(float_value)
        return
    }

    bool_value, is_bool := value.(bool)
    if is_bool {
        fmt.print(bool_value)
        return
    }

    object_header, is_object := value.(^vm.Object)
    if is_object {
        switch object_header.kind {
        case .STRING:
            string_object := cast(^vm.StringObject)object_header
            fmt.print("\"")
            fmt.print(string_object.data)
            fmt.print("\"")
            return

        case .ARRAY:
            array_object := cast(^vm.ArrayObject)object_header
            fmt.print("[")
            for item_index := 0; item_index < len(array_object.data); item_index += 1 {
                if item_index > 0 {
                    fmt.print(", ")
                }
                print_value(array_object.data[item_index])
            }
            fmt.print("]")
            return

        case .MAP:
            map_object := cast(^vm.MapObject)object_header
            fmt.print("{")
            item_index := 0
            for key, item_value in map_object.data {
                if item_index > 0 {
                    fmt.print(", ")
                }
                fmt.print(key)
                fmt.print(": ")
                print_value(item_value)
                item_index += 1
            }
            fmt.print("}")
            return

        case .PROTO_FUNCTION, .NATIVE_FUNCTION:
            fmt.print("<object:", object_header.kind, ">")
            return
        }
    }

    panic("unreachable: value must match one Value variant")
}

native_print :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.print(" ")
        }

        print_value(kiln_state.slots[args_base + arg_index])
    }

    fmt.println()
    return 0
}


native_type :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count < 1 {
        panic("type expected 1 argument")
    }

    value := kiln_state.slots[args_base]
    if value == nil {
        kiln_state.slots[return_slot_base] = new_string_value("nil")
        return 1
    }

    _, is_bool := value.(bool)
    if is_bool {
        kiln_state.slots[return_slot_base] = new_string_value("bool")
        return 1
    }

    _, is_int := value.(i64)
    if is_int {
        kiln_state.slots[return_slot_base] = new_string_value("int")
        return 1
    }

    _, is_float := value.(f64)
    if is_float {
        kiln_state.slots[return_slot_base] = new_string_value("float")
        return 1
    }

    object_header, is_object := value.(^vm.Object)
    if !is_object {
        panic("unreachable: type expected valid Value")
    }

    switch object_header.kind {
    case .STRING:
        kiln_state.slots[return_slot_base] = new_string_value("string")
    case .ARRAY:
        kiln_state.slots[return_slot_base] = new_string_value("array")
    case .MAP:
        kiln_state.slots[return_slot_base] = new_string_value("map")
    case .PROTO_FUNCTION, .NATIVE_FUNCTION:
        kiln_state.slots[return_slot_base] = new_string_value("function")
    }
    return 1
}


native_length :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count < 1 {
        panic("length expected 1 argument")
    }

    value := kiln_state.slots[args_base]
    object_header, is_object := value.(^vm.Object)
    if !is_object {
        panic("length expected array, map, or string")
    }

    switch object_header.kind {
    case .ARRAY:
        array_object := cast(^vm.ArrayObject)object_header
        kiln_state.slots[return_slot_base] = vm.Value(i64(len(array_object.data)))
        return 1
    case .MAP:
        map_object := cast(^vm.MapObject)object_header
        kiln_state.slots[return_slot_base] = vm.Value(i64(len(map_object.data)))
        return 1
    case .STRING:
        string_object := cast(^vm.StringObject)object_header
        kiln_state.slots[return_slot_base] = vm.Value(i64(len(string_object.data)))
        return 1
    case .PROTO_FUNCTION, .NATIVE_FUNCTION:
        panic("length expected array, map, or string")
    }

    panic("unreachable: length expected known object kind")
}


native_assert :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count < 1 {
        panic("assert expected at least 1 argument")
    }

    condition := kiln_state.slots[args_base]
    if value_is_falsey(condition) {
        if arg_count >= 2 {
            message := value_to_string(kiln_state.slots[args_base + 1])
            panic(message)
        }
        panic("assertion failed")
    }

    kiln_state.slots[return_slot_base] = condition
    return 1
}


native_to_string :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count < 1 {
        panic("to_string expected 1 argument")
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_to_string(kiln_state.slots[args_base]))
    return 1
}


native_to_number :: proc(kiln_state: ^vm.State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    if arg_count < 1 {
        panic("to_number expected 1 argument")
    }

    value := kiln_state.slots[args_base]

    int_value, is_int := value.(i64)
    if is_int {
        kiln_state.slots[return_slot_base] = vm.Value(int_value)
        return 1
    }

    float_value, is_float := value.(f64)
    if is_float {
        kiln_state.slots[return_slot_base] = vm.Value(float_value)
        return 1
    }

    object_header, is_object := value.(^vm.Object)
    if !is_object || object_header.kind != .STRING {
        kiln_state.slots[return_slot_base] = vm.Value{}
        return 1
    }

    string_object := cast(^vm.StringObject)object_header

    parsed_int, is_int_text := strconv.parse_i64(string_object.data)
    if is_int_text {
        kiln_state.slots[return_slot_base] = vm.Value(parsed_int)
        return 1
    }

    parsed_float, is_float_text := strconv.parse_f64(string_object.data)
    if is_float_text {
        kiln_state.slots[return_slot_base] = vm.Value(parsed_float)
        return 1
    }

    kiln_state.slots[return_slot_base] = vm.Value{}
    return 1
}
