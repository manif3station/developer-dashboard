# Fixed Bugs

## 6.11

- Fix the cross-platform full-suite workflow failing coverage-gate tests before
  their assertions ran. It installed project dependencies but omitted
  `Devel::Cover` and its `PERL5LIB` export, so child Perl processes could not
  load `Devel::Cover::DB::IO`. The workflow now installs the tool into the
  local library and exports that path before the suite; existing assertions
  are preserved.

## 6.10

- Fix DKT-009: load runtime environment files in parent-to-child order with
  plain files at each directory, allowing project `.env.pl` files to use home
  runtime values and preserving child override precedence.

## 6.09

- Complete Linux inotify coverage for release runners without optional
  `FFI::Platypus`: the fake native adapter now exercises descriptor wrapping,
  byte-safe `add_watch`, and descriptor close. The focused coverage gate reports
  100.0% statement, branch, condition, and subroutine coverage for
  `IndicatorStore::Watch.pm`.

## 6.08

- Add a regression assertion for the Linux inotify close callback on CI runners
  without optional `FFI::Platypus`. A subsequent release run showed that native
  descriptor wrapping and byte-safe watch registration also needed deterministic
  success-path coverage; those paths are covered in 6.09.
- Document that GitHub Release workflows are tag-triggered: a `dist.ini`
  version bump alone does not create a matching tag or publish a release.

## 6.07

- Clarify the cron minute/hour fields after an hourly schedule was entered as
  `* */1 * * *`, which correctly runs every minute. The reference now shows
  `0 */1 * * *` for a run at minute zero each hour. The scheduler implementation
  was verified and did not require a runtime change.

## 6.06

- GitHub issue 59 exposed a hardcoded `/tmp` expectation in the Homebrew
  installer regression test. The test now uses a case-local temporary
  directory and derives both expected command paths from `TMPDIR`; production
  installer behavior was already correct.

## 6.05

- The prompt performance test inherited `WORKSPACE_REF` from the invoking
  environment and compared decorated output with an undecorated prompt. Its
  fast, fallback, and compatibility probes now clear ticket and tmux state so
  the test isolates the code path it intends to compare.
- The HTML attribute escape Perl fallback lacked a regression assertion for a
  defined overloaded reference. Added coverage for that condition when XS is
  disabled; no production behaviour changed.

## 6.04

- No runtime bug fixes in this version. The version records the final Perl
  reference snapshot used for C++ compatibility work.

## 6.00

- Reduce warmed navigation-list assembly overhead by appending saved and skill
  fragments to one scalar instead of allocating a temporary list and joining
  it. Red-first tests pin exact wrapper markup and preserve the route response.
  A 10-million-call Docker comparison measured 1.68x for the wrapper workload;
  no end-to-end speedup is claimed.
- Speed up canonical saved-page id normalization by returning safe flat ASCII
  identifiers before trimming and prefix checks. Red-first tests confirm that
  nested, prefixed, whitespace-bearing, Unicode, undefined, and reference ids
  retain the existing normalization path. The Docker coverage gate passes all
  four metrics at 100.0% over 285 files / 25,326 tests. Three paired route runs preserved exact response
  bytes and improved the median from 0.422330 to 0.347531 ms/request (1.21x).
  This is a workload-specific gain, not evidence of the universal 50x goal.
- Reduced configuration-snapshot selector comparison overhead by replacing
  repeated pretty-JSON construction with a versioned length-prefixed key.
  Red-first tests preserve missing/undefined/defined distinctions and
  delimiter-bearing values. Nine alternating Docker samples measured 1.34x
  faster for the direct helper. Seven paired route samples retained the exact
  response hash but showed inconsistent timing, so no route-speed claim is
  made.
- Reduced repeated scoped `PathRegistry::runtime_root` overhead by reusing the
  deepest root only inside the existing operation/request snapshot. Red-first
  Docker tests verify repeated scoped reads and ensure unscoped calls still
  discover changes. Nine alternating samples measured 1.72x at the accessor
  and 1.24x in the complete `all_paths` inventory with exact JSON parity. The
  matched saved-page route showed no measurable gain, so this is not a
  route-wide or universal 50x claim.
- Replaced `_top_context_html`'s two host-normalization substitutions with
  prefix checks and a single `index` truncation after characterization tests
  pinned existing URL behavior. Nine alternating Docker samples measured 1.32x
  faster with exact output parity. No route-level speedup is attributed; the
  all-subroutine 50x goal remains open.
- Reuse the top-chrome prompt summary only when collector configuration and
  indicator freshness validation confirms it remains unchanged; status-file
  edits and status-route collector syncs that change configured indicators
  force a fresh summary. Focused Docker regression suites pass. With 50
  indicators, the matched saved-page route improved from 1.117690 to 0.435739
  ms/request (2.56x) with exact response-byte parity; NYTProf recorded 2 versus
  704 `list_indicators` calls. The forced portable-watcher comparison showed no
  measurable speedup, and the all-subroutine 50x goal remains open.
- Fixed stale prompt-summary text after `/system/status` performs the collector
  sync first: any changed collector synchronization now invalidates the cached
  summary for the next page render. Red-first tests in `t/03-web-app.t` and
  `t/668-problem48-status-response-cache.t` cover the sequence. The post-fix
  full Docker coverage gate passes all 285 files and 25,293 tests with 100.0%
  statement, branch, condition, and subroutine coverage across lib/ (51,645
  detail rows).
- Compiled the previous-format Markdown section-separator pattern once at module load
  instead of constructing it for each parse. The padded CRLF regression and
  focused PageDocument/saved-page route suites pass (188 tests). Nine
  alternating Docker samples measured the parser at 1.06x faster with exact
  parsed-output parity; the route-level timing remained within noise, so this
  is a narrow helper result and not a universal speed claim.
- Extended release hygiene to exclude default and named Devel::Cover databases
  using either hyphen or underscore suffixes. The 6.00 tarball exposed the
  defect by shipping `cover_db-p48-focus`; regression checks now cover both
  gather/prune matching and built archive members. The rebuilt archive has no
  matching members; `t/15-release-metadata.t` passes 5,756 assertions and the
  blank-container `cpanm` install plus integration run passes.
- Made Problem 48 route-benchmark verification portable across installations
  with and without optional native filesystem watchers. The benchmark reports
  the backend state and observed snapshot hits, and `--no-native-watch` forces
  the portable fallback. Native-cache scan and containment counts are asserted
  only when a backend is available; route byte parity remains mandatory in
  both modes. Combined focused Docker suites pass 432 assertions. A successful
  blank-environment install of this rebuilt tarball remains to be verified.
- Fixed lazy watcher imports after app or skill-route handlers change the
  working directory. The optional module is now resolved relative to the
  caller's absolute source path rather than a relative `@INC` entry, and an
  existing `%INC` load is preserved. The red `t/08-web-update-coverage.t`
  failure returned HTTP 500 on skill pages; the focused Docker rerun passes
  722 assertions across web routes, dispatcher, and route-benchmark tests.

## 5.99

- Made `t/41-skill-dispatcher-direct-coverage.t` independent of optional
  `FFI::Platypus` by injecting its deterministic watcher for path-filtering
  assertions. Made `t/673-problem48-saved-page-route-benchmark.t` compare
  optimized and control output with the same run's response hash, so the test
  works when distribution tests execute from a versioned extraction path.
  Reproduced both failures with `cpanm` in the blank Docker integration
  container; the corrected focused Docker suites pass 425 assertions. The
  rebuilt tarball install remains to be verified.

## 5.98

- Reduced `_prompt_summary` intermediate list allocations by composing the
  existing status/alias rows directly with `map` and `join`. A red-first Docker
  regression protects order, Unicode aliases, and source-array immutability;
  the focused web suites pass 1,054 assertions. Nine alternating 100,000-call
  measurements with 50 indicator rows improved from 865.926 ms to 797.271 ms
  (1.09x). The gain is helper-specific and does not establish 50x for the route
  or every subroutine.

## 5.97

- Reran the complete Docker coverage gate after the scalar mode accessor:
  285 files and 25,242 tests passed with 100.0% statement, branch, condition,
  and subroutine coverage across `lib/` (51,597 detail rows; no stale
  uncoverable annotations). This does not establish the 50x performance goal.

- Added `PageDocument::mode` and changed top-chrome rendering to read only the
  mode scalar instead of allocating the complete public page hash. A red-first
  Docker test fails if top chrome calls `as_hash`; focused document and web-app
  suites pass 629 assertions. Nine alternating million-call samples measured
  4.74x faster mode access with exact value parity.

- Reran the complete Docker coverage gate after canonical flat page-id
  validation: 285 files and 25,238 tests passed with 100.0% statement, branch,
  condition, and subroutine coverage across `lib/` (51,588 detail rows; no
  stale uncoverable annotations). This verifies coverage, not the all-routine
  50x performance target.

- Added a conservative validation fast path for canonical flat ASCII page ids.
  Prefixes, nested ids, Unicode, refs, whitespace, and invalid components
  continue through general normalization and validation. Red-first Docker tests
  pass in the 216-assertion PageStore suite. Nine alternating million-call
  samples measured 879.049 ms before and 430.213 ms after (2.04x).

- Reran the complete Docker coverage gate after the PageDocument id accessor
  and web-renderer regression. All 285 files / 25,236 tests pass with 100.0%
  statement, branch, condition, and subroutine coverage across `lib/` (51,582
  detail rows; no stale uncoverable annotations). Optional-tool-dependent
  checks remain unverified.

- Added `PageDocument::id` so hot renderer paths can read only the page
  identifier rather than allocate the complete `as_hash` result. A red-first
  Docker test failed when `as_hash` was stubbed during nav rendering, then
  passed after the renderer used the accessor. Focused PageDocument and web-app
  suites pass 625 assertions. Nine alternating million-read samples measured
  5.56x for `id()` over `as_hash->{id}`. The matched v5.88 route fixture
  measured 158.53x end to end with exact response parity; this does not prove
  50x for every subroutine.

- Reran the full Docker coverage gate after the fetch-metadata fast paths and
  direct security assertions: 285 files, 25,233 tests, and 100.0% statement,
  branch, condition, and subroutine coverage across `lib/` (51,573 detail
  rows; no stale uncoverable annotations). Optional-tool-gated checks remain
  separate and are not claimed as passing.

- Added an early return for absent, undefined, or reference-valued
  `Sec-Fetch-Site` metadata before lowercase/trim normalization. Existing
  semantics are retained: without a scalar fetch-site label the request is not
  classified as foreign. The focused Docker test passes 34 assertions. Nine
  alternating million-call samples measured 370.968 ms before and 298.395 ms
  after (1.24x) for the headerless path; this is not a universal performance
  claim.

- Added exact-string non-foreign returns for `same-origin` and `none`, avoiding
  case folding and whitespace regexes for the normal browser labels. Varied
  casing/spacing and foreign labels still follow the original normalization
  and security checks. The Docker cross-site suite passes 35 assertions. Nine
  alternating samples of one million same-origin calls measured 830.125 ms
  before and 442.506 ms after (1.88x versus the preceding fast path).

- Removed a second Perl function dispatch from the source-only HTML body
  escaper. Red-first Docker tests proved the public fallback no longer calls the
  reference helper and preserves escaping, undefined input, and overloaded
  stringification. Both source-only and compiled-XS focused suites pass. In 25
  alternating samples of 500,000 ordinary-text calls, the prior fallback
  measured 175.998 ms versus 135.123 ms (1.30x). This narrow fallback gain does
  not prove the all-subroutine 50x objective. The full Docker gate passed 285
  files / 25,229 tests with all four library metrics at 100.0% (51,571 detail
  rows and no stale uncoverable annotations).

- Rechecked the same 100-skill/20-saved-nav dashboard route against v5.88 after
  the current changes. Both responses matched at HTTP 200, 18,792 bytes, and
  the same SHA-256; current measured 0.420060 ms/request versus 135.065870
  (321.54x for this fixture). This is a cumulative route result, not a claim
  that every subroutine is 50x faster.

- Avoided allocating and splitting a multi-section list when parsing a single
  bookmark section. The fallback continues to handle both supported separator
  formats. Red-first Docker tests cover undefined input, whitespace, multiline
  values, unknown names, and extended CODE keys; six exact-parity parser cases
  passed. Nine alternating 500,000-call samples measured 1.87x for a common
  TITLE/HTML input. This is a narrow helper result, not proof of the universal
  50x performance objective.

- Rechecked the optimized saved-page route against exact v5.88 with 100
  installed skill-nav roots and 20 saved nav fragments. Nine matched samples
  of 100 requests had byte-identical HTTP output and medians of 135.065870 and
  1.136279 ms/request (118.87x). This is a workload-specific measurement, not
  proof of the 50x objective for every subroutine or platform.

- Fixed skill-nav watcher setup failure handling when the optional watcher
  cannot close and does not implement `last_error`. The old path called that
  optional method unconditionally and aborted page discovery. A Docker red test
  reproduced it; close diagnostics now use a visible `unknown close failure`
  message when the backend has no error accessor.

- Made watcher-validated skill-nav HTML snapshots reject unavailable page lists
  before comparing reference addresses, removing a numeric warning without
  masking errors or changing the renderer fallback. The web coverage fixture
  now clears cached HTML between mocked fallback cases, and the generated
  attribute markup continues to use the escaped value. Focused Docker web and
  attribute-security suites pass.

- Avoided three malformed-icon repair regexes for ordinary saved-page text by
  checking for the replacement character first. Regression tests preserve all
  repair contexts and unrelated U+FFFD content. The latest matched Docker
  route benchmark measured 97.46x source-only and 90.52x with XS versus v5.88
  for this 100-skill/20-saved-nav fixture. The compiled route sample was not
  faster than source-only, and no all-subroutine claim is made.

- Routed long, densely escaped `PageDocument` text through the shared XS body
  escaper, retaining a plain-value fast return and the original Perl path for
  short or sparse values. Exact output parity passed with the compiled XS
  extension. Seven alternating Docker microbenchmark samples measured 11.29x
  for a 384-character dense fixture; source-only fallback samples ranged from
  0.85x for short quote-heavy text to 1.34x for dense input. This is a
  helper-specific result and does not establish the all-subroutine 50x target.

- Routed long, densely escaped `PageDocument` text through the shared XS body
  escaper, retaining a plain-value fast return and the original Perl path for
  short or sparse values. Exact output parity passed with the compiled XS
  extension. Seven alternating Docker microbenchmark samples measured 11.29x
  for a 384-character dense fixture; ordinary text was near parity. This is a
  helper-specific result and does not establish the all-subroutine 50x target.

- Reused unchanged literal skill-nav page documents through a bounded
  per-dispatcher FIFO cache. Each request still resolves the route and checks
  the high-resolution stat fingerprint; dynamic TT and structured pages are
  always loaded afresh. Red-first Docker tests verify content edits, route
  creation/removal, and cache validation. Two paired 100-skill route runs kept
  the exact HTTP response and measured a 1.2665x incremental gain against the
  uncached current-source control. Problem 48's all-subroutine 50x target is
  still open.

- Fixed duplicate installed-skill discovery in portable config-snapshot
  validation. Watch-path generation now returns the skill entries it already
  found, and the same pass supplies their config paths to the exact-content
  signature. A fresh inventory is still gathered after config merging and on
  every later request, so new layers and same-size edits remain visible.
  Red-first Docker regression coverage verifies the discovery counts and
  malformed optional argument errors; `t/03-web-app.t` passes 507 assertions.
  Exact route response parity was preserved, but the measured profile change is
  not claimed as an end-to-end or v5.88 speedup.

- Added explicit cross-platform CI coverage for Linux, macOS, and Windows on
  x64 and ARM64 hosted hardware. Full-suite lanes run on Linux/macOS x64 and
  ARM64 and Windows x64. Windows ARM64 uses a focused native watcher test
  because its preinstalled Perl is below the distribution's 5.38 minimum; the
  workflow does not represent that lane as a full-suite result.

## 5.96

- Fixed runtime path-ancestry comparisons for Windows. The shared identity
  comparator had hard-coded `/` after canonicalization, while
  `File::Spec::Win32` canonicalizes to backslashes; case variants also failed
  on case-tolerant volumes. Red-first Docker tests reproduced child-path,
  case-variant, drive-root, and textual-prefix cases. The comparator now uses
  the active File::Spec root separator and queries case tolerance for the
  specific root volume. Focused
  PathIdentity/PathRegistry tests pass; actual Windows execution is required
  from the cross-platform GitHub workflow.

- Added optional native filesystem-event adapters for macOS (FSEvents) and
  Windows (wide-character directory notifications) alongside Linux inotify.
  Portable validation remains the fallback. The cross-platform CI matrix now
  installs the platform modules and requires a native watcher to detect a real
  filesystem write; hosted macOS/Windows results are pending. Watcher cleanup
  now treats a false FSEvents stop return as a failure and preserves explicit
  or fallback cleanup diagnostics. The focused Docker watcher test passes 209
  assertions with all four isolated Watch.pm coverage metrics at 100.0%.
  Each CI leg now checks the actual operating system and CPU architecture
  against its declared Linux/macOS/Windows x64/arm64 matrix label.

- Fixed the non-Linux configuration snapshot path so lack of inotify no longer
  disables cross-request snapshot reuse. It checks layered directory metadata
  and hashes the exact global, project, and installed-skill config inputs to
  detect creation, removal, and same-size in-place edits. The focused Docker
  regression exercises both cache reuse and invalidation with the native
  watcher unavailable, including recovery after a watcher rejects its setup.
  The cross-platform workflow now benchmarks automatic and forced-portable
  freshness on all six Linux/macOS/Windows x64/arm64 runners. A paired Linux
  run preserved the exact 12,864-byte response and measured 0.336020 ms/request
  portable versus 0.117619 automatic (2.86x slower); macOS/Windows results are
  pending. This closes config-cache availability, not the all-subroutine 50x
  goal.

## 5.95

- Skill-page loading now computes a skill's ordered runtime layers once and
  shares them between file resolution and page metadata. Request-scoped
  installed-skill inventory reuse also avoids repeating name validation and
  scanning all skill roots for each page; directory existence and disable
  markers are still checked per lookup, and unscoped calls remain fresh.
  Red-first Docker tests verify one resolution per page and live marker changes.
  The paired 50-skill route measured 1.10x against the repeated-lookup control
  with exact response parity; current source measured 8.01x versus v5.88 for
  that workload only. Problem 48's all-subroutine 50x target remains open.

- Skill navigation now reuses its layer list across fragment enumeration and
  loading instead of resolving it once for enumeration and again for every
  fragment. A red-first Docker assertion caught three resolutions for one
  two-fragment skill and now verifies one. The 50-skill fixture improved 1.12x
  against its repeated-lookup control with exact response parity; the broad
  all-subroutine 50x target remains open. Full Docker coverage passed 285 files
  and 24,569 tests with all four metrics at 100.0% (49,830 detail rows).

- Raw skill `nav/*.tt` files that contain ordinary HTML/TT content no longer
  pay for a structured instruction parse that predictably fails before the
  raw fragment fallback. Recognized modern and previous-format page sections
  and raw URL bookmarks keep their existing paths. Red-first Docker tests
  prove parser skipping and structured-page parity. The matched 50-skill
  route measured 1.14x against a forced-parse control with exact response
  parity; the broader all-subroutine 50x objective remains open. The full
  Docker gate passed 285 files / 24,593 tests with all four library metrics
  at 100.0% (49,880 detail rows; no stale uncoverable annotations).

- Literal-nav cache refresh and eviction no longer dereference malformed old
  entries as hashes. A bad in-memory cache entry is replaced safely, and a
  saved nav path that becomes non-regular before its initial fingerprint now
  fails with an explicit `Invalid page path` error. Red-first Docker tests also
  cover stale fingerprints, malformed root snapshots, post-read file/symlink
  replacement, and page-id fallback. The focused PageStore and web tests pass
  646 assertions. The first complete run passed 284 files / 24,495 tests but
  reported 99.9% branch and 99.8% condition coverage. After the unreachable
  condition was simplified, the next full Docker gate passed 284 files / 24,513
  tests and all four `lib/` metrics at 100.0% (49,769 detail rows, no stale
  uncoverable annotations). The all-subroutine 50x target remains open.
- The latest coverage report isolated one impossible MCDC combination in a
  `||=` assignment: validation guarantees the replacement ID is non-empty.
  Replacing it with an explicit false-value guard preserves behavior, and the
  focused instrumented Docker run now reports 100.0% PageStore condition
  coverage. The subsequent full gate also passes all four library metrics at
  100.0%.

- Literal-nav cache misses no longer run duplicate path containment validation:
  the subsequent secure-open boundary performs the single miss check. Cache
  hits still validate the path on every request. The 21-sample Docker A/B route
  benchmark preserved exact HTTP output and measured 12.75x versus v5.88; this
  route-specific result is not the all-subroutine 50x objective. The latest
  full Docker gate passed 284 files / 24,515 tests with statement, branch,
  condition, and subroutine coverage at 100.0% across `lib/` (49,770 detail
  rows, no stale uncoverable annotations).

- Canonical, safe, single-level `nav/*.tt` ids now bypass the general
  normalization/split path in PageStore; prefixed, nested, unusual, and
  traversal ids retain their existing behavior. The Docker regression was red
  before the fast path and now covers both the fast and fallback cases. The
  checked-in benchmark measured 2.45x for the isolated common-id helper, with
  exact validation parity. A reversed-order route confirmation preserved the
  response and measured 13.99x versus v5.88 for the 20-fragment fixture. This
  does not establish the requested 50x gain for every subroutine. The
  subsequent full Docker gate passed 285 files / 24,543 tests with all four
  `lib/` metrics at 100.0% (49,777 detail rows, no stale uncoverable
  annotations).

- Saved-page navigation now checks that its page store is a blessed object
  before probing the direct `load_nav_fragment` method. Lightweight compatibility/test
  page registries that only provide `dashboards_roots` retain the compatibility
  resolver instead of dying with a method call on an unblessed hash. The full
  Docker gate first exposed this failure; it was reproduced directly and fixed,
  and the complete `t/105-web-app-coverage-2.t` file passes. The latest full
  gate passes all four library coverage metrics at 100.0% (see the first item).
- Saved-page nav rendering uses the deepest matching layer recorded during the
  validated nav inventory instead of searching every dashboards root for each
  fragment; custom page resolvers remain authoritative.
  Literal HTML is cached per `PageStore` (up to 128 entries / 4 MiB) by
  high-resolution lstat identity; containment and regular-file checks still run
  for every hit, cache misses use the secure no-follow reader, and edits or
  symlink replacements are observed/rejected. TT and structured fragments
  remain on the normal page/render path. Red-first Docker tests cover direct
  layer selection, precedence, same-file edits, symlink replacement, cache
  bounds, and exact response parity. Matched five-fragment medians were 3.711650
  ms on v5.88 and 0.531738 current (6.98x) in an earlier matched run; the
  corrected precedence run for 20 fragments measured 9.256661 on v5.88 and
  0.699711 current (13.23x). Its no-cache control was 1.406310 ms with the same
  body hash. These route results do not prove the all-subroutine 50x objective;
  the latest full gate result is recorded in the cache-hardening item above.

- Status requests reuse the normalized indicator-collector projection in the
  watcher-validated configuration snapshot. `DEVELOPER_DASHBOARD_CHECKERS` is
  now included in the snapshot environment signature, so selector changes
  cannot reuse a projection built for another filter. Red-first Docker tests
  verified one projection across unchanged requests and a changed signature
  when the filter changes. Two order-reversed 21-sample route pairs preserved
  the exact 12,864-byte response and measured 1.29x (0.113299/0.111630 ms with
  the cache vs 0.143151/0.148051 ms without); projections fell from 2,103 to 1.
  The full Docker gate then passed 284 files / 24,419 tests at 100.0% for all
  four `lib/` metrics (49,525 detail rows; no stale uncoverables). The required
  `perldoc perlsec` command was attempted, but the minimal container lacks a
  loadable POD formatter. The result is specific to this status route; Problem
  48's all-subroutine 50x target remains open.

- Status synchronization reuses the canonical collector-job signature only
  while the watcher-validated configuration snapshot remains current; runtime
  indicator roots are still incorporated into every synchronization signature.
  Invalid explicit signatures now fail with a clear error. Two reverse-order
  21-sample Docker comparisons preserved the exact 12,864-byte response and
  measured 1.19x faster medians (0.105081/0.103180 vs 0.123909/0.124791
  ms/request); signature encodes fell from 2,103 to 1. This route-specific gain
  does not satisfy the all-subroutine 50x target.

- Added a single-pass XS implementation for quoted HTML attribute values.
  Escaping output and UTF-8 flags are checked across both quote characters,
  HTML metacharacters, Unicode, NUL, undefined input, taint mode, and overloaded
  references. Plain Perl fallback attributes at least 12 characters long now
  return after one metacharacter scan if no escaping is needed. The reusable
  benchmark compares against a genuine pure-Perl baseline; Docker measured
  1.63x for a normal nav identifier without XS, 1.80x with XS loaded, and 4.20x
  for quote-heavy text with XS. Short quote-heavy source-only input follows the
  existing substitution path; the wrapped helper measured 0.89x versus the
  lower-level pure-Perl reference on that tiny case. This tradeoff is specific
  to plain longer attributes; it does not prove the whole-route or Problem 48
  50x target, which remains open.
- Fixed a saved-page containment comparison that normalized literal POSIX
  backslashes as path separators. Such names now remain distinct on POSIX;
  case/separator normalization is applied only on Windows. A Docker regression
  first reproduced an outside sibling being accepted as inside the configured
  root, then passed after the fix. The POSIX hot path also skips those two
  unnecessary separator substitutions. A fresh byte-identical route rerun was
  5.97x versus v5.88 (3.777349 vs 0.632660 ms/request), but that cumulative
  route result is not attributed to this correction. Problem 48's all-subroutine
  50x target remains open.
- Fixed repeated shared-navigation filename enumeration on saved-page
  requests. The per-app nav ID inventory is reused only while the ordered nav
  directories retain the same high-resolution filesystem signature; additions
  and removals trigger a rescan. Incomplete directory scans are not cached and
  filesystem errors stay visible. Literal content now has its separate
  stat-validated cache described above; dynamic fragment output is still
  rendered per request. The earlier route inventory reduction was 1.024x and
  did not prove the 50x objective.
  The measured whole-route improvement was 1.024x, so this is a targeted
  reduction in repeated work, not proof of Problem 48's required 50x for every
  subroutine.
- Removed the redundant saved-page candidate containment check before secure
  open. Path containment and no-follow checks still run at the open boundary;
  symlink escape regressions confirm outside page content remains inaccessible.
  The exact-output Docker A/B benchmark measured 1.11x versus a control that
  restores the duplicate realpath check, with 12,600 versus 25,200 checks over
  2,100 requests. Timing was variable across pairs; the all-subroutine 50x
  objective remains open. Full Docker coverage passed 283 files / 24,353 tests
  at 100.0% for all four library metrics.
- Reuse the ordered saved-page roots only within one web request, avoiding one
  repeated root-list discovery per page/nav fragment while guaranteeing the
  next request discovers layers afresh. Direct PageStore calls remain
  uncached; regression tests cover root additions between scopes. The exact
  output benchmark found no route-level gain at five nav fragments and 1.04x
  at ten. Full Docker coverage passed 283 files / 24,372 tests with 100.0%
  statement, branch, condition, and subroutine coverage across `lib/` (49,511
  detail rows; no stale uncoverable annotations). The all-subroutine 50x target
  remains open.

- Problem 48's status snapshot watcher fallback and bounded-path branches now
  have explicit regression coverage for absent/rejected backends, cache
  invalidation, malformed skill entries, and home/project boundary handling.
  The full Docker gate passed 283 files / 24,307 tests with statement, branch,
  condition, and subroutine coverage all at 100.0% across `lib/` (49,396 detail
  rows; no stale uncoverable annotations). The global all-subroutine 50x goal
  remains open.

- Problem 48 now reuses the merged configuration snapshot across unchanged web
  requests. The regression was repeated chmod of already-private runtime
  directories, which emitted inotify `ATTRIB` events and invalidated the cache
  after every request; directory permissions are now checked before chmod.
  The watch set also excludes unrelated ancestors above home/project roots.
  Native-watcher tests prove cache reuse and config-change invalidation, while
  I/O tests prove chmod/stat failures remain visible and redundant chmod is
  skipped. The byte-identical 50-indicator status workload measured 381.04x
  versus v5.88; Problem 48's all-subroutine 50x objective remains open.

- Problem 48 saved-page rendering avoids canonical-instruction serialization
  for literal raw navigation while leaving dynamic nav on the request-aware
  Template Toolkit/CODE path. A separate request-local PageStore root-realpath
  map removes repeated resolution of the same configured dashboards root but
  still checks every candidate path and uses the existing secure open. Red-first
  Docker tests cover exact output, dynamic behavior, predicate truth cases, and
  fresh root resolution on the next request. The exact-output `/app/welcome`
  fixture improved from 3.758640 to 0.673630 ms/request versus v5.88 (5.58x for
  this workload only). Full Docker coverage passed 283 files / 24,251 tests at
  100.0% statement, branch, condition, and subroutine coverage (49,149 detail
  rows; no stale annotations). The security regression trio passed 466 tests;
  the overall all-subroutine 50x goal remains open.

