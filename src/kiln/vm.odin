package kiln


// Opcodes ========================================================================================

Opcode :: enum u8 {
    // Immediate, Constant, and Function Loads
    LOAD_NIL,      // Ax: A=dst
    LOAD_TRUE,     // Ax: A=dst
    LOAD_FALSE,    // Ax: A=dst
    LOAD_CONST,    // ABx: A=dst, B=const
    LOAD_FUNC,     // ABx: A=dst, B=child_proto
    MOVE,          // ABx: A=dst, B=src

    // Array Operations
    NEW_ARRAY,     // ABx: A=dst,       B=initial capacity
    ARRAY_LEN,     // ABx: A=dst,       B=src_array
    ARRAY_GET,     // ABC: A=dst,       B=src_array, C=index
    ARRAY_SET,     // ABC: A=dst_array, B=src, C=index
    ARRAY_PUSH,    // ABx: A=dst_array, B=src
    ARRAY_POP,     // ABx: A=dst,       B=src_array

    // Map Operations
    NEW_MAP,       // ABx: A=dst,     B=reserved
    MAP_LEN,       // ABx: A=dst,     B=src_map
    MAP_GET,       // ABC: A=dst,     B=src_map, C=key
    MAP_SET,       // ABC: A=dst_map, B=key, C=src

    // Numeric Operations
    ADD,           // ABC: A=dst, B=lhs, C=rhs
    SUB,           // ABC: A=dst, B=lhs, C=rhs
    MUL,           // ABC: A=dst, B=lhs, C=rhs
    DIV,           // ABC: A=dst, B=lhs, C=rhs
    NEG,           // ABx: A=dst, B=src

    // Comparison and Boolean Operations
    EQUAL,         // ABC: A=dst, B=lhs, C=rhs
    LESS,          // ABC: A=dst, B=lhs, C=rhs
    LESS_OR_EQUAL, // ABC: A=dst, B=lhs, C=rhs
    NOT,           // ABx: A=dst, B=src

    // Control Flow
    JUMP,          // Jump: offset (relative to post-fetch instruction_index)
    JUMP_FALSE,    // AsBx: A=cond, B=offset; jump if slot[A] is falsey
    HALT,          // ABC: no operands used; stop VM and return nil

    // Calls and Returns
    CALL,          // ABC: A=callee/result base, B=arg_count, C=requested_results
    RETURN,        // ABx: A=first_return, B=produced_results

    // Global Bindings
    GET_GLOBAL,    // ABx: A=dst, B=binding_id
    SET_GLOBAL,    // ABx: A=src, B=binding_id
}


// Instruction layout types =======================================================================

// The real bytecode stream stays `[]u32`.
// These types are used to pack and decode instruction words.
// The opcode decides which layout applies to a given instruction word.

InstABC :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    b:  u8     | 8,
    c:  u8     | 8,
}

InstABx :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    b:  u16    | 16, // wide second operand
}

InstAsBx :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    sb: i16    | 16, // signed wide second operand
}

InstAx :: bit_field u32 {
    op: Opcode | 8,
    a:  u32    | 24, // wide unsigned
}

InstJump :: bit_field u32 {
    op:     Opcode | 8,
    offset: i32    | 24, // wide signed jump offset
}


// Heap objects ===================================================================================

// Heap-backed values start with Object.
// Value stores heap-backed values as ^Object and uses kind to recover the full object type.

ObjectKind :: enum u8 {
    STRING,
    PROTO_FUNCTION,
    NATIVE_FUNCTION,
    ARRAY,
    MAP,
}

Object :: struct {
    kind: ObjectKind,
}


// String objects =================================================================================

StringObject :: struct {
    header: Object, // must be first
    data:   string,
}

// Array objects ==================================================================================

ArrayObject :: struct {
    header: Object, // must be first
    data:  [dynamic]Value,
}

// Map objects ====================================================================================

MapObject :: struct {
    header: Object, // must be first
    data:  map[string]Value,
}


// Functions ======================================================================================

// Proto is compiled bytecode function data.
// It is not itself the runtime function value.
// `bytecode` is the fixed instruction stream for the function.
// `const_pool` is the fixed constant table used by that bytecode.
// `child_protos` is the fixed table of function bodies declared inside this proto.
// `frame_slot_count` is the size of the function's slot window.

Proto :: struct {
    source_name: string,
    name:        string,
    bytecode:    []u32,
    const_pool:  []Value,
    child_protos: []^Proto,
    frame_slot_count: int,
    param_count: int,
}

