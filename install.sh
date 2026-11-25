#!/bin/sh

set -eu

SCRIPT_DIR=$(
    CDPATH= cd -- "$(dirname -- "$0")" && pwd
)
APTFILE="$SCRIPT_DIR/aptfile"
APKFILE="$SCRIPT_DIR/apkfile"
DNFILE="$SCRIPT_DIR/dnfile"
BREWFILE="$SCRIPT_DIR/brewfile"
APTFILE_DEFAULT_CONTENT='
# Repo bootstrap packages for Debian-family hosts.
build-essential
ca-certificates
cpanminus
curl
git
libcrypt-dev
libexpat1-dev
libssl-dev
npm
nodejs
perl
perlbrew
pkg-config
tmux
zlib1g-dev
'
BREWFILE_DEFAULT_CONTENT='
# Repo bootstrap packages for macOS hosts.
cpanminus
curl
expat
git
node
openssl@3
perl
pkgconf
tmux
'
APKFILE_DEFAULT_CONTENT='
# Repo bootstrap packages for Alpine hosts.
alpine-sdk
ca-certificates
curl
expat-dev
git
nodejs
npm
openssl-dev
perl
perl-app-cpanminus
perl-dev
pkgconf
tmux
zlib-dev
'
DNFILE_DEFAULT_CONTENT='
# Repo bootstrap packages for Fedora hosts.
ca-certificates
curl
expat-devel
gcc
gcc-c++
git
make
nodejs
openssl-devel
perl
perl-App-cpanminus
perl-devel
pkgconf-pkg-config
tmux
zlib-devel
'
INSTALL_ROOT="${HOME:?Missing HOME}/perl5"
CPAN_TARGET="${DD_INSTALL_CPAN_TARGET:-}"
DEFAULT_BOOTSTRAP_REPOSITORY_URL="${DD_INSTALL_BOOTSTRAP_REPOSITORY_URL:-https://github.com/manif3station/developer-dashboard.git}"
DEFAULT_BOOTSTRAP_CHECKOUT_DIR="${DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR:-}"
OS_OVERRIDE="${DD_INSTALL_OS_OVERRIDE:-}"
PERLBREW_ROOT="${PERLBREW_ROOT:-$INSTALL_ROOT/perlbrew}"
PERLBREW_HOME="${PERLBREW_HOME:-$PERLBREW_ROOT}"
PERLBREW_APP_DIST_URL="${DD_INSTALL_PERLBREW_APP_DIST_URL:-https://cpan.metacpan.org/authors/id/G/GU/GUGOD/App-perlbrew-1.02.tar.gz}"
PERLBREW_APP_DIST_BASENAME=$(basename "$PERLBREW_APP_DIST_URL")
SYSTEM_PERL_BIN=''
SYSTEM_PERL_ARCHNAME=''
PERLBREW_PERL="${DD_INSTALL_PERLBREW_PERL:-perl-5.44.0}"
MIN_PERL_VERSION='5.038'
PERL_BIN=''
CPANM_SCRIPT=''
RC_FILE=''
ACTIVATION_FILE=''
DASHBOARD_BIN=''
EFFECTIVE_CPAN_TARGET=''
AUTO_SHELL_MODE="${DD_INSTALL_AUTO_SHELL:-auto}"
POST_INSTALL_SHELL_COMMANDS="${DD_INSTALL_SHELL_COMMANDS:-}"
SHELL_BIN_OVERRIDE="${DD_INSTALL_SHELL_BIN:-}"
CURRENT_STEP=''
SUDO_EXPLAINED='0'
PROGRESS_STEPS='detect_platform install_system_packages verify_node_toolchain bootstrap_local_lib install_dashboard_package initialize_dashboard'
PROGRESS_STATUS_detect_platform='pending'
PROGRESS_STATUS_install_system_packages='pending'
PROGRESS_STATUS_verify_node_toolchain='pending'
PROGRESS_STATUS_bootstrap_local_lib='pending'
PROGRESS_STATUS_install_dashboard_package='pending'
PROGRESS_STATUS_initialize_dashboard='pending'
PROGRESS_NOTE_detect_platform=''
PROGRESS_NOTE_install_system_packages=''
PROGRESS_NOTE_verify_node_toolchain=''
PROGRESS_NOTE_bootstrap_local_lib=''
PROGRESS_NOTE_install_dashboard_package=''
PROGRESS_NOTE_initialize_dashboard=''
COLOR_RESET=''
COLOR_GREEN=''
COLOR_RED=''
COLOR_YELLOW=''
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    COLOR_RESET=$(printf '\033[0m')
    COLOR_GREEN=$(printf '\033[32m')
    COLOR_RED=$(printf '\033[31m')
    COLOR_YELLOW=$(printf '\033[33m')
fi

say() {
    printf '%s\n' "$*"
}

fail() {
    if [ -n "$CURRENT_STEP" ]; then
        progress_fail "$CURRENT_STEP" "$*"
    fi
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

progress_label() {
    case "$1" in
        detect_platform)
            printf '%s\n' 'Detect platform and shell profile'
            ;;
        install_system_packages)
            printf '%s\n' 'Install system packages'
            ;;
        verify_node_toolchain)
            printf '%s\n' 'Verify Node toolchain'
            ;;
        bootstrap_local_lib)
            printf '%s\n' 'Bootstrap Perl user-space runtime'
            ;;
        install_dashboard_package)
            printf '%s\n' 'Install Developer Dashboard'
            ;;
        initialize_dashboard)
            printf '%s\n' 'Initialize dashboard runtime'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

progress_set_state() {
    step=$1
    status=$2
    note=${3-}
    case "$step" in
        detect_platform)
            PROGRESS_STATUS_detect_platform=$status
            PROGRESS_NOTE_detect_platform=$note
            ;;
        install_system_packages)
            PROGRESS_STATUS_install_system_packages=$status
            PROGRESS_NOTE_install_system_packages=$note
            ;;
        verify_node_toolchain)
            PROGRESS_STATUS_verify_node_toolchain=$status
            PROGRESS_NOTE_verify_node_toolchain=$note
            ;;
        bootstrap_local_lib)
            PROGRESS_STATUS_bootstrap_local_lib=$status
            PROGRESS_NOTE_bootstrap_local_lib=$note
            ;;
        install_dashboard_package)
            PROGRESS_STATUS_install_dashboard_package=$status
            PROGRESS_NOTE_install_dashboard_package=$note
            ;;
        initialize_dashboard)
            PROGRESS_STATUS_initialize_dashboard=$status
            PROGRESS_NOTE_initialize_dashboard=$note
            ;;
    esac
}

progress_status() {
    case "$1" in
        detect_platform)
            printf '%s\n' "$PROGRESS_STATUS_detect_platform"
            ;;
        install_system_packages)
            printf '%s\n' "$PROGRESS_STATUS_install_system_packages"
            ;;
        verify_node_toolchain)
            printf '%s\n' "$PROGRESS_STATUS_verify_node_toolchain"
            ;;
        bootstrap_local_lib)
            printf '%s\n' "$PROGRESS_STATUS_bootstrap_local_lib"
            ;;
        install_dashboard_package)
            printf '%s\n' "$PROGRESS_STATUS_install_dashboard_package"
            ;;
        initialize_dashboard)
            printf '%s\n' "$PROGRESS_STATUS_initialize_dashboard"
            ;;
    esac
}

progress_note() {
    case "$1" in
        detect_platform)
            printf '%s\n' "$PROGRESS_NOTE_detect_platform"
            ;;
        install_system_packages)
            printf '%s\n' "$PROGRESS_NOTE_install_system_packages"
            ;;
        verify_node_toolchain)
            printf '%s\n' "$PROGRESS_NOTE_verify_node_toolchain"
            ;;
        bootstrap_local_lib)
            printf '%s\n' "$PROGRESS_NOTE_bootstrap_local_lib"
            ;;
        install_dashboard_package)
            printf '%s\n' "$PROGRESS_NOTE_install_dashboard_package"
            ;;
        initialize_dashboard)
            printf '%s\n' "$PROGRESS_NOTE_initialize_dashboard"
            ;;
    esac
}

