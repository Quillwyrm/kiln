# Return Call Forwarding / Open Results

Current Kiln call lowering has fixed result counts:

```txt
CALL   base, arg_count, requested_result_count
RETURN first_slot, produced_count
```

So `return f()` currently returns one value if lowered through normal expression-list finishing.

If Kiln should support forwarding:

```kiln
return f()
```

meaning “return exactly whatever `f()` produced”, the VM needs an explicit open-result mechanism.

Two possible designs:

## Option A: OPEN result sentinel

Reserve a special `CALL` requested-result value:

```txt
CALL base, arg_count, OPEN_RESULTS
```

Meaning:

```txt
call f()
preserve the actual produced result count
RETURN uses that dynamic count
```

Needs a way for the VM to carry “last call produced N results” into `RETURN`.

## Option B: dedicated return-call opcode

Add a special instruction/path:

```txt
RETURN_CALL callee_base, arg_count
```

Meaning:

```txt
call function
return exactly its produced results directly to caller
```

This may be cleaner if forwarding is only valid for direct final-call returns.

## Semantic rule to decide

If enabled:

```kiln
return f()
```

forwards all results.

```kiln
return f(), g()
```

probably returns first result of `f()` plus all/one result of `g()` depending on whether Kiln wants Lua-style final-expression expansion in return lists.

Need to decide this deliberately. Do not accidentally add forwarding as a parser-only tweak.
