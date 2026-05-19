package vm

import "core:fmt"

native_print :: proc(
    vm: ^vmState,
    args_base: int,
    arg_count: int,
    return_slot_base: int,
    wanted_result_count: int,
) -> int {
    _ = return_slot_base
    _ = wanted_result_count

    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
        if arg_index > 0 {
            fmt.printf(" ")
        }

        argument := vm.slots[args_base + arg_index]

        int_value, is_int := argument.(i64)
        if is_int {
            fmt.printf("%d", int_value)
            continue
        }

        float_value, is_float := argument.(f64)
        if is_float {
            fmt.printf("%v", float_value)
            continue
        }

        bool_value, is_bool := argument.(bool)
        if is_bool {
            fmt.printf("%v", bool_value)
            continue
        }

        object_header, is_object := argument.(^ObjectHeader)
        if is_object {
            if object_header.kind == .STRING {
                string_object := cast(^StringObject)object_header
                fmt.printf("%s", string_object.text)
                continue
            }

            fmt.printf("<object:%v>", object_header.kind)
            continue
        }

        fmt.printf("nil")
    }

    fmt.println()
    return 0
}

main :: proc() {
    const_pool := [?]Value{
        Value(i64(20)), // const[0]
        Value(i64(22)), // const[1]
    }

    bytecode := [?]u32{                               // SOURCE        ; VM
        u32(InstABx{ op=.LOAD_CONST, a=0, b=0    }), // a = 20        ; r0 = const[0]
        u32(InstABx{ op=.LOAD_CONST, a=1, b=1    }), // b = 22        ; r1 = const[1]
        u32(InstABC{ op=.ADD,        a=2, b=0, c=1 }), // a+b       ; r2 = r0 + r1
        u32(InstABx{ op=.RETURN,     a=2, b=1    }), // return r2     ; return r2
    }

    entry_proto := FunctionProto{
        name             = "entry",
        bytecode         = bytecode[:],
        const_pool       = const_pool[:],
        frame_slot_count = 3,
        param_count      = 0,
    }

    entry_function := FunctionProtoObject{
        header = ObjectHeader{kind = .FUNCTION_PROTO},
        name   = "entry",
        proto  = &entry_proto,
    }

    functions := [?]^ObjectHeader{
        &entry_function.header,
    }

    state := vmState{
        functions = functions[:],
    }

    result := run_vm(&state)
    fmt.printf("bytecode test: %v\n", result)
}