progress_render() {
    say "Developer Dashboard install progress"
    for step in $PROGRESS_STEPS; do
        status=$(progress_status "$step")
        note=$(progress_note "$step")
        label=$(progress_label "$step")
        case "$status" in
            done)
                prefix="${COLOR_GREEN}[OK]${COLOR_RESET}"
                ;;
            error)
                prefix="${COLOR_RED}[X]${COLOR_RESET}"
                ;;
            active)
                prefix="${COLOR_YELLOW}->${COLOR_RESET}"
                ;;
            *)
                prefix='[ ]'
                ;;
        esac
        if [ -n "$note" ]; then
            say "$prefix $label ($note)"
        else
            say "$prefix $label"
        fi
    done
}

progress_emit() {
    step=$1
    status=$(progress_status "$step")
    note=$(progress_note "$step")
    label=$(progress_label "$step")
    case "$status" in
        done)
            prefix="${COLOR_GREEN}[OK]${COLOR_RESET}"
            ;;
        error)
            prefix="${COLOR_RED}[X]${COLOR_RESET}"
            ;;
        active)
            prefix="${COLOR_YELLOW}->${COLOR_RESET}"
            ;;
        *)
            prefix='[ ]'
            ;;
    esac
    if [ -n "$note" ]; then
        say "$prefix $label ($note)"
    else
        say "$prefix $label"
    fi
}

progress_start() {
    CURRENT_STEP=$1
    progress_set_state "$1" 'active' "${2-}"
    progress_emit "$1"
}

progress_done() {
    progress_set_state "$1" 'done' "${2-}"
    if [ "$CURRENT_STEP" = "$1" ]; then
        CURRENT_STEP=''
    fi
    progress_emit "$1"
}

progress_fail() {
    progress_set_state "$1" 'error' "${2-}"
    if [ "$CURRENT_STEP" = "$1" ]; then
        CURRENT_STEP=''
    fi
    progress_emit "$1"
}

explain_sudo_requirements() {
    if [ "$SUDO_EXPLAINED" = "1" ] || [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    say "About to use sudo for system package installation."
    say "sudo will ask for your operating-system account password, not a Developer Dashboard password."
    say "This access is only for system package installation so the listed bootstrap packages can be installed."
    SUDO_EXPLAINED='1'
}

node_toolchain_ready() {
    node --version >/dev/null 2>&1 &&
        npm --version >/dev/null 2>&1 &&
        npx --version >/dev/null 2>&1
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

manifest_packages() {
    manifest_path=$1
    if [ -f "$manifest_path" ]; then
        sed \
            -e 's/[[:space:]]*#.*$//' \
            -e '/^[[:space:]]*$/d' \
            "$manifest_path"
        return 0
    fi
    case "$(basename "$manifest_path")" in
        aptfile)
            printf '%s\n' "$APTFILE_DEFAULT_CONTENT" | sed \
                -e 's/[[:space:]]*#.*$//' \
                -e '/^[[:space:]]*$/d'
            return 0
            ;;
        dnfile)
            printf '%s\n' "$DNFILE_DEFAULT_CONTENT" | sed \
                -e 's/[[:space:]]*#.*$//' \
                -e '/^[[:space:]]*$/d'
            return 0
            ;;
        brewfile)
            printf '%s\n' "$BREWFILE_DEFAULT_CONTENT" | sed \
                -e 's/[[:space:]]*#.*$//' \
                -e '/^[[:space:]]*$/d'
            return 0
            ;;
        apkfile)
            printf '%s\n' "$APKFILE_DEFAULT_CONTENT" | sed \
                -e 's/[[:space:]]*#.*$//' \
                -e '/^[[:space:]]*$/d'
            return 0
            ;;
    esac

    fail "Missing manifest: $manifest_path"
}

platform_name() {
    if [ -n "$OS_OVERRIDE" ]; then
        printf '%s\n' "$OS_OVERRIDE"
        return 0
    fi

    uname_s=$(uname -s 2>/dev/null || printf 'unknown')
    case "$uname_s" in
        Darwin)
            printf '%s\n' 'darwin'
            return 0
            ;;
        Linux)
            if [ -f /etc/os-release ]; then
                os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n 1)
                os_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"' | head -n 1)
                case "$os_id $os_like" in
                    *alpine*)
                        printf '%s\n' 'alpine'
                        return 0
                        ;;
                    *fedora*)
                        printf '%s\n' 'fedora'
                        return 0
                        ;;
                    *ubuntu*|*debian*)
                        printf '%s\n' "${os_id:-linux}"
                        return 0
                        ;;
                esac
            fi
            [ -f /etc/alpine-release ] && {
                printf '%s\n' 'alpine'
                return 0
            }
            [ -f /etc/fedora-release ] && {
                printf '%s\n' 'fedora'
                return 0
            }
            [ -f /etc/debian_version ] && {
                printf '%s\n' 'debian'
                return 0
            }
            ;;
    esac

    fail "Unsupported platform. Supported platforms are Alpine, Debian, Ubuntu, Fedora, and macOS."
}

package_runner_prefix() {
    if [ "$(id -u)" -eq 0 ]; then
        printf '\n'
        return 0
    fi
    require_command sudo
    printf '%s\n' 'sudo'
}

choose_rc_file() {
    shell_name=$(preferred_shell_name)
    case "$shell_name" in
        bash)
            printf '%s\n' "$HOME/.bashrc"
            return 0
            ;;
        zsh)
            printf '%s\n' "$HOME/.zshrc"
            return 0
            ;;
    esac

    if [ -f "$HOME/.profile" ]; then
        printf '%s\n' "$HOME/.profile"
        return 0
    fi
    if [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"
        return 0
    fi
    if [ -f "$HOME/.zshrc" ]; then
        printf '%s\n' "$HOME/.zshrc"
        return 0
    fi
    printf '%s\n' "$HOME/.profile"
}

choose_activation_file() {
    shell_name=$(preferred_shell_name)
    case "$shell_name" in
        bash)
            printf '%s\n' "$HOME/.profile"
            return 0
            ;;
        zsh)
            printf '%s\n' "$HOME/.zshrc"
            return 0
            ;;
    esac

    printf '%s\n' "$HOME/.profile"
}

ensure_shell_activation_bridge() {
    shell_name=$(preferred_shell_name)
    case "$shell_name" in
        bash)
            append_block_once \
                "$HOME/.profile" \
                'developer-dashboard-bashrc-bridge' \
                'if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi'
            ;;
    esac
}

preferred_shell_path() {
    if [ -n "${DD_INSTALL_PREFERRED_SHELL:-}" ]; then
        printf '%s\n' "$DD_INSTALL_PREFERRED_SHELL"
        return 0
    fi

    if [ -n "${SHELL:-}" ]; then
        printf '%s\n' "$SHELL"
        return 0
    fi

    user_name=$(id -un 2>/dev/null || true)
    if [ -n "$user_name" ] && command -v getent >/dev/null 2>&1; then
        passwd_entry=$(getent passwd "$user_name" 2>/dev/null || true)
        if [ -n "$passwd_entry" ]; then
            printf '%s\n' "$passwd_entry" | awk -F: 'NF { print $NF; exit }'
            return 0
        fi
    fi

    if [ -n "$user_name" ] && command -v dscl >/dev/null 2>&1; then
        user_shell=$(dscl . -read "/Users/$user_name" UserShell 2>/dev/null | awk '/UserShell:/ { print $2; exit }')
        if [ -n "$user_shell" ]; then
            printf '%s\n' "$user_shell"
            return 0
        fi
    fi

    if [ -n "$user_name" ] && [ -r /etc/passwd ]; then
        passwd_shell=$(awk -F: -v user="$user_name" '$1 == user { print $NF; exit }' /etc/passwd)
        if [ -n "$passwd_shell" ]; then
            printf '%s\n' "$passwd_shell"
            return 0
        fi
    fi

    printf '%s\n' '/bin/sh'
}

