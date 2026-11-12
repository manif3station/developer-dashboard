# Developer Dashboard

<p align="center">
  <img src="docs/assets/banner.png" alt="Developer Dashboard — a home for day-to-day development" width="100%">
</p>

<p align="center">
  <a href="https://github.com/manif3station/developer-dashboard/actions/workflows/five-platform-coverage.yml"><img src="https://github.com/manif3station/developer-dashboard/actions/workflows/five-platform-coverage.yml/badge.svg" alt="Five-platform coverage"></a>
  <a href="https://metacpan.org/pod/Developer::Dashboard"><img src="https://img.shields.io/cpan/v/Developer-Dashboard.svg" alt="CPAN version"></a>
  <img src="https://img.shields.io/badge/Perl-5.38%2B-2e6ea6?logo=perl&amp;logoColor=white" alt="Perl 5.38 and later">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-1f2933" alt="macOS, Linux and Windows">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Licence-MIT-green.svg" alt="MIT licence"></a>
</p>

Developer Dashboard brings the everyday tools of local development into one place. Its browser interface, shell commands, prompt status, and scheduled checks share the same saved pages, settings, and runtime data.

## Choose a starting point

| Goal | Start here |
| --- | --- |
| Install it | [Installation](#installation) |
| Open it for the first time | [First Run](#first-run) |
| Save pages, links and actions | [Working With Pages](#working-with-pages) |
| Run scheduled checks in the prompt and browser | [Working With Collectors](#working-with-collectors) |
| Manage containers | [Docker Compose](#docker-compose) |
| Add reusable commands and integrations | [Skills System](#skills-system) |
| Contribute | [Maintainer Guide](#maintainer-guide) |

## Quick start

```sh
./install.sh          # macOS or Linux, from a checkout
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1   # Windows
```

```sh
cpanm --no-wget --notest Developer::Dashboard   # from CPAN
```

```sh
d2 init
d2 serve      # starts the web interface
```

## What's inside

- **Browser pages** for links, notes, forms, and reusable actions.
- **Command line tools** for opening files, navigating to project paths, querying structured data, managing pages, and running repeatable tasks.
- **Collectors and prompt status** for scheduled checks whose latest results can appear in the browser and shell prompt.
- **Project configuration** for path aliases, command extensions, API settings, and Docker Compose overlays, with project settings layered over shared settings.
- **Skills and integrations** for reusable commands, pages, and runtime extensions, including workspace-aware conversations through supported AI command line tools.
- **Cross-platform use** with installers and runtime support for macOS, Linux, and Windows.

## Repository map

```
bin/         d2 CLI entry points
lib/         Developer::Dashboard modules
script/      helpers, including the README sync script
share/       browser assets served by the web interface
t/           test suite (prove -j 10, with a coverage gate)
docs/        design notes and the README header
examples/    example pages, collectors and skills
install.sh   Unix and macOS bootstrap
install.ps1  Windows bootstrap
```

## Contributing

See the [Maintainer Guide](#maintainer-guide) for local development, testing and coverage. Open a pull request as a draft while work is in progress, and mark it ready only when it is done and verified.

## Licence

[MIT](LICENSE)
