# PAX's native-shape JIT: a real, guarded, compile-to-machine-code path

## What this is

PAX (`Developer::Dashboard::Pax::*`) has two distinct compilation
strategies living side by side:

1. **The ~700 hand-matched-shape closure dispatch** in
   `CodeUnitCompiler.pm`/`StandaloneRuntime.pm` - regex-matches raw
   source text against known exact shapes and installs a hand-written
   Perl closure, or falls back to `eval`-ing the original source. This
   delivers a real startup-time win (skipping `@INC` search and
   BEGIN-time compilation) but both the "compiled" and "fallback" paths
   run as real Perl closures inside the real Perl interpreter - it
   cannot deliver a runtime execution speedup, and measured benchmarks
   confirm CPU-bound work runs 1.2x-6.4x SLOWER this way than plain
   interpreted Perl (see `docs/pax-alpine-and-runtime-speed-measured.md`).

2. **The native-shape guarded JIT** - `RegionSelector.pm` selects
   candidate subs from real `B::` op-tree data (via `Capture.pm`'s
   live-capture probe), `HIR.pm` lowers them to a guarded intermediate
   representation, `GuardedSSA.pm` builds SSA form with runtime type
   guards, and `Tier1.pm` emits **real C source**, invokes a **real
   `cc`/`gcc`**, and produces a **genuinely compiled native executable** -
   not packaged source, not a bundled interpreter. This is the only path
   in PAX capable of delivering an actual runtime speedup, because it is
   the only path that runs as real machine code rather than as Perl
   closures.

This page documents strategy 2 - the native-shape JIT.

## Architecture, in order

```
Capture.pm (live-capture probe, real B:: op-tree walk)
  -> detects a sub's body matches a known "native shape" (e.g. i64_binary_leaf)
  -> tags sub_optrees[].native_shape = { kind, op, args, smoke_left, smoke_right, smoke_expected }

RegionSelector.pm
  -> selects subs to consider (application code, or anything already carrying
     a native_shape) as candidate "regions"

HIR.pm
  -> lowers each selected region to a guarded IR graph with deopt_anchors

GuardedSSA.pm
  -> builds SSA form + runtime type guards from the HIR, via
     TypeAnnotationExtractor.pm / TypedIR.pm

Tier1.pm
  -> for each SSA unit whose native_shape.kind/op is recognized, emits real
     C source (_c_translation_unit / _c_binary_expr / _c_loop_body / etc.),
     invokes a real system() call to cc/gcc, and produces a genuine native
     executable with a real smoke-test comparing its actual output to the
     shape's expected value.
```

`GuardManager.pm`/`DeoptEngine.pm` handle the runtime side: if a guard's
assumption is violated at execution time, the mechanism deoptimizes back
to the real Perl interpreter rather than producing a wrong answer -
matching the LuaJIT/PyPy design pattern for speculatively compiling a
dynamic language's hot paths.

## The native-shape catalogue (op support)

The `i64_binary_leaf` shape recognizes a two-argument leaf sub of the
exact form:

```perl
sub name {
    my ($a, $b) = @_;
    return $a <op> $b;
}
```

Recognized ops, as of this page's writing:

| op string       | Perl operator | C emitted                  | notes |
|-----------------|---------------|-----------------------------|-------|
| `add`           | `+`           | `return left + right;`      | |
| `subtract`      | `-`           | `return left - right;`      | |
| `multiply`      | `*`           | `return left * right;`      | |
| `greater_than`  | `>`           | `return left > right ? 1 : 0;` | |
| `bitwise_and`   | `&`           | `return left & right;`      | added DD-1032 |
| `bitwise_or`    | `\|`          | `return left \| right;`     | added DD-1032 |
| `bitwise_xor`   | `^`           | `return left ^ right;`      | added DD-1032 |

