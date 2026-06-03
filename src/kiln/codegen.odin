package kiln

import "core:strings"

// Codegen limits =================================================================================

// MAX_FRAME_SLOTS is the per-proto frame slot ceiling.
// It must stay compatible with u8 slot operands in emitted bytecode layouts.
MAX_FRAME_SLOTS :: 256
MAX_LOOP_DEPTH :: 64
MAX_BREAK_FIXUPS :: 1024
MAX_CONST_POOL_ENTRIES :: 65536 // u16 const index in LOAD_CONST
MAX_CHILD_PROTOS :: 65536      // u16 child proto index in LOAD_FUNC

MIN_JUMP_FALSE_OFFSET :: -32768 // i16 operand
MAX_JUMP_FALSE_OFFSET :: 32767
MIN_JUMP_OFFSET :: -8388608     // signed 24-bit operand
MAX_JUMP_OFFSET :: 8388607


// Proto-local bindings ===========================================================================

// LocalBinding maps an identifier name to a frame slot index.
LocalBinding :: struct {
    name:       string,
    frame_slot: int,
    is_mutable: bool,
}

// Proto state ====================================================================================

// ProtoState is the mutable compile target for one proto/chunk.
// Parser and codegen both mutate this state while lowering source to bytecode.
ProtoState :: struct {
    origin: SourceLocation,
    name:        string,
    param_count: int,

    bytecode:     [dynamic]u32,
    const_pool:   [dynamic]Value,
    child_protos: [dynamic]^Proto,

    frame_slot_count: int,
    local_bindings:   [MAX_FRAME_SLOTS]LocalBinding,
    local_count:      int,
    next_temp_slot:   int,
    scope_depth:      int,
    scope_local_counts: [MAX_FRAME_SLOTS]int,

    // break_fixups stores instruction indexes for unresolved `break` jumps.
    break_fixups: [MAX_BREAK_FIXUPS]int,
    break_fixup_count: int,

    // loop_break_fixup_base marks, per active loop depth, where that loop's break fixups begin.
    loop_break_fixup_base: [MAX_LOOP_DEPTH]int,
    loop_depth: int,
}

// Frame slots ====================================================================================

// record_slots maintains frame_slot_count as max-touched-slot + 1.
record_slots :: proc(proto_state: ^ProtoState, slots: ..int) {
    for slot in slots {
        required_slots := slot + 1
        if required_slots > proto_state.frame_slot_count {
            proto_state.frame_slot_count = required_slots
        }
    }
}

// Proto construction =============================================================================

// origin identifies where this proto originated for diagnostics.
// name is cloned because it can come from source token text.
begin_proto :: proc(origin: SourceLocation, name: string, param_count: int) -> ProtoState {
    return ProtoState{
        origin           = origin,
        name             = strings.clone(name),
        param_count      = param_count,
        bytecode         = make([dynamic]u32),
        const_pool       = make([dynamic]Value),
        child_protos     = make([dynamic]^Proto),
        frame_slot_count = param_count,
    }
}

end_proto :: proc(proto_state: ^ProtoState) -> ^Proto {
    bytecode := make([]u32, len(proto_state.bytecode))
    copy(bytecode, proto_state.bytecode[:])

    const_pool := make([]Value, len(proto_state.const_pool))
    copy(const_pool, proto_state.const_pool[:])

    child_protos := make([]^Proto, len(proto_state.child_protos))
    copy(child_protos, proto_state.child_protos[:])

    delete(proto_state.bytecode)
    delete(proto_state.const_pool)
    delete(proto_state.child_protos)

    proto := new(Proto)
    proto^ = Proto{
        origin           = proto_state.origin,
        name             = proto_state.name,
        bytecode         = bytecode,
        const_pool       = const_pool,
        child_protos     = child_protos,
        frame_slot_count = proto_state.frame_slot_count,
        param_count      = proto_state.param_count,
    }

    return proto
}

// Only call this on an unfinished ProtoState. end_proto moves data into a finished Proto instead.
delete_proto_state :: proc(proto_state: ^ProtoState) {
    delete(proto_state.name)
    delete(proto_state.bytecode)
    delete(proto_state.const_pool)
    delete(proto_state.child_protos)
}

// Constants ======================================================================================
const_int :: proc(proto_state: ^ProtoState, value: i64) -> int {
    if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
        set_error(proto_state.origin, "too many constants in function")
        Parser.failed = true
        return 0
    }

    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, Value(value))

    return const_index
}

const_float :: proc(proto_state: ^ProtoState, value: f64) -> int {
    if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
        set_error(proto_state.origin, "too many constants in function")
        Parser.failed = true
        return 0
    }

    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, Value(value))

    return const_index
}

const_string :: proc(proto_state: ^ProtoState, text: string) -> int {
    if len(proto_state.const_pool) >= MAX_CONST_POOL_ENTRIES {
        set_error(proto_state.origin, "too many constants in function")
        Parser.failed = true
        return 0
    }

    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, new_string_value(text))

    return const_index
}

