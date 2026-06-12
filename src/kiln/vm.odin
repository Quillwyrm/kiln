package kiln

import "core:fmt"
import "core:hash"
import "core:strings"


// Opcodes ========================================================================================
// Instruction layout and operand meaning is documented inline on each opcode name.

Opcode :: enum u8 {
    // Immediate, Constant, and Function Loads
    LOAD_NIL,      // Ax: A=dst
    LOAD_TRUE,     // Ax: A=dst
    LOAD_FALSE,    // Ax: A=dst
    LOAD_CONST,    // ABx: A=dst, B=const
    LOAD_FUNC,     // ABx: A=dst, B=child_proto
    MOVE,          // ABx: A=dst, B=src

    // Array Operations
    NEW_ARRAY,     // ABx: A=dst, B=capacity
    // ARRAY_LEN,  // ABx: A=dst,       B=src_array
    ARRAY_PUSH,    // ABx: A=dst_array, B=src
    // ARRAY_POP,  // ABx: A=dst,       B=src_array

    // Map Operations
    NEW_MAP,       // ABx: A=dst, B=capacity
    // MAP_LEN,    // ABx: A=dst,     B=src_map

    // Indexed Access
    INDEX_GET,     // ABC: A=dst,       B=container, C=key
    INDEX_SET,     // ABC: A=container, B=key,       C=src

    // Typed const-key indexed access
    ARRAY_GET_CONST, // ABC: A=dst,   B=array, C=const_int_index
    ARRAY_SET_CONST, // ABC: A=array, B=const_int_index, C=src
    MAP_GET_CONST,   // ABC: A=dst,   B=map,   C=const_string_key
    MAP_SET_CONST,   // ABC: A=map,   B=const_string_key, C=src

    // Arithmetic and Concatenation Operations
    ADD,           // ABC: A=dst, B=lhs, C=rhs
    SUB,           // ABC: A=dst, B=lhs, C=rhs
    CONCAT,        // ABC: A=dst, B=lhs, C=rhs
    MUL,           // ABC: A=dst, B=lhs, C=rhs
    DIV,           // ABC: A=dst, B=lhs, C=rhs
    MOD,           // ABC: A=dst, B=lhs, C=rhs
    ADD_CONST,     // ABC: A=dst, B=lhs, C=const_index
    SUB_CONST,     // ABC: A=dst, B=lhs, C=const_index
    MUL_CONST,     // ABC: A=dst, B=lhs, C=const_index
    DIV_CONST,     // ABC: A=dst, B=lhs, C=const_index
    MOD_CONST,     // ABC: A=dst, B=lhs, C=const_index
    NEG,           // ABx: A=dst, B=src

    // Comparison and Boolean Operations
    EQUAL,         // ABC: A=dst, B=lhs, C=rhs
    LESS,          // ABC: A=dst, B=lhs, C=rhs
    LESS_OR_EQUAL, // ABC: A=dst, B=lhs, C=rhs
    NOT,           // ABx: A=dst, B=src

    // Control Flow
    JUMP,          // Jump: offset (relative to post-fetch instruction_index)
    JUMP_FALSE,    // AsBx: A=cond, B=offset; jump if slot[A] is falsey
    JUMP_NOT_NIL,  // AsBx: A=cond, B=offset; jump if slot[A] is not nil
    // HALT,       // ABC: no operands used; stop VM and return nil. Reserved for debug/tool use.

    // Calls and Returns
    CALL,          // ABC: A=callee/result base, B=arg_count, C=requested_results
    RETURN,        // ABx: A=first_return, B=produced_results

    // File Bindings
    GET_FILE_BIND,   // ABx: A=dst, B=binding_index
    SET_FILE_BIND,   // ABx: A=src, B=binding_index

    // Module Bindings
    GET_MODULE_BIND, // ABC: A=dst, B=env_index, C=binding_index
    SET_MODULE_BIND, // ABC: A=src, B=env_index, C=binding_index

    // Global Bindings
    GET_GLOBAL_BIND, // ABx: A=dst, B=binding_index
    SET_GLOBAL_BIND, // ABx: A=src, B=binding_index
}

// Bytecode format limits =========================================================================
// These limits are imposed by instruction operand widths.

MAX_FRAME_SLOTS :: 256       // u8 slot operands
MAX_CALL_ARGS :: 255         // u8 CALL argument count
MAX_CONST_POOL_ENTRIES :: 65536 // u16 LOAD_CONST index
MAX_CHILD_PROTOS :: 65536       // u16 LOAD_FUNC index

MIN_COND_JUMP_OFFSET :: -32768 // i16 conditional jump offset
MAX_COND_JUMP_OFFSET :: 32767
MIN_JUMP_OFFSET :: -8388608     // signed 24-bit JUMP offset
MAX_JUMP_OFFSET :: 8388607

// Count operand sentinels.
// CALL.C is u8. RETURN.B is u16.
CALL_OPEN_RESULTS :: 255
RETURN_OPEN_RESULTS :: 65535


// Instruction layout types =======================================================================
// Types used to pack and decode instruction words.
// The opcode decides which layout applies to a given instruction word.

InstABC :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    b:  u8     | 8,
    c:  u8     | 8,
}

InstABx :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    b:  u16    | 16, // wide second operand
}

InstAsBx :: bit_field u32 {
    op: Opcode | 8,
    a:  u8     | 8,
    sb: i16    | 16, // signed wide second operand
}

InstAx :: bit_field u32 {
    op: Opcode | 8,
    a:  u32    | 24, // wide unsigned
}

InstJump :: bit_field u32 {
    op:     Opcode | 8,
    offset: i32    | 24, // wide signed jump offset
}


// Values and heap objects ========================================================================
// Heap-backed values store ^Object. Object must be the first field of every heap object.
// The VM reads Object.kind before casting to the concrete struct.

// ObjectKind tags the concrete struct behind a heap-backed Value.
ObjectKind :: enum u8 {
    STRING,
    PROTO_FUNCTION,
    NATIVE_FUNCTION,
    ARRAY,
    MAP,
}

Object :: struct {
    kind: ObjectKind,
}


// Nil is the zero value. Immediates (bool, i64, f64) live inline. ^Object for heap values.
Value :: union {
    bool,
    i64,
    f64,
    ^Object,
}