preferred_shell_name() {
    shell_path=$(preferred_shell_path)
    shell_name=$(basename "$shell_path")
    case "$shell_name" in
        bash|zsh)
            printf '%s\n' "$shell_name"
            return 0
            ;;
    esac
    printf '%s\n' 'sh'
}

perl_meets_minimum() {
    perl_path=$1
    "$perl_path" -e "exit((\$] >= $MIN_PERL_VERSION) ? 0 : 1)" >/dev/null 2>&1
}

append_once() {
    file_path=$1
    line=$2
    touch "$file_path"
    if ! grep -Fqx "$line" "$file_path" 2>/dev/null; then
        printf '%s\n' "$line" >> "$file_path"
    fi
}

normalize_bash_rc_line() {
    file_path=$1
    line=$2

    touch "$file_path"
    perl_edit_bin='/usr/bin/perl'
    if [ ! -x "$perl_edit_bin" ]; then
        perl_edit_bin=$(command -v perl)
    fi
    "$perl_edit_bin" - "$file_path" "$line" <<'PL'
use strict;
use warnings;

my ( $file_path, $line ) = @ARGV;

open my $read_fh, '<', $file_path or die "Unable to read $file_path: $!";
local $/;
my $text = <$read_fh>;
close $read_fh or die "Unable to close $file_path after reading: $!";
$text = '' if !defined $text;

$text =~ s/^\Q$line\E\n?//mg;

my $guard_re = qr{
    (?:
        ^case \s+ \$- \s+ in \s* \n
        (?:
            (?! ^[ \t]* esac \s* $ )
            .*\n
        )*?
        ^[ \t]* \*i\* \) \s* ;; \s* \n
        ^[ \t]* \* \) \s* return \s* ;; \s* \n
        ^[ \t]* esac \s* \n?
    )
    |
    (?:
        ^[ \t]* \[ \s* -z \s+ "\$PS1" \s* \] \s* && \s* return \s* \n?
    )
}xms;

if ( $text =~ /$guard_re/ ) {
    $text =~ s/$guard_re/$line\n$&/ms;
}
else {
    $text .= "\n" if length($text) && $text !~ /\n\z/;
    $text .= $line . "\n";
}

open my $write_fh, '>', $file_path or die "Unable to write $file_path: $!";
print {$write_fh} $text;
close $write_fh or die "Unable to close $file_path after writing: $!";
PL
}

write_rc_line() {
    file_path=$1
    line=$2

    if [ "$(basename "$file_path")" = '.bashrc' ]; then
        normalize_bash_rc_line "$file_path" "$line"
        return 0
    fi

    append_once "$file_path" "$line"
}

append_block_once() {
    file_path=$1
    marker=$2
    block_text=$3

    touch "$file_path"
    if grep -Fq "$marker" "$file_path" 2>/dev/null; then
        return 0
    fi

    printf '\n%s\n%s\n%s\n' \
        "# $marker" \
        "$block_text" \
        "# /$marker" >> "$file_path"
}

run_logged_command() {
    log_file=$(mktemp "${TMPDIR:-/tmp}/developer-dashboard-install.XXXXXX") ||
        fail "Unable to allocate a temporary install log under ${TMPDIR:-/tmp}"

    if "$@" >"$log_file" 2>&1; then
        rm -f "$log_file"
        return 0
    fi

    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
}

download_to_path() {
    url=$1
    destination=$2
    require_command curl
    mkdir -p "$(dirname "$destination")" ||
        fail "Unable to create download directory for $destination"
    run_logged_command curl -fsSL "$url" -o "$destination" ||
        fail "Unable to download $url"
}