**Divide (`/`) and modulo (`%`) are deliberately NOT supported**, and
this is a correctness decision, not an oversight: Perl's `/` always
returns a float (never matches C's truncating `int64_t` division), and
Perl's `%` follows the sign of the RIGHT operand while C's follows the
LEFT operand's sign. Both would be genuine, silent wrong-answer bugs for
negative or non-evenly-dividing operands if compiled to C as-is. Bitwise
ops were chosen instead because they are bit-for-bit identical between
Perl and C across the full `int64_t` domain, with zero edge cases.

Two other native shapes exist alongside `i64_binary_leaf`:
`i64_sum_loop` (a simple `for` accumulate-to-n loop) and
`i64_masked_mix_accum_loop` (a heavier masked-mix-accumulate benchmark
kernel). Both follow the same detect -> HIR -> SSA -> Tier1 pipeline.

## Where the op catalogue is defined (three places, must stay in sync)

The `i64_binary_leaf` op table is defined independently in three places,
because two separate detectors exist for historical reasons (a live
heredoc-based probe and an older static-source-scan sub), plus the C
codegen:

1. `Capture.pm::_lower_i64_binary_leaf` - inside the heredoc probe script
   fed via stdin to a spawned `perl -` child (the real live-capture
   mechanism). This is the detector that actually runs during a real
   `Capture->new(mode=>'live')->capture($entrypoint)` call.
2. `CodeUnitCompiler.pm::_native_i64_binary_leaf_shape` - a real,
   directly-callable, non-heredoc sub used by a separate, older
   `native_shape_sub` dispatch path.
3. `Tier1.pm::_c_binary_expr` - the C codegen that turns a recognized op
   string into the actual C source line.

Widening the op catalogue requires updating all three, or the three
mechanisms will silently disagree about what is supported.

## Current scope: proven, not yet wired into the real build

This mechanism is currently only reachable through `dashboard pax`
diagnostic/inspect CLI subcommands (`CLI.pm`, `StandaloneAnalysis.pm`,
`RuntimeDispatcher.pm`, `Benchmark.pm`) - it is **not** yet connected to
the real build path (`StandaloneImage.pm`/`CodeUnitCompiler.pm`'s own
dispatch, which still only uses the ~700 hand-matched-shape closures).
Wiring it into the real build path is a separate, larger piece of work
tracked under the DDE-007 architecture plan.

## Verification

`t/220-native-shape-bitwise-ops.t` is the canonical test for this
mechanism: it proves detection at both the live-capture and
`CodeUnitCompiler` levels, then runs the full pipeline end-to-end
(`RegionSelector` -> `HIR` -> `GuardedSSA` -> `Tier1`) to produce a real,
`cc`-compiled native executable and confirms running it produces the
mathematically correct answer - not just that a shape was detected.

## Real-world dispatch is process-spawn-per-call, not in-process (DD-1031)

`NativeRunner.pm::run_i64_binary` and `StandaloneDispatch.pm::_run_perl_region`
(the interpreted fallback) BOTH invoke their target via `IPC::Open3::open3` -
a full process spawn for every single call, on both the native and the
interpreted-fallback side. There is no in-process FFI/`.so`-loading calling
convention anywhere in this pipeline today.

A real, measured proxy benchmark (200 runs each, same host): a compiled
`add`-leaf artifact runs in ~0.69ms/call; `perl -Ilib
-MDeveloper::Dashboard::Pax::StandaloneRuntime -e 'exit(...)'` (approximating
what `_run_perl_region`'s spawned script actually pays - a full `require` of
the 15,101-line `StandaloneRuntime.pm` on every call) takes ~226ms/call -
**~328x slower**. This is a genuine, large, measured speedup, consistent with
(and exceeding) `docs/pax-alpine-and-runtime-speed-measured.md`'s ~36x
`dashboard version` finding.

**The important caveat:** this number reflects avoiding a heavy per-call
module-load cost, not avoiding per-iteration interpretation the way an
in-process JIT (LuaJIT/PyPy-style) would for a genuine hot loop. Because
both paths pay a full fork/exec today, a sustained tight loop invoking this
mechanism millions of times would still pay a process-spawn per call under
the current architecture - a materially different (and worse) profile than
a real in-process native function call. Eliminating the spawn entirely (a
real XS/FFI in-process calling boundary) is a distinct, likely
higher-value target for later stages than simply widening the op catalogue
further under the current spawn-per-call design.
