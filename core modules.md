math

array

map

string
    format(format, ...values) -> string
        returns formatted text

    contains(text, part) -> bool
        true if text contains part

    has_prefix(text, prefix) -> bool
        true if text starts with prefix

    has_suffix(text, suffix) -> bool
        true if text ends with suffix

    split(text, separator) -> array
        splits text into string pieces

    slice(text, start, count) -> string
        returns substring by byte index/count, given current string model

    replace(text, old, new) -> string
        replaces occurrences of old with new

    trim(text) -> string
        removes leading/trailing whitespace

    to_lower(text) -> string
        returns lowercase text

    to_upper(text) -> string
        returns uppercase text

    get_byte(text, index) -> int 
        returns byte value at index

    to_bytes(text) -> array 
        returns array of byte ints


system
    args() -> array
        returns user script arguments, excluding executable/script path

    argv() -> array
        returns raw invocation argument vector

    get_env(name) -> string | nil
        returns environment variable value, or nil if unset

    set_env(name, value)
        sets environment variable for current process

    exit(code)
        exits kiln.exe with integer process status code

    get_os() -> string
        returns host OS name, e.g. "windows", "linux", "macos"

    get_arch() -> string
        returns host architecture name, e.g. "x64", "arm64"


filesystem
    read_file(path) -> string
        reads an entire text file

    write_file(path, text)
        writes text to a file, replacing existing contents

    get_cwd() -> string
        returns current working directory

    set_cwd(path)
        changes current working directory

    exists(path) -> bool
        returns true if a filesystem path exists

    is_file(path) -> bool
        returns true if path exists and is a regular file

    is_dir(path) -> bool
        returns true if path exists and is a directory

    list_dir(path) -> array
        returns direct entry names inside a directory

    make_dir(path)
        creates a directory


path
    join(...) -> string
        joins path parts using host path rules

    base_name(path) -> string
        returns final path component

    dir_name(path) -> string
        returns parent path component

    extension(path) -> string
        returns file extension, probably including dot

    stem(path) -> string
        returns base file name without extension

    normalize(path) -> string
        lexically cleans path text without checking filesystem


io
    read_all() -> string
        reads all remaining stdin until EOF

    read_line() -> string | nil
        reads one stdin line, or nil on EOF

    write(text)
        writes exact text to stdout, no newline

    print(text)
        writes text to stdout, then newline

    write_error(text)
        writes exact text to stderr, no newline

    print_error(text)
        writes text to stderr, then newline
