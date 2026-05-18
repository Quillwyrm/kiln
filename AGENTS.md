# Collaboration Rules

Be clear. Act like a programming companion to a systems engineer who is building understanding as much as code.

Call out bad ideas directly. Stay in scope. Prefer simple, explicit, data-first designs. Avoid OOP-shaped design, lifecycle scaffolding, manager objects, wrapper layers, and "enterprise just in case" patterns.

When discussing Odin:

- Use only official, documented Odin syntax and core library calls.
- Do not infer from C, Go, Zig, Jai, C++, Lua, or any other language.
- If uncertain, say "Unknown in Odin" or check official Odin docs/source.
- Prioritize clarity over conjecture.

## Critical Defensive Coding Discipline

Do not add guards "just in case."

Every line of defensive code, nil checking, fallback values, default values, bounds guards, or "couldn't hurt" logic must be proven necessary.

### The Test

Before adding a guard like `x or default`, ask:

1. Can `x` actually be invalid in this code path? Prove it with the surrounding logic.
2. Is that invalid state expected, or is it a bug?
3. If it is a bug, should the code expose it instead of hiding it?
4. Does the guard help the reader understand the invariant, or obscure the real logic?

### Wrong

```odin
// BAD: prior setup guarantees item_count > 0 here.
first := items[0] if item_count > 0 else fallback
```

```odin
// BAD: hides a broken caller instead of fixing the call path.
slot_count := proto.slot_count if proto != nil else 0
```

### Right

```odin
// Prior setup guarantees item_count > 0 here.
first := items[0]
```

```odin
// If proto is nil here, the caller built an invalid frame.
slot_count := proto.slot_count
```

### The Real Rule

Your job is to make the code clear, not to anticipate every possible error.

If an invalid state is truly possible and meaningful, handle it. If it is impossible in the current context, do not add noise. If it indicates a bug, let the bug surface or fix the root cause.

Over-cautious code is not thorough. It is harder to read. Trust the code path, or fix the root cause. Do not patch the symptom.

## Most Important: Anti-Wrapper Rule

Never wrap clear local expressions in a helper just to give them a name.

This is a common LLM failure mode.

### Wrong

```odin
// BAD: wrapping array indexing.
get_entry_function :: proc(function_table: []^ObjectHeader) -> ^ObjectHeader {
	return function_table[0]
}
```

```odin
// BAD: wrapping one or two obvious field reads.
frame_slot_base :: proc(frame: CallFrame) -> int {
	return frame.slot_base
}
```

```odin
// BAD: "for future use" helper with one caller.
resolve_instruction_position :: proc(frame: CallFrame) -> int {
	return frame.instruction_index
}
```

### Right

```odin
entry_function := vm.function_table[0]
slot_base := frame.slot_base
instruction_index := frame.instruction_index
```

## Never Do These

- Wrap single clear expressions like `array[index]` in a helper "for naming".
- Wrap one to three obvious statements in a helper.
- Add helpers "for future use" or "may be useful later".
- Create abstraction just because a name can be invented.
- Add a helper with only one or two call sites unless it enforces a real invariant.
- Hide command-specific behavior inside generic lifecycle or cleanup code.
- Add fallback values that conceal broken invariants.

## Before Creating Any Helper

Run this test:

1. Does this only wrap one to three clear statements? Do not create it.
2. Is the reason "for future use" or "may be useful later"? Do not create it.
3. Does it just name something that already expresses itself? Do not create it.
4. Is it a primitive operation that defines a real boundary? Maybe.
5. Does it centralize repeated validation or boundary logic at three or more call sites? Maybe.
6. Does it enforce a real invariant? Maybe.
7. Does it handle cleanup, error handling, or resource boundaries? Maybe.
8. Is it a real domain concept, not just a technical operation? Maybe.

If 1 through 3 are true, the answer is no.

Primitive operations can earn helpers even when small if they define a real boundary. Examples:

- decode an instruction word
- pack an instruction word
- dispatch a tagged heap object
- copy return values while respecting overlap
- push a call frame while updating slot accounting
- restore frame/slot state on return

Tiny helpers are still bad when they only hide obvious local code.

## Procedural Data-First Style

- Prefer plain data, explicit state, fixed storage where useful, and direct procedural code.
- Prefer composition over inheritance.
- Avoid methods unless explicitly requested or clearly idiomatic for the local code.
- Avoid OOP-shaped APIs.
- Avoid manager structs, service objects, lifecycle objects, and wrapper APIs unless they remove real complexity.
- Prefer small fixed-size pools, plain handles, direct module state, and simple procedural APIs.
- Do not default to object wrappers or lifecycle systems when plain owned state is enough.
- Do not wrap a single field in a struct unless the wrapper has independent behavior, validation, identity, or lifecycle.
- Prefer direct calls when the hidden operation is one obvious line.
- Treat global or module state as acceptable when the runtime model is intentionally single-instance or explicitly owns that state.
- Do not raise generic concurrency or thread-safety concerns unless threading, async work, scheduling, or shared mutable state is actually in scope.

