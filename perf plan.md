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


Yeah, this is coherent to look at now. Your current results say:

```txt
arith:  Kiln strong
array:  Kiln strong
map:    Kiln strong
string: Kiln weak
```

That is not random. It matches the current runtime design.

## Assignment lowering

Your assignment lowering is **not wrong**.

It is correct semantics, but the bytecode still has avoidable final moves in some cases because the “retarget last result” logic has not caught up with newer producer ops like:

```txt
ADD_CONST
SUB_CONST
MUL_CONST
DIV_CONST
MOD_CONST
MAP_GET_CONST
ARRAY_GET_CONST
INDEX_GET
```

That is a clean bytecode cleanup, but it is not the reason string is slow.

---

# Why string is slow

Your string benchmark is:

```kiln
s := ""
i := 0
for i < 10000 {
    s = s .. to_string(i)
    i += 1
}
n := length(s)
print(n)
```

This hits the worst path in Kiln right now.

## 1. Your concat is naive

Current concat is essentially:

```odin
left_string := ...
right_string := ...
parts := [?]string{left_string.data, right_string.data}

result := new(StringObject)
result.data = strings.concatenate(parts[:])
result.hash = hash.fnv64a(transmute([]byte)result.data)
return Value(cast(^Object)result)
```

That means every `..`:

```txt
allocates a new StringObject
allocates a new string buffer
copies left string
copies right string
hashes the new string
```

For this loop:

```kiln
s = s .. to_string(i)
```

the left side gets bigger every iteration.

So the copy work is not:

```txt
final string length
```

It is:

```txt
0 + len("0")
+ len("0") + len("1")
+ len("01") + len("2")
+ len("012") + len("3")
...
```

That is quadratic growth. Classic naive immutable string append.

So yes: concat is naive. Not broken. Just naive.

## 2. `to_string(i)` is expensive

Current `native_to_string` does:

```odin
kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
```

For an int, `value_to_string` goes through `fmt.tprint`. Then `new_string_value` clones and hashes.

So per loop iteration:

```txt
format int to string
allocate/produce formatted string
clone into StringObject.data
hash StringObject.data
allocate StringObject
native CALL overhead
```

That is a lot.

## 3. `length(s)` is currently a native call

One final `length(s)` is irrelevant in this benchmark, but in general:

```kiln
length(x)
```

currently means:

```txt
GET_GLOBAL_BIND length
move arg
CALL native
arg count check
type check
return int
```

For hot loops, that is obviously more than an opcode.

---

# Normal ways to speed string work

## 1. Add `string.join(parts, sep)`

This is the most honest fix for repeated string building.

Instead of optimizing bad append loops invisibly, provide the normal tool:

```kiln
parts := []
i := 0

for i < 10000 {
    array.push(parts, to_string(i))
    i += 1
}

s := string.join(parts, "")
print(length(s))
```

Host behavior:

```txt
validate parts are strings
compute total byte length
allocate result once
copy each string once
return one StringObject
```

This turns the repeated concat benchmark from quadratic copying into linear copying.

This is the most grug string improvement. No ropes. No builder object. No hidden mutable string trick.

## 2. Add concat-chain lowering later, not now

This:

```kiln
s := a .. b .. c .. d
```

could be compiled as one multi-part concat instead of:

```txt
(((a .. b) .. c) .. d)
```

But it does not fix:

```kiln
s = s .. to_string(i)
```

because that crosses loop iterations. So concat-chain lowering is useful, but not the main problem in your benchmark.

## 3. Consider lazy string hash later

Right now every string construction hashes immediately.

That helps maps, but hurts string-heavy code where strings are never used as map keys.

A more string-friendly design is:

```odin
StringObject :: struct {
    header: Object,
    data: string,
    hash: u64,
    hash_ready: bool,
}
```

Then map lookup does:

```txt
if !hash_ready:
    compute hash
```

This avoids hashing every intermediate concat result.

But this adds state and a branch to map key access. Since your map wins are good, I would **not** do this first. Add `string.join` first. If string benchmarks are still bad, then consider lazy hash.

## 4. Improve `to_string` construction

The current `to_string` likely double-handles temporary string data:

```txt
value_to_string(value) returns string
new_string_value(...) clones it
```

For hot scalar `to_string(i)`, that matters.

A clean improvement would be a dedicated `to_string` result path for primitive values:

```txt
int -> format string -> StringObject owns that result
bool -> return "true"/"false" string
nil -> return "nil" string
string -> return same string object
```

But don’t make wrapper layers just to feel neat.

The key semantic win:

```kiln
to_string("abc")
```

can return the same StringObject because strings are immutable and string identity is not observable. No need to clone.

For int/float, you still need formatting and allocation.

---

# Should `to_string` be an opcode?

Maybe, but split the question.

## Opcode removes call overhead

Currently:

```kiln
to_string(i)
```

does:

```txt
GET_GLOBAL_BIND to_string
arg placement
CALL
native arg count check
native dispatch
return
```

A `TO_STRING` opcode would remove that.

But it does **not** remove the real heavy part:

```txt
format int
allocate string
hash/copy result
```

So `TO_STRING` opcode helps, but it does not magically fix the string benchmark.

