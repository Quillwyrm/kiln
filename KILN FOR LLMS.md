KILN FOR LLMS
==============
no dragon book, no Lex, no Yacc. learning solo from modern first principals. inspired loosley by lua (minus the magic and tables), and informed by personal research, and knowledge gained from respected engineers like; Rob Pike, Jon Blow, Ginger Bill, Casey Muratori. and heavily inspired by the `Handmade` community. 

Purpose
-------
This file is implementation context for future LLM sessions. It describes the current Kiln backend as it exists in source, not a desired rewrite.

Rules for future assistants:
- Kiln is currently one Odin package: `package kiln`. Files are organization only, not namespaces.
- Do not infer missing language features from token names, opcode names, or future notes.
- Describe and modify the implementation that exists.
- Do not propose wrapper objects, manager layers, generic contexts, lifecycle scaffolding, or state passing unless a current invariant earns it.
- Global/package working state is intentional where the model has one active runtime/source pipeline.
- `ProtoState` is intentionally a named, passed state because parent and child proto builds must coexist.
- `Active_State` is intentional internal runtime context for the current host operation.
- Parser/source/codegen are direct and procedural. There is no AST.
- The current source surface is partial. Some VM/codegen features exist before the parser exposes them.

Current file roles
------------------
All files are `package kiln` except `src/main.odin`.

`src/kiln/vm.odin`
    VM substrate: opcodes, instruction layouts, Value/Object model, Proto/runtime function split, BindingTable, CallFrame, State, Active_State, global binding helpers, primitive value operations, runtime errors, and `run_vm`.

`src/kiln/scanner.odin`
    Token model and scanner. Raw source bytes -> `[dynamic]Token`. Scanner owns one active source scan at a time.

`src/kiln/parser.odin`
    Parser state, token cursor, parser errors, local/scope/temp slot logic, function literal lowering, expressions, statements, top-level compile driver. Direct parser-to-bytecode. No AST.

`src/kiln/codegen.odin`
    `ProtoState`, local binding records, codegen limits, proto construction/finalization, const pool helpers, instruction emitters, jump patching, call/return/global emit helpers.

`src/kiln/builtins.odin`
    Builtin/native functions, value display/stringification/type naming helpers, and `bind_global_env`.

`src/kiln/error.odin`
    `SourceLocation`, `Error`, and `set_error`. Errors are stored in the currently selected `Active_State`.

`src/kiln/runtime.odin`
    Host-facing state lifecycle and execution entry points: `new_state`, `delete_state`, `run_source`, `run_file`, `debug_run_file`.

`src/main.odin`
    Test/default host. Creates a state, binds builtins, runs `test.kiln`, prints host-facing errors/results.

Host lifecycle
--------------
The embedding shape is:

    kstate := kiln.new_state()
    defer kiln.delete_state(kstate)

    kiln.bind_global_env(kstate)

    result, err := kiln.run_file(kstate, "test.kiln")

The host passes `^State` at public boundaries. Public boundary procs select that state as `Active_State`. Internal helpers then use `Active_State` instead of receiving `^State` everywhere.

This is not duplicated authority if the rule is obeyed:

    public boundary takes state -> sets Active_State -> internal code uses Active_State

Current boundary procs that select `Active_State`:
- `bind_global_env(state)`
- `run_source(state, source, source_name)`
- `run_file(state, path)`
- `debug_run_file(state, path)`

Do not move `Active_State` into parser/compiler-specific state. It is runtime context, not parser state.

Runtime State and Active_State
------------------------------
`State` is the host-owned runtime instance.

It owns:
- `has_error: bool`
- `error: Error`
- `entry_function: ^ProtoFunctionObject`
- `slots: [MAX_VM_SLOTS]Value`
- `slot_count: int`
- `frame_stack: [MAX_CALLFRAMES]CallFrame`
- `frame_count: int`
- `global_env: BindingTable`

