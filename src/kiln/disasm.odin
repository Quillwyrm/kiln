package kiln

import "core:fmt"
import "core:os"
import "core:strings"
import filepath "core:path/filepath"

disasm_value_text :: proc(value: Value) -> string {
    object, is_object := value.(^Object)
    if is_object && object.kind == .STRING {
        string_object := cast(^StringObject)object
        return fmt.tprintf("\"%s\"", string_object.data)
    }

    if is_object && object.kind == .STRUCT_DEF {
        struct_def := cast(^StructDefObject)object
        return fmt.tprintf("struct %s", struct_def.name)
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
            append(parts, fmt.tprintf("        P%d = %s\n", child_index, proto.child_protos[child_index].proto_label))
        }
    }

    file_refs:    [MAX_BINDINGS]bool
    global_refs:  [MAX_BINDINGS]bool
    env_refs:     [MAX_ENVS][MAX_BINDINGS]bool
    has_bindings := false

    for ip := 0; ip < len(proto.bytecode); ip += 1 {
        word := proto.bytecode[ip]
        op := decode_op(word)

        #partial switch op {
        case .GET_FILE_BIND, .SET_FILE_BIND:
            inst := InstABx(word)
            binding_index := int(inst.b)

            file_refs[binding_index] = true
            has_bindings = true

        case .GET_GLOBAL_BIND, .DECL_GLOBAL_BIND, .SET_GLOBAL_BIND:
            inst := InstABx(word)
            binding_index := int(inst.b)

            global_refs[binding_index] = true
            has_bindings = true

        case .GET_MODULE_BIND, .SET_MODULE_BIND:
            inst := InstABC(word)
            env_index := int(inst.b)
            binding_index := int(inst.c)

            env_refs[env_index][binding_index] = true
            has_bindings = true

        case:
        }
    }

    if has_bindings {
        append(parts, "\n")
        append(parts, "    bindings\n")

        file_env := &state.envs[proto.env_index]
        for binding_index := 0; binding_index < file_env.count; binding_index += 1 {
            if file_refs[binding_index] {
                append(parts, fmt.tprintf("        B%d = %s\n", binding_index, file_env.names[binding_index]))
            }
        }

        for binding_index := 0; binding_index < state.global_env.count; binding_index += 1 {
            if global_refs[binding_index] {
                append(parts, fmt.tprintf("        G%d = %s\n", binding_index, state.global_env.names[binding_index]))
            }
        }

        for env_index := 1; env_index < state.env_count; env_index += 1 {
            env := &state.envs[env_index]
            module_name := module_namespace_from_path(env.id)

            for binding_index := 0; binding_index < env.count; binding_index += 1 {
                if env_refs[env_index][binding_index] {
                    append(parts, fmt.tprintf(
                        "        M%d.B%d = %s.%s\n",
                        env_index,
                        binding_index,
                        module_name,
                        env.names[binding_index],
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
            comment := proto.child_protos[int(inst.b)].proto_label
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

        case .NEW_STRUCT:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, C%d", inst.a, inst.b)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_inst(parts, ip, "NEW_STRUCT", operands, comment)

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

        case .STRUCT_GET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.c)])
            disasm_append_inst(parts, ip, "STRUCT_GET_CONST", operands, comment)

        case .STRUCT_SET_CONST:
            inst := InstABC(word)
            operands := fmt.tprintf("R%d, C%d, R%d", inst.a, inst.b, inst.c)
            comment := disasm_value_text(proto.const_pool[int(inst.b)])
            disasm_append_inst(parts, ip, "STRUCT_SET_CONST", operands, comment)

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

        case .GET_FILE_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, B%d", inst.a, inst.b)
            comment := state.envs[proto.env_index].names[int(inst.b)]
            disasm_append_inst(parts, ip, "GET_FILE_BIND", operands, comment)

        case .SET_FILE_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, B%d", inst.a, inst.b)
            comment := state.envs[proto.env_index].names[int(inst.b)]
            disasm_append_inst(parts, ip, "SET_FILE_BIND", operands, comment)

        case .GET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.envs[int(inst.b)]
            operands := fmt.tprintf("R%d, M%d.B%d", inst.a, inst.b, inst.c)
            module_name := module_namespace_from_path(module_env.id)
            comment := fmt.tprintf("%s.%s", module_name, module_env.names[int(inst.c)])
            disasm_append_inst(parts, ip, "GET_MODULE_BIND", operands, comment)

        case .SET_MODULE_BIND:
            inst := InstABC(word)
            module_env := &state.envs[int(inst.b)]
            operands := fmt.tprintf("R%d, M%d.B%d", inst.a, inst.b, inst.c)
            module_name := module_namespace_from_path(module_env.id)
            comment := fmt.tprintf("%s.%s", module_name, module_env.names[int(inst.c)])
            disasm_append_inst(parts, ip, "SET_MODULE_BIND", operands, comment)

        case .GET_GLOBAL_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, G%d", inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "GET_GLOBAL_BIND", operands, comment)

        case .DECL_GLOBAL_BIND:
            inst := InstABx(word)
            operands := fmt.tprintf("R%d, G%d", inst.a, inst.b)
            comment := state.global_env.names[int(inst.b)]
            disasm_append_inst(parts, ip, "DECL_GLOBAL_BIND", operands, comment)

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
    append(parts, fmt.tprintf("proto %s\n", proto.proto_label))
    if proto.has_vararg {
        append(parts, fmt.tprintf("    params %d + vararg\n", proto.param_count - 1))
    } else {
        append(parts, fmt.tprintf("    params %d\n", proto.param_count))
    }
    append(parts, fmt.tprintf("    slots %d\n", proto.frame_slot_count))
    append(parts, fmt.tprintf("    ops %d\n", len(proto.bytecode)))

    disasm_append_proto_sections(parts, state, proto)
    disasm_append_code(parts, state, proto)

    for child_index := 0; child_index < len(proto.child_protos); child_index += 1 {
        disasm_append_child_proto(parts, state, proto.child_protos[child_index])
    }
}

disassemble_file :: proc(state: ^State, path: string) -> (string, string) {
    Active_State = state
    state.error_string = ""

    resolved_path, abs_err := filepath.abs(path, context.allocator)
    if abs_err != nil {
        return "", set_error(fmt.tprintf("Error: failed to resolve path `%s`", path))
    }
    defer delete(resolved_path)

    source_bytes, read_error := os.read_entire_file(resolved_path, context.allocator)
    if read_error != nil {
        return "", set_error(fmt.tprintf("Error: failed to read `%s`", resolved_path))
    }
    defer delete(source_bytes)

    compile_error := compile_source(string(source_bytes), resolved_path)
    if compile_error != "" {
        return "", compile_error
    }

    entry := state.entry_proto

    parts := make([dynamic]string)
    defer delete(parts)

    append(&parts, resolved_path)
    append(&parts, "\n\n")

    append(&parts, "entry\n")
    append(&parts, fmt.tprintf("    slots %d\n", entry.frame_slot_count))
    append(&parts, fmt.tprintf("    ops %d\n", len(entry.bytecode)))

    disasm_append_proto_sections(&parts, state, entry)
    disasm_append_code(&parts, state, entry)

    for child_index := 0; child_index < len(entry.child_protos); child_index += 1 {
        disasm_append_child_proto(&parts, state, entry.child_protos[child_index])
    }

    return strings.concatenate(parts[:]), ""
}