install_apt_packages() {
    prefix=$(package_runner_prefix)
    manifest_lines=$(manifest_packages "$APTFILE")
    packages=$(printf '%s\n' "$manifest_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    non_node_packages=$(printf '%s\n' "$manifest_lines" | grep -vx 'nodejs' | grep -vx 'npm' || true)
    non_node_list=$(printf '%s\n' "$non_node_packages" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    node_packages=$(printf '%s\n' "$manifest_lines" | grep -E '^(nodejs|npm)$' || true)

    if [ -n "$prefix" ]; then
        explain_sudo_requirements
        $prefix apt-get update
    else
        apt-get update
    fi

    if [ -n "$non_node_list" ]; then
        say "Installing Debian-family packages from $APTFILE: $non_node_list"
        if [ -n "$prefix" ]; then
            $prefix apt-get install -y $non_node_list
        else
            apt-get install -y $non_node_list
        fi
    fi

    install_debian_node_packages "$prefix" "$node_packages"
}

install_debian_node_packages() {
    prefix=$1
    node_packages=$2
    [ -n "$node_packages" ] || return 0
    if node_toolchain_ready; then
        say "Debian-family Node toolchain already available; skipping apt install for: $(printf '%s\n' "$node_packages" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        return 0
    fi

    if printf '%s\n' "$node_packages" | grep -qx 'nodejs'; then
        say "Installing Debian-family Node runtime from $APTFILE: nodejs"
        if [ -n "$prefix" ]; then
            $prefix apt-get install -y nodejs
        else
            apt-get install -y nodejs
        fi
    fi

    if node_toolchain_ready; then
        return 0
    fi

    if printf '%s\n' "$node_packages" | grep -qx 'npm'; then
        say "Installing Debian-family npm package from $APTFILE: npm"
        if [ -n "$prefix" ]; then
            if ! $prefix apt-get install -y npm; then
                if node_toolchain_ready; then
                    return 0
                fi
                fail "Unable to install npm from Debian-family repositories. Third-party nodejs repositories can conflict with the distro npm package. Ensure node, npm, and npx are available on PATH, then rerun install.sh."
            fi
        else
            if ! apt-get install -y npm; then
                if node_toolchain_ready; then
                    return 0
                fi
                fail "Unable to install npm from Debian-family repositories. Third-party nodejs repositories can conflict with the distro npm package. Ensure node, npm, and npx are available on PATH, then rerun install.sh."
            fi
        fi
    fi
}

install_brew_packages() {
    ensure_homebrew
    packages=$(manifest_packages "$BREWFILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    say "Installing Homebrew packages from $BREWFILE: $packages"
    brew install $packages
}

homebrew_bin_candidates() {
    printf '%s\n' \
        "$HOME/.homebrew/bin" \
        '/opt/homebrew/bin' \
        '/usr/local/bin'
}

ensure_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        return 0
    fi

    say "Bootstrapping Homebrew because brew is missing on this macOS host."
    bootstrap_script="${TMPDIR:-/tmp}/developer-dashboard-homebrew-install.sh"
    download_to_path 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' "$bootstrap_script"
    chmod 0755 "$bootstrap_script" ||
        fail "Unable to chmod Homebrew bootstrap script $bootstrap_script"
    NONINTERACTIVE=1 bash -c "$bootstrap_script" ||
        fail "Unable to bootstrap Homebrew automatically on this macOS host"

    for candidate in $(homebrew_bin_candidates); do
        if [ -x "$candidate/brew" ]; then
            PATH="$candidate:$PATH"
            export PATH
            break
        fi
    done

    require_command brew
}

install_apk_packages() {
    prefix=$(package_runner_prefix)
    packages=$(manifest_packages "$APKFILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    say "Installing Alpine packages from $APKFILE: $packages"
    if [ -n "$prefix" ]; then
        explain_sudo_requirements
        $prefix apk add --no-cache $packages
    else
        apk add --no-cache $packages
    fi
}

install_dnf_packages() {
    prefix=$(package_runner_prefix)
    packages=$(manifest_packages "$DNFILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    say "Installing Fedora packages from $DNFILE: $packages"
    if [ -n "$prefix" ]; then
        explain_sudo_requirements
        $prefix dnf install -y $packages
    else
        dnf install -y $packages
    fi
}

ensure_node_toolchain() {
    node_toolchain_ready || fail "Missing required Node toolchain: node, npm, and npx must all be available on PATH"
}

wrap_bootstrap_perl_tool() {
    tool_path=$1
    [ -x "$tool_path" ] || return 0

    real_tool_path="$tool_path.bootstrap-real"
    if [ ! -f "$real_tool_path" ]; then
        mv "$tool_path" "$real_tool_path" ||
            fail "Unable to prepare bootstrap wrapper for $tool_path"
    fi

    cat > "$tool_path" <<EOF
#!/bin/sh
PERL5LIB="$INSTALL_ROOT/lib/perl5${SYSTEM_PERL_ARCHNAME:+:$INSTALL_ROOT/lib/perl5/$SYSTEM_PERL_ARCHNAME}\${PERL5LIB:+:\$PERL5LIB}"
export PERL5LIB
exec "$real_tool_path" "\$@"
EOF
    chmod 0755 "$tool_path" ||
        fail "Unable to chmod bootstrap wrapper $tool_path"
}

bootstrap_perlbrew_perl() {
    export PERLBREW_ROOT
    export PERLBREW_HOME
    SYSTEM_PERL_BIN=$(command -v perl)
    SYSTEM_PERL_ARCHNAME=$("$SYSTEM_PERL_BIN" -MConfig -e 'print $Config{archname}')

    if ! command -v perlbrew >/dev/null 2>&1; then
        require_command cpanm
        say "perlbrew is not on PATH; installing App::perlbrew into $INSTALL_ROOT"
        perlbrew_dist_path="$INSTALL_ROOT/bootstrap-cache/$PERLBREW_APP_DIST_BASENAME"
        download_to_path "$PERLBREW_APP_DIST_URL" "$perlbrew_dist_path"
        run_cpanm --notest --local-lib-contained "$INSTALL_ROOT" "$perlbrew_dist_path"
        wrap_bootstrap_perl_tool "$INSTALL_ROOT/bin/perlbrew"
        wrap_bootstrap_perl_tool "$INSTALL_ROOT/bin/patchperl"
        PATH="$INSTALL_ROOT/bin:$PATH"
        PERL5LIB="$INSTALL_ROOT/lib/perl5${SYSTEM_PERL_ARCHNAME:+:$INSTALL_ROOT/lib/perl5/$SYSTEM_PERL_ARCHNAME}${PERL5LIB:+:$PERL5LIB}"
        export PATH
        export PERL5LIB
    fi

    require_command perlbrew

    say "System Perl is older than $MIN_PERL_VERSION; bootstrapping $PERLBREW_PERL with perlbrew under $PERLBREW_ROOT"
    mkdir -p "$PERLBREW_ROOT"
    run_logged_command perlbrew init ||
        fail "perlbrew init failed while preparing $PERLBREW_ROOT"
    if perlbrew_list_output=$(perlbrew list 2>/dev/null); then
        :
    else
        fail "perlbrew list failed while checking for $PERLBREW_PERL"
    fi
    if ! printf '%s\n' "$perlbrew_list_output" | grep -Fq "$PERLBREW_PERL"; then
        say "Building $PERLBREW_PERL with perlbrew. This can take a while."
        say "Progress log: $PERLBREW_ROOT/build.$PERLBREW_PERL.log"
        run_logged_command perlbrew --notest install "$PERLBREW_PERL" ||
            fail "perlbrew failed to build $PERLBREW_PERL under $PERLBREW_ROOT"
    fi

    PERL_BIN="$PERLBREW_ROOT/perls/$PERLBREW_PERL/bin/perl"
    [ -x "$PERL_BIN" ] || fail "perlbrew did not create $PERL_BIN"
    if [ ! -x "$PERLBREW_ROOT/bin/cpanm" ]; then
        run_logged_command perlbrew install-cpanm ||
            fail "perlbrew install-cpanm failed under $PERLBREW_ROOT"
    fi
    CPANM_SCRIPT="$PERLBREW_ROOT/bin/cpanm"
    [ -x "$CPANM_SCRIPT" ] || fail "perlbrew did not create $CPANM_SCRIPT"

    PERLBREW_HOME_LINE=$(printf 'export PERLBREW_HOME="%s"' "$PERLBREW_HOME")
    PERLBREW_PATH_LINE=$(printf 'export PATH="%s/perls/%s/bin:$PATH"' "$PERLBREW_ROOT" "$PERLBREW_PERL")
    write_rc_line "$RC_FILE" "$PERLBREW_HOME_LINE"
    write_rc_line "$RC_FILE" "$PERLBREW_PATH_LINE"
    PATH="$PERLBREW_ROOT/bin:$PERLBREW_ROOT/perls/$PERLBREW_PERL/bin:$PATH"
    export PATH
    say "Updated $RC_FILE so perlbrew metadata and $PERLBREW_PERL load automatically in new shells."
}

resolve_perl() {
    if [ "$PLATFORM" = "darwin" ]; then
        brew_perl_prefix=$(brew --prefix perl 2>/dev/null || true)
        if [ -n "$brew_perl_prefix" ] && [ -x "$brew_perl_prefix/bin/perl" ]; then
            PATH="$brew_perl_prefix/bin:$PATH"
            export PATH
        fi
    fi

    require_command perl
    if perl_meets_minimum "$(command -v perl)"; then
        PERL_BIN=$(command -v perl)
        CPANM_SCRIPT=$(command -v cpanm)
        return 0
    fi

    case "$PLATFORM" in
        alpine|debian|ubuntu|fedora)
            bootstrap_perlbrew_perl
            return 0
            ;;
    esac

    fail "Perl $MIN_PERL_VERSION or newer is required."
}

# On macOS, Homebrew's default `openssl` formula is now OpenSSL 4.x, and
# Net::SSLeay (needed by LWP::Protocol::https) cannot build against it.
# Point the compiler, the linker and pkg-config at the Homebrew openssl@3
# keg instead, using the same four exports a developer would put in their
# shell profile. A no-op on other platforms and when openssl@3 is missing.
export_darwin_openssl_env() {
    [ "$PLATFORM" = "darwin" ] || return 0
    command -v brew >/dev/null 2>&1 || return 0

    openssl_prefix=$(brew --prefix openssl@3 2>/dev/null || true)
    if [ -z "$openssl_prefix" ] || [ ! -d "$openssl_prefix" ]; then
        say "Homebrew openssl@3 was not found; building without OpenSSL 3 flags."
        return 0
    fi

    CPPFLAGS="-I$openssl_prefix/include"
    LDFLAGS="-L$openssl_prefix/lib"
    OPENSSL_PREFIX="$openssl_prefix"
    PKG_CONFIG_PATH="$openssl_prefix/lib/pkgconfig"
    export CPPFLAGS LDFLAGS OPENSSL_PREFIX PKG_CONFIG_PATH

    if [ -n "${RC_FILE:-}" ]; then
        write_rc_line "$RC_FILE" 'export CPPFLAGS="-I$(brew --prefix openssl@3)/include"'
        write_rc_line "$RC_FILE" 'export LDFLAGS="-L$(brew --prefix openssl@3)/lib"'
        write_rc_line "$RC_FILE" 'export OPENSSL_PREFIX="$(brew --prefix openssl@3)"'
        write_rc_line "$RC_FILE" 'export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"'
    fi

    say "Using Homebrew openssl@3 ($openssl_prefix) for native builds."
}

run_cpanm() {
    cpanm_script=${CPANM_SCRIPT:-$(command -v cpanm)}
    [ -n "$cpanm_script" ] || fail "Missing required command: cpanm"
    "$cpanm_script" --no-wget "$@"
}

bootstrap_local_lib() {
    require_command cpanm
    resolve_perl
    export_darwin_openssl_env

    mkdir -p "$INSTALL_ROOT"
    run_cpanm --notest --local-lib-contained "$INSTALL_ROOT" local::lib App::cpanminus File::ShareDir::Install

    LOCAL_LIB_LINE=$(printf 'eval "$("%s" -I "%s/lib/perl5" -Mlocal::lib)"' "$PERL_BIN" "$INSTALL_ROOT")
    write_rc_line "$RC_FILE" "$LOCAL_LIB_LINE"

    # shellcheck disable=SC2046
    eval "$("$PERL_BIN" -I "$INSTALL_ROOT/lib/perl5" -Mlocal::lib)"
}

resolve_default_dashboard_checkout() {
    if [ -f "$SCRIPT_DIR/lib/Developer/Dashboard.pm" ] && [ -f "$SCRIPT_DIR/Makefile.PL" ]; then
        printf '%s\n' "$SCRIPT_DIR"
        return 0
    fi

    require_command git

    if [ -n "$DEFAULT_BOOTSTRAP_CHECKOUT_DIR" ]; then
        checkout_root=$DEFAULT_BOOTSTRAP_CHECKOUT_DIR
        rm -rf "$checkout_root"
        mkdir -p "$(dirname "$checkout_root")" ||
            fail "Unable to create the parent directory for $checkout_root"
    else
        checkout_root=$(mktemp -d "${TMPDIR:-/tmp}/developer-dashboard-install.XXXXXX") ||
            fail "Unable to allocate a temporary checkout for Developer Dashboard under ${TMPDIR:-/tmp}"
    fi

    run_logged_command git clone --depth 1 --branch master "$DEFAULT_BOOTSTRAP_REPOSITORY_URL" "$checkout_root" ||
        fail "Unable to clone Developer Dashboard from $DEFAULT_BOOTSTRAP_REPOSITORY_URL"
    printf '%s\n' "$checkout_root"
}

install_dashboard() {
    if [ -n "$CPAN_TARGET" ]; then
        EFFECTIVE_CPAN_TARGET=$CPAN_TARGET
        run_cpanm --notest "$CPAN_TARGET"
        return 0
    fi

    checkout_root=$(resolve_default_dashboard_checkout)
    EFFECTIVE_CPAN_TARGET=$checkout_root
    (
        cd "$checkout_root" || exit 1
        run_cpanm --notest .
    ) || fail "Unable to install Developer Dashboard from $checkout_root"
}

shell_bootstrap_target() {
    preferred_shell_name
}

shell_command_runner() {
    if [ -n "$SHELL_BIN_OVERRIDE" ]; then
        printf '%s\n' "$SHELL_BIN_OVERRIDE"
        return 0
    fi

    if [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ]; then
        printf '%s\n' "$SHELL"
        return 0
    fi

    # The runner must speak the same dialect as the bootstrap target, or a
    # blank host without SHELL exported would source bash-flavoured activation
    # files through plain sh and die on the first bash-only construct.
    preferred_path=$(preferred_shell_path)
    if [ -n "$preferred_path" ] && [ -x "$preferred_path" ]; then
        printf '%s\n' "$preferred_path"
        return 0
    fi

    preferred_name=$(preferred_shell_name)
    resolved_preferred=$(command -v "$preferred_name" 2>/dev/null || true)
    if [ -n "$resolved_preferred" ]; then
        printf '%s\n' "$resolved_preferred"
        return 0
    fi

    shell_name=$(basename "${SHELL:-sh}")
    resolved_shell=$(command -v "$shell_name" 2>/dev/null || true)
    if [ -n "$resolved_shell" ]; then
        printf '%s\n' "$resolved_shell"
        return 0
    fi

    printf '%s\n' '/bin/sh'
}

write_dashboard_shell_bootstrap() {
    DASHBOARD_BIN="$INSTALL_ROOT/bin/d2"
    if [ ! -x "$DASHBOARD_BIN" ]; then
        DASHBOARD_BIN=$(command -v d2 || true)
    fi
    [ -n "$DASHBOARD_BIN" ] || fail "Developer Dashboard was installed but the d2 command could not be located"
    [ -x "$DASHBOARD_BIN" ] || fail "Developer Dashboard was installed but $DASHBOARD_BIN is not executable"

    SHELL_BOOTSTRAP_LINE=$(printf 'eval "$("%s" shell %s)"' "$DASHBOARD_BIN" "$(shell_bootstrap_target)")
    write_rc_line "$RC_FILE" "$SHELL_BOOTSTRAP_LINE"
}

run_post_install_shell_commands() {
    [ -n "$POST_INSTALL_SHELL_COMMANDS" ] || return 1

    shell_target=$(shell_bootstrap_target)
    shell_runner=$(shell_command_runner)
    say "Running post-install activation commands through $shell_target."

    case "$shell_target" in
        bash|zsh)
            "$shell_runner" -ilc ". \"$ACTIVATION_FILE\" >/dev/null 2>&1 || . \"$RC_FILE\" >/dev/null 2>&1; $POST_INSTALL_SHELL_COMMANDS"
            ;;
        *)
            ENV="$ACTIVATION_FILE" "$shell_runner" -ic ". \"$ACTIVATION_FILE\" >/dev/null 2>&1 || . \"$RC_FILE\" >/dev/null 2>&1; $POST_INSTALL_SHELL_COMMANDS"
            ;;
    esac || fail "Activated shell commands failed after installation"

    say "Post-install activation commands completed."
    return 0
}

handoff_to_activated_shell() {
    if [ "$AUTO_SHELL_MODE" = '0' ] || [ "$AUTO_SHELL_MODE" = 'false' ] || [ "$AUTO_SHELL_MODE" = 'no' ]; then
        return 1
    fi
    [ -z "$POST_INSTALL_SHELL_COMMANDS" ] || return 1
    if [ ! -t 0 ] || [ ! -t 1 ] || [ ! -t 2 ]; then
        return 1
    fi

    shell_target=$(shell_bootstrap_target)
    shell_runner=$(shell_command_runner)
    [ -x "$shell_runner" ] || return 1

    say "Launching activated $shell_target shell now. Exit once to return to your previous shell."
    case "$shell_target" in
        bash|zsh)
            exec "$shell_runner" -il
            ;;
        *)
            ENV="$ACTIVATION_FILE" exec "$shell_runner" -i
            ;;
    esac
}

