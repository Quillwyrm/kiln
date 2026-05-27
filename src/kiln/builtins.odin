package kiln

import "core:fmt"
import "core:strconv"
import "core:strings"

// Value helpers ==================================================================================

// new_string_value allocates a VM string object and wraps it as Value.
// StringObject owns stable text; callers may pass slices from source or temp strings.
new_string_value :: proc(text: string) -> Value {
    string_object := new(StringObject)
    string_object.header.kind = .STRING
    string_object.data = strings.clone(text)
    return Value(cast(^Object)string_object)
}

// value_type_name returns the user-facing type name for one Kiln value.
value_type_name :: proc(value: Value) -> string {
    if value == nil {
        return "nil"
    }

    _, is_bool := value.(bool)
    if is_bool {
        return "bool"
    }

    _, is_int := value.(i64)
    if is_int {
        return "int"
    }

    _, is_float := value.(f64)
    if is_float {
        return "float"
    }

    object_header, is_object := value.(^Object)
    if is_object {
        switch object_header.kind {
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

    panic("unreachable: value must match one Value variant")
}

// value_to_string returns text conversion used by to_string and assert message formatting.
value_to_string :: proc(value: Value) -> string {
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

    object_header, is_object := value.(^Object)
    if is_object {
        switch object_header.kind {
        case .STRING:
            string_object := cast(^StringObject)object_header
            parts := [?]string{"\"", string_object.data, "\""}
            return strings.concatenate(parts[:])

        case .ARRAY:
            array_object := cast(^ArrayObject)object_header
            parts := make([dynamic]string)
            append(&parts, "[")
            for item_index := 0; item_index < len(array_object.data); item_index += 1 {
                if item_index > 0 {
                    append(&parts, ", ")
                }
                append(&parts, value_to_string(array_object.data[item_index]))
            }
            append(&parts, "]")
            result := strings.concatenate(parts[:])
            delete(parts)
            return result

        case .MAP:
            map_object := cast(^MapObject)object_header
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
            result := strings.concatenate(parts[:])
            delete(parts)
            return result

        case .PROTO_FUNCTION:
            return "<object:PROTO_FUNCTION>"

        case .NATIVE_FUNCTION:
            return "<object:NATIVE_FUNCTION>"
        }
    }

    panic("unreachable: value must match one Value variant")
}


// Print formatting ===============================================================================

// print_value is display formatting for builtin print output.
// Formatting is human-facing and may differ from value_to_string representation.
print_value :: proc(value: Value) {
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

    object_header, is_object := value.(^Object)
    if is_object {
        switch object_header.kind {
        case .STRING:
            string_object := cast(^StringObject)object_header
            fmt.print("\"")
            fmt.print(string_object.data)
            fmt.print("\"")
            return

        case .ARRAY:
            array_object := cast(^ArrayObject)object_header
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
            map_object := cast(^MapObject)object_header
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


// Native builtin implementations =================================================================

// Native builtin call contract:
// - args are read from slots starting at args_base
// - results are written starting at return_slot_base
// - returned int is produced result count
// VM CALL shapes produced results to requested_results.
native_print :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.print(" ")
        }

        print_value(kiln_state.slots[args_base + arg_index])
    }

    fmt.println()
    return 0
}


// native_type returns one of:
// "nil", "bool", "int", "float", "string", "array", "map", "function".
native_type :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_type_name(value))
    return 1
}


// native_length supports array/map/string only.
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
		value_type_name(value),
	)
	runtime_error(kiln_state, message)
	return 0
}


// native_assert errors when first arg is falsey (nil or false).
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
                runtime_error(kiln_state, string_object.data)
                return 0
            }

            runtime_error(kiln_state, value_to_string(message_value))
            return 0
        }

		runtime_error(
			kiln_state,
			fmt.tprintf("assertion failed; condition was `%s`", value_to_string(condition)),
		)
		return 0
	}

    kiln_state.slots[return_slot_base] = condition
    return 1
}


// native_to_string converts one value to a string object.
native_to_string :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int {
    value := Value{}
    if arg_count >= 1 {
        value = kiln_state.slots[args_base]
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
    return 1
}


// native_to_number parses int/float/string numeric forms and returns nil on failure.
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

// bind_global_env installs the core native builtin set into global_env.
bind_global_env :: proc(state: ^State) {
    Active_State = state
    bind_native_global("print", native_print)
    bind_native_global("type", native_type)
    bind_native_global("length", native_length)
    bind_native_global("assert", native_assert)
    bind_native_global("to_string", native_to_string)
    bind_native_global("to_number", native_to_number)
}
