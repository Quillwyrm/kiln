package kiln

import "core:fmt"


// Opcodes ========================================================================================
// Instruction layout and operand meaning is documented inline on each opcode name.

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
    ARRAY_PUSH,    // ABx: A=dst_array, B=src
    ARRAY_POP,     // ABx: A=dst,       B=src_array

    // Map Operations
    NEW_MAP,       // ABx: A=dst,     B=reserved
    MAP_LEN,       // ABx: A=dst,     B=src_map

    // Indexed Access
    INDEX_GET,     // ABC: A=dst,       B=container, C=key
    INDEX_SET,     // ABC: A=container, B=key,       C=src

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
    HALT,          // ABC: no operands used; stop VM and return nil. Currently unused — reserved for debug/tool use.

    // Calls and Returns
    CALL,          // ABC: A=callee/result base, B=arg_count, C=requested_results
    RETURN,        // ABx: A=first_return, B=produced_results

    // Global Bindings
    GET_GLOBAL,    // ABx: A=dst, B=binding_id
    SET_GLOBAL,    // ABx: A=src, B=binding_id
}

// Count operand sentinels.
// CALL.C is u8. RETURN.B is u16.
CALL_OPEN_RESULTS :: 255
RETURN_OPEN_RESULTS :: 65535


// Instruction layout types =======================================================================
// Types used to pack and decode instruction words.
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


// Values and heap objects ========================================================================
// Heap-backed values store ^Object. Object must be the first field of every heap object.
// The VM reads Object.kind before casting to the concrete struct.

// ObjectKind tags the concrete struct behind a heap-backed Value.
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


// Nil is the zero value. Immediates (bool, i64, f64) live inline. ^Object for heap values.
Value :: union {
    bool,
    i64,
    f64,
    ^Object,
}

StringObject :: struct {
    header: Object,
    data:   string,
}

ArrayObject :: struct {
    header: Object,
    data:  [dynamic]Value,
}

MapObject :: struct {
    header: Object,
    data:  map[string]Value,
}



// Functions ======================================================================================
// Proto stores compiled bytecode data. Function objects (ProtoFunctionObject,
// NativeFunctionObject) are the runtime callable values that CALL dispatches.

Proto :: struct {
    origin: SourceLocation,
    name:        string,
    bytecode:    []u32,
    const_pool:  []Value,
    child_protos: []^Proto,
    frame_slot_count: int,
    param_count: int,
}

