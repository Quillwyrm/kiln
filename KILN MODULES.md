# Kiln Module System

Current canon for Kiln modules.

This is design/implementation grounding, not the polished user-facing language reference.

## Terms

```txt
module
    one .kiln source file

bundle
    a directory of direct .kiln modules imported as one namespace

namespace
    imported qualified name used for module access

BindingTable
    runtime namespace storage: name -> Value
```

A namespace is not a runtime value. It is not a map, object, array, or local slot.

A module namespace is backed by a `BindingTable`.

## Import Syntax

Imports are top-level module declarations.

Imports must appear before non-import top-level statements.

```kiln
import "math"
import "bar/foo"
import baz "foobar"
import bundle "root/yourdir"
```

Meaning:

```txt
import "path"
    load module/bundle at path
    bind namespace from path basename/stem

import name "path"
    load module/bundle at path
    bind namespace as name
```

Examples:

```kiln
import "math"        // math.add()
import "bar/foo"     // foo.whatever()
import baz "foo/bar" // baz.whatever()
```

`.kiln` is optional for file modules.

No grouped imports. One `import` statement per module or bundle.

No scoped imports. `import` is not valid inside `if`, `for`, function bodies, or nested blocks.

Conditional usage should import the namespace at top level, then branch normally:

```kiln
import dbg "debug"

if debug {
    dbg.throw()
}
```

## Namespace Naming

Default namespace name comes from the final path component with `.kiln` stripped.

```txt
"math"          -> math
"bar/foo"       -> foo
"bar/foo.kiln"  -> foo
```

If the derived name is not a valid Kiln identifier, explicit naming is required.

```kiln
import "foo-bar"          // error
import foo_bar "foo-bar"  // ok
```

No sanitizing.

A namespace name may not collide with another top-level binding or imported namespace in the same module.

## Namespace Access

```kiln
import "math"

math.add()
```

`math.add` means:

```txt
resolve namespace math
resolve exported binding add in math's BindingTable
emit/use module BindingId access
```

Functions are just values in the BindingTable, same as other exported values.

The intended fast path is indexed binding access, not repeated runtime string lookup.

Conceptually:

```txt
math.add
    namespace math -> module namespace id
    add            -> BindingId inside that namespace
```

So bytecode should be able to use the module namespace id and member `BindingId`.

This preserves the purpose of `BindingTable` and `BindingId`: namespace member access is not Lua-style table lookup.

## Loader Rules

```txt
1. Absolute paths load exact paths.
2. Relative/bare paths resolve relative to the importing file's directory.
3. User files/directories are checked before core/host modules.
4. Missing `.kiln` is allowed for file modules.
5. Loaded modules and bundles are cached by canonical resolved id.
6. Cyclic imports are errors.
```

Core/host modules are fallback providers, not protected names.

## Module Loading And Initialization

Loading a module means:

```txt
resolve its imports
compile/emit its top-level proto
record its exported binding surface
run its top-level code once before dependent module code uses it
```

A loaded module is reused by canonical id.

A module's top-level code runs at most once per state.

This gives module imports a stable dependency order:

```txt
load dependency modules first
then initialize the importing module
```

Cyclic imports are errors.

```txt
a imports b
b imports a

=> cyclic import error
```

Implementation model:

```txt
loaded
    module/bundle BindingTable exists and is initialized

loading
    module/bundle is in the current import chain

not loaded
    module/bundle has not been loaded yet
```

The temporary `loading` set/stack is for cycle detection. It does not belong on `ProtoState`.

## Bundles

If an import path resolves to a directory, it imports a bundle.

```txt
actors/
    player.kiln
    enemy.kiln
    combat.kiln
```

```kiln
import "actors"
```

This creates namespace `actors` by loading the direct `.kiln` children and merging their exported bindings.

Bundle rules:

```txt
direct .kiln children only
sorted filename order
each file keeps its own module scope
imports inside bundle files are normal top-level imports
exports merge into the bundle namespace
duplicate exported names are errors
cycle rules still apply
```

A bundle is not shared package scope.

Files inside a bundle may import sibling modules normally.

A sibling import is still an explicit import and follows the same file-relative resolution rules.

Example shape:

```txt
actors/
    player.kiln
    enemy.kiln
    combat.kiln
```

`actors/combat.kiln`:

```kiln
import "player"
import "enemy"

...

export {
    hit,
}
```

Then importing the bundle:

```kiln
import "actors"
```

loads the direct `.kiln` children, and `combat.kiln` can explicitly depend on `player.kiln` and `enemy.kiln`.

If a bundle file imports a sibling module that is also part of the same bundle, that file is loaded once and reused by canonical id. No double-running top-level code.

## Export Syntax

Current settled shape:

```kiln
// no export statement
// exports nothing
```

```kiln
export
// exports all top-level module bindings
```

```kiln
export {
    foo,
    bar,
    baz,
}
// exports only listed top-level module bindings
```

`export` must be the final top-level statement in a module.

`export { ... }` is an export manifest. Listed names must refer to top-level module bindings in that file.

Duplicate names in an export manifest are errors.

## Export Behavior

Exports expose named module bindings from the file's BindingTable.

```kiln
foo :: function() {}
bar := 10

export {
    foo,
    bar,
}
```

This exports the bindings `foo` and `bar`.

Those bindings may hold function objects, native functions, numbers, strings, arrays, maps, or any other Kiln value.

No export map. No module values. No Lua table-return model.

## State Shape

Expected implementation shape:

```txt
State.global_env
    global BindingTable

State.modules
    loaded module/bundle BindingTables, keyed by canonical id

Loader/import working state
    current import chain for cycle detection
```

`BindingTable` remains namespace storage.

`LocalBinding` / `ProtoState` remain compile-time local and slot metadata.

Do not replace locals with `BindingTable`. Locals compile away to frame slots.

## Post-MVP Idea

Arbitrary explicit bundle:

```kiln
import gameplay "player", "enemy", "combat"
```

Meaning:

```txt
merge exports from listed paths into namespace gameplay
```

Not core MVP.