// Instruction emitters ===========================================================================
// All slot operands are frame-local indexes for the current proto.

// Loads ==========================================================================================

emit_load_nil :: proc(proto_state: ^ProtoState, dst: int) {
    record_slots(proto_state, dst)

    inst := u32(InstAx{ op= .LOAD_NIL, a= u32(dst) })
    append(&proto_state.bytecode, inst)
}

emit_load_true :: proc(proto_state: ^ProtoState, dst: int) {
    record_slots(proto_state, dst)

    inst := u32(InstAx{ op= .LOAD_TRUE, a= u32(dst) })
    append(&proto_state.bytecode, inst)
}

emit_load_false :: proc(proto_state: ^ProtoState, dst: int) {
    record_slots(proto_state, dst)

    inst := u32(InstAx{ op= .LOAD_FALSE, a= u32(dst) })
    append(&proto_state.bytecode, inst)
}

emit_load_const :: proc(proto_state: ^ProtoState, dst, const_index: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .LOAD_CONST, a= u8(dst), b= u16(const_index) })
    append(&proto_state.bytecode, inst)
}

emit_load_func :: proc(proto_state: ^ProtoState, dst, child_proto_index: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .LOAD_FUNC, a= u8(dst), b= u16(child_proto_index) })
    append(&proto_state.bytecode, inst)
}

