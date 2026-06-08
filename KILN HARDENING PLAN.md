    # Kiln Hardening Plan
    
    Baseline: `ksrc0.zip`.
    
    This document intentionally ignores older source zips and drops stale perf-plan drift. It only lists work that is still relevant against `ksrc0` and worth doing as hardening, not random optimization.
    
    The rule for this plan:
    
    ```txt
    keep Kiln grug-fast
    remove dumb work
    do not build an optimizer project
    do not turn core modules into an opcode kitchen sink
    do not add wrappers just to preserve old shapes
    ```
    
    ## Validation path
    
    Use the project validation path from `AGENTS.md`:
    
    ```powershell
    odin check src
    odin build src -out:kiln.exe
    .\kiln.exe run test
    ```
    
    For bytecode-shape checks:
    
    ```powershell
    .\kiln.exe -dis bench
    ```
    
    For benchmark work, build Odin in speed mode. Non-speed builds poison VM timings.
    
    ---
    
    ## Current benchmark read
    
    The current benchmark suite has useful signal but should not be treated as one global score.
    
    Current result shape:
    
    ```txt
    arith:  Kiln strong
    array:  Kiln strong
    map:    Kiln strong
    string: Kiln weak
    ```
    
    The string result is expected from the current runtime shape: immutable string concat copies repeatedly, `to_string` allocates, and every new string is currently hashed immediately even if it is never used as a map key.
    
    Benchmark caveats to keep in mind:
    
    ```txt
    bench_string:
        intentionally hits bad immutable append behavior
        Python may benefit from CPython local string concat behavior
    
    bench_map:
        Kiln/Lua/Python use string keys
        current Umka script uses int keys, so it is not the same map workload
    
    bench_array:
        Kiln uses array.push and 0-based indexing
        Lua version uses normal Lua array idioms
    ```
    
    Keep the families separate:
    
    ```txt
    arith
    array
    map
    string conversion
    string concat
    string join/building
    ```
    
    Do not blend them into one speed claim.
    
    ---
    
    # 1. String runtime hardening
    
    This is the cleanest remaining runtime hardening area.
    
    ## 1.1 Lazy `StringObject.hash`
    
    ### Current source problem
    
    In `ksrc0`, `StringObject.hash` is eagerly computed at string construction:
    
    ```txt
    builtins.odin:
        new_string_value hashes string_object.data immediately
    
    vm.odin:
        value_concat hashes result.data immediately
    
    vm.odin:
        map_find_slot reads key.hash directly
    ```
    
    That means plain string work pays map-key preparation cost. Temporary concat results get fully hashed even when they are never used as map keys.
    
    ### Target rule
    
    ```txt
    StringObject.hash is cached map-key hash.
    hash == 0 means unknown / not computed yet.
    Only map access computes it.
    ```
    
    Do not add `hash_ready` yet. If FNV ever returns `0`, correctness is still fine; that string just recomputes on map access. That is a good trade for now.
    
    ### Implementation shape
    
    Change both string construction sites to set:
    
    ```odin
    string_object.hash = 0
    ```
    
    Add one helper because lazy state needs a single owner:
    
    ```odin
    string_hash :: #force_inline proc(s: ^StringObject) -> u64 {
        if s.hash == 0 {
            s.hash = hash.fnv64a(transmute([]byte)s.data)
        }
        return s.hash
    }
    ```
    
    This helper is earned because it owns lazy cache state. It is not just a wrapper around a clear expression anymore.
    
    Change map primitives so hash is computed once per operation:
    
    ```txt
    map_get:
        key_hash := string_hash(key)
        idx, found := map_find_slot(map_object, key, key_hash)
    
    map_set:
        key_hash := string_hash(key)
        idx, found := map_find_slot(map_object, key, key_hash)
        inserted entry.hash = key_hash
    
    map_delete:
        key_hash := string_hash(key)
        idx, found := map_find_slot(map_object, key, key_hash)
    
    map_find_slot:
        take key_hash as an argument
        never read key.hash directly
    
    map_grow:
        reuse entry.hash already stored in active entries
    ```
    
    `MapEntry.hash` stays. It is the stored hash for the key at insertion time and keeps probing cheap.
    
    ### Validation searches
    
    After implementation:
    
    ```powershell
    rg "\.hash" src\kiln
    ```
    
    Expected direct writes:
    
    ```txt
    StringObject construction: hash = 0
    string_hash: computes s.hash
    map insert: entry.hash = key_hash
    map delete/clear/grow entry cleanup
    ```
    
    Bad pattern:
    
    ```txt
    map code reading key.hash directly
    new strings hashing immediately
    ```
    
    ## 1.2 `value_concat` empty-string shortcuts
    
    ### Current source problem
    
    `value_concat` always allocates a new string object and string buffer after validating both operands are strings.
    
    ### Target rule
    
    Strings are immutable and string identity is not observable, so these are valid:
    
    ```txt
    "" .. rhs -> rhs
    lhs .. "" -> lhs
    ```
    
    ### Implementation shape
    
    After type checks and casts in `value_concat`:
    
    ```odin
    if len(left_string.data) == 0 {
        return rhs
    }
    
    if len(right_string.data) == 0 {
        return lhs
    }
    ```
    
    For actual concatenation:
    
    ```odin
    result.hash = 0
    ```
    
    Do not hash concat results until map access.
    
    This does not fix repeated append. It removes obvious waste and first-iteration empty-string allocation.
    
    ## 1.3 `to_string(string)` returns the same string value
    
    ### Current source problem
    
    `native_to_string` always does:
    
    ```odin
    new_string_value(value_to_string(value))
    ```
    
    For a string argument, that clones an immutable string into a new `StringObject` for no semantic gain.
    
    ### Target rule
    
    ```txt
    to_string(s: string) returns s
    ```
    
    Implementation in `native_to_string`:
    
    ```odin
    value := ...
    object, is_object := value.(^Object)
    if is_object && object.kind == .STRING {
        kiln_state.slots[return_slot_base] = value
        return 1
    }
    
    kiln_state.slots[return_slot_base] = new_string_value(value_to_string(value))
    return 1
    ```
    
    For int/float, formatting still costs real work. Lazy hash removes only the immediate hash cost.

