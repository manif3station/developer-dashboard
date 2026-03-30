package Developer::Dashboard;

use strict;
use warnings;

our $VERSION = '0.35';

1;

__END__

=pod

=head1 NAME

Developer::Dashboard - project-neutral local developer dashboard runtime

=head1 VERSION

0.35

=head1 INTRODUCTION

Developer::Dashboard is a local-first developer toolkit intended to be reusable across unrelated projects.

It provides a small ecosystem for:

=over 4

=item *

saved and transient dashboard pages built from the original bookmark-file shape

=item *

legacy bookmark syntax compatibility using the original
C<:--------------------------------------------------------------------------------:> separator plus directives such as
C<TITLE:>, C<STASH:>, C<HTML:>, C<FORM.TT:>, C<FORM:>, and C<CODE1:>

=item *

Template Toolkit rendering for C<HTML:> and C<FORM.TT:>, with access to
C<stash>, C<ENV>, and C<SYSTEM>

=item *

legacy C<CODE*> execution with captured C<STDOUT> rendered into the page and
captured C<STDERR> rendered as visible errors

=item *

legacy-style per-page sandpit isolation so one bookmark run can share runtime
variables across C<CODE*> blocks without leaking them into later page runs

=item *

old-style root editor behavior with a free-form bookmark textarea when no path is provided

=item *

file-backed collectors and indicators

=item *

prompt rendering for C<PS1>

=item *

project/path discovery helpers

=item *

a lightweight local web interface

=item *

action execution with trusted and safer page boundaries

=item *

plugin-loaded providers, path aliases, and compose overlays

=item *

update scripts and release packaging for CPAN distribution

=back

The core distribution is intentionally project-neutral.

Project-specific behavior should be added through configuration, startup collector definitions, saved pages, and optional plugins.

=head1 DOCUMENTATION

=head2 Main Concepts

=over 4

=item * Path Registry

L<Developer::Dashboard::PathRegistry> resolves logical runtime, config, dashboard, collector, and indicator directories.

=item * File Registry

L<Developer::Dashboard::FileRegistry> resolves stable logical files on top of the path registry.

=item * Page Model

L<Developer::Dashboard::PageDocument> and L<Developer::Dashboard::PageStore> implement the saved/transient page model.

=item * Page Resolver and Plugins

L<Developer::Dashboard::PageResolver> and L<Developer::Dashboard::PluginManager> resolve saved pages, provider pages, plugin-defined aliases, and extension packs.

=item * Actions

L<Developer::Dashboard::ActionRunner> executes built-in actions and trusted local command actions with cwd, env, timeout, background support, and encoded action transport.

=item * Collectors

L<Developer::Dashboard::Collector> and L<Developer::Dashboard::CollectorRunner> implement file-backed prepared-data jobs with managed loop metadata, timeout/env handling, interval and cron-style scheduling, process-title validation, duplicate prevention, and collector inspection data.

=item * Indicators and Prompt

L<Developer::Dashboard::IndicatorStore> and L<Developer::Dashboard::Prompt> expose cached state to shell prompts and dashboards, including compact versus extended prompt rendering, stale-state marking, and generic built-in indicator refresh.

=item * Web Layer

L<Developer::Dashboard::Web::App> and L<Developer::Dashboard::Web::Server> provide the minimal local browser interface, including exact-loopback admin trust and helper login sessions.

=item * Runtime Manager

L<Developer::Dashboard::RuntimeManager> manages the background web service and collector lifecycle with process-title validation, C<pkill>-style fallback shutdown, and restart orchestration.

=item * Update Manager

L<Developer::Dashboard::UpdateManager> runs ordered update scripts and restarts validated collector loops when needed.

=item * Docker Compose Resolver

L<Developer::Dashboard::DockerCompose> resolves project-aware compose files, explicit overlay layers, services, addons, modes, env injection, and the final C<docker compose> command.

=back

=head2 Environment Variables

The distribution supports these compatibility-style customization variables:

=over 4

=item * C<DEVELOPER_DASHBOARD_BOOKMARKS>

Override the saved page root.

=item * C<DEVELOPER_DASHBOARD_CHECKERS>

Filter enabled collector/checker names.

=item * C<DEVELOPER_DASHBOARD_CONFIGS>

Override the config root.

=item * C<DEVELOPER_DASHBOARD_STARTUP>

Override the startup collector-definition root.

=back

=head1 MANUAL

=head2 Installation

Install from CPAN with:

  cpanm Developer::Dashboard

Or install from a checkout with:

  perl Makefile.PL
  make
  make test
  make install

=head2 Local Development

Build the distribution:

  dzil build