StringObject :: struct {
    header: Object,
    data:   string,
    hash:   u64,
}

ArrayObject :: struct {
    header: Object,
    data:  [dynamic]Value,
}

MapEntry :: struct {
    key:       ^StringObject,
    hash:      u64,
    value:     Value,
    tombstone: bool,
}

MapObject :: struct {
    header:          Object,
    entries:         [dynamic]MapEntry,
    count:           int,
    tombstone_count: int,
}


// Map primitives ==================================================================================

// Map storage is an open-addressed string-key table.
// Non-empty bucket arrays always have power-of-two length.
// Empty bucket:     key == nil && !tombstone
// Full bucket:      key != nil
// Tombstone bucket: key == nil && tombstone
//
// Tombstones preserve probe chains after delete.
// count is live entries only.
// tombstone_count is included in growth pressure so dead buckets get rehashed away.
map_init :: proc(map_object: ^MapObject, entry_capacity: int) {
    map_object.count = 0
    map_object.tombstone_count = 0

    if entry_capacity <= 0 {
        map_object.entries = make([dynamic]MapEntry)
        return
    }

    wanted := max(entry_capacity * 2, 8)
    bucket_count := 1
    for bucket_count < wanted {
        bucket_count <<= 1
    }
    map_object.entries = make([dynamic]MapEntry, bucket_count)
}

map_find_slot :: proc(map_object: ^MapObject, key: ^StringObject, key_hash: u64) -> (index: int, found: bool) {
    bucket_count := len(map_object.entries)
    if bucket_count == 0 {
        panic("map_find_slot on empty map storage")
    }

    mask := bucket_count - 1
    start := int(key_hash & u64(mask))
    first_tombstone := -1

    for probe_offset := 0; probe_offset < bucket_count; probe_offset += 1 {
        idx := (start + probe_offset) & mask
        entry := &map_object.entries[idx]

        if entry.key == nil {
            if entry.tombstone {
                if first_tombstone < 0 {
                    first_tombstone = idx
                }
                continue
            }

            if first_tombstone >= 0 {
                return first_tombstone, false
            }
            return idx, false
        }

        if entry.hash == key_hash {
            if entry.key == key || entry.key.data == key.data {
                return idx, true
            }
        }
    }

    if first_tombstone >= 0 {
        return first_tombstone, false
    }

    panic("map_find_slot reached full table")
}

map_get :: proc(map_object: ^MapObject, key: ^StringObject) -> (Value, bool) {
    if len(map_object.entries) == 0 {
        return Value{}, false
    }

    key_hash := string_hash(key)
    idx, found := map_find_slot(map_object, key, key_hash)
    if !found {
        return Value{}, false
    }

    return map_object.entries[idx].value, true
}

map_set :: proc(map_object: ^MapObject, key: ^StringObject, value: Value) {
    if value == nil {
        map_delete(map_object, key)
        return
    }

    if len(map_object.entries) == 0 {
        map_init(map_object, 4)
    }

    key_hash := string_hash(key)
    idx, found := map_find_slot(map_object, key, key_hash)
    if found {
        map_object.entries[idx].value = value
        return
    }

    if (map_object.count + map_object.tombstone_count + 1) * 4 >= len(map_object.entries) * 3 {
        map_grow(map_object)
        idx, found = map_find_slot(map_object, key, key_hash)
    }

    entry := &map_object.entries[idx]

    if entry.tombstone {
        map_object.tombstone_count -= 1
    }

    entry.key = key
    entry.hash = key_hash
    entry.value = value
    entry.tombstone = false
    map_object.count += 1
}

map_delete :: proc(map_object: ^MapObject, key: ^StringObject) {
    if len(map_object.entries) == 0 {
        return
    }

    key_hash := string_hash(key)
    idx, found := map_find_slot(map_object, key, key_hash)
    if !found {
        return
    }

    entry := &map_object.entries[idx]
    entry.key = nil
    entry.hash = 0
    entry.value = Value{}
    entry.tombstone = true
    map_object.count -= 1
    map_object.tombstone_count += 1
}

map_clear :: proc(map_object: ^MapObject) {
    for i := 0; i < len(map_object.entries); i += 1 {
        map_object.entries[i] = MapEntry{}
    }
    map_object.count = 0
    map_object.tombstone_count = 0
}

map_grow :: proc(map_object: ^MapObject) {
    old_entries := map_object.entries

    bucket_count := max(len(old_entries) * 2, 8)

    map_object.entries = make([dynamic]MapEntry, bucket_count)
    map_object.count = 0
    map_object.tombstone_count = 0

    for entry in old_entries {
        if entry.key == nil {
            continue
        }

        idx, _ := map_find_slot(map_object, entry.key, entry.hash)
        map_object.entries[idx] = MapEntry{
            key       = entry.key,
            hash      = entry.hash,
            value     = entry.value,
            tombstone = false,
        }
        map_object.count += 1
    }

    delete(old_entries)
}


// Functions ======================================================================================

// Proto is one finished compiled file or function body executed by the VM.
// Bytecode operands address frame-relative runtime slots and index this proto's
// const-pool and child-proto tables.
Proto :: struct {
    // Source identity used by runtime diagnostics.
    source_name: string,
    source_line: int,
    proto_label: string,
    is_function: bool,

    // Execution shape.
    frame_slot_count: int,
    param_count:      int,
    env_index:        int,

    // Compiled data.
    bytecode:     []u32,
    inst_lines:   []int,
    const_pool:   []Value,
    child_protos: []^Proto,
}

// NativeFunction reads arg_count values starting at args_base, writes produced values
// starting at return_slot_base, and returns its produced result count.
// CALL then shapes those results to its requested count.
NativeFunction :: proc(vm: ^State, args_base: int, arg_count: int, return_slot_base: int) -> int

// Runtime callable backed by one compiled Proto.
ProtoFunctionObject :: struct {
    header: Object,
    impl:   ^Proto,
}

// Runtime callable backed by an Odin procedure.
NativeFunctionObject :: struct {
    header: Object,
    impl:   NativeFunction,
}


// Binding environments ===========================================================================

MAX_BINDINGS :: 256 // binding operands use u8 binding indexes

