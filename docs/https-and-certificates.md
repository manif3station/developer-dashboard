# HTTPS and certificates — what the dashboard issues, reuses, and refuses

This page describes the TLS model as it stands: where the certificate comes from,
when it is regenerated, what it covers, and what enabling SSL changes about who is
treated as an administrator.

It is system-scoped. It describes the behaviour, not any ticket that changed it.

## The certificate is self-signed, per-user, and regenerated on demand

`Web::Server::generate_self_signed_cert` writes `server.crt` and `server.key` into
the home runtime layer's `certs/` directory, located through
`_ssl_certificate_directory` → `PathRegistry`. The home directory is resolved from
`HOME`, then `USERPROFILE`, then `HOMEDRIVE`+`HOMEPATH`, so HTTPS also starts on a
Windows session, which exports no `HOME`.

There is no CA, no enrolment, and nothing to install. The certificate is generated
the first time it is needed and reused after that — but only while it still
satisfies the expected profile.

## Reuse is conditional, and the condition includes expiry

An existing certificate is reused **only** if `_ssl_cert_has_expected_profile`
passes. That function checks, in order:

| check | mechanism |
|---|---|
| `basicConstraints` is `critical, CA:FALSE` | `openssl x509 -noout -text` |
| `extendedKeyUsage` is TLS Web Server Authentication | same |
| `keyUsage` is `critical, Digital Signature, Key Encipherment` | same |
| every expected SAN verifies | `openssl verify -verify_hostname` / `-verify_ip`, **once per SAN** |

**That last row is what makes expiry self-healing, and it is easy to miss.** There
is no explicit expiry check anywhere in the file — no `notAfter` comparison, no
`-checkend`. Expiry is caught because `openssl verify` evaluates the validity
period as part of verification: an expired certificate fails with
`error 10 at 0 depth lookup: certificate has expired`, the profile check returns
false, both files are unlinked, and a fresh certificate is issued.

So **rotation exists**. It is a consequence of the SAN verification loop rather
than a feature written for the purpose, which is precisely why reading the file
for the word "expiry" finds nothing and suggests the opposite.

**The limit of that guarantee:** rotation happens at *certificate-generation time*,
which means at server start. A long-running server that was started before expiry
keeps serving the expired certificate until it is restarted, and nothing warns as
expiry approaches.

The verify loop is skipped if the expected-SAN list is empty — which cannot happen,
because `_ssl_expected_subject_alt_names` always seeds `localhost`, `127.0.0.1` and
`::1` before adding anything caller-supplied.

## What the certificate covers

Always `localhost`, `127.0.0.1`, `::1`, plus the concrete bind host and any
`web.ssl_subject_alt_names` entries. Wildcards are dropped and duplicates collapse
case-insensitively. A changed SAN set fails the profile check and forces
regeneration, so adding an alias to config is enough — no manual reissue.

## Validity period and the 398-day rule that does not apply here

Public certificate authorities are held to a maximum lifetime — 398 days since
Chrome 85, with Apple recommending 397 — and browsers reject publicly-trusted
certificates that exceed it.

**That limit does not govern this certificate.** Chromium's own documentation
scopes the requirement to TLS server certificates from publicly trusted CAs, and
states it does not apply to locally-operated CAs that have been manually
configured. A self-signed localhost certificate is outside it.

The consequence for anything configurable here is a design rule rather than a
number: **warn, never clamp.** Refusing or silently shortening an operator's chosen
validity would enforce a rule that does not apply to them, and would do it
invisibly. Telling them what browsers require of public certificates, and why their
certificate is not one, leaves the decision where it belongs.

### There is a second ceiling, and it is the one that bites

The paragraph above is about the *398-day* rule, and it is correct: that rule does
not reach this certificate. Apple's own page on the change says so in terms — the
398-day maximum applies to TLS server certificates issued from **preinstalled**
root CAs, and *"this change will not affect certificates issued from user-added or
administrator-added Root CAs."*

**But Safari still refuses a certificate that is long enough**, even from a
user-added root. Independent testing found 398 days accepted, 800 days accepted,
1592 days rejected, with the boundary located by half-interval search at roughly
**825 days**. That figure is somebody's measurement rather than a published limit,
and it has not been reproduced here — treat it as "there is a ceiling near two
years on Apple platforms", not as a specification.

So the honest warning for a large `web.ssl_validity_days` is not *"the 398-day
limit does not apply to you"* on its own. That sentence is true and reassuring and
would leave an operator who set 3650 wondering why Safari rejects a certificate
they were told was fine. The warning should say both halves: the public-CA rule
does not govern a self-signed local certificate, **and** Apple platforms appear to
stop honouring one somewhere around two years regardless.

Chromium is the more permissive of the two here, which is the opposite of the
direction one might assume from Apple's stricter public-CA posture.

## Enabling SSL changes the trust model, not just the transport

This is the part most likely to surprise someone reading the auth code alone.

Without SSL, a request arriving from loopback with a numeric **127.0.0.0/8**
literal (strict 0–255 octets) or `::1` is automatically an administrator.
Hostnames that merely *resolve* to loopback are never trusted — that is deliberate
DNS-rebinding protection.

**With SSL enabled, the loopback-admin shortcut is disabled entirely.** The server
runs a loopback front-proxy to an internal HTTPS backend
(`DEVELOPER_DASHBOARD_SSL_PROXIED`), and because every request then arrives from
the proxy, *every* browser client needs a helper login. Turning on HTTPS therefore
turns on authentication, and a setup that worked without credentials will start
asking for them.

## Where this lives

| concern | location |
|---|---|
| generation, reuse, profile check | `Web::Server` |
| SAN normalisation and expectations | `Web::Server` |
| certificate directory resolution | `Web::Server` → `PathRegistry` |
| `web.*` settings, including SAN aliases | `Config` |
| trust decisions and helper sessions | `Web::App` |

## A running server does not notice its own certificate expiring (DD-651)

Regeneration is real but has a narrower trigger than it looks:
`generate_self_signed_cert` reuses an existing certificate only when
`_ssl_cert_has_expected_profile` passes, and that check ends in an
`openssl verify` whose exit status is tested — `verify` validates dates, so an
expired certificate correctly fails the profile check and gets regenerated.

**But regeneration only runs when `generate_self_signed_cert` is CALLED, which
is at server START.** An instance already running when its certificate expires
under it keeps serving the expired one until somebody restarts it. With the
default 365-day validity (configurable under `web.*`, see above), that is a
once-a-year event that arrives with no warning — and the only fix, a restart,
is one nobody knows to perform because nothing said anything was wrong.

The exposure is sharper under SSL than it first looks: with the loopback-admin
shortcut disabled once SSL is on (see above), there is no trusted-local path
that degrades gracefully past a certificate error — every browser client is
already going through the helper-login path this section describes, so an
expired certificate doesn't merely look untrusted, it blocks the one path an
operator would use to notice and fix it.

`dashboard doctor` closes the visibility gap, not the rotation gap: it reads
the active certificate's own `notAfter` (via `openssl x509 -noout -enddate`,
never from config or a generation timestamp) and reports a **warning** inside
a configurable window (`web.ssl_warn_days`, default 30) or a **failure** once
past `notAfter` — the two are distinguishable outcomes because they call for
different actions, "plan a restart" versus "restart now". A certificate that
does not exist raises nothing at all: that is the normal, SSL-never-used
state, not a finding. A certificate that IS present but cannot be parsed
(`openssl x509` exits non-zero) is reported as its own outcome, distinct from
valid, near-expiry, and expired — a checker that cannot look must not report
clean.
