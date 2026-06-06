math

array.
    pack(...values) -> array
        captures values into an array, preserving nils

    unpack(array) -> multiple values
        expands array elements into multiple results

    push(array, value) *DONE*
        appends value to the end of array

    pop(array) -> value *DONE*
        removes and returns the final element

    insert(array, index, value) *DONE*
        inserts value at index, shifting existing elements right

    remove(array, index) -> value *DONE*
        removes and returns element at index, shifting later elements left

    clear(array) *DONE*
        removes all elements

    copy(array) -> array *DONE*
        returns a shallow copy

    slice(array, start, count) -> array *DONE*
        returns a shallow copied sub-array


maps.
    clear(map) *DONE*
        removes all entries

    copy(map) -> map *DONE*
        returns a shallow copy

    get_keys(map) -> array *DONE*
        returns an array of keys

    get_values(map) -> array *DONE*
        returns an array of values
        

string.
    format(format, ...values) -> string
        returns formatted text

    contains(text, part) -> bool *DONE*
        true if text contains part

    has_prefix(text, prefix) -> bool *DONE*
        true if text starts with prefix

    has_suffix(text, suffix) -> bool *DONE*
        true if text ends with suffix

    split(text, separator) -> array *DONE*
        splits text into string pieces

    slice(text, start, count) -> string *DONE*
        returns substring by byte index/count, given current string model

    replace(text, old, new) -> string *DONE*
        replaces occurrences of old with new

    trim(text) -> string *DONE*
        removes leading/trailing whitespace

    to_lower(text) -> string *DONE*
        returns lowercase text

    to_upper(text) -> string *DONE*
        returns uppercase text

    get_byte(text, index) -> int *DONE*
        returns byte value at index

    to_bytes(text) -> array *DONE*
        returns array of byte ints


system.
    args() -> array *DONE*
        returns user script arguments, excluding executable/script path

    argv() -> array *DONE*
        returns raw invocation argument vector

    get_env(name) -> string | nil
        returns environment variable value, or nil if unset

    set_env(name, value)
        sets environment variable for current process

    exit(code) *DONE*
        exits kiln.exe with integer process status code

    get_os() -> string
        returns host OS name, e.g. "windows", "linux", "macos"

    get_arch() -> string
        returns host architecture name, e.g. "x64", "arm64"


filesystem.
    read_file(path) -> string | nil, err *DONE*
        reads an entire text file, or returns nil and error string on failure

    write_file(path, text) -> err | nil *DONE*
        writes text to a file, replacing existing contents, or returns error string on failure

    get_cwd() -> string | nil, err *DONE*
        returns current working directory, or nil and error string on failure

    set_cwd(path) -> err | nil *DONE*
        changes current working directory, or returns error string on failure

    exists(path) -> bool *DONE*
        returns true if a filesystem path exists

    is_file(path) -> bool *DONE*
        returns true if path exists and is a regular file

    is_dir(path) -> bool *DONE*
        returns true if path exists and is a directory

    list_dir(path) -> array | nil, err *DONE*
        returns direct entry names inside a directory, or nil and error string on failure

    make_dir(path) -> err | nil *DONE*
        creates one directory level, or returns error string on failure


path.
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


io.
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


ides:
socket - raw socket/port/https
