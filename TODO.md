
**Stack Trace**
This needs runtime call-frame awareness, but not source line debug metadata yet.

Use `CallFrame` plus `Proto.parent`/function names if available.

Each runtime error can report frames like:

```txt
runtime error: cannot call value of type int

stack:
  in explode
  in wrapper
  in main
```

The VM already has the active frame stack, so walking `state.frame_stack[0..state.frame_count]` is the honest source of call stack. Proto parent chains are useful for lexical ownership/debug naming, but they are not a call stack by themselves. Call stack comes from active frames.

Needed pieces:

- Each `Proto` should have a useful display name:
  - top-level maybe `<main>`
  - named function assignment maybe `foo`
  - anonymous function maybe `<function>`
- On `runtime_error`, include current active frame list.
- Do not overbuild structured exception objects yet. Your existing `Error` can probably grow enough.

**Post Stack Trace / Debug Meta**
This is where source locations become good.

You need instruction-to-source mapping:

```txt
instruction_index -> SourceSpan
```

or roughly:

```txt
DebugLine {
    instruction_index: int,
    token/file/line/column/span
}
```

Then runtime errors can say:

```txt
runtime error: array index out of range: index 4, length 2
test.kiln:32:17
    print(items[4])
                ^
stack:
  at get_item test.kiln:31:5
  at main test.kiln:40:1
```

Best KISS version:

- During codegen, whenever emitting an instruction from a token, record `(instruction_index, token.source_span)`.
- At runtime, current frame has `instruction_index`; look up nearest matching debug entry in that proto.
- Keep this as metadata on `Proto`, not in the bytecode instruction word.
- Don’t put debug locs in every helper yet. Start with source-reachable operations:
  - call
  - index get/set
  - arithmetic/comparison
  - global/local load maybe later
  - return/open result errors

Order I’d do it:

1. Runtime error string cleanup and negative tests.
2. VM stack trace from active frames.
3. Proto/function names.
4. Instruction-to-source debug metadata.
5. Caret snippets.
6. Optional richer structured error categories.

The main rule: don’t mix stack traces and source spans too early. Stack trace says “how did execution get here.” Debug metadata says “which source expression emitted this instruction.” They are related, but they are not the same system.


cat
grep-lite
file-info
copy-with-rename
todo scanner
directory report
stdin word count
config normalizer
tiny module demo
little text adventure/state demo