`Active_State: ^State` is package-level runtime context for the current Kiln operation. It is used by:
- global binding declaration/resolution
- builtin installation
- scanner/parser/codegen error reporting
- compile installation of `entry_function`

Do not pass `^State` through every parser/codegen helper just to avoid a global. That is parameter noise in the current one-active-runtime model. Pass `^State` at public API boundaries. Use `Active_State` internally.

`delete_state` currently frees the `State` shell only. It does not walk heap-backed runtime objects, arrays, maps, strings, protos, proto slices, or function objects. Full heap ownership/GC/destruction is not implemented.

Error model
-----------
`SourceLocation`:
- `source_name: string`
- `line: int`
- `column: int`

`Error`:
- `location: SourceLocation`
- `context_text: string`
- `message: string`

`set_error(location, message, context_text = "")` overwrites `Active_State.error`, sets `Active_State.has_error = true`, and returns `&Active_State.error`.

Scanner/parser errors usually point at token/source positions.
Runtime errors currently point at the current proto origin, not exact bytecode instruction locations. There are no bytecode debug tables yet.

Host presentation is outside Kiln. `main.odin` formats errors roughly as:

    file[line:column] Error [context]: message

Scanner model
-------------
Scanner source state is package singleton `Scanner`, not a named reusable state type.

`Scanner` owns:
- raw source text and source name
- byte cursor: `index`
- line/column cursor
- current token start offset/line/column
- dynamic token buffer
- failure latch

Scanner emits `Token` records:
- `kind: TokenKind`
- `value: TokenValue`
- `offset: int`
- `line: int`
- `column: int`

`TokenValue` only carries payload for:
- `IDENT -> string`
- `INT -> i64`
- `FLOAT -> f64`
- `STRING -> string`

Whitespace is skipped. Newlines are not tokens. Line comments `//...` are skipped. Strings are single-line quoted strings with no escape decoding. Identifiers are ASCII `[A-Za-z_][A-Za-z0-9_]*`. Numeric scanning supports decimal ints, hex ints with `0x`, and decimal floats including `.5`. Exponents/octal are not supported.

`scan_source(source, source_name)` resets `Scanner`, appends tokens, appends EOF on success, and returns `(tokens: [dynamic]Token, error: ^Error)`. Caller owns and deletes returned token dynamic array.

Token kinds currently include more than parser exposes. Do not assume language support only because a token exists.

Parser model
------------
Parser is package singleton `Parser`, not a named reusable type.

`Parser` owns:
- `tokens: []Token`
- `token_index: int`
- `failed: bool`

Parser is only token cursor/failure state. It does not own locals, temps, bytecode, const pool, child protos, scope depth, or loop fixups. Those belong to `ProtoState`.

Core token cursor helpers:
- `current_token()`
- `peek_token()`
- `at_token(kind)`
- `advance_token()`
- `consume_token(proto_state, kind, message)`

Parser errors call `parser_error(proto_state, token, message)`, which uses `proto_state.origin.source_name` for the source file and token line/column for position, then latches `Parser.failed`.

Direct parser-to-codegen
------------------------
There is no AST. Parser functions consume tokens and emit bytecode directly into the current `ProtoState`.

Current compile pipeline:

    compile_source(source, source_name)
        tokens := scan_source(source, source_name)
        Parser.tokens = tokens[:]
        Parser.token_index = 0
        Parser.failed = false
        entry_proto_state := begin_proto(origin, "entry", 0)
        parse_top_level_statements(&entry_proto_state)
        emit implicit `return nil`
        entry_proto := end_proto(&entry_proto_state)
        entry_function := new ProtoFunctionObject pointing at entry_proto
        Active_State.entry_function = entry_function

`compile_source` installs the compiled entry function on `Active_State.entry_function`; `run_vm(state)` then executes that entry.

ProtoState
----------
`ProtoState` is the mutable compile target for one proto/chunk/function/module-init. It is a real named type because more than one must coexist when compiling child protos.

