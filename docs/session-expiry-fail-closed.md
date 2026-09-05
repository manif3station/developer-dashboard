# Session expiry: absence must fail closed, same as garbage

`Developer::Dashboard::SessionStore` is the file-backed store behind helper
login cookies. Two of its code paths decide whether a stored session record is
still valid: `from_cookie` (does this cookie still authenticate?) and
`cleanup`/`sweep_expired` (should this file be reclaimed?). Both make that
decision from one field, `expires_at`, and both must treat every way that
field can be wrong the same way: as expired.

## The rule

> **A session record whose `expires_at` cannot be trusted is expired, whether
> the field is missing, empty, `"0"`, or malformed. There is no code path in
> which an untrustworthy expiry means "never expires."**

This is not a new idea introduced for this rule — it is the stance
`SessionStore::create` already takes for session-id generation, twelve lines
above where this defect lived: the module deliberately has no silent fallback
to weak material, because a silent fallback to something weak *is* the
vulnerability, not a workaround for it. Treating a missing expiry as eternal
is the same shape of mistake, applied to a different field.

## Why the "malformed" case already worked

`_iso8601_to_epoch($text)` returns `0` for anything that does not match a
strict `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z` pattern — including `undef`,
`''`, `'0'`, and free-form garbage. `0 <= time` is always true, so a
malformed timestamp already compared as long-expired and was deleted
correctly by both `from_cookie` and `sweep_expired`.

## Why absence did not

Both call sites had an extra guard placed *before* that comparison, intended
to skip records with no expiry rather than pass them into
`_iso8601_to_epoch`:

- `from_cookie`: `if ( $session->{expires_at} && _iso8601_to_epoch(...) <= time )` —
  a false/undef/empty/`'0'` `expires_at` short-circuits the `&&`, so the
  expiry branch never runs and the session is returned as valid.
- `sweep_expired`/`cleanup`: `next if !defined $expires_at || $expires_at eq '';` —
  the same record is skipped outright, so its file is never removed either.

The asymmetry is the defect: a record that is thoroughly broken (an
unparseable string) was rejected, while a record that is merely incomplete
(the field never written) was accepted forever and never swept. Removing both
guards lets every case — present-and-valid, present-and-expired,
present-and-garbage, and absent — fall through to the same
`_iso8601_to_epoch(...) <= time` comparison, which already handles the first
three correctly and, once the guard is gone, handles the fourth the same way.

## Reachability, stated honestly

`create()` always sets `expires_at`, and its write is atomic (temp file,
secured, then renamed — DD-600), so the product's own code does not currently
produce a session record missing the field. Reaching this path requires a
record from outside `create()`: a hand-edited file, a restored backup, or a
schema written before the field existed. `get()` performs no schema
validation and returns whatever `json_decode` produces, so such a record
would have been accepted silently. This was a latent fail-open on a security
control, not an exploitable path through the product's normal flow as it
stood — worth fixing because the fix is one guard removed per site and the
asset behind it is an authenticated session's bearer credential.

## What to check when touching this code again

Any future change to `from_cookie` or `sweep_expired`/`cleanup` that adds a
guard in front of the expiry comparison should ask: *does this guard change
behavior only for a value `_iso8601_to_epoch` already handles safely, or does
it introduce a new way to skip the comparison entirely?* The second is this
defect's shape. The regression tests for both files
(`t/67-sessionstore-coverage.t`, `t/51-hunt-sessionstore.t`) assert the
absent/empty/`'0'` cases are collected and rejected exactly like a malformed
timestamp, plus a positive control that a genuinely future expiry is left
alone — keep both sides green together, since a guard that always fails
closed (even for valid sessions) would pass the first half of that pair and
break login for everyone.
