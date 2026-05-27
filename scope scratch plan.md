# Scope Scratch Plan

## Goal
Implement block-scoped control flow and function-ready parser structure in a KISS way, reusing current parser/codegen/VM foundations.

## Current Status
Completed:
1. `if / else if / else`
2. Block scope enter/exit using `ProtoState` scope-local-count marks
3. `return` with fixed multi-values (`return a, b, c`)
4. Unary `!`

## Next Slice
Implement:
1. `for <cond> { ... }`
2. `for { ... }` (sugar for infinite loop)
3. `break`

## Semantics Lock
1. `for <cond> { ... }`
   - Evaluate `<cond>` each iteration.
   - Exit when condition is falsey.
2. `for { ... }`
   - Infinite loop form.
   - No condition expression.
3. `break`
   - Exits nearest loop only.
   - Valid only inside loop bodies.
4. `continue`
   - Deferred for now.

## Parser Plan
1. Scanner
   - Ensure `BREAK` token kind exists and keyword mapping for `break`.
2. Statement dispatch
   - Add `.FOR -> parse_for_statement`
   - Add `.BREAK -> parse_break_statement`
3. Loop compile context (parser state)
   - Add fixed loop stack with entries:
     - `exit_jump_patch_list` (or fixed array + count)
     - `continue_target_index` (reserved for future `continue`)
   - Push on loop entry, pop on loop exit.
4. `parse_for_statement`
   - Consume `for`.
   - Record `loop_start_index := next_inst_index(proto_state)`.
   - If next token is `{`:
     - infinite form, no condition jump.
   - Else:
     - claim condition temp slot
     - parse condition expression into slot
     - emit `JUMP_FALSE` placeholder as loop-exit guard
   - Parse block body.
   - Emit back-edge jump to `loop_start_index`.
   - Patch condition false jump (if present) to loop end.
   - Patch all `break` jumps collected for this loop to loop end.
5. `parse_break_statement`
   - Error if loop stack is empty (`break` outside loop).
   - Consume `break`.
   - Emit `JUMP` placeholder.
   - Record jump index in current loop context patch list.

## Codegen/VM Impact
1. No new opcodes required.
2. Reuse existing:
   - `emit_jump_false`
   - `emit_jump`
   - `patch_jump`

## Validation Cases
1. `for true { print("x"); break }`
2. `for { ... break ... }`
3. `for cond { ... }` exits when cond false.
4. Nested loops:
   - inner `break` exits inner only.
5. `break` outside loop gives parser error with source location.

## After This Slice
1. Add `continue` using loop-context continue target.
2. Then move to function declarations / child proto bodies.