Run the CLI directly from the repository:

  perl -Ilib bin/dashboard init
  perl -Ilib bin/dashboard auth add-user <username> <password>
  perl -Ilib bin/dashboard update
  perl -Ilib bin/dashboard serve
  perl -Ilib bin/dashboard stop
  perl -Ilib bin/dashboard restart

=head2 First Run

Initialize the runtime:

  dashboard init

Inspect resolved paths:

  dashboard paths

Render shell bootstrap:

  dashboard shell bash

Start the local app:

  dashboard serve

Open the root path with no bookmark path to get the free-form bookmark editor directly.

Stop the local app and collector loops:

  dashboard stop

Restart the local app and configured collector loops:

  dashboard restart

Create a helper login user:

  dashboard auth add-user <username> <password>

Remove a helper login user:

  dashboard auth remove-user helper

Helper sessions show a Logout link in the page chrome. Logging out removes both
the helper session and that helper account. Helper page views also show the
helper username in the top-right chrome instead of the local system account.
Exact-loopback admin requests do not show a Logout link.

=head2 Working With Pages

Create a starter page document:

  dashboard page new sample "Sample Page"

Save a page:

  dashboard page new sample "Sample Page" | dashboard page save sample

List saved pages:

  dashboard page list

Render a saved page:

  dashboard page render sample

Encode and decode transient pages:

  dashboard page show sample | dashboard page encode
  dashboard page show sample | dashboard page encode | dashboard page decode

Run a page action:

  dashboard action run system-status paths

Bookmark documents use the original separator-line format with directive
headers such as C<TITLE:>, C<STASH:>, C<HTML:>, C<FORM.TT:>, C<FORM:>, and
C<CODE1:>.

The browser editor highlights directive sections, HTML, CSS, JavaScript, and
Perl C<CODE*> content directly inside the editing surface rather than in a
separate preview pane.

Page C<TITLE:> values only populate the HTML C<E<lt>titleE<gt>> element. If a
bookmark should show its title in the page body, add it explicitly inside
C<HTML:>, for example with C<[% title %]>.

C</apps> redirects to C</app/index>, and C</app/E<lt>nameE<gt>> can load
either a saved bookmark document or a saved ajax/url bookmark file.

=head2 Working With Collectors

Initialize example collector config:

  dashboard config init

Run a collector once:

  dashboard collector run example.collector

List collector status:

  dashboard collector list

=head2 Docker Compose

Inspect the resolved compose stack without running Docker:

  dashboard docker compose --dry-run config

Include addons or modes:

  dashboard docker compose --addon mailhog --mode dev up -d

=head2 Prompt Integration

Render prompt text directly:

  dashboard ps1 --jobs 2

Generate bash bootstrap:

  dashboard shell bash

=head2 Browser Access Model

The browser security model follows the legacy local-first trust concept:

=over 4

=item *

requests from exact C<127.0.0.1> with a numeric C<Host> of C<127.0.0.1> are treated as local admin

=item *

requests from other IPs or from hostnames such as C<localhost> are treated as helper access

=item *

helper access requires a login backed by local file-based user and session records

=item *

helper sessions are file-backed, bound to the originating remote address, and expire automatically

=item *

helper passwords must be at least 8 characters long

=back

This keeps the fast path for exact loopback access while making non-canonical or remote access explicit.

The editor and rendered pages also include a shared top chrome with share and
source links on the left and the original status-plus-alias indicator strip on
the right, refreshed from C</system/status>.
That top-right area also includes the local username, the current host or IP
link, and the current date/time in the same spirit as the old local dashboard chrome.
The displayed address is discovered from the machine interfaces, preferring a VPN-style address when one is active, and the date/time is refreshed in the browser with JavaScript.
The bookmark editor also follows the old auto-submit flow, so the form submits when the textarea changes and loses focus instead of showing a manual update button.

The default web bind is C<0.0.0.0:7890>. Trust is still decided from the request origin and host header, not from the listen address.

=head2 Runtime Lifecycle

The runtime manager follows the legacy local-service pattern:

=over 4

=item *

C<dashboard serve> starts the web service in the background by default

=item *

C<dashboard serve --foreground> keeps the web service attached to the terminal

=item *

C<dashboard stop> stops both the web service and managed collector loops

=item *

C<dashboard restart> stops both, starts configured collector loops again, then starts the web service

=item *

web shutdown and duplicate detection do not trust pid files alone; they validate managed processes by environment marker or process title and use a C<pkill>-style scan fallback when needed

=back

=head2 Environment Customization

After installing with C<cpanm>, the runtime can be customized with these environment variables:

=over 4

=item * C<DEVELOPER_DASHBOARD_BOOKMARKS>

Overrides the saved page or bookmark directory.

=item * C<DEVELOPER_DASHBOARD_CHECKERS>

Limits enabled collector or checker jobs to a colon-separated list of names.

=item * C<DEVELOPER_DASHBOARD_CONFIGS>

Overrides the config directory.

=item * C<DEVELOPER_DASHBOARD_STARTUP>

Overrides the startup collector-definition directory.

=back

Startup collector definitions are read from C<*.json> files in C<DEVELOPER_DASHBOARD_STARTUP>. A startup file may contain either a single collector object or an array of collector objects.

=head2 Testing And Coverage

Run the test suite:

  prove -lr t

Measure library coverage with Devel::Cover:

  cpanm --local-lib-contained ./.perl5 Devel::Cover
  export PERL5LIB="$PWD/.perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
  export PATH="$PWD/.perl5/bin:$PATH"
  cover -delete
  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t
  cover -report text -select_re '^lib/' -coverage statement -coverage subroutine

The repository target is 100% statement and subroutine coverage for C<lib/>.

The coverage-closure suite includes managed collector loop start/stop paths
under C<Devel::Cover>, including wrapped fork coverage in
C<t/14-coverage-closure-extra.t>, so the covered run stays green without
breaking TAP from daemon-style child processes.

=head2 Updating Runtime State

Run the ordered update pipeline:

  dashboard update

This performs runtime bootstrap, dependency refresh, shell bootstrap generation, and collector restart orchestration.

=head2 Blank Environment Integration

Run the host-built tarball integration flow with:

  integration/blank-env/run-host-integration.sh

This integration path builds the distribution tarball on the host with
C<dzil build>, starts a blank container with only that tarball mounted into it,
installs the tarball with C<cpanm>, and then exercises the installed
C<dashboard> command inside the clean Perl container.

The harness also:

- creates a fake project wired through C<DEVELOPER_DASHBOARD_BOOKMARKS>, C<DEVELOPER_DASHBOARD_CONFIGS>, and C<DEVELOPER_DASHBOARD_STARTUP>
- verifies the installed CLI works against that fake project through the mounted tarball install
- extracts the same tarball inside the container so C<dashboard update> runs from artifact contents instead of the live repo
- starts the installed web service
- uses headless Chromium to verify the root editor, a saved fake-project bookmark page from the fake project bookmark directory, and the helper login page
- verifies helper logout cleanup and runtime restart and stop behavior

=head1 FAQ

=head2 Is this tied to a specific company or codebase?

No. The core distribution is intended to be reusable for any project.

=head2 Where should project-specific behavior live?

In configuration, startup collector definitions, saved pages, and optional extensions. The core should stay generic.

=head2 Is the software spec implemented?

The current distribution implements the core runtime, page engine, action runner, plugin/provider loader, prompt and collector system, web lifecycle manager, and Docker Compose resolver described by the software spec.

What remains intentionally lightweight is breadth, not architecture:

- plugin packs are JSON-based rather than a larger CPAN plugin API
- provider pages and action handlers are implemented in a compact v1 form
- legacy bookmarks are supported, with Template Toolkit rendering and one clean sandpit package per page run so C<CODE*> blocks can share state within a bookmark render without leaking runtime globals into later requests

=head2 Does it require a web framework?

No. The current distribution includes a minimal HTTP layer implemented with core Perl-oriented modules.

=head2 Why does localhost still require login?

This is intentional. The trust rule is exact and conservative: only numeric loopback on C<127.0.0.1> receives local-admin treatment.

=head2 Why is the runtime file-backed?

Because prompt rendering, dashboards, and wrappers should consume prepared state quickly instead of re-running expensive checks inline.

=head2 How are CPAN releases built?

The repository is set up to build release artifacts with Dist::Zilla and upload them to PAUSE from GitHub Actions.

=head2 What JSON implementation does the project use?

The project uses C<JSON::XS> for JSON encoding and decoding, including shell helper decoding paths.

=head2 What does the project use for command capture and HTTP clients?

The project uses C<Capture::Tiny> for command-output capture via C<capture>, with exit codes returned from the capture block rather than read separately. There is currently no outbound HTTP client in the core runtime, so C<LWP::UserAgent> is not yet required by an active code path.

=head1 SEE ALSO

L<Developer::Dashboard::PathRegistry>,
L<Developer::Dashboard::PageStore>,
L<Developer::Dashboard::CollectorRunner>,
L<Developer::Dashboard::Prompt>

=head1 AUTHOR

Developer Dashboard Contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
