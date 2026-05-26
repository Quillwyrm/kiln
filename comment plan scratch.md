# Comment Plan Scratch

## Stage 1: Semantic Audit (No Edits)
- Read `scanner`, `parser`, `codegen`, `runtime`, `builtins`, and `error`.
- For each file, list:
  - invariants that exist today
  - semantic rules not currently documented
  - comments that are noise or drift-prone

## Stage 2: Exact Comment Plan (No Edits)
- Build an insertion plan with exact anchors:
  - before type/struct/proc
  - inside branch blocks where rule intent matters
- Write proposed comment text in plain English for review.
- Get approval/rejections before patching.

### Phase 2 Draft (VM Style, Non-VM Files Only)

Global rule for stage 3:
- `vm.odin` stays untouched.
- For `scanner/parser/codegen/runtime/builtins/error`, replace existing comments with a new coherent set.
- Do not preserve old wording. Keep only code behavior and rewrite comments from scratch.

#### scanner.odin
Anchor: before `TokenKind`
Text:
`// TokenKind is the set of token types emitted by the scanner.`
`// The parser reads this token stream directly.`

Anchor: before `TokenValue`
Text:
`// TokenValue stores payload data for IDENT/INT/FLOAT/STRING tokens.`
`// Other token kinds leave Token.value empty.`

Anchor: before `Token`
Text:
`// Token is one scanned unit plus its source location.`
`// offset is a byte index in source text.`
`// line and column start at 1 to match printed error locations.`

Anchor: before `Scanner` struct
Text:
`// Scanner is the working state used while scanning one source string.`
`// It stores source text, position, and emitted tokens.`
`// Current design runs one active scan at a time.`

Anchor: before `advance`
Text:
`// advance consumes one source byte and updates line/column.`
`// Newline increments line and resets column to 1.`

Anchor: before `begin_token`
Text:
`// begin_token snapshots the source position where the next token starts.`

Anchor: before `match_next`
Text:
`// match_next conditionally consumes one exact following byte.`

Anchor: before `scanner_error`
Text:
`// scanner_error records a compile error at the current token start location.`
`// Scanner.failed stops scanning after the current step.`

Anchor: before `emit_token`
Text:
`// emit_token appends one token using the current token-start snapshot.`

Anchor: before `is_alpha/is_digit/is_ident_char`
Text:
`// Character classifiers for first-pass ASCII identifier/number rules.`

Anchor: before `scan_ident_or_keyword`
Text:
`// scan_ident_or_keyword consumes [A-Za-z_][A-Za-z0-9_]* and maps keywords.`

Anchor: before `scan_number`
Text:
`// scan_number supports:`
`// - decimal ints`
`// - hex ints with 0x prefix`
`// - decimal floats with optional leading dot (.5)`
`// Rejected here: exponent forms (1e3), octal, and identifier-suffixed numerics.`

Anchor: before `scan_string`
Text:
`// scan_string consumes a single-line quoted string with no escape decoding.`

Anchor: before `skip_line_comment`
Text:
`// skip_line_comment consumes //... until newline and emits no token.`

Anchor: before `scan_symbol`
Text:
`// scan_symbol emits punctuation/operators and handles two-character forms.`

Anchor: before `scan_source`
Text:
`// scan_source resets Scanner state, emits a full token stream, then EOF.`
`// Caller owns the returned [dynamic]Token and must delete it.`

#### parser.odin
Anchor: before `Parser` struct
Text:
`// Parser is the working state for token-stream parsing.`
`// It tracks parse position and parse failure state for one compile operation.`

Anchor: before token cursor helpers (`current_token`, `peek_token`, `at_token`, `advance_token`)
Text:
`// Token cursor helpers over Parser.tokens.`
`// Parser.token_index points to the current token being parsed.`

Anchor: before `parser_error`
Text:
`// parser_error records a source-positioned compile error and stops parse flow.`
`// source_name comes from the current ProtoState being compiled.`

Anchor: before `consume_token`
Text:
`// consume_token enforces required grammar tokens.`
`// On mismatch it records an error and returns zero token value.`

Anchor: before `claim_temp_slot`
Text:
`// claim_temp_slot reserves one temporary frame slot for expression/call work.`
`// Temp slots are bounded by MAX_FRAME_SLOTS due to u8 slot encoding.`

Anchor: before `declare_local`
Text:
`// declare_local binds one identifier to the next local frame slot.`
`// Current parser stage is flat-scope: duplicate local names are rejected.`

Anchor: before `resolve_local`
Text:
`// resolve_local finds the nearest local binding by identifier name.`
`// Reverse scan returns the most recently declared matching local.`

Anchor: before `parse_primary`
Text:
`// parse_primary emits one primary expression value into dst.`
`// IDENT resolves local first, then global binding table by name.`

Anchor: before `parse_call`
Text:
`// parse_call lowers callee(args...) using contiguous call slots:`
`// callee_slot, arg0, arg1, ...`
`// requested_results controls VM CALL result shaping (0 for statements, 1 for expressions).`

