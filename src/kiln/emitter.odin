package kiln

// Proto state ====================================================================================

ProtoState :: struct {
    name:             string,
    param_count:      int,
    bytecode:         [dynamic]u32,
    const_pool:       [dynamic]Value,
    child_protos:     [dynamic]^Proto,
    frame_slot_count: int,
    locals:           [MAX_FRAME_SLOTS]Local_Binding,
    local_count:      int,
    next_temp_slot:   int,
}

// Internals ======================================================================================

record_slots :: proc(proto_state: ^ProtoState, slots: ..int) {
    for slot in slots {
        required_slots := slot + 1
        if required_slots > proto_state.frame_slot_count {
            proto_state.frame_slot_count = required_slots
        }
    }
}

declare_global :: proc(name: string) -> BindingId {
    for binding_index := 0; binding_index < Active_State.global_env.count; binding_index += 1 {
        if Active_State.global_env.names[binding_index] == name {
            return BindingId(binding_index)
        }
    }

    binding_id := BindingId(Active_State.global_env.count)
    Active_State.global_env.names[Active_State.global_env.count] = name
    Active_State.global_env.count += 1

    return binding_id
}

resolve_global :: proc(name: string) -> (binding_id: BindingId, found: bool) {
    for binding_index := 0; binding_index < Active_State.global_env.count; binding_index += 1 {
        if Active_State.global_env.names[binding_index] == name {
            return BindingId(binding_index), true
        }
    }

    return {}, false
}

bind_native_global :: proc(name: string, native_proc: NativeFunction) {
    native_function := new(NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.name = name
    native_function.impl = native_proc

    binding_id := declare_global(name)
    Active_State.global_env.values[int(binding_id)] = Value(cast(^Object)native_function)
}


// Proto construction =============================================================================

begin_proto :: proc(name: string, param_count: int) -> ProtoState {
    return ProtoState{
        name             = name,
        param_count      = param_count,
        bytecode         = make([dynamic]u32),
        const_pool       = make([dynamic]Value),
        child_protos     = make([dynamic]^Proto),
        frame_slot_count = param_count,
    }
}

end_proto :: proc(proto_state: ^ProtoState) -> ^Proto {
    proto := new(Proto)
    proto^ = Proto{
        name             = proto_state.name,
        bytecode         = proto_state.bytecode[:],
        const_pool       = proto_state.const_pool[:],
        child_protos     = proto_state.child_protos[:],
        frame_slot_count = proto_state.frame_slot_count,
        param_count      = proto_state.param_count,
    }

    return proto
}

// Constants ======================================================================================

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

// Jump offsets are relative to the instruction after the jump.
// Current code assumes generated offsets fit the VM instruction layouts.

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
