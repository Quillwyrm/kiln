package kiln

import "core:fmt"
import vm "../vm"


//TODO: len, type, assert, to_string/to_*

// Printing =======================================================================================

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

    object_header, is_object := value.(^vm.ObjectHeader)
    if is_object {
        switch object_header.kind {
        case .STRING:
            string_object := cast(^vm.StringObject)object_header
            fmt.print("\"")
            fmt.print(string_object.text)
            fmt.print("\"")
            return

        case .ARRAY:
            array_object := cast(^vm.ArrayObject)object_header
            fmt.print("[")
            for item_index := 0; item_index < len(array_object.items); item_index += 1 {
                if item_index > 0 {
                    fmt.print(", ")
                }
                print_value(array_object.items[item_index])
            }
            fmt.print("]")
            return

        case .MAP:
            map_object := cast(^vm.MapObject)object_header
            fmt.print("{")
            item_index := 0
            for key, item_value in map_object.items {
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

        case .FUNCTION_PROTO, .FUNCTION_NATIVE:
            fmt.print("<object:", object_header.kind, ">")
            return
        }
    }

    panic("unreachable: value must match one Value variant")
}

native_print :: proc(
    kiln_state: ^vm.State,
    args_base: int,
    arg_count: int,
    return_slot_base: int,
    wanted_result_count: int,
) -> int {
    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.print(" ")
        }

        print_value(kiln_state.slots[args_base + arg_index])
    }

    fmt.println()
    return 0
}
