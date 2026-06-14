package kiln

import "core:os"
import "core:strings"
import "core:path/filepath"


// Error state ====================================================================================

// Kiln reports one compile or runtime error per host operation.
// The error string is already the final printable diagnostic.

source_line_col_at :: proc(source: string, offset: int) -> (line: int, column: int) {
    line = 1
    column = 1

    for index := 0; index < offset; index += 1 {
        if source[index] == '\n' {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    return
}

error_source_name :: proc(source_name: string) -> string {
    fallback, fallback_error := filepath.replace_path_separators(source_name, '/', context.temp_allocator)
    if fallback_error != nil {
        fallback = source_name
    }

    cwd, cwd_error := os.get_working_directory(context.temp_allocator)
    if cwd_error != nil {
        return fallback
    }

    relative_path, relative_error := filepath.rel(cwd, source_name, context.temp_allocator)
    if relative_error != .None {
        return fallback
    }

    if relative_path == ".." || strings.has_prefix(relative_path, "../") || strings.has_prefix(relative_path, "..\\") {
        return fallback
    }

    display_path, display_error := filepath.replace_path_separators(relative_path, '/', context.temp_allocator)
    if display_error != nil {
        return relative_path
    }

    return display_path
}

set_error :: proc(text: string) -> string {
    if text == "" {
        panic("set_error called with empty error string")
    }

    Active_State.error_string = text
    return Active_State.error_string
}