youi 

## 1.5 String work not included here

Do not do these in the string hardening pass:

```txt
string interning
ropes
hidden mutable append
concat-chain lowering
TO_STRING opcode
static string singletons
```

`TO_STRING` only removes call overhead. Runtime string fixes come first.

---

# 2. Core builtin intrinsic/opcode candidates

Only promote tiny VM primitive operations. Do not turn the standard library into bytecode.

## 2.1 Add `LENGTH` opcode and intrinsic lowering

### Current source problem

`length` is currently a native global:

```txt
core.odin binds `length` to native_length
```

A call to `length(x)` currently pays:

```txt
GET_GLOBAL_BIND
argument placement
CALL native
arg count check
type dispatch
return
```

`length` is a core VM primitive over string/array/map. It is small enough to be an opcode.

### Target opcode

```txt
LENGTH // ABx: A=dst, B=src
```

Runtime behavior should match `native_length`:

```txt
array  -> len(array.data)
map    -> map.count
string -> len(string.data)
else runtime error
```

### Lowering rule

Lower only when resolution proves this is the immutable core global `length`, not when the source text merely says `length`.

Do not break shadowing:

```kiln
length := function(x) { return 123 }
length(items) // must call local
```

If current binding resolution cannot prove core-global identity cleanly, do not add spelling-based lowering. Fix resolution or defer the intrinsic.

## 2.2 Lower core `array.push` calls to existing `ARRAY_PUSH`

`ARRAY_PUSH` already exists as a VM opcode and array literals use it.

The module function `array.push(arr, value)` is still a native call. In hot user code, that is an obvious dispatch cost.

Lower only when resolution proves this is the core module binding `array.push`.

Target:

```kiln
array.push(arr, value)
```

becomes:

```txt
ARRAY_PUSH Rarr, Rvalue
```

This is a good intrinsic because it maps directly to an existing primitive opcode.

Do not lower arbitrary module calls by spelling.

## 2.3 Defer `TYPE` and `TO_STRING` opcodes

`type(x)` and `to_string(x)` may earn opcodes later, but not before string runtime cleanup.

Reason:

```txt
TYPE still returns a string
TO_STRING still formats/allocates for numeric values
```

First fix:

```txt
lazy string hash
to_string(string) identity
concat empty shortcuts
string.join
```

Then rebenchmark.

## 2.4 Do not opcode these

Keep these as native/module functions:

```txt
print / io.*
filesystem.*
path.*
string.split
string.replace
string.trim
maps.get_keys
maps.get_values
system.*
```

Those are library/host/text algorithms, not VM primitives.

---

# 3. Branch condition hardening

The KASM still commonly shows:

```txt
LESS Rtmp, Ra, Rb
JUMP_FALSE Rtmp, Jend
```

This is real dispatch waste, but it is not as small as it first looks.

## Important constraint

Current instruction layouts are:

```txt
ABC:  op + A + B + C
ABx:  op + A + u16
AsBx: op + A + i16
Jump: op + i24
```

A fused compare-branch wants:

```txt
lhs slot
rhs slot
jump offset
```

That does not fit cleanly into the existing 32-bit layouts with full `i16` jump range.

So compare+branch fusion is not a tiny opcode patch unless a new instruction layout or restricted-offset design is chosen.

## Decision

Do not implement branch fusion as part of the minor hardening pass.

Keep it as a separate bytecode-layout design item.

When it is designed, start narrow:

```txt
reg/reg less branch for for/if conditions
maybe const compare branch later
```

Do not make a comparison opcode zoo.

---

# 4. Runtime error and source-location hardening

Current runtime errors use the current frame proto origin:

```txt
runtime_error -> set_error(proto.origin, message, context)
```

That means many runtime errors point at the function/file origin, not the exact failing expression.

This is not a performance task. It is language hardening. Do it before adding more surface area.

## 4.1 Per-instruction source location