`ProtoState` owns:
- `origin: SourceLocation`
- `name: string`
- `param_count: int`
- mutable builder buffers: `bytecode: [dynamic]u32`, `const_pool: [dynamic]Value`, `child_protos: [dynamic]^Proto`
- `frame_slot_count: int`
- compile-time locals: `local_bindings: [MAX_FRAME_SLOTS]LocalBinding`, `local_count: int`
- temporary slot cursor: `next_temp_slot: int`
- lexical scope: `scope_depth`, `scope_local_counts`
- loop/break fixup stacks: `break_fixups`, `break_fixup_count`, `loop_break_fixup_base`, `loop_depth`

`LocalBinding` maps source identifier name to VM frame slot:

    LocalBinding { name: string, frame_slot: int }

This is compile-time metadata. Do not replace it with `BindingTable`. `BindingTable` is runtime namespace storage. Locals compile away to frame slots.

Slot model inside ProtoState:
- frame slots are capped by `MAX_FRAME_SLOTS == 256` because bytecode slot operands are u8.
- locals use low slots.
- params are locals starting at slot 0.
- temps start at `next_temp_slot`.
- after statements and block iterations, `next_temp_slot` resets to `local_count` so temporary slots are reused.
- `record_slots` keeps `frame_slot_count` at max touched slot + 1.

Scope model
-----------
Scopes are compile-time only. No scope opcodes exist.

`begin_scope(proto_state)`:
- records current `local_count` in `scope_local_counts[scope_depth]`
- increments `scope_depth`

`end_scope(proto_state)`:
- decrements `scope_depth`
- restores `local_count` to saved mark
- resets `next_temp_slot = local_count`

`declare_local` rejects duplicate names in the current lexical scope only. Nested blocks may shadow outer locals. `resolve_local` reverse scans active local bindings and returns nearest match.

Function body scope is special: `parse_function_body` consumes braces but does not create an extra root scope. Parameters and top-level body locals share the function root scope. Blocks inside the function body use normal `parse_block`, so they create nested scopes.

Function literals and child protos
----------------------------------
`function(...) { ... }` is a primary expression. It emits a runtime function value into a destination slot by compiling a child proto and emitting `LOAD_FUNC` in the parent.

Flow:

    parse_function_literal(parent_proto_state, dst, function_name, origin_token)
        parse parameter tokens while still compiling parent
        child_proto_state := begin_proto(origin, function_name, param_count)
        declare each param as local in child, slots 0..param_count-1
        parse_function_body(&child_proto_state)
        emit implicit `return nil` footer in child
        child_proto := end_proto(&child_proto_state)
        append child_proto to parent_proto_state.child_protos
        emit_load_func(parent_proto_state, dst, child_proto_index)

Parent and child `ProtoState` values coexist. This is why `ProtoState` is explicit and passed.

No closures/upvalues. A child proto does not capture parent locals. Inside a function body, lookup sees the child proto's params/locals and then globals. Parent local names are not visible.

Declaration special case:

    foo := function(a) { ... }

passes `foo` as the child proto name so runtime error context can say `in foo()` instead of anonymous function. `function(...) { ... }` elsewhere uses `"<function>"`.

Current expression model
------------------------
Implemented expression parser is intentionally small:
- primary literals: int, float, string, true, false, nil
- identifiers: local-first, then global binding lookup
- function literal primary
- unary `!`
- call suffix after unary/primary with requested result count 1 in expression context

Precedence/binary expression parsing is intentionally not wired yet. Scanner tokens and VM/codegen opcodes exist for arithmetic/comparisons, but source-level infix parsing is not currently the implemented surface.

No parenthesized expression primary currently documented here unless source implements it later. Do not infer it.

Current statement model
-----------------------
Implemented statement forms:
- `return`
- `return expr`
- `return expr, expr, ...`
- `if expr { ... } [else { ... } | else if ...]`
- `for expr { ... }`
- `for { ... }`
- `break` inside loops
- `ident := expr`
- `ident = expr` for local assignment only
- call statement: `ident(args...)`