initialize_dashboard() {
    require_command d2
    d2 init
}

main() {
    progress_render
    progress_start detect_platform
    PLATFORM=$(platform_name)
    RC_FILE=$(choose_rc_file)
    ACTIVATION_FILE=$(choose_activation_file)
    ensure_shell_activation_bridge
    progress_done detect_platform "$PLATFORM via $(basename "$RC_FILE")"
    progress_start install_system_packages "$PLATFORM"
    case "$PLATFORM" in
        debian|ubuntu)
            install_apt_packages
            ;;
        alpine)
            install_apk_packages
            ;;
        fedora)
            install_dnf_packages
            ;;
        darwin)
            install_brew_packages
            ;;
        *)
            fail "Unsupported platform '$PLATFORM'. Supported platforms are Alpine, Debian, Ubuntu, Fedora, and macOS."
            ;;
    esac
    progress_done install_system_packages "$PLATFORM complete"
    progress_start verify_node_toolchain
    ensure_node_toolchain
    progress_done verify_node_toolchain 'node, npm, and npx ready'
    progress_start bootstrap_local_lib
    bootstrap_local_lib
    progress_done bootstrap_local_lib "$(basename "$PERL_BIN") via $(basename "$RC_FILE")"
    progress_start install_dashboard_package
    install_dashboard
    write_dashboard_shell_bootstrap
    progress_done install_dashboard_package "$EFFECTIVE_CPAN_TARGET"
    progress_start initialize_dashboard
    initialize_dashboard
    progress_done initialize_dashboard "$HOME/.developer-dashboard"
    say "Developer Dashboard is installed and initialized."
    say "Shell setup was written to: $RC_FILE"
    if [ "$ACTIVATION_FILE" != "$RC_FILE" ]; then
        say "Shell activation entry point: $ACTIVATION_FILE"
    fi
    if run_post_install_shell_commands; then
        return 0
    fi
    if handoff_to_activated_shell; then
        return 0
    fi
    say "This installer ran in a child sh process, so your current shell has not loaded the new PATH yet."
    say "Run this now in your current shell:"
    say "  . \"$ACTIVATION_FILE\""
    say "Then verify with:"
    say "  d2 version"
}

