# Comment Refactor — Reconstruction Plan

All changes are comment-only except `value_type_name` (refactored to `switch v in value`).

Note: user prefers single-line `if cond { return }` style; don't touch it.

---

## src/kiln/vm.odin

### Section headers
- Change `// the VM's executable instruction set. / Comments on each opcode ...` → `// Instruction layout and operand meaning is documented inline on each opcode name.`
- Change instruction layout types intro: remove "The real bytecode stream stays `[]u32`..." line, keep "The opcode decides which layout..."
- Change Binding tables header width from 105 → 99 chars
- Change `// fixed-size namespaces. Globals use one BindingTable on State; modules can use the same shape later.` → `// Fixed-size namespaces. Globals use one BindingTable on State.` (capitalize, remove future-talk)

### Values and heap objects section
- Change section intro: remove "The runtime value container used by slots, constants, arrays, maps, and returns." keep the Object line
- Change `// The VM reads Object.kind before casting the pointer to a concrete object struct.` → `// The VM reads Object.kind before casting to the concrete struct.`
- Change Value comment from 3 lines to 1: `// Nil is the zero value. Immediates (bool, i64, f64) live inline. ^Object for heap values.`

### Struct field comments
- Remove `// must be first` from StringObject.header, ArrayObject.header, MapObject.header, ProtoFunctionObject.header, NativeFunctionObject.header

### Functions section
- Replace 12-line preamble (Proto field docs + function object explanations) with: `// Proto stores compiled bytecode data. Function objects (ProtoFunctionObject, NativeFunctionObject) / are the runtime callable values that CALL dispatches.`
- Replace NativeFunction 6-line ABI contract with: `// Odin-backed function impl. CALL shapes produced results to requested: missing = nil, extras ignored.`
- Remove `// ProtoFunctionObject is a runtime callable object...` (name says it)
- Remove `// NativeFunctionObject is a runtime callable object...` (name says it)

### CallFrame section
- Replace 5-line field-by-field docs with: `// One active proto execution window. Slot operands are relative to slot_base.`

### State section
- Replace 10-line field-by-field docs with: `// Host-owned runtime instance. Stores active frames, slots, globals, and error state.`
- Remove blank line between MAX constants and State

### Value helpers
- Change Execution primitives intro: `// These helpers implement primitive VM value operations used by bytecode execution. / Type failures here are VM bugs until they are converted to user-facing runtime errors.` → `// Type failures in these helpers are VM bugs until converted to user-facing runtime errors.`

### Comparison/truthiness helpers
- Remove `// falsey = nil or false / // truthy = everything else` (code is self-explanatory)

### Runtime errors
- Remove `// runtime_error reports a user-facing runtime failure at the current call frame's proto origin. / Proto-origin location identifies the function being run, not the exact bytecode instruction yet.`
- Change `// Runtime errors use the currently executing frame. / // frame_count == 1 is the entry file. Deeper frames are user function calls.` → `// frame_count == 1 is the entry file; deeper frames are user function calls.`

### run_vm switch case comments
- LOAD_FUNC: `// LOAD_FUNC materializes a runtime function object from this proto's child proto table. / The child proto is compiled data; the function object is the callable runtime value.` → `// Materializes a ProtoFunctionObject from this proto's child proto table.`
- NEW_ARRAY: `// NEW_ARRAY A, B / Creates an empty array in slot A. Length starts at 0. / B reserves backing capacity for future pushes (B elements).` → `// B = initial backing capacity for future pushes.`
- ARRAY_GET: `// ARRAY_GET A, B, C / Reads array[B][index in C] into slot A.` → `// Reads array[B][index C] into slot A.`
- ARRAY_SET: `// ARRAY_SET A, B, C / Writes slot B into array A at index in slot C.` → `// Writes slot B into array A at index C.`
- ARRAY_PUSH: remove `// ARRAY_PUSH A, B` line, keep `// Appends slot B to array in slot A.`
- ARRAY_POP: `// ARRAY_POP A, B / Pops tail of array in slot B into slot A. Empty pop is an error.` → `// Pops tail of array B into slot A. Empty pop is an error.`
- CALL: `// CALL A, B, C / A = callee/result base slot / B = argument count / C = requested result count` → `// A = callee/result base, B = arg count, C = requested result count`
- Native call: `// Native calls execute immediately in the caller frame. / Native writes results at return_slot_base and reports produced count.` → `// Executes immediately in the caller frame. Writes results then shapes to requested.`
- Proto call: `// Proto calls push a new frame and continue the VM loop.` → `// Pushes a new frame and continues the VM loop.`
- Register window: `// Proto calls use a register-window layout. / Caller args begin at args_base, and the callee frame also starts at args_base, / so callee slot 0 already contains arg 0.` → `// Register-window: callee frame starts at args_base, so callee slot 0 gets arg 0.`

---

## src/kiln/builtins.odin

### Value helpers section
- Remove `// new_string_value allocates a VM string object and wraps it as Value.` (name says it)
- Remove `// value_type_name returns the user-facing type name for one Kiln value.` (name says it)
- Change `// value_to_string returns text conversion used by to_string and assert message formatting.` → `// Text conversion for to_string() and assert messages.`

