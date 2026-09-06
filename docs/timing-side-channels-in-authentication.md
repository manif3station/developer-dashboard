# Timing side channels in authentication

An authentication endpoint leaks through two channels: what it *says* and how
long it *takes*. This project has fixed defects in both, and the second is the
one that keeps being missed, because the response looks correct while it is
happening.

## The rule

> **Every path out of a credential check must cost the same, including the
> paths that fail early.** A refusal that returns sooner than another refusal
> is an oracle, whatever the response body says.

## What the body already gets right

`verify_user` returns `undef` for a wrong password and for an unknown account
alike, and the web layer renders one message — `Invalid username or
password.` — for both. Read as text, the two are indistinguishable, which is
the property the message was written for.

## What the clock gave away

Until DD-783 the same function was shaped like this:

```perl
my $user = $self->get_user($username) or return;      # absent -> return NOW
my $expected = $self->_expected_password_hash( $user, $username, $password );
```

A **known** username reached `_expected_password_hash` and paid for a
210,000-iteration PBKDF2 derivation. An **unknown** one returned before any
derivation at all. Measured on this host, three runs each:

| input | elapsed |
|---|---|
| known username, wrong password | 0.6082 s |
| unknown username | 0.0000 s |

Six hundred milliseconds is not a subtle signal. Any unauthenticated client
could enumerate which helper accounts exist, and the service binds
`0.0.0.0` by default.

The fix is to make the absent path do the same work before refusing — a decoy
derivation whose result is discarded. After it, the same measurement reads
0.8991 s against 1.0047 s, a ratio of 1.12 where 1.00 is indistinguishable.

## Test it by mechanism, not by stopwatch

A wall-clock assertion in the suite is the wrong instrument: it is flaky under
load, and on a shared host it fails for reasons that have nothing to do with
the defect. Count the work instead —

```perl
my $real = \&Developer::Dashboard::Auth::_pbkdf2_hmac_sha256_hex;
local *Developer::Dashboard::Auth::_pbkdf2_hmac_sha256_hex = sub {
    $derivations++; return $real->(@_);
};
```

— and assert that an unknown username performs the *same number* of
derivations as a known one. That is the property which closes the oracle; the
elapsed time is a consequence of it. Keep the timing figure as recorded
evidence on the card, not as a test that can go red on a busy afternoon.

Assert the other direction too: a missing username or password must cost
**no** derivation, because neither discloses whether an account exists, and a
decoy that fires for them is pure waste on every malformed request.

## Fixing one channel does not make a function timing-safe

The sharpest lesson here is historical. This project had **already** fixed a
timing leak in this very function: DD-604/DD-614 replaced a naive hash
comparison with a constant-time one, closing a side channel measured in
*bytes compared*. The much coarser leak — a whole 210,000-iteration
derivation, present or absent — sat in the same function, unnoticed, until an
ASVS review looked at it from a different angle.

> A fix aimed at one channel in a function is evidence about that channel
> only. It is not a statement about the function.

When reviewing an authentication path, enumerate the ways out of it and price
each one, rather than checking whether the known side channel is closed.

## What remains open, deliberately

Two things this page should not let anyone believe are solved:

**Legacy records are still cheaper.** The decoy costs what a PBKDF2 record
costs. A surviving single-round SHA-256 record — the pre-stretching format
that stays verifiable so an upgrade never locks anyone out — is cheaper than
the decoy and therefore still distinguishable by timing. Enumeration is closed
against modern records and narrowed, not eliminated, against legacy ones.
Closing it means upgrading the last legacy records or making that path pay the
same cost.

**There is no anti-automation.** No lockout, no per-IP throttle, no
failed-attempt counter on the login route. The only brake is the derivation
cost itself, which cuts both ways: each attempt now costs the server ~0.7 s of
CPU whether the account exists or not, so unthrottled concurrent attempts are
also a cheap remote CPU-exhaustion vector. Adding a counter raises real design
questions — where the state lives across multiple workers, what happens on
restart, and whether a lockout becomes a denial of service against the
legitimate user — which is why it is a separate change and not a footnote to a
timing fix.
