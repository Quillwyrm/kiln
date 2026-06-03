# Return Call Forwarding / Open Results

Kiln supports Lua-style final-call expansion in return expression lists.

```kiln
return f()
```

returns all values produced by `f`.

```kiln
return f(), g()
```

returns the first value from `f`, then all values produced by `g`.

Only the final expression in a return list can expand. Non-final calls still request one result.

## Bytecode Shape

Kiln keeps the existing instructions:

```txt
CALL   base, arg_count, requested_result_count
RETURN first_slot, produced_count
```

Open counts are represented with sentinel operands:

```txt
CALL.C   == 255
RETURN.B == 65535
```

`CALL.C == 255` means the call produces an open result range.

`RETURN.B == 65535` means return the fixed prefix plus the last open result range.

## Runtime State

Each call frame stores the last open result range:

```txt
open_result_base
open_result_count
```

An open `CALL` records where its results started and how many values were produced.

An open `RETURN` computes:

```txt
fixed_prefix_count = open_result_base - first_slot
produced_count = fixed_prefix_count + open_result_count
```

The existing caller requested-result machinery still shapes the returned values:

```txt
requested fewer -> discard extras
requested more  -> fill missing values with nil
requested open  -> propagate the open result range
```

## Current Scope

Implemented for return lists only.

These remain fixed-count:

```kiln
a, b := f()
a, b = f()
print(f())
```

Function argument expansion can reuse the same open-result mechanism later, but it is not part of this pass.