### Print formatting section
- Change `// print_value is display formatting for builtin print output. / Formatting is human-facing and may differ from value_to_string representation.` → `// Display formatting for builtin print() output. / Human-facing — quotes strings differently than value_to_string. / Same recursive shape as value_to_string; both exist because their display contracts differ.`

### Native builtin implementations section
- Replace 4-line Native ABI comment with: `// Native ABI: args at slots[args_base], results at slots[return_slot_base], return int is produced count.`
- Remove `// native_type returns one of: "nil", "bool", "int", "float", "string", "array", "map", "function".`
- Remove `// native_length supports array/map/string only.`
- Remove `// native_assert errors when first arg is falsey (nil or false).`
- Remove `// native_to_string converts one value to a string object.`
- Change `// native_to_number parses int/float/string numeric forms and returns nil on failure.` → `// Returns nil on failure instead of erroring.`

### Builtin binding section
- Remove `// bind_global_env installs the core native builtin set into global_env.` (name says it)

### value_type_name refactor (code change, okayed by user)
Replace the `_, is_X := value.(Type)` chain with:
```
value_type_name :: proc(value: Value) -> string {
    if value == nil {
        return "nil"
    }
    switch v in value {
    case bool:    return "bool"
    case i64:     return "int"
    case f64:     return "float"
    case ^Object:
        switch v.kind {
        case .STRING:  return "string"
        case .ARRAY:   return "array"
        case .MAP:     return "map"
        case .PROTO_FUNCTION, .NATIVE_FUNCTION: return "function"
        }
    }
    panic("unreachable")
}
```

---

## src/kiln/codegen.odin

### Jumps/patching
- Tighten MIN_JUMP_FALSE_OFFSET, MAX_CONST_POOL_ENTRIES, etc. inline comments: remove "LOAD_CONST uses a u16 const index." → "u16 const index in LOAD_CONST" etc.

### Proto construction
- Remove `// begin_proto initializes mutable proto construction state.`
- Remove `// end_proto finalizes ProtoState into an owned Proto heap object.` and the "Dynamic buffers are copied" line
- Change `// delete_proto_state frees allocations owned by an unfinished ProtoState. / Successful proto builds use end_proto instead, which moves data into a finished Proto.` → `// Only call this on an unfinished ProtoState. end_proto moves data into a finished Proto instead.`

### Constants
- Remove `// Constant helpers append values to proto const_pool and return const indexes.`

### Instruction emitters
- Change "// Emitters encode VM instructions directly into proto_state.bytecode. / All slot operands are frame-local slot indexes for the current proto." → "// All slot operands are frame-local indexes for the current proto."

### patch_jump
- Remove `// patch_jump rewrites a previously emitted jump to target current bytecode end.` (name says it, keep the offset note)

### emit_call
- Change `// emit_call records the highest slot touched by this call layout, including requested result slots.` → `// Records the highest slot touched by this call layout, including requested result slots.`

---

## src/kiln/scanner.odin

### TokenKind sub-group capitalization
- `// Stream markers` → `// Stream Markers`
- `// Literal keywords` → `// Literal Keywords`
- `// Control flow` → `// Control Flow`
- `// Binding / construction keywords` → `// Binding / Construction Keywords`
- `// Binding operators` → `// Binding Operators`
- `// Arithmetic operators` → `// Arithmetic Operators`
- `// Comparison / logical operators` → `// Comparison / Logical Operators`
- `// Separators / access` → `// Separators / Access`

### Scanner state section
- Replace: `// Scanner is the working state used while scanning one source string. / It stores source text, position, and emitted tokens. / Current design runs one active scan at a time.` → `// Scanner runs one active scan at a time — it is a package-level singleton. / The = {} on the struct value instantiates it as the package singleton immediately.`

### Cursor helpers
- Change `// advance_char consumes one source byte and updates line/column. / Newline increments line and resets column to 1.` → `// Also updates line/column tracking. Newline resets column to 1.`
- Remove `// begin_token snapshots the source position where the next token starts.` (name says it)

### Scanner errors
- Change `// scanner_error records a compile error at the current token start location. / Scanner.failed stops scanning after the current step.` → `// Latch Scanner.failed so scanning stops after the current step.`

### Token emission
- Change `// emit_token appends one token using the current token-start snapshot.` → `// Uses the current token-start snapshot for position data.`

### Character classes
- Remove blank comment line `//` and `// Character classifiers for first-pass ASCII identifier/number rules.`

### scan_string
- Change `// scan_string consumes a single-line quoted string with no escape decoding.` → `// No escape decoding — backslash sequences are literal.`

### skip_line_comment
- Change `// skip_line_comment consumes //... until newline and emits no token.` → `// Emits no token — comments are not preserved in the token stream.`

### scan_symbol
- Change `// scan_symbol emits punctuation/operators and handles two-character forms.` → `// Handles both single-character and two-character punctuation/operator forms.`

### scan_source
- Remove `// scan_source resets Scanner state, emits a full token stream, then EOF.` (name + signature says it)

---

## src/kiln/parser.odin

