# Case/match review follow-up

The September 9 review found six reproducible defects. Fix each with
regressions, preserve the documented semantics, and validate with focused
case/match and porting tests before a full harness run.

1. **Complete:** preserve escaped scalar and array bindings when the
   clause exits, including repeated executions. Four focused files pass
   (169 tests) in the current nonthreaded production build.
2. **Pending:** discover and bind every static regex's named captures,
   including regexes inside object shapes and open-array searches.
3. **Complete:** apply actual-boolean matching consistently to nested
   constants, including imported builtin booleans.
4. **Pending:** remove silent 64-element and 64-binding limits.
5. **Complete:** reject slurp minima outside `0 .. 2**32 - 1` without
   overflowing during decimal parsing.
6. **Pending:** reject statically known duplicate hash keys. Runtime key
   collisions must not raise duplicate-key errors or let an exact shape
   accept unspecified keys.

Keep fixes in incremental commits. Update user documentation and the main
TODO where appropriate. Build and regeneration commands run in the visible
tmux build window; do not change the user's build configuration.
