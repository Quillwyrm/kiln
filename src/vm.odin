package vm


// Opcodes ========================================================================================

Opcode :: enum u8 {
    // OP                // LAYOUT
    HALT, // ABC
    LOAD_CONST, // ABx
    // LOAD_FUNC,        // ABx
    // MOVE,             // ABC
    ADD, // ABC
    SUB, // ABC
    MUL, // ABC
    DIV, // ABC
    NEG, // ABC

    EQUAL, // ABC
    LESS, // ABC
    LESS_OR_EQUAL, // ABC
    NOT, // ABx

    JUMP, // Jump
    JUMP_FALSE, // AsBx: jump if slot[a] is falsey

    // CALL,             // ABC
    RETURN, // ABx

    // GET_GLOBAL,       // ABx
    // SET_GLOBAL,       // ABx
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

InstJump :: bit_field u32 {
    op:     Opcode | 8,
    offset: i32    | 24, // wide signed jump offset
}


// Heap object header =============================================================================

// Heap-backed values start with ObjectHeader.
// Value stores heap-backed values as ^ObjectHeader and uses kind to recover the full object type.

ObjectKind :: enum u8 {
    STRING,
    FUNCTION_PROTO,
    FUNCTION_NATIVE,
}

ObjectHeader :: struct {
    kind: ObjectKind,
}


// String objects =================================================================================

StringObject :: struct {
    header: ObjectHeader, // must be first
    text:   string,
}


// Function values ================================================================================

// FunctionProto is compiled bytecode function data.
// It is not itself the runtime function value.
// `bytecode` is the fixed instruction stream for the function.
// `const_pool` is the fixed constant table used by that bytecode.
// `slot_count` is the size of the function's slot window.

FunctionProto :: struct {
    name:        string,
    bytecode:    []u32,
    const_pool:  []Value,
    slot_count:  int,
    param_count: int,
}

// FunctionNative is an Odin-backed function implementation.
// Args live in vmState.slots starting at args_base.
// Native functions write results directly into vmState.slots starting at return_slot_base.
// wanted_result_count is the exact number of result slots the caller wants to keep.
// The returned int is the number of result values the native function produced.

FunctionNative :: proc(
    vm: ^vmState,
    args_base: int,
    arg_count: int,
    return_slot_base: int,
    wanted_result_count: int,
) -> int

// FunctionProtoObject is a runtime callable object backed by bytecode.
// Values point to this through ^ObjectHeader when header.kind == .FUNCTION_PROTO.

FunctionProtoObject :: struct {
    header: ObjectHeader, // must be first
    name:   string,
    proto:  ^FunctionProto,
}

// FunctionNativeObject is a runtime callable object backed by an Odin procedure.
// Values point to this through ^ObjectHeader when header.kind == .FUNCTION_NATIVE.

FunctionNativeObject :: struct {
    header:      ObjectHeader, // must be first
    name:        string,
    native_proc: FunctionNative,
}


// Value type =====================================================================================

// Nil is the zero value of the union.
// Immediates live inline. Heap-backed values are stored as ^ObjectHeader.

Value :: union {
    bool,
    i64,
    f64,
    ^ObjectHeader,
}


// Globals ========================================================================================

// Globals are VM-owned name bindings.
// GET_GLOBAL searches by name and reads `value`.
// SET_GLOBAL updates an existing binding or appends a new one.

GlobalBinding :: struct {
    name:  string,
    value: Value,
}


// Call frames ====================================================================================

// `slot_base` is the start of this call's slot window inside vmState.slots.
// Logical slots for this frame are addressed relative to that slot base.
// `return_slot_base` and `wanted_result_count` describe where this frame must place return values
// in its caller's slot window. The top-level frame has no caller; top-level RETURN ends execution.
// `previous_used_slot_count` restores the caller's live slot range when this frame returns.

CallFrame :: struct {
    proto:                    ^FunctionProto,
    instruction_index:        int,
    slot_base:                int,
    return_slot_base:         int,
    wanted_result_count:      int,
    previous_used_slot_count: int,
}


// VM state =======================================================================================

VM_MAX_SLOTS :: 4096
VM_MAX_CALL_FRAMES :: 256
VM_MAX_GLOBALS :: 256

// `function_table[0]` is the entry function by convention and must be a FUNCTION_PROTO object.
// LOAD_FUNC indexes `function_table` because slots store runtime Values.
// CALL dispatches callable objects by ObjectHeader.kind.
// `slots` is fixed runtime storage for all active call-frame windows.
// `used_slot_count` is the number of slots claimed by active windows.
// `call_frames` is fixed runtime storage for active bytecode calls.
// `call_frame_count` is the number of live frames.
// `global_bindings` is fixed runtime storage for named global bindings.
// `global_count` is the number of live globals.

vmState :: struct {
    functions:   []^ObjectHeader,
    slots:            [VM_MAX_SLOTS]Value,
    used_slot_count:  int,

    call_frames:      [VM_MAX_CALL_FRAMES]CallFrame,
    call_frame_count: int,

    global_bindings:  [VM_MAX_GLOBALS]GlobalBinding,
    global_count:     int,
}


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

    left_object, is_object := lhs.(^ObjectHeader)
    if is_object {
        right_object, is_object := rhs.(^ObjectHeader)
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

run_vm :: proc(vm: ^vmState) -> Value {
    // Entry must be a proto-backed function object.
    entry_header := vm.functions[0]
    entry_function := cast(^FunctionProtoObject)entry_header
    entry_proto := entry_function.proto

    // Seed the first frame at slot window base 0.
    vm.used_slot_count = entry_proto.slot_count
    vm.call_frames[0] = CallFrame {
        proto                    = entry_proto,
        instruction_index        = 0,
        slot_base                = 0,
        return_slot_base         = 0,
        wanted_result_count      = 1,
        previous_used_slot_count = 0,
    }
    vm.call_frame_count = 1

    for {
        // Current frame is always the last live frame.
        frame := &vm.call_frames[vm.call_frame_count - 1]

        // Fetch then advance instruction_index.
        // Jump offsets are applied relative to this post-fetch index.
        word := frame.proto.bytecode[frame.instruction_index]
        frame.instruction_index += 1

        // Decode/dispatch by opcode, then interpret the matching layout view.
        switch decode_op(word) {
        case .HALT:
            return Value{}

        case .LOAD_CONST:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            vm.slots[dst] = frame.proto.const_pool[int(inst.b)]

        case .ADD:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = value_add(vm.slots[lhs], vm.slots[rhs])

        case .SUB:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = value_sub(vm.slots[lhs], vm.slots[rhs])

        case .MUL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = value_mul(vm.slots[lhs], vm.slots[rhs])

        case .DIV:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = value_div(vm.slots[lhs], vm.slots[rhs])

        case .NEG:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            vm.slots[dst] = value_neg(vm.slots[src])

        case .EQUAL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = Value(value_equal(vm.slots[lhs], vm.slots[rhs]))

        case .LESS:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = Value(value_less(vm.slots[lhs], vm.slots[rhs]))

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            dst := frame.slot_base + int(inst.a)
            lhs := frame.slot_base + int(inst.b)
            rhs := frame.slot_base + int(inst.c)
            vm.slots[dst] = Value(value_less_or_equal(vm.slots[lhs], vm.slots[rhs]))

        case .NOT:
            inst := InstABx(word)
            dst := frame.slot_base + int(inst.a)
            src := frame.slot_base + int(inst.b)
            vm.slots[dst] = Value(value_is_falsey(vm.slots[src]))

        case .JUMP:
            inst := InstJump(word)
            frame.instruction_index += int(inst.offset)

        case .JUMP_FALSE:
            inst := InstAsBx(word)
            condition := frame.slot_base + int(inst.a)
            if value_is_falsey(vm.slots[condition]) {
                frame.instruction_index += int(inst.sb)
            }

        case .RETURN:
            inst := InstABx(word)
            src := frame.slot_base + int(inst.a)

            // First runner returns a single Value directly.
            // Full call/multi-return handling will use inst.b as produced return count.
            return vm.slots[src]
        }
    }
}
