package kiln

import "core:fmt"
import "core:os"
import "core:strings"

disasm_value_text :: proc(value: Value) -> string {
    object, is_object := value.(^Object)
    if is_object && object.kind == .STRING {
        string_object := cast(^StringObject)object
        return fmt.tprintf("\"%s\"", string_object.data)
    }

    return value_to_string(value)
}

disasm_append_line :: proc(parts: ^[dynamic]string, body, comment: string) {
    append(parts, body)

    if comment != "" {
        comment_column := 48

        for i := len(body); i < comment_column; i += 1 {
            append(parts, " ")
        }

        append(parts, "; ")
        append(parts, comment)
    }

    append(parts, "\n")
}

disasm_append_proto_sections :: proc(parts: ^[dynamic]string, state: ^State, proto: ^Proto) {
    if len(proto.const_pool) > 0 {
        append(parts, "\n")
        append(parts, "    constants\n")

        for const_index := 0; const_index < len(proto.const_pool); const_index += 1 {
            append(parts, fmt.tprintf("        C%d = %s\n", const_index, disasm_value_text(proto.const_pool[const_index])))
        }
    }

    if len(proto.child_protos) > 0 {
        append(parts, "\n")
        append(parts, "    children\n")

        for child_index := 0; child_index < len(proto.child_protos); child_index += 1 {
            append(parts, fmt.tprintf("        P%d = %s\n", child_index, proto.child_protos[child_index].name))
        }
    }

    main_refs:   [MAX_BINDINGS]bool
    global_refs: [MAX_BINDINGS]bool
    module_refs: [MAX_MODULES][MAX_BINDINGS]bool
    has_bindings := false

    for ip := 0; ip < len(proto.bytecode); ip += 1 {
        word := proto.bytecode[ip]
        op := decode_op(word)

        #partial switch op {
        case .GET_MAIN_BIND, .SET_MAIN_BIND:
            inst := InstABx(word)
            binding_index := int(inst.b)

            main_refs[binding_index] = true
            has_bindings = true

        case .GET_GLOBAL_BIND, .SET_GLOBAL_BIND:
            inst := InstABx(word)
            binding_index := int(inst.b)

            global_refs[binding_index] = true
            has_bindings = true

        case .GET_MODULE_BIND, .SET_MODULE_BIND:
            inst := InstABC(word)
            module_index := int(inst.b)
            binding_index := int(inst.c)

            module_refs[module_index][binding_index] = true
            has_bindings = true

        case:
        }
    }

    if has_bindings {
        append(parts, "\n")
        append(parts, "    bindings\n")

        for binding_index := 0; binding_index < state.main_env.count; binding_index += 1 {
            if main_refs[binding_index] {
                append(parts, fmt.tprintf("        B%d = %s\n", binding_index, state.main_env.names[binding_index]))
            }
        }

        for binding_index := 0; binding_index < state.global_env.count; binding_index += 1 {
            if global_refs[binding_index] {
                append(parts, fmt.tprintf("        G%d = %s\n", binding_index, state.global_env.names[binding_index]))
            }
        }

        for module_index := 0; module_index < state.module_count; module_index += 1 {
            module_env := &state.module_envs[module_index]

            for binding_index := 0; binding_index < module_env.count; binding_index += 1 {
                if module_refs[module_index][binding_index] {
                    append(parts, fmt.tprintf(
                        "        M%d.B%d = %s.%s\n",
                        module_index,
                        binding_index,
                        state.module_ids[module_index],
                        module_env.names[binding_index],
                    ))
                }
            }
        }
    }
}

