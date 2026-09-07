# A claimed environment limitation needs a live check, not a citation

Why "the docs say X is unavailable" is a claim to verify, not a fact to
inherit, and how cheap the check usually is.

## The problem this solves

Operator notes sometimes record a limitation of the host machine - a tool
that is not installed, a credential that only loads a certain way, a
service that is unreachable. These notes are accurate when written and can
go stale the moment someone installs the tool, changes the host, or the
limitation is simply outgrown. `CLAUDE.md` stated "There is no `gh` CLI on
this machine" and instructed working around it with raw `curl` calls - `gh`
2.45.0 was in fact installed and authenticated correctly with
`GH_TOKEN=$GITHUB_AUTH_TOKEN` (DD-795).

The cost is not the workaround itself (curl always works); it is that the
stale claim gets repeated and trusted without anyone checking, exactly the
way an undated count in prose goes stale silently (see
[[undated-counts-in-prose-go-stale]]) - except here the claim is binary
(present/absent) rather than numeric, so it is even cheaper to falsify.

## The rule

> **Before repeating or acting on a documented environment limitation
> ("there is no X", "Y is unavailable here"), run the one command that
> would prove it wrong.** `which <tool>`, a version check, or a real
> authenticated call costs seconds and either confirms the note or finds it
> stale.

## How to apply

- A sentence claiming a tool or service is absent is a hypothesis with a
  cheap experiment attached. Run the experiment before citing the sentence
  as a constraint on the current task.
- When the check contradicts the documented claim, correct the documented
  claim in the same change - a stale limitation left standing after being
  disproven once is worse than one nobody had checked, because the next
  reader now has evidence it is wrong sitting unused.
- This generalises past tooling: any operator note asserting the host
  cannot do something (no network access, no write permission, no
  credential) is checkable the same way, and should be checked before it
  shapes an approach.
