package compiler

import "../vm"
import "../kiln"



// Emitter state ===============================================================================

Ctx := struct {
    function_table:   [dynamic]^vm.ObjectHeader,
    function_index:   int,
    name:             string,
    param_count:      int,
    bytecode:         [dynamic]u32,
    const_pool:       [dynamic]vm.Value,
    frame_slot_count: int,
}{}

// Internals ======================================================================================

record_slots :: proc(slots: ..int) {
    for slot in slots {
        required_slots := slot + 1
        if required_slots > Ctx.frame_slot_count {
            Ctx.frame_slot_count = required_slots
        }
    }
}

bind_native_global :: proc(globals: ^vm.MapObject, name: string, native_proc: vm.FunctionNative) {
    native_function := new(vm.FunctionNativeObject)
    native_function.header.kind = .FUNCTION_NATIVE
    native_function.name = name
    native_function.native_proc = native_proc

    globals.data[name] = vm.Value(cast(^vm.ObjectHeader)native_function)
}

bind_global_env :: proc() -> ^vm.MapObject {
    globals := new(vm.MapObject)
    globals.header.kind = .MAP
    globals.data = make(map[string]vm.Value)

    bind_native_global(globals, "print", kiln.native_print)
    bind_native_global(globals, "type", kiln.native_type)
    bind_native_global(globals, "length", kiln.native_length)
    bind_native_global(globals, "assert", kiln.native_assert)
    bind_native_global(globals, "to_string", kiln.native_to_string)
    bind_native_global(globals, "to_number", kiln.native_to_number)

    return globals
}

// VM state construction ==========================================================================

build_vm_state :: proc() -> vm.State {
    return vm.State{
        function_table = Ctx.function_table[:],
        globals        = bind_global_env(),
    }
}


// Proto construction =============================================================================

begin_proto :: proc(name: string, param_count: int) -> int {
    function_index := len(Ctx.function_table)
    append(&Ctx.function_table, nil)

    Ctx.function_index = function_index
    Ctx.name = name
    Ctx.param_count = param_count
    Ctx.bytecode = make([dynamic]u32)
    Ctx.const_pool = make([dynamic]vm.Value)
    Ctx.frame_slot_count = param_count

    return function_index
}

end_proto :: proc() -> int {
    proto := new(vm.FunctionProto)
    proto^ = vm.FunctionProto{
        name             = Ctx.name,
        bytecode         = Ctx.bytecode[:],
        const_pool       = Ctx.const_pool[:],
        frame_slot_count = Ctx.frame_slot_count,
        param_count      = Ctx.param_count,
    }

    function_object := new(vm.FunctionProtoObject)
    function_object^ = vm.FunctionProtoObject{
        header = vm.ObjectHeader{kind = .FUNCTION_PROTO},
        name   = Ctx.name,
        proto  = proto,
    }

    function_index := Ctx.function_index
    Ctx.function_table[function_index] = &function_object.header

    return function_index
}



// Constants ======================================================================================

const_int :: proc(value: i64) -> int {
    const_index := len(Ctx.const_pool)
    append(&Ctx.const_pool, vm.Value(value))

    return const_index
}

const_float :: proc(value: f64) -> int {
    const_index := len(Ctx.const_pool)
    append(&Ctx.const_pool, vm.Value(value))

    return const_index
}

const_string :: proc(text: string) -> int {
    string_object := new(vm.StringObject)
    string_object.header.kind = .STRING
    string_object.data = text

    const_index := len(Ctx.const_pool)
    append(&Ctx.const_pool, vm.Value(cast(^vm.ObjectHeader)string_object))

    return const_index
}

// Instruction Emitters ======================================================================================

// Loads ==========================================================================================

emit_load_nil :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_NIL, a= u32(dst) })
    append(&Ctx.bytecode, inst)
}

emit_load_true :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_TRUE, a= u32(dst) })
    append(&Ctx.bytecode, inst)
}

emit_load_false :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstAx{ op= .LOAD_FALSE, a= u32(dst) })
    append(&Ctx.bytecode, inst)
}

emit_load_const :: proc(dst, const_index: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .LOAD_CONST, a= u8(dst), b= u16(const_index) })
    append(&Ctx.bytecode, inst)
}

emit_load_func :: proc(dst, function_index: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .LOAD_FUNC, a= u8(dst), b= u16(function_index) })
    append(&Ctx.bytecode, inst)
}

emit_move :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .MOVE, a= u8(dst), b= u16(src) })
    append(&Ctx.bytecode, inst)
}


// Array operations ===============================================================================

emit_new_array :: proc(dst, array_cap: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .NEW_ARRAY, a= u8(dst), b= u16(array_cap) })
    append(&Ctx.bytecode, inst)
}

emit_array_len :: proc(dst, src_array: int) {
    record_slots(dst, src_array)

    inst := u32(vm.InstABx{ op= .ARRAY_LEN, a= u8(dst), b= u16(src_array) })
    append(&Ctx.bytecode, inst)
}

emit_array_get :: proc(dst, src_array, index: int) {
    record_slots(dst, src_array, index)

    inst := u32(vm.InstABC{ op= .ARRAY_GET, a= u8(dst), b= u8(src_array), c= u8(index) })
    append(&Ctx.bytecode, inst)
}

