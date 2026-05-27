# Errors Proposal

Remaining items after the first error-hardening pass.

## Done (removed from this proposal)

Items 1–5 from the original proposal are implemented in source:

- `run_vm` returns `(Value, ^Error)`
- Proto origin location on `Proto`/`ProtoState`
- `value_type_name` primitive exists
- Builtin panics converted to Kiln errors (length, assert, etc.)
- VM call errors converted (non-function callee, string/array/map callee)
- Stack/frame limit errors converted
- Native ABI error reporting via `runtime_error` + `state.has_error`

## Remaining

### 1. Convert Numeric Runtime Domain Errors

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

### 2. Convert Collection Runtime Domain Errors

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


## Compile Error Improvements (Mostly Done)

- `expected expression, got <token>` — done via `token_text_for_error`
- `expected statement, got <token>` — done
- `too many nested scopes` — done in `begin_scope`
- `too many local variables` / `call uses too many values` — done
- `too many functions in function` / `too many constants in function` — done

Remaining polish items:


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

### 3. Constant And Child Proto Limits

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


## Do Not Do Yet

- Do not add `ErrorKind` yet. One formatted message is enough.
- Do not create `CompileError`, `RuntimeError`, or `RunError` wrappers.
- Do not add severity levels.
- Do not build a rich diagnostic object before exact source spans exist.
- Do not convert internal invariant panics into user errors.
- Do not add per-instruction source tables before runtime error flow exists.