// Odin-backed function impl. CALL shapes produced results to requested: missing = nil, extras ignored.
NativeFunction :: proc(vm: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int


ProtoFunctionObject :: struct {
    header: Object,
    name:   string,
    impl:  ^Proto,
}

NativeFunctionObject :: struct {
    header: Object,
    impl:   NativeFunction,
}


// Binding tables ===============================================================================
// Fixed-size namespaces. Globals use one BindingTable on State.

MAX_BINDINGS :: 256

BindingId :: distinct int

// BindingTable is a named value namespace.
// BindingId values are indexes into one specific BindingTable.
BindingTable :: struct {
    names:      [MAX_BINDINGS]string,
    values:     [MAX_BINDINGS]Value,
    is_mutable: [MAX_BINDINGS]bool,
    count:      int,
}


// Call frames ====================================================================================

// One active proto execution window. Slot operands are relative to slot_base.
CallFrame :: struct {
    proto:                    ^Proto,
    instruction_index:        int,
    slot_base:                int,

    return_slot_base:         int,
    requested_results:   int,
    open_result_base:         int,
    open_result_count:        int,

    caller_slot_count: int,
}


// VM state =======================================================================================
MAX_VM_SLOTS :: 4096
MAX_CALLFRAMES :: 256
// Host-owned runtime instance. Stores active frames, slots, globals, and error state.
State :: struct {
    has_error:        bool,
    error:            Error,
    entry_function:   ^ProtoFunctionObject,
    slots:            [MAX_VM_SLOTS]Value,
    slot_count:       int,

    frame_stack:      [MAX_CALLFRAMES]CallFrame,
    frame_count:      int,
    global_env:       BindingTable,
}

Active_State: ^State


// Binding table primitives =======================================================================

// binding_table_find returns the binding index for name, or -1 when name is absent.
binding_table_find :: proc(table: ^BindingTable, name: string) -> int {
    for binding_index := 0; binding_index < table.count; binding_index += 1 {
        if table.names[binding_index] == name {
            return binding_index
        }
    }

    return -1
}

// binding_table_append appends a new binding. Caller owns duplicate and capacity policy.
binding_table_append :: proc(table: ^BindingTable, name: string, is_mutable: bool) -> BindingId {
    binding_id := BindingId(table.count)
    table.names[table.count] = name
    table.is_mutable[table.count] = is_mutable
    table.count += 1
    return binding_id
}


// Global bindings ================================================================================
// Global binding helpers operate on Active_State.global_env.
// Public host entry points select Active_State before these helpers run.

// bind_native_global installs one native callable into global_env by binding name.
bind_native_global :: proc(name: string, native_proc: NativeFunction) {
    binding_index := binding_table_find(&Active_State.global_env, name)

    binding_id: BindingId
    if binding_index >= 0 {
        binding_id = BindingId(binding_index)
    } else {
        if Active_State.global_env.count >= MAX_BINDINGS {
            set_error(SourceLocation{}, "too many global bindings")
            return
        }

        binding_id = binding_table_append(&Active_State.global_env, name, false)
    }
    Active_State.global_env.is_mutable[int(binding_id)] = false

    native_function := new(NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.impl = native_proc

    Active_State.global_env.values[int(binding_id)] = Value(cast(^Object)native_function)
}


// Execution primitives ===========================================================================


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
    }

    runtime_error(fmt.tprintf("invalid `+`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
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
    }

    runtime_error(fmt.tprintf("invalid `-`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
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
    }

    runtime_error(fmt.tprintf("invalid `*`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
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
    }

    runtime_error(fmt.tprintf("invalid `/`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
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

    runtime_error(fmt.tprintf("invalid unary `-`; expected number, got `%s`", value_type_to_string(value)))
    return Value{}
}

// Comparison/truthiness helpers ==================================================================

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
            if left_object.kind == .STRING && right_object.kind == .STRING {
                left_string := cast(^StringObject)left_object
                right_string := cast(^StringObject)right_object
                return left_string.data == right_string.data
            }

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
    }

    runtime_error(fmt.tprintf("invalid `<`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return false
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
    }

    runtime_error(fmt.tprintf("invalid `<='; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return false
}

// Runtime errors =================================================================================

runtime_error :: proc(message: string) -> ^Error {
    frame := &Active_State.frame_stack[Active_State.frame_count - 1]
    proto := frame.proto

    // frame_count == 1 is the entry file; deeper frames are user function calls.
    context_text := "in entry file"
    if Active_State.frame_count > 1 {
        if proto.name == "<function>" {
            context_text = "in anonymous function"
        } else {
            context_text = fmt.tprintf("in `%s()`", proto.name)
        }
    }

    return set_error(proto.origin, message, context_text)
}


// VM runner ======================================================================================

run_vm :: proc(state: ^State) -> (result: Value, err: ^Error) {
    entry_proto := state.entry_function.impl

    // Seed the first frame at slot window base 0.
    state.slot_count = entry_proto.frame_slot_count
    state.frame_stack[0] = CallFrame {
        proto                    = entry_proto,
        instruction_index        = 0,
        slot_base                = 0,
        return_slot_base         = 0,
        requested_results   = 1,
        open_result_base         = 0,
        open_result_count        = 0,
        caller_slot_count        = 0,
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
            return Value{}, nil

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
            // Materializes a ProtoFunctionObject from this proto's child proto table.
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

        // B = initial backing capacity for future pushes.
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

        // Reads container B at key/index C into slot A.
        case .INDEX_GET:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            container_slot := frame.slot_base + int(inst.b)
            key_slot := frame.slot_base + int(inst.c)

            container_header, is_object := state.slots[container_slot].(^Object)
            if !is_object {
                return Value{}, runtime_error(fmt.tprintf("invalid index read; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

            switch container_header.kind {
            case .ARRAY:
                array_object := cast(^ArrayObject)container_header

                index_i64, is_i64 := state.slots[key_slot].(i64)
                if !is_i64 {
                    return Value{}, runtime_error(fmt.tprintf("invalid array index; expected `int`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                if index_i64 < 0 {
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }

                index := int(index_i64)
                if index >= len(array_object.data) {
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }
                state.slots[dst] = array_object.data[index]

            case .MAP:
                map_object := cast(^MapObject)container_header

                key_header, is_key_object := state.slots[key_slot].(^Object)
                if !is_key_object || key_header.kind != .STRING {
                    return Value{}, runtime_error(fmt.tprintf("invalid map key; expected `string`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                key_object := cast(^StringObject)key_header

                value, exists := map_object.data[key_object.data]
                if exists {
                    state.slots[dst] = value
                } else {
                    state.slots[dst] = Value{}
                }

            case .STRING, .PROTO_FUNCTION, .NATIVE_FUNCTION:
                return Value{}, runtime_error(fmt.tprintf("invalid index read; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

        // Writes slot C into container A at key/index B.
        case .INDEX_SET:
            inst := InstABC(word)
            container_slot := frame.slot_base + int(inst.a)
            key_slot := frame.slot_base + int(inst.b)
            value_slot := frame.slot_base + int(inst.c)

            value := state.slots[value_slot]

            container_header, is_object := state.slots[container_slot].(^Object)
            if !is_object {
                return Value{}, runtime_error(fmt.tprintf("invalid index assignment; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

            switch container_header.kind {
            case .ARRAY:
                array_object := cast(^ArrayObject)container_header

                index_i64, is_i64 := state.slots[key_slot].(i64)
                if !is_i64 {
                    return Value{}, runtime_error(fmt.tprintf("invalid array index; expected `int`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                if index_i64 < 0 {
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }

                index := int(index_i64)
                if index >= len(array_object.data) {
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }
                array_object.data[index] = value

            case .MAP:
                map_object := cast(^MapObject)container_header

                key_header, is_key_object := state.slots[key_slot].(^Object)
                if !is_key_object || key_header.kind != .STRING {
                    return Value{}, runtime_error(fmt.tprintf("invalid map key; expected `string`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                key_object := cast(^StringObject)key_header

                if value == nil {
                    delete_key(&map_object.data, key_object.data)
                } else {
                    map_object.data[key_object.data] = value
                }

            case .STRING, .PROTO_FUNCTION, .NATIVE_FUNCTION:
                return Value{}, runtime_error(fmt.tprintf("invalid index assignment; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

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

        // Pops tail of array B into slot A. Empty pop is an error.
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

        case .ADD:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_add(state.slots[lhs], state.slots[rhs])
            if state.has_error {
                return Value{}, &state.error
            }

        case .SUB:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_sub(state.slots[lhs], state.slots[rhs])
            if state.has_error {
                return Value{}, &state.error
            }

        case .MUL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_mul(state.slots[lhs], state.slots[rhs])
            if state.has_error {
                return Value{}, &state.error
            }

        case .DIV:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = value_div(state.slots[lhs], state.slots[rhs])
            if state.has_error {
                return Value{}, &state.error
            }

        case .NEG:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            state.slots[dst] = value_neg(state.slots[src])
            if state.has_error {
                return Value{}, &state.error
            }

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
            if state.has_error {
                return Value{}, &state.error
            }

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            state.slots[dst] = Value(value_less_or_equal(state.slots[lhs], state.slots[rhs]))
            if state.has_error {
                return Value{}, &state.error
            }

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

            // A = callee/result base, B = arg count, C = requested result count
            call_base := frame.slot_base + int(inst.a)
            args_base := call_base + 1
            arg_count := int(inst.b)
            requested_results := int(inst.c)

            callee_header, is_object := state.slots[call_base].(^Object)
            if !is_object {
                message := fmt.tprintf("invalid function call; expected `function`, got `%s`", value_type_to_string(state.slots[call_base]))
                return Value{}, runtime_error(message)
            }

            switch callee_header.kind {
            case .NATIVE_FUNCTION:
                // Executes immediately in the caller frame. Writes results then shapes to requested.
                native_function := cast(^NativeFunctionObject)callee_header
                produced_results := native_function.impl(state, args_base, arg_count, call_base, requested_results)
                if state.has_error {
                    return Value{}, &state.error
                }

                if requested_results == CALL_OPEN_RESULTS {
                    result_end := call_base + produced_results
                    if result_end > frame.slot_base + MAX_FRAME_SLOTS || result_end > MAX_VM_SLOTS {
                        return Value{}, runtime_error("open call produced too many results")
                    }

                    frame.open_result_base = call_base
                    frame.open_result_count = produced_results
                    if result_end > state.slot_count {
                        state.slot_count = result_end
                    }
                } else if produced_results < requested_results {
                    // Native produced fewer than caller wants.
                    // Fill the missing result slots with nil.
                    for fill_index := produced_results; fill_index < requested_results; fill_index += 1 {
                        state.slots[call_base + fill_index] = Value{}
                    }
                }
                // Extra produced results beyond requested count are ignored by contract.

            case .PROTO_FUNCTION:
                // Pushes a new frame and continues the VM loop.
                proto_function := cast(^ProtoFunctionObject)callee_header
                callee_proto := proto_function.impl

                if state.frame_count >= MAX_CALLFRAMES {
                    return Value{}, runtime_error("call stack limit exceeded")
                }

                callee_slot_base := args_base
                callee_slot_top := callee_slot_base + callee_proto.frame_slot_count
                if callee_slot_top > MAX_VM_SLOTS {
                    return Value{}, runtime_error("runtime slot limit exceeded")
                }

                // Register-window: callee frame starts at args_base, so callee slot 0 gets arg 0.
                caller_slot_count := state.slot_count
                if callee_slot_top > state.slot_count {
                    state.slot_count = callee_slot_top
                }

                // Extra fixed args are rejected; missing params filled with nil.
                if arg_count > callee_proto.param_count {
                    message := fmt.tprintf("too many arguments for `%s()`: expected %d, got %d", proto_function.name, callee_proto.param_count, arg_count)
                    return Value{}, runtime_error(message)
                }

                for param_index := arg_count; param_index < callee_proto.param_count; param_index += 1 {
                    state.slots[callee_slot_base + param_index] = Value{}
                }

                state.frame_stack[state.frame_count] = CallFrame{
                    proto                    = callee_proto,
                    instruction_index        = 0,
                    slot_base                = callee_slot_base,
                    return_slot_base         = call_base,
                    requested_results   = requested_results,
                    open_result_base         = 0,
                    open_result_count        = 0,
                    caller_slot_count        = caller_slot_count,
                }
                state.frame_count += 1

            case .STRING, .ARRAY, .MAP:
                message := fmt.tprintf("invalid function call; expected `function`, got `%s`", value_type_to_string(state.slots[call_base]))
                return Value{}, runtime_error(message)
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

            if produced_results == RETURN_OPEN_RESULTS {
                fixed_prefix_count := frame.open_result_base - produced_slot_base
                if fixed_prefix_count < 0 {
                    panic("open return result base is before produced slot base")
                }
                produced_results = fixed_prefix_count + frame.open_result_count
            }

            if state.frame_count == 1 {
                // Top-level RETURN ends execution and returns to the host.
                // Return first produced value when present, else nil.
                if produced_results > 0 {
                    return state.slots[produced_slot_base], nil
                }
                return Value{}, nil
            }

            caller_result_base := frame.return_slot_base
            requested_results := frame.requested_results

            if requested_results == CALL_OPEN_RESULTS {
                result_end := caller_result_base + produced_results
                if result_end > MAX_VM_SLOTS {
                    return Value{}, runtime_error("open return produced too many results")
                }

                caller_frame := &state.frame_stack[state.frame_count - 2]
                if result_end > caller_frame.slot_base + MAX_FRAME_SLOTS {
                    return Value{}, runtime_error("open return produced too many results")
                }

                for value_index := 0; value_index < produced_results; value_index += 1 {
                    state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
                }

                caller_frame.open_result_base = caller_result_base
                caller_frame.open_result_count = produced_results

                state.slot_count = frame.caller_slot_count
                if result_end > state.slot_count {
                    state.slot_count = result_end
                }
                state.frame_count -= 1
                continue
            }

            copied_result_count := produced_results
            if copied_result_count > requested_results {
                copied_result_count = requested_results
            }

            // Copy produced values into caller result slots.
            // The callee produces below the caller result base, so forward copy is safe
            // (no overlap risk between source and destination).
            for value_index := 0; value_index < copied_result_count; value_index += 1 {
                state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
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
