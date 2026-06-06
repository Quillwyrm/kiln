package kiln

import "core:fmt"
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


// System module ==================================================================================

// argv() -> array
// returns raw invocation argument vector
native_system_argv :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `system.argv()`: expected 0, got %d", arg_count))
        return 0
    }

    argv := new(ArrayObject)
    argv.header.kind = .ARRAY
    argv.data = make([dynamic]Value)
    for arg in kiln_state.argv {
        append(&argv.data, new_string_value(arg))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)argv)
    return 1
}

// args() -> array
// returns user script arguments, excluding script/program name
native_system_args :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 0 {
        runtime_error(fmt.tprintf("too many arguments for `system.args()`: expected 0, got %d", arg_count))
        return 0
    }

    args := new(ArrayObject)
    args.header.kind = .ARRAY
    args.data = make([dynamic]Value)
    for arg in kiln_state.argv[kiln_state.args_start:] {
        append(&args.data, new_string_value(arg))
    }

    kiln_state.slots[return_slot_base] = Value(cast(^Object)args)
    return 1
}

// exit(code)
// exits the process with integer status code
native_system_exit :: proc(kiln_state: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int {
    if arg_count > 1 {
        runtime_error(fmt.tprintf("too many arguments for `system.exit()`: expected 1, got %d", arg_count))
        return 0
    }

    code_i64, code_is_int := native_arg_int(kiln_state, args_base, arg_count, 0, "system.exit", "first")
    if !code_is_int { return 0 }

    os.exit(int(code_i64))
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

    clear(&map_object.data)
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
    copy_object.data = make(map[string]Value)
    for key, value in map_object.data {
        copy_object.data[key] = value
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
    for key in map_object.data {
        append(&keys.data, new_string_value(key))
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
    for _, value in map_object.data {
        append(&values.data, value)
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
        append(&parts_array.data, new_string_value(part))
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

    kiln_state.slots[return_slot_base] = new_string_value(text[start:start + count])
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

    kiln_state.slots[return_slot_base] = new_string_value(result)
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

    kiln_state.slots[return_slot_base] = new_string_value(strings.trim_space(text))
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

    kiln_state.slots[return_slot_base] = new_string_value(lower)
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

    kiln_state.slots[return_slot_base] = new_string_value(upper)
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

    debug_module := bind_module("debug")
    bind_module_native_function(debug_module, "echo", native_debug_echo)

    system_module := bind_module("system")
    bind_module_native_function(system_module, "argv", native_system_argv)
    bind_module_native_function(system_module, "args", native_system_args)
    bind_module_native_function(system_module, "exit", native_system_exit)

    array_module := bind_module("array")
    bind_module_native_function(array_module, "push", native_array_push)
    bind_module_native_function(array_module, "pop", native_array_pop)
    bind_module_native_function(array_module, "clear", native_array_clear)
    bind_module_native_function(array_module, "copy", native_array_copy)
    bind_module_native_function(array_module, "slice", native_array_slice)
    bind_module_native_function(array_module, "insert", native_array_insert)
    bind_module_native_function(array_module, "remove", native_array_remove)

    map_module := bind_module("maps")
    bind_module_native_function(map_module, "clear", native_map_clear)
    bind_module_native_function(map_module, "copy", native_map_copy)
    bind_module_native_function(map_module, "get_keys", native_map_get_keys)
    bind_module_native_function(map_module, "get_values", native_map_get_values)

    string_module := bind_module("string")
    bind_module_native_function(string_module, "contains", native_string_contains)
    bind_module_native_function(string_module, "has_prefix", native_string_has_prefix)
    bind_module_native_function(string_module, "has_suffix", native_string_has_suffix)
    bind_module_native_function(string_module, "split", native_string_split)
    bind_module_native_function(string_module, "slice", native_string_slice)
    bind_module_native_function(string_module, "replace", native_string_replace)
    bind_module_native_function(string_module, "trim", native_string_trim)
    bind_module_native_function(string_module, "to_lower", native_string_to_lower)
    bind_module_native_function(string_module, "to_upper", native_string_to_upper)
    bind_module_native_function(string_module, "get_byte", native_string_get_byte)
    bind_module_native_function(string_module, "to_bytes", native_string_to_bytes)
}

