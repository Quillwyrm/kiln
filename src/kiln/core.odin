package kiln

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"


// Native core-call policy:
// - Missing args read as nil, then normal argument validation reports the issue.
// - Extra args are runtime errors.
// - Native funcs return produced result count; CALL shapes returned values.

// Native argument validation ======================================================================

native_arg_value :: proc(kiln_state: ^State, args_base, arg_count, arg_index: int) -> Value {
    if arg_index >= arg_count {
        return Value{}
    }
    return kiln_state.slots[args_base + arg_index]
}

native_arg_array :: proc(kiln_state: ^State, args_base, arg_count, arg_index: int, fn_name, arg_name: string) -> (^ArrayObject, bool) {
    value := native_arg_value(kiln_state, args_base, arg_count, arg_index)
    header, is_object := value.(^Object)
    if !is_object || header.kind != .ARRAY {
        runtime_error(fmt.tprintf("`%s()` called with invalid %s argument; expected `array`, got `%s`", fn_name, arg_name, value_type_to_string(value)))
        return nil, false
    }

    return cast(^ArrayObject)header, true
}

native_arg_map :: proc(kiln_state: ^State, args_base, arg_count, arg_index: int, fn_name, arg_name: string) -> (^MapObject, bool) {
    value := native_arg_value(kiln_state, args_base, arg_count, arg_index)
    header, is_object := value.(^Object)
    if !is_object || header.kind != .MAP {
        runtime_error(fmt.tprintf("`%s()` called with invalid %s argument; expected `map`, got `%s`", fn_name, arg_name, value_type_to_string(value)))
        return nil, false
    }

    return cast(^MapObject)header, true
}

native_arg_string :: proc(kiln_state: ^State, args_base, arg_count, arg_index: int, fn_name, arg_name: string) -> (string, bool) {
    value := native_arg_value(kiln_state, args_base, arg_count, arg_index)
    header, is_object := value.(^Object)
    if !is_object || header.kind != .STRING {
        runtime_error(fmt.tprintf("`%s()` called with invalid %s argument; expected `string`, got `%s`", fn_name, arg_name, value_type_to_string(value)))
        return "", false
    }

    string_object := cast(^StringObject)header
    return string_object.data, true
}

native_arg_int :: proc(kiln_state: ^State, args_base, arg_count, arg_index: int, fn_name, arg_name: string) -> (i64, bool) {
    value := native_arg_value(kiln_state, args_base, arg_count, arg_index)
    int_value, is_int := value.(i64)
    if !is_int {
        runtime_error(fmt.tprintf("`%s()` called with invalid %s argument; expected `int`, got `%s`", fn_name, arg_name, value_type_to_string(value)))
        return 0, false
    }

    return int_value, true
}


// Debug module ===================================================================================

// echo(value) -> value
// returns the input value, or nil when omitted
native_debug_echo :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `debug.echo()`: expected 1, got %d", arg_count))
        return 0
    }

    if arg_count == 0 {
        kiln_state.slots[return_slot_base] = Value{}
        return 1
    }

    kiln_state.slots[return_slot_base] = kiln_state.slots[args_base]
    return 1
}


// OS module ======================================================================================

// argv() -> array
// returns raw invocation argument vector
native_os_argv :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `os.argv()`: expected 0, got %d", arg_count))
        return 0
    }

    argv := new(ArrayObject)
    argv.header.kind = .ARRAY
    argv.data = make([dynamic]Value)
    for arg in kiln_state.argv {
        append(&argv.data, Value(cast(^Object)new_string_object(arg)))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)argv)
    return 1
}

// args() -> array
// returns user script arguments, excluding script/program name
native_os_args :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `os.args()`: expected 0, got %d", arg_count))
        return 0
    }

    args := new(ArrayObject)
    args.header.kind = .ARRAY
    args.data = make([dynamic]Value)
    for arg in kiln_state.argv[kiln_state.args_start:] {
        append(&args.data, Value(cast(^Object)new_string_object(arg)))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)args)
    return 1
}

