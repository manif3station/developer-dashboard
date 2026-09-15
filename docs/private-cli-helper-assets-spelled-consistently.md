# Private CLI Helper Assets: which built-ins get dedicated helper bodies

What `lib/Developer/Dashboard.pm`'s "Private CLI Helper Assets" POD item
actually claims, and how to check it against the real shipped command
surface. This page describes the current state of the system, not any
one ticket.

## The claim

Private `~/.developer-dashboard/cli/dd/` helper files (staged from
`share/private-cli/`, per this project's LAZY-THIN-CMD architecture) give
a specific set of built-in commands their own dedicated helper body,
rather than staging a thin wrapper that hands off to the shared
`_dashboard-core` runtime. The POD names that set as: query commands
(`jq`/`yq`/`tomq`/`propq`/`iniq`/`csvq`/`xmlq`), `open-file`, `workspace`,
`path`, `file`, and `ps1`.

## How to verify this against the real command surface

    ls share/private-cli/ | grep -E '^(jq|yq|tomq|propq|iniq|csvq|xmlq|open-file|workspace|path|file|ps1)$'

Every name in that list should resolve to a real file under
`share/private-cli/` with its own command body - that is what "dedicated
helper body" means concretely. A name that doesn't resolve is either a
stale claim (the command was renamed or removed) or, as was the case
before this page existed, a claim that never named a real command at
all: the POD once said "prompt commands" here, which is not a command
name anywhere in this codebase - the real command for shell-prompt
rendering is `ps1` (`dashboard ps1`), spelled that way consistently in
every other reference to it in the same file (13 occurrences as of this
writing).

## Why this matters enough for its own page

This project's architecture POD is read by anyone trying to understand
which commands are "first-class" (own dedicated implementation) versus
thin wrappers over the shared core. A command name that doesn't exist
reads as either a documentation bug or, worse, an undocumented feature a
reader might go looking for and fail to find. The fix here (DD-873) was
purely a wording correction - "prompt" to "ps1" - with no change to
which commands actually get dedicated helper bodies.
