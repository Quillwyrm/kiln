Yep — I missed the actual ask. The play is:

```txt
1. source position system for line:col
2. binding-name debug table for “foo” in some errors
3. proto label for `proto <name>` / “in foo()”
```

Not one mega “debug meta” blob.

## Binding names: the clean rule

Do **not** track “names of values.” Track **names of storage locations**.

For Kiln, that means:

```txt
Local/param binding
    slot + live PC range -> name

File/module/global binding
    binding table index -> name

Proto/function body
    proto label -> name
```

That resolves the muddy function problem.

```kiln
foo :: function() {
    x := 10
    x()
}

bar := foo
bar()
```

There are different names in play:

```txt
foo
    top-level binding name
    also maybe inferred proto label for the function literal

bar
    another binding name pointing at the same function value

x
    local binding name for a slot inside foo's frame

foo proto label
    name of the compiled code body currently executing
```

So the error can be:

```txt
test.kiln:3:5 Error in `foo()`: cannot call int binding `x`
```

That uses:

* `foo()` from the **current frame’s proto label**
* `x` from the **local debug table**
* `test.kiln:3:5` from **instruction offset -> line:col**

Not five sources of truth. Three different questions.

## Local binding names

For locals and params, something like this is the normal debug-info idea:

```txt
LocalDebug:
    name
    slot
    start_pc
    end_pc
```

This is not weird. JVM has a LocalVariableTable concept: local variable debug records are tied to bytecode ranges and local indexes, separate from line numbers. Lua also has local variable debug records (`locvars`) in its Proto alongside `lineinfo`/`source`. ([Oracle Docs][1])

So in Kiln terms:

```txt
slot 0, pc 0..end      -> "value"       // param
slot 1, pc 3..14       -> "x"           // local
slot 1, pc 20..28      -> "x"           // different shadowed x maybe
```

This lets runtime errors name operands **only when the operand is a local slot with a live source name**.

Example:

```kiln
x := 10
x()
```

Good:

```txt
cannot call int binding `x`
```

But:

```kiln
make()[0]()
```

No binding name. Do not invent one. Say:

```txt
cannot call int value
```

That’s honest.

## File/module/global binding names

Those names already belong to the binding table.

So, yes: module export names are derived from source/export at compile/load time.

Example:

```kiln
foo :: function() {}
bar := 10

export {
    foo,
    bar,
}
```

The module namespace exposes bindings named `foo` and `bar`. Export does not rename values. It exposes selected top-level binding names.

If an error is about a global/module binding operation, the binding table can provide the name. If the error is inside the function body, use the proto label.

## Proto names

This is only for:

```txt
proto <name>
```

and runtime context:

```txt
Error in `name()`
```

A proto label is the name of compiled code, not the name of the function value.

Initial labels can be:

```txt
entry
<function>
module name/path
```

Then direct binding inference can improve:

```kiln
foo :: function() {}
```

to:

```txt
proto foo
```

That is not “tracking all function value names.” It is just saying:

```txt
this function literal created this proto directly under binding `foo`,
so label the proto `foo`
```

If later:

```kiln
bar := foo
```

the proto label stays `foo`.

## Source debug for whole file: yes, that is normal-ish

A source-level debug record per loaded source is a normal shape. Different systems spell it differently:

* JVM class debug info maps bytecode indexes to source line numbers via `LineNumberTable`; source file identity is separate metadata. ([Oracle Docs][1])
* Lua protos carry `source` and line-info/local-debug arrays; it stores line/debug metadata on protos, not source text in every function. ([lua.org][2])
* Python 3.11 went richer: PEP 657 maps bytecode instructions to start/end line and column offsets for better tracebacks. ([Python Enhancement Proposals (PEPs)][3])

For Kiln, a per-source debug record could be as small as:

```txt
SourceDebug:
    name
    line_starts
```

This is not “source text kept forever.” It is just enough to turn:

```txt
offset 812
```

into:

```txt
line 42, column 17
```

So yes, it is debug metadata for a whole source file. That’s the sane place for it because many protos can come from the same file.

## What is `source_id`?

It is just an index/handle into the source debug records.

```txt
source_id = 0 -> main.kiln
source_id = 1 -> enemy.kiln
source_id = 2 -> combat.kiln
```

A proto compiled from `enemy.kiln` stores:

```txt
source_id = 1
```

Then its instruction offsets mean:

```txt
offset inside source 1
```

Why not frame depth? Because frame depth is execution state, not source identity.

Frame depth changes every call:

```txt
entry -> foo -> bar
```

But `bar`’s proto still came from `enemy.kiln` regardless of whether it is frame 1, 2, or 20.

So:

```txt
source_id
    compile/source identity

frame depth
    runtime call stack position
```

They are not interchangeable.

## The bounded KISS shape

Something like this is enough:

```txt
State / compile session:
    sources: []SourceDebug

SourceDebug:
    name
    line_starts

Proto:
    name              // KASM proto title / runtime context
    source_id
    origin_offset
    inst_offsets
    local_debugs

LocalDebug:
    name
    slot
    start_pc
    end_pc
```

Then errors are assembled like this:

### Parser/compiler error

```txt
source_id = current source
offset = bad_token.start
line:col = source_id + offset -> line_starts
message = parser message
```

### Runtime error

```txt
proto = current frame proto
pc = failed instruction
source_id = proto.source_id
offset = proto.inst_offsets[pc]
line:col = source_id + offset -> line_starts
context = proto.name
```

If the runtime error involves a local slot:

```txt
slot_name = lookup LocalDebug where slot matches and pc is in range
```

Then:

```txt
file.kiln:12:5 Error in `foo()`: cannot call int binding `x`
```

If no local name exists:

```txt
file.kiln:12:5 Error in `foo()`: cannot call int value
```

## The harsh correction

`pc -> tokidx` is bad here. Kill it.

It stores parser/scanner artifacts past their useful lifetime and buys almost nothing over `pc -> offset`.

The good primitive is:

```txt
pc -> source offset
```

The good name table is:

```txt
slot/range -> local name
```

The good proto label is:

```txt
proto.name
```

That’s the play.

[1]: https://docs.oracle.com/en/java/javase/24/docs/api/java.base/java/lang/classfile/attribute/LineNumberTableAttribute.html?utm_source=chatgpt.com "LineNumberTableAttribute (Java SE 24 & JDK 24)"
[2]: https://www.lua.org/source/5.4/lobject.h.html?utm_source=chatgpt.com "Lua 5.4.8 source code - lobject.h"
[3]: https://peps.python.org/pep-0657/?utm_source=chatgpt.com "PEP 657 – Include Fine Grained Error Locations in Tracebacks"
