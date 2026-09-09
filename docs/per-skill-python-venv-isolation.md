# Per-skill Python venv isolation

`SkillManager::_install_skill_requirements_txt` installs each skill's
`requirements.txt` via `python -m pip install --user --requirement`. `--user`
lands the packages in one shared site-packages tree for the whole user
account, so every installed skill on the machine shares one Python
environment. Two skills wanting different versions of the same package
conflict silently, and the failure shape is the one this project's own
CLAUDE.md already documents for the analogous shared `~/perl5` CPAN tree: a
CVE-audit tool pointed at a shared tree reports advisories that belong to no
identifiable consumer, because nothing in a shared tree records which
package belongs to which skill.

## The mechanism

Each skill gets its own venv at `<skill>/local/venv`, reusing the isolation
boundary skills already have for Node dependencies (their own `local/`
directory).

1. `_install_skill_requirements_txt` creates `<skill>/local/venv` (via
   `python -m venv`) if it does not already exist, whenever that skill has a
   `requirements.txt`.
2. Dependencies install into that venv's own `pip`, never `--user`.
3. `command_argv_for_path` (or an adjacent Python resolver) checks whether
   the `.py` file's own skill layer has a `local/venv`; if so, it runs the
   script with that venv's `python` interpreter.
4. A skill with no `requirements.txt` (and therefore no `local/venv`) falls
   back to exactly today's global-`python` behavior - unchanged.

Two skills declaring conflicting versions of the same package resolve
independently, because each has its own venv and its own site-packages.

## What does not change

Skills that have already been installed under the old `--user` scheme are
not migrated automatically - a skill needs its install step re-run to gain a
venv. The global-python fallback path for skills with no `requirements.txt`
is unchanged.

If venv creation itself fails (no real Python available, disk full, etc.),
the install falls back to the previous global `--user` path rather than
leaving the skill with no dependencies installed at all - a degraded but
working state, not a hard failure.

## Origin

Michael proposed a single shared `~/python3` venv for all skills, matching
his `~/perl5`-style single dependency tree. Corrected during discussion:
CLAUDE.md already documents the identical failure shape for `~/perl5` (24
false-positive CVE advisories, none attributable to a real consumer, because
a shared tree cannot say which package belongs to which project). Michael
agreed and asked for per-skill isolation instead ("Ok make it per skill
then... Ok, go for it", 2026-09-08). Tracked as DD-824.