## Better framing: core intrinsics

Don’t think “turn random builtins into opcodes.”

Think:

```txt
some immutable core globals are VM intrinsics
```

Compiler recognizes calls to the actual core binding and lowers them directly.

This matters for semantics. You should not lower by spelling alone if a local shadows it:

```kiln
to_string := function(x) { return "lol" }
to_string(123)
```

That must call the local.

So intrinsic lowering should only happen when resolution says:

```txt
this call is the immutable core global `to_string`
```

not merely when the identifier text is `"to_string"`.

---

# Which builtins earn opcodes?

## Strong yes: `length`

`length(x)` is tiny and common.

Opcode shape:

```txt
LENGTH A=dst, B=value_slot
```

Behavior:

```txt
string -> byte length
array  -> len
map    -> count
else runtime error
```

This avoids native call overhead and keeps semantics exactly the same.

This is the best first builtin opcode.

## Strong maybe: `type`

`type(x)` is tiny but returns a string, so it still allocates unless you cache type-name strings.

Opcode shape:

```txt
TYPE A=dst, B=value_slot
```

First version can still call `new_string_value(value_type_to_string(value))`. It saves call overhead.

Better later: return shared immutable type-name StringObjects.

But if you don’t use `type()` hot, defer it.

## Maybe: `to_string`

Useful if string conversion appears in loops, like your benchmarks.

Opcode shape:

```txt
TO_STRING A=dst, B=value_slot
```

First version:

```txt
string value -> MOVE same string object
other value  -> convert
```

That alone fixes `to_string(s)` clone waste.

For int/float, it still formats.

I’d do this after `length`.

## Weak/no: `to_number`

`to_number` mostly parses strings.

The heavy part is parsing, not native call overhead. It’s not a great opcode candidate unless you use it constantly.

## No: `print`

IO dominates. Native call is fine.

## No: filesystem/path/io

Host IO dominates. Keep native.

## Maybe later: `assert`

Not hot. Keep native.

---

# Module builtins as opcodes?

Some module funcs may earn opcode lowering too.

Example:

```kiln
array.push(arr, value)
```

This is hot in your array benchmark.

If `array.push` is an immutable core module binding, the compiler can lower:

```kiln
array.push(arr, x)
```

to:

```txt
ARRAY_PUSH Rarr, Rx
```

You already have `ARRAY_PUSH`.

That is a very coherent “builtin opcode” because it is not arbitrary. It maps a core primitive operation to a VM primitive.

Same rule:

```txt
only lower when resolution proves this is the core module binding
```

not just because the source text says `array.push`.

Good candidates:

```txt
length(x)        -> LENGTH
array.push(a, x) -> ARRAY_PUSH
type(x)          -> TYPE
to_string(x)     -> TO_STRING
```

Bad candidates:

```txt
filesystem.*
path.*
io.*
string.to_lower / to_upper / split / replace
```

Those are host/library work, not dispatch work.

---

# Coherent plan

Do not chase string perf by randomly adding opcodes.

Do this in order:

## 1. Add `LENGTH` opcode / intrinsic lowering

This is small, hot, and clean.

It helps array loops:

```kiln
for i < length(arr)
```

and string code:

```kiln
length(s)
```

## 2. Add intrinsic lowering for existing core opcodes

If `array.push` currently calls native module code, lower core `array.push` to `ARRAY_PUSH`.

That uses an opcode you already have.

## 3. Add `TO_STRING` opcode only if you want `to_string` in hot loops

Make first version simple:

```txt
if value is string:
    return same string object

else:
    same behavior as current to_string
```

Don’t overbuild.

## 4. Add `string.join`

This is the real fix for repeated string construction.

`string.join(parts, sep)` is a library primitive, not necessarily an opcode. It does one allocation and copy.

## 5. Rebench string as three separate workloads

Separate:

```txt
to_string only
concat only
join style
```

because your current string benchmark mixes all costs.

---

# Blunt recommendation

Immediate next perf work:

```txt
1. Generalize last-result retargeting.
2. Add LENGTH opcode/intrinsic.
3. Lower core array.push to ARRAY_PUSH if not already.
4. Add TO_STRING opcode only if `to_string` remains a hot benchmark target.
5. Add string.join for real string building.
```

Do **not** add lazy hashes, ropes, builders, or big string machinery yet.

Your string benchmark is slow mostly because it is doing the classic bad immutable string append pattern. The grug answer is not magic concat. The grug answer is:

```txt
use join for building
use opcodes for tiny core intrinsics
keep naive concat simple
```



---

1. Finish lowering cleanup:
   - retarget last result
   - unary operand direct lowering
   - branch compare fusion if still clean after KASM review

2. Fix string runtime basics:
   - lazy string hash
   - to_string(string) returns same value
   - concat empty-string shortcut
   - maybe string.join

3. Improve tiny builtins:
   - LENGTH opcode/intrinsic first
   - maybe TYPE / TO_STRING after

4. Error/source infrastructure:
   - string escape decoding
   - source spans
   - stack traces

5. Small language surface:
   - for clauses
   - varargs
   - for-in

6. Structs as its own pass.