BindingFlag :: enum u8 {
    MUTABLE,
    EXPORTED,
}

BindingFlags :: bit_set[BindingFlag; u8]

// BindingEnv is one fixed-size named value namespace.
// Entries occupy 0..<count. names[i], values[i], and flags[i] describe the same binding.
// Bytecode stores i and indexes the arrays directly.
// Bindings are appended and never removed, so their indexes remain stable.
// flags[i] stores per-binding policy bits such as mutability and namespace export visibility.
BindingEnv :: struct {
    id:     string,
    names:  [MAX_BINDINGS]string,
    values: [MAX_BINDINGS]Value,
    flags:  [MAX_BINDINGS]BindingFlags,
    count:  int,
}


// Call frames ====================================================================================

// CallFrame is one active Proto execution window.
// Stored slot bases are absolute State.slots indexes; bytecode slot operands are frame-relative.
CallFrame :: struct {
    // Current execution position.
    proto:             ^Proto,
    instruction_index: int,

    // Frame-local slot window and caller slot high-water mark restored on return.
    slot_base:         int,
    caller_slot_count: int,

    // Fixed caller result count or CALL_OPEN_RESULTS.
    // The caller result base is one slot before this frame's slot_base.
    requested_results: int,

    // Latest open-result range in State.slots produced inside this frame.
    open_result_base:  int,
    open_result_count: int,
}


// VM state =======================================================================================
MAX_VM_SLOTS :: 4096
MAX_CALL_FRAMES :: 256
MAX_ENVS :: 256 // env binding operands use u8 env indexes

// State is one host-owned Kiln runtime instance.
State :: struct {
    // Current host-operation diagnostic. Empty means no current error.
    error_string: string,

    // Compiled entry file.
    entry_proto: ^Proto,

    // Active VM execution and current used slot high-water mark.
    slots:       [MAX_VM_SLOTS]Value,
    slot_count:  int,
    frame_stack: [MAX_CALL_FRAMES]CallFrame,
    frame_count: int,

    // Binding environments. envs[0] is the entry file. envs[1..] are imported and core modules.
    envs:        [MAX_ENVS]BindingEnv,
    env_count:   int,

    // Import-chain stack for cycle detection. Indices in envs[0..<env_count].
    loading_env_indexes: [MAX_ENVS]int,
    loading_env_count:   int,

    // Global binding environment. Host builtins are installed here before user code;
    // user `global` declarations append here during compile. Export flags are ignored.
    global_env: BindingEnv,

    // Raw invocation argv chosen by the host, plus the first user script arg index.
    argv:       []string,
    args_start: int,
}

// Active_State is the host-selected State used by compiler and runtime internals.
Active_State: ^State


// Binding env primitives ==========================================================================

// binding_env_find returns the binding index for name, or -1 when name is absent.
binding_env_find :: proc(env: ^BindingEnv, name: string) -> int {
    for binding_index := 0; binding_index < env.count; binding_index += 1 {
        if env.names[binding_index] == name {
            return binding_index
        }
    }

    return -1
}

// binding_env_append appends a new binding. Caller owns duplicate-name and capacity policy.
// Binding names are cloned because source module text can be freed after compile.
binding_env_append :: proc(env: ^BindingEnv, name: string, is_mutable: bool) -> int {
    binding_index := env.count
    env.names[env.count] = strings.clone(name)
    env.flags[env.count] = {}

    if is_mutable {
        env.flags[env.count] += {.MUTABLE}
    }

    env.count += 1
    return binding_index
}


// Global bindings ================================================================================
// Global binding helpers operate on Active_State.global_env.
// Public host entry points select Active_State before these helpers run.

bind_native_global :: proc(name: string, native_proc: NativeFunction) {
    binding_index := binding_env_find(&Active_State.global_env, name)

    if binding_index >= 0 {
        // Existing builtin binding is being refreshed during host setup.
    } else {
        if Active_State.global_env.count >= MAX_BINDINGS {
            panic("too many global bindings")
        }

        binding_index = binding_env_append(&Active_State.global_env, name, false)
    }
    Active_State.global_env.flags[binding_index] -= {.MUTABLE}

    native_function := new(NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.impl = native_proc

    Active_State.global_env.values[binding_index] = Value(cast(^Object)native_function)
}

// Environment management ==========================================================================

env_find :: proc(id: string) -> int {
    for env_index := 0; env_index < Active_State.env_count; env_index += 1 {
        if Active_State.envs[env_index].id == id {
            return env_index
        }
    }

    return -1
}

// Returns the existing env index for id or appends a new stable env index.
bind_env :: proc(id: string) -> int {
    existing_index := env_find(id)
    if existing_index >= 0 {
        return existing_index
    }

    if Active_State.env_count >= MAX_ENVS {
        panic("too many environments")
    }

    env_index := Active_State.env_count
    Active_State.envs[env_index].id = strings.clone(id)
    Active_State.env_count += 1
    return env_index
}

// Installs one immutable exported native function in an existing module environment.
bind_env_native_function :: proc(env_index: int, name: string, native_proc: NativeFunction) {
    env := &Active_State.envs[env_index]
    binding_index := binding_env_find(env, name)

    if binding_index < 0 {
        if env.count >= MAX_BINDINGS {
            panic("too many native env bindings")
        }

        binding_index = binding_env_append(env, name, false)
    }
    env.flags[binding_index] -= {.MUTABLE}
    env.flags[binding_index] += {.EXPORTED}

    native_function := new(NativeFunctionObject)
    native_function.header.kind = .NATIVE_FUNCTION
    native_function.impl = native_proc

    env.values[binding_index] = Value(cast(^Object)native_function)
}


// Instruction decoding ==========================================================================


decode_op :: proc(word: u32) -> Opcode {
   return Opcode(u8(word & 0xff))
}

// Value helpers ==================================================================================

value_concat :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_object, left_is_object := lhs.(^Object)
    right_object, right_is_object := rhs.(^Object)

    if !left_is_object || left_object.kind != .STRING ||
       !right_is_object || right_object.kind != .STRING {
        runtime_error(fmt.tprintf("failed to concatenate `%s` and `%s`; expected two strings", value_type_to_string(lhs), value_type_to_string(rhs)))
        return Value{}
    }

    left_string := cast(^StringObject)left_object
    right_string := cast(^StringObject)right_object

    if len(left_string.data) == 0 {
        return rhs
    }
    if len(right_string.data) == 0 {
        return lhs
    }

    parts := [?]string{left_string.data, right_string.data}

    result := new(StringObject)
    result.header.kind = .STRING
    result.data = strings.concatenate(parts[:])
    result.hash = 0
    return Value(cast(^Object)result)
}

