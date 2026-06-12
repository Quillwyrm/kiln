// Default Kiln CLI host. Embedding-facing entry points live in runtime.odin.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "kiln"

print_help :: proc() {
    fmt.println("kiln 0.0.0-pre-alpha")
    fmt.println("")
    fmt.println("Usage:")
    fmt.println("  kiln <file.kiln> [args...]")
    fmt.println("  kiln dis <file.kiln>")
    fmt.println("  kiln help")
    fmt.println("  kiln version")
    fmt.println("")
    fmt.println("The `.kiln` extension may be omitted.")
    fmt.println("")
    fmt.println("Options:")
    fmt.println("  -h, --help    Show help")
    fmt.println("  -v, --version Show version")

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

    if first_arg == "version" || first_arg == "--version" || first_arg == "-v" {
        fmt.println("kiln 0.0.0-pre-alpha")
        return
    }

    if first_arg == "dis" {
        if len(os.args) != 3 {
            fmt.eprintln("usage: kiln dis <file.kiln>")
            os.exit(1)
        }

        path_arg := os.args[2]

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
        kiln.set_argv(kstate, os.args, 3)

        kasm, err := kiln.disassemble_file(kstate, source_path)
        if err != "" {
            fmt.eprintln(err)
            os.exit(1)
        }

        fmt.print(kasm)
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

    _, err := kiln.run_file(kstate, source_path)
    if err != "" {
        fmt.eprintln(err)
        os.exit(1)
    }
}
