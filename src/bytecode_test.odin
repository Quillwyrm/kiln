package vm

import "core:fmt"

// Test harness ===============================================================================

run_bytecode_test :: proc(name: string, const_pool: []Value, bytecode: []u32, slot_count: int) -> Value {
	// PROGRAM DATA ============================================================================

	entry_proto := FunctionProto{
        name        = name,
        bytecode    = bytecode,
        const_pool  = const_pool,
        slot_count  = slot_count,
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

main :: proc() {
    // MATH CASE ===============================================================================

    const_pool_math := [?]Value{
        Value(i64(20)),  // const[0]
        Value(i64(22)),  // const[1]
        Value(f64(2.5)), // const[2]
    }

    bytecode_math := [?]u32{                           // SOURCE             ; VM
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

    bytecode_if_else := [?]u32{                           // SOURCE                    ; VM
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

    bytecode_while := [?]u32{                             // SOURCE                  ; VM
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

	bytecode_less_or_equal := [?]u32{                         // SOURCE                   ; VM
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

	fmt.printf("math: %v\n", run_bytecode_test("math", const_pool_math[:], bytecode_math[:], 8))
	fmt.printf("if_else: %v\n", run_bytecode_test("if_else", const_pool_if_else[:], bytecode_if_else[:], 4))
	fmt.printf("while: %v\n", run_bytecode_test("while", const_pool_while[:], bytecode_while[:], 5))
	fmt.printf("less_or_equal: %v\n", run_bytecode_test("less_or_equal", const_pool_less_or_equal[:], bytecode_less_or_equal[:], 4))
}
