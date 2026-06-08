package kiln

import "core:strings"

// Proto-local bindings ===========================================================================

// LocalBinding stores the name and mutability of one local frame slot.
// Its index in ProtoState.local_bindings is its frame slot.
LocalBinding :: struct {
    name:       string,
    is_mutable: bool,
}

// Proto state ====================================================================================

// ProtoState is the mutable compiler working state for one unfinished Proto.
// begin_proto creates its dynamic arrays; end_proto or delete_proto_state releases them.
ProtoState :: struct {
    // Proto identity and current-file compile context.
    origin:         SourceLocation,
    name:           string,
    param_count:    int,
    is_function:    bool,
    is_module:      bool,
    module_index:   int,

    // Unfinished compiled output copied into Proto by end_proto.
    bytecode:     [dynamic]u32,
    const_pool:   [dynamic]Value,
    child_protos: [dynamic]^Proto,

    // Frame-slot and lexical-local working state.
    frame_slot_count:  int,
    local_bindings:    [MAX_FRAME_SLOTS]LocalBinding,
    local_count:       int,
    next_temp_slot:    int,
    scope_local_marks: [dynamic]int,

    // Imported namespaces visible throughout this file and its child protos.
    import_names:          [MAX_MODULES]string,
    import_module_indexes: [MAX_MODULES]int,
    import_count:          int,

    // Unresolved control-flow jumps owned by active loops.
    // Each break fixup is an unresolved jump instruction index.
    break_jump_fixups:      [dynamic]int,
    // Each active loop records where its entries begin in break_jump_fixups.
    loop_break_fixup_bases: [dynamic]int,
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
begin_proto :: proc(origin: SourceLocation, name: string, param_count: int, is_function: bool) -> ProtoState {
    return ProtoState{
        origin                  = origin,
        name                    = strings.clone(name),
        param_count             = param_count,
        is_function             = is_function,
        frame_slot_count        = param_count,
        bytecode                = make([dynamic]u32),
        const_pool              = make([dynamic]Value),
        child_protos            = make([dynamic]^Proto),
        scope_local_marks       = make([dynamic]int),
        break_jump_fixups       = make([dynamic]int),
        loop_break_fixup_bases  = make([dynamic]int),
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
    delete(proto_state.scope_local_marks)
    delete(proto_state.break_jump_fixups)
    delete(proto_state.loop_break_fixup_bases)

    proto := new(Proto)
    proto^ = Proto{
        origin           = proto_state.origin,
        name             = proto_state.name,
        is_module        = proto_state.is_module,
        bytecode         = bytecode,
        const_pool       = const_pool,
        child_protos     = child_protos,
        frame_slot_count = proto_state.frame_slot_count,
        param_count      = proto_state.param_count,
    }

    return proto
}

// Releases an unfinished ProtoState after compile failure. Successful compilation uses end_proto.
delete_proto_state :: proc(proto_state: ^ProtoState) {
    delete(proto_state.name)
    delete(proto_state.bytecode)
    delete(proto_state.const_pool)
    delete(proto_state.child_protos)
    delete(proto_state.scope_local_marks)
    delete(proto_state.break_jump_fixups)
    delete(proto_state.loop_break_fixup_bases)
}

// Constants ======================================================================================
const_int :: proc(proto_state: ^ProtoState, value: i64) -> int {
    for const_index := 0; const_index < len(proto_state.const_pool); const_index += 1 {
        existing, is_int := proto_state.const_pool[const_index].(i64)
        if is_int && existing == value {
            return const_index
        }
    }

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
    for const_index := 0; const_index < len(proto_state.const_pool); const_index += 1 {
        existing, is_float := proto_state.const_pool[const_index].(f64)
        if is_float && existing == value {
            return const_index
        }
    }

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
    for const_index := 0; const_index < len(proto_state.const_pool); const_index += 1 {
        object, is_object := proto_state.const_pool[const_index].(^Object)
        if !is_object || object.kind != .STRING {
            continue
        }

        string_object := cast(^StringObject)object
        if string_object.data == text {
            return const_index
        }
    }

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
    if dst == src {
        return
    }

    record_slots(proto_state, dst, src)

    inst := u32(InstABx{ op= .MOVE, a= u8(dst), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

// Array operations ===============================================================================
emit_new_array :: proc(proto_state: ^ProtoState, dst, capacity: int) -> int {
    record_slots(proto_state, dst)

    inst_index := len(proto_state.bytecode)
    inst := u32(InstABx{ op= .NEW_ARRAY, a= u8(dst), b= u16(capacity) })
    append(&proto_state.bytecode, inst)

    return inst_index
}

patch_new_array_capacity :: proc(proto_state: ^ProtoState, inst_index, capacity: int) {
    inst := InstABx(proto_state.bytecode[inst_index])
    proto_state.bytecode[inst_index] = u32(InstABx{
        op = .NEW_ARRAY,
        a  = inst.a,
        b  = u16(capacity),
    })
}

// emit_array_len :: proc(proto_state: ^ProtoState, dst, src_array: int) {
//     record_slots(proto_state, dst, src_array)
//
//     inst := u32(InstABx{ op= .ARRAY_LEN, a= u8(dst), b= u16(src_array) })
//     append(&proto_state.bytecode, inst)
// }

emit_array_push :: proc(proto_state: ^ProtoState, dst_array, src: int) {
    record_slots(proto_state, dst_array, src)

    inst := u32(InstABx{ op= .ARRAY_PUSH, a= u8(dst_array), b= u16(src) })
    append(&proto_state.bytecode, inst)
}

// emit_array_pop :: proc(proto_state: ^ProtoState, dst, src_array: int) {
//     record_slots(proto_state, dst, src_array)
//
//     inst := u32(InstABx{ op= .ARRAY_POP, a= u8(dst), b= u16(src_array) })
//     append(&proto_state.bytecode, inst)
// }

// Map operations =================================================================================

emit_new_map :: proc(proto_state: ^ProtoState, dst, capacity: int) -> int {
    record_slots(proto_state, dst)

    inst_index := len(proto_state.bytecode)
    inst := u32(InstABx{ op= .NEW_MAP, a= u8(dst), b= u16(capacity) })
    append(&proto_state.bytecode, inst)

    return inst_index
}

patch_new_map_capacity :: proc(proto_state: ^ProtoState, inst_index, capacity: int) {
    inst := InstABx(proto_state.bytecode[inst_index])
    proto_state.bytecode[inst_index] = u32(InstABx{
        op = .NEW_MAP,
        a  = inst.a,
        b  = u16(capacity),
    })
}

// emit_map_len :: proc(proto_state: ^ProtoState, dst, src_map: int) {
//     record_slots(proto_state, dst, src_map)
//
//     inst := u32(InstABx{ op= .MAP_LEN, a= u8(dst), b= u16(src_map) })
//     append(&proto_state.bytecode, inst)
// }

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

emit_array_get_const :: proc(proto_state: ^ProtoState, dst, array_slot, const_idx: int) {
    record_slots(proto_state, dst, array_slot)

    inst := u32(InstABC{ op= .ARRAY_GET_CONST, a= u8(dst), b= u8(array_slot), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_array_set_const :: proc(proto_state: ^ProtoState, array_slot, const_idx, src: int) {
    record_slots(proto_state, array_slot, src)

    inst := u32(InstABC{ op= .ARRAY_SET_CONST, a= u8(array_slot), b= u8(const_idx), c= u8(src) })
    append(&proto_state.bytecode, inst)
}

emit_map_get_const :: proc(proto_state: ^ProtoState, dst, map_slot, const_idx: int) {
    record_slots(proto_state, dst, map_slot)

    inst := u32(InstABC{ op= .MAP_GET_CONST, a= u8(dst), b= u8(map_slot), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_map_set_const :: proc(proto_state: ^ProtoState, map_slot, const_idx, src: int) {
    record_slots(proto_state, map_slot, src)

    inst := u32(InstABC{ op= .MAP_SET_CONST, a= u8(map_slot), b= u8(const_idx), c= u8(src) })
    append(&proto_state.bytecode, inst)
}

// Arithmetic and concatenation operations ========================================================

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

emit_concat :: proc(proto_state: ^ProtoState, dst, lhs, rhs: int) {
    record_slots(proto_state, dst, lhs, rhs)

    inst := u32(InstABC{ op= .CONCAT, a= u8(dst), b= u8(lhs), c= u8(rhs) })
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

emit_add_const :: proc(proto_state: ^ProtoState, dst, lhs, const_idx: int) {
    record_slots(proto_state, dst, lhs)

    inst := u32(InstABC{ op= .ADD_CONST, a= u8(dst), b= u8(lhs), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_sub_const :: proc(proto_state: ^ProtoState, dst, lhs, const_idx: int) {
    record_slots(proto_state, dst, lhs)

    inst := u32(InstABC{ op= .SUB_CONST, a= u8(dst), b= u8(lhs), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_mul_const :: proc(proto_state: ^ProtoState, dst, lhs, const_idx: int) {
    record_slots(proto_state, dst, lhs)

    inst := u32(InstABC{ op= .MUL_CONST, a= u8(dst), b= u8(lhs), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_div_const :: proc(proto_state: ^ProtoState, dst, lhs, const_idx: int) {
    record_slots(proto_state, dst, lhs)

    inst := u32(InstABC{ op= .DIV_CONST, a= u8(dst), b= u8(lhs), c= u8(const_idx) })
    append(&proto_state.bytecode, inst)
}

emit_mod_const :: proc(proto_state: ^ProtoState, dst, lhs, const_idx: int) {
    record_slots(proto_state, dst, lhs)

    inst := u32(InstABC{ op= .MOD_CONST, a= u8(dst), b= u8(lhs), c= u8(const_idx) })
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
        if offset < MIN_COND_JUMP_OFFSET || offset > MAX_COND_JUMP_OFFSET {
            set_error(proto_state.origin, "conditional jump is too far")
            Parser.failed = true
            return jump_index
        }
    }

    inst := u32(InstAsBx{ op= .JUMP_FALSE, a= u8(cond_slot), sb= i16(offset) })
    append(&proto_state.bytecode, inst)

    return jump_index
}

emit_jump_not_nil :: proc(proto_state: ^ProtoState, cond_slot: int, target_index: int = -1) -> int {
    record_slots(proto_state, cond_slot)

    jump_index := next_inst_index(proto_state)
    offset := 0
    if target_index >= 0 {
        offset = target_index - (jump_index + 1)
        if offset < MIN_COND_JUMP_OFFSET || offset > MAX_COND_JUMP_OFFSET {
            set_error(proto_state.origin, "conditional jump is too far")
            Parser.failed = true
            return jump_index
        }
    }

    inst := u32(InstAsBx{ op= .JUMP_NOT_NIL, a= u8(cond_slot), sb= i16(offset) })
    append(&proto_state.bytecode, inst)

    return jump_index
}

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

    if op == .JUMP_FALSE || op == .JUMP_NOT_NIL {
        if offset < MIN_COND_JUMP_OFFSET || offset > MAX_COND_JUMP_OFFSET {
            set_error(proto_state.origin, "conditional jump is too far")
            Parser.failed = true
            return
        }

        old_inst := InstAsBx(word)
        inst := u32(InstAsBx{ op= op, a= old_inst.a, sb= i16(offset) })
        proto_state.bytecode[jump_index] = inst
        return
    }

    panic("patch_jump expected JUMP or conditional jump")
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

retarget_last_abc_result :: proc(proto_state: ^ProtoState, old_dst, new_dst: int) -> bool {
    if old_dst == new_dst {
        return true
    }

    if len(proto_state.bytecode) == 0 {
        return false
    }

    word_index := len(proto_state.bytecode) - 1
    word := proto_state.bytecode[word_index]
    op := decode_op(word)

    #partial switch op {
    case .ADD, .SUB, .CONCAT, .MUL, .DIV, .MOD, .EQUAL, .LESS, .LESS_OR_EQUAL:
        inst := InstABC(word)
        if int(inst.a) != old_dst {
            return false
        }

        inst.a = u8(new_dst)
        proto_state.bytecode[word_index] = u32(inst)
        record_slots(proto_state, new_dst)
        return true
    }

    return false
}

// Main binding instructions ======================================================================

emit_get_main_bind :: proc(proto_state: ^ProtoState, dst: int, binding_index: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .GET_MAIN_BIND, a= u8(dst), b= u16(binding_index) })
    append(&proto_state.bytecode, inst)
}

emit_set_main_bind :: proc(proto_state: ^ProtoState, src: int, binding_index: int) {
    record_slots(proto_state, src)

    inst := u32(InstABx{ op= .SET_MAIN_BIND, a= u8(src), b= u16(binding_index) })
    append(&proto_state.bytecode, inst)
}

// Module binding instructions ====================================================================

emit_get_module_bind :: proc(proto_state: ^ProtoState, dst, module_index, binding_index: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABC{ op= .GET_MODULE_BIND, a= u8(dst), b= u8(module_index), c= u8(binding_index) })
    append(&proto_state.bytecode, inst)
}

emit_set_module_bind :: proc(proto_state: ^ProtoState, src, module_index, binding_index: int) {
    record_slots(proto_state, src)

    inst := u32(InstABC{ op= .SET_MODULE_BIND, a= u8(src), b= u8(module_index), c= u8(binding_index) })
    append(&proto_state.bytecode, inst)
}

// Global binding instructions ====================================================================

emit_get_global_bind :: proc(proto_state: ^ProtoState, dst: int, binding_index: int) {
    record_slots(proto_state, dst)

    inst := u32(InstABx{ op= .GET_GLOBAL_BIND, a= u8(dst), b= u16(binding_index) })
    append(&proto_state.bytecode, inst)
}

emit_set_global_bind :: proc(proto_state: ^ProtoState, src: int, binding_index: int) {
    record_slots(proto_state, src)

    inst := u32(InstABx{ op= .SET_GLOBAL_BIND, a= u8(src), b= u16(binding_index) })
    append(&proto_state.bytecode, inst)
}
