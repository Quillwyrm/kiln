package compiler

import "../vm"

// Emitter state ==================================================================================

Emitter := struct {
    entry_function:   ^vm.ProtoFunctionObject,
    global_env:       vm.BindingTable,
    name:             string,
    param_count:      int,
    bytecode:         [dynamic]u32,
    const_pool:       [dynamic]vm.Value,
    child_protos:     [dynamic]^vm.Proto,
    frame_slot_count: int,
}{}

// Internals ======================================================================================

record_slots :: proc(slots: ..int) {
    for slot in slots {
        required_slots := slot + 1
        if required_slots > Emitter.frame_slot_count {
            Emitter.frame_slot_count = required_slots
        }
    }
}

bind_global :: proc(name: string) -> vm.BindingId {
    for binding_index := 0; binding_index < Emitter.global_env.count; binding_index += 1 {
        if Emitter.global_env.names[binding_index] == name {
            return vm.BindingId(binding_index)
        }
    }

    binding_id := vm.BindingId(Emitter.global_env.count)
    Emitter.global_env.names[Emitter.global_env.count] = name
    Emitter.global_env.count += 1

    return binding_id
}

bind_native_global :: proc(name: string, native_proc: vm.NativeFunction) {
    native_function := new(vm.NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.name = name
    native_function.impl = native_proc

    binding_id := bind_global(name)
    Emitter.global_env.values[int(binding_id)] = vm.Value(cast(^vm.Object)native_function)
}

// VM state construction ==========================================================================

build_vm_state :: proc() -> vm.State {
    return vm.State{
        entry_function = Emitter.entry_function,
        global_env     = Emitter.global_env,
    }
}


// Proto construction =============================================================================

begin_proto :: proc(name: string, param_count: int) {
    Emitter.name = name
    Emitter.param_count = param_count
    Emitter.bytecode = make([dynamic]u32)
    Emitter.const_pool = make([dynamic]vm.Value)
    Emitter.child_protos = make([dynamic]^vm.Proto)
    Emitter.frame_slot_count = param_count
}

end_proto :: proc() {
    proto := new(vm.Proto)
    proto^ = vm.Proto{
        name             = Emitter.name,
        bytecode         = Emitter.bytecode[:],
        const_pool       = Emitter.const_pool[:],
        child_protos     = Emitter.child_protos[:],
        frame_slot_count = Emitter.frame_slot_count,
        param_count      = Emitter.param_count,
    }

    function_object := new(vm.ProtoFunctionObject)
    function_object^ = vm.ProtoFunctionObject{
        header = vm.Object{kind = .PROTO_FUNCTION},
        name   = Emitter.name,
        impl  = proto,
    }

    Emitter.entry_function = function_object
}

// Constants ======================================================================================

const_int :: proc(value: i64) -> int {
    const_index := len(Emitter.const_pool)
    append(&Emitter.const_pool, vm.Value(value))

    return const_index
}

const_float :: proc(value: f64) -> int {
    const_index := len(Emitter.const_pool)
    append(&Emitter.const_pool, vm.Value(value))

    return const_index
}

const_string :: proc(text: string) -> int {
    string_object := new(vm.StringObject)
    string_object.header.kind = .STRING
    string_object.data = text

    const_index := len(Emitter.const_pool)
    append(&Emitter.const_pool, vm.Value(cast(^vm.Object)string_object))

    return const_index
}

// Instruction emitters ===========================================================================

// Loads ==========================================================================================

emit_load_nil :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_NIL, a= u32(dst) })
    append(&Emitter.bytecode, inst)
}

emit_load_true :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_TRUE, a= u32(dst) })
    append(&Emitter.bytecode, inst)
}

emit_load_false :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_FALSE, a= u32(dst) })
    append(&Emitter.bytecode, inst)
}

emit_load_const :: proc(dst, const_index: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .LOAD_CONST, a= u8(dst), b= u16(const_index) })
    append(&Emitter.bytecode, inst)
}

emit_load_func :: proc(dst, child_proto_index: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .LOAD_FUNC, a= u8(dst), b= u16(child_proto_index) })
    append(&Emitter.bytecode, inst)
}

emit_move :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .MOVE, a= u8(dst), b= u16(src) })
    append(&Emitter.bytecode, inst)
}

// Array operations ===============================================================================

emit_new_array :: proc(dst, array_cap: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .NEW_ARRAY, a= u8(dst), b= u16(array_cap) })
    append(&Emitter.bytecode, inst)
}

emit_array_len :: proc(dst, src_array: int) {
    record_slots(dst, src_array)

    inst := u32(vm.InstABx{ op= .ARRAY_LEN, a= u8(dst), b= u16(src_array) })
    append(&Emitter.bytecode, inst)
}

emit_array_get :: proc(dst, src_array, index: int) {
    record_slots(dst, src_array, index)

    inst := u32(vm.InstABC{ op= .ARRAY_GET, a= u8(dst), b= u8(src_array), c= u8(index) })
    append(&Emitter.bytecode, inst)
}

emit_array_set :: proc(dst_array, src, index: int) {
    record_slots(dst_array, src, index)

    inst := u32(vm.InstABC{ op= .ARRAY_SET, a= u8(dst_array), b= u8(src), c= u8(index) })
    append(&Emitter.bytecode, inst)
}

