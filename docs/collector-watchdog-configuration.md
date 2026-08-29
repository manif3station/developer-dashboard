# Collector watchdog configuration

How the collector watchdog's limits are set, and the precedence that decides
which setting wins. This page describes the system, not any one ticket.

## What the watchdog does

The collector fleet is supervised. When a collector exits, the watchdog restarts
it — but not indefinitely: a collector that dies repeatedly in a short window is
a broken collector, and restarting it forever turns one fault into a busy loop
that hides the fault. Three numbers govern that judgement:

| setting | what it decides |
|---|---|
| **restart limit** | how many restarts are allowed inside the window before the watchdog gives up on that collector |
| **restart window (seconds)** | the span the restarts are counted over |
| **stall grace (seconds)** | how long a collector may appear stalled before the watchdog treats it as dead rather than slow |

The limit and the window are one idea in two parts: "N restarts within M seconds"
is the actual rule, and neither half means anything alone.

## Where the values come from

Three sources, in a fixed order. **The first one that supplies a usable value
wins.**

```
environment variable   ->   config.json   ->   built-in default
```

| setting | environment variable | config key |
|---|---|---|
| restart limit | `DEVELOPER_DASHBOARD_COLLECTOR_RESTART_LIMIT` | `watchdog.restart_limit` |
| restart window | `DEVELOPER_DASHBOARD_COLLECTOR_RESTART_WINDOW_SECONDS` | `watchdog.restart_window_seconds` |
| stall grace | `DEVELOPER_DASHBOARD_COLLECTOR_STALL_GRACE_SECONDS` | `watchdog.stall_grace_seconds` |

```json
{
  "watchdog": {
    "restart_limit": 5,
    "restart_window_seconds": 600,
    "stall_grace_seconds": 20
  }
}
```

Config is layered like everything else in the runtime: the deepest
`.developer-dashboard/` directory from `~` down through the current working
directory's parents wins, and the `watchdog` object merges key by key. Setting
`restart_limit` in a project layer does not discard a `stall_grace_seconds` set
further up.

### Why the environment wins, and not the other way round

This is the part worth understanding before changing it.

The environment variables existed first, and something out there is already
setting them — a service unit, a container entrypoint, an operator's shell. If
the config key outranked the environment, then adding a `watchdog` block to a
config file would silently change the behaviour of every deployment that had been
relying on its environment, and it would do so at the next restart rather than at
the moment anyone made the decision.

So the config key is an **addition, not an override**. A deployment that sets
nothing gets the built-in defaults, exactly as before. A deployment that sets the
environment keeps behaving exactly as before, whatever any config file says. Only
a deployment that sets the config key *and not* the environment sees the new
value — which is precisely the case the config key was added for.

The general form of that rule: **when you add a second way to configure something
that already has one, the existing way keeps precedence, or you have shipped a
silent behaviour change disguised as a feature.**

## What counts as a usable value

Each config key is validated before it is believed. A value is used only when it
is present, is entirely digits, and is at least 1. Anything else — a missing key,
an empty string, a word, a negative, a zero, a float — is treated as *not set*,
and resolution falls through to the next source.

Falling through rather than failing is deliberate. A malformed watchdog number is
not worth refusing to start a collector over, and the next source down is always
a value the deployment has already been living with.

Zero is rejected rather than honoured because a zero restart limit and an absent
restart limit are indistinguishable to a reader, and the one that stops the
watchdog restarting anything at all should have to be said in a way nobody types
by accident.

## A note for anyone adding a fourth setting

Write the validation as separate guard statements, not one compound condition:

```perl
return undef if !defined $value;
return undef if $value !~ /^\d+$/;
return undef if $value < 1;
return $value + 0;
```

That is not style. A single `if (!defined $value || $value !~ /^\d+$/ || $value <
1)` leaves condition-coverage gaps that no reasonable set of tests closes tidily,
and this project's gate requires 100.0 on **condition** as well as statement,
branch and subroutine. The decomposed form makes each outcome reachable by one
obvious test. `web_workers()` in the same module has used this shape for the same
reason.
