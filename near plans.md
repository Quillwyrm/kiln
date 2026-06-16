Yeah, your ordering is mostly right. I’d make the next thing **three-part `for` clauses**.

My suggested order:

```txt
1. three-part for clauses
2. varargs
3. for-in loops
4. structs + field access
5. module bundles
6. cleanup pass
7. GC
```

I’d maybe swap **module bundles** earlier if you want a non-VM task between heavier runtime features, but conceptually it is least connected to GC/object semantics, so I would not let it block the core language surface.

## 1. Three-part `for` clauses next

This is the best next task.

It is specified, useful, and should mostly reuse machinery you already have:

```kiln
for i := 0; i < 10; i += 1 {
    print(i)
}
```

It is basically:

```txt
enter loop scope
emit initializer
loop_start:
    eval condition
    jump_if_false loop_end
    body
    post statement
    jump loop_start
loop_end:
patch breaks
exit loop scope
```

This is a good next feature because it stresses parser/codegen control-flow without adding a new runtime object kind.

The main details to be careful about:

```txt
initializer may be declaration or assignment
post may be assignment / compound assignment / call statement
post may not be declaration
condition is expression
loop variable scope should include condition, body, and post
break exits the whole loop
```

This is a nice contained win.

## 2. Varargs after that

Varargs are also a good next target, but they touch function call setup more than `for` does.

Spec shape:

```kiln
log := function(prefix, ...values) {
    print(values[0])
}
```

Semantics:

```txt
fixed params bind left-to-right
missing fixed args become nil
extra args are an error unless vararg exists
vararg captures remaining args into fresh array
```

Implementation pressure points:

```txt
parser: parameter list recognizes ...name only at end
proto/function metadata: has_vararg + vararg local slot
call setup: create array from extra args
arity check: fixed-only errors on extra args, vararg accepts them
```

This is still fairly contained. It does allocate arrays at call boundaries, so it touches runtime behavior, but not in a scary way.

## 3. For-in loops after varargs

`for-in` is more than just syntax.

```kiln
for value in items {
}

for index, value in items {
}
```

It needs semantic lowering/runtime policy:

```txt
collection expr evaluated once
array length captured at loop start
array element read at iteration start
map keys snapshot at loop start
map deleted key may produce nil value
iteration over non-array/non-map errors
loop vars are locals visible inside body
```

That is enough detail that I would not do it before three-part `for`.

It probably wants hidden compiler temps:

```txt
_collection
_index
_length / keys
_key
_value
```

For arrays, you can lower to an index loop.

For maps, use a key snapshot array, then lookup value each step. That matches your spec and avoids iterator object design.

This is still reasonable before structs because it completes control flow and collection traversal.

## 4. Structs + field access

Structs are the first actually large remaining language feature.

Your struct design is not just dot syntax. It adds real runtime concepts:

```txt
StructDefObject
StructObject
FieldSpec
field layout
field defaults
constructor validation
field assignment checks
unknown field errors
nominal struct-def identity
```

That touches:

```txt
ObjectKind / Value display / type()
parser
codegen
field access lowering
assignment target resolution
runtime get/set field op
constructor op
default construction
error messages
later GC marking
```

So yeah, I would not sneak this in before the smaller surface features.

The important call: implement **structs and field access as one semantic feature**, not separately as random dot syntax.

Dot access only earns itself because structs have fixed fields:

```kiln
entity.hp
```

So the feature chunk is:

```txt
struct def / struct instance / field get / field set
```

Immediate `struct { ... }` could be staged if needed, but the real useful core is probably:

```kiln
Entity := struct def {
    name: string,
    hp: int,
}

e := Entity {
    name = "goblin",
}

e.hp = 10
print(e.name)
```

That is the milestone.

## 5. Module bundles

This one is weirdly separate.

```kiln
import "actors"
```

where `actors/` loads direct `.kiln` files and merges exports into one namespace.

It touches:

```txt
resolver
module loader
module env storage
export merging
duplicate export errors
sorted file loading
cycle/reuse rules
```

But it does **not** really pressure parser/codegen/VM semantics much.

So I would either do it:

```txt
after for-in, before structs
```

if you want a break from VM/runtime work,

or:

```txt
after structs
```

if you want to finish core language semantics first.

My bias: do it after structs, because module bundles are packaging ergonomics. Structs are core data model.

## Why not GC earlier?

Your current vague plan makes sense:

```txt
finish surface
cleanup
GC
```

Especially if structs are truly in MVP.

If you do GC before structs, then structs later force you to reopen GC for:

```txt
StructDefObject field specs/defaults
StructObject field values
nested defaults / container defaults
```

That is not fatal, but if structs are near-term anyway, doing them before GC means GC sees the real heap shape.

## My actual recommendation

Do this:

```txt
Next:
    three-part for clauses

Then:
    varargs

Then:
    for-in loops

Then:
    structs + field access

Then:
    module bundles, unless you want a lighter non-VM task before structs

Then:
    cleanup and GC
```

The main reason is dependency shape:

```txt
for clauses:
    control-flow lowering only

varargs:
    call setup + array packing

for-in:
    control-flow + collection semantics + hidden temps

structs:
    new object model + parser/codegen/runtime access checks

bundles:
    module resolver/package ergonomics
```

So yeah: bang out three-part `for` next. It is useful, specified, and low-risk. Then varargs. That gets you momentum without disturbing the object model right before the heavy struct/GC work.
