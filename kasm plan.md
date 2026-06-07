Yeah. I checked the source shape.

Current path is exactly:

```txt
run_file(state, path)
    read file
    run_source(state, source, path)

run_source(state, source, source_name)
    Active_State = state
    clear state error
    compile_source(source, source_name)
    run_proto(state, state.entry_proto)
```

And `compile_source(...)` already does the important part:

```txt
compile_source(...)
    scan / parse / lower
    end_proto(...)
    Active_State.entry_proto = compiled proto
```

So yes, `disassemble_file` can be a single black-box operation.

No need to expose a `compile_file_to_proto`, no need for a public `debug_compile_file`, no need for a separate host-visible proto dump pipeline.

## Clean shape

```odin
kasm, err := kiln.disassemble_file(kstate, source_path)
if err != nil {
    print_kiln_error(err)
    os.exit(1)
}

fmt.println(kasm)
```

And internally:

```txt
disassemble_file(state, path) -> string, err
    Active_State = state
    clear state error

    read source file
        on read failure return Error

    compile_source(source, path)
        on compile failure return Error

    entry := state.entry_proto

    format entry proto bytecode into string
    format child protos too
    return string, nil
```

That is the right amount of API.

## Main host branch

In `main.odin`, the mode can just be:

```txt
if first_arg == "disasm":
    expect exactly one path arg
    resolve optional .kiln same as normal execution
    new state
    bind core env/modules
    set argv if needed, though script args are irrelevant
    kasm, err := kiln.disassemble_file(kstate, source_path)
    print error or print kasm
    return
```

No execution.

## Why it works without running

Because bytecode already exists after `compile_source`.

Execution only materializes runtime behavior:

```txt
LOAD_FUNC creates function objects
CALL runs code
RETURN exits frames
```

But the actual compiled child protos already exist inside:

```txt
state.entry_proto.child_protos
```

So the disassembler only needs the compiled proto tree, not a VM run.

## About helper overthinking

You’re right. For this stage, do **not** design it as:

```txt
compile_file_to_proto
disassemble_entry_function
disassemble_proto_tree
debug_dump_proto
debug_format_const
...
```

as a whole little subsystem.

Just make:

```txt
disassemble_file
```

own the bespoke job.

Inside that proc, format the entry proto and child protos however directly feels sane. If the formatting body becomes ugly, split a private formatting proc later because the code earned it, not because “debug architecture.”

The only real boundary needed now is:

```txt
kiln.disassemble_file(state, path) -> string, err
```

Everything else is implementation detail.


bench.kiln

entry
    slots 2
    ops 7

    children
        P0 = bench

    bindings
        B0 = bench
        G0 = print

    code
        0000    LOAD_FUNC       R0, P0      ; bench
        0001    SET_MAIN_BIND   R0, B0      ; bench
        0002    GET_GLOBAL_BIND R0, G0      ; print
        0003    GET_MAIN_BIND   R1, B0      ; bench
        0004    CALL            R1, 0, 1
        0005    CALL            R0, 1, 0
        0006    RETURN          R0, 0

proto bench
    params 0
    slots 5
    ops 10

    constants
        C0 = 10000000
        C1 = 0
        C2 = 1

    code
        0000    LOAD_CONST      R0, C0      ; 10000000
        0001    LOAD_CONST      R1, C1      ; 0
        0002    LOAD_CONST      R2, C1      ; 0
J0:
        0003    LESS            R3, R1, R0
        0004    JUMP_FALSE      R3, J1      ; +5
        0005    ADD             R2, R2, R1
        0006    LOAD_CONST      R4, C2      ; 1
        0007    ADD             R1, R1, R4
        0008    JUMP            J0          ; -6
J1:
        0009    RETURN          R2, 1


Final conventions:

R0
    frame-relative register slot

C0
    constant pool entry

P0
    child proto entry

B0
    main/current binding id

G0
    global binding id

M0.B0
    module binding id

J0:
    jump target label definition

J0
    jump label reference

;
    derived bytecode comment


<file>

entry
    slots N
    ops N

    constants     optional
    children      optional
    bindings      optional
    code

proto <name>
    params N
    slots N
    ops N

    constants     optional
    children      optional
    bindings      optional
    code

omit empty sections
omit params for entry
file name appears once at top
child protos use proto <name>
jump labels use compact J0: / J0
instruction indexes stay raw bytecode indexes
comments describe bytecode facts, not guessed source reconstruction
