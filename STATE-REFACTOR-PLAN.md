# State Refactor Plan

## Goal

Clean up the compile-time state model before source-level functions and module/init protos.

The current `Parser` / `Emitter` split is bring-up scaffolding. The fields inside them are
mostly not owned by "the parser" or "the emitter" as separate long-term concepts.

The key correction:

```txt
ProtoState is the mutable compile state for one proto.
Proto is the finished VM data.
```

## State Roles

```txt
State --might call this Run_State or something
    Runtime instance.
    Owns globals, frames, slots, current error storage, and later heap/module cache.

Source_State
    Active/global source cursor for now.
    Owns token stream, token index, source name, and source failure state.

ProtoState
    Mutable build state for one proto/function/module chunk.
    Must be explicit and passable because child protos need a fresh ProtoState while the
    parent ProtoState remains alive.
```

## Move Into ProtoState

Current parser-owned fields that actually belong to `ProtoState`:

```txt
locals
local_count
temp_slot
```

Current emitter-owned fields that also belong to `ProtoState`:

```txt
name
param_count
bytecode
const_pool
child_protos
frame_slot_count
```

## Intended Call Shape

Parser operations consume the active `Source_State` and mutate an explicit `ProtoState`:

```odin
parse_statement :: proc(proto_state: ^ProtoState) {
}

parse_expression_into :: proc(proto_state: ^ProtoState, dst: int) {
}
```

Emitter operations mutate the passed proto build state:

```odin
emit_load_const :: proc(proto_state: ^ProtoState, dst, const_index: int) {
}

emit_call :: proc(proto_state: ^ProtoState, call_base, arg_count, requested_results: int) {
}
```

Avoid ambiguous parameter names like `proto` when the type is `^ProtoState`.

## Why Passing ProtoState Wins

Child protos require two proto compile states to exist at once:

```txt
parent ProtoState stays alive
child ProtoState is created for function body
finish child -> ^Proto
append child to parent.child_protos
emit LOAD_FUNC in parent using child index
continue compiling parent
```

A global proto stack would work, but it hides the actual mutation target behind "current proto"
state. Passing `^ProtoState` makes the output target explicit without forcing `State` or
source cursor state through every call.

## Not In Scope

Do not solve these as part of this refactor:

```txt
compiler reentrancy
parallel compilation
compile-time imports
module loader design
runtime VM error conversion
closures/upvalues
```

This refactor is only about making the proto build target explicit so child protos and module
init protos have a clean foundation.