emit_array_set :: proc(dst_array, src, index: int) {
    record_slots(dst_array, src, index)

    inst := u32(vm.InstABC{ op= .ARRAY_SET, a= u8(dst_array), b= u8(src), c= u8(index) })
    append(&Ctx.bytecode, inst)
}

emit_array_push :: proc(dst_array, src: int) {
    record_slots(dst_array, src)

    inst := u32(vm.InstABx{ op= .ARRAY_PUSH, a= u8(dst_array), b= u16(src) })
    append(&Ctx.bytecode, inst)
}

emit_array_pop :: proc(dst, src_array: int) {
    record_slots(dst, src_array)

    inst := u32(vm.InstABx{ op= .ARRAY_POP, a= u8(dst), b= u16(src_array) })
    append(&Ctx.bytecode, inst)
}


// Map operations =================================================================================

emit_new_map :: proc(dst: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .NEW_MAP, a= u8(dst), b= 0 })
    append(&Ctx.bytecode, inst)
}

emit_map_len :: proc(dst, src_map: int) {
    record_slots(dst, src_map)

    inst := u32(vm.InstABx{ op= .MAP_LEN, a= u8(dst), b= u16(src_map) })
    append(&Ctx.bytecode, inst)
}

emit_map_get :: proc(dst, src_map, key: int) {
    record_slots(dst, src_map, key)

    inst := u32(vm.InstABC{ op= .MAP_GET, a= u8(dst), b= u8(src_map), c= u8(key) })
    append(&Ctx.bytecode, inst)
}

emit_map_set :: proc(dst_map, key, src: int) {
    record_slots(dst_map, key, src)

    inst := u32(vm.InstABC{ op= .MAP_SET, a= u8(dst_map), b= u8(key), c= u8(src) })
    append(&Ctx.bytecode, inst)
}


// Numeric operations =============================================================================

emit_add :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .ADD, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_sub :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .SUB, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_mul :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .MUL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_div :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .DIV, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_neg :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .NEG, a= u8(dst), b= u16(src) })
    append(&Ctx.bytecode, inst)
}


// Comparison and boolean operations ==============================================================

emit_equal :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_less :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .LESS, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_less_or_equal :: proc(dst, lhs, rhs: int) {
    record_slots(dst, lhs, rhs)

    inst := u32(vm.InstABC{ op= .LESS_OR_EQUAL, a= u8(dst), b= u8(lhs), c= u8(rhs) })
    append(&Ctx.bytecode, inst)
}

emit_not :: proc(dst, src: int) {
    record_slots(dst, src)

    inst := u32(vm.InstABx{ op= .NOT, a= u8(dst), b= u16(src) })
    append(&Ctx.bytecode, inst)
}


// Jumps and patching =============================================================================

// Jump offsets are relative to the instruction after the jump.
// Current code assumes generated offsets fit the VM instruction layouts.

next_inst_index :: proc() -> int {
    return len(Ctx.bytecode)
}

emit_jump :: proc(target_index: int = -1) -> int {
    jump_index := next_inst_index()
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
    }

    inst := u32(vm.InstJump{ op= .JUMP, offset= i32(offset) })
    append(&Ctx.bytecode, inst)

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
    append(&Ctx.bytecode, inst)

    return jump_index
}

patch_jump :: proc(jump_index: int) {
    word := Ctx.bytecode[jump_index]
    target_index := next_inst_index()
    offset := target_index - (jump_index + 1)

    op := vm.decode_op(word)
    if op == .JUMP {
        inst := u32(vm.InstJump{ op= .JUMP, offset= i32(offset) })
        Ctx.bytecode[jump_index] = inst
        return
    }

    if op == .JUMP_FALSE {
        old_inst := vm.InstAsBx(word)
        inst := u32(vm.InstAsBx{ op= .JUMP_FALSE, a= old_inst.a, sb= i16(offset) })
        Ctx.bytecode[jump_index] = inst
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

    inst := u32(vm.InstABC{ op= .CALL, a= u8(call_base), b= u8(arg_count), c= u8(requested_results) })
    append(&Ctx.bytecode, inst)
}


emit_return :: proc(first_slot, result_count: int) {
    if result_count > 0 {
        record_slots(first_slot + result_count - 1)
    }

    inst := u32(vm.InstABx{ op= .RETURN, a= u8(first_slot), b= u16(result_count) })
    append(&Ctx.bytecode, inst)
}

emit_halt :: proc() {
    inst := u32(vm.InstABC{ op= .HALT })
    append(&Ctx.bytecode, inst)
}


// Global bindings ================================================================================

emit_get_global :: proc(dst, name_const: int) {
    record_slots(dst)

    inst := u32(vm.InstABx{ op= .GET_GLOBAL, a= u8(dst), b= u16(name_const) })
    append(&Ctx.bytecode, inst)
}

emit_set_global :: proc(src, name_const: int) {
    record_slots(src)

    inst := u32(vm.InstABx{ op= .SET_GLOBAL, a= u8(src), b= u16(name_const) })
    append(&Ctx.bytecode, inst)
}
