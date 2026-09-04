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
