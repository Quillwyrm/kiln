# Kiln Module / File Environment Plan

## Current Settled Model

Kiln has moved from:

```txt
top-level declarations = entry proto locals
```

to:

```txt
top-level declarations = main_env bindings
entry proto            = init bytecode for the main file
```

Current persistent binding tables on `State`:

```txt
main_env
    top-level bindings from the main source file

global_env
    host/builtin bindings and explicit `global` declarations
```

Current resolution order:

```txt
local bindings -> main_env -> global_env
```

This is intentional. `main_env` gives same-file/top-level visibility without closures or upvalues.

Example:

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}

print(mul(3))
```

`scale` is not captured. It is loaded from `main_env`.

## Shadowing Rule

Kiln should use normal language shadowing:

```txt
same scope/table duplicate = error
shadowing across scopes/env layers = allowed
assignment resolves the nearest mutable binding
```

So these are valid:

```kiln
name := "main"

show :: function(name) {
    print(name)
}
```

```kiln
global debug := "global"
debug := "main"

print(debug) // main binding
```

Same-scope duplicates are still errors:

```kiln
x := 1
x := 2 // duplicate top-level binding
```

```kiln
f := function(x, x) {} // duplicate parameter binding
```

## Declaration-Before-Use

Kiln is declaration-before-use.

This is not a bug or missing module feature:

```kiln
call_later :: function() {
    later()
}

later :: function() {}
```

`later` is not visible while `call_later` is compiled.

That fits the one-pass parser-lowerer design and keeps Kiln simpler. If order-independent top-level functions are ever wanted, that would require a deliberate predeclare pass. Do not add that accidentally.

## Current Bytecode Shape

Do not replace this with generic env refs yet.

Current concrete opcodes:

```txt
GET_MAIN_BIND
SET_MAIN_BIND
GET_GLOBAL_BIND
SET_GLOBAL_BIND
```

This is the right current shape. It keeps the VM direct and avoids a fake generic environment abstraction before modules exist.

Future module support may add:

```txt
GET_MODULE_BIND
SET_MODULE_BIND
```

or may later justify a generic binding instruction. Do not decide that until module envs exist in code.

## Current BindingTable Meaning

`BindingTable` is persistent named storage:

```txt
names[]
values[]
is_mutable[]
count
```

It is used for:

```txt
main_env
global_env
future module envs
```

Binding indexes are only meaningful inside one specific `BindingTable`.

## Runtime / Host API Boundary

Do not over-design runtime/load/check semantics yet.

Current rule:

```txt
State is the active mutable Kiln runtime/program container.
compile_source may mutate it.
After compile failure, the active State is not guaranteed meaningful.
```

The CLI creates a fresh `State` for each command, which is enough for now.

Do not add rollback, lifecycle preservation, "loaded program" management, or embedding policy until the runtime API becomes the active task.

## Why Modules Still Need File Environments

For modules, the same idea generalizes:

```txt
source file = persistent file/module BindingTable + init proto
```

A module file has:

```txt
module_env
    persistent BindingTable for top-level module bindings

init proto
    executable bytecode that initializes module_env
```

Example:

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}

export { mul }
```

`mul` must be able to read `scale` after the module init proto has finished.

Because Kiln has no closures/upvalues, `scale` cannot live in the module init proto frame. It must live in persistent module storage.

## Future Module Storage Shape

Keep storage role-readable until the code earns a more generic shape.

Likely future `State` direction:

```txt
State
    main_env:   BindingTable
    global_env: BindingTable

    module_envs: fixed/dynamic collection of BindingTable
    module_count: int
```

No `EnvRef` enum or generic environment registry yet.

If module lookup needs a compact handle later, add the smallest handle that the actual implementation needs.

## Future Lookup Rules

Inside code compiled from a file/module:

```txt
1. locals / params
2. current file/module environment
3. global environment
```

Imported namespaces are not searched by bare name.

They require qualified access:

```kiln
import "math"

math.add(1, 2)
```

Same-file private access is bare:

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}
```

External access must use namespace qualification and export visibility:

```kiln
import "math"

