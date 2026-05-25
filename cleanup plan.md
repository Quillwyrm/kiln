I’d do it in this order:

1. **Hard AGENTS.md audit**
   - helper slop
   - defensive guards that hide bugs
   - stale comments
   - weird names
   - accidental lifecycle behavior
   - dead/unused emitter/parser/scanner surfaces

2. **Parser cleanup**
   - comments that explain actual parser policy
   - result-count call policy documented
   - slot/temp policy documented
   - maybe rename vague procs if any read wrong

3. **Emitter cleanup**
   - ordering, section comments, naming consistency
   - check if any old `gen` comments remain
   - check `begin_proto/end_proto/build_vm_state` still honestly named

4. **VM cleanup**
   - stale `call_frames` vs `frame_stack` comments
   - function/proto naming drift
   - native call result contract comments
   - panic messages that still mention old names

5. **Native builtin cleanup**
   - decide if native procs should respect `requested_results`
   - `assert` should maybe panic with unquoted plain message later, but raw Odin panic is fine for now
   - comments around ABI should be explicit

6. **Then basic error system**
   - scanner/parser errors first
   - runtime source locations later
