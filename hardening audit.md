# Kiln Hardening Audit

Baseline checked:

- `odin check src` passes.
- `odin run src` currently reaches the deliberate `length(10)` error in `test.kiln`.
- This audit is read-only against source behavior. It lists hardening work, not completed fixes.

## Fixed Since Original Audit

### 1. Heap strings can point into freed source text

**FIXED**: `new_string_value` in `builtins.odin` now uses `strings.clone()` so `StringObject.data` owns stable storage.

### 3. `value_to_string` leaks dynamic array backing storage

**FIXED**: `delete(parts)` now runs after `strings.concatenate` in both array and map paths.

### 4. Compile errors leak unfinished `ProtoState` buffers

**FIXED**: `delete_proto_state` exists and is called on all compile failure paths.

### 5. Global binding table can overflow

**FIXED**: `declare_global` checks `MAX_BINDINGS` and returns error when full.

### 10. Runtime errors point at proto origin, not the failing expression

**FIXED**: `runtime_error` uses proto origin from the current frame.

### 11. `bind_global_env` is not idempotent in allocation behavior

**FIXED**: `declare_global` returns existing binding id for repeated names, so calling `bind_global_env` twice reuses existing global slots and leaks only one native function object per builtin (acceptable during bring-up).


## Remaining

### 1. `delete_state` does not free heap objects

`delete_state` only frees the `State` struct. Heap objects (strings, arrays, maps, protos, function objects) are not walked. Known temporary leak until GC or heap tracking exists.

### 2. Bytecode operand casts can silently truncate  

Constant pool and child proto indexes (`u16`) and some jump offsets are not range-checked at the compiler level. Parser has checks for `MAX_CONST_POOL_ENTRIES`/`MAX_CHILD_PROTOS`, but direct casts through the emitter layer are unchecked. Add checks at the point where the language limit is crossed, not at every cast.

### 3. Numeric runtime panics not user-facing yet

`value_add`/`sub`/`mul`/`div`/`neg`/`less`/`less_or_equal` still `panic` on invalid operands. Not exposed yet (no binary expression parsing), but must be converted to `runtime_error` before arithmetic syntax lands.

### 4. Condition temp slot not reset before block body

`parse_if_statement` and `parse_for_statement` claim a condition temp, emit the jump, then parse the block without resetting `next_temp_slot`. This wastes one slot inside the block. Fix: reset `proto_state.next_temp_slot = proto_state.local_count` after the condition jump.

### 5. Array/map opcode panics not user-facing yet

ARRAY_GET/SET/PUSH/POP and MAP_LEN/GET/SET still `panic`. Acceptable while only hand-authored bytecode hits them. Convert before source-level array/map syntax.

### 6. `debug_run_file` is bring-up host behavior

Fine now. Move to `main` or delete when runtime.odin should be host-agnostic.

### 7. `main` is fixed to `test.kiln`

Fine now. Will need CLI args for a real `kiln.exe`.

### 8. Scanner recognizes future tokens parser does not support

`global`, `map`, `::` are scanned but not parsed. Not a bug — scanner can recognize future syntax, parser decides what's legal.

### 9. `emit_halt` is dead code

Either document as debug opcode or delete.

### 10. String length is byte length

`length("...")` returns byte count of UTF-8. Coherent for ASCII-first surface. Needs deliberate language rule if Unicode is required.

### 11. Function object display is VM-shaped

`<object:PROTO_FUNCTION>` should become `<function>` or `<function foo()>` once functions are used in user output.

### 12. Missing arguments = nil, extra args ignored

Implemented and intentional. Documented here as language rule for future varargs.

### 13. `Error` comment is narrow

`src/kiln/error.odin` still says "compile/load error payload" but now also carries runtime errors. Quick comment fix.

## Not Findings (Intentional)

- `Active_State` as selected runtime inside one Kiln operation
- `ProtoState` passed explicitly because parent/child protos coexist
- `Value{}` as language nil
- Parser emitting bytecode directly (no AST)
- Panics for impossible internal union fallthroughs

Do not spend cleanup energy fighting these.

## Suggested Order

1. Fix `delete_state` heap ownership (document or add allocation list)
2. Reset condition temp slots before `if`/`for` blocks
3. Convert numeric runtime panics before binary syntax lands
4. Convert array/map runtime panics before source syntax lands
5. Bytecode operand range checks at compiler limit crossings
6. Fix `Error` comment drift
7. Cleanup: delete `emit_halt` or document, update `ODIN-AGENTS-BIBLE.md`
