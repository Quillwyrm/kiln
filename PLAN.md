We were trying to do a **parser-shape sprint**, not really a feature sprint.

The intended shift was:

```txt
old-ish shape:
    parse statement by special cases
    identifier-led assignment/declaration
    expression parser handles call suffix in a cramped way
    assignment targets are mostly names

target shape:
    define a clean expression spine
    make postfix/index/call composition explicit
    make assignment targets descriptor-based
    keep declaration targets name-based
```

The core expression shift was:

```txt
primary -> postfix -> prefix -> expr
```

Meaning:

```txt
primary:
    literals
    identifiers
    function literals
    array literals
    parenthesized expressions

postfix:
    call suffix (...)
    index suffix [...]
    repeated chains like calls[0](), items[0][1], make()()

prefix:
    not expr
    later unary minus

expr:
    currently prefix
    later precedence parser
```

The concrete additions were supposed to be:

```txt
parse_expr_postfix
parse_expr_call_suffix
parse_expr_index_suffix
parse_expr_array_literal
ExprIndex
indexed reads/writes
array literals
parenthesized expressions
```

Statement parsing was the risky part. The clean intended rule became:

```txt
declaration:
    IDENT { "," IDENT } ":=" expr_list
    declaration LHS is names only

assignment/call statement:
    starts from allowed statement-start forms
    parses an expression
    if followed by = or , -> assignment
    otherwise expression must be ExprCall
```

The important correction we found late:

```txt
Expression-start tokens are not automatically statement-start tokens.
```

So `(expr)` and `[expr]` can be valid inside expressions without `LEFT_PAREN` / `LEFT_BRACKET` being valid statement starts.

The sprint also wanted assignment targets to become descriptor-based:

```txt
valid assignment targets:
    ExprLocal
    ExprIndex

invalid declaration target:
    items[0] := value

valid assignment:
    items[0] = value
    a, items[0] = 1, 2
```

The thing that derailed us was accidentally broadening statement starts too far, then trying to patch the consequences with newline/line-sensitive suffix rules. That was wrong for Kiln because Kiln is meant to be grammar-defined and whitespace/newline-insensitive.

So the reset for today is:

```txt
1. Write the grammar contract first.
2. Separate expression grammar from statement grammar.
3. Decide exact valid statement starts.
4. Then re-implement the sprint from that grammar.
```
