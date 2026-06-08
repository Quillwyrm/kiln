Yes. The lazy hash note is probably the most real string win here. Right now this is dumb for string-heavy code:

```odin
result.data = strings.concatenate(parts[:])
result.hash = hash.fnv64a(transmute([]byte)result.data)
```

That means every temporary concat result gets fully hashed even if it is never used as a map key. In your string benchmark, most strings are never map keys. You are paying map-key preparation cost for plain string building.

That should change.

## 1. Lazy string hash

Current shape:

```odin
StringObject :: struct {
    header: Object,
    data:   string,
    hash:   u64,
}
```

Keep that shape. Do **not** add `hash_ready bool` yet.

Use `hash == 0` as “not computed yet.”

Could FNV produce `0` for some string? In theory yes. If that happens, that string just recomputes its hash each map access. Correctness is still fine. That is a good grug trade. No extra field, no extra bool, no wider object.

New string construction:

```odin
string_object.hash = 0
```

Concat:

```odin
result.hash = 0
```

Then maps compute hash when needed.

### The helper that is actually earned

This helper is earned because lazy hashing needs one invariant:

```odin
string_hash :: #force_inline proc(string_object: ^StringObject) -> u64 {
    if string_object.hash == 0 {
        string_object.hash = hash.fnv64a(transmute([]byte)string_object.data)
    }

    return string_object.hash
}
```

This is not wrapper slop. It owns lazy hash state.

Then map code should stop reading `key.hash` directly.

Change:

```odin
start := int(key.hash & u64(mask))
```

to either:

```odin
key_hash := string_hash(key)
```

before probing, or better pass the hash into the probe.

I’d prefer:

```odin
map_find_slot :: proc(map_object: ^MapObject, key: ^StringObject, key_hash: u64) -> (index: int, found: bool)
```

Then:

```odin
key_hash := string_hash(key)
idx, found := map_find_slot(map_object, key, key_hash)
```

Inside slot compare:

```odin
if entry.hash == key_hash {
    if entry.key == key || entry.key.data == key.data {
        return idx, true
    }
}
```

On insert:

```odin
entry.hash = key_hash
```

That avoids recomputing hash during set.

This is the clean lazy-hash version:

```txt
StringObject.hash:
    cached hash, 0 means unknown

string_hash:
    compute/cache hash when map needs it

StringObject construction:
    sets hash = 0

MapEntry.hash:
    stores hash used when inserted
```

This directly helps concat-heavy string benchmarks because temporary strings no longer get hashed unless they become map keys.

## 2. Naive concat

Your concat is currently naive because every `..` allocates and copies a new string:

```kiln
s = s .. to_string(i)
```

Each loop copies all of old `s` again. That is O(n²) copying.

The KISS fix is **not** ropes. Not a mutable hidden string. Not concat magic across loop iterations.

The KISS fix is:

```txt
keep `..` simple
add `string.join(parts, sep)`
```

Then efficient string building is explicit:

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

Host `string.join` does:

```txt
validate array elements are strings
compute total output length
allocate once
copy all pieces once
return string
```

That is the right grug tool.

### Can concat itself be cheaply improved?

Yes, small local wins:

#### a) Empty string shortcuts

In `value_concat`:

```odin
if len(left_string.data) == 0 {
    return rhs
}

if len(right_string.data) == 0 {
    return lhs
}
```

Because strings are immutable and identity is not observable, returning the existing string object is semantically fine.

This helps cases like:

```kiln
s := ""
s = s .. x
```

First iteration avoids one allocation.

It does not fix repeated append, but it is free and correct.

#### b) Maybe two-string manual concat

`strings.concatenate(parts[:])` is fine unless profiling says it’s bad. Don’t hand-roll copying yet. Your first real win is lazy hash and join.

## 3. Naive `to_string`

Current:

```odin
kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
```

For string input, this is bad.

```kiln
to_string("abc")
```

currently likely:

```txt
value_to_string(string) returns string_object.data
new_string_value clones it
new StringObject
```

That should just return the same string value.

KISS fix:

```odin
native_to_string :: proc(...) -> int {
    ...

    if object, ok := value.(^Object); ok && object.kind == .STRING {
        kiln_state.slots[return_slot_base] = value
        return 1
    }

    kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
    return 1
}
```

That is a pure win.

### For int/float/bool/nil

`to_string(i)` still formats. That is real work. But with lazy hash, the created string no longer gets hashed immediately.

Also, for tiny constant names:

```txt
nil
true
false
```

You could return shared static strings later, but don’t do that yet unless you add a general intern/static-string story.

## Are all 3 easy wins?

### Lazy hash

Yes. Very good win. Moderate touch because map code must compute hash lazily.

Required changes:

```txt
StringObject construction:
    hash = 0

value_concat:
    hash = 0

map_get/map_set/map_delete:
    compute key_hash once with string_hash(key)

map_find_slot:
    take key_hash arg or compute once at top

map_grow:
    existing entry.hash already stored, reuse it
```

This is worth doing.

### Concat

Partial easy win:

```txt
empty string shortcut:
    easy

string.join:
    easy/moderate core module function

full repeated-append optimization:
    not easy, do not do now
```

So “fix naive concat” means add the right explicit tool, not make `s = s .. x` magic.

### to_string

Easy win:

```txt
to_string(string) returns same string object
lazy hash removes immediate hash cost for new conversions
```

Opcode version is separate.

## Should `to_string` be an opcode?

Eventually maybe, but not first.

Do the runtime fixes first:

```txt
1. lazy hash
2. to_string(string) returns same object
3. concat empty shortcuts
4. string.join
```

Then benchmark.

If `to_string(i)` is still hot, add a `TO_STRING` opcode/intrinsic. But opcode only removes call overhead. It does not remove formatting cost.

## What I’d tell OC

```txt
String perf cleanup, KISS pass:

1. Make StringObject.hash lazy.

Use hash == 0 as "not computed".
All StringObject construction sites set hash = 0.

Add:

    string_hash :: #force_inline proc(s: ^StringObject) -> u64 {
        if s.hash == 0 {
            s.hash = hash.fnv64a(transmute([]byte)s.data)
        }
        return s.hash
    }

Map lookup/set/delete must call string_hash(key) once and pass/use that hash.
Do not read key.hash directly unless the value came from string_hash.

2. value_concat should not hash the result.

After concatenate:
    result.hash = 0

Also add immutable empty-string shortcuts:
    "" .. rhs -> rhs
    lhs .. "" -> lhs

Returning the existing string Value is valid because strings are immutable.

3. native_to_string should return strings unchanged.

If value is a string object:
    return the same Value

Only non-string values go through value_to_string/new_string_value.

4. Do not add TO_STRING opcode yet.
Do not add ropes.
Do not add hidden mutable string append.
Do not add interning.

5. After that, add string.join(parts, sep) as the real efficient string-building primitive.
```

## Expected benchmark impact

For your current string benchmark:

```kiln
s = s .. to_string(i)
```

Lazy hash should help a lot because you stop hashing every intermediate `s`.

`to_string(string)` won’t help that exact loop, because `to_string(i)` is int conversion.

Empty concat shortcut helps only the first iteration.

`string.join` will destroy that benchmark if you rewrite the benchmark to use the correct tool, because it changes quadratic copying to one final copy.

## Blunt call

Do lazy hash now. It’s obviously wrong to hash every string at construction when only map keys need hash.

Do `to_string(string)` same-object now. It’s obviously wrong to clone immutable strings.

Do concat empty shortcuts now. Tiny and correct.

Do `string.join` soon. That is the real fix for string building.

Do not add string opcodes until after those runtime/library fixes.