Anchor: before `parse_expression`
Text:
`// parse_expression currently supports primary expressions plus call suffix.`
`// Operator precedence parsing is not in this stage yet.`

Anchor: before `parse_statement`
Text:
`// parse_statement supports three top-level statement forms:`
`// - ident := expression`
`// - ident = expression (local-only assignment)`
`// - call statement`

Anchor: before `parse_top_level_statements`
Text:
`// parse_top_level_statements parses until EOF or first parse failure.`
`// After each statement, next_temp_slot resets to local_count so temporary slots are reused.`

Anchor: before `compile_source`
Text:
`// compile_source scans source, parses top-level forms, and builds entry proto.`
`// On success it installs Active_State.entry_function for VM execution.`

#### codegen.odin
Anchor: before `MAX_FRAME_SLOTS`
Text:
`// MAX_FRAME_SLOTS is the per-proto frame slot ceiling.`
`// It must stay compatible with u8 slot operands in emitted bytecode layouts.`

Anchor: before `LocalBinding`
Text:
`// LocalBinding maps an identifier name to a frame slot index.`

Anchor: before `ProtoState`
Text:
`// ProtoState is the mutable compile target for one proto/chunk.`
`// Parser and codegen both mutate this state while lowering source to bytecode.`

Anchor: before `record_slots`
Text:
`// record_slots maintains frame_slot_count as max-touched-slot + 1.`

Anchor: before `declare_global`
Text:
`// declare_global returns a BindingId for binding_name.`
`// If the name exists, it returns the existing id.`
`// Otherwise it appends a new binding and returns its id.`

Anchor: before `resolve_global`
Text:
`// resolve_global looks up an existing binding name without creating one.`

Anchor: before `bind_native_global`
Text:
`// bind_native_global installs one native callable into global_env by binding name.`

Anchor: before `begin_proto`
Text:
`// begin_proto initializes mutable proto construction state.`
`// source_name identifies where this proto originated for diagnostics.`

Anchor: before `end_proto`
Text:
`// end_proto finalizes ProtoState into an owned Proto heap object.`
`// Dynamic buffers are copied to owned slices, then the dynamic buffers are deleted.`

Anchor: before constant helpers (`const_int/const_float/const_string`)
Text:
`// Constant helpers append values to proto const_pool and return const indexes.`

Anchor: before emit sections (`Loads`, `Array`, `Map`, `Numeric`, `Comparison`, `Jumps`, `Calls`, `Global`)
Text:
`// Emitters encode VM instructions directly into proto_state.bytecode.`
`// All slot operands are frame-local slot indexes for the current proto.`

Anchor: before `patch_jump`
Text:
`// patch_jump rewrites a previously emitted jump to target current bytecode end.`
`// Offsets are relative to instruction index after jump fetch.`

Anchor: before `emit_call`
Text:
`// emit_call records the highest slot touched by this call layout, including requested result slots.`

#### runtime.odin
Anchor: before `new_state/delete_state`
Text:
`// Runtime state lifecycle for host embedding.`

Anchor: before `run_source`
Text:
`// run_source is the main host entry for source execution on one state.`
`// It selects Active_State, clears previous error, compiles, then executes VM.`

Anchor: before `run_file`
Text:
`// run_file loads source text from disk and forwards to run_source.`
`// File read errors use line=0, column=0 because no source location exists yet.`

Anchor: before `debug_run_file`
Text:
`// debug_run_file is a host-facing debug path that prints source and output.`

#### error.odin
Anchor: before `Error` struct
Text:
`// Error is the current compile/load error payload surfaced to the host.`

Anchor: before `set_error`
Text:
`// set_error overwrites Active_State.error and returns its address.`
`// This runtime keeps one active error slot per state.`

#### builtins.odin
Anchor: before `new_string_value`
Text:
`// new_string_value allocates a VM string object and wraps it as Value.`

Anchor: before `value_to_string`
Text:
`// value_to_string returns text conversion used by to_string and assert message formatting.`
`// Used by builtins like to_string and assert message formatting.`

Anchor: before `bind_global_env`
Text:
`// bind_global_env installs the core native builtin set into global_env.`

Anchor: before `print_value`
Text:
`// print_value is display formatting for builtin print output.`
`// Formatting is human-facing and may differ from value_to_string representation.`

Anchor: before first native (`native_print`)
Text:
`// Native builtin call contract:`
`// - args are read from slots starting at args_base`
`// - results are written starting at return_slot_base`
`// - returned int is produced result count`
`// VM CALL shapes produced results to requested_results.`

Anchor: before each native proc block
Text:
`// native_type: returns one of "nil", "bool", "int", "float", "string", "array", "map", "function".`
`// native_length: supports array/map/string only.`
`// native_assert: errors when first arg is falsey (nil or false).`
`// native_to_string: converts one value to string object.`
`// native_to_number: parses int/float/string numeric forms; returns nil on failure.`

## Stage 3: Micro Patch Passes (File by File)
- Patch one file at a time, comments only.
- No behavior changes mixed into comment passes.
- After each file:
  - run `odin check src`
  - optional `odin run src`
- Review diff, then continue to next file.