// exit(code)
// exits the process with integer status code
native_os_exit :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `os.exit()`: expected 1, got %d", arg_count))
        return 0
    }

    code_i64, code_is_int := native_arg_int(kiln_state, args_base, arg_count, 0, "os.exit", "first")
    if !code_is_int { return 0 }

    os.exit(int(code_i64))
}


// FS module ======================================================================================
// FS policy:
// - Caller contract errors are runtime errors:
//   wrong argument count, wrong argument type, missing required arguments.
// - Recoverable host filesystem failures are returned as string errors.
// - Predicate queries return bool.
// - list_dir returns direct entry names in host order, unsorted.
// - make_dir creates one directory level.
// - set_cwd mutates process cwd, so later relative paths use the new cwd.

// read_file(path) -> string | nil, err
// reads an entire text file, or returns nil and an error string on failure
native_fs_read_file :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.read_file()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.read_file", "first")
    if !path_is_string { return 0 }

    bytes, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        kiln_state.slots[return_slot_base] = Value{}
        kiln_state.slots[return_slot_base + 1] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.read_file()` failed for `%s`: %v", path, read_error)))
        return 2
    }
    defer delete(bytes)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(string(bytes)))
    kiln_state.slots[return_slot_base + 1] = Value{}
    return 2
}

// write_file(path, text) -> err | nil
// writes text to a file, replacing existing contents, or returns an error string on failure
native_fs_write_file :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `fs.write_file()`: expected 2, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.write_file", "first")
    if !path_is_string { return 0 }
    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "fs.write_file", "second")
    if !text_is_string { return 0 }

    write_error := os.write_entire_file(path, text)
    if write_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.write_file()` failed for `%s`: %v", path, write_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}

// get_cwd() -> string | nil, err
// returns current working directory, or nil and an error string on failure
native_fs_get_cwd :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `fs.get_cwd()`: expected 0, got %d", arg_count))
        return 0
    }

    cwd, cwd_error := os.get_working_directory(context.allocator)
    if cwd_error != nil {
        kiln_state.slots[return_slot_base] = Value{}
        kiln_state.slots[return_slot_base + 1] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.get_cwd()` failed: %v", cwd_error)))
        return 2
    }
    defer delete(cwd)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(cwd))
    kiln_state.slots[return_slot_base + 1] = Value{}
    return 2
}

// set_cwd(path) -> err | nil
// changes current working directory, or returns an error string on failure
native_fs_set_cwd :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.set_cwd()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.set_cwd", "first")
    if !path_is_string { return 0 }

    cwd_error := os.set_working_directory(path)
    if cwd_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.set_cwd()` failed for `%s`: %v", path, cwd_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}

// exists(path) -> bool
// returns true if a filesystem path exists
native_fs_exists :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.exists()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.exists", "first")
    if !path_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(os.exists(path))
    return 1
}

// is_file(path) -> bool
// returns true if path exists and is a regular file
native_fs_is_file :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.is_file()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.is_file", "first")
    if !path_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(os.is_file(path))
    return 1
}

// is_dir(path) -> bool
// returns true if path exists and is a directory
native_fs_is_dir :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.is_dir()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.is_dir", "first")
    if !path_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(os.is_dir(path))
    return 1
}

// list_dir(path) -> array | nil, err
// returns direct entry names inside a directory, or nil and an error string on failure
native_fs_list_dir :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.list_dir()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.list_dir", "first")
    if !path_is_string { return 0 }

    entries, list_error := os.read_all_directory_by_path(path, context.allocator)
    if list_error != nil {
        kiln_state.slots[return_slot_base] = Value{}
        kiln_state.slots[return_slot_base + 1] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.list_dir()` failed for `%s`: %v", path, list_error)))
        return 2
    }
    defer os.file_info_slice_delete(entries, context.allocator)

    entry_names := new(ArrayObject)
    entry_names.header.kind = .ARRAY
    entry_names.data = make([dynamic]Value)
    for entry in entries {
        append(&entry_names.data, Value(cast(^Object)new_string_object(entry.name)))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)entry_names)
    kiln_state.slots[return_slot_base + 1] = Value{}
    return 2
}

// make_dir(path) -> err | nil
// creates one directory level, or returns an error string on failure
native_fs_make_dir :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `fs.make_dir()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "fs.make_dir", "first")
    if !path_is_string { return 0 }

    make_error := os.make_directory(path)
    if make_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`fs.make_dir()` failed for `%s`: %v", path, make_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}


