package vm

import "core:fmt"

// Test harness ===============================================================================

run_bytecode_test :: proc(name: string, const_pool: []Value, bytecode: []u32, frame_slot_count: int) -> Value {
    // PROGRAM DATA ============================================================================

    entry_proto := FunctionProto{
        name        = name,
        bytecode    = bytecode,
        const_pool  = const_pool,
        frame_slot_count = frame_slot_count,
        param_count = 0,
    }

    entry_function := FunctionProtoObject{
        header = ObjectHeader{kind = .FUNCTION_PROTO},
        name   = entry_proto.name,
        proto  = &entry_proto,
    }

    functions_data := [?]^ObjectHeader{
        &entry_function.header,
    }

    state := vmState{
        functions = functions_data[:],
    }

    // EXECUTE =================================================================================

    return run_vm(&state)
}

run_bytecode_test_with_state :: proc(state: ^vmState) -> Value {
    return run_vm(state)
}

native_print :: proc(
    vm: ^vmState,
    args_base: int,
    arg_count: int,
    return_slot_base: int,
    wanted_result_count: int,
) -> int {

    for arg_index := 0; arg_index < arg_count; arg_index += 1 {
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
    // MATH CASE ===============================================================================

    const_pool_math := [?]Value{
        Value(i64(20)),  // const[0]
        Value(i64(22)),  // const[1]
        Value(f64(2.5)), // const[2]
    }

    bytecode_math := [?]u32{                            // SOURCE             ; VM
        u32(InstABx{ op=.LOAD_CONST, a=0, b=0      }), // a = 20             ; r0 = const[0]
        u32(InstABx{ op=.LOAD_CONST, a=1, b=1      }), // b = 22             ; r1 = const[1]
        u32(InstABx{ op=.LOAD_CONST, a=2, b=2      }), // c = 2.5            ; r2 = const[2]
        u32(InstABC{ op=.ADD,        a=3, b=0, c=1 }), // sum = a + b        ; r3 = r0 + r1
        u32(InstABC{ op=.SUB,        a=4, b=3, c=2 }), // diff = sum - c     ; r4 = r3 - r2
        u32(InstABC{ op=.MUL,        a=5, b=4, c=1 }), // scaled = diff * b  ; r5 = r4 * r1
        u32(InstABC{ op=.DIV,        a=6, b=5, c=1 }), // div = scaled / b   ; r6 = r5 / r1
        u32(InstABx{ op=.NEG,        a=7, b=6      }), // result = -div      ; r7 = -r6
        u32(InstABx{ op=.RETURN,     a=7, b=1      }), // return result      ; return r7
    }
    // EXPECTED: -39.5 =========================================================================

    // IF/ELSE CASE ============================================================================

    const_pool_if_else := [?]Value{
        Value(i64(10)),  // const[0]
        Value(i64(20)),  // const[1]
        Value(i64(111)), // const[2]
        Value(i64(222)), // const[3]
    }

    bytecode_if_else := [?]u32{                            // SOURCE                    ; VM
        u32(InstABx{  op=.LOAD_CONST, a=0, b=0        }), // a = 10                    ; r0 = const[0]
        u32(InstABx{  op=.LOAD_CONST, a=1, b=1        }), // b = 20                    ; r1 = const[1]
        u32(InstABC{  op=.LESS,       a=2, b=0, c=1   }), // cond = a < b              ; r2 = r0 < r1
        u32(InstAsBx{ op=.JUMP_FALSE, a=2, sb=2       }), // if !cond jump else        ; skip next 2 words
        u32(InstABx{  op=.LOAD_CONST, a=3, b=2        }), // then: result = 111        ; r3 = const[2]
        u32(InstJump{ op=.JUMP,       offset=1        }), // jump end                  ; skip else load
        u32(InstABx{  op=.LOAD_CONST, a=3, b=3        }), // else: result = 222        ; r3 = const[3]
        u32(InstABx{  op=.RETURN,     a=3, b=1        }), // return result             ; return r3
    }
    // EXPECTED: 111 ===========================================================================

    // WHILE CASE ==============================================================================

    const_pool_while := [?]Value{
        Value(i64(0)), // const[0]
        Value(i64(5)), // const[1]
        Value(i64(1)), // const[2]
    }

    bytecode_while := [?]u32{                              // SOURCE                  ; VM
        u32(InstABx{  op=.LOAD_CONST, a=0, b=0        }), // i = 0                   ; r0 = const[0]
        u32(InstABx{  op=.LOAD_CONST, a=1, b=0        }), // sum = 0                 ; r1 = const[0]
        u32(InstABx{  op=.LOAD_CONST, a=2, b=1        }), // limit = 5               ; r2 = const[1]
        u32(InstABx{  op=.LOAD_CONST, a=3, b=2        }), // one = 1                 ; r3 = const[2]
        u32(InstABC{  op=.LESS,       a=4, b=0, c=2   }), // cond = i < limit        ; r4 = r0 < r2
        u32(InstAsBx{ op=.JUMP_FALSE, a=4, sb=3       }), // if !cond jump end       ; skip loop body
        u32(InstABC{  op=.ADD,        a=1, b=1, c=0   }), // sum = sum + i           ; r1 = r1 + r0
        u32(InstABC{  op=.ADD,        a=0, b=0, c=3   }), // i = i + one             ; r0 = r0 + r3
        u32(InstJump{ op=.JUMP,       offset=-5       }), // jump loop head          ; back to LESS
        u32(InstABx{  op=.RETURN,     a=1, b=1        }), // return sum              ; return r1
    }
    // EXPECTED: 10 ============================================================================

    // LESS_OR_EQUAL CASE ======================================================================

    const_pool_less_or_equal := [?]Value{
        Value(i64(5)),   // const[0]
        Value(i64(5)),   // const[1]
        Value(i64(900)), // const[2]
        Value(i64(100)), // const[3]
    }

    bytecode_less_or_equal := [?]u32{                          // SOURCE                   ; VM
        u32(InstABx{  op=.LOAD_CONST,    a=0, b=0      }), // a = 5                    ; r0 = const[0]
        u32(InstABx{  op=.LOAD_CONST,    a=1, b=1      }), // b = 5                    ; r1 = const[1]
        u32(InstABC{  op=.LESS_OR_EQUAL, a=2, b=0, c=1 }), // cond = a <= b            ; r2 = r0 <= r1
        u32(InstAsBx{ op=.JUMP_FALSE,    a=2, sb=2     }), // if !cond jump else       ; skip next 2 words
        u32(InstABx{  op=.LOAD_CONST,    a=3, b=2      }), // then: result = 900       ; r3 = const[2]
        u32(InstJump{ op=.JUMP,          offset=1      }), // jump end                 ; skip else load
        u32(InstABx{  op=.LOAD_CONST,    a=3, b=3      }), // else: result = 100       ; r3 = const[3]
        u32(InstABx{  op=.RETURN,        a=3, b=1      }), // return result            ; return r3
    }
    // EXPECTED: 900 ===========================================================================

    // CALL + GLOBAL + NATIVE PRINT CASE ======================================================

    print_name := StringObject{
        header = ObjectHeader{kind = .STRING},
        text   = "print",
    }

    stored_name := StringObject{
        header = ObjectHeader{kind = .STRING},
        text   = "stored",
    }

    hello_text := StringObject{
        header = ObjectHeader{kind = .STRING},
        text   = "hello from native print",
    }

    const_pool_native_print := [?]Value{
        Value(&print_name.header),  // const[0]
        Value(&hello_text.header),  // const[1]
        Value(&stored_name.header), // const[2]
        Value(i64(123)),            // const[3]
    }

    bytecode_native_print := [?]u32{                         // SOURCE                          ; VM
        u32(InstABx{ op=.GET_GLOBAL, a=0, b=0           }), // print_fn = global["print"]      ; r0 = print
        u32(InstABx{ op=.LOAD_CONST, a=1, b=1           }), // msg = "hello..."                ; r1 = const[1]
        u32(InstABC{ op=.CALL,       a=0, b=1, c=0      }), // print(msg)                      ; call r0(r1)
        u32(InstABx{ op=.LOAD_CONST, a=2, b=3           }), // value = 123                     ; r2 = const[3]
        u32(InstABx{ op=.SET_GLOBAL, a=2, b=2           }), // global["stored"] = value        ; set stored
        u32(InstABx{ op=.GET_GLOBAL, a=3, b=2           }), // out = global["stored"]          ; r3 = stored
        u32(InstABx{ op=.RETURN,     a=3, b=1           }), // return out                      ; return r3
    }
    // EXPECTED PRINT: hello from native print
    // EXPECTED RESULT: 123 ====================================================================

    print_function := FunctionNativeObject{
        header      = ObjectHeader{kind = .FUNCTION_NATIVE},
        name        = "print",
        native_proc = native_print,
    }

    entry_proto_native_print := FunctionProto{
        name        = "native_print_entry",
        bytecode    = bytecode_native_print[:],
        const_pool  = const_pool_native_print[:],
        frame_slot_count = 4,
        param_count = 0,
    }

    entry_function_native_print := FunctionProtoObject{
        header = ObjectHeader{kind = .FUNCTION_PROTO},
        name   = "native_print_entry",
        proto  = &entry_proto_native_print,
    }

    functions_native_print := [?]^ObjectHeader{
        &entry_function_native_print.header,
    }

    global_bindings_native_print := [VM_MAX_GLOBALS]GlobalBinding{}
    global_bindings_native_print[0] = GlobalBinding{
        name  = "print",
        value = Value(&print_function.header),
    }

    state_native_print := vmState{
        functions       = functions_native_print[:],
        global_bindings = global_bindings_native_print,
        global_count    = 1,
    }

    // PROTO CALL + RESULT ARITY CASE ==========================================================

    callee_const_pool := [?]Value{
        Value(i64(40)), // const[0]
        Value(i64(2)),  // const[1]
    }

    callee_bytecode := [?]u32{                            // SOURCE                ; VM
        u32(InstABx{ op=.LOAD_CONST, a=0, b=0        }), // r0 = 40               ; first result
        u32(InstABx{ op=.LOAD_CONST, a=1, b=1        }), // r1 = 2                ; second result
        u32(InstABx{ op=.RETURN,     a=0, b=2        }), // return r0, r1         ; produced 2
    }

    callee_proto := FunctionProto{
        name        = "callee_returns_two",
        bytecode    = callee_bytecode[:],
        const_pool  = callee_const_pool[:],
        frame_slot_count = 2,
        param_count = 0,
    }

    entry_bytecode_call_arity := [?]u32{                    // SOURCE                       ; VM
        u32(InstABx{ op=.LOAD_FUNC, a=0, b=1           }), // fn = functions[1]            ; r0 = callee
        u32(InstABC{ op=.CALL,      a=0, b=0, c=3      }), // (r0,r1,r2)=fn()             ; want 3 results
        u32(InstABx{ op=.NOT,       a=3, b=2           }), // third_is_nil = not r2        ; nil -> true
        u32(InstABx{ op=.RETURN,    a=3, b=1           }), // return third_is_nil          ; return r3
    }

    entry_proto_call_arity := FunctionProto{
        name        = "entry_call_arity",
        bytecode    = entry_bytecode_call_arity[:],
        const_pool  = []Value{},
        frame_slot_count = 4,
        param_count = 0,
    }

    entry_function_call_arity := FunctionProtoObject{
        header = ObjectHeader{kind = .FUNCTION_PROTO},
        name   = "entry_call_arity",
        proto  = &entry_proto_call_arity,
    }

    callee_function_call_arity := FunctionProtoObject{
        header = ObjectHeader{kind = .FUNCTION_PROTO},
        name   = "callee_returns_two",
        proto  = &callee_proto,
    }

    functions_call_arity := [?]^ObjectHeader{
        &entry_function_call_arity.header,  // functions[0] = entry
        &callee_function_call_arity.header, // functions[1] = callee
    }

    state_call_arity := vmState{
        functions = functions_call_arity[:],
    }
    // EXPECTED RESULT: true ===================================================================

    fmt.printf("math: %v\n", run_bytecode_test("math", const_pool_math[:], bytecode_math[:], 8))
    fmt.printf("if_else: %v\n", run_bytecode_test("if_else", const_pool_if_else[:], bytecode_if_else[:], 4))
    fmt.printf("while: %v\n", run_bytecode_test("while", const_pool_while[:], bytecode_while[:], 5))
    fmt.printf("less_or_equal: %v\n", run_bytecode_test("less_or_equal", const_pool_less_or_equal[:], bytecode_less_or_equal[:], 4))
    fmt.printf("native_print_globals: %v\n", run_bytecode_test_with_state(&state_native_print))
    fmt.printf("proto_call_arity: %v\n", run_bytecode_test_with_state(&state_call_arity))
}