// NativeFunction is an Odin-backed function implementation.
// Args live in vmState.slots starting at args_base.
// Native functions write produced results into state.slots starting at return_slot_base.
// requested_results is the number of result slots the caller wants.
// The returned int is the number of result values the native function produced.
// CALL shapes produced results to requested results, like proto RETURN does:
// missing requested results become nil, and extra produced results are ignored.

NativeFunction :: proc(
    vm: ^State,
    args_base: int,
    arg_count: int,
    return_slot_base: int,
    requested_results: int,
) -> int

// ProtoFunctionObject is a runtime callable object backed by bytecode.
// Values point to this through ^Object when header.kind == .PROTO_FUNCTION.

ProtoFunctionObject :: struct {
    header: Object, // must be first
    name:   string,
    impl:  ^Proto,
}

// NativeFunctionObject is a runtime callable object backed by an Odin procedure.
// Values point to this through ^Object when header.kind == .NATIVE_FUNCTION.

NativeFunctionObject :: struct {
    header:      Object, // must be first
    name:        string,
    impl: NativeFunction,
}


// Value type =====================================================================================

// Nil is the zero value of the union.
// Immediates live inline. Heap-backed values are stored as ^Object.
// Value{} represents language-level nil.

Value :: union {
    bool,
    i64,
    f64,
    ^Object,
}


// Bindings =======================================================================================

MAX_BINDINGS :: 256

BindingId :: distinct int

// BindingTable is a named value namespace.
// BindingId values are indexes into one specific BindingTable.
BindingTable :: struct {
    names:  [MAX_BINDINGS]string,
    values: [MAX_BINDINGS]Value,
    count:  int,
}


// Call frames ====================================================================================

// `slot_base` is the start of this call's slot window inside vmState.slots.
// Logical slots for this frame are addressed relative to that slot base.
// `return_slot_base` and `requested_results` describe where this frame must place return values
// in its caller's slot window. The top-level frame has no caller; top-level RETURN ends execution.
// `caller_slot_count` restores the caller's occupied slot range when this frame returns.

CallFrame :: struct {
    proto:                    ^Proto,
    instruction_index:        int,
    slot_base:                int,

    return_slot_base:         int,
    requested_results:   int,

    caller_slot_count: int,
}


// VM state =======================================================================================

MAX_VM_SLOTS :: 4096
MAX_CALLFRAMES :: 256

// `entry_function` is the top-level function object run by `run_vm`.
// LOAD_FUNC indexes the currently executing proto's child protos.
// CALL dispatches callable objects by Object.kind.
// `slots` is fixed runtime storage for all active call-frame windows.
// `slot_count` is the number of slots claimed by active windows.
// `frame_stack` is fixed runtime storage for active bytecode calls.
// `frame_count` is the number of occupied entries in frame_stack.
// The current frame is frame_stack[frame_count - 1].
// `global_env` is the active global namespace.

State :: struct {
    error:            Error,
    entry_function:   ^ProtoFunctionObject,
    slots:            [MAX_VM_SLOTS]Value,
    slot_count:       int,

    frame_stack:      [MAX_CALLFRAMES]CallFrame,
    frame_count:      int,
    global_env:       BindingTable,
}

Active_State: ^State


// Execution ======================================================================================

// Decode =========================================================================================

decode_op :: proc(word: u32) -> Opcode {
   return Opcode(u8(word & 0xff))
}

// Value helpers ==================================================================================

value_add :: proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int + right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) + right_float)
        }

        panic("ADD expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float + f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float + right_float)
        }

        panic("ADD expected numbers")
    }

    panic("ADD expected numbers")
}

value_sub :: proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int - right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) - right_float)
        }

        panic("SUB expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float - f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float - right_float)
        }

        panic("SUB expected numbers")
    }

    panic("SUB expected numbers")
}

value_mul :: proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int * right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) * right_float)
        }

        panic("MUL expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float * f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float * right_float)
        }

        panic("MUL expected numbers")
    }

    panic("MUL expected numbers")
}

value_div :: proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(f64(left_int) / f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) / right_float)
        }

        panic("DIV expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float / f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float / right_float)
        }

        panic("DIV expected numbers")
    }

    panic("DIV expected numbers")
}

value_neg :: proc(value: Value) -> Value {
    int_value, is_int := value.(i64)
    if is_int {
        return Value(-int_value)
    }

    float_value, is_float := value.(f64)
    if is_float {
        return Value(-float_value)
    }

    panic("NEG expected number")
}

// Comparison/truthiness helpers ==================================================================

// falsey = nil or false
// truthy = everything else
value_is_falsey :: proc(value: Value) -> bool {
    bool_value, is_bool := value.(bool)
    if is_bool {
        return !bool_value
    }

    if value == nil {
        return true
    }

    return false
}