// Path module ====================================================================================
// Path functions are pure path-string transforms. They do not touch the filesystem.
// Caller contract errors are runtime errors. Allocation failure is a runtime error.

// join(parts...) -> string
// joins path parts using host path rules
native_path_join :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    parts := make([dynamic]string)
    defer delete(parts)

    for arg_index in 0..<arg_count {
        value := native_arg_value(kiln_state, args_base, arg_count, arg_index)
        header, is_object := value.(^Object)
        if !is_object || header.kind != .STRING {
            runtime_error(fmt.tprintf("`path.join()` called with invalid argument %d; expected `string`, got `%s`", arg_index + 1, value_type_to_string(value)))
            return 0
        }

        string_object := cast(^StringObject)header
        append(&parts, string_object.data)
    }

    joined, join_error := os.join_path(parts[:], context.allocator)
    if join_error != nil {
        runtime_error(fmt.tprintf("`path.join()` failed to allocate result string: %v", join_error))
        return 0
    }
    defer delete(joined)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(joined))
    return 1
}

// base_name(path) -> string
// returns final path component
native_path_base_name :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `path.base_name()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "path.base_name", "first")
    if !path_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(os.base(path)))
    return 1
}

// dir_name(path) -> string
// returns parent path component
native_path_dir_name :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `path.dir_name()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "path.dir_name", "first")
    if !path_is_string { return 0 }

    dir, _ := os.split_path(path)
    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(dir))
    return 1
}

// extension(path) -> string
// returns file extension, including the dot
native_path_extension :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `path.extension()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "path.extension", "first")
    if !path_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(os.ext(path)))
    return 1
}

// stem(path) -> string
// returns base file name without extension
native_path_stem :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `path.stem()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "path.stem", "first")
    if !path_is_string { return 0 }

    if path == "" {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(""))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(os.stem(path)))
    return 1
}

// normalize(path) -> string
// lexically cleans path text without checking filesystem
native_path_normalize :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `path.normalize()`: expected 1, got %d", arg_count))
        return 0
    }

    path, path_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "path.normalize", "first")
    if !path_is_string { return 0 }

    normalized, normalize_error := os.clean_path(path, context.allocator)
    if normalize_error != nil {
        runtime_error(fmt.tprintf("`path.normalize()` failed to allocate result string: %v", normalize_error))
        return 0
    }
    defer delete(normalized)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(normalized))
    return 1
}


// IO module ======================================================================================
// IO functions talk to host standard streams. Caller contract errors are runtime errors.
// Recoverable stream failures return error strings.

// read_all() -> string | nil, err
// reads all remaining stdin until EOF
native_io_read_all :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `io.read_all()`: expected 0, got %d", arg_count))
        return 0
    }

    data := make([dynamic]byte)
    defer delete(data)

    buffer: [4096]byte
    for {
        read_count, read_error := os.read(os.stdin, buffer[:])
        if read_count > 0 {
            append(&data, ..buffer[:read_count])
        }

        if read_error != nil {
            read_io_error, read_is_io_error := read_error.(io.Error)
            if read_is_io_error && read_io_error == .EOF {
                kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(string(data[:])))
                kiln_state.slots[return_slot_base + 1] = Value{}
                return 2
            }

            kiln_state.slots[return_slot_base] = Value{}
            kiln_state.slots[return_slot_base + 1] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.read_all()` failed: %v", read_error)))
            return 2
        }
    }
}

// read_line() -> string | nil, err
// reads one stdin line, or nil on EOF before any bytes
native_io_read_line :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `io.read_line()`: expected 0, got %d", arg_count))
        return 0
    }

    line := make([dynamic]byte)
    defer delete(line)

    buffer: [1]byte
    for {
        read_count, read_error := os.read(os.stdin, buffer[:])
        if read_count > 0 {
            if buffer[0] == '\n' {
                if len(line) > 0 && line[len(line) - 1] == '\r' {
                    pop(&line)
                }

                kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(string(line[:])))
                kiln_state.slots[return_slot_base + 1] = Value{}
                return 2
            }

            append(&line, buffer[0])
        }

        if read_error != nil {
            read_io_error, read_is_io_error := read_error.(io.Error)
            if read_is_io_error && read_io_error == .EOF {
                if len(line) == 0 {
                    kiln_state.slots[return_slot_base] = Value{}
                    kiln_state.slots[return_slot_base + 1] = Value{}
                    return 2
                }

                if line[len(line) - 1] == '\r' {
                    pop(&line)
                }

                kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(string(line[:])))
                kiln_state.slots[return_slot_base + 1] = Value{}
                return 2
            }

            kiln_state.slots[return_slot_base] = Value{}
            kiln_state.slots[return_slot_base + 1] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.read_line()` failed: %v", read_error)))
            return 2
        }
    }
}