# Jenkins test-node setup (install.sh --jenkins).
#
# Takes a fresh macOS, Debian or Ubuntu machine to a working test node:
# system packages, Java 21, Perl 5.38.2 built by perlbrew under
# $HOME/perl5/perlbrew, cpanm inside that Perl, the pinned distributions
# from share/jenkins, the agent's remote root, and a final check. It does
# not install the dashboard and does not edit shell rc files. Everything
# is relative to $HOME. A second run on a finished node changes nothing.
JENKINS_PERL_NAME='perl-5.38.2'
JENKINS_PERL_NUMBER='5.038002'
JENKINS_PERL_SHORT='5.38.2'
JENKINS_CPANM_VERSION='1.7049'
JENKINS_JAVA_MAJOR='21'
JENKINS_APT_EXTRA='openjdk-21-jre-headless make'
JENKINS_BREW_EXTRA='openjdk@21 openssl@3 make'
# The small package set a test node needs: build tools, the libraries the
# Perl build links against, curl, and Git. The full manifests are not
# used here: perlbrew comes from its own installer, cpanm from cpanmin.us,
# and node, npm, perl, tmux and the package-manager perlbrew and cpanminus
# are not needed for a green round.
JENKINS_APT_PACKAGES='build-essential ca-certificates curl git libcrypt-dev libexpat1-dev libssl-dev pkg-config zlib1g-dev'
JENKINS_BREW_PACKAGES='curl expat git pkgconf'
JENKINS_PERLBREW_INSTALLER_URL='https://install.perlbrew.pl'
JENKINS_CPANM_BOOTSTRAP_URL='https://cpanmin.us'
JENKINS_TIME_SERVER='time.apple.com'
JENKINS_TEST_ONLY_HELPERS='Test::LeakTrace Test::Requires Test::Warnings Test::Fatal B::COW'
JENKINS_KEY_MODULES='Net::SSLeay JSON::XS Test::Pod'
JENKINS_LIST="$SCRIPT_DIR/share/jenkins/modules-unix.txt"
JENKINS_COMPILED_LIST="$SCRIPT_DIR/share/jenkins/modules-compiled.txt"
JENKINS_AGENT_ROOT="$HOME/jenkins"
JENKINS_WORK=''
JENKINS_FINISHED='0'
JENKINS_PERL_BIN_DIR=''
JENKINS_SITE_DIR=''
JENKINS_TESTED_STAMP=''

jenkins_say() {
    say "install.sh --jenkins: $*"
}

# Runs when the --jenkins route ends for any reason. Removes the work
# folder and, unless the route finished, prints the one FAILED line.
jenkins_on_exit() {
    jenkins_status=$1
    if [ -n "$JENKINS_WORK" ] && [ -d "$JENKINS_WORK" ]; then
        rm -rf "$JENKINS_WORK"
    fi
    if [ "$JENKINS_FINISHED" != '1' ]; then
        printf '%s\n' "install.sh --jenkins: FAILED (exit $jenkins_status). This machine is not ready to be a Jenkins test node." >&2
    fi
}

# Runs a command with its output kept back unless it fails, and with
# standard input closed so no tool can stop to ask a question.
jenkins_run() {
    run_logged_command "$@" </dev/null
}

# Runs a command as root: directly when already root, else through sudo
# without a password prompt.
jenkins_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    require_command sudo
    sudo -n "$@"
}

jenkins_detect_platform() {
    PLATFORM=$(platform_name)
    case "$PLATFORM" in
        darwin|debian|ubuntu)
            ;;
        *)
            fail "install.sh --jenkins supports macOS, Debian and Ubuntu only; this machine is '$PLATFORM'."
            ;;
    esac
    if [ "$PLATFORM" = 'debian' ]; then
        debian_major=$(jenkins_debian_major_version)
        case "$debian_major" in
            ''|*[!0-9]*)
                fail "install.sh --jenkins cannot tell the Debian version; refusing to set up a test node on an unknown Debian."
                ;;
            *)
                if [ "$debian_major" -lt 13 ]; then
                    fail "install.sh --jenkins supports Debian 13 and later; this machine is Debian $debian_major."
                fi
                ;;
        esac
    fi
    jenkins_say "platform $PLATFORM"
}

# The major version of this Debian machine: the VERSION_ID in
# /etc/os-release, or /etc/debian_version when there is no os-release,
# or DD_INSTALL_DEBIAN_VERSION_ID when that is set (the test seam t/40
# uses to fake a Debian version on a box that is not Debian). Prints an
# empty line when the version cannot be told at all.
jenkins_debian_major_version() {
    debian_version_id="${DD_INSTALL_DEBIAN_VERSION_ID:-}"
    if [ -z "$debian_version_id" ] && [ -f /etc/os-release ]; then
        debian_version_id=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -n 1)
    fi
    if [ -z "$debian_version_id" ] && [ -f /etc/debian_version ]; then
        debian_version_id=$(head -n 1 /etc/debian_version)
    fi
    printf '%s\n' "${debian_version_id%%.*}"
}

# macOS only: the time server and the no-sleep settings a test node needs.
jenkins_macos_node_settings() {
    [ "$PLATFORM" = 'darwin' ] || return 0
    jenkins_say "macOS node settings: time server and no sleep"
    jenkins_sudo systemsetup -setnetworktimeserver "$JENKINS_TIME_SERVER" ||
        fail "Unable to set the network time server"
    jenkins_sudo systemsetup -setusingnetworktime on ||
        fail "Unable to turn network time on"
    jenkins_sudo pmset -a powernap 0 sleep 0 disksleep 0 displaysleep 0 standby 0 hibernatemode 0 autopoweroff 0 ||
        fail "Unable to switch sleep off"
    jenkins_sudo sntp -sS "$JENKINS_TIME_SERVER" ||
        fail "Unable to read the time from $JENKINS_TIME_SERVER"
}

