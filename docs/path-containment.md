# Path containment

How the Developer Dashboard keeps an untrusted path segment inside the directory
it is supposed to stay in. This page describes the system, not any one ticket.

## The problem this solves

Several parts of the product build a filesystem path by joining a trusted root to
a segment that came from outside: a CLI argument, an archive member name, a skill
name, a saved-page name, a remote search result. `File::Spec->catfile` and
`File::Spec->catdir` are **concatenation primitives with no security contract** —
they neither canonicalise a path nor reject a `..` segment. Joining a root to
`../../../etc/thing` produces exactly that path, and the caller then opens,
creates or unlinks it.

The consequence is not abstract. Depending on which sink the path reaches:

| sink | what an escape gives an attacker |
|---|---|
| `open '>'` / `make_path` | arbitrary directory creation and file write |
| `unlink` | arbitrary deletion of any file matching the fixed leaf name |
| `open '<'` | disclosure of any readable file |

The deletion sink is the one most often underestimated, because the code reads as
"remove our own marker" and in fact removes anybody's.

## The rule

**Every path built from an untrusted segment is resolved through a containment
helper that returns nothing when the result escapes its root, and every caller
treats "nothing" as a refusal rather than a fallback.**

Two halves, and both are load-bearing. A helper that contains correctly but whose
caller falls back to the unchecked path on `undef` protects nothing.

## How containment is implemented here

Resolution is **lexical**: the segments are split, `.` is dropped, each `..` pops
the accumulated stack, and a `..` with nothing left to pop is a refusal. The
filesystem is never consulted.

```perl
for my $part ( grep { $_ !~ m{\A\.?\z} } map { split m{[\\/]+}, $_ } @segments ) {
    if ( $part eq '..' ) {
        return if !@resolved;   # escaped the root - refuse
        pop @resolved;
        next;
    }
    push @resolved, $part;
}
return if !@resolved;
return File::Spec->catfile( $root, @resolved );
```

### Why lexical rather than `realpath`

The SEI CERT Perl rule *IDS00-PL, Canonicalize path names before validating them*
recommends canonicalising with `Cwd` and then checking the result sits under the
allowed root. That is sound advice and it catches one case this approach does
not — a parent directory that is a **symlink** pointing outside the root, which
is lexically innocent.

It also reopens a window this approach closes. `realpath` asks the filesystem a
question whose answer can change before the write that follows it: the classic
time-of-check-to-time-of-use race. A lexical decision cannot change between the
check and the use, because it never depended on the filesystem in the first
place.

The product chooses lexical containment, and treats the symlinked-parent case as
a known, separately-tracked limitation rather than an unstated one. Where a
directory tree is attacker-controlled enough for that to matter, the containment
helper is not the only control that should be present.

## Where it applies

Every place a segment from outside the process is joined to a root. The known
sites, each of which was a defect before it was a rule:

- **Saved pages** — a page name from a web request joined to the `dashboards/`
  root.
- **Skill install** — a skill or repository name joined to the layer's
  `skills/` root.
- **Archive extraction** — an archive member name joined to a cache root; the
  Zip Slip class, where the malicious name lives inside the archive rather than
  in the request.
- **Docker service toggles** — a service name from `dashboard docker
  disable|enable` joined to the layer's `config/docker` root.

The list is a description of what has been found, not a boundary. **The test for
a new call site is not whether it appears above; it is whether any segment in the
path came from outside the process.**

## Reviewing a change against this rule

1. Does this code join a root to a segment it did not itself construct?
2. Is that segment reachable from a CLI argument, an HTTP request, an archive, a
   config file, or a network response?
3. Does the join go through a containment helper?
4. Does the caller **refuse** on `undef`, or does it fall through to an
   unchecked path?
5. Is there a test that a `..` segment is rejected — asserting the refusal, and
   asserting the file outside the root was not created, written or removed?

Point 5 matters more than it looks. A test that only asserts an exception was
thrown does not notice a fix that raises the exception *after* doing the damage.
Assert the state of the filesystem outside the root, not only the return value.