// write(text) -> err | nil
// writes exact text to stdout, no newline
native_io_write :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `io.write()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "io.write", "first")
    if !text_is_string { return 0 }

    _, write_error := os.write_string(os.stdout, text)
    if write_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.write()` failed: %v", write_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}

// print(text) -> err | nil
// writes text to stdout, then newline
native_io_print :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `io.print()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "io.print", "first")
    if !text_is_string { return 0 }

    _, write_error := os.write_string(os.stdout, text)
    if write_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.print()` failed: %v", write_error)))
        return 1
    }

    _, newline_error := os.write_string(os.stdout, "\n")
    if newline_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.print()` failed: %v", newline_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}

// write_error(text) -> err | nil
// writes exact text to stderr, no newline
native_io_write_error :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `io.write_error()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "io.write_error", "first")
    if !text_is_string { return 0 }

    _, write_error := os.write_string(os.stderr, text)
    if write_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.write_error()` failed: %v", write_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}

// print_error(text) -> err | nil
// writes text to stderr, then newline
native_io_print_error :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `io.print_error()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "io.print_error", "first")
    if !text_is_string { return 0 }

    _, write_error := os.write_string(os.stderr, text)
    if write_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.print_error()` failed: %v", write_error)))
        return 1
    }

    _, newline_error := os.write_string(os.stderr, "\n")
    if newline_error != nil {
        kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(fmt.tprintf("`io.print_error()` failed: %v", newline_error)))
        return 1
    }

    kiln_state.slots[return_slot_base] = Value{}
    return 1
}


// Array module ===================================================================================

// push(array, value)
// appends value to the end of array
native_array_push :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `array.push()`: expected 2, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.push", "first")
    if !arg_is_array { return 0 }

    append(&array_object.data, native_arg_value(kiln_state, args_base, arg_count, 1))
    return 0
}

// pop(array) -> value
// removes and returns the final element
native_array_pop :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `array.pop()`: expected 1, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.pop", "first")
    if !arg_is_array { return 0 }

    if len(array_object.data) == 0 {
        runtime_error("`array.pop()` called on empty array")
        return 0
    }

    kiln_state.slots[return_slot_base] = pop(&array_object.data)
    return 1
}

// clear(array)
// removes all elements
native_array_clear :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `array.clear()`: expected 1, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.clear", "first")
    if !arg_is_array { return 0 }

    clear(&array_object.data)
    return 0
}

// copy(array) -> array
// returns a shallow copy
native_array_copy :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `array.copy()`: expected 1, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.copy", "first")
    if !arg_is_array { return 0 }

    copy_object := new(ArrayObject)
    copy_object.header.kind = .ARRAY
    copy_object.data = make([dynamic]Value)
    for value in array_object.data {
        append(&copy_object.data, value)
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)copy_object)
    return 1
}

// slice(array, start, count) -> array
// returns a shallow copied sub-array
native_array_slice :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 3 {
        runtime_error(fmt.tprintf("too many arguments for `array.slice()`: expected 3, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.slice", "first")
    if !arg_is_array { return 0 }
    start_i64, start_is_int := native_arg_int(kiln_state, args_base, arg_count, 1, "array.slice", "second")
    if !start_is_int { return 0 }
    count_i64, count_is_int := native_arg_int(kiln_state, args_base, arg_count, 2, "array.slice", "third")
    if !count_is_int { return 0 }

    start := int(start_i64)
    count := int(count_i64)
    if start < 0 || count < 0 || start > len(array_object.data) || count > len(array_object.data) - start {
        runtime_error(fmt.tprintf("`array.slice()` range invalid; start %d and count %d are out of bounds for array length %d", start, count, len(array_object.data)))
        return 0
    }

    slice_object := new(ArrayObject)
    slice_object.header.kind = .ARRAY
    slice_object.data = make([dynamic]Value)
    for value in array_object.data[start:start + count] {
        append(&slice_object.data, value)
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)slice_object)
    return 1
}

// insert(array, index, value)
// inserts value at index, shifting existing elements right
native_array_insert :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 3 {
        runtime_error(fmt.tprintf("too many arguments for `array.insert()`: expected 3, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.insert", "first")
    if !arg_is_array { return 0 }
    index_i64, index_is_int := native_arg_int(kiln_state, args_base, arg_count, 1, "array.insert", "second")
    if !index_is_int { return 0 }

    index := int(index_i64)
    if index < 0 || index > len(array_object.data) {
        runtime_error(fmt.tprintf("`array.insert()` index %d out of bounds for array length %d", index, len(array_object.data)))
        return 0
    }

    value := native_arg_value(kiln_state, args_base, arg_count, 2)
    append(&array_object.data, Value{})
    copy(array_object.data[index + 1:], array_object.data[index:len(array_object.data) - 1])
    array_object.data[index] = value
    return 0
}

// remove(array, index) -> value
// removes and returns element at index, shifting later elements left
native_array_remove :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `array.remove()`: expected 2, got %d", arg_count))
        return 0
    }

    array_object, arg_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "array.remove", "first")
    if !arg_is_array { return 0 }
    index_i64, index_is_int := native_arg_int(kiln_state, args_base, arg_count, 1, "array.remove", "second")
    if !index_is_int { return 0 }

    index := int(index_i64)
    if index < 0 || index >= len(array_object.data) {
        runtime_error(fmt.tprintf("`array.remove()` index %d out of bounds for array length %d", index, len(array_object.data)))
        return 0
    }

    removed := array_object.data[index]
    copy(array_object.data[index:], array_object.data[index + 1:])
    pop(&array_object.data)

    kiln_state.slots[return_slot_base] = removed
    return 1
}


// Map module =====================================================================================

// clear(map)
// removes all entries
native_map_clear :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `maps.clear()`: expected 1, got %d", arg_count))
        return 0
    }

    map_object, arg_is_map := native_arg_map(kiln_state, args_base, arg_count, 0, "maps.clear", "first")
    if !arg_is_map { return 0 }

    map_clear(map_object)
    return 0
}

// copy(map) -> map
// returns a shallow copy
native_map_copy :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `maps.copy()`: expected 1, got %d", arg_count))
        return 0
    }

    map_object, arg_is_map := native_arg_map(kiln_state, args_base, arg_count, 0, "maps.copy", "first")
    if !arg_is_map { return 0 }

    copy_object := new(MapObject)
    copy_object.header.kind = .MAP
    map_init(copy_object, map_object.count)
    for entry in map_object.entries {
        if entry.key == nil {
            continue
        }
        map_set(copy_object, entry.key, entry.value)
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)copy_object)
    return 1
}

// get_keys(map) -> array
// returns an array of keys
native_map_get_keys :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `maps.get_keys()`: expected 1, got %d", arg_count))
        return 0
    }

    map_object, arg_is_map := native_arg_map(kiln_state, args_base, arg_count, 0, "maps.get_keys", "first")
    if !arg_is_map { return 0 }

    keys := new(ArrayObject)
    keys.header.kind = .ARRAY
    keys.data = make([dynamic]Value)
    if map_object.count > 0 {
        reserve(&keys.data, map_object.count)
    }
    for entry in map_object.entries {
        if entry.key == nil {
            continue
        }
        append(&keys.data, Value(cast(^Object)entry.key))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)keys)
    return 1
}

// get_values(map) -> array
// returns an array of values
native_map_get_values :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `maps.get_values()`: expected 1, got %d", arg_count))
        return 0
    }

    map_object, arg_is_map := native_arg_map(kiln_state, args_base, arg_count, 0, "maps.get_values", "first")
    if !arg_is_map { return 0 }

    values := new(ArrayObject)
    values.header.kind = .ARRAY
    values.data = make([dynamic]Value)
    if map_object.count > 0 {
        reserve(&values.data, map_object.count)
    }
    for entry in map_object.entries {
        if entry.key == nil {
            continue
        }
        append(&values.data, entry.value)
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)values)
    return 1
}


// String module ==================================================================================

// contains(text, part) -> bool
// true if text contains part
native_string_contains :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.contains()`: expected 2, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.contains", "first")
    if !text_is_string { return 0 }
    part, part_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.contains", "second")
    if !part_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(strings.contains(text, part))
    return 1
}

