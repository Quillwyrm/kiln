package kiln

// Proto-local bindings ===========================================================================

// MAX_FRAME_SLOTS is the per-proto frame slot ceiling.
// It must stay compatible with u8 slot operands in emitted bytecode layouts.
MAX_FRAME_SLOTS :: 256
MAX_LOOP_DEPTH :: 64
MAX_BREAK_FIXUPS :: 1024

// LocalBinding maps an identifier name to a frame slot index.
LocalBinding :: struct {
    name: string,
    frame_slot: int,
}

// Proto state ====================================================================================

// ProtoState is the mutable compile target for one proto/chunk.
// Parser and codegen both mutate this state while lowering source to bytecode.
ProtoState :: struct {
    source_name: string,
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

// Internals ======================================================================================

// record_slots maintains frame_slot_count as max-touched-slot + 1.
record_slots :: proc(proto_state: ^ProtoState, slots: ..int) {
    for slot in slots {
        required_slots := slot + 1
        if required_slots > proto_state.frame_slot_count {
            proto_state.frame_slot_count = required_slots
        }
    }
}

// declare_global returns a BindingId for binding_name.
// If the name exists, it returns the existing id.
// Otherwise it appends a new binding and returns its id.
declare_global :: proc(binding_name: string) -> BindingId {
    for binding_index := 0; binding_index < Active_State.global_env.count; binding_index += 1 {
        if Active_State.global_env.names[binding_index] == binding_name {
            return BindingId(binding_index)
        }
    }

    binding_id := BindingId(Active_State.global_env.count)
    Active_State.global_env.names[Active_State.global_env.count] = binding_name
    Active_State.global_env.count += 1

    return binding_id
}

// resolve_global looks up an existing binding name without creating one.
resolve_global :: proc(binding_name: string) -> (binding_id: BindingId, found: bool) {
    for binding_index := 0; binding_index < Active_State.global_env.count; binding_index += 1 {
        if Active_State.global_env.names[binding_index] == binding_name {
            return BindingId(binding_index), true
        }
    }

    return {}, false
}

// bind_native_global installs one native callable into global_env by binding name.
bind_native_global :: proc(name: string, native_proc: NativeFunction) {
    native_function := new(NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.name = name
    native_function.impl = native_proc

    binding_id := declare_global(name)
    Active_State.global_env.values[int(binding_id)] = Value(cast(^Object)native_function)
}


// Proto construction =============================================================================

// begin_proto initializes mutable proto construction state.
// source_name identifies where this proto originated for diagnostics.
begin_proto :: proc(source_name, name: string, param_count: int) -> ProtoState {
    return ProtoState{
        source_name      = source_name,
        name             = name,
        param_count      = param_count,
        bytecode         = make([dynamic]u32),
        const_pool       = make([dynamic]Value),
        child_protos     = make([dynamic]^Proto),
        frame_slot_count = param_count,
    }
}

// end_proto finalizes ProtoState into an owned Proto heap object.
// Dynamic buffers are copied to owned slices, then the dynamic buffers are deleted.
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
        source_name      = proto_state.source_name,
        name             = proto_state.name,
        bytecode         = bytecode,
        const_pool       = const_pool,
        child_protos     = child_protos,
        frame_slot_count = proto_state.frame_slot_count,
        param_count      = proto_state.param_count,
    }

    return proto
}

// Constants ======================================================================================

// Constant helpers append values to proto const_pool and return const indexes.
const_int :: proc(proto_state: ^ProtoState, value: i64) -> int {
    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, Value(value))

    return const_index
}

const_float :: proc(proto_state: ^ProtoState, value: f64) -> int {
    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, Value(value))

    return const_index
}

const_string :: proc(proto_state: ^ProtoState, text: string) -> int {
    string_object := new(StringObject)
    string_object.header.kind = .STRING
    string_object.data = text

    const_index := len(proto_state.const_pool)
    append(&proto_state.const_pool, Value(cast(^Object)string_object))

    return const_index
}

// Instruction emitters ===========================================================================

// Emitters encode VM instructions directly into proto_state.bytecode.
// All slot operands are frame-local slot indexes for the current proto.
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

emit_array_get :: proc(proto_state: ^ProtoState, dst, src_array, index: int) {
    record_slots(proto_state, dst, src_array, index)

    inst := u32(InstABC{ op= .ARRAY_GET, a= u8(dst), b= u8(src_array), c= u8(index) })
    append(&proto_state.bytecode, inst)
}

emit_array_set :: proc(proto_state: ^ProtoState, dst_array, src, index: int) {
    record_slots(proto_state, dst_array, src, index)

    inst := u32(InstABC{ op= .ARRAY_SET, a= u8(dst_array), b= u8(src), c= u8(index) })
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

emit_map_get :: proc(proto_state: ^ProtoState, dst, src_map, key: int) {
    record_slots(proto_state, dst, src_map, key)

    inst := u32(InstABC{ op= .MAP_GET, a= u8(dst), b= u8(src_map), c= u8(key) })
    append(&proto_state.bytecode, inst)
}

emit_map_set :: proc(proto_state: ^ProtoState, dst_map, key, src: int) {
    record_slots(proto_state, dst_map, key, src)

    inst := u32(InstABC{ op= .MAP_SET, a= u8(dst_map), b= u8(key), c= u8(src) })
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
    }

    inst := u32(InstAsBx{ op= .JUMP_FALSE, a= u8(cond_slot), sb= i16(offset) })
    append(&proto_state.bytecode, inst)

    return jump_index
}

// patch_jump rewrites a previously emitted jump to target current bytecode end.
// Offsets are relative to instruction index after jump fetch.
patch_jump :: proc(proto_state: ^ProtoState, jump_index: int) {
    word := proto_state.bytecode[jump_index]
    target_index := next_inst_index(proto_state)
    offset := target_index - (jump_index + 1)

    op := decode_op(word)
    if op == .JUMP {
        inst := u32(InstJump{ op= .JUMP, offset= i32(offset) })
        proto_state.bytecode[jump_index] = inst
        return
    }

    if op == .JUMP_FALSE {
        old_inst := InstAsBx(word)
        inst := u32(InstAsBx{ op= .JUMP_FALSE, a= old_inst.a, sb= i16(offset) })
        proto_state.bytecode[jump_index] = inst
        return
    }

    panic("patch_jump expected JUMP or JUMP_FALSE")
}

// Calls and returns ==============================================================================

// emit_call records the highest slot touched by this call layout, including requested result slots.
emit_call :: proc(proto_state: ^ProtoState, call_base, arg_count, requested_results: int) {
    occupied_call_slots := arg_count + 1
    if requested_results > occupied_call_slots {
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
}

emit_return :: proc(proto_state: ^ProtoState, first_slot, result_count: int) {
    if result_count > 0 {
        record_slots(proto_state, first_slot + result_count - 1)
    }

    inst := u32(InstABx{ op= .RETURN, a= u8(first_slot), b= u16(result_count) })
    append(&proto_state.bytecode, inst)
}

emit_halt :: proc(proto_state: ^ProtoState) {
    inst := u32(InstABC{ op= .HALT })
    append(&proto_state.bytecode, inst)
}

// Global bindings ================================================================================

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
