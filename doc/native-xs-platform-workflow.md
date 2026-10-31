# Cross-platform XS build and watcher checks

The platform compatibility workflow builds the Dashboard XS extension after
installing project dependencies and before running the complete test suite.
Unix runners use make; Windows runners use gmake. The normal distribution
build remains the source of the extension mapping.

The Windows ARM64 native-watcher job runs on windows-11-arm. It checks both
the runner architecture and Perl's configured architecture, installs the
project dependencies, builds the same XS extension, and runs the watcher
contract test with blib/arch on @INC. This makes the native check test the
compiled ARM64 extension instead of silently falling back to portable
validation.

macOS continues to install Mac::FSEvents as its platform-specific event
backend. Linux inotify and Windows directory notifications are provided by
the shared XS extension. No workflow job installs or requires
FFI::Platypus or FFI::CheckLib.

Run the static workflow contract and watcher tests in the development
container:

    d2 docker compose exec dev prove -Iblib/arch -Iblib/lib -Ilib -lv t/230-native-xs-workflow.t t/669-problem48-inotify-watch.t

The 2026-10-31 Docker verification passed all 290 test files and 25,955 tests.
Statement, branch, condition, and subroutine coverage each reached 100.0
percent. The Watch.pm loader regression was included in that full run, and no
module-redefinition warnings were emitted. These local results do not claim that
the hosted Linux, macOS, or Windows workflows have passed; inspect those runs
after the change is pushed.
