# Errors Plan

Remaining error-hardening items after the first pass is implemented.

## Done (removed from this plan)

Items 1–8 from the original plan are implemented in source:

- Proto origin location on `Proto`/`ProtoState`
- `runtime_error(state, message)` with proto-origin context
- `run_vm` returns `(Value, ^Error)`
- `value_type_name` primitive
- Builtin nil/missing-arg semantics locked
- Native builtins report errors through `runtime_error`
- Builtin panics converted to errors (length, assert)
- Invalid function call panics converted to errors


## Current Focus

Small parser/scanner improvements that are relevant now:

- `expected expression, got <token>`
- `expected statement, got <token>`
- `too many nested scopes`

Keep these direct. Do not add a rich diagnostic layer.


## Later

These are good, but not part of this immediate pass:

- stack traces
- per-instruction source locations
- `ErrorKind`
- rich diagnostic objects
- converting numeric op errors before binary parsing is implemented
- converting collection op errors before array/map syntax reaches them