- Problem 48 `Config::load_global` now establishes one runtime-layer candidate
  scope for a single configuration load and preserves an enclosing request
  scope. The first red Docker test saw five ancestry walks; after the change it
  sees one. A later-load regression confirms a newly created layer is visible
  immediately after the prior operation. In a parity-checked alternating
  Docker workload with four runtime layers and 25 skill configs, median time
  fell from 0.3175 to 0.2106 ms/load (1.51x). This does not meet the 50x
  all-subroutine target.
  `api_registry` uses the same operation-local inventory: its red-first test
  saw four ancestry walks before and one after. An alternating four-layer,
  25-skill Docker comparison preserved normalized output and improved median
  time from 0.3728 to 0.2638 ms/load (1.41x). A subsequent API load sees newly
  created layers. The clean full Docker gate passed 281 files / 24,176 tests
  with statement, branch, condition, and subroutine metrics at 100.0% across
  `lib/` (49,037 detail rows; no stale annotations).

- Problem 48 scoped runtime-path follow-up: cache the runtime directory-name
  choice only within the explicit runtime-layer operation scope, then re-read it
  on the next operation; exact home cwd skips ancestry and project-root work.
  Undefined, empty, and reference parent arguments now fail with the documented
  runtime-layer parent-path error instead of incidental Perl warnings.
  Red-first Docker tests exposed both redundant checks and protected next-call
  freshness. The scoped 50-collector `Config::load_global` median fell from
  0.146348 to 0.084262 ms/load (1.74x) with canonical output parity and external
  edits visible on the next call. The status route remained byte-identical but
  showed noisy timing, and the standalone method remains 1.09x slower than
  v5.88. No universal 50x claim is made.

- Problem 48 PathRegistry metadata follow-up: cache only the encoded JSON
  scalar for the most recent runtime-root/application-name pair. Repeated
  identical calls serialize once; changing either value regenerates the
  scalar. Every call still revalidates the live directory and metadata file,
  checks file type/owner/mode, reads on-disk bytes, and repairs or rejects the
  same cases as before. Red-first Docker tests failed on the redundant encode
  count and an uninitialized-content warning before the guards, then passed all
  317 PathRegistry assertions. The route kept the exact
  12,864-byte body hash; 0.247939 ms/request versus the previous 0.249081 ms is
  within noise and is not claimed as a speedup.

- Problem 48 state-root permission follow-up: `state_root` and
  `_state_root_for_layer` no longer harden the same directory immediately
  before `_write_state_metadata` repeats creation and permission checks.
  Red-first Docker assertions verified one metadata check per resolved root,
  with `all_paths` output unchanged. Focused PathRegistry/status tests passed
  361 assertions. Under NYTProf, `_ensure_state_dir` fell from 400 calls /
  2.82 ms exclusive to 300 / 0.523 ms across 100 byte-identical status
  requests. Unprofiled route timing was within noise (0.250821 versus 0.249081
  ms/request). A proposed indicator-job shortcut was slower at 0.858x and was
  rejected. The subsequent clean Docker gate passed 281 files / 24,182 tests,
  with statement, branch, condition, and subroutine coverage at 100.0% across
  `lib/` (49,039 detail rows; no stale annotations). No all-routine 50x claim is
  made.

- Problem 48 matched status-route recheck after the state-root follow-up:
  v5.88 measured 60.881879 ms/request and current source 0.342300 ms/request
  (177.77x) across 21 runs of 100 requests with 50 indicators. Both returned
  HTTP 200 and the same 12,864-byte SHA-256 body. This applies only to the
  tested route/workload and does not prove 50x for every subroutine.

- Problem 48 config-merge follow-up: skip the initial recursive merge when a
  single global config file is the only layer, preserve collector/provider
  identity normalization, and skip the repo merge when that layer is empty.
  Multi-layer, skill-fragment, and non-empty repo precedence are unchanged.
  The red-first Docker check caught one unnecessary merge and now sees none for
  the unique single-layer case; duplicate identity behavior remains covered.
  Focused web/config/benchmark tests passed 630 assertions. The route body
  remained byte-identical at 12,864 bytes; measured current-route timing was
  within run-to-run noise, so no additional speedup is claimed.

- Problem 48 stable collector-sync follow-up: add an optional Linux inotify
  hint via typed FFI::Platypus bindings. It skips repeated portable directory
  and file-signature validation only when the matching watch set has no
  mutation events; any event or watcher error forces the existing full
  validator, with visible warnings on failures. The native-enabled Docker
  regression suite and exact inventory/freshness benchmark passed. The stable
  50-indicator helper measured 0.001600 ms with inotify versus 0.256500 ms
  with portable validation (160.33x); this is not a v5.88 or whole-dashboard
  comparison and does not close the all-subroutine 50x goal. The latest full
  Docker gate passed 281 files / 24,176 tests, with statement, branch,
  condition, and subroutine coverage at 100.0% (49,037 detail rows; no stale
  annotations).

- Problem 48: cache constructed indicator status-file path strings while the
  ordered roots and discovered inventory are unchanged. Every status file is
  still metadata-checked on each request, so external edits and replacements
  remain visible. A red-first Docker regression reproduced 24 path joins for
  12 entries across two stable validations; it now verifies only 12. A
  21-sample 50-collector `/system/status` comparison preserved exact 12,414-
  byte bodies and measured 72.341 ms per 100 requests without path reuse versus
  66.347 ms with it (1.09x). This incremental result does not prove the
  all-subroutine 50x goal. Cache guard tests cover absent/stale signatures and
  malformed path lists. The full Docker gate passed 277 files / 23,938 tests
  with statement, branch, condition, and subroutine coverage at 100.0% across
  lib/ (48,462 detail rows; no stale uncoverable annotations).

- Problem 48 delivery gate: stabilize the empty machine-IP discovery case in
  `t/08-web-update-coverage.t`. Earlier route checks can cache a real host or
  container address, so the test now clears that cache before verifying the
  no-interface-result branch. The focused Docker test passes all 286
  assertions. The 5.95 tarball installed successfully with cpanm in a blank
  Docker environment; its bundled suite passed 277 files / 18,197 tests, and
  the documented blank-environment integration run passed.

## 5.94

- Problem 48: avoid constructing each indicator status-file path twice during
  unchanged status-response freshness validation. A shared existence map lets
  the active collector check reuse the inventory scan while preserving all
  file-signature checks. The red-first Docker test observed 24 path joins for
  12 entries before and 12 after. A fresh matched 50-collector benchmark
  measured 34.307 ms/request on v5.88 and 0.437 ms/request currently (78.50x)
  with exact 12,687-byte response parity. This is one route/workload only; the
  all-subroutine 50x objective remains open. The full Docker coverage gate
  passed all four metrics at 100.0% across 48,438 detail rows with no stale
  uncoverable annotations; perlsec and 622 security regression assertions
  passed afterward.

- Problem 48 status-route follow-up: after validated collector synchronization
  confirms configuration, status files, and directory inventory are unchanged,
  reuse the serialized status response and skip rebuilding the equivalent
  in-memory payload. Any detected change regenerates the payload and JSON.
  Red-first Docker tests cover exact bytes, payload-builder bypass, and cache
  invalidation. A matched 50-collector Docker run measured 34.257 ms/request on
  v5.88 versus 0.597 ms/request currently (57.38x), with identical 12,687-byte
  responses. This is a route-specific result; the every-subroutine 50x target
  remains open. The clean Docker gate passed 277 files / 23,871 tests with
  100.0% statement, branch, condition, and subroutine coverage across lib/
  (48,324 detail rows; no stale uncoverable annotations).
- Problem 48 follow-up: avoid repeated JSON reads and collector planning on
  unchanged status requests by reusing raw bytes only when high-resolution file
  metadata, active collector configuration, and directory inventory match.
  Each request decodes fresh values and detects external writes; changed config
  or indicator inventory takes the normal reconciliation path. Red-first Docker
  tests cover freshness and mutation boundaries. The 50-collector
  `/system/status` response remained byte-identical at 12,687 bytes and
  measured 0.670 ms/request against 35.090 ms on v5.88 (52.37x). This is a
  route-specific result. The clean Docker suite passed 276 files / 23,851
  tests and 100.0% statement, branch, condition, and subroutine coverage
  (48,283 detail rows). The all-subroutine 50x objective remains open.
- Problem 48: skip duplicate local and inherited indicator lookups when a
  collector synchronization has exactly one state root. A red-first Docker
  regression verifies these lookups do not run, while the existing mutation,
  listing, and retirement checks preserve observable state. The 50-collector
  `/system/status` benchmark retained exact response bytes and measured 3.51x
  over the previous comparison path; the all-routine 50x goal remains open.
- Problem 48 baseline verification: benchmark the same 50-collector status
  workload against v5.88 and the current checkout in Docker. Both returned
  identical 12,687-byte bodies; medians were 35.090 ms/request and 1.624
  ms/request (21.61x). This does not meet the 50x all-subroutine objective.
- Problem 48: avoid resolving indicator roots and decoding each status file
  repeatedly during one collector sync. The request-local cache shares the
  ordered root snapshot between collector comparisons and final inventory;
  writes/deletes invalidate affected entries, and later requests reread disk.
  Regression coverage verifies one root resolution, one physical read per
  indicator, cross-request freshness, and retirement cleanup. On a 50-collector
  status route, 15 alternating Docker runs measured 9.203 ms/request before
  and 2.689 ms/request after (3.42x) with exact response-byte parity. This is
  one route/workload gain, not the 50x all-subroutine objective.

## 5.92

- Problem 48: cache compiled scalar Template Toolkit blocks across web requests
  and create fresh render documents; cache machine-address discovery for five
  seconds; and scope canonical path identities and runtime-layer existence
  snapshots to each request. Red-first Docker regressions cover compiled-block
  reuse, expiry, request cleanup, and fresh-layer visibility in the next
  operation. A matched 15-run route comparison measured 0.497 ms versus 1.673
  ms for v5.88 (3.37x); this does not meet the all-routine 50x objective.
- Problem 48: cache parsed scalar Template Toolkit trees for the duration of
  one web request, with fresh documents per render and limits of 16 sources,
  256 KiB per source, and 1 MiB aggregate per include-root set. Tests verify
  dynamic stash, custom META, live includes, fresh-request visibility, parse
  failure reporting, and bounded-cache fallback. Fair request-scoped Docker
  microbenchmarks with an INCLUDE file measured 1.38x for five identical
  bodies and 0.97x for five distinct bodies. The broader 50x target remains
  open.
- Problem 48: fix early-but-rare escape dispatch in the native HTML escaper.
  Long inputs with fewer than four escapes in the first 16 characters now use
  chunk-copy even when the first escape is near offset zero. The compiled-XS
  Docker regression passes 44 assertions with exact byte, UTF-8, and taint
  parity; a 1 MiB prefix-sparse case measured 2.65x helper and 1.69x full
  instruction-highlighting speedups versus Perl. The full Docker gate passed
  275 files / 23,738 tests with 100.0% statement, branch, condition, and
  subroutine coverage across lib/ (47,889 detail rows, no stale uncoverables).
  The broader 50x objective remains open.
- Problem 48: compile the shared HTML body escaper as XS for ordinary scalar
  input while keeping source-only fallback and overloaded-reference behavior.
  A staged Docker MakeMaker build passed exact output, Unicode, embedded-NUL,
  UTF-8-flag, and taint-mode tests. The installed XS backend measured 12.63x
  faster than Perl at 1 MiB and 9.53x for full instruction highlighting. This
  result is specific to large text and does not satisfy the all-subroutine
  target.
- Problem 48: keep the native escaper fast across different text distributions:
  unchanged return for plain text, direct XS for dense escapes, and native
  chunk-copy for sparse escapes. Red-first dispatch tests and staged 1 MiB
  parity cover all three paths, including UTF-8. A 21-sample Docker benchmark
  measured helper gains of 12.40x/3.08x/1.02x and complete instruction
  highlighting gains of 9.02x/1.74x/1.00x for dense/sparse/plain inputs.
  Problem 48's all-routine 50x target remains open.
- Problem 48 HTML escaper branch coverage: add source-only tests for both
  ordering-comparison outcomes and direct Perl fallback normalization of
  undefined input. The final init-enabled Docker gate passed 274 files / 24,088
  tests with 100.0% statement, branch, condition, and subroutine coverage
  across lib/ (47,881 detail rows; no stale uncoverable annotations).
- Problem 48: cover both native and Perl HTML-escape dispatch branches without
  requiring a compiled artifact in source-only coverage. The full Docker gate
  passes 274 files / 24,063 tests and 100.0% on all four lib/ coverage metrics.

- Problem 48: normalize Dancer request arguments with one request object, one
  PSGI environment read, and one read of each required header. The red-first
  Docker regression reproduced 13 request acquisitions, four environment
  reads, and a duplicate Host read. Exact normalized payload parity was
  verified; a paired 200,000-call microbenchmark measured 5.568 versus 3.665
  microseconds per call (1.52x). This is not a 50x all-subroutine result.

- Problem 48 follow-up: read the seven required request headers from their
  fixed PSGI `HTTP_*` environment keys rather than repeatedly invoking Plack's
  header accessor. Docker parity tests compare these values to actual Plack
  normalization, verify invalid environment input fails explicitly, and check
  the standalone helper path. A five-pair benchmark with 200,000 calls per arm
  preserved canonical JSON output and measured 5.167 versus 2.578
  microseconds/call (2.00x). This is still a narrow helper gain.

- Problem 48: precompute indicator ordering fields for lists of at least 32
  entries so the sort comparator avoids repeated method dispatch and hash
  lookups. Regression coverage verifies reference comparator parity on the
  same input array, exercises collector-only and direct tuple order/name tie
  breaks, and confirms that the large-list path avoids the old comparator
  method. Final full two-layer list benchmarks with exact canonical output
  measured 1.04x at 50 entries, 1.14x at 1,000, and 1.06x at 5,000. A final
  30-pair isolated 5,000-record sort benchmark measured 16.240 ms with the
  prior comparator versus 10.763 ms decorated (1.51x) with exact order parity.
  Problem 48's overall
  50x-per-subroutine target remains open.

- Fix the root-only auth unreadable-record regression fixture: its temporary
  runtime directories and record are owned by the dropped uid, so permission
  hardening succeeds and the test checks the intended denied file read.

- Keep Inline, MCE::Map, SPVM, and SPVM::Digest::SHA optional in generated
  prerequisites because only Problem 48 experiment scripts/tests use them.
  This prevents clean installs from requiring benchmark toolchains or failing
  on unrelated upstream optional-engine tests.

- Problem 48: bypass Template Toolkit setup for static bookmark HTML with no
  default percent-bracket opener. The regression proves exact Unicode output
  and zero context/include/service setup; an alternating Docker benchmark
  measured 80.66x for that static render path only. The overall
  50x-per-subroutine target remains open.

- Repair blank-environment tarball verification for distributions whose
  public module delegates `$VERSION`: read `META.yml` first and retain a
  literal-module fallback for earlier archives. The regression fixture covers
  metadata precedence, earlier-format extraction, and loading the helper without
  launching the integration run. This release-gate fix does not claim that
  Problem 48's 50x-per-subroutine performance goal is complete.

- Keep the coverage gate's Devel::Cover serializer stamp beside its database,
  not inside it. A full Docker run reproduced Devel::Cover reporting its own
  marker as an invalid database; the red-first gate test now verifies adjacent
  storage, reader identity, and migration of the old in-database marker.

- Problem 48: give direct Dancer backend handlers the same request-local
  runtime-layer and installed-skill inventory scope as `Web::App::handle()`.
  A red-first PSGI test reduces ancestry discovery from five calls to one across
  repeated reads in one request and verifies scope cleanup afterward. Exact
  `/system/status` output stayed unchanged; 11 paired Docker samples measured
  0.5984 ms/request without the scope and 0.5696 ms/request with it (1.05x).
  Avoid redundant state-directory chmod only when the observed mode is exactly
  `0700`; non-private directories still follow the visible chmod/error path.
  The red-first I/O regression passes, and 21-run Docker microbenchmarks measured
  0.002329 ms per call at v5.88 versus 0.001290 ms currently (1.80x). A
  steady-state NYTProf run recorded 1,300 versus 100 PathRegistry chmod calls
  across 100 status requests. This is incremental evidence; Problem 48's
  all-subroutine 50x target remains open.

- Problem 48 coverage follow-up: deterministically exercise the failed `stat _`
  guard in state-directory hardening and the array-reference app guard in
  Dancer request scoping. Focused Docker tests pass 157 assertions, and the
  clean full Docker gate passes 272 files / 23,603 tests with 100.0% `lib/`
  coverage across statement, branch, condition, and subroutine metrics
  (47,773 detail rows, no stale uncoverables). Post-gate `perlsec`, syntax,
  POD, and diff checks pass. Problem 48's performance objective remains open.

- Problem 48: share exact path-identity results for the duration of one direct
  Dancer request, then discard the scope. The red-first route test verifies one
  resolution for repeated identical paths in each of two requests. Across 100
  exact-output `/system/status` requests, PathIdentity calls fell from 1,300 to
  600; 11 alternating Docker pairs measured 0.478 ms/request without the scope
  and 0.463 ms/request with it (1.03x). This is incremental, not the 50x target.

## 5.89

- Problem 48: reduce repeated Template Toolkit service construction in web
  rendering without retaining stale include templates between requests.
  Within a request, PageRuntime reuses a service only for the exact ordered
  include roots; Web::App discards the service scope when handling ends.
  Red-first Docker coverage checks current stash values, new include lookup,
  root changes, immediate visibility of file edits on the next request, and
  filtering undefined, reference-valued, and empty include roots before
  Template Toolkit sees them.
  Twenty-one paired runs of 500 exact-parity template renders measured 0.1825
  ms per fresh construction versus 0.1248 ms with scoped reuse (1.46x); this narrow
  gain does not meet Problem 48's all-subroutine 50x objective. The focused
  Docker suites passed 397 tests; the full gate passed 272 files / 23,952 tests
  with 100.0% statement, branch, condition, and subroutine coverage across
  lib/ (47,723 rows, no stale uncoverable annotations). Required web security
  suites passed 459 tests; `perlsec`, syntax/POD, release-metadata, and diff
  checks passed afterward.

- Problem 48: let nested PathRegistry aggregate reads reuse the request-local
  runtime-layer candidate scope rather than replacing it. A Docker route test
  bounds runtime ancestry discovery to two scans despite a permission-check
  re-entry and confirms the scope is discarded at the request boundary.

- Problem 48: avoid repeating the layered web-settings lookup within one
  request. The red-first Docker route test observed three calls while
  authorization and page chrome independently asked for settings; a
  request-local snapshot reduces this to one without persisting stale values
  between requests. `web_settings` now derives SSL validity from its existing
  merged config. On the measured page/status route, merged-config reads fall
  from seven to one; collector assembly reuses the exact snapshot and entries.
  The final Docker gate passed 271 files / 23,901 tests with 100.0% statement,
  branch, condition, and subroutine coverage across lib/ (47,644 rows, no stale
  uncoverables); unavailable optional tools and platform checks were explicitly
  skipped.

- Problem 48: reuse skill config entries read for the merged configuration
  when assembling collectors, avoiding a second pass over the same installed
  skill `config.json` files. The red-first test observed two entry enumerations
  before the fix and asserts one afterward. An alternating 21-pair Docker
  benchmark with 250 skills preserved canonical output and measured 27.324 ms
  for the former double-read flow versus 15.446 ms after (1.77x).

- Problem 48: remove PathRegistry's eager Fcntl import from runtime metadata
  file-type checks and use Perl's cached lstat file tests instead. Red-first
  Docker import coverage failed before the change; metadata symlink, directory,
  owner, and I/O regressions pass afterward. A 21-pair Docker microbenchmark
  measured 13.888 ms without Fcntl versus 15.017 ms with the former import
  (1.08x for isolated startup). This is not the 50x all-routine target.

- Problem 48: cache the shared JSON wrapper's lazily constructed canonical
  pretty encoder and UTF-8 decoder instead of allocating a JSON::XS object for
  each call. Red-first Docker tests assert one object, byte-for-byte canonical
  output behavior, and decoder recovery after malformed state input. Alternating
  21-pair Docker benchmarks of 10,000 calls each measured 1.41x encoding and
  1.17x decoding with exact output parity. The full Docker gate passed 270 files / 23,465 tests with
  100.0% statement, branch, condition, and subroutine coverage across lib/
  (47,486 detail rows). This targeted gain does not meet the 50x-per-subroutine
  goal.

- Problem 48: avoid repeating path-identity resolution for the selected home
  runtime root during each ancestor-layer walk when it is also present in the
  discovered home-layer list. The red-first test observed three normalizations
  of that exact path instead of two distinct necessary uses; runtime ancestry
  output remains unchanged and separate `.d2`/canonical siblings are preserved.
  The matched web-test profile retained 3,373 calls and measured 72.2 ms before
  versus 56.4 ms after (1.28x) for this routine.

- Problem 48: eliminate the repeated 1,008-entry section-key scan in
  separator-format bookmark parsing. Fixed section names use constant-time membership and
  numeric CODE names retain their existing acceptance behavior. The red-first
  regression verifies zero reads of the large key list and exact parser
  output; 21-run Docker microbenchmarks measured 122.13x for 10 sections and
  127.47x for 1,001. A matched NYTProf web-test workload dropped from 482 ms to
  3.59 ms exclusive across 148 parser calls. This is a parser-specific result.

- Problem 48: avoid reading the same indicator files twice while building the
  configured-collector status response. A red-first Docker test caught two
  listings and now requires one with exact response-body parity. The collector
  sync path returns its final inventory for payload rendering; orphan cleanup
  still refreshes that inventory after deleting a record. NYTProf showed 88
  listings becoming 46 across 44 status-payload/summary operations, with
  instrumented payload time improving 1.22x. This is not a 50x global claim.

- Problem 48: make indicator listing discover runtime roots once per listing
  instead of once for the listing and again for every record. A red-first test
  observed five root-discovery calls for four indicators; it now observes one.
  Files are still read on every operation and layered precedence is unchanged.
  Exact-output Docker benchmarks measured 8.06x (one layer) and 12.15x (two
  layers). This is a targeted result, not a claim that the 50x overall goal is
  met.

- Problem 48: share ancestor runtime-layer discovery between runtime_layers
  and runtime_layer_root_for during one operation. A red-first Docker test
  showed two ancestor walks in all_paths; it now performs one, while operation
  scopes are discarded so later calls detect newly created or removed runtime
  layers. The focused PathRegistry test passes 298 assertions.

- Problem 48: use native `getcwd` when absolute `$PWD` exactly matches the
  physical process directory, and validate distinct absolute PWD values by
  device/inode to preserve logical symlink spelling. A red-first Docker test
  verifies the one-call common path and symlink behavior; stale values use the
  physical directory. A matched 21-pair Docker microbenchmark measured
  1.7025 ms/call for shell-backed `Cwd::cwd` and 0.0009 ms/call for the helper
  (1,891.6x), with equal physical output. This result is specific to replacing
  shell-backed `cwd`, not a gain over native `Cwd::getcwd`. The 50x
  all-subroutine target remains open.

- Problem 48: verify the complete regression/coverage state after the direct
  native-getcwd common-path correction. The Docker gate passed 270 files /
  23,458 tests with 100.0% statement, branch, condition, and subroutine
  coverage across lib/ (47,464 rows; no stale uncoverables). Optional tools and
  environment-bound checks were explicitly skipped. Post-gate perlsec rendered.

- Problem 48: prevent stale object-lifetime runtime-layer memoization. A
  red-first Docker test reproduced a newly created project `.developer-dashboard`
  layer remaining invisible to the same PathRegistry object; the fix refreshes
  unscoped discovery while preserving per-operation reuse in `all_paths` and
  the path CLI. Creation and removal cases pass in the focused Docker suite.
- Problem 48: skip the redundant top-level disabled-marker `stat` when
  collecting nested skills with `include_disabled`; nested inventory checks
  the marker once when it builds its queue. Red-first Docker tests caught the
  duplicate and cover empty input. Exact output parity held in 51 paired
  benchmark runs: 50 skills improved from 0.599 ms to 0.496 ms (1.21x), and
  250 skills from 3.089 ms to 2.585 ms (1.19x). This local improvement is not
  evidence of the 50x-per-subroutine objective.
- Problem 48: scope canonical path-identity reuse to one `all_paths` call so
  repeated identical path strings avoid duplicate normalization without leaving
  stale results on the registry. Red-first Docker tests prove scoped reuse,
  undefined-path handling, and fresh resolution after scope exit. Exact JSON
  parity held in 51 paired runs; this sub-millisecond aggregate improved from
  0.576 ms to 0.424 ms (1.36x), well below the all-subroutine 50x target.
  The refreshed full Docker gate passed 264 files / 23,292 tests with 100.0%
  statement, branch, condition, and subroutine coverage across `lib/` (47,360
  detail rows), followed by a successful `perldoc perlsec` check.
- Problem 48: reuse sorted top-level skill directory names between nested
  discovery and layered config lookup only during one paths invocation. A
  red-first Docker regression caught two scans; the request snapshot reduces
  this to one and is discarded afterward. Disabled markers remain live, and a
  subsequent lookup sees a newly created skill. A two-layer 50-skill parity
  benchmark measured 1.465 ms versus 1.136 ms (about 1.29x); this is a narrow
  optimization, not the 50x-per-subroutine result.
- Problem 48: add direct regression coverage for Auth's defined native PBKDF2
  digest passthrough and Paths' empty-HOME builder path. The full Docker suite
  passed 263 files / 23,272 tests with 100.0% statement, branch, condition,
  and subroutine coverage across `lib/` (47,329 detail rows; no stale
  uncoverable annotations). This verifies coverage only; the 50x performance
  target remains open.
- Problem 48: cover both native and fallback branches of the PBKDF2 adapter
  without depending on installed optional FFI modules. Deterministic Docker
  tests fake the OpenSSL binding boundary and verify digest parity, lazy/cache
  initialization, signed-int buffer limits, and explicit native failures. An
  isolated Devel::Cover run reports 100.0% statement, branch, condition, and
  subroutine coverage for `Crypto::PBKDF2.pm`; this does not imply that the
  repository-wide 100% coverage or 50x-per-subroutine performance goals pass.
- Problem 48: keep `Developer::Dashboard::CLI::TableHelpers` out of the JSON-only
  paths startup path. A red-first Docker probe confirmed the eager import;
  after the change, JSON remains available without loading table code, while
  human/table output lazily loads the renderer and preserves its headings.
  This removes unnecessary startup work only and does not meet the 50x goal.
- Problem 48: share runtime-layer candidate discovery only for the duration
  of an aggregate `all_paths` operation, avoiding repeated ancestor scans
  across its permission checks without retaining stale roots between calls.
  Red-first Docker coverage caught 16 walks before the change; the scoped path
  now uses at most two in the test fixture. A later lookup discovers a project
  runtime layer created after `all_paths`. The 15-lookup benchmark preserved
  the selected root and measured 1.162 ms versus 0.305 ms (about 3.81x); this
  result is scoped and does not meet the 50x goal.
- Problem 48: reuse one installed-skill config inventory while resolving
  global and skill-qualified path aliases, eliminating a second scan across
  skill config files. Red-first Docker tests assert two prior inventory calls
  become one and validate malformed inputs. A synthetic 50-skill/two-layer
  benchmark preserved canonical JSON and measured 4.304 ms before versus
  2.342 ms after (about 1.84x); this does not satisfy the 50x objective.
- Problem 48: normalize the candidate once in `runtime_layer_root_for` rather
  than once for each runtime root. Root paths still receive their own live
  canonical resolution, with component-boundary matching unchanged. The
  red-first Docker test caught three candidate resolutions; the five-root
  100-pair benchmark preserved selected-root behavior and measured 0.059 ms
  versus 0.042 ms (about 1.41x), not the 50x target.
- Problem 48: merge only the `path_aliases` domain when reading layered skill
  config for the path command, avoiding recursive merges of unrelated fields
  and full skill namespaces. Docker regression tests preserve exact alias
  output and assert the unused merges are absent. A 50-skill/two-layer fixture
  with 80 unrelated fields measured 22.262 ms before versus 9.774 ms after
  (about 2.28x); this scoped result is below 50x.
- Problem 48: reuse one nested-skill inventory for configured path aliases and
  `Folder.pm` aliases in the `paths` command, avoiding a second recursive scan.
  Disabled skills and descendants remain excluded from Folder providers even
  though config alias reading retains its explicit include-disabled behavior.
  Red-first Docker tests caught the two scans and verify argument diagnostics,
  disabled filtering, and unchanged JSON. A 50-skill/two-depth benchmark
  measured 4.355 ms separate versus 3.317 ms shared (about 1.31x) with exact
  canonical JSON parity; this does not meet the 50x target.