Add source location data parallel to bytecode.

Target shape:

```txt
Proto:
    source_locations: []SourceLocation or []source_offset
```

Each emitted instruction should carry the source location of the construct that caused it.

Be careful: do not force every `emit_*` call to take a token if that explodes callsites. A small `ProtoState.current_location` may be cleaner if parser statement/expression code sets it at the right boundary.

The invariant must be honest:

```txt
runtime instruction index -> source location of source construct responsible for that instruction
```

No fake fallback that silently points everything to proto origin.

## 4.2 Runtime errors use instruction location

Before returning a runtime error, VM already writes:

```odin
frame.instruction_index = pc
```

Once instruction source locations exist, `runtime_error` should use the failing instruction's location, not only `proto.origin`.

Be precise about post-fetch `pc`:

```txt
word := bytecode[pc]
pc += 1
```

The currently executing instruction index is `pc - 1`.

## 4.3 Stack traces

After per-instruction locations exist, add stack traces.

Current error has only:

```txt
runtime_context string
message
location
```

Target error should carry a compact stack:

```txt
frame function/module name
source location for current/callsite instruction
```

Keep it simple. No symbolic debugger. No source excerpts first pass.

---

# 5. String escape decoding

Scanner currently says:

```txt
No escape decoding; backslash sequences are literal.
```

This is a core language literal hardening task.

Implement string escape decoding in `scanner.odin::scan_string`.

Required escapes should match the language doc, not ad hoc C drift. If the doc says:

```txt
\n
\t
\\
\"
\'
```

then implement exactly those.

Behavior:

```txt
valid escape -> decoded byte in token string value
unknown escape -> scanner error with source location
unterminated escape before closing quote/EOF -> scanner error
```

Do not add Unicode escapes or hex escapes unless the language doc explicitly chooses them.

---

# 6. Observability

Disassembly already exists and is the main truth view for lowering.

The useful next observability tool is execution counts, not another optimizer.

## 6.1 Instruction/opcode counters

Add optional VM counters behind a debug/profile path.

Minimum useful output:

```txt
total executed instructions
count per opcode
```

This answers:

```txt
how many MOVE instructions actually execute?
how hot are CALL, LENGTH, ARRAY_PUSH, MAP_GET_CONST?
are string benchmarks dominated by CONCAT or native CALL?
```

Do not let counters pollute normal runtime. Keep them behind a CLI flag or debug build path.

Possible CLI shape:

```powershell
.\kiln.exe profile bench
```

No need for nanosecond timing inside the VM yet. Opcode counts are enough.

---

# 7. Deferred language features

These are not hardening tasks. Keep them separate from perf/runtime cleanup.

## 7.1 Structs and field access

Treat as its own design project.

Structs touch:

```txt
field storage
field lookup
literal/default behavior
kind/type behavior
map overlap
future method temptation
error text
```

Do not mix structs into the string/runtime/lowering hardening pass.

## 7.2 Varargs

Separate call/arity design pass.

Varargs affect:

```txt
function parameter representation
call argument handling
array packing
missing/extra argument behavior
```

Do not implement while changing call intrinsics or return mechanics.

## 7.3 For clauses and for-in loops

Separate parser/lowering pass.

For clauses are likely straightforward.

For-in needs a precise iterable contract:

```txt
arrays: index/value or value?
maps: key/value order unspecified
strings: bytes or not supported?
```

Do not let for-in accidentally define hidden iterator objects unless that is explicitly chosen.

---

# 8. Rejected / not part of this plan

Do not do these as part of hardening:

```txt
JIT
quickening
NaN boxing
32-bit object handles
threaded dispatch
GC-for-performance pass
interpreter superinstruction zoo
string interning
ropes
hidden mutable string append
builtin opcode kitchen sink
optimizer pipeline
```

Some may become valid later. None are needed for the current Kiln baseline.

---

# 9. Suggested execution order

## Pass 1: string runtime hardening

```txt
lazy string hash
to_string(string) identity
concat empty shortcuts
string.join
```

Run:

```txt
string conversion benchmark
string concat benchmark
string join benchmark
map benchmark, to ensure lazy hash does not regress maps badly
```

## Pass 2: primitive intrinsics

```txt
LENGTH opcode / intrinsic lowering
array.push intrinsic lowering to existing ARRAY_PUSH
```

Run:

```txt
array benchmark
string benchmark using length
normal tests
KASM checks that shadowed length/array.push still call user/local binding
```

## Pass 3: error/source hardening

```txt
string escape decoding
per-instruction source locations
runtime stack traces
```

Run intentionally bad scripts, not benchmarks.

## Pass 4: observability

```txt
opcode execution counters
```

Use counters to decide any further opcode work. Do not guess.

---

# 10. Push gate for each hardening pass

For any pass:

```powershell
odin check src
odin build src -out:kiln.exe
.\kiln.exe run test
```

Then:

```txt
KASM proves expected bytecode shape
benchmark family relevant to the change is re-run
no helper was added unless it owns a real invariant
no source-shadowing semantics are broken by intrinsic lowering
```
