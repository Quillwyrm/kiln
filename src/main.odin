// Default Kiln CLI host. Embedding-facing entry points live in runtime.odin.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "kiln"

print_help :: proc() {
    fmt.println("kiln")
    fmt.println("")
    fmt.println("Usage:")
    fmt.println("  kiln <file.kiln> [args...]")
    fmt.println("")
    fmt.println("Examples:")
    fmt.println("  kiln tool.kiln")
    fmt.println("  kiln copy-file.kiln input.txt out")
    fmt.println("")
    fmt.println("The .kiln extension may be omitted.")
}

print_kiln_error :: proc(err: ^kiln.Error) {
    name    := err.location.source_name
    line    := err.location.line
    col     := err.location.column
    run_ctx := err.runtime_context
    msg     := err.message

    if run_ctx != "" {
        fmt.eprintfln("%s[%d:%d] Error %s: %s", name, line, col, run_ctx, msg)
    } else {
        fmt.eprintfln("%s[%d:%d] Error: %s", name, line, col, msg)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        print_help()
        return
    }

    first_arg := os.args[1]

    if first_arg == "help" || first_arg == "--help" || first_arg == "-h" {
        print_help()
        return
    }

    path_arg := first_arg
    script_args_start := 2

    source_path := path_arg
    tried_ext_path := ""

    if !os.exists(source_path) && !strings.has_suffix(path_arg, ".kiln") {
        tried_ext_path = fmt.tprintf("%s.kiln", path_arg)
        source_path = tried_ext_path
    }

    if !os.exists(source_path) {
        if tried_ext_path != "" {
            fmt.eprintfln("source file not found: tried `%s` or `%s`", path_arg, tried_ext_path)
        } else {
            fmt.eprintfln("source file not found: `%s`", path_arg)
        }
        os.exit(1)
    }

    kstate := kiln.new_state()
    defer kiln.delete_state(kstate)

    kiln.bind_core_env(kstate)
    kiln.bind_core_modules(kstate)
    kiln.set_argv(kstate, os.args, script_args_start)

    // The CLI host ignores the script return value; embedding hosts can use it.
    result, err := kiln.run_file(kstate, source_path)
    if err != nil {
        print_kiln_error(err)
        os.exit(1)
    }
}