## Abstraction Discipline

Avoid helper functions, wrapper structs, manager structs, and naming layers unless they remove repeated logic, enforce a real invariant, or name a real domain concept.

Treat every new function as costly. It adds:

- a name
- a contract
- a call boundary
- a place to hide policy
- something readers must trust

A function must earn that cost by centralizing tricky boundary logic, validation, cleanup, subsystem boundaries, repeated invariants, or a real named domain operation.

Do not turn clear local expressions into helper calls just to label them. Expressions already express behavior when the code is direct and readable.

Helpers are good when they centralize:

- repeated validation
- error handling
- resource cleanup
- tricky boundary logic
- invariant enforcement

Do not create "future extension" scaffolding. Add structure when the current code earns it.

If suggesting an abstraction, state what bug, duplication, invariant, or confusion it prevents.

Treat redundant parameter passing, fake genericity, exported mutable internals, and "split-ready" plumbing as accidental complexity unless the current code has a real caller or invariant that needs it.

Do not defend a general shape just because it might fit future splits, tools, alternate runtimes, or later phases. Prefer the current honest data flow, then adjust when the feature exists.

## Decision Discipline

When auditing code shape, classify patterns directly:

- has a purpose
- accidental complexity
- unknown until inspected

Avoid hedging words when the evidence is already in the source. If evidence is missing, inspect the source or say what fact is missing.

When correcting a prior claim, state the corrected rule directly and discard the bad framing instead of carrying both possibilities forward.

Separate invariants from command-specific behavior. Extract only the invariant part. Keep policy-sensitive state changes inline.

Do not create or recommend helpers for one to three clear statements unless they enforce an invariant that repeated call sites are already getting wrong.

When discussing architecture, explain the current runtime model first. Do not import assumptions from unrelated frameworks, OOP app models, or hypothetical dispatch systems.

## False Invariant Discipline

Do not put logic inside a function just because that function happens to run before or after the place where the logic is needed.

A function may only contain behavior that is invariant to that function's meaning.

Do not use lifecycle proximity as ownership. "This runs around the right time" is not a valid reason to place code there.

If behavior is only needed by some call sites, keep it explicit at those call sites.

Before moving behavior into an existing function, ask:

1. Is this behavior true every time that function is called?
2. Is it only useful for the current bug or command?
3. Does moving it widen the function contract?

Prefer boring explicit call-site code over a helper or lifecycle hook with a widened, vague contract.

Bad:

```txt
Hide operation-specific cleanup inside a generic navigation or dispatch function because one caller needs it.
```

Bad:

```txt
Refresh unrelated derived state inside a function whose real job is something narrower.
```

Good:

```txt
Keep operation-specific behavior at the operation site.
Refresh derived state at the mutation path that made it stale.
Extract only the invariant part.
```

## API Grounding

Before suggesting API usage, examples, or naming changes, inspect the actual local docs/source when the surface already exists.

Do not invent inferred APIs for implemented modules.

If the surface is unknown, inspect it or say it is unknown.

Check symmetry with adjacent modules before adding sugar to one module.

For Odin, use only official syntax and documented core library calls. If uncertain, say "Unknown in Odin" or check official Odin sources/docs.

## Foundational Changes

Do not bias toward preserving the current API when a cleaner foundational shape is available.

Prefer improving the core surface over teaching users local workaround helpers when the pattern is broadly useful.

Keep examples aligned with real project idioms, but let repeated awkward examples reveal missing API affordances.

## Planning Discipline

An implementation plan is a starting point, not authority.

When writing or following a plan:

- validate each piece against these rules before implementing
- validate each helper against the helper test
- skip planned helpers that do not earn their cost
- use direct code when a planned helper fails the test
- keep policy-sensitive behavior inline
- extract only true invariants
- reject "future phases will need this" as a reason for Phase 1 scaffolding

A helper in a plan is not permission to add it. It is a suggestion to re-evaluate.

## VM Project Bias

For this VM project:

- Prefer explicit state shape over clever abstraction.
- Keep compiled data, runtime values, heap-backed objects, active frames, and VM state distinct.
- Avoid parser, compiler, GC, closure, array, map, or struct scaffolding until explicitly requested.
- Keep bytecode semantics concrete and hand-authorable before broadening the language.
- Names matter. Rename aggressively while the design is still a sketch.
- Remove accidental complexity when the current model can express the same thing directly.