Statement dispatch is token-kind-led for control flow, then IDENT-led for declarations/assignment/call.

Bare blocks are not statement-dispatched unless source adds it later. `parse_block` exists and is used by `if` and `for`. Function bodies use `parse_function_body`, not `parse_block`, to avoid adding a root body scope above params.

`CONST_DECL`, `GLOBAL`, `MAP`, delimiters, array/map opcodes, etc. exist in token/opcode/codegen layers but do not imply complete parser surface.

Global lookup and BindingTable
------------------------------
`BindingTable` is a fixed-size namespace:

    names:  [MAX_BINDINGS]string
    values: [MAX_BINDINGS]Value
    count:  int

Globals live in `State.global_env`.

`BindingId` is a distinct int indexing one BindingTable. Bytecode global ops use binding ids instead of source strings:
- `GET_GLOBAL A, binding_id`
- `SET_GLOBAL A, binding_id`

Current parser behavior for identifiers:
- resolve local first.
- otherwise resolve an existing global binding by name.
- unknown names are compile errors.

Current local assignment only assigns locals. `ident = expr` errors if ident is not local. No general user global assignment surface is documented here.

`bind_global_env(state)` selects `Active_State = state` and installs builtin native functions into that state's `global_env` using `bind_native_global`.

Codegen and bytecode
--------------------
Bytecode is `[]u32`. Instruction layout is selected by opcode.

Layouts:
- `InstABC`: op u8, a u8, b u8, c u8
- `InstABx`: op u8, a u8, b u16
- `InstAsBx`: op u8, a u8, signed b i16
- `InstAx`: op u8, a u24-ish in u32 bit field
- `InstJump`: op u8, signed 24-bit offset

Important caps:
- frame slots: 256 (`u8` slot operands)
- const pool entries: 65536 (`u16` const index)
- child protos: 65536 (`u16` child proto index)
- fixed VM slots: 4096
- fixed call frames: 256
- fixed global bindings: 256

Codegen helpers append instruction words into `ProtoState.bytecode`. They also call `record_slots` so `frame_slot_count` reflects max slot touched.

Jump offsets are relative to the instruction index after fetch. `emit_jump` and `emit_jump_false` can emit placeholders. `patch_jump` patches placeholders to target current bytecode end. Conditional jumps use signed i16 offset. Unconditional jumps use signed 24-bit offset.

Loop/break lowering
-------------------
`for expr { ... }`:
- records loop start instruction index
- emits condition expression into temp slot
- emits `JUMP_FALSE` placeholder to loop exit
- parses block
- emits `JUMP` back to loop start
- patches exit jump
- patches all `break` jumps registered for this loop

`for { ... }`:
- no condition expression or exit jump
- loops until `break`, `return`, or runtime termination

`break` emits unresolved `JUMP`; its instruction index is stored in `ProtoState.break_fixups`. Per-loop base indexes isolate nested loop break fixups.

Proto finalization and ownership
--------------------------------
`begin_proto(origin, name, param_count)` returns a `ProtoState` with cloned name and dynamic builder arrays.

`end_proto(proto_state)`:
- copies dynamic bytecode buffer to exact `[]u32`
- copies dynamic const pool to exact `[]Value`
- copies dynamic child proto pointer buffer to exact `[]^Proto`
- deletes the dynamic builder arrays
- allocates `Proto`
- moves/copies final fields into it

Finished `Proto` owns its exact slices. `ProtoState` must not be used after `end_proto`. On parse failure before finalization, use `delete_proto_state` to delete cloned name and dynamic buffers.

Note: `Proto.name` currently receives the cloned name from `ProtoState`; finished proto owns that string conceptually. Full proto destruction is not implemented.

Proto versus function object
----------------------------
`Proto` is compiled bytecode data. It is not itself a callable `Value`.

Runtime callable values are heap objects:
- `ProtoFunctionObject` points at a `^Proto`
- `NativeFunctionObject` points at an Odin `NativeFunction`

