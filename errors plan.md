# Errors Plan

This is the immediate error-hardening plan. It excludes stack traces and
per-instruction source locations for now.


## Goal

Runtime user errors should return through the same host-facing `Error` path as
scanner/parser/load errors.

Rule:

- valid Kiln source can trigger it: return Kiln `Error`
- broken compiler/VM invariant only: keep `panic`


## 1. Add Proto Origin Location

Runtime errors need an honest source location before VM panics are converted.

Add origin fields to `ProtoState` and `Proto`:

```text
source_name
source_line
source_column
name
```

Origin policy:

- entry proto: source start, `line=1`, `column=1`, name `entry`
- named function literal: declaration identifier token, name from that identifier
- anonymous function literal: `function` token, name `<function>`

This supports messages like:

```text
test.kiln[53:1] Error in function `helper`: invalid function call; expected `function`, got `int`
```

This is proto-origin location, not exact failing expression location.


## 2. Add Runtime Error Formatting

Add a small runtime error path that uses the current frame's proto origin.

Shape:

```text
runtime_error(state, message) -> ^Error
```

This helper earns its cost because every VM runtime error needs the same source
prefix policy:

- source name
- proto origin line/column
- function/entry context
- message

Message prefix policy:

```text
source[line:column] Error: message
source[line:column] Error in entry: message
source[line:column] Error in function `name`: message
```

For now, the message can be stored fully formatted in `Error.message`, or the
main printer can learn the context fields later. Keep the first pass simple.


## 3. Change `run_vm` Return Shape

Change:

```text
run_vm(state) -> Value
```

to:

```text
run_vm(state) -> (Value, ^Error)
```

Then `run_source` forwards runtime errors the same way it forwards compile
errors.

Host API stays:

```text
result, err := run_file(state, path)
```


## 4. Add User-Facing Value Type Names

Add one primitive for language type names:

```text
nil
bool
int
float
string
function
array
map
```

This should be used by:

- `type(...)`
- invalid function call errors
- builtin argument/domain errors
- later numeric and collection errors

This helper earns its cost because it centralizes the language's public type
names.


## 5. Lock Builtin Nil/Missing-Arg Semantics

Because proto calls now make missing args explicit nil, builtins should use the
same model:

```text
type()          -> "nil"
type(nil)       -> "nil"

to_string()     -> "nil"
to_string(nil)  -> "nil"

to_number()     -> nil
to_number(nil)  -> nil

length(nil)     -> error
length(wrong)   -> error

assert(nil)     -> error
assert(false)   -> error
assert(false, message) -> error with message
```

Extra args remain ignored unless the builtin intentionally uses them.


## 6. Let Native Builtins Report Kiln Errors

Keep the native return-count ABI.

Minimal rule:

- builtin calls runtime error path or `set_error`
- builtin returns `0`
- VM checks `state.error.message != ""` after native call
- VM returns `(Value{}, &state.error)` when a native set an error

This avoids adding a native error wrapper type.


## 7. Convert Immediate Builtin Panics

Convert these user-reachable builtin panics first:

- `length` wrong type
- `assert` failure

The missing-argument panics mostly disappear because missing args are nil.

Example messages:

```text
invalid `length` call; expected `array`, `map`, or `string`, got `nil`
invalid `length` call; expected `array`, `map`, or `string`, got `int`
assertion failed
<custom assert message>
```


## 8. Convert Invalid Function Calls

User code can call non-functions:

```text
x := 10
x()
```

Convert current `CALL expected function object` panics into Kiln errors:

```text
invalid function call; expected `function`, got `int`
invalid function call; expected `function`, got `string`
invalid function call; expected `function`, got `array`
```

Keep implementation limit panics for now unless the limit is clearly
user-reachable in normal source.


## 9. Improve Immediate Compile Errors

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

