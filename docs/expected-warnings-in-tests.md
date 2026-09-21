# Warnings a test provokes on purpose, and where they end up

Warnings are errors on this project. A test that deliberately drives a failure
path will sometimes produce a warning the interpreter itself emits, which is
neither a defect nor something the test wanted to assert. This page describes
where those go wrong and how to contain them. It is about the system, not any
one ticket.

## The shape

A test forces a real failure — a full disk, a closed pipe, a permission denial
— because that is the branch under test. The code under test dies correctly and
the assertion passes. But **perl also warns**, on its own account, about
something it had to clean up while unwinding:

    Warning: unable to close filehandle $fh properly: No space left on device

Nothing failed. The test is green. The warning goes to stderr and stays there,
on every run, for ever.

## Why a leaked warning costs more here than elsewhere

**Warnings are errors is a rule this project actually enforces**, so a warning
that appears on every run is not a small untidiness — it is a permanent
exception to a rule everyone else obeys. Three consequences, in order of how
expensive they turn out to be:

- **It trains the reader to skim.** A stderr line that is always present stops
  being read. The next warning appears in a stream already established as
  noise.
- **It destroys stderr as a signal.** Any check that treats clean stderr as
  meaningful has nothing to work with, because stderr is never clean.
- **It looks deliberate.** A reader who finds one test tolerating the warning
  and another leaking it infers a decision was made. Usually none was.

## The rule

**Tolerate the exact artifact, at exactly the point that provokes it, and
rethrow everything else.**

    {
        local $SIG{__WARN__} = sub {
            my ($w) = @_;
            return if defined $w && $w =~ /unable to close filehandle.*No space left on device/;
            die $w;
        };
        $err = eval { $thing->that_fails(...); 1 } ? '' : $@;
    }

Three properties, each load-bearing:

- **Scoped to the block**, not the file. A file-wide handler silences warnings
  from code that was never meant to produce any.
- **Matched narrowly.** The pattern names *both* the artifact and its cause. A
  filter on `/unable to close filehandle/i` alone would also absorb a close
  failure from `EIO` or `EBADF` at the same site — a different bug wearing the
  same words.
- **Rethrows the rest.** Anything unmatched becomes fatal, so the block stays as
  strict as the rest of the suite.

### A second correct shape, and when it applies

Collect-and-assert is equally rigorous and reads better when the test wants to
*say something* about the warnings:

    my @warnings;
    { local $SIG{__WARN__} = sub { push @warnings, $_[0] }; ... }
    is( scalar( grep { $_ !~ /unable to close filehandle/i } @warnings ), 0, '...' );

Here a looser pattern is safe, because the structure fails on anything
unexpected regardless. **The two shapes are not interchangeable part by part:**
lifting the loose pattern into the tolerate-and-die form gives you the weakest
of both — a handler that dies on surprises but waves through a whole family of
real failures.

## The trap when verifying the fix

Failure-path tests are usually guarded, because they need something the host may
not have — `/dev/full`, a device, a privilege. So:

> **Confirm the guarded block actually ran.** On a host where it skips, stderr is
> clean whether or not anything was fixed, and the fix is indistinguishable from
> no fix.

Assert a positive marker that only appears when the block executes — its own
test description in the output — in **both** the before and after runs. A before
and after that differ only in a number nobody checked the provenance of is not a
measurement.

## Reviewing a change against this

- Does the handler name the cause, or only the symptom?
- Is it scoped to the provoking block, or draped over the file?
- Does anything unmatched still fail?
- Did the verification prove the guarded block ran, on both sides?
- If a sibling test handles the same warning, does this one match its shape —
  and if it deliberately differs, does a comment say why?

## A different shape: overriding an IMPORTED sub carries its importer's prototype

The warnings above are provoked by a failure path. This one is provoked by the
**mock itself** — installing a test double over a sub that was never declared
in this project's own code, and whose prototype the mock author cannot see by
reading this repository.

### The mechanism

A module that does `use Time::HiRes qw(sleep time);` does not declare its own
`sleep`. The imported name is an **alias** for `Time::HiRes::sleep`, and it
carries whatever prototype `Time::HiRes::sleep` has on the Perl that loaded
it. That prototype is not fixed across Perl/Time::HiRes versions — it has been
observed as both `(;$)` and `(;@)` on Perls this project has actually run on.

A test that overrides such a sub **permanently, at file scope**, with a
non-local typeglob assignment —

    *Some::Package::sleep = sub { ... };

— has Perl check the assignment against the slot's *existing* contents for
two independent things, both separately warnable and both fatal under this
project's `use warnings FATAL => 'all'`:

- **`redefine`** — is a named sub being replaced at all?
- **`prototype`** — does the new sub's prototype (including the case of
  having none) match the old one's?

**Silencing `redefine` alone does not touch `prototype`.** And giving the
override sub no prototype of its own does not make it safe either — Perl
still compares "no prototype" against whatever the existing sub's prototype
is, and reports a mismatch (`... vs none`) exactly as it would for two
different explicit prototypes. The only combination immune to the version the
imported sub's prototype happens to carry is silencing **both** categories
together:

    no warnings qw(redefine prototype);
    *Some::Package::sleep = sub { ... };

### Why this is invisible on some machines and fatal on others

The prototype comparison is between two concrete values, so whether it fires
at all depends on whether the machine's imported sub's prototype happens to
equal the override's. A developer whose local interpreter's imported sub
already matches the override never sees anything — the check passes
trivially. A CI runner (or any other machine) whose interpreter's import
carries a different prototype hits the mismatch every time. **Neither
observation proves anything about the other machine** — a clean local run is
not evidence the override is safe, only evidence that this one machine's
import happens to agree with it.

### The narrower, always-safe alternative

A **`local`** typeglob assignment —

    local *Some::Package::sleep = sub { ... };

— triggers neither warning category, on any Perl, because `local`izing a glob
temporarily clears the slot before the new value is installed: there is
nothing present for the new assignment to be checked against. This is safe by
construction and needs no `no warnings` at all — but it is dynamically
scoped, so it reverts the moment the enclosing block exits. It is the right
tool for a mock that only needs to be active inside one test block; it is the
*wrong* tool for a mock that must survive for an entire test file's duration,
because a `local` inside a file-scope `BEGIN` block reverts as soon as that
`BEGIN` block finishes running.

### Applying this

Before overriding any sub this project did not itself declare (an import from
a core module, a role, an inherited method):

1. Is the override scoped to one block, or does it need to live for the whole
   file? A block-scoped override should use `local *glob = sub {...}` and
   needs no extra `no warnings` line at all.
2. A file-scope override needs a permanent (non-`local`) glob assignment, and
   therefore needs `no warnings qw(redefine prototype);` together — never
   `redefine` alone — regardless of whether the override sub itself carries an
   explicit prototype.
3. Never conclude an override is safe from a single machine's clean run. The
   prototype the override collides with belongs to whatever provided the
   original sub, not to this project's code, and it can differ by
   interpreter/module version between any two machines running the same
   checkout.