disasm_append_code :: proc(parts: ^[dynamic]string, state: ^State, proto: ^Proto) {
    label_for_ip := make([]int, len(proto.bytecode))
    defer delete(label_for_ip)

    for ip := 0; ip < len(label_for_ip); ip += 1 {
        label_for_ip[ip] = -1
    }

    for ip := 0; ip < len(proto.bytecode); ip += 1 {
        word := proto.bytecode[ip]
        op := decode_op(word)

        #partial switch op {
        case .JUMP:
            inst := InstJump(word)
            target_ip := ip + 1 + int(inst.offset)

            if target_ip >= 0 && target_ip < len(label_for_ip) {
                label_for_ip[target_ip] = 0
            }

        case .JUMP_FALSE, .JUMP_NOT_NIL:
            inst := InstAsBx(word)
            target_ip := ip + 1 + int(inst.sb)

            if target_ip >= 0 && target_ip < len(label_for_ip) {
                label_for_ip[target_ip] = 0
            }

        case:
        }
    }

    next_label := 0
    for ip := 0; ip < len(label_for_ip); ip += 1 {
        if label_for_ip[ip] >= 0 {
            label_for_ip[ip] = next_label
            next_label += 1
        }
    }

    append(parts, "\n")
    append(parts, "    code\n")

    for ip := 0; ip < len(proto.bytecode); ip += 1 {
        if label_for_ip[ip] >= 0 {
            append(parts, fmt.tprintf("    J%d:\n", label_for_ip[ip]))
        }

        word := proto.bytecode[ip]
        op := decode_op(word)

        #partial switch op {
        case .LOAD_NIL:
            inst := InstAx(word)
            body := fmt.tprintf("        %04d    LOAD_NIL         R%d", ip, inst.a)
            disasm_append_line(parts, body, "")

        case .LOAD_TRUE:
            inst := InstAx(word)
            body := fmt.tprintf("        %04d    LOAD_TRUE        R%d", ip, inst.a)
            disasm_append_line(parts, body, "")

        case .LOAD_FALSE:
            inst := InstAx(word)
            body := fmt.tprintf("        %04d    LOAD_FALSE       R%d", ip, inst.a)
            disasm_append_line(parts, body, "")

        case .LOAD_CONST:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    LOAD_CONST       R%d, C%d", ip, inst.a, inst.b)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_line(parts, body, comment)

        case .LOAD_FUNC:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    LOAD_FUNC        R%d, P%d", ip, inst.a, inst.b)
            comment := proto.child_protos[int(inst.b)].name
            disasm_append_line(parts, body, comment)

        case .MOVE:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    MOVE             R%d, R%d", ip, inst.a, inst.b)
            disasm_append_line(parts, body, "")

        case .NEW_ARRAY:
            inst := InstAx(word)
            body := fmt.tprintf("        %04d    NEW_ARRAY        R%d", ip, inst.a)
            disasm_append_line(parts, body, "")

        case .ARRAY_PUSH:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    ARRAY_PUSH       R%d, R%d", ip, inst.a, inst.b)
            disasm_append_line(parts, body, "")

        case .NEW_MAP:
            inst := InstAx(word)
            body := fmt.tprintf("        %04d    NEW_MAP          R%d", ip, inst.a)
            disasm_append_line(parts, body, "")

        case .INDEX_GET:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    INDEX_GET        R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .INDEX_SET:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    INDEX_SET        R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .ADD:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    ADD              R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .SUB:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    SUB              R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .CONCAT:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    CONCAT           R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .MUL:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    MUL              R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .DIV:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    DIV              R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .MOD:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    MOD              R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .NEG:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    NEG              R%d, R%d", ip, inst.a, inst.b)
            disasm_append_line(parts, body, "")

        case .EQUAL:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    EQUAL            R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .LESS:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    LESS             R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    LESS_OR_EQUAL    R%d, R%d, R%d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .NOT:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    NOT              R%d, R%d", ip, inst.a, inst.b)
            disasm_append_line(parts, body, "")

        case .JUMP:
            inst := InstJump(word)
            target_ip := ip + 1 + int(inst.offset)
            body := fmt.tprintf("        %04d    JUMP             J%d", ip, label_for_ip[target_ip])
            disasm_append_line(parts, body, fmt.tprintf("%+d", inst.offset))

        case .JUMP_FALSE:
            inst := InstAsBx(word)
            target_ip := ip + 1 + int(inst.sb)
            body := fmt.tprintf("        %04d    JUMP_FALSE       R%d, J%d", ip, inst.a, label_for_ip[target_ip])
            disasm_append_line(parts, body, fmt.tprintf("%+d", inst.sb))

        case .JUMP_NOT_NIL:
            inst := InstAsBx(word)
            target_ip := ip + 1 + int(inst.sb)
            body := fmt.tprintf("        %04d    JUMP_NOT_NIL     R%d, J%d", ip, inst.a, label_for_ip[target_ip])
            disasm_append_line(parts, body, fmt.tprintf("%+d", inst.sb))

        case .CALL:
            inst := InstABC(word)
            body := fmt.tprintf("        %04d    CALL             R%d, %d, %d", ip, inst.a, inst.b, inst.c)
            disasm_append_line(parts, body, "")

        case .RETURN:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    RETURN           R%d, %d", ip, inst.a, inst.b)
            disasm_append_line(parts, body, "")

        case .GET_MAIN_BIND:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    GET_MAIN_BIND    R%d, B%d", ip, inst.a, inst.b)
            comment := state.main_env.names[int(inst.b)]
            disasm_append_line(parts, body, comment)

        case .SET_MAIN_BIND:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    SET_MAIN_BIND    R%d, B%d", ip, inst.a, inst.b)
            comment := state.main_env.names[int(inst.b)]
            disasm_append_line(parts, body, comment)

        case .GET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.module_envs[int(inst.b)]
            body := fmt.tprintf("        %04d    GET_MODULE_BIND  R%d, M%d.B%d", ip, inst.a, inst.b, inst.c)
            comment := fmt.tprintf("%s.%s", state.module_ids[int(inst.b)], module_env.names[int(inst.c)])
            disasm_append_line(parts, body, comment)

        case .SET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.module_envs[int(inst.b)]
            body := fmt.tprintf("        %04d    SET_MODULE_BIND  R%d, M%d.B%d", ip, inst.a, inst.b, inst.c)
            comment := fmt.tprintf("%s.%s", state.module_ids[int(inst.b)], module_env.names[int(inst.c)])
            disasm_append_line(parts, body, comment)

        case .GET_GLOBAL_BIND:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    GET_GLOBAL_BIND  R%d, G%d", ip, inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_line(parts, body, comment)

        case .SET_GLOBAL_BIND:
            inst := InstABx(word)
            body := fmt.tprintf("        %04d    SET_GLOBAL_BIND  R%d, G%d", ip, inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_line(parts, body, comment)
        }
    }
}