jenkins_install_system_packages() {
    jenkins_say "system packages, Java $JENKINS_JAVA_MAJOR and make"
    case "$PLATFORM" in
        debian|ubuntu)
            prefix=$(package_runner_prefix)
            if [ -n "$prefix" ]; then
                explain_sudo_requirements
                $prefix apt-get update
            else
                apt-get update
            fi
            # The --jenkins route installs the small list above, not the
            # full manifest: the test node needs build tools, Java, Git
            # and the libraries the Perl build links against, and
            # nothing else. perlbrew comes from its own installer and
            # cpanm from cpanmin.us.
            if [ -n "$prefix" ]; then
                # shellcheck disable=SC2086
                $prefix apt-get install -y $JENKINS_APT_PACKAGES $JENKINS_APT_EXTRA </dev/null ||
                    fail "Unable to install: $JENKINS_APT_PACKAGES $JENKINS_APT_EXTRA"
            else
                # shellcheck disable=SC2086
                apt-get install -y $JENKINS_APT_PACKAGES $JENKINS_APT_EXTRA </dev/null ||
                    fail "Unable to install: $JENKINS_APT_PACKAGES $JENKINS_APT_EXTRA"
            fi
            ;;
        darwin)
            HOMEBREW_NO_AUTO_UPDATE=1
            HOMEBREW_NO_INSTALL_CLEANUP=1
            export HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
            ensure_homebrew
            # shellcheck disable=SC2086
            brew install $JENKINS_BREW_PACKAGES $JENKINS_BREW_EXTRA </dev/null ||
                fail "Unable to install: $JENKINS_BREW_PACKAGES $JENKINS_BREW_EXTRA"
            ;;
    esac
}

# Finds perlbrew under $PERLBREW_ROOT, or installs it there from its own
# installer, downloaded to a file first and never piped. A perlbrew
# elsewhere on PATH is never used: the real nodes run the installer one,
# and the package-manager one is unused.
jenkins_ensure_perlbrew() {
    if [ -x "$PERLBREW_ROOT/bin/perlbrew" ]; then
        PATH="$PERLBREW_ROOT/bin:$PATH"
        export PATH
        return 0
    fi
    jenkins_say "perlbrew is missing; installing it under $PERLBREW_ROOT"
    require_command bash
    perlbrew_installer="$JENKINS_WORK/jenkins-perlbrew-install.sh"
    download_to_path "$JENKINS_PERLBREW_INSTALLER_URL" "$perlbrew_installer"
    jenkins_run bash "$perlbrew_installer" ||
        fail "The perlbrew installer failed"
    [ -x "$PERLBREW_ROOT/bin/perlbrew" ] ||
        fail "The perlbrew installer did not create $PERLBREW_ROOT/bin/perlbrew"
    PATH="$PERLBREW_ROOT/bin:$PATH"
    export PATH
}

# How many parallel jobs the Perl build gets: the machine's CPU count
# (nproc on Linux, sysctl on macOS), or 4 when the count cannot be read.
jenkins_build_jobs() {
    jenkins_cpu_count=''
    if [ "$PLATFORM" = 'darwin' ]; then
        jenkins_cpu_count=$(sysctl -n hw.ncpu 2>/dev/null || true)
    else
        jenkins_cpu_count=$(nproc 2>/dev/null || true)
    fi
    case "$jenkins_cpu_count" in
        ''|*[!0-9]*|0)
            printf '%s\n' '4'
            ;;
        *)
            printf '%s\n' "$jenkins_cpu_count"
            ;;
    esac
}

# Builds Perl 5.38.2 whatever the system Perl is, and refuses to go on
# unless that Perl reports exactly 5.38.2.
jenkins_build_perl() {
    PERLBREW_ROOT="$HOME/perl5/perlbrew"
    PERLBREW_HOME="$PERLBREW_ROOT"
    export PERLBREW_ROOT PERLBREW_HOME
    JENKINS_PERL_BIN_DIR="$PERLBREW_ROOT/perls/$JENKINS_PERL_NAME/bin"
    JENKINS_SITE_DIR="$PERLBREW_ROOT/perls/$JENKINS_PERL_NAME/lib/site_perl/$JENKINS_PERL_SHORT"
    JENKINS_TESTED_STAMP="$PERLBREW_ROOT/perls/$JENKINS_PERL_NAME/.jenkins-compiled-tests-passed"
    PERL_BIN="$JENKINS_PERL_BIN_DIR/perl"

    mkdir -p "$PERLBREW_ROOT" || fail "Unable to create $PERLBREW_ROOT"
    jenkins_ensure_perlbrew
    if [ -x "$PERL_BIN" ]; then
        jenkins_say "$JENKINS_PERL_NAME is already built"
    else
        jenkins_run perlbrew init ||
            fail "perlbrew init failed while preparing $PERLBREW_ROOT"
        jenkins_say "building $JENKINS_PERL_NAME with perlbrew; this can take a while"
        jenkins_build_jobs=$(jenkins_build_jobs)
        jenkins_run perlbrew install "$JENKINS_PERL_NAME" --notest -j "$jenkins_build_jobs" ||
            fail "perlbrew failed to build $JENKINS_PERL_NAME under $PERLBREW_ROOT"
    fi
    [ -x "$PERL_BIN" ] || fail "perlbrew did not create $PERL_BIN"
    "$PERL_BIN" -e "exit(\$] == $JENKINS_PERL_NUMBER ? 0 : 1)" </dev/null ||
        fail "$PERL_BIN is not Perl $JENKINS_PERL_SHORT; refusing to go on"
    PATH="$JENKINS_PERL_BIN_DIR:$PATH"
    export PATH
}

# Puts cpanm inside the 5.38.2 tree. The bootstrap is downloaded to a
# file first: piped in, with standard input closed, it installs nothing.
jenkins_install_cpanm() {
    CPANM_SCRIPT="$JENKINS_PERL_BIN_DIR/cpanm"
    if [ -x "$CPANM_SCRIPT" ] &&
        "$CPANM_SCRIPT" --version </dev/null 2>/dev/null | grep -Fq "version $JENKINS_CPANM_VERSION"; then
        jenkins_say "cpanm $JENKINS_CPANM_VERSION is already in $JENKINS_PERL_NAME"
        return 0
    fi
    jenkins_say "installing cpanm $JENKINS_CPANM_VERSION into $JENKINS_PERL_NAME"
    cpanm_bootstrap="$JENKINS_WORK/jenkins-cpanm-bootstrap.pl"
    download_to_path "$JENKINS_CPANM_BOOTSTRAP_URL" "$cpanm_bootstrap"
    jenkins_run "$PERL_BIN" "$cpanm_bootstrap" --notest "App::cpanminus@$JENKINS_CPANM_VERSION" ||
        fail "Unable to install cpanm $JENKINS_CPANM_VERSION into $JENKINS_PERL_NAME"
    [ -x "$CPANM_SCRIPT" ] || fail "cpanm is missing from $JENKINS_PERL_BIN_DIR"
}

# On macOS native builds must find Homebrew's OpenSSL 3 (Net::SSLeay).
jenkins_openssl_env() {
    [ "$PLATFORM" = 'darwin' ] || return 0
    RC_FILE=''
    OPENSSL_PREFIX=''
    export_darwin_openssl_env
    [ -n "${OPENSSL_PREFIX:-}" ] ||
        fail "Homebrew openssl@3 was not found; Net::SSLeay cannot be built without it"
    PATH="$JENKINS_PERL_BIN_DIR:$OPENSSL_PREFIX/bin:$PATH"
    export PATH
}

# Says whether a pinned distribution file is already recorded as
# installed in the 5.38.2 tree. Reads both .meta locations: directly
# under the site folder and under the arch folder, because the layout
# differs between machines. A missing or empty site folder means the
# distribution is not installed, and the glob is never left literal.
jenkins_dist_installed() {
    [ -n "$JENKINS_SITE_DIR" ] && [ -d "$JENKINS_SITE_DIR" ] || return 1
    for jenkins_meta in "$JENKINS_SITE_DIR"/.meta/*/install.json "$JENKINS_SITE_DIR"/*/.meta/*/install.json; do
        [ -f "$jenkins_meta" ] || continue
        if grep -Fqs "\"pathname\":\"$1\"" "$jenkins_meta"; then
            return 0
        fi
    done
    return 1
}

# Writes the pathname of every installed pinned distribution, one per
# line. Reads each install.json on its own: real cpanm writes install.json
# with no trailing newline, so catting them all together merges them into
# one line and a single sed pass would keep only the last pathname.
# Reads both .meta locations, directly under the site folder and under the
# arch folder, because the layout differs between machines.
jenkins_installed_pathnames() {
    [ -n "$JENKINS_SITE_DIR" ] && [ -d "$JENKINS_SITE_DIR" ] || return 0
    for jenkins_meta in "$JENKINS_SITE_DIR"/.meta/*/install.json "$JENKINS_SITE_DIR"/*/.meta/*/install.json; do
        [ -f "$jenkins_meta" ] || continue
        sed -n 's/.*"pathname":"\([^"]*\)".*/\1/p' "$jenkins_meta"
    done
}

