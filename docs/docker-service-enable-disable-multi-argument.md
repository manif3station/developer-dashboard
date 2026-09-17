# Docker service enable/disable: multiple services in one invocation

## What this is

`dashboard docker enable <service...>` and `dashboard docker disable
<service...>` toggle whether a docker-compose service is included when the
project's compose files are materialized and run. Each accepts one **or
more** service names in a single invocation, dispatched from
`share/private-cli/_dashboard-core` into
`Developer::Dashboard::DockerCompose`'s existing `enable_service`/
`disable_service` methods, called once per named service.

## The contract

- `dashboard docker disable foo bar` disables both `foo` and `bar` -
  writes `{base}/config/docker/foo/disabled.yml` and
  `{base}/config/docker/bar/disabled.yml`. `dashboard docker enable foo
  bar` removes both markers.
- The single-service form (`dashboard docker disable foo`) behaves exactly
  as before - it is the one-service case of the same loop, not a separate
  code path.
- A mix of valid and invalid service names still toggles every valid name;
  an invalid name produces a clear per-service error rather than aborting
  the whole call. The process exits non-zero whenever at least one name
  failed, even if others succeeded.
- The `{base}` resolution (this project's DD-OOP-LAYERS runtime root) and
  the `disabled.yml` marker format are unchanged from the single-service
  behavior - only the argument-count restriction was lifted.

## Why it works this way

Before this, `_dashboard-core` died on more than one argument:

```perl
my $service = shift @ARGV || die "Usage: dashboard docker disable <service>\n";
die "Usage: dashboard docker disable <service>\n" if @ARGV;
```

`enable_service`/`disable_service` were already correct per-service
operations with no shared state between calls, so extending the CLI
dispatch to loop over every remaining `@ARGV` entry - collecting a
per-service result rather than stopping at the first failure - was
sufficient; no change was needed to `DockerCompose.pm` itself, the marker
file format, or `{base}` resolution.

## Where this is exercised

`t/05-cli-smoke.t` covers: multi-name disable, multi-name enable, the
single-service form staying unchanged, and a partial-failure case (a bad
service name among good ones - the good name still gets disabled, the
process exits non-zero, and an error is reported for the bad one, with
state cleaned up afterward).

## What uses this

Any operator or automation toggling more than one docker-compose service
at once - previously requiring one `dashboard docker disable <name>` call
per service, now a single invocation.