disasm_append_child_proto :: proc(parts: ^[dynamic]string, state: ^State, proto: ^Proto) {
    append(parts, "\n")
    append(parts, fmt.tprintf("proto %s\n", proto.name))
    append(parts, fmt.tprintf("    params %d\n", proto.param_count))
    append(parts, fmt.tprintf("    slots %d\n", proto.frame_slot_count))
    append(parts, fmt.tprintf("    ops %d\n", len(proto.bytecode)))

    disasm_append_proto_sections(parts, state, proto)
    disasm_append_code(parts, state, proto)

    for child_index := 0; child_index < len(proto.child_protos); child_index += 1 {
        disasm_append_child_proto(parts, state, proto.child_protos[child_index])
    }
}

disassemble_file :: proc(state: ^State, path: string) -> (string, ^Error) {
    Active_State = state
    state.has_error = false
    state.error = Error{}

    source_bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        location := SourceLocation{source_name = path, line = 0, column = 0}
        return "", set_error(location, fmt.tprintf("failed to read '%s'", path))
    }
    defer delete(source_bytes)

    compile_error := compile_source(string(source_bytes), path)
    if compile_error != nil {
        return "", compile_error
    }

    entry := state.entry_proto

    parts := make([dynamic]string)
    defer delete(parts)

    append(&parts, path)
    append(&parts, "\n\n")

    append(&parts, "entry\n")
    append(&parts, fmt.tprintf("    slots %d\n", entry.frame_slot_count))
    append(&parts, fmt.tprintf("    ops %d\n", len(entry.bytecode)))

    disasm_append_proto_sections(&parts, state, entry)
    disasm_append_code(&parts, state, entry)

    for child_index := 0; child_index < len(entry.child_protos); child_index += 1 {
        disasm_append_child_proto(&parts, state, entry.child_protos[child_index])
    }

    return strings.concatenate(parts[:]), nil
}