// has_prefix(text, prefix) -> bool
// true if text starts with prefix
native_string_has_prefix :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.has_prefix()`: expected 2, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.has_prefix", "first")
    if !text_is_string { return 0 }
    prefix, prefix_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.has_prefix", "second")
    if !prefix_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(strings.has_prefix(text, prefix))
    return 1
}

// has_suffix(text, suffix) -> bool
// true if text ends with suffix
native_string_has_suffix :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.has_suffix()`: expected 2, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.has_suffix", "first")
    if !text_is_string { return 0 }
    suffix, suffix_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.has_suffix", "second")
    if !suffix_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(strings.has_suffix(text, suffix))
    return 1
}

// split(text, separator) -> array
// splits text into string pieces
native_string_split :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.split()`: expected 2, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.split", "first")
    if !text_is_string { return 0 }
    separator, separator_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.split", "second")
    if !separator_is_string { return 0 }

    parts, err := strings.split(text, separator)
    if err != nil {
        runtime_error("`string.split()` failed to allocate result array")
        return 0
    }
    defer delete(parts)

    parts_array := new(ArrayObject)
    parts_array.header.kind = .ARRAY
    parts_array.data = make([dynamic]Value)
    for part in parts {
        append(&parts_array.data, Value(cast(^Object)new_string_object(part)))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)parts_array)
    return 1
}

// slice(text, start, count) -> string
// returns substring by byte index/count, given current string model
native_string_slice :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 3 {
        runtime_error(fmt.tprintf("too many arguments for `string.slice()`: expected 3, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.slice", "first")
    if !text_is_string { return 0 }
    start_i64, start_is_int := native_arg_int(kiln_state, args_base, arg_count, 1, "string.slice", "second")
    if !start_is_int { return 0 }
    count_i64, count_is_int := native_arg_int(kiln_state, args_base, arg_count, 2, "string.slice", "third")
    if !count_is_int { return 0 }

    start := int(start_i64)
    count := int(count_i64)
    if start < 0 || count < 0 || start > len(text) || count > len(text) - start {
        runtime_error(fmt.tprintf("`string.slice()` range invalid; start %d and count %d are out of bounds for string length %d", start, count, len(text)))
        return 0
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(text[start:start + count]))
    return 1
}

// replace(text, old, new) -> string
// replaces occurrences of old with new
native_string_replace :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 3 {
        runtime_error(fmt.tprintf("too many arguments for `string.replace()`: expected 3, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.replace", "first")
    if !text_is_string { return 0 }
    old, old_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.replace", "second")
    if !old_is_string { return 0 }
    new, new_is_string := native_arg_string(kiln_state, args_base, arg_count, 2, "string.replace", "third")
    if !new_is_string { return 0 }

    result, result_was_allocation := strings.replace_all(text, old, new)
    if result_was_allocation {
        defer delete(result)
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(result))
    return 1
}

// trim(text) -> string
// removes leading/trailing whitespace
native_string_trim :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `string.trim()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.trim", "first")
    if !text_is_string { return 0 }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(strings.trim_space(text)))
    return 1
}

