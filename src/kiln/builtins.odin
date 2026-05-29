package kiln

import "core:fmt"
import "core:strconv"
import "core:strings"

// Value helpers ==================================================================================

// StringObject owns stable text; callers may pass slices from source or temp strings.
new_string_value :: proc(text: string) -> Value {
    string_object := new(StringObject)
    string_object.header.kind = .STRING
    string_object.data = strings.clone(text)
    return Value(cast(^Object)string_object)
}

value_type_to_string :: proc(value: Value) -> string {
    if value == nil {
        return "nil"
    }

    switch v in value {
    case bool:
        return "bool"
    case i64:
        return "int"
    case f64:
        return "float"
    case ^Object:
        switch v.kind {
        case .STRING:
            return "string"
        case .ARRAY:
            return "array"
        case .MAP:
            return "map"
        case .PROTO_FUNCTION, .NATIVE_FUNCTION:
            return "function"
        }
    }

    panic("unreachable")
}

value_to_string :: proc(value: Value) -> string {
    if value == nil {
        return "nil"
    }

    switch v in value {
    case bool:
        return fmt.tprint(v)
    case i64:
        return fmt.tprint(v)
    case f64:
        return fmt.tprint(v)

    case ^Object:
        switch v.kind {
        case .STRING:
            string_object := cast(^StringObject)v
            return string_object.data

        case .ARRAY:
            array_object := cast(^ArrayObject)v
            parts := make([dynamic]string)

            append(&parts, "[")
            for item_index := 0; item_index < len(array_object.data); item_index += 1 {
                if item_index > 0 {
                    append(&parts, ", ")
                }

                item := array_object.data[item_index]
                item_object, item_is_object := item.(^Object)
                if item_is_object && item_object.kind == .STRING {
                    string_object := cast(^StringObject)item_object
                    append(&parts, "\"")
                    append(&parts, string_object.data)
                    append(&parts, "\"")
                } else {
                    append(&parts, value_to_string(item))
                }
            }
            append(&parts, "]")

            result := strings.concatenate(parts[:])
            delete(parts)
            return result

        case .MAP:
            map_object := cast(^MapObject)v
            parts := make([dynamic]string)

            append(&parts, "{")
            item_index := 0
            for key, item_value in map_object.data {
                if item_index > 0 {
                    append(&parts, ", ")
                }

                append(&parts, "\"")
                append(&parts, key)
                append(&parts, "\": ")

                item_object, item_is_object := item_value.(^Object)
                if item_is_object && item_object.kind == .STRING {
                    string_object := cast(^StringObject)item_object
                    append(&parts, "\"")
                    append(&parts, string_object.data)
                    append(&parts, "\"")
                } else {
                    append(&parts, value_to_string(item_value))
                }

                item_index += 1
            }
            append(&parts, "}")

            result := strings.concatenate(parts[:])
            delete(parts)
            return result

        case .PROTO_FUNCTION:
            return "function()"

        case .NATIVE_FUNCTION:
            return "function()"
        }
    }

    panic("unreachable: value must match one Value variant")
}


// Native builtin implementations =================================================================

native_print :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.print(" ")
        }

        fmt.print(value_to_string(kiln_state.slots[args_base + arg_index]))
    }

    fmt.println()
    return 0
}


native_type :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_type_to_string(value))
    return 1
}


native_length :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    object_header, is_object := value.(^Object)
    if is_object {
        switch object_header.kind {
        case .ARRAY:
            array_object := cast(^ArrayObject)object_header
            kiln_state.slots[return_slot_base] = Value(i64(len(array_object.data)))
            return 1
        case .MAP:
            map_object := cast(^MapObject)object_header
            kiln_state.slots[return_slot_base] = Value(i64(len(map_object.data)))
            return 1
        case .STRING:
            string_object := cast(^StringObject)object_header
            kiln_state.slots[return_slot_base] = Value(i64(len(string_object.data)))
            return 1
        case .PROTO_FUNCTION, .NATIVE_FUNCTION:
        }
    }

    message := fmt.tprintf(
        "`length()` called with invalid argument; expected `array`, `map`, or `string`, got `%s`",
        value_type_to_string(value),
    )
    runtime_error(message)
    return 0
}


native_assert :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    condition := Value{}
    if arg_count >= 1 {
        condition = kiln_state.slots[args_base]
    }

    if value_is_falsey(condition) {
        if arg_count >= 2 {
            message_value := kiln_state.slots[args_base + 1]
            message_object, is_object := message_value.(^Object)
            if is_object && message_object.kind == .STRING {
                string_object := cast(^StringObject)message_object
                runtime_error(string_object.data)
                return 0
            }

            runtime_error(value_to_string(message_value))
            return 0
        }

        runtime_error(
            fmt.tprintf("assertion failed; condition was `%s`", value_to_string(condition)),
        )
        return 0
    }

    kiln_state.slots[return_slot_base] = condition
    return 1
}


native_to_string :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
    return 1
}


// Returns nil on failure instead of erroring.
native_to_number :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    int_value, is_int := value.(i64)
    if is_int {
        kiln_state.slots[return_slot_base] = Value(int_value)
        return 1
    }

    float_value, is_float := value.(f64)
    if is_float {
        kiln_state.slots[return_slot_base] = Value(float_value)
        return 1
    }

    object_header, is_object := value.(^Object)
    if !is_object || object_header.kind != .STRING {
        kiln_state.slots[return_slot_base] = Value{}
        return 1
    }

    string_object := cast(^StringObject)object_header

    parsed_int, is_int_text := strconv.parse_i64(string_object.data)
    if is_int_text {
        kiln_state.slots[return_slot_base] = Value(parsed_int)
        return 1
    }

    parsed_float, is_float_text := strconv.parse_f64(string_object.data)
    if is_float_text {
        kiln_state.slots[return_slot_base] = Value(parsed_float)
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}


// Builtin binding ================================================================================

bind_global_env :: proc(state: ^State) {
    Active_State = state
    bind_native_global("print", native_print)
    bind_native_global("type", native_type)
    bind_native_global("length", native_length)
    bind_native_global("assert", native_assert)
    bind_native_global("to_string", native_to_string)
    bind_native_global("to_number", native_to_number)
}