- Problem 48: carry validated nested-skill ancestry forward while building
  config write locations, rather than revalidating every chain prefix and
  shifting the breadth-first queue. The red-first Docker test caught repeated
  segment validation; parity tests cover top-level/global, git-managed, deeper
  ancestor, and invalid-segment cases. A 50-skill/two-depth benchmark preserved
  exact canonical JSON and improved this routine from 5.407 ms to 2.048 ms
  (about 2.64x). NYTProf measured nested discovery at 12.1/3.60 ms
  inclusive/exclusive before versus 6.89/1.06 ms after. This scoped result does
  not satisfy the 50x objective.
- Problem 48: reuse discovered nested-skill directory chains when resolving
  read-side alias overrides, avoiding a second layer walk per skill. Red-first
  Docker tests check write-target parity and prevent repeated resolution. A
  synthetic 50-skill/two-layer/two-depth benchmark measured 4.216 ms versus
  2.347 ms (about 1.80x) with exact output parity; this does not meet the 50x
  target.
- Problem 48: add a grouped installed-skill layer inventory and consume it for
  layered collector and API-key config, removing the repeated layer scan per
  skill while preserving merge order and disabled masking. Docker tests assert
  exact precedence and fail if Config returns to per-skill scans. A synthetic
  50-skill/four-layer parity benchmark measured 4.431 ms before versus 3.409 ms
  grouped (about 1.30x), not the requested 50x.
- Problem 48: defer Getopt::Long in `share/private-cli/ps1` and parse exact
  generated-prompt options locally. Unsupported and abbreviated inputs still
  use the compatibility parser. Docker tests cover values, prompt output,
  warning-free fallback, and fast-path module loading. The canonical-path
  benchmark was 29.338 ms versus 33.174 ms with Getopt::Long preloaded (about
  1.13x); a 30-pair public-command control was 65.535 ms versus 72.307 ms
  (about 1.10x). This does not meet the 50x target.
- Problem 48: use the switchboard-provided library path in the `ps1` helper,
  keeping FindBin for standalone fallback. Docker tests confirm both routes
  and identical prompt content except the live timestamp. The measured helper
  path difference was only 1.01x, not a 50x result.
- Problem 48: make the prompt helper use the repository library path supplied
  by the public switchboard and defer FindBin to standalone fallback execution.
  Red-first Docker regressions verify both routes, normal prompt output, and no
  warnings. An alternating 25-pair cold-helper benchmark measured 33.364 ms
  with the supplied path versus 33.671 ms with fallback (about 1.01x); this is
  not meaningful evidence for the 50x objective.
- Problem 48: avoid loading FindBin in the private `paths` helper when the
  public switchboard has already supplied `DEVELOPER_DASHBOARD_REPO_LIB`.
  FindBin remains the standalone fallback. Docker tests verify both routes,
  warning-free operation, and byte-identical JSON. An alternating 100-pair
  fresh helper-process benchmark measured 26.963 ms with fallback versus
  24.782 ms with the supplied path (about 1.09x); this is not a 50x end-to-end
  result.
- Problem 48: update `t/43-explicit-coverage-qa.t` to stub the path-bound
  `Config->for_path_config` constructor after CLI::Paths stopped constructing
  the previous Config/FileRegistry pair. The final Docker coverage gate,
  including the paths helper's lazy FindBin change, passed 263 files / 23,551
  tests with 100.0% statement, branch, condition, and subroutine coverage
  (46,954 detail rows; no stale uncoverable annotations). `perldoc perlsec` was
  run and reviewed in the same container after the final gate.
- Problem 48: reuse a path-only `Config` view for prompt and path CLI config
  operations. The collector and path-alias readers use `PathRegistry` and do
  not access `FileRegistry`; the `dashboard paths` helper no longer imports or
  constructs it. A red-first Docker test blocked the module and failed on
  `dashboard paths -o json`; focused prompt, config, and path CLI tests passed
  361 assertions after the change. An alternating 25-cycle process comparison
  measured `dashboard paths -o json` at 64.636 ms with `FileRegistry` unloaded
  versus 72.077 ms with it force-loaded (about 1.12x). This control isolates
  module loading rather than the full former implementation, and does not
  establish the 50x goal.
- Problem 48: avoid constructing a `FileRegistry` for prompt collector reads.
  Collector configuration only uses `PathRegistry`, so `Config` now provides
  a path-only collector view and `ps1` uses it. A red-first Docker regression
  blocked `FileRegistry` and failed before the change; the prompt-loader and
  Config suites now pass 327 tests. An alternating 25-cycle fresh-process
  benchmark measured 76.918 ms versus 85.200 ms with `FileRegistry`
  force-loaded (about 1.11x). The full Docker coverage gate passed 263 files /
  23,541 tests with all four library metrics at 100.0% (46,955 detail rows).
  This prompt-specific result does not meet the all-routine 50x requirement.
- Problem 48: keep `Capture::Tiny` out of the ordinary prompt startup path.
  The prompt helper only needs capture for tmux ticket lookup, and
  `IndicatorStore` only needs it for the full project/Git refresh, not its
  prompt-only route. A red-first Docker regression installed a module stub
  that dies if ordinary `ps1 --no-indicators` imports Capture::Tiny; it failed
  before and passed after both imports were deferred. The prompt-loader, CLI
  smoke, and IndicatorStore Docker suites passed 1,322 tests. An alternating
  25-cycle cold-process benchmark measured 71.498 ms with lazy loading versus
  78.034 ms with Capture::Tiny force-loaded (about 1.09x); the overall 50x
  target remains unmet.
- Problem 48: keep the FFI accelerator tests valid when optional FFI modules
  are absent. Previously the test intentionally skipped native checks, then
  unconditionally required `FFI::CheckLib` and exited early. It now skips only
  the fixtures requiring absent modules, while fallback tests still run and
  all native assertions run when those modules are available. The final Docker
  gate passed 263 files / 23,539 tests with 100.0% statement, branch,
  condition, and subroutine coverage (46,943 detail rows).
- Problem 48: parse the canonical path CLI output flags (`-o`, `--output`,
  `-ovalue`, and `--output=value`) without initializing `Getopt::Long`.
  Noncanonical syntax, including abbreviations, still uses the compatibility
  parser. Red-first Docker tests cover both paths, argument preservation, and
  exact JSON output parity. An in-process benchmark measured 130.4 ms per
  100,000 fast parses versus 1,604.1 ms through `Getopt::Long` (about 12.3x
  for this isolated parse workload). A paired 20-cycle full-command benchmark
  returned identical 981-byte JSON and measured 67.578 ms versus 72.113 ms
  through the compatibility parser (about 1.07x); the all-routine 50x
  objective remains open.
- Problem 48: load `Getopt::Long` only when a path verb parses options. The
  `path project-root` route no longer pays its module initialization cost; a
  red-first Docker subprocess test showed it loaded before the change and
  absent after. The lazy-load and path CLI suites passed 57 tests. An
  alternating 25-run process benchmark measured 28.863 ms for the lazy path
  and 32.937 ms with `Getopt::Long` preloaded (about 1.14x). A cumulative
  20-cycle ABBA comparison of project-root dispatch against the prior
  Config/FileRegistry construction and eager option-parser setup measured
  26.852 ms versus 35.489 ms with exact output parity (about 1.32x). This is a
  command-specific gain, not the requested application-wide 50x result.
- Problem 48: defer `Config` and `FileRegistry` imports from the path CLI until
  the selected verb needs configured aliases. `path project-root` and `path
  locate` now avoid those modules; a red-first Docker subprocess probe showed
  both modules loaded before the change and neither loaded after the change.
  The focused lazy-load and path command suites passed 55 tests. A paired
  25-run process benchmark measured 30.372 ms with lazy imports and 36.041 ms
  with both modules preloaded (about 1.19x); this is a measured improvement,
  not completion of the 50x objective.
- Problem 48: avoid loading hook-only modules on every dashboard command. The
  switchboard no longer imports the unused `Config` module or eagerly loads
  `IO::Handle`, `IO::Select`, `IPC::Open3`, and `Symbol`; hook execution loads
  its own dependencies on demand. Red-first Docker regressions failed on all
  five eager imports, then the focused lazy-load test and 1,029-assertion
  hook-heavy CLI smoke suite passed. A paired 25-run benchmark measured
  33.104 ms for the preloaded-module control and 31.520 ms for lazy imports
  (about 1.05x), a modest change that does not close Problem 48's 50x target.
- Problem 48: keep optional FFI dependencies optional at module-load time. The
  PBKDF2 adapter no longer imports `FFI::Platypus` or its buffer module during
  compilation; fresh interpreters without those recommendations can load the
  adapter and reach the tested Perl fallback. A red-first Docker regression
  reproduced the previous fatal `Can't locate FFI/Platypus.pm` error. The
  focused adapter now has 100% statement, branch, condition, and subroutine
  coverage.
- Problem 48: declare FFI::Platypus and FFI::CheckLib as optional runtime
  recommendations, matching the adapter's portable Perl fallback. If either
  FFI module or the FFI buffer module is absent, native acceleration is marked
  unavailable; unrelated module-load failures remain visible. Red-first Docker
  regressions cover metadata and all three missing-module cases.
- Problem 48: avoid resolving a runtime ancestry stop path once per parent
  directory. The walk lazily computes its canonical stop identity once and
  exits on exact path-string equality before filesystem canonicalization; a
  red-first Docker regression measured stop-path identity lookups falling from
  three to one for a three-level project-root fixture. The exact-root path still
  skips canonicalization. This is not evidence of a 50x end-to-end
  speedup.
- Problem 48: short-circuit path ancestry checks for identical nonempty path
  strings before `abs_path`; different spellings retain symlink-aware
  canonicalization. A red-first Docker regression checks the result and that
  canonicalization is skipped.
- Problem 48: fix the standalone PSGI bootstrap, which failed at startup because
  its prompt renderer had no indicator store. The bootstrap now shares one
  `IndicatorStore` with `Prompt`; a Docker regression loads the actual PSGI
  app and verifies its `/system/status` response.
- Problem 48: reuse the state-root account name for an unchanged environment
  tuple, avoiding repeated NSS lookups in minimal environments while detecting
  changes to account-name environment overrides.
- Problem 48: stop rewriting identical runtime-root metadata on every lookup;
  verify ownership, type, mode, and content first, repair missing or stale
  metadata, and reject symbolic-link metadata paths.
- Problem 46 follow-up: the Docker workspace service inherited a POSIX locale,
  causing tmux to render UTF-8 prompt/status icons as underscores. The
  final Docker Compose handoff sets `LC_CTYPE=C.UTF-8` for the tmux client and
  newly started server, preserving the user's broader `LANG`. Ordinary
  workspace and compatibility ticket environment builders do not override the
  locale. A red-first Docker regression verifies this scope and the exact
  Compose argv; a real tmux replay confirms icons render after attachment,
  including to an existing C-locale server.
- Problem 48: use OpenSSL's native PBKDF2-HMAC-SHA256 through FFI for the
  measured helper-authentication hot path, retaining the existing Digest::SHA
  path when native crypto is unavailable or input byte semantics require it.
- Problem 48: defer Pod::Usage loading on lightweight command paths; profiling
  shows it is loaded only when usage rendering is required.
- Problem 48: keep the `version` fast path from loading Platform, InternalCLI,
  Handle, or FileRegistry; NYTProf measured 35.114 ms median versus the 5.88
  baseline of 56.7 ms (about 1.62x, not the requested 50x).
- Problem 48: load the distribution version from a minimal metadata module and
  defer Platform dependencies in PathRegistry and InternalCLI until needed.
- Problem 48: avoid spawning `pwd` for current-directory lookups when the
  absolute `PWD` matches the current directory's device and inode; keep the
  original `Cwd::cwd` fallback and preserve logical symlink paths.
- Problem 48: reduce the 15-run `dashboard version` median from 35.114 ms to
  32.287 ms after the verified-PWD change (1.76x versus 5.88 baseline overall;
  still short of the 50x objective).
- Problem 48: build `dashboard paths`' aggregate inventory from one resolved
  state root, avoiding two repeated runtime metadata writes; avoid loading
  Platform for PathRegistry's guarded passwd fallback. Latest 15-run Docker
  medians: version 31.486 ms, paths 71.309 ms, ps1 83.641 ms. These are about
  1.80x, 1.31x, and 1.31x versus their recorded 5.88 baselines, not 50x.
- Problem 48: exclude disposable temporary helper trees from coverage
  instrumentation while retaining full `lib/` measurement; the previous
  Docker gate passed 100.0% statement, branch, condition, and subroutine
  coverage.
- Problem 48: keep runtime-generated saved-Ajax and CODE sandpit statements
  from inflating PageRuntime.pm's static source map, and fail closed when a
  Devel::Cover warning appears beside a 100.0% Total row. The final Docker
  gate passed 262 files / 23,442 tests and all four coverage metrics at 100.0%.
- Problem 48: cover the final PathRegistry condition combinations for changed
  defined environment values and undefined metadata reads. The latest Docker
  gate passed 263 files / 23,488 tests at 100.0% statement, branch, condition,
  and subroutine coverage (46,834 detail rows; no stale annotations).
- Remove the unused HTTP::Tiny runtime prerequisite from all distribution
  manifests; a release-metadata regression test prevents it from returning.
- Confirm exact digest compatibility, 210,000 rounds, £ behavior, and explicit
  native buffer/call error handling in focused Docker tests.
- Evaluate MCE against startup profiling; do not parallelize collector
  readiness because it would change the tested start-and-verify fail-fast order.

## 5.88

- Problem 46 follow-up: use `docker compose up -d --no-build workspace` for
  default Docker workspace starts so Compose cannot implicitly build when the
  image is missing. Only `-d -C` requests a build, with output streamed live.
- Verify the checkout's outer workspace command passes the writable tmux socket
  location and attaches to the existing in-container tmux session.

## 5.87

- Problem 46 follow-up: explicitly pass `TMUX_TMPDIR=/dev/shm` to the inner
  workspace process, so tmux can create/connect to its socket even when the
  installed container command predates the `/tmp` permission fallback.
- Verify the exact outer Docker workspace command attaches to the inner tmux
  session while leaving the host alias unchanged.

## 5.86

- Problem 46: do not build a stopped Docker workspace by default; lowercase
  `-c -d` starts it with `up -d workspace`. Uppercase `-C` opts into a cached
  build and streams Compose progress live.
- Reuse a running workspace even with `-C`; preserve container state.
- Keep tmux interactive in Docker, with a writable socket fallback when the
  container's `/tmp` bind mount is not writable.
- Add regression coverage for the option parser, help/completion, startup
  command order, live build output, and container tmux attach behavior.

## 5.85

- Problem 46: allocate a real TTY for the Docker workspace's final Compose
  exec and pass its streams through directly, so tmux attaches interactively.
- When `/tmp` is not writable inside the container, use `/dev/shm` for tmux's
  socket via `TMUX_TMPDIR`; repeat that selection for subsequent workspace
  commands so they find the same session.

## 5.84

- Problem 47: prevent the multi-platform GitHub image build from repeating the
  full 23,000+ test suite under QEMU per architecture, which caused the 120
  minute workflow timeout. The complete repository gates remain required, and
  the newly built distribution is still installed into the runtime image.

## 5.83

- Problem 46: reuse a running workspace container without rebuilding it; when
  stopped, use cached `up -d --build`, and stop safely if its state is unknown.

## 5.82

- Problem 46 regression: keep the host path alias unchanged when the Docker
  workspace registers its `/workspace` mapping; use an owner-only additive
  `/dev/shm` config overlay and reject symlinked overlay directories.
- Problem 47: pin the Ubuntu base image by its multi-platform manifest digest,
  completing the Scorecard pinned-container dependency finding.

## 5.81

- Problem 47: build Docker Hub images from the latest master checkout, then
  replace the bootstrap MetaCPAN package with the fresh tested Dist::Zilla
  archive; publish version and latest tags for Linux amd64/arm64.

## 5.80

- Finalize Problem 46's packaged verification record: the 5.79 archive passed
  a blank-container `cpanm` install with tests enabled, and the 5.79 image
  reports the matching version. Record remaining repository-level Scorecard
  governance gates separately from the feature implementation.

## 5.79

- Reissue Problem 46's distribution so the completed status and report are
  included in the archive after the 5.78 image version was already recorded.
  No runtime behavior changed from 5.78.

## 5.78

- Problem 46: add Docker mode to `d2 workspace -c <alias>` through `-d` or
  `--docker`, preserving the standard local tmux flow when Docker is omitted.
- Run Compose startup, container alias registration, and inner workspace in
  order; stop at any failed step, with setup guidance when the `workspace`
  service cannot start.
- Document Docker workspace requirements and add command-sequence, failure,
  help, and shell-completion regression tests.

## 5.77

- Finalize Problem 45's packaged report after successful 5.76 image help/version
  checks and blank-container `cpanm` distribution/integration verification.
- Keep the tarball's documented completion state aligned with the verified
  runtime behavior; no runtime behavior changed from 5.76.

## 5.76

- Problem 45: support Docker-style `-t` timestamps and `-f` follow mode for
  web, collector, named-collector, and mixed logs, composable with both
  `--tail N` and `--tail=N` forms.
- Preserve persisted collector run timestamps; stamp raw web log lines at read
  time because their file format has no stored per-line event timestamps.
- Update the public logs help and `serve logs` parsing, with coverage for
  append following, truncation, mixed streams, flags, and error cases.

## 5.75

- Finalize Problem 45's package and image using a fresh version after the
  5.74 image version was already consumed; the implementation is unchanged.

## 5.74

- Problem 45: add `--tail N` and `--tail=N` to the top-level dashboard log
  commands, including the combined output, web scope, and collector scopes.
- Keep `-n N` compatible, allow zero lines, and reject negative or malformed
  limits with clear usage output.
- Add public CLI, parser, help-catalog, and packaging metadata regressions.

## 5.73

- Make the problem report index explicitly cover Problems 1–44 in numeric order;
  record Problem 39 as unassigned instead of leaving an unexplained gap.
- Mark the October 3 problem-report introduction as a historical snapshot and
  clarify that later release entries supersede it.
- Add a release-metadata test that guards numbered problem-report coverage.
- Exclude generated terminal transcript logs from Dist::Zilla archives and
  guard that packaging rule with the release-metadata test.

## 5.71

- Problem 43: scope Compose skill `.env` interpolation to the selected service
  instead of letting an unrelated skill service overwrite a colliding key.
- Keep deferred service inference and all-effective-service environment
  behavior for operations without a matching service selection.
- Add sequential foo/bar Docker regressions for merged-config and operation
  environments.

## 5.70

- Finalize Problem 44 after the image-build version guard marked 5.69 as used;
  rebuild the artifact and runtime image with the completed problem report.
- Repeat the blank-environment `cpanm` install/test and integration flow for
  the final 5.70 archive.

## 5.69

- Problem 44: preserve caller-exported environment values above home, skill,
  and project `.env`/`.env.pl` files across public command and skill dispatch.
- Keep unset values and normal layer precedence working; clear inaccurate
  env-audit provenance when a caller value wins.
- Add direct EnvLoader and isolated public-switchboard/skill CLI regression
  coverage, including restoration and visible errors on broken env files.
- Verify 258 Docker test files / 22,690 tests with 100.0% statement, branch,
  condition, and subroutine coverage, plus the 459-test web/security trio.
- Pass 7/7 CPANTS kwalitee indicators and all 348 POD syntax checks; build
  the 5.69 tarball and image, confirm the image reports 5.69, and complete the
  blank-container `cpanm` installation and installed-runtime integration.

## 5.68

- Problem 42: load home runtime `.env` and `.env.pl` files as defaults before
  skill-root and skill-CLI env files, allowing skill settings to override home
  values while preserving final precedence for deeper project runtime layers.
- Add regression coverage for the captured home-versus-skill overwrite and for
  project runtime values remaining the deepest override.

## 5.67

- Problem 41: remove the built-in Docker indicator and executable availability
  probe. Docker status is now shown only through an explicitly configured
  collector.
- Clean up only persisted records that exactly match the former core Docker
  indicator signature; preserve customized and collector-managed indicators
  named `docker`.
- Add regression coverage proving core refresh does not probe for Docker and
  does not recreate its indicator.

## 5.65

- Problem 40 follow-up: when no conventional project Compose file exists, treat
  an explicit leading `-f`/`--file` input as the base and defer runtime service
  discovery until Docker Compose resolves its service map.
- Add regression coverage proving runtime service folders and skill
  environment are not preloaded before that explicit base config succeeds.
- Verify the complete 258-file Docker suite (22,609 tests) at 100.0% across all
  four coverage metrics.
- Build the 5.65 tarball and runtime image; verify `dashboard version` reports
  5.65 and the tarball passes 100% CPANTS kwalitee.
- Install the tarball with `cpanm` (without `--notest`) in a blank Docker
  environment and pass the complete installed-runtime integration script.
- Pass the source POD syntax gate for all 348 discovered Perl files.

## 5.64

- Problem 40: run the base `docker compose config` before discovering isolated
  service overlays. Use only its resolved service names, preserve explicit
  Compose file/project-directory arguments, honor layered disabled/development
  markers, and reject path-shaped service names before runtime lookup.
- Add hermetic Docker regression coverage for the base-config selection order,
  nested skill overlays, CLI-only service names, explicit-file-only bases,
  native Compose help, and malformed config/argument/materialization failures.
- Verify 258 test files / 22,615 tests and 100.0% coverage for statements,
  branches, conditions, and subroutines; the focused web-security trio passes
  all 459 tests.

## 5.63

- Finalized Problem 38's config-first release as a distinct version after the
  image build guard rejected reuse of 5.62; the generated README and all
  module versions now match the package.

## 5.62

- Completed Problem 38's config-first verification: all Compose verbs now have
  recorded Docker coverage proving the effective base plus overlays are
  materialized before the requested operation.
- Recorded successful full coverage, release image version, and blank-container
  tarball installation/integration results.

## 5.61

- Fixed the remaining Problem 38 failure before materialization: local base
  YAML is read as raw bytes and a normalized in-memory copy is used for service
  discovery. The original source file remains unchanged; regression coverage
  verifies the captured materialized config is UTF-8 before an operation uses
  it.

## 5.60

- Rebuilt the Problem 38 release with the completed problem report included and
  all Perl module versions aligned at 5.60.

## 5.59

- Fixed the D2 image version-shadowing follow-up: the release tarball is
  installed into `/root/perl5`, which is the runtime-first Perl library, rather
  than only into the system library. A fresh image now uses the same version it
  was built from. Checkout test coverage verifies the local image recipe when
  present; the ignored operator recipe is intentionally absent from tarballs.

## 5.58

- Problem 38 follow-up: Docker Compose operations no longer skip config
  materialization when the resolver found no explicit layered files. Compose's
  automatically discovered base config is materialized first, and the requested
  operation then runs against the generated file. Non-Compose commands retain
  direct execution. A container regression test verifies the two-step flow.

## 5.57

- Fixed Problem 38: normalize captured merged Docker Compose YAML to valid
  UTF-8 before writing the temporary file. Valid UTF-8 sequences are preserved;
  isolated Windows-1252 bytes are converted, and undefined octets become the
  Unicode replacement character. Regression coverage verifies both YAML
  parsing and the shared `config`, `up`, `down`, `build`, `ps`, and `logs` path.

## 5.56

- Fixed Problem 37: cron collectors awaiting their next scheduled run are no
  longer considered stalled based on an old `last_completed_at` value. The
  watchdog checks the live scheduler-loop heartbeat instead, still recovering
  a cron loop whose heartbeat itself becomes stale.

## 5.55

- Problem 34 follow-up: make the public Docker Compose helper use the same
  layered-config materialization path as the resolver's operational runner.
  Compose operations now consume the merged file, retain the invocation
  project directory, and stream stdout/stderr until completion.

## 5.54

- Problem 34 follow-up: layered Compose `build`, `up`, `down`, and other
  operations retain the invocation project's directory after configuration
  materialization, so project identity and relative paths do not shift to the
  temporary merged file. Explicit `--project-directory` remains authoritative;
  malformed or undefined arguments fail visibly before Compose is invoked.

## 5.53

- Fixed Problems 25 and 36: preserve native help for dotted skill CLIs and
  merge shell-completion candidates across same-named project/home skills.
  Both fixes have regression coverage and a verified 5.53 image build.

## 5.52

- Fixed Problem 25 follow-up: dotted skill CLI help flags now bypass the
  internal `skills _exec` help parser and reach the skill-owned command.
- Fixed Problem 36: shell completion now merges unique commands from every
  active project/home layer of a same-named skill.

## 5.51

- Fixed Problem 25 follow-up: dotted skill CLI help flags now bypass the
  internal `skills _exec` help parser and reach the skill-owned command.

## 5.50

- Problem 35: configure `Dist::Zilla::Plugin::UploadToCPAN` as the explicit PAUSE releaser
  required by `dzil release`; keep credentials external to the repository and
  add a regression assertion.

## 5.49

- Problems 12, 32, 33, and 34: complete the tracked delivery evidence for the
  already verified behavior, including the successful blank-environment
  package integration run.

## 5.48

- Problem 12 follow-up: map dotted workspace references to tmux's underscore-
  normalized session names, verify session ownership, and safely confirm
  duplicate-creation races before reusing a session.
- Problem 32: separate command and path alias completion and avoid recursive
  directory walks for each `cdr` completion step.
- Problem 33: add an explicit regression proving unknown initial `cdr` words
  remain search terms for navigation and completion.
- Problem 34: scope automatic Compose service discovery to the local Compose
  project's declared services while preserving explicit service selection.

## 5.47

- Problem 34: use a local Compose file as the invocation project's base and
  scope automatic runtime overlays to its declared service names. Explicit
  service selectors remain opt-in; no-local-file discovery is unchanged.
- Problem 33 regression guard: prove an unknown first `cdr` token remains a
  search term in both navigation and later-argument completion.
- Problem 12 follow-up: map dotted workspace references to tmux's normalized
  underscore session names, verify an existing session's `WORKSPACE_REF` to
  reject name collisions, and confirm duplicate-session races before reuse.
- Problem 32: separate path aliases from root command completion, expose them
  with existing sessions under `workspace`, and bound `cdr` completion to one
  directory level per entered term instead of recursively walking whole trees.

## 5.46

- Corrected the main manual to describe plain `cpanm` test execution and the
  installed `d2` version/delegation checks performed by blank-container
  integration verification.
- Released the final 5.46 artifact and image after that documentation update,
  preserving unique versioning.

## 5.45

- Strengthened the blank-environment tarball integration gate to verify the
  installed `d2` entrypoint reports the tarball version, delegates GNU grep
  help, and passes Docker Compose config/help arguments through unchanged.
- Added explicit Problem 31 regression evidence that new marker files are
  written under the selected home runtime and all active layer markers are
  removed by enable/disable commands.

## 5.44

- Fixed Problem 12: `dashboard workspace <skill>.<alias> -c` now resolves
  configured aliases and skill `lib/Folder.pm` methods at any nested skill
  depth. Configured aliases win collisions, and resolver errors remain visible.
- Fixed Problem 25: delegated help reaches its owning CLI, including
  `dashboard of grep --help`, `dashboard of --print grep --help`, and native
  Docker Compose help even when wrapper selectors precede Compose commands.
  Dashboard wrapper help remains available explicitly.
- Fixed Problem 30: collector `cron` expressions in `config.json` now accept
  standard five-field numbers, names, lists, ranges, and steps; calendar
  matching follows crontab day-of-month/day-of-week rules, malformed or missing
  schedules fail before a loop starts, and each matching minute runs once.
- Fixed Problem 31: Docker service disable and development markers are honored
  in every active `config/docker/<service>` layer. Enabling a service removes
  all `disabled.yml` markers; disabling development removes all `develop.yml`
  markers across those layers.
- Enabled an init reaper in the blank-install Compose service so packaged
  process-group tests do not mistake orphaned zombies for live descendants.

## 5.41

- Prevent Devel::Cover databases with both default and custom names from being
  gathered into the release tarball.

## 5.40

- Fixed Problem 27: `dashboard of grep -nr <pattern> <dir>` now searches file
  contents recursively and opens the unique matching files through the normal
  chooser. Grep receives an argument vector, not shell-evaluated text. Perl
  module names resolve across all existing directories in the process `@INC`.
- Fixed Problem 28: collector working directories now resolve configured path
  aliases and skill-qualified `lib/Folder.pm` aliases. Configured aliases remain
  authoritative when names collide with read-only skill aliases.

## 5.38

- Follow-up to Problem 26: retain `origin/<branch>` for symbolic and detached
  remote refs unless the corresponding local branch resolves to the exact same
  commit. In that one redundant-prefix case, show `<branch>`. Loose and packed
  local and remote refs are supported without following symlinked ref paths.

## 5.37

- Fixed Problem 26 in the shared `dashboard ps1` renderer: local branch names
  retain all slash-separated components, and `origin/<branch>` remains visible
  unless a same-named local branch points to the same commit.
  Symlinked origin-ref roots and packed-ref files are not followed. Because all
  generated shell adapters use this renderer, Bash, Zsh, sh, and PowerShell
  show the same label; shell-bootstrap tests now assert that each adapter calls
  the shared `dashboard ps1` command.

## 5.36

- Revisited Problem 7: nested skill `cli/__init__` entrypoints now run when the
  dotted command names the nested skill itself, at any depth. Explicit command
  files are checked first and the deepest available initializer wins.

## 5.35

