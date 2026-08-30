# Where a `# uncoverable` annotation actually has to live

Devel::Cover's own docs give the annotation vocabulary (`# uncoverable branch
true`, `# uncoverable condition left`, and so on) but not where, physically, the
comment has to sit relative to the code it excuses. Get the placement wrong and
Devel::Cover silently ignores the annotation - no error, no warning, the metric
just stays short - which reads exactly like "this line genuinely isn't excused
yet" and sends the next reader hunting for a coverage gap that was already
described correctly, just in the wrong spot.

It is system-scoped: a placement rule for any `# uncoverable` annotation in this
repository, not a record of one ticket's fix.

## What actually works, verified against Devel::Cover 1.52 with minimal repros

**A single-line statement:** a trailing comment on that exact line works.

```perl
return if !$enabled && !-t STDERR;    # uncoverable condition right
```

**A multi-line compound condition** (an `if`/`die ... if` spanning several
physical lines): the annotation has to be immediately above the *first* line of
the statement, with nothing - not even a blank line - between the annotation and
the code. A trailing comment on the specific physical line containing the
sub-expression it names does **not** work; Devel::Cover attributes the whole
compound condition to the line the statement starts on, not to whichever line a
given operand happens to sit on.

```perl
# uncoverable condition false
die "Unknown collector '$target'\n"
  if $scope eq 'collector' && defined $target
  && $target ne ''
  && !_collector_known( $collectors, $config, $target );
```

**A multi-line hash/list constructor:** same rule - annotate immediately above
the opening line (`my %h = (` or the `Package->new(` call), not above the
individual key/value line the branch lives on. Devel::Cover attributes every
branch inside the constructor to that opening line.

```perl
# uncoverable branch false
# uncoverable condition right
return if !$enabled && !-t STDERR;
return Developer::Dashboard::CLI::Progress->new(
    ...
);
```

**Two annotations for two different criteria on the same construct** (e.g. one
branch issue and one condition issue on the same `if`) stack as separate `#
uncoverable ...` lines, each still immediately above the statement, no blank
line between them:

```perl
# uncoverable branch false
# uncoverable condition right
return if !$enabled && !-t STDERR;
```

## The limitation that has no annotation workaround

Devel::Cover cannot resolve an uncoverable-branch annotation against **two
textually-identical branch shapes folded onto one reported line** - which
happens when a multi-line hash/list constructor contains the same ternary or
condition written out twice for two different keys:

```perl
my %h = (
    dynamic => ( -t STDERR ? 1 : 0 ),
    color   => ( -t STDERR ? 1 : 0 ),
);
```

Devel::Cover reports both `-t STDERR ? :` branches against the constructor's
opening line, and no combination of stacked `# uncoverable branch` annotations
above that line clears both - one clears, the other stays flagged, regardless of
how many identical annotation lines are stacked. This was verified directly:
1, 2, and 3 stacked `# uncoverable branch true` lines above the opening line
each cleared exactly one of the two branches and left the other marked.

**There is no annotation fix for this.** The actual fix is to stop having two
identical branch shapes in the first place - compute the value once and reuse
it:

```perl
my $interactive = -t STDERR ? 1 : 0;    # uncoverable branch true
my %h = (
    dynamic => $interactive,
    color   => $interactive,
);
```

This is very often also the better code regardless of the coverage tool: two
copies of the same conditional are two places that can drift out of sync, and
collapsing them removes both the coverage gap and the duplication that caused
it.

## Before annotating anything, ask whether the code can just be simplified

Two of the three uncoverable annotations described above were avoidable
entirely, not just work-aroundable. `$target ne ''` was a redundant re-check of
a condition an earlier `die` in the same function already guaranteed; deleting
it removed the coverage gap along with the dead logic. A caller-side
`defined $x && $x ne ''` guard around a function whose own contract already
promises a non-empty defined return is the same shape from the other direction.

**Prefer deleting the dead condition over annotating it as uncoverable, every
time the code allows it.** Reach for `# uncoverable` only for what is
genuinely a property of the *host or test environment* rather than the
project's own logic - the `-t STDERR` checks above are the legitimate case: no
CI runner or `prove` invocation ever attaches a controlling terminal to
STDERR, so that branch is unreachable no matter how the surrounding code is
written.