jenkins_list_lines() {
    sed -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# Installs the pinned list in list order, one distribution at a time,
# without running their tests, and stops at the first that fails.
jenkins_install_pinned_list() {
    [ -f "$JENKINS_LIST" ] || fail "Missing pinned list: $JENKINS_LIST"
    jenkins_list_copy="$JENKINS_WORK/pinned-list.txt"
    jenkins_list_lines "$JENKINS_LIST" > "$jenkins_list_copy"
    jenkins_total=$(wc -l < "$jenkins_list_copy" | tr -d '[:space:]')
    jenkins_say "the $jenkins_total pinned distributions, in list order"
    jenkins_new=0
    while IFS= read -r jenkins_dist; do
        if jenkins_dist_installed "$jenkins_dist"; then
            continue
        fi
        rm -f "$JENKINS_TESTED_STAMP"
        jenkins_run run_cpanm --notest \
            --mirror https://cpan.metacpan.org --mirror https://backpan.perl.org \
            "$jenkins_dist" ||
            fail "Unable to install pinned distribution $jenkins_dist"
        jenkins_new=$((jenkins_new + 1))
        say "OK $jenkins_dist"
    done < "$jenkins_list_copy"
    jenkins_say "$jenkins_new of $jenkins_total installed now, the rest were already there"
}

# Runs the own tests of the distributions that hold compiled code, then
# removes the test-only helpers those tests pull in.
jenkins_test_compiled_list() {
    [ -f "$JENKINS_COMPILED_LIST" ] || fail "Missing compiled list: $JENKINS_COMPILED_LIST"
    if [ -f "$JENKINS_TESTED_STAMP" ]; then
        jenkins_say "the compiled distributions already passed their own tests"
        return 0
    fi
    jenkins_compiled_copy="$JENKINS_WORK/compiled-list.txt"
    jenkins_list_lines "$JENKINS_COMPILED_LIST" > "$jenkins_compiled_copy"
    jenkins_say "the own tests of the compiled distributions"
    while IFS= read -r jenkins_dist; do
        jenkins_run run_cpanm --test-only "$jenkins_dist" ||
            fail "Compiled distribution $jenkins_dist failed its own tests"
        say "TESTED OK $jenkins_dist"
    done < "$jenkins_compiled_copy"
    for jenkins_helper in $JENKINS_TEST_ONLY_HELPERS; do
        if "$PERL_BIN" "-M$jenkins_helper" -e 1 </dev/null >/dev/null 2>&1; then
            jenkins_run run_cpanm --uninstall -f "$jenkins_helper" ||
                fail "Unable to remove the test-only helper $jenkins_helper"
        fi
    done
    : > "$JENKINS_TESTED_STAMP" || fail "Unable to write $JENKINS_TESTED_STAMP"
}

jenkins_create_agent_root() {
    mkdir -p "$JENKINS_AGENT_ROOT" || fail "Unable to create $JENKINS_AGENT_ROOT"
}

jenkins_java_command() {
    if [ "$PLATFORM" = 'darwin' ]; then
        jenkins_java_prefix=$(brew --prefix "openjdk@$JENKINS_JAVA_MAJOR" 2>/dev/null || true)
        printf '%s\n' "$jenkins_java_prefix/bin/java"
        return 0
    fi
    command -v java 2>/dev/null || printf '%s\n' 'java'
}

# The final check: Java, the Perl, cpanm, the installed distributions
# against the pinned list, the key modules and the agent root.
jenkins_verify() {
    jenkins_say "final check"
    jenkins_java=$(jenkins_java_command)
    jenkins_java_text=$("$jenkins_java" -version 2>&1 </dev/null) ||
        fail "Java did not run: $jenkins_java"
    printf '%s\n' "$jenkins_java_text" | grep -Fq "version \"$JENKINS_JAVA_MAJOR." ||
        fail "$jenkins_java is not Java $JENKINS_JAVA_MAJOR"

    "$PERL_BIN" -e "exit(\$] == $JENKINS_PERL_NUMBER ? 0 : 1)" </dev/null ||
        fail "$PERL_BIN is not Perl $JENKINS_PERL_SHORT"
    "$CPANM_SCRIPT" --version </dev/null 2>/dev/null | grep -Fq "version $JENKINS_CPANM_VERSION" ||
        fail "$CPANM_SCRIPT is not cpanm $JENKINS_CPANM_VERSION"

    jenkins_want="$JENKINS_WORK/want.txt"
    jenkins_have="$JENKINS_WORK/have.txt"
    LC_ALL=C sort "$JENKINS_WORK/pinned-list.txt" > "$jenkins_want"
    jenkins_installed_pathnames | LC_ALL=C sort -u > "$jenkins_have"
    if ! cmp -s "$jenkins_want" "$jenkins_have"; then
        diff "$jenkins_want" "$jenkins_have" >&2 || true
        fail "The installed distributions differ from the pinned list $JENKINS_LIST"
    fi

    for jenkins_module in $JENKINS_KEY_MODULES; do
        "$PERL_BIN" "-M$jenkins_module" -e 1 </dev/null ||
            fail "$jenkins_module does not load in $JENKINS_PERL_NAME"
    done
    [ -d "$JENKINS_AGENT_ROOT" ] || fail "Missing agent root $JENKINS_AGENT_ROOT"
}

jenkins_main() {
    trap 'jenkins_on_exit $?' EXIT
    JENKINS_WORK=$(mktemp -d "${TMPDIR:-/tmp}/developer-dashboard-jenkins.XXXXXX") ||
        fail "Unable to create a work folder under ${TMPDIR:-/tmp}"
    jenkins_detect_platform
    jenkins_macos_node_settings
    jenkins_install_system_packages
    jenkins_build_perl
    jenkins_install_cpanm
    jenkins_openssl_env
    jenkins_install_pinned_list
    jenkins_test_compiled_list
    jenkins_create_agent_root
    jenkins_verify
    JENKINS_FINISHED='1'
    jenkins_say "DONE. This machine is ready to be a Jenkins test node: $JENKINS_PERL_NAME under \$HOME/perl5/perlbrew, $jenkins_total pinned distributions, agent root \$HOME/jenkins."
}

# Arguments.
#   (none)      Install Developer Dashboard for this user. This is the
#               only path there was before arguments existed, and it is
#               unchanged.
#   --jenkins   Set this machine up as a Jenkins test node instead
#               (macOS, Debian and Ubuntu). It does not install the
#               dashboard and does not edit shell rc files.
# Anything else is refused before anything is installed or changed.
usage() {
    printf '%s\n' 'Usage: install.sh [--jenkins]' >&2
    printf '%s\n' '  (no argument)  install Developer Dashboard for this user' >&2
    printf '%s\n' '  --jenkins      set this machine up as a Jenkins test node' >&2
}

if [ "$#" -eq 0 ]; then
    main
elif [ "$#" -eq 1 ] && [ "$1" = '--jenkins' ]; then
    jenkins_main
else
    printf '%s\n' "install.sh: unknown argument: $*" >&2
    usage
    exit 2
fi
