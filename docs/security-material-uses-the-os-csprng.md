# Security-sensitive random material comes from the OS CSPRNG, never `rand()`

Any value whose job is to resist guessing by an attacker - a session id, a
password-hash salt, a bearer token, anything used as unpredictable material
in an authentication or authorization decision - is generated via
`Crypt::URandom::urandom()`, never via Perl's built-in `rand()` or a
construction that hashes `rand()` together with other, attacker-observable
values.

## Why `rand()` is unsafe for this

Perl's `rand()` uses the C library's `drand48` (or equivalent), seeded with
roughly 32 bits of entropy. That is a small enough space to become
tractable for an attacker willing to precompute against it, and it is not
what a cryptographic random-number generator is - drand48 is designed for
statistical simulation, not for resisting a targeted adversary.

**A hash of "hard to guess" values is not the same as a hash of "impossible
to guess" values.** A construction like

    sha256_hex( join ':', $$, time, rand(), $username )

looks like it draws from several sources, but only `rand()` contributes
real uncertainty: the process id is small and, inside this project's own
container deployment, is **always 1** (PID 1, zero entropy); the wall-clock
second is often inferable from logs or file mtimes; the username is known
to anyone targeting that specific account. The total entropy of the whole
construction is bounded by `rand()`'s ~32 bits, not by the number of terms
being hashed together.

## The fix: `Crypt::URandom::urandom(N)`

    use Crypt::URandom qw(urandom);
    my $material = unpack 'H*', urandom(32);   # 256 bits, hex-encoded

`Crypt::URandom` is imported **at compile time, with no fallback** -
`Developer::Dashboard::SessionStore` established this pattern first
(DD-452/453, fixing CPANSA-Dancer2-2026-13577's underlying weakness for
this project's own session ids) and its own comment states the reasoning
directly: *"there is deliberately no fallback, because a SILENT fallback to
weak material is the vulnerability itself, not the remedy for it."* A
`try`/`fallback-to-rand()` construction would reintroduce exactly the
weakness being fixed, silently, whenever the CSPRNG module happened to be
unavailable - worse than an honest compile-time failure, because it fails
open rather than closed.

## Fixing one instance does not fix the pattern (DD-900)

`SessionStore.pm::create`'s session-id generation was the first instance
found and fixed. `Auth.pm::add_user`'s **password-hash salt** used the
identical weak construction and was not touched by that fix - the two live
in the same file family and the same security domain (authentication), and
the sibling instance went unnoticed for a full development cycle because
the original fix was scoped to "session ids" rather than to "every
security-sensitive random value in this codebase." A predictable salt does
not break PBKDF2's per-attempt stretching directly, but it defeats the
actual purpose of salting - preventing precomputed/targeted attacks and
cross-account rainbow-table reuse - since an attacker who can narrow the
salt space to ~32 bits can precompute against that whole space once.

**When you fix one instance of this pattern, grep the rest of the codebase
for the same shape** (`rand()` feeding into a hash alongside `$$`/`time`/
any other attacker-observable value) rather than assuming the fix is
complete once the reported instance is closed.

## Related

- `lib/Developer/Dashboard/SessionStore.pm` - the first instance (DD-452/453).
- `lib/Developer/Dashboard/Auth.pm` - the second instance (DD-900), the
  password-hash salt in `add_user`.