emit_move :: proc(proto_state: ^ProtoState, dst, src: int) {
    record_slots(proto_state, dst, src)

    inst := u32(InstABx{ op= .MOVE, a= u8(dst), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

// Array operations ===============================================================================
// Stub — wired when the parser parses corresponding syntax.

emit_new_array :: proc(proto_state: ^ProtoState, dst, array_cap: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .NEW_ARRAY, a= u8(dst), b= u16(array_cap) })
    append(&proto_state.bytecode, inst)
}

emit_array_len :: proc(proto_state: ^ProtoState, dst, src_array: int) {
    record_slots(proto_state, dst, src_array)

    inst := u32(InstABx{ op= .ARRAY_LEN, a= u8(dst), b= u16(src_array) })
    append(&proto_state.bytecode, inst)
}

emit_array_push :: proc(proto_state: ^ProtoState, dst_array, src: int) {
    record_slots(proto_state, dst_array, src)

    inst := u32(InstABx{ op= .ARRAY_PUSH, a= u8(dst_array), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

emit_array_pop :: proc(proto_state: ^ProtoState, dst, src_array: int) {
    record_slots(proto_state, dst, src_array)

    inst := u32(InstABx{ op= .ARRAY_POP, a= u8(dst), b= u16(src_array) })
    append(&proto_state.bytecode, inst)
}

// Map operations =================================================================================

emit_new_map :: proc(proto_state: ^ProtoState, dst: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .NEW_MAP, a= u8(dst), b= 0 })
    append(&proto_state.bytecode, inst)
}

emit_map_len :: proc(proto_state: ^ProtoState, dst, src_map: int) {
    record_slots(proto_state, dst, src_map)

    inst := u32(InstABx{ op= .MAP_LEN, a= u8(dst), b= u16(src_map) })
    append(&proto_state.bytecode, inst)
}

// Indexed access ================================================================================

emit_index_get :: proc(proto_state: ^ProtoState, dst, container, key: int) {
    record_slots(proto_state, dst, container, key)

    inst := u32(InstABC{ op= .INDEX_GET, a= u8(dst), b= u8(container), c= u8(key) })
    append(&proto_state.bytecode, inst)
}

emit_index_set :: proc(proto_state: ^ProtoState, container, key, src: int) {
    record_slots(proto_state, container, key, src)

    inst := u32(InstABC{ op= .INDEX_SET, a= u8(container), b= u8(key), c= u8(src) })
    append(&proto_state.bytecode, inst)
}

// Numeric operations =============================================================================

emit_add :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .ADD, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_sub :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .SUB, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_mul :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .MUL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_div :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .DIV, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_mod :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .MOD, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_neg :: proc(proto_state: ^ProtoState, dst, src: int) {
    record_slots(proto_state, dst, src)

    inst := u32(InstABx{ op= .NEG, a= u8(dst), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

// Comparison and boolean operations ==============================================================

emit_equal :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_less :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .LESS, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_less_or_equal :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .LESS_OR_EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&proto_state.bytecode, inst)
}

emit_not :: proc(proto_state: ^ProtoState, dst, src: int) {
    record_slots(proto_state, dst, src)

    inst := u32(InstABx{ op= .NOT, a= u8(dst), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

// Jumps and patching =============================================================================
// Jump offsets are relative to the instruction after the jump fetch.

next_inst_index :: proc(proto_state: ^ProtoState) -> int {
    return len(proto_state.bytecode)
}

emit_jump :: proc(proto_state: ^ProtoState, target_index: int = -1) -> int {
    jump_index := next_inst_index(proto_state)
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
        if offset < MIN_JUMP_OFFSET || offset > MAX_JUMP_OFFSET {
            set_error(proto_state.origin, "jump is too far")
            Parser.failed = true
            return jump_index
        }
    }

    inst := u32(InstJump{ op= .JUMP, offset= i32(offset) })
    append(&proto_state.bytecode, inst)

    return jump_index
}

emit_jump_false :: proc(proto_state: ^ProtoState, cond_slot: int, target_index: int = -1) -> int {
    record_slots(proto_state, cond_slot)

    jump_index := next_inst_index(proto_state)
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
        if offset < MIN_JUMP_FALSE_OFFSET || offset > MAX_JUMP_FALSE_OFFSET {
            set_error(proto_state.origin, "conditional jump is too far")
            Parser.failed = true
            return jump_index
        }
    }

    inst := u32(InstAsBx{ op= .JUMP_FALSE, a= u8(cond_slot), sb= i16(offset) })
    append(&proto_state.bytecode, inst)

    return jump_index
}

// Offsets are relative to instruction index after jump fetch.
patch_jump :: proc(proto_state: ^ProtoState, jump_index: int) {
    word := proto_state.bytecode[jump_index]
    target_index := next_inst_index(proto_state)
    offset := target_index - (jump_index + 1)

    op := decode_op(word)
    if op == .JUMP {
        if offset < MIN_JUMP_OFFSET || offset > MAX_JUMP_OFFSET {
            set_error(proto_state.origin, "jump is too far")
            Parser.failed = true
            return
        }

        inst := u32(InstJump{ op= .JUMP, offset= i32(offset) })
        proto_state.bytecode[jump_index] = inst
        return
    }

    if op == .JUMP_FALSE {
        if offset < MIN_JUMP_FALSE_OFFSET || offset > MAX_JUMP_FALSE_OFFSET {
            set_error(proto_state.origin, "conditional jump is too far")
            Parser.failed = true
            return
        }

        old_inst := InstAsBx(word)
        inst := u32(InstAsBx{ op= .JUMP_FALSE, a= old_inst.a, sb= i16(offset) })
        proto_state.bytecode[jump_index] = inst
        return
    }

    panic("patch_jump expected JUMP or JUMP_FALSE")
}

// Calls and returns ==============================================================================

// Records the highest fixed slot touched by this call layout.
// Open-result calls record the callee/args only; produced result count is runtime data.
// Returns the bytecode index of the emitted CALL instruction.
emit_call :: proc(proto_state: ^ProtoState, call_base, arg_count, requested_results: int) -> int {
    call_index := next_inst_index(proto_state)

    occupied_call_slots := arg_count + 1
    if requested_results != CALL_OPEN_RESULTS && requested_results > occupied_call_slots {
        occupied_call_slots = requested_results
    }
    record_slots(proto_state, call_base + occupied_call_slots - 1)

    inst := u32(InstABC{
        op= .CALL,
        a= u8(call_base),
        b= u8(arg_count),
        c= u8(requested_results),
    })
    append(&proto_state.bytecode, inst)

    return call_index
}

// set_call_requested_results rewrites the requested-result operand of a previously emitted CALL.
// It enforces the u8 operand limit for the CALL result count.
set_call_requested_results :: proc(proto_state: ^ProtoState, call_index, result_count: int) {
    if result_count < 0 {
        panic("CALL requested result count cannot be negative")
    }

    if result_count >= CALL_OPEN_RESULTS {
        set_error(proto_state.origin, "too many call results")
        Parser.failed = true
        return
    }

    word := proto_state.bytecode[call_index]
    inst := InstABC(word)
    inst.c = u8(result_count)
    proto_state.bytecode[call_index] = u32(inst)
}

// set_call_open_results rewrites a previously emitted CALL to produce an open result range.
set_call_open_results :: proc(proto_state: ^ProtoState, call_index: int) {
    word := proto_state.bytecode[call_index]
    inst := InstABC(word)
    inst.c = u8(CALL_OPEN_RESULTS)
    proto_state.bytecode[call_index] = u32(inst)
}

emit_return :: proc(proto_state: ^ProtoState, first_slot, result_count: int) {
    if result_count != RETURN_OPEN_RESULTS && result_count > 0 {
        record_slots(proto_state, first_slot + result_count - 1)
    }

    inst := u32(InstABx{ op= .RETURN, a= u8(first_slot), b= u16(result_count) })
    append(&proto_state.bytecode, inst)
}

// Global binding instructions ====================================================================

emit_get_global :: proc(proto_state: ^ProtoState, dst: int, binding_id: BindingId) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .GET_GLOBAL, a= u8(dst), b= u16(int(binding_id)) })
    append(&proto_state.bytecode, inst)
}

emit_set_global :: proc(proto_state: ^ProtoState, src: int, binding_id: BindingId) {
    record_slots(proto_state, src)

    inst := u32(InstABx{ op= .SET_GLOBAL, a= u8(src), b= u16(int(binding_id)) })
    append(&proto_state.bytecode, inst)
}