math.mul(3)   // ok if exported
math.scale    // error if private
```

## ProtoState Context Later

Child function protos must know which persistent file/module environment they belong to.

Current main-file implementation can hard-code `main_env`.

For modules, `ProtoState` will probably need a small compile context:

```txt
current module/file env
imported namespace table
```

Do not add that until modules exist.

Top-level declaration is still inferred from existing compile state:

```txt
function_depth == 0
scope_depth == 0
```

So:

```txt
top-level declaration -> current file/module BindingTable
nested declaration    -> frame local slot
```

## Export Semantics

A module `BindingTable` holds all top-level module bindings.

Export only controls external visibility.

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}

export { mul }
```

Means:

```txt
scale
    exists in module env
    private

mul
    exists in module env
    exported
```

Export does not:

```txt
copy values
create a map
create a module object
move bindings into main_env
merge bindings into globals
```

Export only says:

```txt
other files may resolve this binding through namespace access
```

## Native Modules First

Implement native modules before source-file modules.

Reason:

```txt
native modules test namespace access and BindingTable module storage
without needing path resolution, source loading, cycle detection, bundles, or export manifests
```

A native module is just a host-filled module BindingTable.

Example conceptual host setup:

```txt
bind_native_module(state, "array")
bind_native_module(state, "math")
```

Kiln source imports it normally:

```kiln
import "array"

array.push(items, value)
```

Do not make native module functions global by default.

## Minimal Native Module Import

First import resolver can be tiny:

```txt
parse import "array"
    check registered native module envs
    bind namespace name "array" to that module env
```

No filesystem yet.

No source module loading yet.

No bundles yet.

This proves the user-facing model:

```txt
without import
    namespace unavailable

with import
    namespace available
```

## Source Modules Later

After native module imports work, source modules become another provider for the same namespace mechanism.

Source module load flow later:

```txt
resolve path
if already loaded:
    return module env

if currently loading:
    cyclic import error

create module BindingTable
compile source file against that module env
run module init proto once
mark loaded
return module env
```

Source lookup policy can be decided then.

Do not build path resolution, source loading, cycles, or caching into the first native-module import pass.

## Bundles Later

Bundles come after plain file modules.

A bundle is another module environment created by merging exports from direct child modules.

Bundle env:

```txt
BindingTable containing merged exported bindings
```

Bundle rules later:

```txt
direct .kiln children only
sorted filename order
each child keeps its own file env
merge exported bindings into bundle env
duplicate exported names are errors
```

Do not implement bundles before plain source modules.

## Remaining Milestones

### Phase 1: Native Module Namespaces

Add host-filled native module envs.

Implement:

```txt
import "array"
namespace.member access
call native function through namespace
```

Goal:

```txt
namespace access works
native functions work through module envs
no source loader yet
```

### Phase 2: Export Visibility

Add export state for module env bindings.

Possible forms:

```kiln
export

export {
    foo,
    bar,
}
```

No export means exports nothing.

Bare export means export all top-level module bindings.

Manifest export lists specific top-level module bindings.

### Phase 3: Source File Modules

Add `.kiln` source file loading.

Each source module gets its own module env and init proto.

Goal:

```kiln
import "math"

print(math.mul(3))
```

where `math.kiln` defines and exports `mul`.

### Phase 4: Bundles

Add directory bundle imports after file modules are stable.

Bundles merge exported child bindings into one namespace.

## Non-Goals For The Next Pass

Do not add:

```txt
module objects
module map values
Lua-style returned tables
dynamic namespace lookup
globals polluted by module exports
scoped imports
bundles before file modules
dynamic native plugins
manifest files
package manager behavior
generic env_ref abstraction
generic GET_BINDING / SET_BINDING
runtime/check/load lifecycle policy
order-independent forward references
```

## Core Model Summary

```txt
BindingTable
    persistent named storage

main_env
    main source file BindingTable

global_env
    host/builtin/global BindingTable

module_envs
    future imported source/native/bundle BindingTables

top-level declaration
    current file/module BindingTable

nested declaration
    frame local slot

same-file lookup
    locals -> current file/module env -> globals

namespace lookup
    imported namespace -> module env -> exported binding

native module
    host-filled module env

source module
    module env + init proto

export
    visibility over existing module env bindings
```

## Main Design Win

Modules do not add a new namespace mechanism.

They use the primitive Kiln already has:

```txt
BindingTable is persistent namespace storage.
```

The parser/codegen owns meaning:

```txt
which binding table?
which binding index?
is it visible?
is it mutable?
```

The VM stays simple and concrete:

```txt
GET_MAIN_BIND / SET_MAIN_BIND
GET_GLOBAL_BIND / SET_GLOBAL_BIND
future module binding ops only when modules exist
```