// to_lower(text) -> string
// returns lowercase text
native_string_to_lower :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `string.to_lower()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.to_lower", "first")
    if !text_is_string { return 0 }

    lower, err := strings.to_lower(text)
    if err != nil {
        runtime_error("`string.to_lower()` failed to allocate result string")
        return 0
    }
    defer delete(lower)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(lower))
    return 1
}

// to_upper(text) -> string
// returns uppercase text
native_string_to_upper :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `string.to_upper()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.to_upper", "first")
    if !text_is_string { return 0 }

    upper, err := strings.to_upper(text)
    if err != nil {
        runtime_error("`string.to_upper()` failed to allocate result string")
        return 0
    }
    defer delete(upper)

    kiln_state.slots[return_slot_base] = Value(cast(^Object)new_string_object(upper))
    return 1
}

// get_byte(text, index) -> int
// returns byte value at index
native_string_get_byte :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.get_byte()`: expected 2, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.get_byte", "first")
    if !text_is_string { return 0 }
    index_i64, index_is_int := native_arg_int(kiln_state, args_base, arg_count, 1, "string.get_byte", "second")
    if !index_is_int { return 0 }

    index := int(index_i64)
    if index < 0 || index >= len(text) {
        runtime_error(fmt.tprintf("`string.get_byte()` index %d out of bounds for string length %d", index, len(text)))
        return 0
    }

    kiln_state.slots[return_slot_base] = Value(i64(text[index]))
    return 1
}

// to_bytes(text) -> array
// returns array of byte ints
// join(parts, sep) -> string
// concatenates array elements as strings separated by sep; allocates result once
native_string_join :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 2 {
        runtime_error(fmt.tprintf("too many arguments for `string.join()`: expected 2, got %d", arg_count))
        return 0
    }

    parts_array, parts_is_array := native_arg_array(kiln_state, args_base, arg_count, 0, "string.join", "first")
    if !parts_is_array { return 0 }

    sep, sep_is_string := native_arg_string(kiln_state, args_base, arg_count, 1, "string.join", "second")
    if !sep_is_string { return 0 }

    part_count := len(parts_array.data)
    total_len := 0

    for i := 0; i < part_count; i += 1 {
        item := parts_array.data[i]
        header, is_object := item.(^Object)
        if !is_object || header.kind != .STRING {
            runtime_error(fmt.tprintf("`string.join()` called with invalid element at index %d; expected `string`, got `%s`", i, value_type_to_string(item)))
            return 0
        }

        string_obj := cast(^StringObject)header
        total_len += len(string_obj.data)
    }

    if part_count > 1 {
        total_len += len(sep) * (part_count - 1)
    }

    result_bytes := make([]byte, total_len)
    offset := 0

    for i := 0; i < part_count; i += 1 {
        header, _ := parts_array.data[i].(^Object)
        string_obj := cast(^StringObject)header

        offset += copy(result_bytes[offset:], transmute([]byte)string_obj.data)

        if i < part_count - 1 {
            offset += copy(result_bytes[offset:], transmute([]byte)sep)
        }
    }

    string_object := new(StringObject)
    string_object.header.kind = .STRING
    string_object.data = string(result_bytes)
    string_object.hash = 0

    kiln_state.slots[return_slot_base] = Value(cast(^Object)string_object)
    return 1
}

native_string_to_bytes :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `string.to_bytes()`: expected 1, got %d", arg_count))
        return 0
    }

    text, text_is_string := native_arg_string(kiln_state, args_base, arg_count, 0, "string.to_bytes", "first")
    if !text_is_string { return 0 }

    bytes := new(ArrayObject)
    bytes.header.kind = .ARRAY
    bytes.data = make([dynamic]Value)
    for byte_value in text {
        append(&bytes.data, Value(i64(byte_value)))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)bytes)
    return 1
}


// Core environment ===============================================================================

// Installs Kiln's default immutable root builtins into state.
bind_core_env :: proc(state: ^State) {
    Active_State = state
    bind_native_global("print", native_print)
    bind_native_global("type", native_type)
    bind_native_global("length", native_length)
    bind_native_global("assert", native_assert)
    bind_native_global("to_string", native_to_string)
    bind_native_global("to_number", native_to_number)
}

// Installs Kiln's default immutable native modules into state.
bind_core_modules :: proc(state: ^State) {
    Active_State = state

    debug_env := bind_env("debug")
    bind_env_native_function(debug_env, "echo", native_debug_echo)

    os_env := bind_env("os")
    bind_env_native_function(os_env, "argv", native_os_argv)
    bind_env_native_function(os_env, "args", native_os_args)
    bind_env_native_function(os_env, "exit", native_os_exit)

    fs_env := bind_env("fs")
    bind_env_native_function(fs_env, "read_file", native_fs_read_file)
    bind_env_native_function(fs_env, "write_file", native_fs_write_file)
    bind_env_native_function(fs_env, "get_cwd", native_fs_get_cwd)
    bind_env_native_function(fs_env, "set_cwd", native_fs_set_cwd)
    bind_env_native_function(fs_env, "exists", native_fs_exists)
    bind_env_native_function(fs_env, "is_file", native_fs_is_file)
    bind_env_native_function(fs_env, "is_dir", native_fs_is_dir)
    bind_env_native_function(fs_env, "list_dir", native_fs_list_dir)
    bind_env_native_function(fs_env, "make_dir", native_fs_make_dir)

    path_env := bind_env("path")
    bind_env_native_function(path_env, "join", native_path_join)
    bind_env_native_function(path_env, "base_name", native_path_base_name)
    bind_env_native_function(path_env, "dir_name", native_path_dir_name)
    bind_env_native_function(path_env, "extension", native_path_extension)
    bind_env_native_function(path_env, "stem", native_path_stem)
    bind_env_native_function(path_env, "normalize", native_path_normalize)

    io_env := bind_env("io")
    bind_env_native_function(io_env, "read_all", native_io_read_all)
    bind_env_native_function(io_env, "read_line", native_io_read_line)
    bind_env_native_function(io_env, "write", native_io_write)
    bind_env_native_function(io_env, "print", native_io_print)
    bind_env_native_function(io_env, "write_error", native_io_write_error)
    bind_env_native_function(io_env, "print_error", native_io_print_error)

    array_env := bind_env("array")
    bind_env_native_function(array_env, "push", native_array_push)
    bind_env_native_function(array_env, "pop", native_array_pop)
    bind_env_native_function(array_env, "clear", native_array_clear)
    bind_env_native_function(array_env, "copy", native_array_copy)
    bind_env_native_function(array_env, "slice", native_array_slice)
    bind_env_native_function(array_env, "insert", native_array_insert)
    bind_env_native_function(array_env, "remove", native_array_remove)

    map_env := bind_env("maps")
    bind_env_native_function(map_env, "clear", native_map_clear)
    bind_env_native_function(map_env, "copy", native_map_copy)
    bind_env_native_function(map_env, "get_keys", native_map_get_keys)
    bind_env_native_function(map_env, "get_values", native_map_get_values)

    string_env := bind_env("string")
    bind_env_native_function(string_env, "contains", native_string_contains)
    bind_env_native_function(string_env, "has_prefix", native_string_has_prefix)
    bind_env_native_function(string_env, "has_suffix", native_string_has_suffix)
    bind_env_native_function(string_env, "split", native_string_split)
    bind_env_native_function(string_env, "slice", native_string_slice)
    bind_env_native_function(string_env, "replace", native_string_replace)
    bind_env_native_function(string_env, "trim", native_string_trim)
    bind_env_native_function(string_env, "to_lower", native_string_to_lower)
    bind_env_native_function(string_env, "to_upper", native_string_to_upper)
    bind_env_native_function(string_env, "get_byte", native_string_get_byte)
    bind_env_native_function(string_env, "to_bytes", native_string_to_bytes)
    bind_env_native_function(string_env, "join", native_string_join)
}

