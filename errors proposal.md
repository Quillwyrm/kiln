# Errors Proposal

This is an audit of current Kiln error paths and a staged proposal for making
errors part of the language surface instead of Odin panic output.


## Current State

Compile/load errors already use `Error`:

- scanner errors call `set_error`
- parser errors call `set_error`
- `run_file` reports file read errors through `Error`
- `main` prints `source[line:column] Error: message`

Runtime errors do not consistently use `Error` yet:

- VM type/domain failures mostly call `panic`
- builtin argument/domain failures call `panic`
- `assert(false, "...")` calls `panic`

That split is the main thing to harden.


## Error Rule

If valid Kiln source can trigger the failure, it should be a Kiln `Error`.

If only a broken Kiln implementation can trigger the failure, `panic` is fine.

Examples of user program errors:

- calling a non-function value
- using `length` on an int
- passing too few args to a builtin that requires one arg
- failed `assert`
- array index is not an int
- array index is out of bounds
- numeric operator receives a non-number
- VM stack/frame limit exceeded by user recursion

Examples of implementation invariant failures:

- `patch_jump` receives an instruction that is not `JUMP` or `JUMP_FALSE`
- impossible `Value` union state
- compiler emits impossible bytecode layout


## Message Style

Use direct user-facing language. Do not expose opcode names in normal user errors.

Preferred shape:

```text
test.kiln[12:1] Error: invalid function call; expected `function`, got `int`
```

Type names should use backticks:

```text
`nil`
`bool`
`int`
`float`
`string`
`function`
`array`
`map`
```

String values should keep normal string formatting:

```text
"hello"
```

Do not use `<int>` or `<function>`. Angle brackets read like placeholders or
debug object formatting.


## Immediate Improvements

### 1. Add A Runtime Error Exit Path

`run_vm` currently returns only `Value`.

For runtime errors, it should return both result and error:

```odin
run_vm :: proc(state: ^State) -> (result: Value, err: ^Error)
```

`run_source` then forwards the VM error just like it forwards compile errors.

This keeps the host-facing model the same:

```odin
result, err := kiln.run_file(kstate, "test.kiln")
```

No new public error wrapper is needed. The existing `Error` payload is enough.

### 2. Add Runtime Error Location From Current Frame

Exact instruction line/column is not available yet.

The first useful runtime location should come from the current proto:

```text
proto.source_name
proto.source_line
proto.source_column
```

That means `Proto` and `ProtoState` need origin line/column fields.

Policy:

- entry proto origin is the start of the source file
- named function literal origin is the declared identifier token
- anonymous function literal origin is the `function` token

This gives runtime errors and first stack traces a useful frame origin without
requiring per-instruction debug tables.

### 3. Add One Value Type Name Primitive

Runtime errors and `type(...)` need the same value taxonomy.

Add one primitive operation that returns the user-facing type name for a `Value`:

```text
nil, bool, int, float, string, function, array, map
```

This helper earns its cost because it centralizes the language's public type
names across:

- `type(...)`
- runtime call errors
- builtin argument errors
- numeric/domain errors
- collection errors

### 4. Convert Builtin Panics That Users Can Trigger

Current builtin panics that should become Kiln errors:

- `type expected 1 argument`
- `length expected 1 argument`
- `length expected array, map, or string`
- `assert expected at least 1 argument`
- assertion failure messages
- `to_string expected 1 argument`
- `to_number expected 1 argument`

Example messages:

```text
test.kiln[8:1] Error: invalid `length` call; expected `array`, `map`, or `string`, got `int`
test.kiln[9:1] Error: invalid `type` call; expected 1 argument, got 0
test.kiln[10:1] Error: assertion failed
```

The native function ABI needs a way for a native builtin to report failure.

Minimal shape:

- builtin calls `set_error(...)`
- builtin returns `0`
- VM checks `state.error.message != ""` after native call and exits

That keeps the current native return-count contract. It does not require a new
native error type.

### 5. Convert VM Call Errors

Current user-reachable call panics:

- non-object callee
- string/array/map object callee

These should become:

```text
invalid function call; expected `function`, got `int`
invalid function call; expected `function`, got `string`
invalid function call; expected `function`, got `array`
```

Keep internal capacity panics separate until they are user-reachable. Once
recursive or deeply nested user calls can hit `MAX_CALLFRAMES` or `MAX_VM_SLOTS`,
those should also become Kiln runtime errors:

```text
call stack limit exceeded
runtime slot limit exceeded
```

### 6. Convert Numeric Runtime Domain Errors

These are user errors once binary operators are parsed:

- `ADD expected numbers`
- `SUB expected numbers`
- `MUL expected numbers`
- `DIV expected numbers`
- `NEG expected number`
- `LESS expected numbers`
- `LESS_OR_EQUAL expected numbers`

Preferred message form:

```text
invalid `+` operands; expected numbers, got `string` and `int`
invalid unary `-`; expected number, got `bool`
invalid `<` operands; expected numbers, got `array` and `int`
```

This can wait until binary expression parsing is active, but the VM paths are
already visible.

### 7. Convert Collection Runtime Domain Errors

These are user errors once array/map syntax is parsed:

- `ARRAY_LEN expected array object`
- `ARRAY_GET expected array object`
- `ARRAY_GET expected i64 index`
- `ARRAY_GET index out of bounds`
- `ARRAY_SET expected array object`
- `ARRAY_SET expected i64 index`
- `ARRAY_SET index out of bounds`
- `ARRAY_PUSH expected array object`
- `ARRAY_POP expected array object`
- `ARRAY_POP on empty array`
- `MAP_LEN expected map object`
- `MAP_GET expected map object`
- `MAP_GET expected string key`
- `MAP_SET expected map object`
- `MAP_SET expected string key`

Preferred message form:

```text
invalid array index; expected `int`, got `string`
array index out of bounds: 12
cannot pop from empty array
invalid map key; expected `string`, got `int`
```

Do not spend implementation time on these before the source syntax reaches
them, unless hand-authored bytecode testing starts depending on them.


## Compile Error Improvements

The scanner and parser are already mostly in the right shape. These are worth
cleaning up before the language surface grows much more.

### 1. Unsupported Keyword Statements

`global` and `map` scan as keywords, but parser statement dispatch currently
falls to `expected statement`.

Better messages:

```text
`global` declarations are not implemented yet
map literal is only valid in expression position
```

Only add these once the intended surface is locked enough that the messages are
not stale the next day.

### 2. Generic Expected Expression

Current parser errors like `expected expression` are correct but sometimes thin.

Better forms when the token is known:

```text
expected expression, got `}`
expected expression, got `else`
```

This is useful after expression parsing broadens.

### 3. Scope Depth Limit

`begin_scope` writes `scope_local_counts[scope_depth]`.

There is currently no explicit compile error for too many nested block scopes.
That should become:

```text
too many nested scopes
```

This is a real user-reachable limit because `scope_local_counts` is fixed-size.

### 4. Constant And Child Proto Limits

Bytecode operands use `u16` for const indexes and child proto indexes.

The compiler should eventually error before indexes exceed that encoding:

```text
too many constants in proto
too many child functions in proto
```

This is not urgent, but it is a real fixed bytecode limit.


## Stack Traces

Do not build full stack traces first.

A useful first stack trace only needs proto origins:

```text
test.kiln[72:1] Error: invalid function call; expected `function`, got `int`
stack:
  in helper at test.kiln[53:1]
  in entry at test.kiln[1:1]
```

That can be produced by walking `state.frame_stack` because each `CallFrame`
already points at a `Proto`.

Exact instruction locations need a later debug table:

```text
proto.source_lines[instruction_index]
proto.source_columns[instruction_index]
```

That should wait. It touches every emit path and should be done deliberately,
not sprinkled into individual opcodes.


## Recommended Order

1. Add proto origin line/column to `ProtoState` and `Proto`.
2. Change `run_vm` to return `(Value, ^Error)`.
3. Add one value type-name primitive.
4. Convert native builtin panics to Kiln errors.
5. Convert VM function-call panics to Kiln errors.
6. Add first stack trace printing from proto origins.
7. Convert numeric and collection domain panics as their source syntax becomes active.
8. Add per-instruction debug locations later.


## Do Not Do Yet

- Do not add `ErrorKind` yet. One formatted message is enough.
- Do not create `CompileError`, `RuntimeError`, or `RunError` wrappers.
- Do not add severity levels.
- Do not build a rich diagnostic object before exact source spans exist.
- Do not convert internal invariant panics into user errors.
- Do not add per-instruction source tables before runtime error flow exists.

