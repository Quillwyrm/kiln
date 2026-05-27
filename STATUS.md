# Kiln Status

Consolidation of `hardening audit.md`, `errors proposal.md`, and `cleanup plan.md`.
Original docs preserved for reference; this is the current picture.

## Remaining Hardening

### 1. `delete_state` does not free heap objects (deferred)
Only frees the `State` struct. Strings, arrays, maps, protos, function objects are not walked. Acceptable until GC or heap tracking exists.

### 2. Numeric runtime panics not user-facing
`value_add`/`sub`/`mul`/`div`/`neg`/`less`/`less_or_equal` still `panic` on invalid operands. Convert to `runtime_error` before binary expression parsing lands.

### 4. Collection runtime panics not user-facing
ARRAY_GET/SET/PUSH/POP and MAP_LEN/GET/SET still `panic`. Convert before array/map source syntax.

## Error System

### Domain errors (not wired yet)
Binary operator and collection errors are designed but not implemented. Preferred forms:
```
invalid `+` operands; expected numbers, got `string` and `int`
array index out of bounds: 12
cannot pop from empty array
invalid map key; expected `string`, got `int`
```

### Stack traces (not implemented)
First useful trace just walks `state.frame_stack` proto origins. Exact instruction locations need a debug source table — defer until error flow is mature.

### Do Not Do Yet
- No `ErrorKind` — one formatted message is enough
- No `CompileError`/`RuntimeError`/`RunError` wrappers
- No severity levels
- No rich diagnostic objects before exact source spans exist
- No per-instruction source tables before runtime error flow exists

## Cleanup Phase Status

| Phase | Status |
|-------|--------|
| 1. AGENTS.md audit | Done |
| 2. Parser cleanup | Partial — session work improved comments/style |
| 3. Emitter cleanup | Partial — naming consistent, no stale gen comments |
| 4. VM cleanup | Partial — runtime_error/RETURN fixed, `call_frames` vs `frame_stack` still has stale comments |
| 5. Native builtin cleanup | Not started — `requested_results` handling, ABI contract comments |
| 6. Error system | Mostly done — scanner/parser errors improved, runtime locations need work |

## Deliberate Non-Goals
- `Active_State` as selected runtime inside one Kiln operation
- `ProtoState` passed explicitly because parent/child protos coexist
- `Value{}` as language nil
- Parser emitting bytecode directly (no AST)
- Panics for impossible internal union fallthroughs
