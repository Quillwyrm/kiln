Yeah. High-level landed shape:

```txt
State:
    has_error: bool
    error_string: string
```

No public `Error` object. No `SourceLocation` error object. Kiln builds the final diagnostic string at the failure site. The host prints it.

## Error domains

```txt
comptime error
    scanner + parser-lowerer + codegen/import compile path
    stops compilation
    uses line:col when token data exists

runtime error
    VM/native execution failure
    stops execution
    uses proto source line and proto_label

bug error
    implementation invariant failure
    panic/assert
```

Expected filesystem/io/etc failures stay ordinary Kiln return values, not `State.error_string`.

## Final string shapes

### Token-shape / parser errors

```txt
source[line:col] Error near TOKEN: message
```

Example:

```txt
main.kiln[2:10] Error near "goblin": expected ':' after map key
```

`near TOKEN` is the anchor: where the parser noticed the problem.

`message` is still descriptive and local:

```txt
expected ')' after function parameters
expected '}' to close block
expected ':' after map key
expected expression
```

Do not shrink these into generic messages.

### Semantic/comptime errors

```txt
source[line:col] Error: message
```

Example:

```txt
main.kiln[8:5] Error: binding `foo` is not declared
main.kiln[12:1] Error: break is only valid inside loops
```

No `near TOKEN` when the message already names the offending thing clearly.

### Runtime errors

```txt
source[line] Error in proto_label: message
```

Example:

```txt
main.kiln[4] Error in update: invalid `/`; divisor cannot be zero
```

No runtime column. No source spans. No instruction debug table.

## Minimum formatting helpers

Probably just:

```odin
set_error_string(text)

compile_error(token, message)
compile_error_near(token, message)

runtime_error(message)
```

Meaning:

```txt
set_error_string
    sets has_error and final error_string

compile_error
    source[line:col] Error: message

compile_error_near
    source[line:col] Error near TOKEN: message

runtime_error
    source[line] Error in proto_label: message
```

The helpers own only the outer diagnostic shell.

The call site owns the meaningful dynamic message:

```odin
compile_error(name_token, fmt.tprintf("binding `%s` is not declared", name))

compile_error_near(Parser.current_token, "expected ':' after map key")

runtime_error("invalid `/`; divisor cannot be zero")
```

## Minimum state/data

```txt
State:
    has_error
    error_string

Scanner:
    source
    source_name

Token:
    start offset
    enough token text/kind to print TOKEN

Proto:
    source_name
    source_line
    proto_label
```

Compile line/col is derived immediately from:

```txt
Scanner.source + Token.start
```

Runtime line is stored on `Proto`:

```txt
Proto.source_line
```

## Proto labels

`proto_label` is real metadata, useful for runtime errors, stack traces, and KASM/disasm headers.

Label only honest direct function-value storage, not arbitrary RHS starts-with-function cases.

```kiln
foo := function() {}   // label: foo
foo :: function() {}   // label: foo
foo = function() {}    // label: foo

foo :: function() {}() // do not label as foo; foo receives call result
```

## Stack trace shape later

Simple frame walk:

```txt
Stack trace:
  at update main.kiln[4]
  at entry main.kiln[1]
```

Uses existing `frame_stack[i].proto`.

No stack trace object required.

## Core rule

```txt
Dynamically enrich the final string only with data naturally available at the failure site.
Do not contort parser/VM data flow for prettier errors yet.
```

Cut rot, not corners.
