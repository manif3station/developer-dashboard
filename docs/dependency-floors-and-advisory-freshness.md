# Dependency floors, and the freshness of the advisory database

Two separate things decide whether the CVE gate tells you the truth: what the
manifests **permit**, and whether the advisory database has **heard of** the
advisory. Both can be wrong while the gate exits 0, and they fail in different
ways, so they are worth holding apart.

## The gate's subject is what the chain PERMITS, not what you installed

`script/cpan-audit-declared-chain` walks the declared runtime closure and asks,
per distribution, what is the **lowest** version this chain would accept. That
floor is then compared against advisory ranges. It is deliberately not a
question about the copy on your disk: a distribution ships to strangers, and
what matters is the worst resolution a user's client could legitimately pick.

So an unversioned requirement is not neutral — it is a declaration that any
version is acceptable, including versions with published advisories.

### A floor can be inherited from somewhere you did not look

This is the part that surprises. `cpanfile` may say

```perl
requires 'URI';
```

and the gate still reports a floor of **1.59**, because the closure walk takes
the maximum floor demanded by anything in the chain, and `Plack`'s
`runtime/requires` asks for `URI >= 1.59`. Our own manifest contributed
nothing.

The consequence: **grepping your own manifest for a version does not tell you
what floor the chain demands.** Only the closure walk does. Read the gate's
`floor demanded:` line, which names both the number and which distribution's
requirement produced it.

### Modules that share a distribution share its version

Advisories are published against **distributions**, while manifests declare
**modules**. `URI::Escape` ships inside the `URI` distribution and tracks its
version — measured, an installed URI 5.34 carries URI::Escape 5.34 — so a floor
on either constrains the same distribution, and the gate takes the max across
every module mapping to it.

Declare the floor on **every** module you require from that distribution. A
floor on only one is correct today and silently drops to zero the day somebody
removes that one requirement, which is the kind of regression nothing reports.

## A clean audit is only as current as its database

`CPAN::Audit::DB` is a **static, versioned snapshot** shipped as a normal CPAN
distribution. Whatever copy is on `PERL5LIB` is what the gate consults, and
nothing on this host refreshes it. Its version is a datestamp:

```sh
perl -MCPAN::Audit::DB -e 'print "$CPAN::Audit::DB::VERSION\n"'   # e.g. 20260906.002
```

An advisory published after that stamp **does not exist** as far as the gate is
concerned. It does not warn, degrade, or hedge — it reports:

```
No distribution in the declared runtime closure permits a version inside an advisory range.
```

and exits 0. That sentence is true about the database it consulted and says
nothing whatever about the world.

> A clean result from a database that does not contain the advisory is not
> evidence of absence. It is the instrument reporting its own ignorance with
> total confidence.

### The failure has been observed here, and it is cheap to reproduce

Same closure, same library root, the database as the **only** variable:

| `CPAN::Audit::DB` | verdict |
|---|---|
| `20260807.001` | exit 0 — nothing permits a vulnerable version |
| `20260906.002` | exit 1 — `URI permits 1.59 which has advisory CPANSA--2026-19953` |

Thirty days of drift was the whole difference between a clean release gate and
a finding. Every CVE-clean record taken on the host in between was accurate
about what ran and was not evidence of what it claimed.

### So: state the database version beside the verdict

A verdict without its database version is not interpretable later. When
recording a CVE gate result — on a card, in a release note, anywhere — record
the stamp with it, exactly as a coverage figure is meaningless without the tree
it was measured on.

To audit against current data without mutating the shared `~/perl5` tree that
every project on this machine draws from, install a snapshot into a throwaway
root and put it **first** on the path:

```sh
cpanm --local-lib-contained /tmp/fresh-cpansa CPANSA::DB
PERL5LIB="/tmp/fresh-cpansa/lib/perl5:$HOME/perl5/lib/perl5" \
  perl script/cpan-audit-declared-chain <library-root>
```

## Do not let the gate's silence be your only instrument

When a floor is raised in response to an advisory, prove the fix by
**mechanism** rather than by the gate going quiet — the gate is exactly the
thing whose blindness you are trying to rule out. Ask the comparator directly:

```perl
CPAN::Audit::Version->new->in_range( '5.34', '<5.36' )   # true  - vulnerable
CPAN::Audit::Version->new->in_range( '5.37', '<5.36' )   # false - fixed
```

A pass that is attributable to the version you declared is a fix. A pass
attributable to a database that never mentioned the distribution is a
coincidence wearing the same clothes.

## Which audit is the release gate

Unchanged, and worth repeating because the distinction decides how a red CI is
read: `cpan-audit-declared-chain` judges **the product** and is the gate.
`cpan-audit-project` inventories **an isolated root** and includes the perl
interpreter, whose advisories are environmental (DD-499). See
`docs/gate-map.md`.

The trap is what that makes easy to dismiss. An advisory affecting a real
declared dependency can surface first through the isolated audit, wearing the
label of the audit you have been told is not a blocker. **Read what the finding
names, not which step reported it** — the environmental one and the real one
arrive in the same message.
