Compile error should prevent all execution

If this happens:

print("a")
this is bad syntax @@@
print("b")

then correct behavior should be:

Error: scanner/parser error

and no print("a") output.

Even if direct codegen emitted bytecode for print("a") before encountering the error, run_source should not call run_vm if compilation failed.
