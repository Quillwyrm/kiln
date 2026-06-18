package kiln

import "core:fmt"
import "core:strconv"
import "core:strings"
// Value helpers ==================================================================================

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
    parts := make([dynamic]string)
    parents := make([dynamic]^Object)

    append_value_string(&parts, value, &parents)

    result := strings.concatenate(parts[:])
    delete(parts)
    delete(parents)
    return result
}

// parents tracks array/map objects currently being formatted above this value.
// Seeing one again means a cycle, so print [...] or {...}.
append_value_string :: proc(parts: ^[dynamic]string, value: Value, parents: ^[dynamic]^Object) {
    if value == nil {
        append(parts, "nil")
        return
    }

    switch v in value {
    case bool:
        append(parts, fmt.tprint(v))
        return
    case i64:
        append(parts, fmt.tprint(v))
        return
    case f64:
        text := fmt.tprintf("%g", v)
        append(parts, text)

        for i := 0; i < len(text); i += 1 {
            if i == 0 && text[i] == '-' {
                continue
            }
            if text[i] < '0' || text[i] > '9' {
                return
            }
        }

        append(parts, ".0")
        return

    case ^Object:
        switch v.kind {
        case .STRING:
            string_object := cast(^StringObject)v
            append(parts, string_object.data)
            return

        case .ARRAY:
            for i := 0; i < len(parents); i += 1 {
                if parents[i] == v {
                    append(parts, "[...]")
                    return
                }
            }
            append(parents, v)

            array_object := cast(^ArrayObject)v

            append(parts, "[")
            for item_index := 0; item_index < len(array_object.data); item_index += 1 {
                if item_index > 0 {
                    append(parts, ", ")
                }

                item := array_object.data[item_index]
                item_object, item_is_object := item.(^Object)
                if item_is_object && item_object.kind == .STRING {
                    string_object := cast(^StringObject)item_object
                    append(parts, "\"")
                    append(parts, string_object.data)
                    append(parts, "\"")
                } else {
                    append_value_string(parts, item, parents)
                }
            }
            append(parts, "]")

            pop(parents)
            return

        case .MAP:
            for i := 0; i < len(parents); i += 1 {
                if parents[i] == v {
                    append(parts, "{...}")
                    return
                }
            }
            append(parents, v)

            map_object := cast(^MapObject)v

            append(parts, "{")
            item_index := 0
            for entry in map_object.entries {
                if entry.key == nil {
                    continue
                }
                if item_index > 0 {
                    append(parts, ", ")
                }

                append(parts, "\"")
                append(parts, entry.key.data)
                append(parts, "\": ")

                item_object, item_is_object := entry.value.(^Object)
                if item_is_object && item_object.kind == .STRING {
                    string_object := cast(^StringObject)item_object
                    append(parts, "\"")
                    append(parts, string_object.data)
                    append(parts, "\"")
                } else {
                    append_value_string(parts, entry.value, parents)
                }

                item_index += 1
            }
            append(parts, "}")

            pop(parents)
            return

        case .PROTO_FUNCTION, .NATIVE_FUNCTION:
            append(parts, "function()")
            return
        }
    }

    panic("unreachable: value must match one Value variant")
}


// Native builtin implementations =================================================================

native_print :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.print(" ")
        }

        fmt.print(value_to_string(kiln_state.slots[args_base + arg_index]))
    }

    fmt.println()
    return 0
}


native_type :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `type()`: expected 1, got %d", arg_count))
        return 0
    }

    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(value_type_to_string(value)))
    return 1
}


native_length :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `length()`: expected 1, got %d", arg_count))
        return 0
    }

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
            kiln_state.slots[return_slot_base] = Value(i64(map_object.count))
            return 1
        case .STRING:
            string_object := cast(^StringObject)object_header
            kiln_state.slots[return_slot_base] = Value(i64(len(string_object.data)))
            return 1
        case .PROTO_FUNCTION, .NATIVE_FUNCTION:
        }
    }

    message := fmt.tprintf("`length()` called with invalid argument; expected `array`, `map`, or `string`, got `%s`", value_type_to_string(value))
    runtime_error(message)
    return 0
}


native_assert :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `assert()`: expected 2, got %d", arg_count))
        return 0
    }

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

        runtime_error(fmt.tprintf("assertion failed; condition was `%s`", value_to_string(condition)))
        return 0
    }

    kiln_state.slots[return_slot_base] = condition
    return 1
}


native_to_string :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `to_string()`: expected 1, got %d", arg_count))
        return 0
    }

    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    object, is_object := value.(^Object)
    if is_object && object.kind == .STRING {
        kiln_state.slots[return_slot_base] = value
        return 1
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(value_to_string(value)))
    return 1
}


// Returns nil on failure instead of erroring.
native_to_number :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `to_number()`: expected 1, got %d", arg_count))
        return 0
    }

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