string_hash :: #force_inline proc(s: ^StringObject) -> u64 {
    if s.hash == 0 {
        s.hash = hash.fnv64a(transmute([]byte)s.data)
    }
    return s.hash
}

value_add :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int + right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) + right_float)
        }
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float + f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float + right_float)
        }
    }

    runtime_error(fmt.tprintf("invalid `+`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
}

value_sub :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int - right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) - right_float)
        }
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float - f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float - right_float)
        }
    }

    runtime_error(fmt.tprintf("invalid `-`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
}

value_mul :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_int * right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(f64(left_int) * right_float)
        }
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return Value(left_float * f64(right_int))
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return Value(left_float * right_float)
        }
    }

    runtime_error(fmt.tprintf("invalid `*`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
}

value_div :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_int, left_is_int := lhs.(i64)
    left_float, left_is_float := lhs.(f64)
    right_int, right_is_int := rhs.(i64)
    right_float, right_is_float := rhs.(f64)

    if (!left_is_int && !left_is_float) || (!right_is_int && !right_is_float) {
        runtime_error(fmt.tprintf("invalid `/`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
        return Value{}
    }

    if (right_is_int && right_int == 0) || (right_is_float && right_float == 0) {
        runtime_error("invalid `/`; divisor cannot be zero")
        return Value{}
    }

    if left_is_int {
        if right_is_int {
            return Value(f64(left_int) / f64(right_int))
        }
        return Value(f64(left_int) / right_float)
    }

    if right_is_int {
        return Value(left_float / f64(right_int))
    }
    return Value(left_float / right_float)
}

value_mod :: #force_inline proc(lhs, rhs: Value) -> Value {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            if right_int == 0 {
                runtime_error("invalid `%`; divisor cannot be zero")
                return Value{}
            }

            return Value(left_int % right_int)
        }
    }

    runtime_error(fmt.tprintf("invalid `%`; expected ints, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return Value{}
}

value_neg :: #force_inline proc(value: Value) -> Value {
    int_value, is_int := value.(i64)
    if is_int {
        return Value(-int_value)
    }

    float_value, is_float := value.(f64)
    if is_float {
        return Value(-float_value)
    }

    runtime_error(fmt.tprintf("invalid unary `-`; expected number, got `%s`", value_type_to_string(value)))
    return Value{}
}

// Comparison/truthiness helpers ==================================================================

value_is_falsey :: #force_inline proc(value: Value) -> bool {
    bool_value, is_bool := value.(bool)
    if is_bool {
        return !bool_value
    }

    if value == nil {
        return true
    }

    return false
}

value_equal :: #force_inline proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int == right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) == right_float
        }

        return false
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float == f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float == right_float
        }

        return false
    }

    left_bool, is_bool := lhs.(bool)
    if is_bool {
        right_bool, is_bool := rhs.(bool)
        if is_bool {
            return left_bool == right_bool
        }

        return false
    }

    left_object, is_object := lhs.(^Object)
    if is_object {
        right_object, is_object := rhs.(^Object)
        if is_object {
            if left_object.kind == .STRING && right_object.kind == .STRING {
                left_string := cast(^StringObject)left_object
                right_string := cast(^StringObject)right_object
                return left_string.data == right_string.data
            }

            return left_object == right_object
        }

        return false
    }

    if lhs == nil {
        return rhs == nil
    }

    panic("unreachable: lhs must match one Value variant")
}

value_less :: #force_inline proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int < right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) < right_float
        }
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float < f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float < right_float
        }
    }

    runtime_error(fmt.tprintf("invalid `<`; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return false
}

value_less_or_equal :: #force_inline proc(lhs, rhs: Value) -> bool {
    left_int, is_int := lhs.(i64)
    if is_int {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_int <= right_int
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return f64(left_int) <= right_float
        }
    }

    left_float, is_float := lhs.(f64)
    if is_float {
        right_int, is_int := rhs.(i64)
        if is_int {
            return left_float <= f64(right_int)
        }

        right_float, is_float := rhs.(f64)
        if is_float {
            return left_float <= right_float
        }
    }

    runtime_error(fmt.tprintf("invalid `<='; expected numbers, got `%s` and `%s`", value_type_to_string(lhs), value_type_to_string(rhs)))
    return false
}

// Runtime errors =================================================================================

runtime_error :: proc(message: string) -> string {
    frame := &Active_State.frame_stack[Active_State.frame_count - 1]
    proto := frame.proto

    context_text := ""
    if !proto.is_function {
        if proto.env_index == 0 {
            context_text = "entry file"
        } else {
            env := &Active_State.envs[proto.env_index]
            module_name := module_namespace_from_path(env.id)
            context_text = fmt.tprintf("module %s", module_name)
        }
    } else {
        context_text = proto.proto_label
    }

    line := proto.source_line
    inst_index := frame.instruction_index - 1
    if inst_index >= 0 && inst_index < len(proto.inst_lines) {
        line = proto.inst_lines[inst_index]
    }

    return set_error(fmt.tprintf("%s[%d] Error in %s: %s", proto.source_name, line, context_text, message))
}


// VM runner ======================================================================================

