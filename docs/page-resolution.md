# How a page id becomes a page

Ask the dashboard for a page by id — from a route, from the CLI, from a saved
bookmark — and something has to decide *which* page that is. There are two
places it can come from, they are tried in a fixed order, and the failure
behaviour is more careful than it first appears.

This page is system-scoped: it describes the model, not any change to it.

## Two sources, in order

```perl
sub load_named_page {
    my ( $self, $id ) = @_;
    die 'Missing page id' if !defined $id || $id eq '';

    my $saved = eval { $self->{pages}->load_saved_page($id) };
    if ($saved) {
        $saved->{meta}{source_kind} = 'saved';
        return $saved;
    }
    ...
    return $self->load_provider_page($id);
}
```

**Saved storage first.** Pages persisted under `dashboards/` as raw
`KEY: VALUE` source. A hit is stamped `meta.source_kind = 'saved'`, which is how
anything downstream can tell a user-authored page from a generated one.

**Providers second.** A flat list searched by id, where a match may be a
`builtin` — `system-status` and `project-context` are generated on demand from
the path registry rather than read from disk.

That ordering is a policy, not an accident: a saved page of the same id
*overrides* a provider, so a user can shadow a generated page by saving one
with the same name.

## The failure path is where the care is

`load_saved_page` can fail for three genuinely different reasons, and they must
not be treated alike:

| reason | what it means | what should happen |
|---|---|---|
| **not found** | no such saved page | fall through to providers |
| **read failure** | the file exists and could not be read | surface it — this is the real diagnostic |
| **parse failure** | the file was read and is not valid | surface it — likewise |

Only the first is a reason to keep looking. So the fall-through is guarded by
matching the error, not by catching everything:

```perl
if ( $@ !~ /\APage '\Q$id\E' not found/ ) {
    die $@;
}
return $self->load_provider_page($id);
```

**Collapsing those three into a silent fall-through is a real defect, and it has
been fixed once already.** A permissions problem or a corrupt page file would
otherwise be reported as `Page 'x' not found` once the provider lookup also
missed — sending whoever reads it to look for a missing page rather than a
broken one. The wrong diagnosis is worse than no diagnosis, because it comes
with a direction.

## What the resolver knows and does not say

By the time resolution fails, two things have been established and neither
reaches the caller:

- **which kind** of saved-storage failure occurred — the distinction above is
  computed, used to decide the fall-through, and then dropped;
- **which provider ids exist** — the provider list was searched, so the set of
  ids that *would* have matched is in hand.

The caller gets `Page '<id>' not found`. For the most common failure — a
mistyped or renamed id — that is the least useful thing that could be said,
because the answer the reader needs is sitting in the resolver at the moment it
gives up.

Perl's own loader is the model worth comparing against. It does not say "module
not found"; it says:

```
Can't locate Foo.pm in @INC (@INC contains: /path/a /path/b /path/c)
```

It names what was sought **and** enumerates every candidate tried, in order.
The general principle: **for a lookup over an ordered candidate set, report the
candidates, not just the verdict.**

## Where this lives

| concern | location |
|---|---|
| id → page, both sources, fall-through policy | `PageResolver` |
| saved-page storage, and the three failure kinds | `PageStore` |
| the page object itself | `PageDocument` |
| runtime paths the builtins report | `PathRegistry` |
| executing a saved page's handlers | `PageRuntime` |

Note that skill pages do **not** resolve through this path. They are served from
`<layer>/skills/<repo>/` via the `/app/<skill>[/<sub-skill>]/<id>` routes, and
are browser-editable only transiently — a POSTed edit renders for that request
and is never persisted back to the skill's shipped bookmark file.
