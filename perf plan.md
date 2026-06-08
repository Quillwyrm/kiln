Yeah, I’d do a **minor perf pass now**, but only the stuff that gives you a better baseline without changing the shape of the project.

The correct line is:

```txt
do local VM/lowerer cleanup
do not start an optimizer project
do not redesign Value
do not turn the stdlib into opcodes everywhere
```

## The “do now” set

### 1. VM math/truthiness fast paths

This is worth doing.

```txt
ADD int/int
SUB int/int
MUL int/int
MOD int/int
LESS int/int
LESS_OR_EQUAL int/int
NEG int
NOT bool/nil
JUMP_FALSE bool/nil
EQUAL obvious scalar cases
```

Why:

```txt
local to vm.odin
does not change bytecode
does not change language semantics
measured win
easy to revert
```

Keep the rule:

```txt
fast obvious case inline
fallback to canonical helper
```

This is a clean minor pass.

### 2. Hot-frame caching

Also worth doing, but more carefully.

This was the biggest measured win. It is not “too complex” if you keep the invariant brutally clear:

```txt
pc lives in a local during dispatch

write pc back before:
    error-capable helpers
    native calls
    returning errors
    changing frames

refresh cached locals after:
    CALL pushes a frame
    RETURN pops a frame
```

This is more delicate than math fast paths, but still contained to the VM loop. It does not infect the language, parser, modules, or API.

I’d do it after fast paths, not before, and test hard.

### 3. Lowerer cleanups, but only obvious ones

Do these only after a bytecode dump, but they’re likely good:

```txt
do not emit MOVE A, A

use expression result slot directly for if/for conditions

emit arithmetic directly into assignment destination when safe:
    sum = sum + i
    -> ADD sum, sum, i

avoid ADD temp; MOVE dst when dst is known and safe
```

This is probably the most “foundationally nice” perf work because it makes the bytecode less dumb.

But don’t do broad optimization. Just remove obvious waste.

## The “maybe now” set

### Bytecode dump / instruction counter

Honestly, this should come before or during the minor perf pass.

Not because it makes Kiln faster, but because it prevents guessing.

Minimum useful tools:

```txt
debug dump bytecode for a proto
count executed instructions
optional opcode frequency counts
```

That gives you a ground truth like:

```txt
this loop emits 9 instructions per iteration
ADD runs 20 million times
MOVE runs 30 million times
```

That tells you where the next simple cleanup is.

## The “not now” set

Do not do these yet:

```txt
ADD_CONST / LESS_CONST
compare+branch fused opcodes
superinstructions
NaN boxing
32-bit handles
quickening
JIT
GC for performance
threaded dispatch
```

Those are later. Some are good ideas, but they change the VM surface or runtime architecture. You are not there yet.

## Builtins as opcodes?

Some builtins, yes. Most, no.

The natural split:

```txt
VM primitive
    should probably be opcode eventually

library/native operation
    should stay native call
```

### Good opcode candidates

```txt
length(value)
type(value), maybe
array push/pop, maybe
```

`length` is the best candidate because it is:

```txt
primitive over core runtime values
common in loops
currently a native call
small semantics
no host IO
```

A `LENGTH dst, src` opcode would be natural.

But do not rush it. First see whether `length()` appears hot in real scripts or benchmarks. If users write:

```go
for i < length(items) {
```

then `LENGTH` earns itself quickly.

### Bad opcode candidates

These should stay native/module calls:

```txt
filesystem.read_file
filesystem.write_file
path.normalize
io.read_line
io.print
string.split
string.replace
string.trim
maps.get_keys
system.args
```

Those are library/host operations. Making them opcodes would pollute the VM.

## Are core modules as native calls normal or bad?

Normal. Good, actually.

Your current design is right:

```txt
language primitives
    bytecode opcodes

host/core library
    native functions bound into modules
```

That is exactly the sane split.

Native calls being slower than opcodes is fine. They are not supposed to be the hot inner-loop mechanism.

Bad would be making every standard library function an opcode because “performance.” That turns the VM into a kitchen sink.

The better rule:

```txt
If it manipulates VM primitive values in a tiny universal way:
    maybe opcode

If it talks to host/system/files/streams/paths/text algorithms:
    native module

If it is convenience surface:
    native module
```

So:

```txt
length
    plausible opcode

array index
    opcode already

map index
    opcode already

array.push
    maybe opcode if hot enough

string.split
    native

io.print
    native

filesystem.read_file
    native
```

## My recommended minor perf pass

I’d do exactly this:

```txt
Pass 1: observability
    bytecode dump
    instruction counter
    opcode counts if easy

Pass 2: VM local improvements
    scalar fast paths
    JUMP_FALSE / NOT truthiness inline
    maybe #force_inline on hot slow-path helpers as experiment

Pass 3: hot-frame caching
    reapply carefully with strict pc/frame sync rule

Pass 4: tiny lowerer cleanups
    no MOVE A,A
    use condition result slots directly
    direct destination lowering where obviously safe
```

Stop there.

That gives you a better baseline without turning Kiln into an optimizer project.

## My call

Yes, do a minor perf pass now.

Not because Kiln needs to be fast already. Because these changes are mostly **removing obvious interpreter bringup costs**. They give you a more honest baseline for future work.

The pass should end when you hit the first thing that feels like “new compiler architecture.”

Good now:

```txt
local VM fast paths
frame caching
basic bytecode visibility
obvious redundant MOVE cleanup
```

Too much now:

```txt
specialized opcode families
intrinsics everywhere
quickening
value representation redesign
optimizer pipeline
```

`hot-frame caching + scalar fast paths + bytecode cleanup`


1. Constant pool dedup for scalar literals.
2. Indexed access lowering cleanup.
3. Re-run map/array/entity benches.
4. Add INDEX_GET / INDEX_SET fast paths.
5. Re-run benches again.

1. INDEX_GET_CONST / INDEX_SET_CONST
2. String hash caching
3. Maybe string interning
4. A very small arithmetic-const opcode family
5. Maybe compare+branch fusion
6. Known immutable function calls later