`LOAD_FUNC` materializes a new `ProtoFunctionObject` from the current proto's `child_protos` table at runtime. The child proto is compiled data; the function object is the runtime value.

`compile_source` wraps the entry proto in a `ProtoFunctionObject` and stores it at `Active_State.entry_function`.

Value/object model
------------------
`Value` is a union:
- `bool`
- `i64`
- `f64`
- `^Object`

`Value{}` is language nil.

Heap objects start with `Object { kind: ObjectKind }`. `Object` must be first in every heap object. VM casts from `^Object` after checking kind.

Current object kinds:
- STRING -> `StringObject { header, data: string }`
- PROTO_FUNCTION -> `ProtoFunctionObject { header, name, impl: ^Proto }`
- NATIVE_FUNCTION -> `NativeFunctionObject { header, name, impl: NativeFunction }`
- ARRAY -> `ArrayObject { header, data: [dynamic]Value }`
- MAP -> `MapObject { header, data: map[string]Value }`

`value_type_name` user-facing types:
- nil, bool, int, float, string, array, map, function

Numeric semantics in VM helpers:
- int/int arithmetic stays int where implemented.
- int/float or float/int promotes to float.
- comparisons operate across int/float numeric family.
- invalid numeric operation paths currently panic in primitive helpers, except call/type errors converted to user errors in some paths.

Falsey semantics:
- nil and false are falsey.
- everything else is truthy.

Array/map runtime behavior
--------------------------
VM supports array and map opcodes, even where parser surface may be incomplete.

Array object stores `[dynamic]Value`.
- `NEW_ARRAY` creates empty array with reserved capacity.
- `ARRAY_LEN` returns length.
- `ARRAY_GET` requires array object and i64 index, bounds checked.
- `ARRAY_SET` requires array object and i64 index, bounds checked.
- `ARRAY_PUSH` appends.
- `ARRAY_POP` pops tail, errors on empty.

Map object stores Odin `map[string]Value`.
- keys must be string objects.
- missing key reads nil.
- assigning nil deletes key.
- non-nil assignment stores value.

CALL/RETURN and frame windows
-----------------------------
`State.slots` is one fixed global slot array for all active call frames.

Each `CallFrame` owns a window:
- `slot_base`: start of this frame's logical slot 0 in `State.slots`
- `proto`: currently executing proto
- `instruction_index`
- `return_slot_base`: caller slot where results should go
- `requested_results`: caller requested result count
- `caller_slot_count`: saved caller occupied slot range, restored on return

Slot operands in bytecode are frame-relative. VM computes physical slot as:

    physical = frame.slot_base + operand

Top-level `run_vm` seeds one frame at slot base 0 using `entry_proto.frame_slot_count`. Top-level `RETURN` ends execution and returns first produced value, or nil if no values.

`CALL A, B, C`:
- A is callee/result base slot.
- B is arg count.
- C is requested result count.
- arguments are in contiguous slots starting at A+1.

Native function calls execute immediately in the caller frame:
- native reads args from `args_base`
- native writes results at `return_slot_base` (the call base)
- native returns produced result count
- VM nil-fills missing requested results; extra produced results are ignored.

Proto function calls push a new frame:
- callee slot base is `args_base`
- callee slot 0 already contains arg 0
- callee frame uses the caller's argument slots as its initial frame window
- missing fixed params are explicitly filled with nil
- extra args remain above fixed params and are ignored for now
- frame count and slot count are checked against fixed VM limits

`RETURN A, B`:
- A is first produced slot in callee frame.
- B is produced result count.
- non-top-level return copies up to requested result count into caller result slots.
- copy handles overlap in shared slot array.
- missing requested results are nil-filled.
- extra produced results are ignored.
- caller slot count and frame count are restored.

Native ABI
----------
`NativeFunction` signature:

    proc(vm: ^State, args_base: int, arg_count: int, return_slot_base: int, requested_results: int) -> int