value_equal :: proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int == right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) == right_float
        }

        return false
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float == f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float == right_float
        }

        return false
    }

    left_bool, is_bool := lhs.(bool)
    if is_bool {
        right_bool, is_bool := rhs.(bool)
        if is_bool {
            return left_bool == right_bool
        }

        return false
    }

    left_object, is_object := lhs.(^Object)
    if is_object {
        right_object, is_object := rhs.(^Object)
        if is_object {
            return left_object == right_object
        }

        return false
    }

    if lhs == nil {
        return rhs == nil
    }

    panic("unreachable: lhs must match one Value variant")
}

value_less :: proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int < right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) < right_float
        }

        panic("LESS expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float < f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float < right_float
        }

        panic("LESS expected numbers")
    }

    panic("LESS expected numbers")
}

value_less_or_equal :: proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int <= right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) <= right_float
        }

        panic("LESS_OR_EQUAL expected numbers")
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float <= f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float <= right_float
        }

        panic("LESS_OR_EQUAL expected numbers")
    }

    panic("LESS_OR_EQUAL expected numbers")
}

// VM runner ======================================================================================

run_vm :: proc(state: ^State) -> Value {
    entry_proto := state.entry_function.impl

    // Seed the first frame at slot window base 0.
    state.slot_count = entry_proto.frame_slot_count
    state.frame_stack[0] = CallFrame {
        proto                    = entry_proto,
        instruction_index        = 0,
        slot_base                = 0,
        return_slot_base         = 0,
        requested_results   = 1,
        caller_slot_count = 0,
    }
    state.frame_count = 1

    for {
        // Current frame is always the last occupied call-frame entry.
        frame := &state.frame_stack[state.frame_count - 1]

        // Fetch then advance instruction_index.
        // Jump offsets are applied relative to this post-fetch index.
        word := frame.proto.bytecode[frame.instruction_index]
        frame.instruction_index += 1

        // Decode/dispatch by opcode, then interpret the matching layout view.
        // All slot operands are frame-relative:
        // slot[A] == state.slots[frame.slot_base + A]
        switch decode_op(word) {
        case .HALT:
            return Value{}

        case .LOAD_NIL:
            inst := InstAx(word)
            dst := frame.slot_base + int(inst.a)
            state.slots[dst] = Value{}

        case .LOAD_TRUE:
            inst := InstAx(word)
            dst := frame.slot_base + int(inst.a)
            state.slots[dst] = Value(bool(true))

        case .LOAD_FALSE:
            inst := InstAx(word)
            dst := frame.slot_base + int(inst.a)
            state.slots[dst] = Value(bool(false))

        case .LOAD_CONST:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            state.slots[dst] = frame.proto.const_pool[int(inst.b)]

        case .LOAD_FUNC:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            child_proto := frame.proto.child_protos[int(inst.b)]

            function_object := new(ProtoFunctionObject)
            function_object.header.kind = .PROTO_FUNCTION
            function_object.name = child_proto.name
            function_object.impl = child_proto

            state.slots[dst] = Value(cast(^Object)function_object)

        case .MOVE:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            state.slots[dst] = state.slots[src]

        // NEW_ARRAY A, B
        // Creates an empty array in slot A. Length starts at 0.
        // B reserves backing capacity for future pushes (B elements).
        case .NEW_ARRAY:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            array_cap := int(inst.b)
            array_object := new(ArrayObject)
            array_object.header.kind = .ARRAY
            array_object.data = make([dynamic]Value, 0, array_cap)
            state.slots[dst] = Value(cast(^Object)array_object)

        case .ARRAY_LEN:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            header, is_object := state.slots[src].(^Object)
            if !is_object || header.kind != .ARRAY {
                panic("ARRAY_LEN expected array object")
            }
            array_object := cast(^ArrayObject)header
            state.slots[dst] = Value(i64(len(array_object.data)))

        // ARRAY_GET A, B, C
        // Reads array[B][index in C] into slot A.
        case .ARRAY_GET:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            array_slot := frame.slot_base + int(inst.b)
            index_slot := frame.slot_base + int(inst.c)

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                panic("ARRAY_GET expected array object")
            }
            array_object := cast(^ArrayObject)array_header

            index_i64, is_i64 := state.slots[index_slot].(i64)
            if !is_i64 {
                panic("ARRAY_GET expected i64 index")
            }
            if index_i64 < 0 {
                panic("ARRAY_GET index out of bounds")
            }

            index := int(index_i64)
            if index >= len(array_object.data) {
                panic("ARRAY_GET index out of bounds")
            }
            state.slots[dst] = array_object.data[index]

        // ARRAY_SET A, B, C
        // Writes slot B into array A at index in slot C.
        case .ARRAY_SET:
            inst := InstABC(word)
            array_slot := frame.slot_base + int(inst.a)
            value_slot := frame.slot_base + int(inst.b)
            index_slot := frame.slot_base + int(inst.c)

            value := state.slots[value_slot]

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                panic("ARRAY_SET expected array object")
            }
            array_object := cast(^ArrayObject)array_header

            index_i64, is_i64 := state.slots[index_slot].(i64)
            if !is_i64 {
                panic("ARRAY_SET expected i64 index")
            }
            if index_i64 < 0 {
                panic("ARRAY_SET index out of bounds")
            }

            index := int(index_i64)
            if index >= len(array_object.data) {
                panic("ARRAY_SET index out of bounds")
            }
            array_object.data[index] = value

        // ARRAY_PUSH A, B
        // Appends slot B to array in slot A.
        case .ARRAY_PUSH:
            inst := InstABx(word)
            array_slot := frame.slot_base + int(inst.a)
            value_slot := frame.slot_base + int(inst.b)

            value := state.slots[value_slot]

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                panic("ARRAY_PUSH expected array object")
            }
            array_object := cast(^ArrayObject)array_header

            append(&array_object.data, value)

        // ARRAY_POP A, B
        // Pops tail of array in slot B into slot A. Empty pop is an error.
        case .ARRAY_POP:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            array_slot := frame.slot_base + int(inst.b)

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                panic("ARRAY_POP expected array object")
            }
            array_object := cast(^ArrayObject)array_header

            popped_value, ok := pop_safe(&array_object.data)
            if ok {
                state.slots[dst] = popped_value
            } else {
                panic("ARRAY_POP on empty array")
            }

        case .NEW_MAP:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            map_object := new(MapObject)
            map_object.header.kind = .MAP
            map_object.data = make(map[string]Value)
            state.slots[dst] = Value(cast(^Object)map_object)

        case .MAP_LEN:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            map_slot := frame.slot_base + int(inst.b)
            map_header, is_object := state.slots[map_slot].(^Object)
            if !is_object || map_header.kind != .MAP {
                panic("MAP_LEN expected map object")
            }
            map_object := cast(^MapObject)map_header
            state.slots[dst] = Value(i64(len(map_object.data)))

        case .MAP_GET:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            map_slot := frame.slot_base + int(inst.b)
            key_slot := frame.slot_base + int(inst.c)

            map_header, is_map_object := state.slots[map_slot].(^Object)
            if !is_map_object || map_header.kind != .MAP {
                panic("MAP_GET expected map object")
            }
            map_object := cast(^MapObject)map_header

            key_header, is_key_object := state.slots[key_slot].(^Object)
            if !is_key_object || key_header.kind != .STRING {
                panic("MAP_GET expected string key")
            }
            key_object := cast(^StringObject)key_header

            value, exists := map_object.data[key_object.data]
            if exists {
                state.slots[dst] = value
            } else {
                state.slots[dst] = Value{}
            }

        case .MAP_SET:
            inst := InstABC(word)
            map_slot := frame.slot_base + int(inst.a)
            key_slot := frame.slot_base + int(inst.b)
            value_slot := frame.slot_base + int(inst.c)

            map_header, is_map_object := state.slots[map_slot].(^Object)
            if !is_map_object || map_header.kind != .MAP {
                panic("MAP_SET expected map object")
            }
            map_object := cast(^MapObject)map_header

            key_header, is_key_object := state.slots[key_slot].(^Object)
            if !is_key_object || key_header.kind != .STRING {
                panic("MAP_SET expected string key")
            }
            key_object := cast(^StringObject)key_header

            value := state.slots[value_slot]
            if value == nil {
                delete_key(&map_object.data, key_object.data)
            } else {
                map_object.data[key_object.data] = value
            }

        case .ADD:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_add(state.slots[lhs], state.slots[rhs])

        case .SUB:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_sub(state.slots[lhs], state.slots[rhs])

        case .MUL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_mul(state.slots[lhs], state.slots[rhs])

        case .DIV:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_div(state.slots[lhs], state.slots[rhs])

        case .NEG:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            state.slots[dst] = value_neg(state.slots[src])

        case .EQUAL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = Value(value_equal(state.slots[lhs], state.slots[rhs]))

        case .LESS:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = Value(value_less(state.slots[lhs], state.slots[rhs]))

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = Value(value_less_or_equal(state.slots[lhs], state.slots[rhs]))

        case .NOT:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            state.slots[dst] = Value(value_is_falsey(state.slots[src]))

        case .JUMP:
            inst := InstJump(word)
            frame.instruction_index += int(inst.offset)

        case .JUMP_FALSE:
            inst := InstAsBx(word)
            condition := frame.slot_base + int(inst.a)
            if value_is_falsey(state.slots[condition]) {
                frame.instruction_index += int(inst.sb)
            }

        case .CALL:
            inst := InstABC(word)

            // CALL A, B, C
            // A = callee/result base slot
            // B = argument count
            // C = requested result count
            call_base := frame.slot_base + int(inst.a)
            args_base := call_base + 1
            arg_count := int(inst.b)
            requested_results := int(inst.c)

            callee_header, is_object := state.slots[call_base].(^Object)
            if !is_object {
                panic("CALL expected function object")
            }

            switch callee_header.kind {
            case .NATIVE_FUNCTION:
                // Native calls execute immediately in the caller frame.
                // Native writes results at return_slot_base and reports produced count.
                native_function := cast(^NativeFunctionObject)callee_header
                produced_results := native_function.impl(state, args_base, arg_count, call_base, requested_results)

                if produced_results < requested_results {
                    // Native produced fewer than caller wants.
                    // Fill the missing result slots with nil.
                    for fill_index := produced_results; fill_index < requested_results; fill_index += 1 {
                        state.slots[call_base + fill_index] = Value{}
                    }
                }
                // Extra produced results beyond requested count are ignored by contract.

            case .PROTO_FUNCTION:
                // Proto calls push a new frame and continue the VM loop.
                proto_function := cast(^ProtoFunctionObject)callee_header
                callee_proto := proto_function.impl

                if state.frame_count >= MAX_CALLFRAMES {
                    panic("CALL exceeded MAX_CALLFRAMES")
                }

                callee_slot_base := args_base
                callee_slot_top := callee_slot_base + callee_proto.frame_slot_count
                if callee_slot_top > MAX_VM_SLOTS {
                    panic("CALL exceeded MAX_VM_SLOTS")
                }

                caller_slot_count := state.slot_count
                if callee_slot_top > state.slot_count {
                    state.slot_count = callee_slot_top
                }

                // Caller arguments already start at callee slot 0 because the callee frame
                // begins at args_base. Missing fixed parameters are explicit Kiln nil.
                for param_index := arg_count; param_index < callee_proto.param_count; param_index += 1 {
                    state.slots[callee_slot_base + param_index] = Value{}
                }

                state.frame_stack[state.frame_count] = CallFrame{
                    proto                    = callee_proto,
                    instruction_index        = 0,
                    slot_base                = callee_slot_base,
                    return_slot_base         = call_base,
                    requested_results   = requested_results,
                    caller_slot_count        = caller_slot_count,
                }
                state.frame_count += 1

            case .STRING:
                panic("CALL expected function object")
            case .ARRAY:
                panic("CALL expected function object")
            case .MAP:
                panic("CALL expected function object")
            }

        case .GET_GLOBAL:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            binding_id := int(inst.b)
            state.slots[dst] = state.global_env.values[binding_id]

        case .SET_GLOBAL:
            inst := InstABx(word)
            src := frame.slot_base + int(inst.a)
            binding_id := int(inst.b)
            state.global_env.values[binding_id] = state.slots[src]

        case .RETURN:
            inst := InstABx(word)
            produced_slot_base := frame.slot_base + int(inst.a)
            produced_results := int(inst.b)

            if state.frame_count == 1 {
                // Top-level RETURN ends execution and returns to the host.
                // Return first produced value when present, else nil.
                if produced_results > 0 {
                    return state.slots[produced_slot_base]
                }
                return Value{}
            }

            caller_result_base := frame.return_slot_base
            requested_results := frame.requested_results

            copied_result_count := produced_results
            if copied_result_count > requested_results {
                copied_result_count = requested_results
            }

            // Copy produced values into caller result slots.
            // Source and destination can overlap in the shared slot array.
            if copied_result_count > 0 {
                if caller_result_base < produced_slot_base {
                    for value_index := 0; value_index < copied_result_count; value_index += 1 {
                        state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
                    }
                } else {
                    for value_index := copied_result_count - 1; value_index >= 0; value_index -= 1 {
                        state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
                    }
                }
            }

            // Fill missing requested results with nil.
            if copied_result_count < requested_results {
                for fill_index := copied_result_count; fill_index < requested_results; fill_index += 1 {
                    state.slots[caller_result_base + fill_index] = Value{}
                }
            }

            // Pop current frame and restore caller's used slot range.
            state.slot_count = frame.caller_slot_count
            state.frame_count -= 1
        }
    }
}
