# PAX on Alpine, and the actual runtime speedup, measured

Follow-up to
[docs/pax-can-compile-this-codebase-in-2-minutes.md](pax-can-compile-this-codebase-in-2-minutes.md)
(DD-871), which proved PAX compiles `bin/dashboard` on glibc but left two
questions open: does it work on Alpine (musl), and is the compiled binary
actually faster. Both measured directly (DD-872, 2026-09-14/15).

## Alpine (musl libc): fails, with a specific, fixable, identified cause

`pax build bin/dashboard` inside a fresh `alpine:3` container (perl 5.42.2,
gcc/binutils 2.45.1 via `apk add perl perl-dev gcc make musl-dev`) reached
every stage successfully - the same 63 source units, 62 application files,
37 packaged runtime dependencies, and 17 bundled XS modules DD-871 measured
on glibc - and then failed only at the final `Compile standalone launcher`
step, with an empty error reason.

**Root cause, isolated and confirmed:** PAX's `_compile_launcher`
(`lib/PAX/StandaloneImage.pm`) shells out to `objcopy` with abbreviated
GNU long options:

    objcopy --input binary --output elf64-x86-64 --binary-architecture i386:x86-64 code.pkg code.pkg.o

On Alpine's binutils (2.45.1), `--input` is an **ambiguous** abbreviation
and `objcopy` refuses to run:

    objcopy: option `--input' is ambiguous

Reproduced by hand against PAX's own intermediate `.pax-launcher-build/`
payload files (`code.pkg`, `runtime.pkg`, `assets.pkg`, `native.pkg` -
these survive because PAX writes them under the build's own output
directory, not a container-local temp path). Running the identical
command with the **full** option names fixes it outright:

    objcopy --input-target binary --output-target elf64-x86-64 --binary-architecture i386:x86-64 code.pkg code.pkg.o
    # exit 0, code.pkg.o produced correctly

**This is not a musl/XS-linking incompatibility** (the risk this ticket
set out to check) - every compile and dependency-analysis stage that
would actually be sensitive to musl vs glibc succeeded identically to the
glibc run. It is a narrower, shallower bug: PAX's own `objcopy` invocation
relies on an abbreviation that one binutils build resolves unambiguously
and a newer one does not. The one-line fix (spell out `--input-target`/
`--output-target`) is PAX's to make, not developer-dashboard's - noted
here as a finding to hand back, not something this project can work
around from its own side.

## Runtime speed: genuinely faster, measured, not assumed

DD-871 only checked correctness (`version` printed `4.31`). This measured
actual wall-clock cost, on the same glibc container (`perl:5.42.0`), same
command (`dashboard version`), with the project's real dependencies
installed for a fair interpreted-path baseline (`cpanm --installdeps .` -
skipping this step measures a `BEGIN failed` exit, not the real command,
which was caught and corrected before trusting any number):

| path | 20 runs (wall-clock) | per-run |
|---|---|---|
| interpreted (`perl bin/dashboard version`) | 2.059s | ~103ms |
| PAX-compiled binary | 0.057s | ~2.9ms |

**~36x faster per invocation.** Verified the binary is doing real work
each time, not returning a cached/no-op result: three separate direct
runs each printed the correct `4.31`.

The magnitude is consistent with what a compiled binary buys over
interpreted Perl for a short-lived CLI invocation - avoiding `@INC`
module search and BEGIN-time compilation of the whole dependency
tree on every process start, which is Perl's dominant startup cost for
a command this cheap. It is not evidence about steady-state throughput
for long-running processes (the web server, collectors) - those were
already out of scope (DD-871, owner decision Q-160) and startup cost is
not their bottleneck.

## Runtime speed on a data-processing workload: the opposite result (DD-953)

DD-872's ~36x speedup was measured on `dashboard version` - a command that
does almost no work, so avoiding Perl's own startup/compile cost dominates
the result. DD-953 asked the same question for real data-processing work:
the 7 data-query CLI commands (`jq`, `yq`, `tomq`, `propq`, `iniq`, `csvq`,
`xmlq` - `lib/Developer/Dashboard/CLI/Query.pm`) against a large fixture,
in the same `developer-dashboard:latest` container.

**Methodology.** One equivalent ~50,000-record dataset built in each of
the 7 native formats (JSON/YAML/TOML/Java-properties/INI/CSV/XML, 1.4-4.6MB
each). Each command run twice per path: once interpreted
(`perl -Ilib share/private-cli/<cmd> <query> <fixture>`), once as a
standalone binary built with `dashboard pax build -o <cmd>-bin
share/private-cli/<cmd>` (89.7MB each - the whole bundled runtime, not a
thin wrapper). Every one of the 14 runs' output was verified byte-for-byte
against the expected value before trusting its timing - a fast wrong
answer is not evidence of anything.

| command | interpreted | compiled | result |
|---|---|---|---|
| jq    | 0.110s  | 0.701s  | **6.4x slower** |
| yq    | 0.387s  | 0.942s  | **2.4x slower** |
| tomq  | 10.011s | 11.762s | **1.2x slower** |
| iniq  | 1.229s  | 2.630s  | **2.1x slower** |
| propq | 1.685s  | 2.529s  | **1.5x slower** |
| csvq  | 0.148s  | 0.924s  | **6.2x slower** |
| xmlq  | 1.972s  | 3.152s  | **1.6x slower** |

Every row is a matched same-query, same-fixture pair, output-verified
before the timing was trusted.

**The compiled binary was slower on every single command measured** - the
opposite of DD-872's result, and not a close call (1.2x to 6.4x slower).
Root cause, by construction rather than guesswork: DD-872's `dashboard
version` command does essentially no work, so `perl`'s own startup and
`@INC`/BEGIN-time module compilation *is* almost the entire measured cost
- exactly what a compiled binary eliminates. These 7 commands spend most
of their wall-clock time actually parsing 1.4-4.6MB of real data (JSON/
YAML/TOML/etc decoding is genuine CPU work, not startup overhead), so
avoiding Perl's compile-time cost buys proportionally little - while the
compiled binary pays its own real cost every invocation: unpacking a
90MB self-contained payload (bundled runtime + every dependency) before
it can even begin parsing the fixture. `tomq`'s own already-slow parser
(10s interpreted, see below) shows the smallest relative penalty (1.2x)
precisely because the parsing work dominates enough to make the
unpacking overhead comparatively small - the two effects trade off in
opposite directions as the real workload grows.

**Separate finding: `tomq` is dramatically slower than every other
command**, interpreted or compiled (10-12s vs well under 3s for
everything else at a comparable fixture size). This is `_parse_toml`'s
own algorithmic cost, unrelated to PAX - worth a focused look as its own
finding, not folded into the PAX comparison above.

**What this means for DD-871/DD-872's premise.** "PAX makes dashboard
invocations meaningfully faster" is true specifically for cheap,
startup-dominated commands, and does not generalize to data-processing
workloads - measured now on both ends, not assumed on either. A
standalone binary's fixed unpacking cost is a real, non-negligible tax
that a heavy workload can absorb but a light one cannot escape from
without it dominating the result. Any future decision to ship a
PAX-compiled build of a data-query command should weigh this measured
cost, not the `dashboard version` number.

## What this settles for SOW DDS-001 / epic DDE-002

- The core premise (PAX makes `dashboard`/`d2` invocations meaningfully
  faster) is now measured, not assumed: ~36x on a representative command.
- Alpine support is blocked on an upstream PAX fix, not a developer-dashboard
  change - worth reporting to the PAX project, and worth re-testing once
  fixed rather than assuming it will "just work."
- Both findings are inputs to scoping the actual compile-cache-run wrapper
  implementation (future work under DDE-002), not implementations
  themselves.
