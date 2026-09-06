# Remediation advice is part of the attack surface

**System-scoped.** This is about every message this product prints that tells a
person what to run next — the CVE gates' stale-corpus refusals, install
bootstrap output, any "to fix this, do X" line. It is not about one ticket.

## The claim

**A tool's output is shipped code.** A refusal that names a command is a
recommendation the user will paste into a shell with their own privileges. It
gets the same review as the code that produced it, because it has the same
effect: it decides what runs on the user's machine.

This is easy to miss, because the recommendation is a *string*. It is not
executed by us, no test covers it by default, no linter reads it, and the
security audits grep for dangerous constructs in code rather than in the advice
the code prints. So it is the one output that can be wrong for months while
every gate stays green.

## The specific failure this page exists for

Both CVE gates refused a stale advisory corpus and told the user:

    cpanm --local-lib-contained /tmp/dd-fresh-cpansa CPANSA::DB
    PERL5LIB=/tmp/dd-fresh-cpansa/lib/perl5:$PERL5LIB <gate> <root>

Three properties, and the danger is in their combination rather than in any one
of them:

1. **The path is FIXED**, so it is predictable.
2. **`/tmp` is `1777`.** The sticky bit stops a user *deleting* another user's
   files. It does not stop them *creating* a directory first.
3. **`cpanm` reuses an existing directory** rather than refusing it — and the
   very next line puts that directory **first** on `PERL5LIB`.

So the recipe installs into a location the user does not control and then loads
Perl from it, ahead of every legitimate tree, on the advice of the security tool
itself.

**On the machine where it was found, the directory already existed** —
`drwxrwxr-x`, created hours earlier by an unrelated run, already containing
`CPAN/Audit/DB.pm` and `CPANSA/DB.pm`: exactly the modules the instruction says
to prepend. The hazard did not need contriving.

The published analogue is **CVE-2026-25645** (the Requests library), whose
`extract_zipped_paths()` "extracts files using deterministic, predictable
filenames and reuses existing files without validation, allowing a local
attacker with write access to `/tmp` to pre-create malicious files". Same three
properties. Classified **CWE-377** (Insecure Temporary File) and **CWE-378**
(Creation of Temporary File With Insecure Permissions).

## The rule

**Never name a fixed path under a world-writable directory in output a user is
expected to run.** Generate it per invocation:

    DIR=$(mktemp -d)
    cpanm --local-lib-contained "$DIR" CPANSA::DB
    PERL5LIB="$DIR/lib/perl5:$PERL5LIB" <gate> <root>

`mktemp -d` yields `drwx------` against the `drwxrwxr-x` measured on the fixed
path, and it is the remedy CWE-377's own guidance names.

## Two constraints that pull against each other, and both must hold

**The advice must stay ACTIONABLE.** The reason the refusal names a fix at all
is that a refusal with no way forward gets worked around rather than followed.
Replacing the recipe with "consult the documentation" would satisfy the security
objection by destroying the message's purpose. The fix above is one line longer
and still pastes as a block.

**The recipe must PARSE.** A refusal that prints a recipe with a syntax error is
worse than one that prints nothing, because the user believes it and then has to
debug our message. Extract the recipe lines from the emitted text and run
`sh -n` on them — this is cheap and nothing else checks it.

## How this class hides

**A scratch value promoted to shipped output.** `dd-fresh-cpansa` was a
directory name invented in a working session and pasted into the message
without being re-read as a user would read it. It means nothing to anyone
outside that session. When writing output a stranger will act on, read it back
as that stranger: every literal in it is a decision, including the ones that
arrived by accident.

**A fix that covered the incident and not the class.** This project had already
fixed shared fixed-`/tmp` paths once — for its own gate verdicts, which two
sandboxes were overwriting. That fix covered the *tools that write verdicts* and
not *every fixed `/tmp` path the project produces, including one it merely
recommends*. The same shape reappeared hours later, in code whose subject was
untrustworthy verdicts.

> When fixing one instance of a shape, either fix the others or write down that
> you did not. A shape fixed in one place and left in another reads as a
> **decision** to the next person, because somebody clearly considered the area.

## What to check, concretely

- `grep -rn "/tmp/" script/ lib/ bin/ share/` — every hit in user-facing output
  is a finding until shown otherwise. A *lock* file that is overridable and
  operator-local is a different thing from a directory prepended to `@INC`; say
  which one you have.
- Confirm the file actually ships. `dist.ini`'s `exclude_filename` list is the
  only thing that keeps a path out of the tarball — `.gitignore` does not.
- Assert on the *emitted text*, not on the source line, so a refactor of how the
  message is built cannot silently drop the property.
- Include a control: the pre-fix text must FAIL the assertion. Otherwise a green
  result is equally consistent with the test never having looked at the message.