run_proto :: proc(state: ^State, proto: ^Proto) -> (result: Value, err: string) {
    // Seed the first frame at slot window base 0.
    state.slot_count = proto.frame_slot_count
    state.frame_stack[0] = CallFrame {
        proto                    = proto,
        instruction_index        = 0,
        slot_base                = 0,
        requested_results        = 1,
        open_result_base         = 0,
        open_result_count        = 0,
        caller_slot_count        = 0,
    }
    state.frame_count = 1

    frame := &state.frame_stack[state.frame_count - 1]
    current_proto := frame.proto
    pc := frame.instruction_index
    bytecode := current_proto.bytecode
    const_pool := current_proto.const_pool
    child_protos := current_proto.child_protos
    slot_base := frame.slot_base
    file_env := &state.envs[current_proto.env_index]

    for {
        // Fetch then advance pc.
        // Jump offsets are applied relative to this post-fetch pc.
        word := bytecode[pc]
        pc += 1
        frame.instruction_index = pc

        switch decode_op(word) {
        // case .HALT:
        //     return Value{}, nil

        case .LOAD_NIL:
            inst := InstAx(word)
            dst := slot_base + int(inst.a)
            state.slots[dst] = Value{}

        case .LOAD_TRUE:
            inst := InstAx(word)
            dst := slot_base + int(inst.a)
            state.slots[dst] = Value(bool(true))

        case .LOAD_FALSE:
            inst := InstAx(word)
            dst := slot_base + int(inst.a)
            state.slots[dst] = Value(bool(false))

        case .LOAD_CONST:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            state.slots[dst] = const_pool[int(inst.b)]

        case .LOAD_FUNC:
            // Materializes a ProtoFunctionObject from this proto's child proto table.
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            child_proto := child_protos[int(inst.b)]

            function_object := new(ProtoFunctionObject)
            function_object.header.kind = .PROTO_FUNCTION
            function_object.impl = child_proto

            state.slots[dst] = Value(cast(^Object)function_object)

        case .MOVE:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            src := slot_base + int(inst.b)
            state.slots[dst] = state.slots[src]

        case .NEW_ARRAY:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            capacity := int(inst.b)

            array_object := new(ArrayObject)
            array_object.header.kind = .ARRAY
            array_object.data = make([dynamic]Value)

            if capacity > 0 {
                reserve(&array_object.data, capacity)
            }

            state.slots[dst] = Value(cast(^Object)array_object)

        // case .ARRAY_LEN:
        //     inst := InstABx(word)
        //     dst := slot_base + int(inst.a)
        //     src := slot_base + int(inst.b)
        //     header, is_object := state.slots[src].(^Object)
        //     if !is_object || header.kind != .ARRAY {
        //         panic("ARRAY_LEN expected array object")
        //     }
        //     array_object := cast(^ArrayObject)header
        //     state.slots[dst] = Value(i64(len(array_object.data)))

        case .INDEX_GET:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            container_slot := slot_base + int(inst.b)
            key_slot := slot_base + int(inst.c)

            container_header, is_object := state.slots[container_slot].(^Object)
            if !is_object {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid index read; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

            switch container_header.kind {
            case .ARRAY:
                array_object := cast(^ArrayObject)container_header

                index_i64, is_i64 := state.slots[key_slot].(i64)
                if !is_i64 {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("invalid array index; expected `int`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                if index_i64 < 0 {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }

                index := int(index_i64)
                if index >= len(array_object.data) {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }
                state.slots[dst] = array_object.data[index]

            case .MAP:
                map_object := cast(^MapObject)container_header

                key_header, is_key_object := state.slots[key_slot].(^Object)
                if !is_key_object || key_header.kind != .STRING {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("invalid map key; expected `string`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                key_object := cast(^StringObject)key_header

                value, exists := map_get(map_object, key_object)
                if exists {
                    state.slots[dst] = value
                } else {
                    state.slots[dst] = Value{}
                }

            case .STRING, .PROTO_FUNCTION, .NATIVE_FUNCTION:
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid index read; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

        case .INDEX_SET:
            inst := InstABC(word)
            container_slot := slot_base + int(inst.a)
            key_slot := slot_base + int(inst.b)
            value_slot := slot_base + int(inst.c)

            value := state.slots[value_slot]

            container_header, is_object := state.slots[container_slot].(^Object)
            if !is_object {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid index assignment; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

            switch container_header.kind {
            case .ARRAY:
                array_object := cast(^ArrayObject)container_header

                index_i64, is_i64 := state.slots[key_slot].(i64)
                if !is_i64 {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("invalid array index; expected `int`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                if index_i64 < 0 {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }

                index := int(index_i64)
                if index >= len(array_object.data) {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
                }
                array_object.data[index] = value

            case .MAP:
                map_object := cast(^MapObject)container_header

                key_header, is_key_object := state.slots[key_slot].(^Object)
                if !is_key_object || key_header.kind != .STRING {
                    frame.instruction_index = pc
                    return Value{}, runtime_error(fmt.tprintf("invalid map key; expected `string`, got `%s`", value_type_to_string(state.slots[key_slot])))
                }
                key_object := cast(^StringObject)key_header

                map_set(map_object, key_object, value)

            case .STRING, .PROTO_FUNCTION, .NATIVE_FUNCTION:
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid index assignment; expected `array` or `map`, got `%s`", value_type_to_string(state.slots[container_slot])))
            }

        case .ARRAY_GET_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            array_slot := slot_base + int(inst.b)
            index_i64 := const_pool[int(inst.c)].(i64)

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid array index read; expected `array`, got `%s`", value_type_to_string(state.slots[array_slot])))
            }

            array_object := cast(^ArrayObject)array_header

            if index_i64 < 0 {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
            }

            index := int(index_i64)
            if index >= len(array_object.data) {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
            }

            state.slots[dst] = array_object.data[index]

        case .ARRAY_SET_CONST:
            inst := InstABC(word)
            array_slot := slot_base + int(inst.a)
            index_i64 := const_pool[int(inst.b)].(i64)
            value_slot := slot_base + int(inst.c)

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid array index assignment; expected `array`, got `%s`", value_type_to_string(state.slots[array_slot])))
            }

            array_object := cast(^ArrayObject)array_header

            if index_i64 < 0 {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
            }

            index := int(index_i64)
            if index >= len(array_object.data) {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("array index out of range: index %d, length %d", index_i64, len(array_object.data)))
            }

            array_object.data[index] = state.slots[value_slot]

        case .MAP_GET_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            map_slot := slot_base + int(inst.b)
            key_object := cast(^StringObject)const_pool[int(inst.c)].(^Object)

            map_header, is_object := state.slots[map_slot].(^Object)
            if !is_object || map_header.kind != .MAP {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid map index read; expected `map`, got `%s`", value_type_to_string(state.slots[map_slot])))
            }

            map_object := cast(^MapObject)map_header

            value, exists := map_get(map_object, key_object)
            if exists {
                state.slots[dst] = value
            } else {
                state.slots[dst] = Value{}
            }

        case .MAP_SET_CONST:
            inst := InstABC(word)
            map_slot := slot_base + int(inst.a)
            key_object := cast(^StringObject)const_pool[int(inst.b)].(^Object)
            value_slot := slot_base + int(inst.c)

            map_header, is_object := state.slots[map_slot].(^Object)
            if !is_object || map_header.kind != .MAP {
                frame.instruction_index = pc
                return Value{}, runtime_error(fmt.tprintf("invalid map index assignment; expected `map`, got `%s`", value_type_to_string(state.slots[map_slot])))
            }

            map_object := cast(^MapObject)map_header

            map_set(map_object, key_object, state.slots[value_slot])

        case .ARRAY_PUSH:
            inst := InstABx(word)
            array_slot := slot_base + int(inst.a)
            value_slot := slot_base + int(inst.b)

            value := state.slots[value_slot]

            array_header, is_object := state.slots[array_slot].(^Object)
            if !is_object || array_header.kind != .ARRAY {
                panic("ARRAY_PUSH expected array object")
            }
            array_object := cast(^ArrayObject)array_header

            append(&array_object.data, value)

        // Pops tail of array B into slot A. Empty pop is an error.
        // case .ARRAY_POP:
        //     inst := InstABx(word)
        //     dst := slot_base + int(inst.a)
        //     array_slot := slot_base + int(inst.b)
        //
        //     array_header, is_object := state.slots[array_slot].(^Object)
        //     if !is_object || array_header.kind != .ARRAY {
        //         panic("ARRAY_POP expected array object")
        //     }
        //     array_object := cast(^ArrayObject)array_header
        //
        //     popped_value, ok := pop_safe(&array_object.data)
        //     if ok {
        //         state.slots[dst] = popped_value
        //     } else {
        //         panic("ARRAY_POP on empty array")
        //     }

        case .NEW_MAP:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            capacity := int(inst.b)

            map_object := new(MapObject)
            map_object.header.kind = .MAP
            map_init(map_object, capacity)

            state.slots[dst] = Value(cast(^Object)map_object)

        // case .MAP_LEN:
        //     inst := InstABx(word)
        //     dst := slot_base + int(inst.a)
        //     map_slot := slot_base + int(inst.b)
        //     map_header, is_object := state.slots[map_slot].(^Object)
        //     if !is_object || map_header.kind != .MAP {
        //         panic("MAP_LEN expected map object")
        //     }
        //     map_object := cast(^MapObject)map_header
        //     state.slots[dst] = Value(i64(len(map_object.data)))

        case .ADD:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int + right_int)
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) + right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float + f64(right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float + right_float)
                    continue
                }
            }

            state.slots[dst] = value_add(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .SUB:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int - right_int)
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) - right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float - f64(right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float - right_float)
                    continue
                }
            }

            state.slots[dst] = value_sub(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .CONCAT:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)
            state.slots[dst] = value_concat(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .MUL:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int * right_int)
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) * right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float * f64(right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float * right_float)
                    continue
                }
            }

            state.slots[dst] = value_mul(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .DIV:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(f64(left_int) / f64(right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float && right_float != 0.0 {
                    state.slots[dst] = Value(f64(left_int) / right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(left_float / f64(right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float && right_float != 0.0 {
                    state.slots[dst] = Value(left_float / right_float)
                    continue
                }
            }

            state.slots[dst] = value_div(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .MOD:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(left_int % right_int)
                    continue
                }
            }

            state.slots[dst] = value_mod(state.slots[lhs], state.slots[rhs])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .ADD_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := const_pool[int(inst.c)]

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int + right_int)
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) + right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float + f64(right_int))
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float + right_float)
                    continue
                }
            }

            state.slots[dst] = value_add(state.slots[lhs], rhs)
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .SUB_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := const_pool[int(inst.c)]

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int - right_int)
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) - right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float - f64(right_int))
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float - right_float)
                    continue
                }
            }

            state.slots[dst] = value_sub(state.slots[lhs], rhs)
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .MUL_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := const_pool[int(inst.c)]

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_int * right_int)
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(f64(left_int) * right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := rhs.(i64)
                if right_is_int {
                    state.slots[dst] = Value(left_float * f64(right_int))
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float {
                    state.slots[dst] = Value(left_float * right_float)
                    continue
                }
            }

            state.slots[dst] = value_mul(state.slots[lhs], rhs)
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .DIV_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := const_pool[int(inst.c)]

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := rhs.(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(f64(left_int) / f64(right_int))
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float && right_float != 0.0 {
                    state.slots[dst] = Value(f64(left_int) / right_float)
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := rhs.(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(left_float / f64(right_int))
                    continue
                }
                right_float, right_is_float := rhs.(f64)
                if right_is_float && right_float != 0.0 {
                    state.slots[dst] = Value(left_float / right_float)
                    continue
                }
            }

            state.slots[dst] = value_div(state.slots[lhs], rhs)
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .MOD_CONST:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := const_pool[int(inst.c)]

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := rhs.(i64)
                if right_is_int && right_int != 0 {
                    state.slots[dst] = Value(left_int % right_int)
                    continue
                }
            }

            state.slots[dst] = value_mod(state.slots[lhs], rhs)
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .NEG:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            src := slot_base + int(inst.b)

            int_value, is_int := state.slots[src].(i64)
            if is_int {
                state.slots[dst] = Value(-int_value)
                continue
            }

            float_value, is_float := state.slots[src].(f64)
            if is_float {
                state.slots[dst] = Value(-float_value)
                continue
            }

            state.slots[dst] = value_neg(state.slots[src])
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .EQUAL:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            lhs_value := state.slots[lhs]
            rhs_value := state.slots[rhs]

            // nil checks first (nil is the union zero value, not an object)
            if lhs_value == nil || rhs_value == nil {
                state.slots[dst] = Value(bool(lhs_value == nil && rhs_value == nil))
                continue
            }

            // int/int, int/float
            lhs_int, lhs_is_int := lhs_value.(i64)
            if lhs_is_int {
                rhs_int, rhs_is_int := rhs_value.(i64)
                if rhs_is_int {
                    state.slots[dst] = Value(bool(lhs_int == rhs_int))
                    continue
                }
                rhs_float, rhs_is_float := rhs_value.(f64)
                if rhs_is_float {
                    state.slots[dst] = Value(bool(f64(lhs_int) == rhs_float))
                    continue
                }
                state.slots[dst] = Value(bool(false))
                continue
            }

            // float/int, float/float
            lhs_float, lhs_is_float := lhs_value.(f64)
            if lhs_is_float {
                rhs_int, rhs_is_int := rhs_value.(i64)
                if rhs_is_int {
                    state.slots[dst] = Value(bool(lhs_float == f64(rhs_int)))
                    continue
                }
                rhs_float, rhs_is_float := rhs_value.(f64)
                if rhs_is_float {
                    state.slots[dst] = Value(bool(lhs_float == rhs_float))
                    continue
                }
                state.slots[dst] = Value(bool(false))
                continue
            }

            // bool/bool
            lhs_bool, lhs_is_bool := lhs_value.(bool)
            if lhs_is_bool {
                rhs_bool, rhs_is_bool := rhs_value.(bool)
                if rhs_is_bool {
                    state.slots[dst] = Value(bool(lhs_bool == rhs_bool))
                    continue
                }
                state.slots[dst] = Value(bool(false))
                continue
            }

            // Both are objects at this point (nil already handled above).
            lhs_object, lhs_is_object := lhs_value.(^Object)
            rhs_object, rhs_is_object := rhs_value.(^Object)
            if lhs_is_object && rhs_is_object {
                if lhs_object == rhs_object {
                    state.slots[dst] = Value(bool(true))
                    continue
                }
                // Both strings but different pointer -> compare contents via fallback.
                if lhs_object.kind == .STRING && rhs_object.kind == .STRING {
                    state.slots[dst] = Value(value_equal(lhs_value, rhs_value))
                    continue
                }
                // Different non-string objects -> not equal.
                state.slots[dst] = Value(bool(false))
                continue
            }

            // Remaining type mismatches (object vs non-object, etc.) -> not equal.
            state.slots[dst] = Value(bool(false))

        case .LESS:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(bool(left_int < right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(bool(f64(left_int) < right_float))
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(bool(left_float < f64(right_int)))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(bool(left_float < right_float))
                    continue
                }
            }

            state.slots[dst] = Value(value_less(state.slots[lhs], state.slots[rhs]))
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .LESS_OR_EQUAL:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            lhs := slot_base + int(inst.b)
            rhs := slot_base + int(inst.c)

            left_int, left_is_int := state.slots[lhs].(i64)
            if left_is_int {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(bool(left_int <= right_int))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(bool(f64(left_int) <= right_float))
                    continue
                }
            }

            left_float, left_is_float := state.slots[lhs].(f64)
            if left_is_float {
                right_int, right_is_int := state.slots[rhs].(i64)
                if right_is_int {
                    state.slots[dst] = Value(bool(left_float <= f64(right_int)))
                    continue
                }
                right_float, right_is_float := state.slots[rhs].(f64)
                if right_is_float {
                    state.slots[dst] = Value(bool(left_float <= right_float))
                    continue
                }
            }

            state.slots[dst] = Value(value_less_or_equal(state.slots[lhs], state.slots[rhs]))
            if state.error_string != "" {
                frame.instruction_index = pc
                return Value{}, state.error_string
            }

        case .NOT:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            src := slot_base + int(inst.b)

            value := state.slots[src]
            bool_value, is_bool := value.(bool)
            if is_bool {
                state.slots[dst] = Value(!bool_value)
            } else {
                state.slots[dst] = Value(value == nil)
            }

        case .JUMP:
            inst := InstJump(word)
            pc += int(inst.offset)

        case .JUMP_FALSE:
            inst := InstAsBx(word)
            condition := slot_base + int(inst.a)

            value := state.slots[condition]
            bool_value, is_bool := value.(bool)
            if is_bool {
                if !bool_value {
                    pc += int(inst.sb)
                }
            } else if value == nil {
                pc += int(inst.sb)
            }

        case .JUMP_NOT_NIL:
            inst := InstAsBx(word)
            condition := slot_base + int(inst.a)
            if state.slots[condition] != nil {
                pc += int(inst.sb)
            }

        case .CALL:
            inst := InstABC(word)

            // A = callee/result base, B = arg count, C = requested result count
            call_base := slot_base + int(inst.a)
            args_base := call_base + 1
            arg_count := int(inst.b)
            requested_results := int(inst.c)

            callee_header, is_object := state.slots[call_base].(^Object)
            if !is_object {
                frame.instruction_index = pc
                message := fmt.tprintf("invalid function call; expected `function`, got `%s`", value_type_to_string(state.slots[call_base]))
                return Value{}, runtime_error(message)
            }

            switch callee_header.kind {
            case .NATIVE_FUNCTION:
                frame.instruction_index = pc

                // Executes immediately in the caller frame. Writes results then shapes to requested.
                native_function := cast(^NativeFunctionObject)callee_header
                produced_results := native_function.impl(state, args_base, arg_count, call_base)
                if state.error_string != "" {
                    return Value{}, state.error_string
                }

                if requested_results == CALL_OPEN_RESULTS {
                    result_end := call_base + produced_results
                    if result_end > slot_base + MAX_FRAME_SLOTS || result_end > MAX_VM_SLOTS {
                        return Value{}, runtime_error("open call produced too many results")
                    }

                    frame.open_result_base = call_base
                    frame.open_result_count = produced_results
                    if result_end > state.slot_count {
                        state.slot_count = result_end
                    }
                } else if produced_results < requested_results {
                    // Fill missing requested results with nil.
                    for fill_index := produced_results; fill_index < requested_results; fill_index += 1 {
                        state.slots[call_base + fill_index] = Value{}
                    }
                }
                // Extra produced results beyond requested count are ignored by contract.

            case .PROTO_FUNCTION:
                frame.instruction_index = pc

                // Pushes a new frame and continues the VM loop.
                proto_function := cast(^ProtoFunctionObject)callee_header
                callee_proto := proto_function.impl

                if state.frame_count >= MAX_CALL_FRAMES {
                    return Value{}, runtime_error("call stack limit exceeded")
                }

                callee_slot_base := args_base
                callee_slot_top := callee_slot_base + callee_proto.frame_slot_count
                if callee_slot_top > MAX_VM_SLOTS {
                    return Value{}, runtime_error("runtime slot limit exceeded")
                }

                // Register-window: callee frame starts at args_base, so callee slot 0 gets arg 0.
                caller_slot_count := state.slot_count
                if callee_slot_top > state.slot_count {
                    state.slot_count = callee_slot_top
                }

                // Extra fixed args are rejected; missing params filled with nil.
                if arg_count > callee_proto.param_count {
                    message := fmt.tprintf("too many arguments for `%s()`: expected %d, got %d", callee_proto.proto_label, callee_proto.param_count, arg_count)
                    return Value{}, runtime_error(message)
                }

                for param_index := arg_count; param_index < callee_proto.param_count; param_index += 1 {
                    state.slots[callee_slot_base + param_index] = Value{}
                }

                state.frame_stack[state.frame_count] = CallFrame{
                    proto                    = callee_proto,
                    instruction_index        = 0,
                    slot_base                = callee_slot_base,
                    requested_results        = requested_results,
                    open_result_base         = 0,
                    open_result_count        = 0,
                    caller_slot_count        = caller_slot_count,
                }
                state.frame_count += 1

                frame = &state.frame_stack[state.frame_count - 1]
                current_proto = frame.proto
                pc = frame.instruction_index
                bytecode = current_proto.bytecode
                const_pool = current_proto.const_pool
                child_protos = current_proto.child_protos
                slot_base = frame.slot_base
                file_env = &state.envs[current_proto.env_index]

            case .STRING, .ARRAY, .MAP:
                frame.instruction_index = pc
                message := fmt.tprintf("invalid function call; expected `function`, got `%s`", value_type_to_string(state.slots[call_base]))
                return Value{}, runtime_error(message)
            }

        case .GET_FILE_BIND:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            binding_index := int(inst.b)
            state.slots[dst] = file_env.values[binding_index]

        case .SET_FILE_BIND:
            inst := InstABx(word)
            src := slot_base + int(inst.a)
            binding_index := int(inst.b)
            file_env.values[binding_index] = state.slots[src]

        case .GET_MODULE_BIND:
            inst := InstABC(word)
            dst := slot_base + int(inst.a)
            env_index := int(inst.b)
            binding_index := int(inst.c)
            state.slots[dst] = state.envs[env_index].values[binding_index]

        case .SET_MODULE_BIND:
            inst := InstABC(word)
            src := slot_base + int(inst.a)
            env_index := int(inst.b)
            binding_index := int(inst.c)
            state.envs[env_index].values[binding_index] = state.slots[src]

        case .GET_GLOBAL_BIND:
            inst := InstABx(word)
            dst := slot_base + int(inst.a)
            binding_index := int(inst.b)
            state.slots[dst] = state.global_env.values[binding_index]

        case .SET_GLOBAL_BIND:
            inst := InstABx(word)
            src := slot_base + int(inst.a)
            binding_index := int(inst.b)
            state.global_env.values[binding_index] = state.slots[src]

        case .RETURN:
            frame.instruction_index = pc

            inst := InstABx(word)
            produced_slot_base := slot_base + int(inst.a)
            produced_results := int(inst.b)

            if produced_results == RETURN_OPEN_RESULTS {
                fixed_prefix_count := frame.open_result_base - produced_slot_base
                if fixed_prefix_count < 0 {
                    panic("open return result base is before produced slot base")
                }
                produced_results = fixed_prefix_count + frame.open_result_count
            }

            if state.frame_count == 1 {
                // Top-level RETURN ends execution and returns to the host.
                // Return first produced value when present, else nil.
                if produced_results > 0 {
                    return state.slots[produced_slot_base], ""
                }
                return Value{}, ""
            }

            caller_result_base := slot_base - 1
            requested_results := frame.requested_results

            if requested_results == CALL_OPEN_RESULTS {
                result_end := caller_result_base + produced_results
                if result_end > MAX_VM_SLOTS {
                    return Value{}, runtime_error("open return produced too many results")
                }

                caller_frame := &state.frame_stack[state.frame_count - 2]
                if result_end > caller_frame.slot_base + MAX_FRAME_SLOTS {
                    return Value{}, runtime_error("open return produced too many results")
                }

                for value_index := 0; value_index < produced_results; value_index += 1 {
                    state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
                }

                caller_frame.open_result_base = caller_result_base
                caller_frame.open_result_count = produced_results

                state.slot_count = frame.caller_slot_count
                if result_end > state.slot_count {
                    state.slot_count = result_end
                }
                state.frame_count -= 1

                frame = &state.frame_stack[state.frame_count - 1]
                current_proto = frame.proto
                pc = frame.instruction_index
                bytecode = current_proto.bytecode
                const_pool = current_proto.const_pool
                child_protos = current_proto.child_protos
                slot_base = frame.slot_base
                file_env = &state.envs[current_proto.env_index]

                continue
            }

            copied_result_count := produced_results
            if copied_result_count > requested_results {
                copied_result_count = requested_results
            }

            // Copy produced values into caller result slots.
            // The callee produces below the caller result base, so forward copy is safe
            // (no overlap risk between source and destination).
            for value_index := 0; value_index < copied_result_count; value_index += 1 {
                state.slots[caller_result_base + value_index] = state.slots[produced_slot_base + value_index]
            }

            // Fill missing requested results with nil.
            if copied_result_count < requested_results {
                for fill_index := copied_result_count; fill_index < requested_results; fill_index += 1 {
                    state.slots[caller_result_base + fill_index] = Value{}
                }
            }

            state.slot_count = frame.caller_slot_count
            state.frame_count -= 1

            frame = &state.frame_stack[state.frame_count - 1]
            current_proto = frame.proto
            pc = frame.instruction_index
            bytecode = current_proto.bytecode
            const_pool = current_proto.const_pool
            child_protos = current_proto.child_protos
            slot_base = frame.slot_base
            file_env = &state.envs[current_proto.env_index]
        }
    }
}
