# Kiln Module / File Environment Refactor Plan

## Core Direction

Shift Kiln from:

```txt
file = proto
```

to:

```txt
file = persistent BindingTable + init proto
```

A source file has:

```txt
file environment
    persistent BindingTable for top-level bindings

init proto
    executable bytecode that initializes that file environment
```

This removes the discrepancy between entry files and imported modules.

Top-level file declarations are no longer root-frame locals. They are persistent file bindings.

Nested function/block declarations stay frame locals.

## Why This Exists

This case should work:

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}

export { mul }
```

`mul` must be able to use `scale` later, after the file init proto has finished.

Because Kiln has no closures/upvalues, `scale` cannot live in the parent proto frame. It must live in persistent file/module storage.

So:

```txt
scale
    file BindingTable binding

mul
    file BindingTable binding holding a function value

mul body
    resolves scale through same-file BindingTable lookup
```

This is not closure capture. It is same-file binding access.

## BindingTable Meaning

A `BindingTable` is persistent named storage:

```txt
BindingTable
    names[]
    values[]
    is_mutable[]
    count
```

It holds all bindings for that environment, not only exports.

Examples:

```txt
global_env
    core builtins and explicit global declarations

entry_env
    top-level bindings from the entry file

module_env
    top-level bindings from one imported source/native/bundle module
```

A module BindingTable contains private and exported bindings.

Export is visibility over existing bindings. It does not copy values.

```txt
module BindingTable
    scale    private
    mul      exported
```

## Storage Shape

Do not flatten everything into a vague `binding_tables[]` unless the code earns it.

Prefer role-readable storage:

```txt
State
    global_env: BindingTable
    entry_env: BindingTable
    module_envs: fixed/dynamic collection of BindingTable
    module_count: number of used module envs
```

`global_env` and `entry_env` are distinct because they have distinct language roles.

`module_envs` stores imported source modules, native modules, and later bundle namespaces.

## Access Shape

Storage can stay role-based, while bytecode access becomes generic.

Use a compact environment reference:

```txt
env_ref
    identifies one BindingTable

binding_id
    identifies one binding inside that BindingTable
```

Conceptually:

```txt
env_ref 0
    global_env

env_ref 1
    entry_env

env_ref 2 + n
    module_envs[n]
```

Then bytecode can use generic binding-table operations:

```txt
GET_BINDING dst, env_ref, binding_id
SET_BINDING src, env_ref, binding_id
```

This replaces source-shaped opcodes like:

```txt
GET_GLOBAL
SET_GLOBAL
GET_FILE
SET_FILE
GET_MODULE
SET_MODULE
```

The VM does not need to know whether the source name came from globals, the entry file, a source module, or a native module.

The VM only needs:

```txt
which BindingTable?
which binding inside it?
read or write?
```

## Lookup Rules

Inside code compiled from a file:

```txt
1. locals / params
2. current file environment
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

## ProtoState Context

`ProtoState` should keep the compile context needed to resolve names.

Likely needed:

```txt
current_env_ref
    current file environment for this proto

import namespace table
    namespace name -> env_ref
```

Do not add a stored `is_module_top_level` flag.

File-root declaration can be inferred from existing compile state:

```txt
function_depth == 0
scope_depth == 0
```

So:

```txt
if function_depth == 0 and scope_depth == 0:
    declaration goes into current file environment
else:
    declaration goes into frame locals
```

Child function protos keep the same `current_env_ref` as the file they are compiled from. That lets function bodies resolve same-file bindings without closures.

## ExprDesc Direction

Current `ExprGlobal` can collapse into a more general binding descriptor.

Conceptual descriptor:

```txt
ExprBinding
    env_ref
    binding_id
```

Then these all become the same lowerable shape:

```txt
same-file binding
    current_env_ref + binding_id

global binding
    global env_ref + binding_id

imported namespace member
    imported env_ref + exported binding_id
```

The compile-time resolution rules differ, but the VM access is the same.

## Top-Level Declaration Lowering

At file root:

```kiln
x := 10
```

declares `x` in the current file environment.

At nested scope:

```kiln
function() {
    x := 10
}
```

declares `x` as a frame local.

For file-root declarations:

```txt
1. validate names
2. create/reserve BindingTable entries
3. lower RHS into temp slots
4. SET_BINDING into the file environment
```

The exact self-reference policy can be decided during implementation, but the key storage rule is settled:

```txt
file-root declarations are file environment bindings, not frame locals
```

## Global Declarations

`global` remains explicit.

```kiln
global debug := true
```

declares into `global_env`.

Normal file-root declaration:

```kiln
debug := true
```

declares into the current file environment.

So the storage classes are:

```txt
local
    frame slot

file binding
    current file BindingTable

global binding
    global_env BindingTable
```

## Export Semantics

A module BindingTable holds all top-level bindings.

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
move bindings into entry_env
merge bindings into globals
```

Export only says:

```txt
other files may resolve this binding through namespace access
```

## Native Modules First

After the binding-table/file-env refactor, implement native modules before source-file modules.

Reason:

```txt
native modules test namespace access and BindingTable module storage
without needing path resolution, source loading, cycle detection, bundles, or export manifests
```

A native module is just a host-filled BindingTable.

Example conceptual host setup:

```txt
bind_native_module(state, "array")
bind_native_module(state, "math")
```

The module environment contains native function values:

```txt
array module env
    push     NativeFunctionObject
    pop      NativeFunctionObject
    length   NativeFunctionObject
```

Kiln source still imports it normally:

```kiln
import "array"

array.push(items, value)
```

Do not make native module functions global by default.

The point is to prove:

```txt
import -> namespace name -> env_ref
namespace.member -> binding_id
call -> native function value
```

## Minimal Native Module Import

First import resolver can be tiny:

```txt
parse import "array"
    check registered native module envs
    bind namespace name "array" to env_ref
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

Source module load flow:

```txt
resolve path
if already loaded:
    return module env_ref

if currently loading:
    cyclic import error

create module BindingTable
compile source file with current_env_ref = module env_ref
load imports first
run module init proto once
mark loaded
return module env_ref
```

Source lookup policy can follow the existing module plan:

```txt
user source files/directories first
core/host native modules as fallback
```

So a source file can override a core module name if resolution rules allow that.

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

## Suggested Milestones

### Phase 1: Generic Binding Access

Replace or route `GET_GLOBAL` / `SET_GLOBAL` through generic binding access.

Goal:

```txt
globals still work
VM now knows how to read/write BindingTable by env_ref + binding_id
```

No language behavior change required yet.

### Phase 2: Entry File Environment

Add `entry_env`.

Change file-root declarations to use `entry_env`.

Nested locals remain frame slots.

Test:

```kiln
scale := 10

mul :: function(x) {
    return x * scale
}

print(mul(3))
```

Expected:

```txt
30
```

This proves persistent file-scope bindings work without closures.

### Phase 3: Native Module Environments

Add host-filled native module envs.

Import native module namespaces:

```kiln
import "array"

items := []
array.push(items, 10)
```

Goal:

```txt
namespace access works
native functions work through module envs
no source loader yet
```

### Phase 4: Source File Modules

Add `.kiln` source file loading.

Each source module gets its own file env and init proto.

Goal:

```kiln
import "math"

print(math.mul(3))
```

where `math.kiln` defines and exports `mul`.

### Phase 5: Export Visibility

Add final export forms:

```kiln
export

export {
    foo,
    bar,
}
```

No export means exports nothing.

Bare export means export all top-level file bindings.

Manifest exports listed top-level file bindings.

### Phase 6: Bundles

Add directory bundle imports after file modules are stable.

Bundles merge exported child bindings into one namespace.

## Non-Goals For This Pass

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
```

## Core Model Summary

```txt
BindingTable
    persistent named storage

global_env
    global BindingTable

entry_env
    entry file BindingTable

module_envs[]
    imported source/native/bundle BindingTables

env_ref
    compact reference to one BindingTable

binding_id
    index inside that BindingTable

GET_BINDING / SET_BINDING
    VM primitive for persistent binding access

file root declaration
    current file BindingTable

nested declaration
    frame local slot

same-file lookup
    locals -> current file env -> globals

namespace lookup
    imported namespace -> module env -> exported binding

native module
    host-filled module env

source module
    file env + init proto

export
    visibility over existing file env bindings
```

## Main Design Win

Modules do not add a new namespace mechanism.

They reveal the real primitive:

```txt
BindingTable is persistent namespace storage.
```

Files, globals, native modules, and source modules all use that primitive.

The VM stays simple:

```txt
read/write indexed BindingTable values
```

The parser/codegen owns meaning:

```txt
which env?
which binding?
is it visible?
is it mutable?
```