Contract:
- args live in `vm.slots[args_base + i]`
- native writes produced results starting at `return_slot_base`
- return int is produced result count
- VM shapes produced results to requested results after native returns
- native can call `runtime_error(vm, message)`; VM checks `state.has_error` after native call and returns `&state.error`

Current builtins
----------------
Installed by `bind_global_env`:
- `print(...)` -> prints values, returns 0 results
- `type(value)` -> string type name
- `length(value)` -> length of array/map/string; user runtime error otherwise
- `assert(condition, message?)` -> returns condition if truthy; runtime error if falsey
- `to_string(value)` -> string object using `value_to_string`
- `to_number(value)` -> returns int/float from numeric value or numeric string; nil on failure

`value_to_string` is conversion text for `to_string` and assertions. `print_value` is display formatting for print and may differ.

Runtime error model
-------------------
`runtime_error(state, message)` looks at current call frame, uses current proto origin, and sets context text:
- top-level frame -> `in entry file`
- named function -> `in name()`
- anonymous function -> `in anonymous function`

Runtime errors are incomplete but host-facing. Many invalid VM operation type paths still panic instead of returning `Error`.

Current language surface summary
--------------------------------
Definitely implemented in current parser:
- literals: nil, bool, int, float, string
- identifiers with local-first/global lookup
- local declaration `name := expr`
- local assignment `name = expr`
- call expressions/statements
- function literal `function(params...) { ... }` as value expression
- named function declaration via `name := function(...) { ... }`
- return, including multiple return expressions
- if / else / else if
- for conditional loop and infinite loop `for {}`
- break inside loops
- unary `!`
- source fallthrough returns nil

Partially present below parser surface or intentionally upcoming:
- arithmetic/comparison source precedence parser is not wired yet, though tokens/opcodes/value helpers exist.
- array/map opcodes and runtime objects exist; source syntax support may be incomplete/absent in current parser.
- `global`, `::`, `map`, semicolon tokens exist but current parser behavior should be checked before claiming surface support.
- modules/BindingTable-backed namespaces are planned but not implemented as source module loader.
- structs/type tags are future notes, not current implementation.
- closures/upvalues are intentionally absent.

Memory ownership realities
--------------------------
Current allocation model is simple and leaky by design until heap tracking/GC/destruction exists.

Known allocations:
- `new(State)`, freed by `delete_state`
- `new(StringObject)`, string data cloned by `strings.clone`
- `new(ArrayObject)`, dynamic array storage
- `new(MapObject)`, Odin map storage
- `new(Proto)`, exact slices for bytecode/const_pool/child_protos
- `new(ProtoFunctionObject)` at compile entry and each LOAD_FUNC execution
- `new(NativeFunctionObject)` for builtins

`delete_state` currently only frees the State shell. It does not walk or free heap objects, proto graphs, maps, arrays, function objects, or cloned strings.

Current project design line
---------------------------
Do not reinterpret Kiln through OOP patterns, AST compiler assumptions, static type system assumptions, or generic embeddable-runtime architecture.

The current backend model is:

    host API selects State
    scan source to tokens
    parser consumes tokens and mutates ProtoState
    codegen emits packed u32 bytecode and const/child proto tables
    end_proto freezes ProtoState into Proto
    ProtoFunctionObject wraps Proto as callable runtime value
    run_vm executes entry function with fixed slot/frame arrays
    CALL pushes frames or invokes native ABI
    RETURN shapes results back to caller

The important state split is:
- `Active_State`: current runtime instance for host operation
- `Scanner`: current raw source scan
- `Parser`: current token cursor/failure state
- `ProtoState`: explicit passed compile target for one proto
- `State`: host-owned runtime storage

Do not collapse `ProtoState` back into parser/emitter globals. Do not pass `^State` through every internal helper just to avoid `Active_State`. Do not invent reusable state types for singleton scanner/parser working state unless multiple live instances become a real current need.