- Added working help and TAB completion across the internal CLI surface.
  Command/action help, aliases, recognized flags, default API-list options,
  the direct `version` command, and global help now use one catalog. Global
  help is concise, and workspace option completion does not query tmux.
- Made the release metadata version check follow `dist.ini` instead of pinning
  the preceding release number.

## 5.34

- Completed Problem 24's Pod::Text security floor and isolated audit guard.
  Kept the CI workflow assertion in the checkout-only test so packaged tests
  do not expect the unshipped `.github` tree.
- Fixed saved bookmarks with a scheme-relative target such as
  `//example.com/x` failing with "Can't locate object method host via package
  URI::_generic"; the host and port are now read from an `http:` copy of the
  target. Brought `lib/` to 100.0 percent on all four Devel::Cover metrics
  (Problem 20).

## 5.33

- Fixed the isolated CPAN audit's Pod::Text security failure. Runtime metadata
  now requires podlators 6.1.1+, and the audit verifies that the fixed module is
  loaded from the scanned root before applying the exact advisory disposition.

## 5.32

- Corrected the Problem 21–23 report's historical release labels and recorded
  the actual post-push Scorecard result and remaining governance tasks.

## 5.31

- Corrected the Problem 21–23 delivery report so push, release, Docker image,
  and post-push Scorecard status are no longer marked pending or stale.

## 5.29

- Keep the shipped Problem 23 report aligned with the release gates completed
  for the archive and Docker image.

## 5.28

- Excluded stale generated `pax-output/` files from the source archive after
  package inspection found old compiled artifacts still being collected.

## 5.27

- Made the blank-environment outsider-browser check accept both Chromium's
  generic 401 page and `ERR_HTTP_RESPONSE_CODE_FAILURE`, while preserving
  checks that neither bootstrap guidance nor a login form leaks to outsiders.

## 5.26

- Removed the embedded PAX compiler and self-compilation integration, which
  added a second execution and release path. The dashboard now consistently
  runs its CLI through the active Perl interpreter; Docker regression tests
  guard the helper, module, command, and release-workflow boundary.
- Stabilized blank-container outsider-browser verification across Chromium's
  generic 401 error-page and HTTP-response-failure output forms while retaining
  explicit no-bootstrap-content assertions.

## 5.25

- Fixed standalone runtime-family expansion and payload mapping when modules
  have duplicate paths, compiled/excluded sources, or a PAX-owned `lib/` root.
  Eligible known paths stay authoritative, unexcluded copies remain available,
  and the launcher receives importable module paths. Docker regressions cover
  all three cases.
- Completed Problems 21 and 22 package validation after blank-container tests
  exposed the module-family and nested `lib/` payload defects.

## 5.23

- Fixed standalone runtime-family expansion re-adding a stale duplicate of a
  dependency after `_locate_module_runtime_file` had selected its known source
  path. Expansion now keeps the already-selected module path authoritative;
  Docker regression coverage exercises two copies at real module-relative
  paths. The blank-container test later exposed and prompted a follow-up fix
  for bundled PAX module paths in 5.25.

## 5.22

- Completed Problems 21 and 22 delivery verification. Both `.d2` and
  `.developer-dashboard` runtime roots participate together, and
  `ddfile.local` dependencies remain private to their owning skill. Stabilized
  the standalone-image source-path regression with a unique fixture namespace
  after a full packaged run exposed an unrelated module-family collision.
- Updated packaged-test compatibility for the current Chromium headless SSL
  diagnostic, and ran the release install/test gate in an init-enabled blank
  Docker container.

## 5.21

- Completed Problems 21 and 22 delivery regressions. The blank-container suite
  now runs with an init process so process-tree tests can verify orphan cleanup,
  and Chromium SSL checks accept the current headless certificate diagnostic as
  well as interstitial HTML. Packaged CI-trigger checks now skip explicitly
  because GitHub workflow files are not part of the distribution.

## 5.20

- Fixed mixed `.d2` and `.developer-dashboard` runtime roots masking each other.
  Both existing roots now participate at each home/project depth; the
  canonical `.developer-dashboard` root keeps same-depth lookup and write
  precedence. Regression coverage checks CLI, config, Docker, dashboard, skill,
  environment, and security-root discovery.
- Fixed installed-skill `ddfile.local` dependencies being sent through the
  runtime-wide installer and landing beside the owning skill. They now install
  into `<skill>/skills/<repo-name>/`, with traversal containment checks and
  recursion guards; ordinary `ddfile` dependencies remain runtime-wide.

## 5.18

- Fixed skill Dancer2 before-hook response headers being overwritten by
  dashboard defaults. Existing hook headers now override defaults and explicit
  backend headers retain final precedence. Documented the required `hook before`
  declaration and verified hook variables are readable from page and Ajax CODE.
  Confirmed skill `Dashboard.pm` top-level code is loaded once at server startup,
  while its request hooks run per request.

## 5.17

- Added bookmark `HEAD:` content and inject it into the rendered document's
  `<head>`. Parsing, canonical serialization, web rendering, and editor HTML
  highlighting support it; documentation warns that it is trusted raw HTML.

## 5.16

- Fixed skill-install progress falsely saying `ddfile` or `ddfile.local` was
  absent when the manifest existed but had no dependency installs to perform.
  A missing-file message is now used only when the manifest is actually absent.

## 5.15

- Fixed skill installs ignoring repository branch selection. Remote installs
  now accept `-b`/`--branch`; fresh installs try `master` then `main`, while
  reinstalls preserve the installed checkout's current branch unless explicitly
  overridden. Invalid/local/DD-file uses are rejected before replacing files.

## 5.14

- Fixed `d2 <skill>.` shell completion omitting skill path aliases. Completion
  now merges configured aliases with names returned by that skill's
  `Folder->__list__`, while loading only the specifically named skill module.

## 5.13

- Fixed skill-owned path aliases being invisible to `cdr` and `d2 paths` when
  they were implemented as `lib/Folder.pm` methods instead of config entries.
  Config aliases retain precedence, `Folder->__list__` contributes a
  list-context inventory without writing to the skill, and `d2 path add`
  continues to save overrides only in config.

## 5.12

- Fixed `d2 docker --help` and `dashboard docker --help` returning no output.
  The Docker helper now documents its Compose and service-management commands,
  recognizes `-h`, `help`, and a missing subcommand, and explicitly rejects
  unknown subcommands. Docker completion now includes `development` and offers
  `enable`/`disable` after it.

## 5.11

- Fixed skill dashboard CODE execution and saved skill Ajax subprocesses so the
  skill root and inherited skill `.env`/`.env.pl` files apply to both paths,
  not only CLI commands. Page values are scoped to the current render and Ajax
  values to the child process; neither mutates the long-lived web worker
  environment. Added direct PageRuntime and `/app/<skill>/<page>` and
  `/ajax/<skill>/<file>` route regression coverage.

## 5.10

- Fixed DD-1054: `dashboard serve --foreground` hung indefinitely with zero
  output for any skill declaring a collector. `CollectorRunner::_find_running_loop`
  scanned every `/proc` PID and fell back to a per-pid `ps` subprocess spawn
  whenever a candidate's cmdline was readable-but-empty - the permanent shape
  of a kernel thread, not a race. On a host with hundreds of kernel threads
  that made startup cost one subprocess spawn per thread. Now skips such a
  candidate before ever calling `_read_process_title`.

## 5.09

- Fixed DD-1049: `_locate_module_runtime_file` returned the FIRST @INC/roots
  match for a module name, discarding the dependency scan's own known
  source_path for that module. An earlier @INC entry holding a
  stale/duplicate copy of the same module name could silently win and be
  bundled into a compiled standalone binary instead of the real copy. Now
  prefers a known source_path when the caller supplies one.

## 5.08

- Fixed DD-1040: compiled `dashboard init` crashed with an undefined-coderef
  error. Three self-recursive closures in StandaloneRuntime.pm's merge/collect
  helpers looked up their own recursion by bare sub name instead of the
  package-qualified name, so the lookup resolved against the wrong package and
  returned undef.

## 5.07

- Fixed Docker Compose service-file selection so `compose.yml` always remains
  the base file. `development.compose.yml` is appended only when the service
  has a `develop.yml` opt-in marker.
- Added `docker development enable|disable <service>` commands to write or
  remove that marker, with contained-path validation and explicit errors.
- A marker without its development compose file now resolves to the base file
  without error; tests cover source and PAX standalone runtime behavior.

## 5.06

- Skill dashboard CODE now puts the exact skill layer that supplied the page
  first in localized `@INC`, followed by other active skill layers.
- Skill Perl CLI scripts now receive the supplying skill's `lib/` as the first
  `@INC` path, even though the generic dashboard library is also passed with
  Perl's `-I` option. `PERL5LIB` likewise orders the command skill's `lib/`
  before inherited skill and shared local Perl libraries.
- Regression tests print the actual `@INC` inside dashboard CODE and a
  dispatched CLI Perl script and assert the respective owning skill `lib/`
  directory is first.
- Excluded and pruned generated `pax-output/` binaries and other excluded
  build/runtime trees from Dist::Zilla gathering. Git-ignored files can still
  sit in the source tree; `exclude_match` alone filters files after traversal,
  so pruning the excluded directories prevents expensive scans and accidental
  packaging.

## 5.05

- Fixed transient `Ajax` URL generation to encode rendered Template Toolkit
  code, not the original template source. `data => { args => 123 }` now renders
  `my $foobar = [% args %];` as `my $foobar = 123;` before tokenization.
- Added a regression test for the transient encoded payload and documented the
  behavior for transient URLs and saved Ajax files.

## 5.04

- **DD-1059:** the v5.03 release (edab2938, DD-1051) shipped
  `t/226-pax-paxfile-parser.t` without its required full-POD-DOC block -
  the fix existed only as an uncommitted working-tree edit in the shared
  main checkout when DD-1051's own git-gate work built on top of my merge
  commit and pushed before I committed it. Master's own t/15 gate was
  broken (8 failing subtests) between edab2938 and the fix commit
  (593dc904). Root cause: two tickets' git-gate work sharing one
  uncommitted-work-visible checkout directory - see DD-1070 for the
  related docker.images.build staleness this same race exposed.

## 5.03

