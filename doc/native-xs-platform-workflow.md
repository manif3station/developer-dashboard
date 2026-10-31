# Cross-platform XS build and watcher checks

The platform compatibility workflow builds the Dashboard XS extension after
installing project dependencies and before running the complete test suite.
Unix runners use Bash, Perl and make. Windows runners use PowerShell, the Perl
installed by the workflow, and gmake; Git Bash's unrelated Perl must not be
used for the XS build or coverage-tool setup. The normal distribution build
remains the source of the extension mapping.

The Windows ARM64 watcher job runs on windows-11-arm and verifies the runner's
architecture before checking Perl's configured architecture. The hosted image
observed on 2026-10-31 provided an ARM64 runner but only
MSWin32-x64-multi-thread Perl. The workflow therefore emits a visible warning
and skips dependency installation, XS compilation and watcher testing when
native ARM64 Perl is unavailable. It does not report that as a native ARM64
test pass. If a native ARM64 Perl is present, the job builds the extension and
runs the watcher contract test with blib/arch on @INC.

The Windows x64 job must keep XS compilation and Devel::Cover setup in
PowerShell. A hosted run on 2026-10-31 exposed that invoking `perl Makefile.PL`
from Git Bash selected its MSYS Perl, whose @INC lacks ExtUtils::MakeMaker,
even though the workflow's Windows Perl was installed correctly. Separate
Windows and Unix steps now keep each platform on its configured Perl and path
separator. The Docker workflow contract checks these shell choices; hosted
verification of the follow-up is pending.

macOS continues to install Mac::FSEvents as its platform-specific event
backend. Linux inotify and Windows directory notifications are provided by
the shared XS extension. No workflow job installs or requires
FFI::Platypus or FFI::CheckLib.

Run the static workflow contract and watcher tests in the development
container:

    d2 docker compose exec dev prove -Iblib/arch -Iblib/lib -Ilib -lv t/230-native-xs-workflow.t t/669-problem48-inotify-watch.t

The 2026-10-31 Docker verification of version 6.14 passed all 290 test files
and 25,955 tests. Statement, branch, condition, and subroutine coverage each
reached 100.0 percent. The Watch.pm loader regression was included in that full
run, and no module-redefinition warnings were emitted. After the first push,
Linux x64 and ARM64 passed; the Windows x64 build failed in the Git Bash Perl
selection described above, and Windows ARM64 lacked a native Perl runtime.
The Windows shell correction and explicit ARM64-unavailable warning are now
covered by the focused Docker workflow test; both require a hosted rerun before
their results can be claimed.
