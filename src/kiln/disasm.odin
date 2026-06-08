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

DISASM_OPCODE_WIDTH :: 19

disasm_append_inst :: proc(parts: ^[dynamic]string, ip: int, op_name, operands, comment: string) {
    body := fmt.tprintf("        %04d    %s", ip, op_name)

    for i := len(op_name); i < DISASM_OPCODE_WIDTH; i += 1 {
        body = strings.concatenate({body, " "})
    }

    if operands != "" {
        body = strings.concatenate({body, operands})
    }

    disasm_append_line(parts, body, comment)
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
            operands := fmt.tprintf("R%d", inst.a)
            disasm_append_inst(parts, ip, "LOAD_NIL", operands, "")

        case .LOAD_TRUE:
            inst := InstAx(word)
            operands := fmt.tprintf("R%d", inst.a)
            disasm_append_inst(parts, ip, "LOAD_TRUE", operands, "")

        case .LOAD_FALSE:
            inst := InstAx(word)
            operands := fmt.tprintf("R%d", inst.a)
            disasm_append_inst(parts, ip, "LOAD_FALSE", operands, "")

        case .LOAD_CONST:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, C%d", inst.a, inst.b)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_inst(parts, ip, "LOAD_CONST", operands, comment)

        case .LOAD_FUNC:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, P%d", inst.a, inst.b)
            comment := proto.child_protos[int(inst.b)].name
            disasm_append_inst(parts, ip, "LOAD_FUNC", operands, comment)

        case .MOVE:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, R%d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "MOVE", operands, "")

        case .NEW_ARRAY:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, %d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "NEW_ARRAY", operands, "")

        case .ARRAY_PUSH:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, R%d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "ARRAY_PUSH", operands, "")

        case .NEW_MAP:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, %d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "NEW_MAP", operands, "")

        case .INDEX_GET:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "INDEX_GET", operands, "")

        case .INDEX_SET:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "INDEX_SET", operands, "")

        case .ARRAY_GET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "ARRAY_GET_CONST", operands, comment)

        case .ARRAY_SET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, C%d, R%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_inst(parts, ip, "ARRAY_SET_CONST", operands, comment)

        case .MAP_GET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "MAP_GET_CONST", operands, comment)

        case .MAP_SET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, C%d, R%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_inst(parts, ip, "MAP_SET_CONST", operands, comment)

        case .ADD:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "ADD", operands, "")

        case .SUB:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "SUB", operands, "")

        case .CONCAT:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "CONCAT", operands, "")

        case .MUL:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "MUL", operands, "")

        case .DIV:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "DIV", operands, "")

        case .MOD:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "MOD", operands, "")

        case .ADD_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "ADD_CONST", operands, comment)

        case .SUB_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "SUB_CONST", operands, comment)

        case .MUL_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "MUL_CONST", operands, comment)

        case .DIV_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "DIV_CONST", operands, comment)

        case .MOD_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "MOD_CONST", operands, comment)

        case .NEG:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, R%d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "NEG", operands, "")

        case .EQUAL:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "EQUAL", operands, "")

        case .LESS:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "LESS", operands, "")

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "LESS_OR_EQUAL", operands, "")

        case .NOT:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, R%d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "NOT", operands, "")

        case .JUMP:
            inst := InstJump(word)
            target_ip := ip + 1 + int(inst.offset)
            operands := fmt.tprintf("J%d", label_for_ip[target_ip])
            disasm_append_inst(parts, ip, "JUMP", operands, fmt.tprintf("%+d", inst.offset))

        case .JUMP_FALSE:
            inst := InstAsBx(word)
            target_ip := ip + 1 + int(inst.sb)
            operands := fmt.tprintf("R%d, J%d", inst.a, label_for_ip[target_ip])
            disasm_append_inst(parts, ip, "JUMP_FALSE", operands, fmt.tprintf("%+d", inst.sb))

        case .JUMP_NOT_NIL:
            inst := InstAsBx(word)
            target_ip := ip + 1 + int(inst.sb)
            operands := fmt.tprintf("R%d, J%d", inst.a, label_for_ip[target_ip])
            disasm_append_inst(parts, ip, "JUMP_NOT_NIL", operands, fmt.tprintf("%+d", inst.sb))

        case .CALL:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, %d, %d", inst.a, inst.b, inst.c)
            disasm_append_inst(parts, ip, "CALL", operands, "")

        case .RETURN:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, %d", inst.a, inst.b)
            disasm_append_inst(parts, ip, "RETURN", operands, "")

        case .GET_MAIN_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, B%d", inst.a, inst.b)
            comment := state.main_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "GET_MAIN_BIND", operands, comment)

        case .SET_MAIN_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, B%d", inst.a, inst.b)
            comment := state.main_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "SET_MAIN_BIND", operands, comment)

        case .GET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.module_envs[int(inst.b)]
            operands := fmt.tprintf("R%d, M%d.B%d", inst.a, inst.b, inst.c)
            comment := fmt.tprintf("%s.%s", state.module_ids[int(inst.b)], module_env.names[int(inst.c)])
            disasm_append_inst(parts, ip, "GET_MODULE_BIND", operands, comment)

        case .SET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.module_envs[int(inst.b)]
            operands := fmt.tprintf("R%d, M%d.B%d", inst.a, inst.b, inst.c)
            comment := fmt.tprintf("%s.%s", state.module_ids[int(inst.b)], module_env.names[int(inst.c)])
            disasm_append_inst(parts, ip, "SET_MODULE_BIND", operands, comment)

        case .GET_GLOBAL_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, G%d", inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "GET_GLOBAL_BIND", operands, comment)

        case .SET_GLOBAL_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, G%d", inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "SET_GLOBAL_BIND", operands, comment)
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