- **Problem 15:** `Local::BoundedCommand::run_bounded` (t/152's test harness)
  killed a backgrounded grandchild but never reaped it once its immediate
  parent died, leaving a permanent zombie inside any container run without an
  init that reaps orphans - exactly the shape this project's own gate
  containers run in. It now declares itself a Linux/x86_64 subreaper before
  forking and sweeps for the orphan on both its TERM and KILL exit paths.
  (DD-1051)

## 5.02

- **DD-1059:** `lib/Developer/Dashboard/Pax/Paxfile.pm` had only 11.5 percent
  Devel::Cover coverage (real CI job 107060018763, run 35823444473) - no
  dedicated test file existed for its paxfile.yml parser, so only the
  package/use lines had ever run. Added `t/226-pax-paxfile-parser.t`,
  bringing it to 100.0 percent on all four metrics.

## 5.01

- **Problem 12:** `dashboard workspace` now resolves bare registered aliases,
  including skill-qualified aliases such as `bar.foo`, and starts the tmux
  session in the resolved directory without requiring `-c`.
- **Problem 13:** Page CODE blocks automatically import the namespaced
  `Developer::Dashboard::DataHelper` JSON functions, so authors do not need to
  repeat the import in each block.
- **Problem 14:** Web startup discovers active skills' `lib/Dashboard.pm`
  extensions, loads their routes/settings into the shared Dancer2 app, and
  enforces the dashboard authorization gate for added routes.
- Release packaging excludes the generated `t/tmp-sow03/` PAX test outputs;
  `GatherDir` had included an ELF executable and `AutoPrereqs` failed decoding
  it as UTF-8.
- Inline `env` and `Developer::Dashboard::Handle::Proxy` packages are now
  excluded from package-index metadata because they intentionally live inside
  other modules rather than standalone `.pm` files.
- Added regression coverage and operator documentation for Problems 12–14.

## 5.00

- Synchronized the release metadata, module versions, POD, and generated
  README for the 5.00 distribution.

## 4.99

- The all-metric coverage workflow test now skips explicitly in release
  tarballs that do not contain the source checkout's `.github/` directory.

## 4.98

- Release tarball test runs now skip source-checkout-only workflow, security,
  audit, and metadata gates when their intentionally excluded inputs are absent.
- The UTF-8 PAX regression test now declares its POD encoding, keeping the
  packaged POD syntax gate clean.
- The coverage gate no longer emits uninitialized-value warnings when run from
  an installed tarball without checkout metadata.

## 4.97

- Skill command scripts can now load modules shipped under their skill's
  `lib/` directory because skill lib roots are added to the managed
  `PERL5LIB`.
- Skill dashboard `CODE` sections can now `use` modules from the owning
  skill's `lib/` directory through a scoped `@INC` update.
- Skill command env loading now includes participating `cli/.env` files, then
  applies the invocation cwd `.env` last so local project values can override
  skill defaults.
- `d2` now loads the invocation cwd `.env` even when it is run from a directory
  outside the user's home or detected project root.
- Shell completion now exposes a skill `cli/__init__` command as the bare skill
  name instead of `skill.__init__`.
- The confusing public `ticket` helper alias has been removed; users should use
  `workspace`.
- Multi-level nested skill commands are covered so `skill.child.grand.command`
  continues to resolve through repeated `skills/<name>` directories.
- Release tarball installs no longer fail on checkout-only GitHub workflow
  validation; the workflow test still runs in a source checkout and skips when
  `.github/` is absent from the intentionally trimmed release payload.

## 4.91

- Restored the saved `/app/<name>` bookmark forwarding contract from the
  saved URL bookmark handler: external HTTP(S) targets redirect with the
  incoming query, local routes continue through internal dispatch, and
  `<name>.selected.pos` selects one value from array parameters.
- Skill bookmark Template Toolkit includes now resolve both relative dashboard
  fragments and explicit `skills/<name>/dashboards/<file>` paths.
- Saved Ajax helpers now process `code` as a Template Toolkit template when
  `data => { ... }` is supplied before storing the executable handler.
- `dashboard init` and `d2 init` now keep dashboard-owned helpers under the
  private `cli/dd` namespace; user-owned files in the surrounding `cli`
  directory remain untouched.
- Nested skill commands such as `d2 foo.bar.bob` now receive the current
  DD-OOP runtime environment and the parent-to-leaf skill `.env`/`.env.pl`
  chain before `bob` executes.
- Raised the Dancer2 dependency floor to 2.2.0 to exclude newly reported
  vulnerable releases below that fixed range.


## 4.90

- **DD-1050**: standalone binaries crashed on `--help`/`jq` (and any
  subcommand reaching the real dispatcher) with `Can't locate lib.pm in
  @INC` - `_skip_dependency_module` wrongly excluded `lib` as a
  zero-runtime-footprint compiler pragma. `use lib LIST` is really
  `BEGIN { unshift(@INC, LIST) }`, a genuine runtime `import()` that
  needs `lib.pm` physically bundled, exactly like `overload` (DD-1022).
  Fixed by removing `lib` from the skip-list regex; `parent`, `base`,
  `constant`, `mro` and `if` remain on it, with no confirmed live crash
  for any of them.

## 4.89

- **DD-1052**: tmux ticket-status hook crashed on macOS zsh with a glob
  `NOMATCH` error - `_dd_apply_tmux_ticket_status` in
  `share/private-cli/_dashboard-core` referenced `status-format[N]`
  unquoted in its zsh/bash/sh blocks, and zsh treats an unquoted,
  unmatched glob-shaped token as a fatal error by default (unlike
  bash/sh). Fixed by quoting every occurrence in the POSIX-family
  blocks; the PowerShell block is unaffected (different
  argument-parsing model) and was left as-is.

## 4.88

- **DD-1029**: standalone compiled binaries crashed with `Can't locate
  overloading.pm in @INC` on most subcommands - `overload.pm`'s own
  internal implementation transitively requires `overloading.pm` (a
  distinct, similarly-named sibling module), several hops deep inside
  Perl core rather than directly `use`'d by our own code, so dependency
  discovery never saw it. Fixed by widening `_declared_modules`'s
  no-Module regex; functional fix shipped in `d79cc09b` (no version bump
  at the time, corrected here per the ticket-level version gate).

## 4.87

- **DD-1035 follow-up**: v4.86's own fix broke `t/183`'s "self-built pax
  runs without source checkout in its working directory" - caught by real
  GitHub Actions CI. The exclusion fix in v4.86 correctly stopped
  `hybrid_compiled_pcu_v1` dependencies from bundling via the normal path
  (why a force-include pass was needed), but also correctly stopped
  `bundled_pure_perl`/`bundled_xs` dependencies living under the same
  excluded root (e.g. `Developer::Dashboard::Pax::CLI` when `pax` compiles
  itself) - and nothing was force-including those. Widened the
  force-include condition to cover any dependency under
  `$PAX_OWN_LIB_ROOT`, regardless of packaging class.

## 4.86

- **DD-1035**: a compiled PAX standalone binary could crash with `Can't
  locate Developer/Dashboard/SeedSync.pm in @INC` on `--help`/`jq` (any
  subcommand reaching a `hybrid_compiled_pcu_v1`-packaged dependency) -
  confirmed live on two real GitHub Actions PAX Release runs. Root cause:
  `StandaloneImage.pm`'s `$PAX_OWN_LIB_ROOT` exclusion was silently inert
  (missing `abs_path()` around an unresolved `catdir(...,updir,updir,updir)`
  string), and the separate force-include mechanism for hybrid
  dependencies only ever protected an already-selected file from
  exclusion, never added one the normal selection missed. Fixed both
  together. Never reproducible locally - every host this ticket touched
  happened to mask the gap with a stray installed copy of this project's
  own package somewhere on `@INC`.

## 4.85

- **DD-1010**: `bin/dashboard`'s self-compile mechanism (DD-882) resolved a
  PAX cache hit but discarded it rather than exec'ing it, left disabled
  since DD-905/DD-930 found real compiled-binary defects. Both root causes
  had since shipped (DD-922, and DD-930's own fix), but the exec call
  itself was never added back. Now execs a resolved hit via
  `_exec_switchboard_command()`, the same mechanism the `ps1` allowlist
  already used, with the anti-infinite-loop guard set immediately before
  the exec call. Verified with a full container suite run (9 pre-existing
  environmental failures found, none caused by this change) and real
  timing measurements (cold compile 86.8s, warm self-exec 129-138ms, the
  bare compiled binary 2-4ms).

## 4.84

- **DD-1021**: `t/09-runtime-manager.t` test 202 stubbed `capture()` to
  fake `ss` output but never stubbed `command_in_path()`, so on a
  container with no real `ss` binary the code under test silently took
  the lsof/proc fallback instead, routing around the mock entirely.
  `t/105-web-app-coverage-2.t` test 382 asserted a chmod-0000 file is
  404-unreadable, false under root (a real capability, not a `-r` stat
  lie). Fixed with an attempt-based skip matching `t/78`'s established
  pattern.
- **DD-1044**: `EnvLoader::_load_env_pl_file`'s audit recording relied
  purely on a before/after `%ENV` value diff, so a `.env.pl` assigning
  `$ENV{KEY}` to the value it already had was silently never recorded.
  A new `_env_pl_assigned_keys()` statically scans the file's own
  source for literal assignment targets and unions that set with the
  existing diff.
- **DD-1009**: `Pax::ArtifactCache::write_artifact` truncated its
  cache-metadata JSON to zero bytes on `open`, well before the content
  was written - the same defect class already fixed in DD-989 and
  DD-1003. Fixed with the same temp-path-then-rename pattern.
- **DD-1023**: `release-github.yml` and `test.yml` were missing an
  explicit `binutils` install step, so `t/183`'s self-hosted pax-build
  scenarios failed with `cc: fatal error: cannot execute 'as'` on a
  runner where it wasn't already present.


## 4.83

- **DD-1015**: wired a real Windows amd64 PAX build into
  `pax-release.yml`, replacing the `echo TODO` placeholder. MinGW-w64
  ships real GNU binutils, so `StandaloneImage.pm`'s compiler probe now
  detects either ELF (Linux) or COFF (Windows/MinGW) object format
  from a real compiled probe and dispatches to the matching objcopy
  target table (`pe-x86-64` for amd64). `windows-arm64` stays a
  placeholder - binutils' PE-ARM64 objcopy target name was not
  confirmed against the real tool, and this project's rule against
  unverified specific claims means the code dies with a clear message
  rather than guessing a target name.
- **DD-1025**: the GitHub Release page only ever attached the source
  distribution tarball (`Developer-Dashboard-X.XX.tar.gz` and its
  `.sha256`/`.asc`/provenance files) - the compiled PAX standalone
  binaries built by `pax-release.yml` existed only as ephemeral GitHub
  Actions workflow-run artifacts, never attached to the release page,
  not discoverable there, and subject to the default 90-day artifact
  expiry unlike release assets. Fixed by making `pax-release.yml`
  callable as a reusable workflow (`workflow_call`) and adding it as a
  sibling job in `release-github.yml`, with a new `attach-pax-binaries`
  job that downloads its build outputs and uploads each to the release
  via `gh release upload` once both the release and the binaries
  exist.


## 4.82

- **DD-1022**: `StandaloneImage.pm::_skip_dependency_module` wrongly
  treated `overload` as a compile-time-only pragma safe to omit from a
  standalone binary's bundled runtime payload, the same category as
  strict/warnings/utf8/etc. `overload` is not compile-time-only - it
  installs real subroutines (STRINGIFY/NUMIFY/etc) invoked later, at
  runtime, whenever the overloaded object is stringified or numified.
  Confirmed live by downloading a real GitHub Actions CI artifact and
  running it in a fresh container with no host Perl reachable:
  `File::Temp` (bundled because `Capture::Tiny` depends on it) itself
  does `use overload '""' => 'STRINGIFY', '0+' => 'NUMIFY', fallback
  => 1;`, so any subcommand whose code path reached
  `File::Temp`/`Capture::Tiny` crashed at `BEGIN` time. Shipped
  undetected in v4.78/v4.79 because the release smoke-check only ever
  ran `dashboard version`, whose own code path never touches
  `File::Temp`. Fixed by removing `overload` from the skip list.


## 4.81

- **DD-1020** (real fix for t/183, misdiagnosed as DD-1023): the
  compiler probe `_objcopy_target_for_compiler` ran before
  `_compile_launcher`'s own `local $ENV{PATH} = $tool_path` restoration
  was applied. t/183's self-hosted pax-build scenarios deliberately run
  a compiled pax binary under `env -i PATH=/nonexistent` to prove true
  standalone execution needs no external PATH - under that, `cc` could
  still be resolved via an absolute path but then could not find its
  own `as` subprocess, since gcc's internal assembler lookup needs a
  PATH to search regardless of how `cc` itself was resolved. Confirmed
  live: DD-1023's explicit `binutils` install changed nothing in real
  CI, because `as` was never actually missing. Fixed by moving the
  probe call inside the same PATH-restoration scope the objcopy/cc
  calls below it already use.


## 4.80

- **DD-1019**: t/159-dollar-question-guard-sweep.t and
  t/185-paxcache-lock-survives-benchmark-reentry.t were both failing for
  real, deterministic reasons, not CI-load timing flakiness as first
  assumed. t/159: a refactor moved CollectorRunner.pm's
  _terminate_command_process body into shared
  CommandRunner.pm::terminate_command_process without carrying its
  `local $?;` guard, leaving the DD-670 setter baseline stale and 2
  genuinely-unguarded $?-setters undetected; a 3rd flagged hit
  (CLI/Ask.pm::_docs_context) was a false positive from the sweep's
  backtick regex matching markdown code-spans inside a documentation
  heredoc, which _strip_comments had no concept of. t/185: DD-936 added
  an opt-in kill switch (DD_PAX=on) after this file was written, and it
  was never updated to opt in, so neither of its resolve() calls ever
  spawned a real background compile at all.
- **DD-1011**: t/43-explicit-coverage-qa.t asserted the pre-DD-1005
  usage strings for `dashboard file add`/`dashboard path add`, missing
  the `[-c|--create[=MODE]]` flag DD-1005 added.
- **DD-1023**: `release-github.yml` and `test.yml`'s `ubuntu-latest`
  runners lacked a working assembler (`as`), breaking t/183's
  self-hosted pax-build scenarios which compile real C code. Fixed by
  installing `binutils` explicitly, matching `pax-release.yml`'s own
  established toolchain-install precedent.


## 4.79

- **DD-1020** (correction, same day): the objcopy architecture detection
  shipped in v4.78 used `$Config{archname}` to decide the target, which
  is wrong for a cross-compiling build - confirmed live in real CI,
  `linux-i686` still failed at the launcher link
  (`i386:x86-64 architecture of input file 'code.pkg.o' is incompatible
  with i386 output`) even after v4.78 landed, because that runner
  cross-compiles 32-bit objects via a `-m32`-forcing `cc` wrapper on an
  ordinary native x86_64 Perl - `$Config{archname}` there never changes
  regardless of the actual compilation target. `linux-arm64` (a native
  aarch64 runner) genuinely was fixed by v4.78, confirmed by a real
  artifact produced in CI - only the i686 cross-compile case was wrong.
  Fixed by compiling a trivial probe object with the ACTUAL `cc` that
  will build the launcher and reading back its genuine ELF
  class/machine, rather than trusting any metadata about the host.


## 4.78

- **DD-1020**: `StandaloneImage.pm::_compile_launcher`'s 4 `objcopy` calls
  hardcoded `--output elf64-x86-64 --binary-architecture i386:x86-64`
  unconditionally, correct only on an x86_64 build host. Confirmed live
  in real CI (PAX Release workflow): `linux-arm64` failed with
  `objcopy code.pkg failed` (objcopy cannot honor an x86-64 spec on an
  aarch64 toolchain), `linux-i686` failed at the final link (a 32-bit/
  64-bit object mismatch, since objcopy kept emitting 64-bit x86-64
  objects while DD-1013's `-m32` `cc` wrapper linked for 32-bit).
  Fixed by adding `_objcopy_target_for_arch($archname)`, which detects
  the build host's real architecture from `$Config{archname}` and
  selects the correct objcopy `--output`/`--binary-architecture` pair
  from a table verified against the real objcopy/binutils tool (a fresh
  container with `binutils-aarch64-linux-gnu` installed, not an
  unverified web search) for x86_64/i686/i386/aarch64, dying with a
  clear message naming the unrecognized architecture otherwise.


## 4.77

- **DD-1018** (follow-up to v4.76's two fixes): a real GitHub Actions run
  of `pax-release.yml` surfaced a THIRD defect after the cpanm-bootstrap
  and node24-floor fixes landed. `share/private-cli/pax`'s own lib
  resolution (`use FindBin qw($Bin); use lib "$Bin/../lib";`) failed with
  `Can't locate Developer/Dashboard/Pax/CLI.pm in @INC`, even though
  `share/private-cli/../lib` was listed as a checked `@INC` entry in the
  error - despite every local invocation this session ran succeeding
  with the identical command. Root cause not fully diagnosed (FindBin's
  `$Bin`+cwd resolution appears to behave differently in the GitHub
  Actions runner environment); fixed by passing `-Ilib` explicitly on
  the `perl` invocation in the workflow's Linux build step, sidestepping
  the inference entirely rather than depending on it.
  `t/213-pax-release-perl-setup.t` extended to assert `-Ilib` is present.

## 4.76

- **DD-1018**: every real GitHub Actions run of `pax-release.yml`
  (added by DD-1012, wired for Linux by DD-1013) failed from the moment
  it first shipped, from two separate root causes found via live
  `gh run`/`gh api` verification. First: GitHub-hosted
  `ubuntu-latest`/`ubuntu-24.04-arm` runners do not ship `cpanm`
  pre-installed - "cpanm: command not found", exit 127, on all 3 Linux
  matrix jobs, every single run. Fixed by adding the same
  `shogo82148/actions-setup-perl` step `test.yml` already uses (identical
  pinned SHA, `perl-version: '5.44'`) before the `cpanm`-dependent step.
  Second: `actions/upload-artifact@ea165f8d65b6...` (v4.6.2) declares
  `node20`, below this project's enforced `node24` floor (DD-449: a
  `node20` action died under GitHub's forced `node24` upgrade and cost
  ten days of CI) - caught via "Audit action pin provenance" failing in
  real CI on DD-1017's own push, a second real defect in the same
  not-yet-landed file, fixed together rather than fragmenting into
  another ticket. Re-pinned to v7.0.1
  (`043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`), verified `node24`
  independently via `gh api` and `script/audit-action-pins` itself.
  `t/213-pax-release-perl-setup.t` proves the Perl-setup step's presence,
  ordering, and exact pin match against `test.yml` (RED-then-GREEN
  verified), plus a network-dependent block running
  `script/audit-action-pins` itself and asserting no pin reports below
  the node floor.

## 4.75

- **DD-1017** (found live while implementing DD-1013, part of epic
  DDE-006): `bin/d2`'s dispatch line -
  `exec { $^X } $^X, $dashboard, @ARGV;` - unconditionally invoked the
  perl interpreter against its sibling `dashboard` file, assuming
  `$dashboard` was always Perl source. This broke the moment
  `$dashboard` was itself a PAX-compiled standalone binary (an ELF/PE/
  Mach-O executable rather than Perl source) - reproduced live: a
  compiled `d2` binary crashed trying to run a compiled `dashboard`
  binary this way, since perl cannot parse an executable as source.
  Fixed by adding `_dashboard_is_compiled_binary`, which reads the
  sibling's first two bytes - a Perl script always opens with a `#!`
  shebang, a compiled binary never does - and branching the dispatch
  accordingly: `exec { $dashboard } $dashboard, @ARGV` directly for a
  compiled sibling, the existing `$^X`-routed exec unchanged for Perl
  source. Also corrected `bin/d2`'s own POD, which claimed the re-exec
  always happens "under the same Perl interpreter" - no longer
  universally true. `t/212-d2-dispatch-to-compiled-dashboard.t` proves
  both paths: a fast synthetic-file slice confirms d2 no longer attempts
  to perl-parse a non-shebang file (the exact pre-fix crash signature),
  and a real slice builds a genuine pax-compiled `dashboard` binary and
  confirms `d2` execs it directly with matching output.
  `t/49-d2-entrypoint.t` (17/17, unmodified) and `t/184-d2-self-compile.t`
  (12/12, including its DD-924 test which exercises a REAL compiled `d2`
  binary's own embedded copy of this exact fix) both confirmed
  unaffected.

## 4.74

- **DD-1013** (part of epic DDE-006, Multi-platform PAX CI): DD-1012's
  workflow skeleton left the linux-amd64/arm64/i686 matrix jobs with a
  placeholder build step only - nothing actually built or verified a
  Linux dashboard binary. Fixed by wiring each to a real
  `dashboard pax build --compact -o pax-output/dashboard bin/dashboard`
  invocation, mirroring `t/182-dashboard-self-compile.t`'s own proven
  local pattern (no `paxfile.yml` needed - the build tool auto-discovers
  dependencies). For linux-i686, `gcc-multilib`/`g++-multilib` are
  installed and a PATH-prepended wrapper forces `-m32`, since
  `StandaloneImage.pm`'s `_compile_launcher` hardcodes
  `_which('cc') || _which('gcc')` and never reads `$ENV{CC}` - a plain
  `CC=...` override is silently ignored. **A real bug was caught and fixed
  in that wrapper before landing**: its first version execed the bare
  name `cc` rather than an absolute path, so it resolved through the same
  `PATH` it had just been prepended to and called *itself* forever -
  observed live as an 18+ minute CPU-pegged runaway producing zero
  output. Fixed by resolving the real `cc`'s absolute path
  (`command -v cc`) before writing the wrapper. Each job then
  smoke-verifies its own binary - `file` confirms genuine 32-bit ELF for
  i686, and the binary's `version` output is compared byte-for-byte
  against the source-Perl CLI's, failing the job on any divergence.
  `t/211-pax-release-linux-build-wiring.t` proves the wiring and
  explicitly forbids the self-recursion regression class this ticket
  found. **d2 is deferred**: while implementing this ticket it was found
  that `bin/d2`'s re-exec line unconditionally shells through `perl` to
  invoke its sibling `dashboard`, with no handling for the case where
  that sibling is a compiled binary - filed as DD-1017, which blocks the
  d2 half of every platform-build ticket under DDE-006, not just this
  one.

## 4.73

- **DD-1012** (part of epic DDE-006, Multi-platform PAX CI): there was no
  GitHub Actions workflow wiring a push-to-master trigger to a
  multi-platform PAX build matrix. Added
  `.github/workflows/pax-release.yml`, modeled on `package-ghcr.yml`'s
  established convention (`on: push: branches:[master], tags:['v*'],
  workflow_dispatch`; concurrency group with `cancel-in-progress`;
  minimized permissions; action refs pinned to a full commit SHA with a
  version comment - one such SHA was initially guessed wrong and caught
  before landing by verifying it against `gh api
  repos/actions/upload-artifact/git/refs/tags/v4.6.2` directly). The
  matrix defines all 6 owner-confirmed platform/arch targets (mac arm64;
  linux arm64/amd64/i686; windows arm64/amd64), each with a placeholder
  build step and a distinct per-target `actions/upload-artifact` step, so
  sibling tickets (DD-1013 Linux, DD-1014 macOS, DD-1015 Windows, DD-1016
  the shared functional-verification harness) only need to replace the
  placeholder with a real `dashboard pax build` invocation.
  `t/210-pax-release-workflow-skeleton.t` proves the file is valid YAML,
  matches `package-ghcr.yml`'s trigger byte for byte (compared directly
  against the live file), and that the matrix/artifact wiring is correct.

## 4.72

- **DD-1002**: nine `lib/Developer/Dashboard/Pax/*.pm` modules each
  hand-rolled their own `JSON::XS->new->...->encode()` chain with
  independently drifted option sets (ascii/canonical/pretty/utf8
  combinations) instead of using the shared `Developer::Dashboard::JSON`
  wrapper the rest of the codebase already uses - nothing guarded against a
  tenth ad hoc call site being added, or an existing one silently changing
  its output encoding without anyone noticing. Fixed by adding
  `json_encode_with_options($value, %opts)` to `JSON.pm` and converting all
  nine call sites across `ArtifactCache.pm`, `AppImage.pm`, `AppServer.pm`,
  `CLI.pm`, `CodeUnitCompiler.pm` (6 sites), `ProfileGuidedAOT.pm`, and
  `StandaloneImage.pm`. `Pax/Capture.pm`'s isolated child-probe call site
  (piped via `open3($^X, '-', ...)` with no guaranteed `-I lib` path) is a
  documented, deliberate exception, left as a direct `JSON::XS->new` call.
  `t/208-json-centralization.t` proves the new function reproduces every
  option combination byte-identically to the pre-change chains, scans for
  any remaining undocumented direct `JSON::XS->new` construction site, and
  directly exercises the 4 changed files (`ArtifactCache`, `AppImage`,
  `AppServer`, `Pax::CLI`) that no other existing test in the suite loads at
  all - including a real forked UNIX-socket server for
  `AppServer::run_client` so the socket-connected branch is genuinely
  reached rather than falling through to its `_direct_exec` fallback.

## 4.71

- **DD-1006**: `Pax::StandaloneImage::_compile_launcher` ran a build eval
  (chdir into the build dir, run objcopy/cc) followed by a separate
  cwd-restore eval, and read `$@` once to build the `reason` field on
  both `not_built` failure paths. Perl resets `$@` at the start and on
  successful completion of every eval - so when the build eval died but
  the restore eval then succeeded (the ordinary case: the build fails,
  and restoring the working directory afterwards works fine), the
  restore eval's own successful completion silently erased the build
  eval's `$@` before `reason => $@` ever read it. A developer whose
  standalone-image build genuinely failed - objcopy exiting nonzero, no
  compiler found, the launcher compile itself failing - got back an
  empty `reason` string with no clue which step broke. Fixed by
  capturing `my $build_error = $@` immediately after the build eval
  returns and `my $restore_error = $@` immediately after the restore
  eval returns, each read before the other eval gets a chance to run and
  reset the shared `$@` - each failure path now reports its own
  correctly-captured diagnostic. `t/209-standaloneimage-build-error-capture.t`
  proves AC-1 (build failure survives a successful restore) end-to-end
  via a fake failing `objcopy` on `PATH`, an isolated mechanism-level
  test for AC-2 (restore failure isn't masked by a stale build-eval
  `$@`), and a SKIP-guarded happy-path check for AC-3.

## 4.70

- **DD-1005**: `d2 path add`/`d2 file add` had no way to mark an alias as
  lazily creatable - resolving an alias whose target was missing always
  failed with today's existing not-found handling, with no opt-in path to
  auto-create it. Fixed by adding a `-c`/`--create` flag (optional octal
  chmod mode, accepted bare or as `--create 0777`/`--create=0777`/`-c 0777`)
  that marks the saved alias, and a shared create-on-resolve check in
  `PathRegistry::resolve_dir`/`FileRegistry::resolve_file` - the ONE place
  this logic lives, so `cdr`, workspace routes, and every direct Perl
  caller of the resolver get it for free with no per-call-site duplication.
  A file alias's create-on-resolve creates only the target's PARENT
  directory (Q-184), leaving the file itself for the caller to write.
  Documented in `docs/path-and-file-alias-lazy-create.md`.

## 4.69

- **DD-1003**: `PaxCache::_run_compile_and_install` wrote its `md5_file`
  cache-freshness marker with a plain `open('>', $md5_file)` followed by a
  separate `print`/`close` - truncating the file to zero bytes the instant
  `open()` succeeded, well before the digest was actually written. An
  interruption in that window (SIGKILL, OOM, a host reboot mid-compile)
  left `md5_file` as a real, existing, zero-byte file sitting next to an
  already-valid, already-renamed binary - permanently wedging `resolve()`
  into treating a fresh cache entry as stale forever, burning a full PAX
  recompile on every future invocation for a binary that never actually
  needed rebuilding again. Fixed to match `bin_file`'s own already-atomic
  install two lines above it: write the digest to a sibling temp path,
  then `rename()` it onto `md5_file` - a reader can only ever observe the
  complete previous content or the complete new content, never a
  truncated state in between. `t/206-paxcache-md5-atomic-write.t` proves
  this directly via a real fork+SIGKILL race against the production
  `_run_compile_and_install` path with a 20MB payload (large enough to
  give the write a genuinely observable duration), confirmed RED against
  the unfixed code and GREEN against the fix.

## 4.68

- **DD-1004**: `d2 path add`/`d2 file add` always wrote into the flat
  global `config.json`, even for a dotted, skill-depth-prefixed alias name
  (e.g. `foo.bar.something`) - there was no write side at all for
  DD-977/978's read-only skill-alias qualification, and no resolver walked
  a skill's own nested `skills/` subdirectory. Fixed by adding
  `PathRegistry::nested_skill_dir_chain`/`nested_skill_entries`/
  `skill_config_write_location` and the matching `Config::save_skill_*`/
  `remove_skill_*`/`split_skill_alias_name` machinery, routed through new
  top-level `save_path_alias`/`save_file_alias`/`remove_path_alias`/
  `remove_file_alias` dispatchers. Per the owner's git-preservation
  correction (Q-182): the write never targets a skill's own file directly,
  at any depth, so a user's override always shadows that skill's shipped
  default without risking data loss on the skill's next `d2 skill install`/
  update. Documented in
  `docs/skill-depth-prefixed-alias-add-and-git-preservation-walk-up.md`.

## 4.67

- **DD-989**: fixed a symlink-clobber vulnerability in
  `Developer::Dashboard::IndicatorStore::set_indicator`. Its staging path
  used to be the bare literal `"$file.pending"` with no pid/time/counter
  uniquifier at all, and permissions were secured only AFTER the write -
  the exact write-then-secure anti-pattern already fixed six other times
  (DD-599/600/601/602/848/850), but worse: a fully predictable path,
  missed by both prior sweeps because neither searched for a
  pending-file writer with no uniquifier whatsoever. Live-reproduced: a
  symlink pre-planted at the predictable staging path let a local actor
  clobber an arbitrary victim file's content and leave the real
  `status.json` pointing at the victim afterward. Fixed by routing
  through the shared `Developer::Dashboard::PathRegistry::atomic_write_secure`
  helper via a new `_pending_indicator_file` staging-path helper (pid +
  time + a per-process monotonic counter), matching the pattern already
  used by `SessionStore.pm`/`Auth.pm`/`Collector.pm`/`CLI/Ask.pm`/`Zipper.pm`.
  Added `t/204-indicatorstore-pending-path-symlink.t`, a regression test
  that plants a symlink at the historical predictable path and asserts
  the victim file is untouched and the real indicator file ends up a
  regular file with correct content. Updated
  `docs/pending-file-staging-paths-across-the-codebase.md` to add
  IndicatorStore as the 7th migrated site. Filed DD-999 (pre-existing
  500-line module-size overage) and DD-1000 (unaudited lock-file symlink
  exposure, low severity) as separate, out-of-scope follow-ups found
  during this ticket's audits.

## 4.66

- **DD-993**: fixed a CI-only, warnings-FATAL build failure (`Prototype
  mismatch: sub Developer::Dashboard::RuntimeManager::sleep (;$) vs
  (;@)`) in `t/100-runtimemanager-coverage.t` and
  `t/106-runtimemanager-coverage-2.t`. `RuntimeManager.pm` imports its
  `sleep` from `Time::HiRes`, so `RuntimeManager::sleep` is an alias
  whose prototype is whatever the running Perl's `Time::HiRes` gives
  `sleep()` - `(;$)` on the Perl 5.44 GitHub Actions runner used
  (run 35292793810), `(;@)` on the Perl 5.40.1 this project's own
  `developer-dashboard:latest` Docker image bundles, which is exactly why
  the bug reproduced on CI and not locally. Both coverage files installed
  their test-only mock of `RuntimeManager::sleep` as a permanent
  (non-local) typeglob assignment guarded only by
  `no warnings 'redefine'`, which does not cover Perl's separate
  `prototype` warning category - confirmed even an unprototyped override
  still mismatches `(;$) vs none` once only `redefine` is silenced. Fixed
  by silencing both categories together
  (`no warnings qw(redefine prototype);`) and dropping the mock's own
  explicit prototype, matching the style already used by every other
  mock in the suite. Added `t/203-runtimemanager-sleep-mock-prototype.t`,
  a deterministic, Perl-version-independent regression test for the
  mechanism (reproduces it against a hand-declared prototype rather than
  the real `Time::HiRes`, so it cannot pass locally the way the original
  bug did), and a new system-scoped section in
  `docs/expected-warnings-in-tests.md` on overriding subs imported (not
  locally declared) from another module.

## 4.65

- **DD-941**: `t/15-release-metadata.t`'s retired-internal-wording gate
  correctly bans retired terms case-insensitively across shipped docs/POD,
  but FIXED_BUGS.md's
  own append-only `## 4.37` (DD-931) and `## 4.42` (DD-933) entries
  legitimately reference the real, current, shipping identifier
  `__PAX_RUNTIME_LEGACY_NAMESPACE__` and describe it in prose as a
  "legacy-namespace alias" - the `## 4.37` entry uses that phrase without
  the literal identifier present on the same line, so an identifier-only
  allow-list (as tested) did not close the gate. Escalated as Q-177/Q-179;
  the owner chose to widen the allow-list to the phrase itself (Q-179
  option A) rather than grandfather by content age or reword an already-
  tagged, append-only entry. Fixed by adding
  `_strip_legacy_namespace_mentions()` to `t/15-release-metadata.t`, which
  strips both `__PAX_RUNTIME_LEGACY_NAMESPACE__` and the phrase
  `legacy-namespace` (both case-insensitive) from a copy of the text
  immediately before the existing `\blegacy\b` check runs, for both the
  doc-path and POD-path loops. A genuinely retired bare mention of that
  same banned term anywhere else still fails the gate (verified with a
  disposable negative-case control). Documented system-wide in
  `docs/retired-internal-wording-allow-list.md`.

## 4.64

- **DD-926**: `pax build`'s intermediate build cache directory
  (`.pax-launcher-build`, derived in
  `Developer::Dashboard::Pax::StandaloneImage::_compile_launcher`) was a
  single literal path shared by every uid building against the same output
  parent directory - commonly bare `/tmp`. A root-owned build (e.g. from
  inside a `developer-dashboard:latest` container) left it owned root:root;
  every later non-root build sharing that output parent then failed
  outright with `Permission Denied`, and the failure did not self-clear
  (a non-root user cannot remove root-owned files without `sudo`).
  Namespaced the directory per invoking uid
  (`.pax-launcher-build-<uid>`, via a new `_pax_launcher_build_dir_name`
  helper) - the same technique `File::Temp` uses to avoid this exact
  shared-`/tmp` collision class - while same-uid repeated builds keep
  reusing the same per-uid path.

## 4.63

- **DD-986**: `CLI::Skills.pm` carried its own private `_render_table`/
  `_format_row`/`_plain_text`, left out of DD-773's consolidation of
  `Files.pm`/`Paths.pm`/`Which.pm` onto the shared
  `TableHelpers::render_table`. Grepping every real call site confirmed
  its ANSI-stripping behavior was never exercised (both content-producing
  helpers feeding cells return hardcoded plain text), so it was dead
  weight rather than a distinguishing behaviour. Migrated onto the shared
  helper, removed ~40 duplicated lines, verified byte-identical output.

## 4.62

- **DD-984**: `Developer::Dashboard.pm`'s "Layered Env Files" POD section -
  the natural place a reader would look for anything about `.env`/`.env.pl`
  loading - made zero mention of DD-979's `env->include`/`# include`
  feature, documented ~2500 lines later inside the unrelated `EMBEDDING IN
  PERL CODE` section with no cross-reference either way. Fixed by adding a
  short pointer paragraph in both directions.

## 4.61

- **DD-985**: `CLI::OpenFile`'s `_scope_relative_path_match` (the
  exact-match fast path for `dashboard of <scope> <pattern...>`)
  joined caller-supplied search-pattern tokens via
  `File::Spec->catfile` onto the resolved scope directory with no
  containment check - a `..` segment in the pattern escaped `$scope`
  entirely, so ordinary usage like `dashboard of myproject
  ../../.ssh id_rsa` could open or print any file readable by the
  invoking user (CWE-22 path traversal), with no special flag
  needed. Fixed by resolving through `_contained_cache_path`, the
  same lexical containment helper this project's DD-498 Zip Slip fix
  already established, rather than a second bespoke check. Verified
  RED-then-GREEN with a real secret file outside the scope directory:
  the traversal payload returned a genuine match before the fix and
  is rejected after. The regex-search fallback path (rooted at
  `$scope` via `File::Find`) was confirmed structurally
  non-vulnerable and left untouched.

## 4.60

- **DD-979**: while implementing the new `.env`/`.env.pl` skill include
  feature (`env->include(...)` / `# include <foo.bar>`), found that
  `EnvInclude::_resolve_targets`'s dot-split of the include spec, while
  structurally safe against a literal `..` token, still let a spec like
  `../..` survive as a bare `/` segment and reach
  `File::Spec->catdir` unvalidated - a path-traversal exposure. Fixed
  before landing with an explicit `_valid_segment()` defense-in-depth
  guard (rejects `.`, `..`, embedded `/`/`\`, control/NUL bytes,
  empty/undef); verified with a live traversal-payload test against a
  planted fixture outside the skills tree.

## 4.59

- **DD-978**: the parallel gap to DD-977 (4.58), for `file_aliases`
  instead of `path_aliases` - `Config::file_aliases()` only ever read
  the top-level project/global merged config key, so a skill's own
  `config/config.json` `file_aliases` block was completely invisible
  to `cdr`/`d2 paths`. Fixed by adding `Config::_skill_file_aliases()`,
  an exact parallel to `_skill_path_aliases()` (deliberately a separate
  helper rather than a shared one, to avoid destabilizing the
  already-shipped `path_aliases` behavior), merged into
  `file_aliases()`. Same skill-name qualification convention, same
  OOP-LAYERS-safe-by-construction merge behavior. Verified with 20 new
  tests in `t/93-config-coverage.t` and a live end-to-end docker probe.

## 4.58

- **DD-977**: `Config::path_aliases()` only ever read the top-level
  project/global merged config key, so a skill's own
  `config/config.json` `path_aliases` block was completely invisible
  to `cdr`/`d2 paths` - dead weight a skill author could write and
  nothing would ever read. Fixed by adding `Config::_skill_path_aliases()`,
  which walks installed skills' own config and qualifies each alias by
  skill name (`skill.alias`, mirroring `_skill_collectors`' established
  convention) unless already qualified. Verified this required no new
  merge logic: a skill's own config already merges recursively across
  every DD-OOP-LAYER it participates in via the existing
  `_skill_config_hash`/`_merge_hashes` recursion, since `path_aliases`
  is a plain `HASH` key rather than a named array. `file_aliases` has
  the identical gap and is tracked separately as DD-978.

## 4.57

- **DD-964**: `docs/pax-coverage-measurement.md`'s "What this does not
  yet cover" section cited DD-929 as tracking the follow-up work of
  wiring `t/182`/`t/183`/`t/184` into the coverage gate and driving
  `Pax/*.pm` to 100% coverage. DD-929 reached `done-not-released`
  (terminal) without doing that work, and no card existed to carry
  it - the same shape as this project's own disable-is-not-done rule,
  applied to a stale doc pointer. Fixed by filing DD-967 as the real
  open follow-up ticket and updating the doc to cite it.

## 4.56

- **DD-929**: `lib/Developer/Dashboard/Pax/*.pm` (~25-30 vendored files)
  was completely absent from every Devel::Cover coverage report - not low
  coverage, literally zero rows, since a PAX-compiled binary execs a
  bundled perl with its own extraction root spliced onto `PERL5LIB`
  before the exec, and Devel::Cover's default startup behavior silently
  ignores anything already present on `@INC` at that point (it snapshots
  `@INC` very early and treats it all as library code to skip). Fixed by
  adding `Developer::Dashboard::Pax::CoverageSelect`, which computes the
  binary's already-stable, content-addressed extraction root (from its
  own reported `source_hash` - `StandaloneImage.pm` was never actually
  unstable here, contrary to an earlier diagnosis) and builds the
  `Devel::Cover -select` pattern that overrides the default ignore.
  Verified live: a real PAX binary, built and run under the computed
  `PERL5OPT`, now genuinely collects coverage data instead of zero rows.

## 4.55

- **DD-958**: `Platform.pm`'s `resolve_runnable_file` (lines 183-184) and
  `command_argv_for_path` (line 226's guard / line 227's Windows fallback
  return) each carried an untested direction on both the forced-Windows
  side and its natural-Linux counterpart, with no uncoverable annotation
  either - a genuine gap in the "100.0 on every metric, always"
  discipline. Fixed by adding 4 test assertions to
  `t/84-platform-coverage.t`: 2 using the project's established
  `local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32'` override
  to force `is_windows()` true, 2 natural-Linux counterparts - the
  true/false coverage columns track the literal written condition
  (`!is_windows()` / `is_windows()`), not Devel::Cover's
  display-rewritten "unless" text, so both sides needed separate
  coverage. Platform.pm now 100.0 on all 4 Devel::Cover metrics.

## 4.54

- **DD-928**: `Zipper.pm`'s `load_saved_ajax_code` had no uncoverable
  annotation at all on its `open(...) or die` failure branch, leaving
  branch coverage at 98.3% despite its own dedicated test file passing -
  a real, silent gap in the standing "100.0 on every metric, always"
  discipline. Fixed with a correctly-polarized `# uncoverable branch
  true` (Devel::Cover rewrites `EXPR or STATEMENT` internally as
  `unless(EXPR){STATEMENT}`, so `true` is the rare failure path and
  `false` is the common success path - inverted from the naive reading).

## 4.51

- **DD-946**: two pre-existing, silently-broken `# uncoverable branch`
  annotations on `open(...) or return` constructs in
  `CLI/Ask.pm` (`_execute_grep_repo`, `_load_transcript`) had branch
  true/false backwards - Devel::Cover rewrites `X or Y` internally as
  `unless(X){Y}`, inverting the naive true/false reading, so the
  annotation excused the wrong (always-hit) side while the real rare
  path stayed genuinely uncovered. Masked by rounding (the file's total
  branch count was small enough that one unaccounted line still
  displayed 100.0) until DD-946's larger diff surfaced it. Fixed by
  swapping both annotations to `branch true`, confirmed via an isolated
  Devel::Cover probe before and after.
- **DD-946**: `_workspace_key`'s two textually-identical `!defined $x ||
  $x eq ''` fallback checks were tracked by Devel::Cover as two separate
  condition instances, and only one honored its `# uncoverable condition
  right` annotation even in an isolated reproduction with the real
  fallback value possibly undef - reproduced directly (two occurrences
  of one literal condition string in one sub trip this; a single
  occurrence does not). Fixed by restructuring both checks to call a
  shared `_blank()` helper, collapsing the duplicate condition instance
  into one Devel::Cover location.

## 4.43

- **DD-943**: t/15-release-metadata.t's `_perl_doc_paths()` walked `t/` for
  every `.pm`/`.pl`/`.t` file with no exclusion for `t/tmp-sow03/` - a
  scratch directory `t/183-pax-cli-build-run-contract.t` creates with
  deliberately minimal-POD fixture files to exercise the PAX build
  pipeline, and leaves on disk after its own run (cleaned only at its own
  START, by design). When t/183 ran before t/15 in the same `prove`
  process, t/15 incorrectly scanned those fixtures and failed ~25 subtests
  against files never meant to carry real project POD. Confirmed
  pre-existing (present in CI for the commit immediately before DD-933
  landed, not introduced by it). Fixed by mirroring an exclusion pattern
  already used elsewhere in the same file. Verified RED-then-GREEN with a
  new subtest creating a real stray fixture and confirming it's excluded.


## 4.42

- **DD-933**: CodeUnitCompiler.pm's dependency-discovery pass (which walks
  literal source text to decide a compiled entrypoint's compiled_packages
  closure) can miss a class referenced only inside a sub body the compiler
  special-cases and substitutes with a runtime op - the same shape DD-931
  fixed for EnvAudit. Confirmed hitting JSON (~53 call sites) and SeedSync
  (4 call sites) in StandaloneRuntime.pm, both called via the never-
  reliably-populated __PAX_RUNTIME_LEGACY_NAMESPACE__ alias from inside
  other special-cased ops - a compiled entrypoint whose closure had no
  other literal reference to either class would crash "Undefined
  subroutine" the first time such an op ran. Fixed by requiring both
  classes directly at file-load time and calling their real package names.
  Verified RED-then-GREEN with a new test (t/198) invoking the real op
  dispatcher directly, plus a full-suite Docker container run against a
  clean-master baseline confirming zero regressions.


## 4.39

- **DD-935**: `pax build` took 4.5+ minutes to compile a single file -
  `CodeUnitCompiler.pm`, the compiler's own ~13,000-line source,
  compiling itself - versus ~4 minutes for the other 112 files in the
  build combined. Root cause: `_extract_sub_body`/`_extract_sub_source`
  walked brace depth with a per-character `substr()` loop against the
  file's own large decoded source string, called multiple times per
  declared sub. Fixed by replacing the manual loop with a
  `\G`-anchored regex scan that lets the C regex engine skip
  non-brace characters natively. Verified: 1.4s -> 0.0005s per
  extraction call, 0.12s for the full self-compile (was a 2-minute-plus
  timeout). Also dropped the launcher's `cc` flag from `-O2` to `-O0`
  (no runtime benefit on a thin bootstrap stub, real compile-time cost).

## 4.37

- **DD-931**: a genuinely PAX-compiled `bin/dashboard` binary crashed with
  `Can't locate object method "record" via package
  "__PAX_RUNTIME_LEGACY_NAMESPACE__::EnvAudit"` whenever its env-loading
  runtime ops ran, because `EnvAudit` is never added to
  `CodeUnitCompiler`'s `compiled_packages` (its only literal source
  reference sits inside a sub whose entire body the compiler substitutes
  with a hardcoded op before its own dependency-discovery pass ever sees
  the call). Fixed by requiring `Developer::Dashboard::EnvAudit` directly
  in both runtime op implementations instead of going through the
  never-populated legacy-namespace alias. Root-causes DD-930's mitigation;
  `bin/dashboard`'s self-exec guard stays disabled pending DD-932/933/934,
  three further defects found while verifying this fix end to end.

## 4.32

- **DD-868/DD-870/DD-878**: `FileRegistry::resolve_file`, `PathRegistry::resolve_dir`,
  `File::_resolve_file` and `Folder::_resolve_path` all dispatched a
  caller-supplied alias name to ANY method the resolved object/class
  answered `can()` true for, not just an intended path getter. Fixed with a
  compile-time allowlist in each. DD-868/870 were confirmed reachable via
  `dashboard file resolve <name>`/`dashboard path resolve <name>`; DD-878's
  two instances one layer down were confirmed NOT reachable by any current
  caller, but fixed as defense-in-depth since `File`'s own POD documents
  dynamic dispatch as an intended public API pattern.
- **DD-874**: `Config.pm`'s `api_registry` merged the operator's own
  deepest-writable `api.json` layer BEFORE a skill's bundled API-key
  fragments, so an installed skill could silently replace or tombstone an
  operator-set key set via `dashboard api add`. Fixed by merging skill
  fragments first (lowest priority) and the operator's own layer last.

## 4.31

- **DD-770**: `.claude/tools/host-ready`'s foreign-process detector matched
  on command-line text, spoofable via Perl's `$0 = "..."` (verified live:
  `ps args`/`/proc/PID/cmdline`/`/proc/PID/comm` all read the same
  rewritten buffer). Fixed with a positive-only `/proc/PID/exe` veto that
  never turns "could not verify" into "excluded".
- **DD-771**: `/tmp/dd-gate-host.lock` being shared with the Tira project
  is deliberate (TKT-857), not a bug - corrected during this card's own
  research. Fixed the two real survivors: an unnamed lock holder in
  `run-suite`'s refusal, and a retry silently destroying a failed
  attempt's log.
- **DD-740**: `board-pulse`, `next-action` and `tira-bridge-run` each
  hardcoded the checkout's absolute path instead of sharing `.claude/
  tools/board`'s DD-545 `git --git-common-dir` resolution, so each failed
  run from a sandbox, a container, or a different checkout location.
- **DD-785**: seven `lib/` modules hand-rolled the same paths-registry
  constructor guard (four byte-identical). Extracted into
  `Developer::Dashboard::PathsRegistryArg`.
- **DD-767**: `t/100` and `t/103`'s empty-environ probe loops were bounded
  by a poll count (3000), not wall-clock time - DD-482 specified the
  wall-clock fix and it was never shipped. Fixed with a `Time::HiRes`
  60-second deadline and a state+cmdline diagnostic that no longer reports
  a zombie as "alive".

## 4.30

- **DD-764**: a stored session whose `expires_at` was absent, empty, or "0"
  was accepted as valid forever by `SessionStore::from_cookie` and skipped by
  `sweep_expired`, so the record was both immortal and uncollectable - while a
  malformed timestamp already failed closed, because `_iso8601_to_epoch`
  returns 0 for anything not matching its strict ISO-8601 pattern. Both
  truthiness guards are gone, so an absent expiry now compares the same way
  malformed input already did: the session is rejected and deleted on use, and
  the file is collected by the sweep. `create()` always writes `expires_at`,
  so reaching this needed a record written outside the product's own path - a
  hand-edit, a restore, or an older schema - making it a latent fail-open on a
  session bearer credential rather than an exploitable bug.
- **DD-737**: a collectors config entry carrying only a name and an interval
  (no `command` and no `code`) was forked into a loop worker anyway; that
  worker died on its first tick with "Collector <name> missing command or
  code" and on every tick after that, forever, without ever disabling itself,
  leaving an unreaped process behind each time it died on a host whose PID 1
  does not reap orphans. Reproduced in the project's container image, where
  two `dashboard restart` cycles left three or more defunct "dashboard
  collector" entries that later restarts never cleared. `start_loop` now runs
  the same command/code validation `_collector_source` already performed per
  tick, before writing a pidfile or forking, so a misconfigured collector
  fails immediately with that error and spawns no process.
- **DD-753**: `RuntimeManager` launched PowerShell by hardcoding the bare
  string `powershell` at four call sites, while `CollectorRunner` did the same
  job through a resolver that tries PATH under both spellings, then the
  SystemRoot install path, and names the missing executable when none
  resolves. On a Windows host where PowerShell is not on PATH, the collector
  said what was wrong and the dashboard runtime failed through `system()` into
  an empty capture, indistinguishable from a legitimately empty result. The
  resolver now lives once in `ProcessSupervision` and is used by both modules,
  so all four runtime call sites resolve PowerShell the same way, and each
  reports the missing executable in the shape its own contract requires - a
  status pair, a die, or an empty list. Verified on Linux only; no Windows
  guest was available, and the card records that platform verification as
  still owed.
- **DD-738**: `d2()`'s AUTOLOAD handled only a single word and shelled out
  immediately, returning a plain string, so a second method call on it -
  `d2()->collector->list` - died as a bareword class lookup. A bareword method
  now starts a lazy proxy that accumulates dotted segments at any depth,
  mirroring the CLI's own dotted dispatch, and nothing executes until the
  chain is terminated with a call: `d2()->foo->bar->()` runs
  `dashboard foo.bar`. An un-terminated chain is inert in boolean, numeric and
  string context and stringifies to something obviously non-executing ("d2
  proxy: foo.bar"), so a stray debug print cannot run a command; underscores
  in a segment are rewritten to hyphens, since a Perl method name cannot carry
  a hyphen and the hyphenated half of the CLI was otherwise unreachable
  through the chained form. INCOMPATIBLE CHANGE: this reaches the single-word form with it -
  `d2->doctor` now needs the trailing `->()` to execute - while `d2->run(...)`,
  which takes its words as separate arguments and passes them through
  verbatim, is unaffected.

## 4.29

- **DD-585/589/590/591/592/593**: six query functions across
  CollectorRunner.pm, IndicatorStore.pm, RuntimeManager.pm, ActionRunner.pm,
  SkillManager.pm (three functions) and PageRuntime.pm shelled out to check
  or reap a process and left Perl's global `$?` holding their own last
  subprocess's exit status after returning, without localizing `$?` at sub
  entry. A caller reading bare `$?` afterward for an unrelated reason
  silently inherits the wrong value - DD-585's own discovery was exactly
  this shape, in a test file's END block. Fixed uniformly with `local $?;`.
  Half of these instances (DD-590, DD-593) were found and largely fixed by
  the project's own autonomous hourly bug-hunt round; both were resumed
  after the round's own session ended mid-verification, with nothing lost
  either time.
- **DD-594**: the automation's end-of-round park comment silently defaulted
  to the retired shared 'DD Bot' identity because nothing ever set
  `DD_TIRA_PARK_AUTHOR`.
- **DD-586**: an operator-tool spec's timeout was too tight for its own
  deliberately long-running fixture, causing intermittent false failures.
- **DD-587**: the hourly bug-hunt and 10-minute blocked-resolver automation
  had been silently disabled for 9 days; re-enabled and verified working.
- **DD-562**: master's coverage gate read 100.0 locally but 99.9 on CI.
- **DD-567**: a perl-interpreter CVE advisory blocked CI immediately before
  the test/coverage steps, on 5 consecutive pushes.
- **DD-568**: an early CI step failing silently skipped the test and
  coverage steps after it; they now run with `if: always()`.
- **DD-572**: the pre-push security grep matched 'brewfile' against the
  retired-system marker 'ewf', making a required gate return permanent
  noise.
- **DD-573**: 13 operator-tool specs existed with nothing ever running them.
- **DD-574**: the audit gate could fail without saying which check failed.
- **DD-581**: nothing recorded a coverage verdict the board's gate
  indicator could read, so it could never show green.
- **DD-582**: gate-status reported RUNNING for a log it had no way to know
  was still being written.
- **DD-583**: the Telegram ack watcher answered a question about its own
  silence with silence.
- **DD-584**: two dd-tg operator specs had been failing with nobody told.

## 4.28

- The v4.27 signed release never published. Its workflow failed at the test step
  because t/155-coverage-gate-library-path.t asserted that the operator's local
  library tree exists on every host: it runs script/coverage-gate with PERL5LIB
  stripped and expected the declared dependencies to resolve, which holds only
  where those dependencies live in the single directory the gate adds. CI installs
  them elsewhere, so the gate reported a missing module - the correct behaviour -
  and the test failed the suite and blocked the release. The environment-dependent
  cases now skip with their reason stated, and the guard still fails if the gate's
  repair is removed (DD-552).


## 4.27

- Browser smoke tests could hang indefinitely on a host whose browser cannot
  complete a loopback fetch. One coverage run sat on such a fetch for one day
  and twenty hours, holding a web server, a starman master and worker and a
  whole browser process tree, producing no failure and no exit status - a
  stalled run is indistinguishable from a slow one. External commands in those
  tests are now bounded, and the bound signals the command's whole process
  group rather than the single visible process (DD-538).
- Those tests could also fail for an environmental fault and report it as a
  product failure. They now probe first, over plain HTTP from a minimal local
  server rather than through the product, and skip with the probe URL and the
  browser's own behaviour printed when the browser cannot fetch at all - so a
  broken host skips loudly instead of blocking every gate (DD-534).
- The workspace command captured its final tmux attach through a pipe, funnelling
  a full-screen interactive program through a capture buffer and leaving a perl
  process alive as its parent for the whole life of the session. It now execs,
  so tmux inherits the terminal and no process is left behind (DD-537).
- A collector could accumulate supervisor loops without limit. Start, stop and
  status all treated the pidfile as the authority on what was running, so once
  that file was lost every start forked another loop that nothing could see,
  stop or count; twenty-seven were alive at once for a collector declared
  singleton, each firing on its own schedule. They now establish what is running
  from the process table, adopt the existing loop, and repair the record
  (DD-532).
- A collector stopped by a signal recorded only that it had stopped, which is
  identical to an orderly shutdown, a watchdog stop and a stray kill. It now
  records which signal arrived and which process received it (DD-543).
- The coverage gate failed on any launch that did not inherit a library path -
  cron, a systemd unit, a non-interactive shell - and reported an installed,
  declared dependency as missing, pointing the diagnosis at the product when the
  fault was the launch. It resolves its own library tree now, and still fails
  loudly when a dependency is genuinely absent (DD-523).

## 4.24

- Login open-redirect class: the redirect sanitizer rejected only the single
  reported byte sequence, so sibling encodings of an absolute off-site target
  still escaped. The sanitizer now rejects the whole class, and the
  Host-header variant on both HTTPS-enforcement redirect paths is closed too
  (DD-415, DD-419).
- Saved-page write traversal: PageStore accepted a page name that resolved
  outside the dashboards root, allowing a write anywhere the server user
  could reach. The resolved path is now required to stay inside the root
  (DD-395).
- Skill-route traversal: skill-namespaced web routes accepted
  parent-directory segments, exposing files outside the skill tree; static
  file serving is now containment-asserted (DD-416). The install path had the
  same flaw - a repo name could escape the skills root - and now refuses
  (DD-426).
- Attribute-context XSS: page-derived values were HTML-escaped for element
  text but interpolated raw into HTML attributes, so a crafted saved page
  could break out of an attribute and execute script. Every attribute-context
  insertion is now encoded for that context (DD-421), and saved bookmark link
  segments are percent-encoded for URL context (DD-423).
- Missing CSRF defense: state-changing requests were accepted regardless of
  Origin or Referer, so a foreign page could drive an authenticated helper
  session. Foreign-origin state-changing requests are now rejected on every
  web tier (DD-422).
- Transient-token 403 bypass: the denial for transient ?token= URLs was
  conditioned on the absence of an accompanying file value, so sending one
  bypassed the 403. The denial now depends on the token alone (DD-425).
- Release tarball leaks: dzil gathers from disk, not from git, so dogfood QA
  evidence and ticket worktrees shipped inside the distribution (DD-414), and
  the Hermes runtime state root - which carries credentials - shipped with it
  (DD-432). Both are excluded and the exclusion is asserted by the release
  metadata gate.
- Collector timeout leaked processes: a timed-out collector command left its
  descendants running because only the direct child was signalled; the full
  process subtree is now terminated (DD-388), and blocked Windows command
  collectors are interrupted at their timeout instead of hanging (DD-389).
- Concurrent collector writers clobbered each other: the atomic
  write-and-rename used one shared pending filename, so two workers racing on
  the same state file could interleave and publish a truncated document. The
  pending name is now per-process (DD-418).
- Collector log corruption: append and rotation were unsynchronised (DD-399),
  and a combined lines+days rotation rule could cut mid-entry and orphan the
  body. Rotation now cuts on entry boundaries under a shared per-log lock
  (DD-427).
- Saved-Ajax disconnect leaked children and killed them too early: descendant
  processes survived a client disconnect (DD-396), and the SIGTERM grace
  window collapsed to zero elapsed time so handlers were SIGKILLed without a
  chance to clean up (DD-428).
- Runtime state readers died on a transient empty state file mid-rename
  (DD-411), and the web lifecycle acted on incomplete runtime state (DD-412).
- Windows startup failures: the SSL certificate home was resolved outside
  PathRegistry so the HTTPS server never started (DD-417); unguarded passwd
  lookups died in non-interactive sessions instead of resolving a user and a
  home (DD-413); PERL5LIB generation assumed POSIX separators (DD-397); and
  the PowerShell startup env cache clobbered live PATH state (DD-390).
- Collectors stopped when the updates directory was absent, treating a
  missing optional directory as a fatal condition (DD-398).
- Accessibility and layout: generated HTML documents carried no lang
  attribute (DD-405), page-editor textareas had no programmatic accessible
  name (DD-409), rendered page chrome overflowed 320px viewports (DD-410),
  and logout dead-ended a loopback-admin browser on the login page (DD-408).
- Gate blindness: the POD syntax gate graded a stale copy rather than the
  source tree and was hiding three real reds (DD-429); the coverage gate
  graded the stale build tree instead of lib/ (DD-431); and a failed exec in
  the harness process silently blinded it (DD-428).
- PathRegistry forked /bin/pwd on every working-directory lookup (DD-393),
  and MakeMaker license metadata disagreed with the MIT licence (DD-400).

## 4.23

- Host-trust DNS-rebinding vector: `_request_is_loopback_admin` trusted any
  Host header that resolved to a loopback address, so an attacker-controlled
  DNS name pointing at 127.0.0.1 could reach admin-tier routes from a local
  browser. Trust now requires exact loopback literals or configured
  `web.ssl_subject_alt_names` aliases (plus the existing loopback remote
  check); resolution alone no longer grants admin.
- CI coverage gate under-enforcement: the workflows verified only statement
  and subroutine coverage, so branch/condition regressions could merge
  silently. All three workflows now fail closed through
  script/check-all-metric-coverage on any of the four metrics below 100.0
  or any malformed report.
- Fresh-runtime API test pollution: t/15's fresh-runtime block resolved the
  config root from the ambient working directory, writing config/api.json
  into a dev checkout's runtime layer and failing locally while passing in
  CI. The block now chdirs into its isolated HOME.

## 4.22 - expired sessions are now actually reclaimed

The 4.21 batch added SessionStore::sweep_expired but left it unwired, so expired session files still accumulated. The housekeeper run now calls the sweep each cycle and reports the count (t/58), completing the expired-session-GC fix.


## 4.21 - automated bug-hunt round 1 batch fixes

Fixes found by the hourly automated bug-hunt and shipped together, each with a regression test (t/50-t/57): single-layer collector/provider dedup in the config merge; atomic config/api/state writes with checked close(); forged encoded-action token arbitrary command execution (payload `source` no longer trusted); session-id path traversal (cookie id sanitized before path use); `Secure` on the session cookie over HTTPS; PBKDF2 password stretching, still verifying existing password hashes; `timeout_ms` round-trip (Windows x1000 blow-up); `* * * * *` cron per-minute dedup; signal-killed commands recorded as failures not exit 0; setsid Windows guard on background actions; git-error vs dirty-tree distinction. Deferred: housekeeper wiring of session sweep, DNS-rebinding host-trust tightening, timed-out command subtree kill.


## 4.20 - SSL front-proxy no longer grants remote clients loopback admin

**Root cause:** the `--ssl` public frontend raw-TCP-proxies TLS bytes to the internal Starman backend that terminates TLS, so the backend's REMOTE_ADDR is always the proxy's loopback socket (127.0.0.1). `Auth::trust_tier` then treated any request with a loopback `Host` header as trusted loopback admin, so a remote attacker sending `Host: 127.0.0.1` over HTTPS obtained unauthenticated admin.
**Fix:** `_run_ssl_backend_process` sets `DEVELOPER_DASHBOARD_SSL_PROXIED`; `authorize_request` passes it to `trust_tier`, which returns `helper` (no loopback-admin shortcut) whenever proxied. Real loopback admin over plain HTTP is unchanged.
**Prevention:** never derive trust from REMOTE_ADDR on a connection that has passed through a same-host proxy; the proxied peer address cannot prove the real client is local.

## 4.17 - `dashboard collector stop <name>` now truly stops the collector

- Fixed `dashboard collector stop <name>` appearing to do nothing: the collector
  came back running (a new loop pid) and `dashboard collector status <name>` kept
  reporting `running: 1` moments after the stop.
- Root cause:
  `dashboard collector start` starts the collector loop AND a background
  supervisor (watchdog) that keeps the collector alive. The `collector stop`
  subcommand called the low-level `CollectorRunner::stop_loop` directly, which
  only killed the loop and never told the supervisor to stop — so the supervisor
  immediately restarted the collector. A related race also let the supervisor
  create a DUPLICATE loop when it checked the freshly started loop before that
  loop had set its process title, and stop only tracked one of them. Killed loops
  additionally left their long-running command subtrees behind, and the
  consumer-facing `status.json` was never reset.
- Fix:
  `collector stop` now routes through the supervisor-aware
  `RuntimeManager::stop_collectors` (matching `dashboard stop collector`), which
  deregisters the collector from the supervisor and stops it before terminating
  the loop. `start_loop` now recognizes an already-running loop from its recorded
  state as well as by process identity, so no duplicate loop is created. Stopping
  a loop now resets `status.json`, group-SIGKILLs SIGTERM-ignoring command
  subtrees, kills the loop before its workers with a worker-count-scaled grace,
  persists active worker pids on spawn, sweeps crashed-loop orphans, and
  recognizes managed loops from recorded state on proc-blind hosts (Windows).
- Prevention:
  `dashboard collector stop <name>` is now regression-tested end to end in
  `t/05-cli-smoke.t` (the collector stays not-running after the stop), and the
  loop process-tree, scaled-grace, crashed-loop-sweep, proc-blind recognition,
  and start_loop de-duplication behaviours each have focused coverage in
  `t/14-coverage-closure-extra.t`.

## 4.15 - Blank-host installs no longer fail the post-install activation step

- Fixed `install.sh` runs on blank hosts without `SHELL` exported (fresh
  Docker containers and `curl ... | sh` bootstraps) failing the post-install
  activation step with `eval: Syntax error: "(" unexpected` after an otherwise
  successful install.
- Root cause:
  the bootstrap target shell and the activation runner were resolved through
  two different paths. `shell_bootstrap_target` consulted the passwd entry and
  correctly picked `bash`, so bash-dialect rc and activation files were
  written, but `shell_command_runner` only consulted `$SHELL` and fell back to
  plain `sh` when it was unset, so dash sourced the bash-only bootstrap and
  died on the first function definition.
- Fix:
  `shell_command_runner` now resolves the preferred shell path and name before
  falling back, so the runner always speaks the same dialect as the bootstrap
  files it sources.
- Prevention:
  `t/40-install-bootstrap.t` now drives `install.sh` with an empty `SHELL` and
  a bash bootstrap target and asserts the post-install commands dispatch
  through the resolved bash runner, locking the target-runner pairing in place
  for blank-container installs.

## 4.14 - Packaged module versions can no longer drift behind a release bump

- Fixed the `4.13` release shipping 53 of 54 modules under `lib/` still
  declaring `our $VERSION = '4.12'` while `dist.ini` and
  `Developer::Dashboard` said `4.13`, which broke the rule that every packaged
  module carries the single repository release version.
- Also fixed `Auth::_ip_is_loopback` accepting malformed IPv4 literals such as
  `127.0.0.999` as loopback, because the octet pattern matched any one-to-three
  digit run instead of the valid `0-255` range.
- Also restored the released `4.12` entries in `Changes` and `FIXED_BUGS.md`
  that the `4.13` update overwrote in place instead of prepending, which had
  erased the changelog record of a tagged release.
- Root cause:
  the `4.13` bump edited only `Developer::Dashboard`, `dist.ini`, and the
  previous changelog entries, and the release-metadata gate only compared the
  main module version against `dist.ini`, so nothing failed when the other 53
  modules and the released `4.12` history were left behind.
- Fix:
  every module under `lib/` now declares `4.14`, the lost `4.12` changelog and
  fixed-bugs entries are restored from the `v4.12` tag, and the loopback check
  validates each octet strictly.
- Prevention:
  `t/15-release-metadata.t` now walks every `lib/**/*.pm` and fails when any
  module version differs from the `dist.ini` release version, and the auth
  unit tests pin both the invalid-octet rejections and the valid
  `127.0.0.0/8` acceptances so neither regression can ship silently again.

## 4.13 - GitHub Actions now closes the installed-dist `Web::App` asset branch too

- Fixed the last GitHub Actions coverage drift where the source tree could pass
  locally at `100.0 / 100.0 / 100.0` but the hosted `Test` and
  `GitHub Release` workflows still reported `lib/Developer/Dashboard/Web/App.pm`
  at `99.9` statement coverage.
- Root cause:
  the earlier hardening covered the route-level compatibility helpers, but the
  clean Ubuntu runner still missed the installed-distribution
  `File::ShareDir::dist_dir()` asset candidate branch inside
  `Developer::Dashboard::Web::App::_bundled_public_asset_path`. Local runs were
  masking that because the repo-share tree was available first.
- Fix:
  the focused helper coverage test now forces `_bundled_public_asset_path`
  through an isolated installed-dist asset root, proving the `dist_dir()`
  branch directly instead of relying on the source-tree share layout.
- Prevention:
  whenever a path resolver has separate source-tree and installed-dist branches,
  the focused coverage suite must drive both explicitly so GitHub-hosted covered
  runs cannot depend on whichever asset tree happens to exist first.

## 4.12 - GitHub Actions now closes the `Web::App` coverage edge reliably

- Fixed the remaining GitHub Actions coverage drift where the source tree could
  pass locally at `100.0 / 100.0 / 100.0` but the hosted `Test` and
  `GitHub Release` workflows still reported `lib/Developer/Dashboard/Web/App.pm`
  at `99.9` statement coverage.
- Root cause:
  a small set of compatibility helpers in `Developer::Dashboard::Web::App`
  depended on indirect route fan-out for coverage. On slower or differently
  scheduled GitHub runners, those helper calls were not always observed in the
  same way as the local full-suite run, which left the workflow-side numeric
  `Devel::Cover` gate just below the strict `100.0 / 100.0 / 100.0` threshold.
- Fix:
  the focused web coverage tests now call those compatibility helpers directly
  as well as through the routed browser paths. That keeps the behaviour contract
  unchanged while making the reviewed `Web::App` statement coverage deterministic
  across local and GitHub-hosted runs.
- Prevention:
  future low-traffic compatibility helpers must get direct focused assertions in
  the web coverage suite instead of relying only on indirect route dispatch to
  keep the release coverage totals closed.

## 4.11 - GitHub signed-release tags no longer imply an unasked CPAN upload

- Fixed the GitHub Actions release split so ordinary `vX.XX` tags can drive
  the signed GitHub release path without automatically invoking the GitHub-
  hosted PAUSE upload workflow.
- Root cause:
  the repository had coupled both `release-github.yml` and `release-cpan.yml`
  to the same tag-push event. That made the safest repo-side way to satisfy
  Scorecard's signed-release check collide with the standing rule that PAUSE
  publication must stay explicit and operator-driven.
- Fix:
  `release-cpan.yml` is now manual-only through `workflow_dispatch`, while the
  tag-driven `release-github.yml` path remains in place for signed GitHub
  releases. The release guidance and main POD now describe that split
  explicitly, and the CodeQL workflow also watches every branch on push so the
  repository-side SAST signal is not artificially limited to `master`.
- Prevention:
  the release metadata regression test now checks that the release manual says
  `vX.XX` tags belong to the signed GitHub release path and that the GitHub-
  hosted CPAN upload workflow stays manual-only.

## 4.10 - Project-local Docker service folders now really live under config/docker

- Fixed the project-local Docker Compose service layout so isolated service
  folders, override lookup, and disabled markers all live under
  `./.developer-dashboard/config/docker/...`.
- Root cause:
  the implementation had drifted into a split model where the home runtime
  used `config/docker/...` but child project runtime layers still looked under
  `./.developer-dashboard/docker/...`. That contradicted the intended
  config-root contract and made the public docs impossible to keep accurate.
- Fix:
  the resolver now searches project-local isolated service folders only under
  `./.developer-dashboard/config/docker/...`, and toggle writes for child
  project layers now persist `disabled.yml` in that same tree. The README, main
  POD, and docker-focused docs now describe one consistent layout.
- Prevention:
  `t/10-extension-action-docker.t` now creates the project-local service
  override under `./.developer-dashboard/config/docker/...` and checks that the
  project-local disable marker is written there too.

## 4.09 - Smart-routed skill browser edits now stay on the skill alias

- Fixed the browser editor and Play flow for smart-routed skill pages such as
  `/app/youtube`, where the underlying skill bookmark file can still declare
  `BOOKMARK: index`.
- Root cause:
  the normal render path already knew how to resolve `/app/<skill>` and nested
  `/app/<skill>/<sub-skill>` aliases through the skill dispatcher, but the
  `/app/.../edit` and `/app/.../source` routes still assumed every named route
  was a saved bookmark. That made edit fall back to the blank saved-page
  template, and a Play POST could collapse the browser chrome to
  `/app/index/edit` because the posted skill source kept the file's internal
  `BOOKMARK: index` id instead of the smart route alias.
- Fix:
  the web app now resolves edit and source requests through the same saved-then-
  skill smart-routing path, stamps canonical browser routes onto skill pages,
  and keeps skill edit POSTs transient while forcing the rendered page id back
  to the requested smart alias. That preserves `/app/<skill>/edit`,
  `/app/<skill>/source`, `/app/<skill>`, and nested child-skill aliases across
  Edit and Play without saving over bookmark namespaces.
- Prevention:
  `t/20-skill-web-routes.t` now covers top-level and nested skill-index render,
  edit, source, and Play flows. The regression explicitly checks that browser
  chrome and form actions stay on the smart route alias rather than drifting to
  `/app/index`.

## 4.08 - Fix test.yml coverage verification regex to match Devel::Cover three-column output

- Fixed the GitHub Actions test workflow coverage verification so it correctly
  matches all three coverage columns that Devel::Cover outputs.
- Root cause:
  Line 49 of .github/workflows/test.yml was using an incomplete regex pattern:
  `grep -E '^Total[[:space:]]+100\.0[[:space:]]+100\.0($|[[:space:]])'`
  This pattern only matched the first two 100.0 values (statement and subroutine),
  but when you run `cover -report text -select_re '^lib/' -coverage statement -coverage subroutine`,
  Devel::Cover actually outputs THREE columns in the Total line: statement, subroutine, and branch.
  The incomplete regex caused t/34-scorecard-guardrails.t test 73 to fail because
  the test expects all coverage workflows to use the full three-value pattern that
  matches the complete Devel::Cover output format.
- Fix:
  Updated line 49 of .github/workflows/test.yml to use the complete regex pattern:
  `grep -E '^Total[[:space:]]+100\.0[[:space:]]+100\.0[[:space:]]+100\.0$'`
  This pattern now correctly matches all three 100.0 values that Devel::Cover
  outputs in the Total coverage summary line, ensuring 100% coverage across
  statement, subroutine, and branch metrics.
- Prevention:
  The test suite in t/34-scorecard-guardrails.t (lines 104-123) enforces that all
  coverage workflows (test.yml, release-cpan.yml, release-github.yml) use this
  consistent three-value regex pattern. This prevents future drift where workflows
  might use different coverage verification patterns. The pattern is also resilient
  to Devel::Cover output format variations by using flexible [[:space:]] matching
  rather than fixed-width column spacing.

## 4.08 - The browser editor and operator CLI output are harder to misuse

- Fixed two recurring product-shape problems: bookmark editing still exposed
  the raw separator format too directly, and several built-in operator
  commands still defaulted to raw JSON instead of readable summaries.
- Root cause:
  the browser editor preserved the canonical bookmark file structure but made
  users manage every separator line inside one large textarea, while the CLI
  surface had drifted into a mixed output model where some operator commands
  printed tables and others printed machine payloads by default.
- Fix:
  the Web UI editor now breaks bookmark sections into separate visible blocks,
  keeps the canonical hidden source in sync, lets `Tab` create a new section,
  and uses an explicit Play button to recombine, save, and render. In the CLI,
  operator-facing path, file, api, and skill inspection or mutation commands
  now default to human-readable table summaries, with `-o json` reserved for
  the full raw machine payload when automation needs it.

## 4.07 - Complete Node.js 24 migration with SHA-pinned action versions in package-ghcr workflow

- Fixed remaining GitHub Actions Node.js 20 deprecation warnings in package-ghcr.yml by upgrading to SHA-pinned Node.js 24-compatible action versions.
- Root cause:
  package-ghcr.yml was previously updated (v4.06) to use major version tags (v4, v3, v6) with
  Node.js 24 compatibility claims in comments, but continued to generate deprecation warnings because
  those major version tags resolved to older minor versions that still used Node.js 20 runtime.
  GitHub Actions deprecation notice specifically warned:
  "Node.js 20 actions are deprecated. The following actions are running on Node.js 20 and may not
  work as expected: actions/checkout@v4, docker/build-push-action@v6, docker/login-action@v3."
  All other workflows (test.yml, release-cpan.yml, release-github.yml, codeql.yml, fuzz-js.yml) had
  already been updated to use SHA-pinned v5.2.2 checkout and proper Node.js 24-compatible versions
  with FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 environment variable in v4.05, but package-ghcr.yml was
  left behind using the v4 major tag approach.
- Fix:
  updated package-ghcr.yml to use the same SHA-pinned Node.js 24-compatible action versions used
  across all other workflows in the repository:
  - actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v5.2.2
  - docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567  # v3.3.0
  - docker/build-push-action@48aba3b46d1b1fec4febb7c5d0c644b249a11355  # v6.10.0
  Added FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true environment variable to the job configuration,
  consistent with test.yml, release-cpan.yml, and release-github.yml workflows. This ensures
  explicit opt-in to Node.js 24 runtime and eliminates all deprecation warnings.
- Prevention:
  maintained SHA pinning for security (OpenSSF Scorecard requirement) consistent with all other
  workflows in the repository. Version comments (# v5.2.2, # v3.3.0, # v6.10.0) provide traceability
  while SHA pins ensure deterministic, auditable builds. All six GitHub Actions workflows now use
  consistent Node.js 24-compatible action versions with SHA pinning:
  - .github/workflows/package-ghcr.yml (this fix)
  - .github/workflows/test.yml (updated in v4.05)
  - .github/workflows/release-cpan.yml (updated in v4.05)
  - .github/workflows/release-github.yml (updated in v4.05)
  - .github/workflows/codeql.yml (updated in v4.05)
  - .github/workflows/fuzz-js.yml (updated in v4.05)
- Impact:
  eliminates the last remaining Node.js 20 deprecation warnings from GitHub Actions workflow runs.
  All workflows now use SHA-pinned Node.js 24-compatible actions that will continue to function
  after Node.js 20 EOL (September 16, 2026). Repository now maintains consistent security posture
  with SHA-pinned actions across all workflows while being future-proof against the Node.js 20
  deprecation timeline. OCI package publishing pipeline will continue to work reliably through and
  beyond the Node.js 24 transition period.

## 4.06 - Fix Node.js 24 deprecation warnings and Dockerfile undefined variable in package-ghcr workflow (SUPERSEDED by 4.07)

## 4.05 - Update GitHub Actions to Node 24 compatible versions

- Fixed all GitHub Actions workflows that were failing with deprecated action
  versions that did not support Node 24 runtime.
- Root cause:
  the workflows set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` but used outdated
  action SHAs that were pinned before Node 24 support was available. GitHub
  runners deprecated Node 20 for JavaScript actions, causing deployment failures
  in the release-github.yml workflow and potential failures in other workflows.
  The action SHAs were from checkout v4 era (SHA: 93cb6efe18208431cddfb8368fd83d5badbf9bfd)
  and an old setup-perl version (SHA: 8a3e458e34220c3cd62497d8c297eae315b88a72).
  Additionally, the release-github.yml workflow was missing comprehensive
  Dist::Zilla plugin dependencies that could cause build failures.
- Fix:
  updated all workflows to use Node 24 compatible action versions:
  - actions/checkout@v5.2.2 (SHA: 11bd71901bbe5b1630ceea73d27597364c9af683)
  - shogo82148/actions-setup-perl@v1.32.0 (SHA: 9c1eca9952ccc07f9ca4a2097b63df93d9d138e9)
  Added comprehensive Dist::Zilla plugin installation to release-github.yml
  matching the release-cpan.yml pattern, including:
  - Dist::Zilla::Plugin::ManifestSkip
  - Dist::Zilla::Plugin::MetaProvides::Package
  - Dist::Zilla::Plugin::PkgVersion
  - Dist::Zilla::Plugin::ShareDir
  - File::ShareDir::Install
  This ensures the GitHub Release workflow can successfully build and publish
  release tarballs with proper metadata and shared directory support.
- Prevention:
  maintained SHA pinning for security (Scorecard requirement) while updating to
  current stable versions. Added version comments (# v5.2.2, # v1.32.0) for
  traceability. Updated six workflows total:
  - .github/workflows/release-github.yml (primary fix for deployment failure)
  - .github/workflows/release-cpan.yml
  - .github/workflows/test.yml
  - .github/workflows/package-ghcr.yml
  - .github/workflows/codeql.yml
- .github/workflows/fuzz-js.yml

## 4.04 - Windows helper staging, bootstrap, and dotted skill dispatch are stable again

- Fixed the public switchboard and Windows helper-runtime regressions that
  broke `dashboard init`, dotted skill execution, and later Windows bootstrap
  sessions.
- Root cause:
  the switchboard refactor moved built-in helper dispatch to the more general
  command-aware path but left one direct `_builtin_helper_path('skills')` call
  behind, while the staged private `_dashboard-core` helper started calling
  `is_windows()` without importing it. At the same time, the in-progress
  Windows runtime and bootstrap work needed one coherent closeout for helper
  refresh deferral, detached helper entrypoints, PowerShell `HOME`, and GNU
  make exposure.
- Fix:
  restored the public `_builtin_helper_path` compatibility wrapper on top of
  `_builtin_helper_command`, imported `is_windows` into the staged private
  core, kept Windows core-backed built-ins on the shared `_dashboard-core`
  path, completed the detached Windows web and collector helper coverage plus
  state-file replacement fallbacks, and taught `install.ps1` to seed
  `env:HOME` from PowerShell `HOME` and create a stable `make.cmd` shim for
  Strawberry Perl's GNU make provider. Follow-on hardening now also forces
  non-interactive CPAN environment defaults for skill `cpanm` installs so the
  fresh-session PowerShell bootstrap proof does not hang behind dependency
  configure prompts when it reaches `dashboard skills install browser`.

## 4.03 - OWASP claim wording now matches the actual shipped evidence

- Fixed the repo's OWASP claim boundary so the docs and gates no longer stop
  at policy wording without a shipped closure artifact.
- Root cause:
  the repository already had an OWASP ASVS 5.0 and Top 10 gate in policy,
  tests, and manuals, but it still lacked a dedicated scope-of-work record
  that mapped chapters to evidence and stated clearly when a stronger public
  `OWASP compliant` claim would actually be justified.
- Fix:
  added a shipped OWASP compliance SOW and evidence matrix under `doc/`,
  wired it into `t/47-owasp-gate.t` and `t/15-release-metadata.t`, and
  tightened the security and release manuals plus the main generated manual so
  the safe public wording remains `OWASP-aligned` / `OWASP-gated` until the
  remaining governance and release blockers are really closed.

## 4.02 - Runtime helper detection and final gate closure are stable

- Fixed the runtime helper substring probe and the final coverage-closure harness path that depended on it.
- Root cause:
  `_helper_file_supports_internal_command` was using a compact return
  expression that did not stay trustworthy under the full gate loop, and the
  matching coverage-closure test used a fragile temporary helper setup that
  was too easy to destabilize while closing the last line-level coverage gaps.
- Fix:
  the runtime helper matcher now returns an explicit boolean from a stable
  substring check, and `t/47-zombie-coverage-closure.t` now keeps a real
  helper fixture alive on disk and exercises the matcher through a direct
  runtime object call before validating the remaining collector-runner
  branches.

## 4.01 - Layered API auth is now operable through a first-class dashboard api command

- Fixed the missing operator workflow for layered saved-Ajax machine auth.
- Root cause:
  the backend already understood layered `config/api.json`, but operators had
  no supported command to inspect the effective merged registry, hash raw
  secrets safely, update only the deepest writable layer, or hide inherited
  API groups without editing parent JSON by hand.
- Fix:
  added the built-in `dashboard api` command with `ls`, `add`, and `rm`
  actions; `dashboard api` now defaults to listing the effective merged
  registry, raw secrets are hashed to SHA-256 before persistence, exact
  `/ajax/...` routes can be added or removed idempotently, `--maybe-secret`
  now supports one-command route-focused creates or overwrites, fresh runtimes
  bootstrap `config/api.json` automatically, and inherited API groups can be
  masked through child-layer tombstones in the writable layer while the parent
  config stays untouched.

## 4.00 - Layered API auth for saved ajax routes works without weakening helper sessions

- Fixed remote machine access for selected saved `/ajax/...` handlers so
  operators can authorize them with layered `config/api.json` keys instead of
  forcing a helper-user login flow.
- Root cause:
  saved ajax routes only understood the existing local-admin or helper-session
  auth path. Even when an operator needed one exact saved ajax route for a
  remote application, the backend had no layered `config/api.json` contract,
  no SHA-256 machine-secret verification, and no route-scoped auth bypass for
  that use case. The PSGI/Dancer adapter also discarded the custom API auth
  headers before they could reach the backend.
- Fix:
  the config loader now merges `config/api.json` through `DD-OOP-LAYERS` plus
  installed skill layer chains, the web backend recognizes exact registered
  `/ajax/...` routes and verifies `X-DD-API-Key` plus `X-DD-API-Secret`
  against stored SHA-256 digests, helper sessions still work on the same
  routes, and missing or wrong machine credentials now fail closed with
  `403 {"status":"forbidden"}`. The PSGI/Dancer adapter now forwards those API
  headers unchanged so the browser-facing entrypoint and direct backend calls
  enforce the same contract.

## 3.99 - Blank-environment tarball installs keep shell-based child commands runnable

- Fixed blank-environment tarball installs that failed even after dashboard
  child processes repaired `PATH` for the current Perl interpreter.
- Root cause:
  collector shell commands are launched through `sh -c`, but the shared child
  environment builder only forced the current Perl interpreter directory to
  the front of `PATH`. In a clean container with an intentionally broken or
  stripped `PATH`, that kept `perl` resolvable while still leaving `sh`
  missing, so `_run_command` failed during the packaged `t/07-core-units.t`
  regression that exercises the repaired-path contract.
- Fix:
  dashboard-managed child env builders now also keep the active shell
  directory at the front of `PATH`, alongside the current interpreter bin.
  The loader regression now locks in that shell-directory guarantee, the core
  units regression proves `_run_command` succeeds under a stripped `PATH`, and
  the rebuilt tarball now installs successfully in a blank Docker environment
  with `cpanm` and dist tests enabled.

## 3.98 - Disabled collectors, singleton loops, and lifecycle stop paths behave correctly

- Fixed collector config handling so `disable => 1` or `"disable": true`
  means the collector is actually disabled instead of only being marked in
  config while the runtime still lets it run.
- Root cause:
  collector startup and indicator sync still treated configured collectors as
  active as long as they were present in merged config. A disabled collector
  could still be started by lifecycle commands, a named manual start could
  still launch it, and its managed indicator state could linger behind as if
  it were still part of the live fleet.
- Fix:
  collector config normalization now carries a stable disable flag, runtime
  startup skips those jobs, named starts reject them explicitly, and lifecycle
  actions stop any already-running managed loop for a disabled collector.
  Managed collector indicator sync now also removes disabled collector
  indicators instead of keeping stale active rows around.
- Fixed lingering dashboard `<defunct>` processes that still built up under
  long-lived collector loops and collector watchdog supervisor parents.
- Root cause:
  the collector loop only reaped finished worker children at the top of the
  next scheduler tick, and the watchdog supervisor did not reap adopted direct
  children at all. Long-interval collectors could therefore leave zombie worker
  children behind until the next interval, and stale supervisors could keep
  unreaped dashboard children around for days.
- Fix:
  collector loops now reap exited workers immediately through a local
  `SIGCHLD` handler as well as on each loop pass, and the watchdog supervisor
  now reaps exited direct children both when `SIGCHLD` fires and on every
  watchdog pass. The regression tests lock in both paths so the runtime no
  longer depends on a later tick or external cleanup to remove defunct
  dashboard processes.
- Fixed dashboard-managed tmux ticket and workspace sessions that repainted
  their status block every two seconds and kept `ps1 --mode tmux-status-top`
  churn permanently hot.
- Root cause:
  the staged shell bootstrap and ticket status helper hard-coded tmux
  `status-interval 2`, so every managed session kept re-running the prompt
  status command far more often than the dashboard indicators actually needed.
- Fix:
  dashboard-managed tmux sessions now refresh that status strip every
  fifteen seconds instead of every two seconds. The helper staging and CLI
  regression tests lock the new cadence in.
- Fixed shell collectors that recursively executed `dashboard ...` or `d2 ...`
  on tiny intervals and could flood one machine with overlapping dashboard
  process trees.
- Root cause:
  collector scheduling treated heavy dashboard-recursive shell commands the
  same as cheap direct probes, so a local config with several `interval: 5`
  dashboard collectors could keep the runtime permanently busy even when the
  user only wanted occasional status updates.
- Fix:
  collector loops now apply a default `30` second floor to shell collectors
  that re-enter dashboard, while still allowing explicit opt-out through
  `allow_fast_poll`, `allow_fast_dashboard_poll`, or the
  `DEVELOPER_DASHBOARD_MIN_DASHBOARD_COMMAND_INTERVAL_SECONDS` override. The
  watchdog uses that same effective interval when deciding whether a collector
  is stale, so the safety floor does not create false restarts.
- Fixed collector stop and restart paths that could leave a long-running
  singleton command alive after the loop wrapper had already been stopped.
- Root cause:
  collector stop logic concentrated on the managed loop pid and its worker pid,
  but not the full worker process group. A shell-launched long-running command
  could outlive the loop wrapper, making singleton scheduling appear to overlap
  because the old command was still alive after the loop bookkeeping moved on.
- Fix:
  collector workers now run in their own process groups, loop shutdown signals
  those whole worker groups, and loop state persists `active_worker_pids` so
  tests can lock in the live singleton no-overlap contract.
- Fixed web stop flows that could hang or return misleading lifecycle state when
  process discovery lagged behind the saved runtime metadata.
- Root cause:
  `stop_web` only escalated to `KILL` when `running_web()` could still
  rediscover the live pid, and it treated every `dashboard ajax:` process owned
  by the current user as part of the web runtime being stopped.
- Fix:
  web stop now keeps the saved managed pid as the reported lifecycle owner,
  still kills the saved pid when runtime discovery lags, and limits ajax worker
  cleanup to the current dashboard runtime root instead of sweeping unrelated
  ajax workers.
- Fixed macOS helper/collector startup failures caused by stale user-local
  dual-life XS modules shadowing the active Perl core.
- Root cause:
  dashboard-owned processes inherited `PERL5LIB` as-is, so a local-lib tree
  with an older `Encode.bundle` or similar dual-life module could appear ahead
  of the current interpreter's matching core directories. Staged helpers,
  collector child commands, saved Ajax subprocesses, and skill hooks could
  then die during startup with XS handshake mismatch errors.
- Fix:
  dashboard bootstrap now normalizes `PERL5LIB` so dashboard-owned libraries
  remain visible while the active interpreter's core, site, and vendor
  directories stay ahead of inherited user-local shadow copies. The same safe
  ordering is used for the public switchboard, staged private helper core,
  runtime child-process envs, and skill command envs.
- Fixed macOS collector child commands that still fell back to the wrong Perl
  binary even after the safe `PERL5LIB` ordering was in place.
- Root cause:
  dashboard-managed child commands and hooks could still execute `dashboard`
  through `/usr/bin/env perl` inside a non-interactive child `PATH` that found
  `/usr/bin/perl` before the Perl interpreter that installed Dashboard under
  `~/perl5`. That left collector commands such as
  `dashboard system-status.load memory` running the wrong executable against
  the right library tree, which failed with Perl-version mismatch errors and
  left restart flows chasing stale loop state.
- Fix:
  dashboard-managed child env builders now keep the current interpreter's bin
  directory at the front of `PATH` alongside the safe `PERL5LIB` ordering, so
  collectors, saved Ajax subprocesses, and skill hooks continue to execute the
  same Perl build as the parent dashboard process.
- Fixed macOS collector commands that emitted shell startup chatter before
  their JSON payload and then failed collector JSON parsing.
- Root cause:
  collector shell commands were launched through a login shell. On affected
  macOS hosts that let the shell print session-restore text, commands such as
  `dashboard system-status.load memory` produced banner text before the JSON
  body, which made collector JSON parsing fail even though the command itself
  succeeded.
- Fix:
  collector shell commands now run through a non-login shell, keeping the
  inherited runtime environment but avoiding shell startup chatter that is not
  part of the collector payload.
- Fixed manual named collector stop/restart operations that could hang while
  the watchdog restarted the same collector underneath the CLI.
- Root cause:
  explicit named collector lifecycle commands removed the target from the
  watched set, but they left the watchdog supervisor process itself running.
  One in-flight watchdog pass could still observe the collector as missing and
  spawn a replacement loop while the manual restart path was still waiting for
  the collector it had just stopped.
- Fix:
  explicit named collector stop/restart operations now pause the watchdog
  supervisor while the manual lifecycle action runs, then restore supervision
  for the remaining watched collectors afterwards.

## 3.92 - Prompt switchboard eager-load trimming and targeted helper refresh

- Fixed the remaining `dashboard ps1` startup drag after the earlier prompt
  renderer cleanup.
- Root cause:
  the public `dashboard` switchboard was still doing expensive work before the
  staged `ps1` helper ran. Every prompt render still loaded the suggestion
  runtime, loaded helper-staging-only modules, rebuilt the same path registry
  multiple times, and refreshed the whole helper tree instead of just the one
  helper being invoked.
- Fix:
  the switchboard now lazy-loads the unknown-command suggestion runtime, keeps
  `File::ShareDir` and `SeedSync` out of the hot path unless a helper really
  needs repair, stages only the requested built-in helper during steady-state
  dispatch, and reuses one `PathRegistry` object across the whole invocation.
- Fixed prompt-time config loading to read installed skill `config/config.json`
  files directly instead of constructing the full skill dispatch runtime just
  to merge config fragments.

## 3.91 - Prompt fast-path subprocess trimming and collector sync skipping

- Fixed `dashboard ps1` so it no longer probes `tmux show-environment` when
  the shell is not inside tmux. Ordinary non-tmux shells now avoid that extra
  subprocess entirely.
- Fixed prompt git branch rendering so it reads `.git/HEAD` and worktree
  `gitdir:` metadata directly instead of spawning `git branch` on every prompt
  render.
- Fixed prompt core-indicator refresh so the prompt path now refreshes only
  prompt-visible core indicators instead of paying for hidden `project` and
  `git` subprocess checks every time.
- Fixed prompt collector syncing so repeated `dashboard ps1` renders skip the
  full collector indicator sync path when the stored managed indicator state
  already matches the configured collector set.
- Removed one unused `Developer::Dashboard::Collector` construction from the
  staged `ps1` helper so prompt startup does not instantiate dead runtime work.

## 3.90 - PathRegistry cwd reuse, env-loader cwd reuse, and nested skill env hardening

- Fixed the startup-performance miss from the improvement plan: `PathRegistry`
  now actually uses the constructor-supplied cwd and memoizes repeated
  DD-OOP-LAYERS path derivation for the lifetime of one helper invocation.
- Fixed `EnvLoader` plain-directory traversal so it reuses the registry cwd
  instead of calling `cwd()` again while walking root, project, and leaf `.env`
  files.
- Kept the nested skill env and compose layering behavior intact while closing
  the remaining coverage and packaging gates on top of the new startup-path
  changes.

## 3.89 - Nested skill env chains, nested compose roots, and ActionRunner gate closure

- Fixed nested skill env loading so dotted commands such as
  `dashboard foo.bar.zzz.show` now load `foo/.env`, `foo/bar/.env`, and
  `foo/bar/zzz/.env` from root to leaf before the command runs.
- When a deeper nested skill overrides the same key, the parent value is now
  preserved under cumulative aliases before the leaf wins the plain key. For
  example, three nested `VERSION` assignments now leave `foo_VERSION`,
  `foo_bar_VERSION`, and `VERSION` available together.
- Fixed docker compose skill discovery so nested installed skill compose roots
  such as `skills/foo/skills/bar/skills/zzz/config/docker/zzz/compose.yml`
  participate in service resolution instead of being ignored.
- Participating nested skill compose roots now export both the leaf
  `<skill>_DDDC` alias such as `zzz_DDDC` and the cumulative nested alias such
  as `foo_bar_zzz_DDDC`, both pointing at the owning `config/docker/` root.
- Closed the remaining ActionRunner gate miss by adding regression coverage for
  invalid action payloads, missing cwd failures, safe/trust edge cases, and
  detached background-child startup failures around stdio, cwd, and exec.

## 3.88 - Compose skill env layering and detached background tarball stability

- Fixed `dashboard docker compose` so each participating skill compose service
  now contributes its `<skill-root>/.env` file plus one normalized
  `<skill>_DDDC` docker-root variable during stack resolution.
- Fixed detached background page command actions so root-owned blank-container
  tarball installs no longer fail when the action wrapper exits. The detached
  supervisor now reaps its owned command child, and action-runner liveness
  checks treat already-reaped or zombie wrappers as stopped instead of leaving
  stale background-action state behind.

## 3.86 - Fix packaged shell bootstrap entrypoint reuse

- Fixed `dashboard shell` packaging so generated bootstrap helpers always
  re-enter the active public `bin/dashboard` path instead of leaking a stale
  inherited `DEVELOPER_DASHBOARD_ENTRYPOINT` from another checkout or build
  tree.
- This closes the blank-container tarball install failure where extracted
  distributions generated shell helpers that pointed back to the source
  checkout.

## 3.85 - Export skill-specific compose env roots for participating skills

- Fixed `dashboard docker compose` so installed skill services can contribute
  `<skill-root>/.env` when their `config/docker/<service>/compose.yml` or
  `development.compose.yml` file actually participates in the resolved stack.
- Disabled skills stay excluded from compose env loading, and the compose path
  does not execute `<skill-root>/.env.pl`.
- Added a skill-specific `<skill-name>_DDDC` compose environment variable for
  each participating skill, pointing at that skill's `config/docker/` root
  after normalizing non-identifier characters in the skill name to
  underscores.

## 3.84 - Load participating skill .env files into docker compose resolution

- Fixed `dashboard docker compose` so installed skill services can contribute
  `<skill-root>/.env` when their `config/docker/<service>/compose.yml` or
  `development.compose.yml` file actually participates in the resolved stack.
- Disabled skills stay excluded from compose env loading, and the compose path
  does not execute `<skill-root>/.env.pl`.
## 3.83 - Show only real skill dependency work in install progress

- Fixed the interactive `dashboard skills install` progress board so it no
  longer prints `[OK] ... skipped: ... not present` rows for dependency files
  that do not exist in the fetched skill.
- Root cause:
  the progress board predeclared every possible dependency step before the
  skill checkout had been inspected, so the install path later marked absent
  manifests as successful skipped work. That made users think a dependency had
  been installed when there had actually been nothing to do.
- Fix:
  the progress board now starts with fetch and layout tasks only, then appends
  dependency rows after the fetched skill root is known and only for manifest
  files that are really present.
- Fixed platform noise in the same install progress flow.
- Root cause:
  operating-system-specific manifests such as `brewfile` and `wingetfile` were
  being shown on unrelated hosts, even though those package managers could
  never run there.
- Fix:
  `aptfile`, `apkfile`, `dnfile`, `wingetfile`, and `brewfile` now appear only
  on their matching host families, while cross-platform manifests such as
  `package.json`, `requirements.txt`, `cpanfile`, `cpanfile.local`,
  `Makefile`, `ddfile`, and `ddfile.local` appear only when the corresponding
  file exists.
  pid as live forever, then died with `Collector '...' did not stop after TERM
  and KILL`.
- Fix:
  both `CollectorRunner` and `RuntimeManager` now read process state and treat
  zombie `Z` pids as stopped before deciding whether the pid is still alive.

## 3.79 - Replace TOML::Tiny with TOML::Parser for tarball-install stability

- Fixed the `tomq` runtime dependency chain by replacing `TOML::Tiny` with
  `TOML::Parser`.
- `TOML::Tiny 0.21` no longer passes its own clean-container test suite on
  Perl 5.38, which made `cpanm Developer-Dashboard-X.XX.tar.gz` fail under
  the required install-with-tests gate before the distribution could finish
  installing.
- The new parser path also inflates TOML booleans into plain Perl `1` and `0`
  scalars so CLI and JSON query output stays predictable.

## 3.78 - Fix missing Devel::Cover in the GitHub release workflow

- Fixed the tag-triggered GitHub release workflow so it installs
  `Devel::Cover` before it runs the numeric coverage gate.
- This removes the `cover: command not found` exit-127 failure that blocked
  GitHub release publication even after the local test and coverage gates had
  already passed.

## 3.77 - Align all shipped lib module versions with the repo version

- Fixed a release metadata drift where the main repo version had moved forward
  but many shipped modules under `lib/` still declared the previous version.
- Fixed the source tree so every shipped Perl module now reports the same
  `3.77` distribution version, keeping CI, release metadata, and packaged
  builds in sync.

## 3.76 - Fix blank-host bootstrap installer checkout configure prereqs

- Fixed blank Ubuntu streamed installs such as
  `curl .../install.sh | sh` so the installer now seeds
  `File::ShareDir::Install` into `~/perl5` before it asks `cpanm --notest .`
  to install the cloned checkout.
- Fixed the matching Windows checkout bootstrap path so `install.ps1` also
  stages `File::ShareDir::Install` before the local checkout install.

## 3.75 - Fix source-tree helper lookup in RuntimeManager and bundle jQuery 4

- Root cause:
  the Windows background web-launch helper path in `RuntimeManager` called
  `dist_dir('Developer-Dashboard')` directly. That works in installed
  distributions, but a source-tree CI run has no installed dist share yet, so
  `t/09-runtime-manager.t` could die early with `Failed to find share dir for
  dist 'Developer-Dashboard'`. Separately, `/js/jquery.js` still served an
  older handwritten compatibility shim instead of the real bundled jQuery 4
  asset the route name now implies.

- Fix:
  switched `RuntimeManager` onto the existing guarded helper-asset resolver so
  missing installed dist shares no longer abort source-tree tests and the
  staged helper path still wins when appropriate. Added regression coverage
  for the exact missing-dist-share failure case. Replaced the built-in
  `/js/jquery.js` response with a bundled local copy of `jquery-4.0.0.min.js`,
  kept `/js/jquery-4.0.0.min.js` as a compatibility alias for the same
  shipped payload, and updated route, static-file, release-metadata, and
  documentation checks to reflect the bundled asset. Also taught the browser
  bookmark editor to expand a fresh `:---` line into the full separator and
  seed the next sensible unique directive automatically, so common
  `TITLE -> HTML -> CODE<N>` edits no longer require repetitive manual typing.

## 3.74 - Add Python skill command dispatch and requirements.txt installs

- Root cause:
  the runtime could already launch Perl, Node, Go, Java, shell, and Windows
  script extensions directly from logical `cli/<command>` names, but it did
  not recognize `.py` files at all. Skill installs also had no first-class
  Python dependency step, so a skill could ship `cli/foo.py` and
  `requirements.txt` but the runtime would neither launch the command through
  `python` nor install its Python dependencies through the normal manifest
  chain.

- Fix:
  added `.py` to the runnable-file resolution path on Unix and Windows,
  dispatches those files through the preferred `python` interpreter, and added
  regression coverage for extensionless lookup plus Windows runnable-file
  detection. Added a dedicated `requirements.txt` install step after
  `package.json` and before the Perl manifests, running
  `python -m pip install --user --requirement requirements.txt` from the skill
  root. Updated the shipped manuals, progress labels, and dependency-order
  coverage so the public docs and release gates describe the Python path in
  full detail.

## 3.73 - Run executable JavaScript skill commands and hooks through node

- Root cause:
  the runnable-file resolver only knew about `.pl`, `.go`, `.java`, shell,
  and Windows script extensions. Skills could already install Node
  dependencies from `package.json`, but executable `cli/<command>.js` files
  and `.js` hook files were never discovered from logical command names and
  were never launched through `node`.

- Fix:
  added `.js` to the runnable-file extension search chain, dispatches those
  files through the preferred `node` binary on Unix and Windows, and added
  regression coverage for both extensionless lookup and Windows runnable-file
  detection. Updated the shipped manuals and release-metadata coverage so the
  public docs describe the end-to-end Node command path alongside the
  existing `package.json` install chain.

## 3.72 - Fix stalled collectors and move tmux workspaces to layered env refresh

- Root cause:
  the collector watchdog only checked whether the managed loop process still
  existed. If a collector loop stayed alive but stopped updating its runtime
  status or completing new runs, the watchdog treated it as healthy and left
  it silent forever. The tmux workflow was also still named `ticket`
  throughout the primary user-facing command surface, and resumed sessions
  kept whatever environment they were created with instead of reloading the
  current plain-directory `.env` chain.

- Fix:
  the watchdog now detects a live managed collector loop that has stopped
  making progress, stops that loop explicitly, and restarts it through the
  same managed restart path used for dead-loop recovery. Added regression
  coverage for stalled-loop recycling and for the watchdog error metadata
  written when a stall is repaired. The primary tmux workflow is now
  `dashboard workspace`, with `dashboard ticket` preserved as a compatibility
  alias. Workspace sessions now seed `WORKSPACE_REF`, keep `TICKET_REF` for
  compatibility, and reload plain-directory `.env` files from the highest
  ancestor down to the current directory both when a session is created and
  when it is resumed, unsetting keys that disappeared from the current layered
  environment.

## 3.71 - Preserve collector indicator order and runtime custom-route aliases

- Root cause:
  collector config sync correctly seeded `collector_order` from the
  `collectors` array in `config/config.json`, but a later live
  `CollectorRunner->run_once()` update rebuilt that indicator payload without
  passing the existing indicator record back into
  `collector_indicator_candidate()`. That dropped the persisted
  `collector_order` field after one collector refreshed itself, so the status
  board, page-header indicators, and `dashboard ps1` could drift back to
  alphabetical ordering even though the configured collector order was still
  correct.
  The custom route loader also only read installed skill `config/routes.json`
  files. Runtime-level `config/routes.json` aliases for normal saved bookmarks
  or built-in `/ajax`, `/js`, `/css`, and `/others` paths were never loaded,
  so a route like `"/java": "/app/learn.ai"` always fell through to `404`
  even when `dashboards/learn.ai` existed.

- Fix:
  live collector status writes now reload the existing indicator state and
  pass it into `collector_indicator_candidate()` before persisting the updated
  status. That keeps the managed collector metadata, including
  `collector_order`, stable across live refreshes. Added a regression that
  runs one collector after `sync_collectors()` and verifies the ordered
  indicator list still matches the `collectors` array order. The route
  dispatcher now also loads runtime-level `config/routes.json` files across
  the active config-layer chain, so saved bookmark aliases like `/java ->
  /app/learn.ai` resolve through the same flat route schema as skill custom
  routes. Added regressions for runtime `/app`, `/ajax`, `/js`, `/css`, and
  `/others` aliases, plus an integration check that `/java` renders the same
  bookmark body as `/app/learn.ai`.

## 3.70 - Move skill route metadata to config/routes.json and widen custom route coverage

- Root cause:
  installed skill custom routing only understood the earlier
  `dashboards/routes.json` Ajax-only schema. Skill authors could not define
  custom fallback paths for `/app`, `/js`, `/css`, or `/others`, and the
  manifest format did not match the simpler public-path-to-smart-route form
  you wanted. That left the route contract broader in the runtime than in the
  authoring surface, and it kept the metadata in the wrong place.

- Fix:
  moved skill route metadata to `config/routes.json` and changed the supported
  schema to a flat custom-path map. Each custom path now maps to one local
  smart route string such as `/ajax/foo` or to an object with `to` plus an
  optional `type`. The loader now expands that format into the internal route
  model, rejects mixed/invalid schemas explicitly, defaults custom Ajax routes
  to `json`, and serves custom `/app`, `/ajax`, `/js`, `/css`, and `/others`
  paths only after the smart parent routes miss. Saved skill-page Ajax URLs
  now continue to emit the canonical custom path from `config/routes.json`.
  Also fixed `dashboard serve logs -f` so it snapshots the already-read log
  byte offset before entering follow mode; without that, a line appended in
  the gap between the initial tail print and the old seek-to-end follow loop
  could be skipped forever and hang the follower tests.

## 3.69 - Fix skill ajax custom routing and collector indicator ordering

- Root cause:
  installed skill ajax handling only knew the smart `/ajax/<repo>/...`
  namespace and the saved-page `Ajax(file => ...)` helper always emitted that
  older route shape. Skill authors had no supported way to publish a
  canonical custom path such as `/v1/status`, no alias metadata contract, and
  no route-level default content type beyond repeating `?type=...` in every
  generated URL. At the same time, managed collector indicators were sorted by
  name once they reached prompt and page-header rendering, so the browser
  status strip and `dashboard ps1` could drift away from the configured
  collector array order.

- Fix:
  added `dashboards/routes.json` skill metadata with `version`, `ajax`,
  required canonical `path`, optional `aliases`, and optional default `type`
  fields. Skill pages now emit the declared canonical custom path while the
  smart `/ajax/<repo>/...` resolver stays the parent route and alias/custom
  paths only run after that smart route misses. The web layer now honors route
  default content types including raw mime strings, and browser prompt/status
  rendering now preserves managed collector order from the configured
  collector array instead of re-sorting those indicators alphabetically.

- Prevention:
  added focused dispatcher, direct web, PSGI, prompt, and page-header
  regressions for canonical custom ajax paths, alias fallback, smart-route
  compatibility, default `json`/`html`/raw mime handling, and configured
  collector-order rendering in both `/system/status` payloads and PS1 output.

## 3.68 - Fix collector overlap policy and bounded parallel scheduling

- Root cause:
  collector loops executed `run_once()` inline inside the long-lived scheduler
  process. A slow collector therefore blocked the next interval tick entirely,
  which made "run again on schedule even while the previous run is still
  active" impossible. The persisted collector status model also used an
  unlocked read/merge/write path plus a single `running => 0` completion write,
  so any future overlap support would have raced and cleared a still-live run.

- Fix:
  normalized collector config to accept `mode` and `multiple`, defaulting to
  `singleton` and allowing bounded overlap only when `mode` is `multiple`.
  The collector loop now spawns bounded worker children per due tick, reaps
  them explicitly, and keeps singleton collectors from overlapping while
  allowing opt-in multiple collectors to run up to their configured parallel
  limit. Collector status writes now run under an exclusive lock and maintain
  an `active_runs` counter so concurrent completions do not incorrectly mark
  another live run as stopped.

- Prevention:
  added focused config and collector-loop regressions that lock in the default
  singleton policy, the default `multiple => 2` bound, invalid config
  rejection, active-run cleanup after synchronous execution, and the
  scheduler's different overlap behavior across singleton and multiple modes.

## 3.67 - Fix zombie child processes across runtime helpers

- Root cause:
  several long-lived runtime paths started or stopped child processes without
  fully owning their wait/reap lifecycle. Detached web startup left behind the
  intermediate launcher child, collector and watchdog stop paths signalled
  managed children without reaping them, the SSL frontend only reaped
  connection workers opportunistically from the accept loop, and background
  page actions returned the direct forked child to the caller instead of
  daemonizing cleanly. On macOS and WSL that left visible zombie processes
  behind after normal runtime activity.

- Fix:
  moved child reaping into the runtime owners. Collector stop and watchdog
  shutdown now reap managed children after TERM/KILL handling, background page
  actions now daemonize through an intermediate launcher and return the real
  detached pid, web startup reaps its intermediate launcher child, and the SSL
  frontend now reaps connection workers through `SIGCHLD` while treating
  interrupted `accept()` calls as retries until an explicit shutdown signal is
  requested.

- Prevention:
  strengthened the focused runtime tests so stop paths now fail if they leave
  caller-owned children to be reaped later, and SSL/action regressions now
  lock the no-zombie contract into the suite.

## 3.66 - Fix silent collector death with watchdog restart supervision

- Root cause:
  collector job failures inside the loop were already caught and logged, but
  there was no long-lived watchdog around the collector loop process itself.
  If that loop process died after startup, the collector stayed down until a
  human noticed and restarted it manually, which looked like a silent stop.

- Fix:
  added a managed collector watchdog supervisor in `RuntimeManager` that keeps
  watching the configured collector fleet after startup, restarts loops that
  die unexpectedly, and records restart counters, timestamps, and error text
  in collector status plus collector logs. After too many crashes in the
  watchdog window, it now stops blindly restarting and marks the collector
  `attention_required` so the operator sees a concrete problem to address.

- Prevention:
  added regression coverage for post-start collector supervision so the runtime
  tests now fail if a managed collector can disappear without watchdog restart
  state or without an explicit attention-required escalation path.

## 3.65 - Fix release closeout drift and staged helper/runtime verification regressions

- Root cause:
  the post-`3.64` tree contained real fixes, but the closeout flow stalled
  before commit and push. During that gap, version metadata was left at `3.64`
  while new changes accumulated, staged helpers that re-entered
  `_dashboard-core` directly could lose the repo lib path in direct helper
  smoke coverage, and `CLI::Progress` treated falsey `max_detail_lines` as
  zero visible detail lines instead of the documented fallback rolling window.

- Fix:
  bumped the release to `3.65`, resynced the canonical POD, generated README,
  and release metadata expectations, taught staged core-backed helpers to seed
  `DEVELOPER_DASHBOARD_REPO_LIB` from `@INC` before re-entering
  `_dashboard-core`, and normalized falsey `max_detail_lines` to the intended
  ten-line fallback window.

- Prevention:
  added an explicit repo rule that once a mandatory gate miss is identified,
  the closeout flow must continue automatically instead of stopping at a soft
  handoff question.

## 3.64 - Fix macOS Terminal.app update_terminal_cwd error

- Root cause:
  On macOS, Terminal.app defines `update_terminal_cwd()` in
  `/etc/bashrc_Apple_Terminal` to update the window title with the current
  working directory. When the dashboard shell bootstrap was evaluated in a
  fresh bash session without this file being sourced first, pressing Enter
  would trigger the error: `-bash: update_terminal_cwd: command not found`

- Fix:
  added guard to bash shell bootstrap to source `/etc/bashrc_Apple_Terminal`
  when `update_terminal_cwd` is missing, preventing the error on fresh macOS
  bash sessions.

## 3.63 - Fix Docker build output truncation and add dockerfile manifest support

- Root cause:
  `Progress.pm` capped detail lines at 10 by default, truncating long-running
  operation output such as Docker builds during skill installation. Users saw
  only the first 10 lines with no autoscroll or continuation.

- Fix:
  changed `Progress.pm` to make `max_detail_lines` optional (undef = unlimited),
  allowing full streaming output for operations like Docker builds while still
  supporting explicit caps where needed.

- Enhancement:
  added `dockerfile` manifest support to `SkillManager`, allowing skills to
  declare a `dockerfile` that gets built automatically during installation.
  The build output now streams in full to the progress board.

- Testing:
  added test coverage for dockerfile detection in skill metadata and progress
  task sequence.

- macOS Terminal.app fix:
  added guard to source /etc/bashrc_Apple_Terminal when update_terminal_cwd
  is missing, preventing "-bash: update_terminal_cwd: command not found" errors
  on fresh macOS bash sessions.


## 3.62 - Fix root ddfile drift after skill uninstall

- Root cause:
  explicit `dashboard skills install <source>` correctly registered the source
  in `~/.developer-dashboard/ddfile`, but `dashboard skills uninstall
  <repo-name>` only removed the cloned skill tree and left the root registry
  behind.

- Fix:
  uninstall now removes root `ddfile` entries whose sources resolve back to the
  uninstalled repo name while preserving comments, line order, and unrelated
  entries.

## 3.61 - Fix inconsistent repository licensing metadata and docs

- Fixed the repository licensing state so it no longer mixed Perl_5 metadata,
  GPL text in `LICENSE`, an Artistic sidecar file, and user-facing wording
  that still described the project as dual-licensed under the Perl terms.
- Switched the distribution metadata, shipped root `LICENSE`, canonical POD,
  generated README, and Scorecard guardrails to one explicit MIT license
  contract so users and automation now see the same license everywhere.

## 3.60 - Clarify license disclaimer and liability baseline in user-facing docs

- Clarified the main README and canonical POD so the open-source license
  position is explicit: the software is provided `as is`, no warranty is
  given, and the project relies on the normal free-software liability
  disclaimer as the baseline protection for ordinary public distribution.
- Clarified that the disclaimer is still not unlimited and local law can
  matter, which keeps the documentation accurate instead of overstating the
  license as absolute protection in every jurisdiction.

## 3.59 - Fix nested installed skill nav discovery in the web UI

- Fixed shared skill-nav discovery so nested installed skill trees such as
  `skills/ho/skills/coverage/dashboards/nav/index.tt` now render their nav
  fragments on the nested skill route itself and also join the shared nav
  strip above normal saved pages such as `/app/index`.
- Fixed the skill dispatcher so global skill-nav collection now recurses
  through nested installed `skills/<repo>` trees in deterministic order while
  still skipping disabled nested skills during normal runtime lookup.
- Fixed layered skill-nav route-id discovery so `dashboards/nav/*` is walked
  recursively instead of only reading direct files from the first `nav/`
  directory. That keeps nested nav fragments addressable without flattening
  them back to one level.

## 3.58 - Fix installed shell-bootstrap drift, packaged helper discovery, and flaky post-build smart-router packaging checks

- Fixed dashboard-managed helper staging so each helper body now carries an
  explicit `developer-dashboard-managed-helper-version` marker. That makes it
  possible to distinguish a genuinely current installed helper from an older
  helper body that happens to share the same module version number, which is
  exactly the failure mode that hid the missing tmux ticket bootstrap on
  `hp.local`.
- Fixed Debian-family bash installs so dashboard-managed shell bootstrap lines
  are now written above the standard non-interactive `return` guards in
  `~/.bashrc`, including Ubuntu's single-line `[ -z "$PS1" ] && return`
  form. That keeps non-interactive shells such as tmux `#()` status commands
  able to resolve `dashboard`, which restores `dashboard ticket` indicator
  rendering on installed hosts such as `hp.local` instead of making the
  feature work only in fully interactive shells.
- Fixed `dashboard doctor` so it now audits that misplaced `~/.bashrc`
  bootstrap shape and repairs it with `dashboard doctor --fix` alongside the
  existing staged-helper drift repair path. This gives already-installed hosts
  a first-party self-heal path instead of forcing operators to reinstall or
  hand-edit their shell startup files.
- Fixed Windows `.cmd` and `.bat` launcher resolution so cross-platform hosts
  such as Linux, WSL, and packaged-install test environments normalize an
  extensionless local `cmd` helper in `PATH` back to `cmd.exe` instead of
  misclassifying it as a custom command processor. This keeps the expected
  Windows command-dispatch contract stable when tarball installs run on
  non-Windows packaging hosts that happen to expose a generic `cmd` shim.
- Fixed `dashboard doctor` so it now audits staged helper drift under
  `~/.developer-dashboard/cli/dd/`, reports stale or missing
  dashboard-managed helpers such as `_dashboard-core`, and can restage them
  with `dashboard doctor --fix` when the installed helper assets are current.
  This gives operators a first-party way to spot runtime helper skew instead
  of reverse-engineering mismatched `dashboard shell` and `dashboard ps1`
  behavior by hand.
- Fixed packaged helper asset discovery so tarball, PAUSE, and `cpanm`
  install-test trees now resolve `share/private-cli` from a stable absolute
  module source path captured at load time. Later `chdir` calls in
  long-running test or install processes no longer make the staged helper
  runtime look for `_dashboard-core` under the wrong working directory.
- Fixed the post-build smart-router two-stage Docker guard so one transient
  upstream `cpanm` fetch or unpack failure is retried once before the
  packaging gate is treated as a deterministic repository regression. This
  keeps a corrupt CPAN download from masquerading as a smart-router breakage
  in the built tarball.

## 3.45 - Fix stale Unix bootstrap target selection and missing tmux package installs

- Fixed Unix-like `install.sh` so blank streamed installs such as
  `curl ... | sh` no longer fall back to the stale
  `Developer::Dashboard` CPAN target when `DD_INSTALL_CPAN_TARGET` is unset.
  Checkout and extracted-tarball runs now install `.` directly, while
  streamed runs clone the current GitHub `master` checkout into a temporary
  local tree and install that checkout instead.
- Fixed the shipped Unix bootstrap package manifests so `aptfile`, `apkfile`,
  `dnfile`, and `brewfile` all install `tmux`, which keeps
  `dashboard ticket` available on blank machines without making operators
  guess a missing first-party dependency.
- Fixed blank Ubuntu bootstrap installs so the Debian-family package set now
  includes `libcrypt-dev`, preventing Perl XS dependencies such as
  `HTTP::Parser::XS`, `JSON::XS`, `YAML::XS`, and `Template::Toolkit` from
  failing with a missing `crypt.h` header during `cpanm`.

## 3.44 - Fix Docker-style progression ANSI detail colors

- Fixed `dashboard skills install` progression output so active rolling detail
  lines now render in blue and failed detail lines stay visible in red instead
  of leaving the Docker-style detail pane mostly uncolored while only the task
  marker changed color.

## 3.43 - Fix stale staged helper reuse across upgrades

- Fixed home-runtime helper staging so rerunning built-in helper extraction
  removes dashboard-managed older flat helpers from
  `~/.developer-dashboard/cli/` and keeps the active built-in helper surface
  converged on `~/.developer-dashboard/cli/dd/`.
- Fixed staged shell bootstrap regression coverage so the managed
  `dashboard shell bash` helper itself must emit the tmux ticket status
  bootstrap after staging instead of only checking the repo checkout command
  path.
- Fixed the blank-environment integration image so host-built tarball
  installs now include the native CPAN build packages required by
  `XML::Parser`, `Net::SSLeay`, and related transitive prerequisites before
  the installed-runtime smoke reaches the helper-staging checks.
- Fixed the blank-environment browser runtime so the integration image now
  uses a real Debian Chromium binary instead of the Ubuntu snap-wrapper
  launcher stub that could not run headless browser smoke checks inside the
  container.
- Fixed the host-side blank-environment launcher so it now rebuilds the
  integration image from the current Dockerfile before running the
  installed-runtime smoke, preventing cached older images from silently
  reintroducing the dead snap-wrapper browser path.

## 3.42 - Fix blank-mac bootstrap, container runtime isolation, and ticket tmux status layout

- Fixed blank new macOS bootstrap so `install.sh` now bootstraps Homebrew
  automatically when `brew` is missing instead of dying immediately with
  `Missing required command: brew`.
- Fixed Linux runtime lifecycle isolation so host-side `dashboard restart`
  and `dashboard stop` runs no longer kill or adopt Developer Dashboard web
  and collector pids that belong to another pid namespace such as a sibling
  Docker container.
- Fixed long-running skill dependency installs so manifest steps such as
  `brewfile`, `package.json`, `cpanfile`, and `Makefile` now stream a
  Docker-style rolling detail window under the active epic task while keeping
  the full task board visible.
- Fixed `dashboard ticket` tmux prompt/status handling so both fresh and
  already-existing ticket sessions suppress inline prompt indicators,
  move the full indicator strip into the first row of a two-line bottom
  tmux status block, keep tmux's normal indexed session/window row
  underneath it, preserve TT-backed percentage indicators and live
  collector values, and stop truncating the useful part of the indicator
  strip as aggressively.

## 3.40 - Move tmux prompt indicators into tmux status-right

- Fixed generated shell bootstraps so tmux sessions no longer leave collector
  indicators duplicated inside the inline shell prompt.
- Fixed tmux prompt rendering by moving indicator glyphs into tmux
  `status-right` through `dashboard ps1 --mode tmux-status` while the inline
  prompt stays focused on the cursor line.

## 3.37 - Guard Windows fresh PowerShell bootstrap and InternalCLI installed roots

- Fixed the release verification gap so the explicit coverage suite now proves
  the `InternalCLI` branch where `File::ShareDir` already returns the
  `private-cli` root itself.
- Fixed the release hygiene loop so the numeric `Devel::Cover` gate remains at
  `100.0 / 100.0 / 100.0` after the Windows bootstrap profile fixes.
- Fixed the Windows smoke gap so the streamed `irm .../install.ps1 | iex`
  verification now spawns a brand-new profile-loaded PowerShell session and
  proves that `dashboard`, `dashboard version`, and `dashboard logs` all work
  there without a manual PATH edit.

## 3.36 - Fix Windows self-contained PowerShell profile bootstrap

- Fixed the generated PowerShell profile block so fresh Windows sessions no
  longer send the multi-line `dashboard shell ps` output array directly into
  `Invoke-Expression`.
- Fixed the streamed Windows bootstrap so `irm .../install.ps1 | iex` now
  writes a self-contained profile block that restores `local::lib`, exposes
  `dashboard` on `PATH`, and activates the prompt bootstrap in future
  PowerShell sessions.

## 3.35 - Fix Windows shared helper root selection

- Fixed the installed private helper asset lookup on Windows so
  `dashboard init` no longer stops at an empty
  `MSWin32-x64-multi-thread/auto/Developer/Dashboard/private-cli`
  directory when the real shipped helper assets live under
  `auto/share/dist/Developer-Dashboard/private-cli`.
- Fixed the streamed Windows checkout bootstrap so a blank host can now
  finish `dashboard init` after `irm .../install.ps1 | iex`, stage the home
  helper runtime, and continue into the generated PowerShell shell bootstrap
  cleanly.

## 3.34 - Fix Windows helper staging bootstrap lookup

- Fixed the installed private helper asset lookup so Windows local::lib
  installs no longer look for `_dashboard-core` under the wrong arch-auto
  path when the shared dist asset root actually lives under
  `auto/share/dist/Developer-Dashboard/private-cli`.
- Fixed the streamed PowerShell bootstrap so `install.ps1` now runs
  `dashboard init` before activating `dashboard shell ps` in the current
  shell, ensuring the staged home helper runtime exists before the bootstrap
  asks for PowerShell shell wiring.
- Fixed the generated PowerShell profile guard so new sessions only ask
  `dashboard shell ps` for bootstrap output after the staged home helper
  runtime exists under `~/.developer-dashboard/cli/dd/_dashboard-core`.

## 3.33 - Fix streamed Windows install bootstrap path

- Fixed the packaged install metadata so end-user installs no longer pull
  `Plack::Test` and `Test::Pod` through the `Developer::Dashboard` test
  prerequisite path.
- Fixed the streamed Windows bootstrap path so blank hosts no longer fail with
  `Module 'Test::SharedFork' is not installed` while running
  `irm .../install.ps1 | iex`.
- Fixed the PSGI-facing repository tests by replacing the `Plack::Test`
  dependency with a local harness under `t/lib`, keeping the shipped metadata
  focused on real runtime requirements.
- Fixed the Windows install bootstrap docs so the public examples use the
  `install.ps1` entrypoint and describe the lighter packaged install path.
- Fixed the streamed Windows checkout bootstrap so the default GitHub checkout
  install now uses a Windows-safe `Makefile.PL` version path and no longer
  fails during `cpanm --notest .` with
  `Could not open 'lib/Developer::Dashboard.pm': Invalid argument`.
- Fixed the managed helper staging path so a zero-byte
  `~/.developer-dashboard/cli/dd/_dashboard-core` is repaired automatically
  instead of being preserved as if it were a user helper, restoring thin CLI
  commands such as `dashboard encode`.
- Fixed the PowerShell bootstrap so `install.ps1` now sets the CurrentUser
  execution policy to `RemoteSigned` before writing the generated profile,
  allowing new PowerShell sessions to load the `dashboard shell ps`
  bootstrap instead of failing with `running scripts is disabled`.
- Fixed the generated PowerShell profile block so `PERL_MB_OPT` no longer uses
  nested literal quotes that break new sessions with
  `Unexpected token '$ddInstallRoot""'`.

## 3.30 - Streamed PowerShell bootstrap native-output fix

- Fixed the streamed Windows bootstrap so native `winget` command output is
  written to the host terminal instead of leaking into the PowerShell return
  stream of helper functions.
- Fixed the `irm .../install.ps1 | iex` path so the Strawberry Perl package
  bootstrap now passes a single resolved Perl path string into the PATH setup
  step instead of contaminating that parameter with `winget` console output.
- Fixed the Windows Perl bootstrap so `install.ps1` no longer tries to
  self-install `App::cpanminus` while the downloaded `cpanm` bootstrap script
  is still running, avoiding the Windows file-replacement failure that broke
  the `local::lib` setup step on blank hosts.
- Fixed the public bootstrap examples so the canonical streamed PowerShell
  command now uses the exact
  `https://raw.githubusercontent.com/manif3station/developer-dashboard/refs/heads/master/install.ps1`
  URL.

## 3.28 - Windows bootstrap filename and winget source repair

- Fixed the public Windows checkout bootstrap entrypoint so the canonical file
  is now `install.ps1` instead of the atypical `install.ps`, keeping the
  streamed `irm ... | iex` operator flow aligned with normal PowerShell script
  naming.
- Fixed the Windows bootstrap `winget` path so Git, Strawberry Perl, and
  Node.js installs are pinned to the community `winget` source instead of
  implicitly touching every configured source.
- Fixed the Windows bootstrap error handling so a broken `msstore` source now
  triggers one `winget source reset --force` plus source refresh retry and, if
  that still fails, the installer reports the failing HRESULT-style exit code
  instead of only a raw negative integer.

## 3.27 - Windows checkout bootstrap installer

- Fixed the checkout bootstrap story on Windows by adding a repo-root
  `install.ps1` entrypoint that can be run directly from PowerShell or streamed
  through `irm ... | iex`.
- Fixed the Windows bootstrap flow so it now provisions missing Git,
  Strawberry Perl, and Node.js LTS packages through `winget`, bootstraps
  `cpanm`, installs Developer Dashboard with `cpanm --notest`, activates the
  PowerShell shell bootstrap, and runs `dashboard init`.
- Fixed the release metadata and integration asset guards so the Windows
  bootstrap installer must stay documented, packaged in the tarball, and kept
  out of the CPAN-installed script namespace.

## 3.26 - Blank-container tarball install policy alignment

- Fixed the blank-container tarball gate so it now installs the built release
  tarball with `cpanm --notest` only after the normal source-tree `prove -lr t`
  and explicit numeric `Devel::Cover` gates have already passed.
- Fixed the integration plan, release workflow notes, and integration asset
  guards so the repo no longer treats `cpanm --notest` as a Windows-only
  exception for the packaged tarball install path.
- Fixed the blank-environment integration runner so its packaged tarball
  install step follows the same `cpanm --notest` policy as the documented
  release flow.

## 3.25 - Installed web route parity for skill-local namespaces

- Fixed the installed Dancer web route layer so `/ajax/<repo>/...` and
  nested child-skill Ajax paths no longer bypass the smart skill router and
  incorrectly fall through to `Ajax handler not found`.
- Fixed the installed Dancer web route layer so `/js/<repo>/...`,
  `/css/<repo>/...`, and `/others/<repo>/...` now use the same longest-prefix
  skill route resolution as the backend app instead of only checking the
  global saved public roots.
- Fixed the installed Dancer web route layer so `/app/<repo>/...` and nested
  child-skill bookmark routes stay aligned with the backend smart skill route
  fallback instead of dropping into the blank editor path for installed skill
  pages.
- Added live PSGI regressions for top-level and nested `/app`, `/ajax`,
  `/js`, `/css`, and `/others` skill-local routes so future smart-router work
  has to pass the installed route layer too, not just direct backend unit
  dispatch.
- Fixed the blank-editor helper-login path so the root editor now keeps the
  helper request context and still renders helper chrome, including the logout
  link and helper username, during installed blank-environment integration
  runs.
- Fixed the release process so the extracted-dashboard smart-router regression
  now has an explicit post-build guardrail in `t/44-smart-router-two-stage.t`
  and the host integration launcher runs it immediately after `dzil build`
  before the larger blank-environment flow starts.

## 3.24 - Skill-local route namespaces and nested skill asset routing

- Fixed skill-local bookmark pages so `Ajax(file => ...)` inside
  `~/.developer-dashboard/skills/<repo>/dashboards/...` now emits stable saved
  endpoints under `/ajax/<repo>/...` instead of falling back to transient
  tokenized `/ajax?token=...` URLs.
- Fixed `/ajax`, `/js`, `/css`, and `/others` so they now prefer the longest
  installed skill prefix, including nested child skills under
  `skills/<repo>/...`, before treating the remaining path as the handler or
  asset path.
- Fixed the ambiguous route case where a normal nested saved-bookmark asset or
  saved Ajax file starts with the same segment as an installed skill name, so
  Developer Dashboard now falls back to the global nested file instead of
  incorrectly returning `404`.
- Fixed nested child skill URL generation so names like
  `/ajax/<repo>/<sub-skill>/...` are emitted as real path segments instead of
  URL-encoding the slash into a single `%2F` segment.

## 3.23 - README source-of-truth and sync guardrails

- Fixed the release process so `README.md` is no longer treated as a second
  hand-edited manual that can drift away from the canonical
  `Developer::Dashboard` POD.
- Fixed the release metadata gate so it now checks that the tracked
  `README.md` exactly matches the Markdown generated by the checkout sync
  helper from the canonical POD source.
- Fixed the JS fast-check test harness so newer `npm` update-notifier messages
  no longer fail the stderr-clean fuzz gate even when the property tests
  themselves are green.

## 3.22 - README.md format regression

- Fixed the shipped `README.md` so it is Markdown again instead of an accidental
  POD copy.
- Fixed the release metadata gate so it now fails if `README.md` starts with POD
  markers such as `=pod` or `=head1`.

## 3.21 - Final extracted dashboard prune cleanup

- Fixed the public `dashboard` POD examples so core no longer mentions the
  extracted API Dashboard by name.
- Fixed the release-metadata gate so it now fails if core code, docs, POD,
  tests, or shipped assets reintroduce `API Dashboard` or `SQL Dashboard`
  names after extraction.

## 3.20 - Root ddfile first-install status reporting

- Fixed `dashboard skills install` so sources listed only in the home root
  `~/.developer-dashboard/ddfile` are reported as `installed` on their first
  successful bare update-all run even when the skill does not ship `.env`
  `VERSION` metadata.
- Fixed the progress rundown and default summary table so first-time
  root-`ddfile` installs no longer claim `unknown (- -> -)` after a
  successful install.
- Fixed `dashboard stop collector NAME` so the default table summary still
  reports the named stopped collector when the managed loop is alive but its
  process title has not become observable yet.

## 3.19 - Optional browser workspace extraction from core

- Fixed the core/runtime boundary so the default Developer Dashboard
  distribution no longer claims, seeds, or ships an optional browser workspace
  that has been moved out of core.
- Fixed the shipped manuals, release metadata, and test guides so they now
  describe only the browser pages and verification paths that still belong to
  the core distribution.

## 3.19 - Container restart and stop listener ownership

- Fixed `dashboard stop` and `dashboard restart` so they can still find and
  terminate the real serving pid after the managed web process renames itself
  into the underlying `starman master` listener shape.
- Fixed container lifecycle control so saved web-state listener ports are used
  to recover the active listener pid, preventing Docker runs from leaving the
  web listener behind or losing restart ownership after startup.
- Problem 48: remove the saved-navigation fragment array on cache misses. The
  ordered list is accumulated into the same scalar representation used by the
  snapshot cache; exact response and cache payload tests pass. Docker's
  20-fragment helper benchmark measured 2.09x faster, but the full-route
  difference was within noise and is not represented as a route-level gain.