emit_array_push :: proc(dst_array, src: int) {
    record_slots(dst_array, src)

    inst := u32(vm.InstABx{ op= .ARRAY_PUSH, a= u8(dst_array), b= u16(src) })
    append(&Emitter.bytecode, inst)
}

emit_array_pop :: proc(dst, src_array: int) {
    record_slots(dst, src_array)

    inst := u32(vm.InstABx{ op= .ARRAY_POP, a= u8(dst), b= u16(src_array) })
    append(&Emitter.bytecode, inst)
}

// Map operations =================================================================================

emit_new_map :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .NEW_MAP, a= u8(dst), b= 0 })
    append(&Emitter.bytecode, inst)
}

emit_map_len :: proc(dst, src_map: int) {
    record_slots(dst, src_map)

    inst := u32(vm.InstABx{ op= .MAP_LEN, a= u8(dst), b= u16(src_map) })
    append(&Emitter.bytecode, inst)
}

emit_map_get :: proc(dst, src_map, key: int) {
    record_slots(dst, src_map, key)

    inst := u32(vm.InstABC{ op= .MAP_GET, a= u8(dst), b= u8(src_map), c= u8(key) })
    append(&Emitter.bytecode, inst)
}

emit_map_set :: proc(dst_map, key, src: int) {
    record_slots(dst_map, key, src)

    inst := u32(vm.InstABC{ op= .MAP_SET, a= u8(dst_map), b= u8(key), c= u8(src) })
    append(&Emitter.bytecode, inst)
}

// Numeric operations =============================================================================

emit_add :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .ADD, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_sub :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .SUB, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_mul :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .MUL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_div :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .DIV, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_neg :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .NEG, a= u8(dst), b= u16(src) })
    append(&Emitter.bytecode, inst)
}

// Comparison and boolean operations ==============================================================

emit_equal :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_less :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .LESS, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_less_or_equal :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .LESS_OR_EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Emitter.bytecode, inst)
}

emit_not :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .NOT, a= u8(dst), b= u16(src) })
    append(&Emitter.bytecode, inst)
}

// Jumps and patching =============================================================================

// Jump offsets are relative to the instruction after the jump.
// Current code assumes generated offsets fit the VM instruction layouts.

next_inst_index :: proc() -> int {
    return len(Emitter.bytecode)
}

emit_jump :: proc(target_index: int = -1) -> int {
    jump_index := next_inst_index()
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
    }

    inst := u32(vm.InstJump{ op= .JUMP, offset= i32(offset) })
    append(&Emitter.bytecode, inst)

    return jump_index
}

emit_jump_false :: proc(cond_slot: int, target_index: int = -1) -> int {
    record_slots(cond_slot)

    jump_index := next_inst_index()
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
    }

    inst := u32(vm.InstAsBx{ op= .JUMP_FALSE, a= u8(cond_slot), sb= i16(offset) })
    append(&Emitter.bytecode, inst)

    return jump_index
}

patch_jump :: proc(jump_index: int) {
    word := Emitter.bytecode[jump_index]
    target_index := next_inst_index()
    offset := target_index - (jump_index + 1)

    op := vm.decode_op(word)
    if op == .JUMP {
        inst := u32(vm.InstJump{ op= .JUMP, offset= i32(offset) })
        Emitter.bytecode[jump_index] = inst
        return
    }

    if op == .JUMP_FALSE {
        old_inst := vm.InstAsBx(word)
        inst := u32(vm.InstAsBx{ op= .JUMP_FALSE, a= old_inst.a, sb= i16(offset) })
        Emitter.bytecode[jump_index] = inst
        return
    }

    panic("patch_jump expected JUMP or JUMP_FALSE")
}

// Calls and returns ==============================================================================

emit_call :: proc(call_base, arg_count, requested_results: int) {
    occupied_call_slots := arg_count + 1
    if requested_results > occupied_call_slots {
        occupied_call_slots = requested_results
    }
    record_slots(call_base + occupied_call_slots - 1)

    inst := u32(vm.InstABC{
        op= .CALL,
        a= u8(call_base),
        b= u8(arg_count),
        c= u8(requested_results),
    })
    append(&Emitter.bytecode, inst)
}

emit_return :: proc(first_slot, result_count: int) {
    if result_count > 0 {
        record_slots(first_slot + result_count - 1)
    }

    inst := u32(vm.InstABx{ op= .RETURN, a= u8(first_slot), b= u16(result_count) })
    append(&Emitter.bytecode, inst)
}

emit_halt :: proc() {
    inst := u32(vm.InstABC{ op= .HALT })
    append(&Emitter.bytecode, inst)
}

// Global bindings ================================================================================

emit_get_global :: proc(dst: int, binding_id: vm.BindingId) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .GET_GLOBAL, a= u8(dst), b= u16(int(binding_id)) })
    append(&Emitter.bytecode, inst)
}

emit_set_global :: proc(src: int, binding_id: vm.BindingId) {
    record_slots(src)

    inst := u32(vm.InstABx{ op= .SET_GLOBAL, a= u8(src), b= u16(int(binding_id)) })
    append(&Emitter.bytecode, inst)
}
