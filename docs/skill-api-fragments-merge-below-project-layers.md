# Skill `config/api.json` fragments merge BELOW project layers, not above

Why `Config::api_registry`'s merge order matters, what it protects against,
and how it differs from the general `config/config.json` merge in the same
file. This page describes the current behavior of the system, not any one
ticket.

## The rule

`Config::api_registry` builds the visible, layered API-key authorization
registry (client name -> secret + allowed ajax routes) that
`Web::App::_authorize_api_request` checks against an incoming
`x-dd-api-key`/`x-dd-api-secret` pair. Two kinds of source contribute to it:

- **Project-layer `config/api.json` files**, one per `.developer-dashboard`
  directory from `~` down through the cwd's parents (the DD-OOP-LAYERS
  chain), reversed so the deepest, most-specific layer is merged last and
  therefore wins. This is the layer an operator writes to directly via
  `dashboard api add --key ... --secret ...`.
- **Installed skills' own `config/api.json` fragments**, one per skill under
  `dashboard skills install <git-url-or-local-dir>`.

**Skill fragments are merged FIRST, as the lowest-priority defaults. Every
project layer is merged on top, last.** So an operator's own key, once set
at any project layer, can never be silently overridden or disabled by a
skill - a skill can only ever supply an API key the operator hasn't already
defined somewhere in their own layer chain.

## Why this direction, specifically

`_merge_api_key_hashes`'s right-hand side can do two things to an existing
entry: replace its secret/routes outright, or tombstone it with
`{"disabled": true}`, which removes it from the merged registry entirely.
Neither operation is announced anywhere - `dashboard api ls` shows the final
merged state with no indication of which layer or skill produced any given
entry. If skill fragments merged last (the pre-DD-874 order), any installed
skill - and this project explicitly supports installing skills from
arbitrary git URLs - could silently replace an operator's secret with one
the skill's author knows, or silently disable machine-to-machine auth for a
client the operator depends on, with the only visible symptom being a
previously-working credential suddenly returning a generic auth rejection.

Putting skill fragments first instead means the worst a misbehaving or
buggy skill can do is fail to provide its OWN key if the operator happens
to have defined one with the same name - never take away one the operator
already controls.

## Why this is different from the general config merge

`Config::load_global` (the same file, `_skill_config_fragments`) merges
skill fragments in the same relative position - after every project layer -
but it is not vulnerable to the same problem, because each skill's payload
is wrapped under its own namespaced key: `{ '_' . $skill_name => $config }`.
Two skills - or a skill and a project layer - can never collide on the same
top-level key, because no project layer ever writes a key starting with
`_<skillname>`. `_skill_api_fragments` returns the raw, un-namespaced
API-key hash instead, because the whole point of the registry is a flat
`client-name -> {secret, routes}` map that an incoming request's
`x-dd-api-key` header is looked up against directly - namespacing the keys
would break that lookup. The merge-order fix exists specifically because
this domain cannot use the same namespacing trick the general config
domain already uses safely.

## What this does NOT change

A skill can still contribute a genuinely new API-client key that no project
layer defines - that case was never broken and still works exactly as
before. The `disabled: true` tombstone mechanism itself is untouched; it is
still available for a *project layer* to disable a key a *skill* defined,
which is the direction DD-OOP-LAYERS' "deepest layer wins" already intends.

## Related

See the main architecture POD's DD-OOP-LAYERS section in
`lib/Developer/Dashboard.pm` for the general layer-precedence philosophy
this fix extends by one rung.