### Parser state section
- Change `// working state for token-stream parsing. / It tracks parse position and parse failure state for one compile operation.` → `// Token cursor and failure latch for one compile operation.`

### Token cursor section
- Remove `// helpers over Parser.tokens. / Parser.token_index points to the current token being parsed.`

### Parser errors
- Remove `// token_text_for_error returns source-shaped text for parser error messages.`
- Change `// parser_error records a source compile error at a token location. / This covers grammar errors and codegen limits found while the parser drives bytecode generation.` → `// Covers grammar errors and codegen limits found while the parser drives bytecode generation.`
- Change `// consume_token enforces required grammar tokens. / On mismatch it records an error and returns zero token value.` → `// On mismatch records an error and returns zero token value.`

### Slots and locals
- Remove `// claim_temp_slot reserves one temporary frame slot for expression/call work.` (name says it)
- Change `// begin_scope starts one lexical block scope in the current proto. / It records the local-count mark used when this scope exits.` → `// Records the local-count mark so end_scope can discard this scope's locals.`
- Change `// end_scope exits one lexical block scope in the current proto. / Locals declared in this scope are discarded by restoring the saved local-count mark.` → `// Restores the saved local-count mark, discarding locals declared in this scope.`
- Remove `// declare_local binds one identifier to the next local frame slot.` (keep "Duplicate names are rejected within the current lexical scope only.")
- Remove `// resolve_local finds the nearest local binding by identifier name.` (keep "Reverse scan returns the most recently declared matching local." or incorporate it)

### Functions
- Change `// parse_function_literal parses function(params...) { body } as a value expression. / The compiled child proto is stored on the parent proto and loaded by LOAD_FUNC.` → `// The compiled child proto is stored on the parent and loaded by LOAD_FUNC at runtime.`

### Expressions
- Remove `// parse_primary emits one primary expression value into dst.` (name says it)
- Remove `// parse_unary parses prefix unary operators and primary expressions.` (keep "Prefix NOT lowers by evaluating the operand first, then emitting NOT into dst.")
- Change `// parse_call lowers callee(args...) using contiguous call slots: / callee_slot, arg0, arg1, ... / requested_results controls VM CALL result shaping (0 for statements, 1 for expressions).` → `// Layout: callee_slot, arg0, arg1, ... / requested_results controls CALL result shaping (0 for statements, 1 for expressions).`

### Statements
- Change `// parse_block parses one braced statement block. / Blocks create a new lexical local scope.` → `// Creates a new lexical local scope.`
- Change `// parse_if_statement parses: / if <expression> { <statements> } [else { <statements> }]` → `// if <expression> { <statements> } [else if ...] [else { <statements> }]`
- Change parse_for_statement: remove block-comment style proto, keep "Condition form evaluates each iteration. / Braced form is infinite-loop sugar..."
- Change `// parse_break_statement parses: / break / break is only valid inside loop bodies.` → `// Only valid inside loop bodies.`
- Change parse_return_statement: remove proto-like operand docs, keep the behavior note
- Change `// parse_statement supports: (8-line list)` → `// Supported forms: if/for/break/return, decl, local assign, call.`
- Remove `// parse_top_level_statements parses until EOF or first parse failure.` (keep the temp-slot reset note)

### Source compilation
- Change `// compile_source scans source, parses top-level forms, and builds entry proto. / On success it installs Active_State.entry_function for VM execution.` → `// On success installs Active_State.entry_function for VM execution.`

---

## src/kiln/error.odin

- Replace the long intro (5 paragraphs about compile vs runtime errors, SourceLocation design) with: `// Kiln reports one compile or runtime error per host operation.`
- Move SourceLocation comment above the struct (currently it's below)
- `// SourceLocation identifies a source position. Errors and protos can outlive the / scanner, so the full source name is stored rather than a token stream reference.`
- Error struct: add `// context_text provides function context, e.g. "in helper()".`
- Change `// set_error overwrites Active_State.error and returns its address. / This runtime keeps one active error slot per state.` → `// Each state keeps one active error slot — subsequent errors overwrite.`

---

## src/kiln/runtime.odin

- Remove `// Runtime state lifecycle for host embedding.` (section title says it)
- Change `// delete_state currently frees the State shell only. / Heap-backed runtime objects are not walked until Kiln has heap tracking or GC.` → `// Heap-backed runtime objects are not walked — deleted state leaks them until heap tracking exists.`
- Change `// run_source is the main host entry for source execution on one state. / It selects Active_State, clears previous error, compiles, then executes VM. / When err != nil, result is undefined and should be ignored.` → `// run_source selects Active_State, clears previous error, compiles, then executes VM. / When err != nil, result is undefined.`
- Remove `// When err != nil, result is undefined and should be ignored.` from run_file (redundant)
- Change `// debug_run_file is a host-facing debug path that prints source and output. / When err != nil, result is undefined and should be ignored.` → `// debug path that prints source and output before execution.`

---

## src/main.odin

- Add file-level purpose comment: `// Test host for developent. Creates a state, binds builtins, runs test.kiln, prints errors or results. / Not the general embedding API — see runtime.odin for the host-facing entry points.`
