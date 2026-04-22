#!/bin/sh

set -eu

SCRIPT_DIR=$(
    CDPATH= cd -- "$(dirname -- "$0")" && pwd
)
APTFILE="$SCRIPT_DIR/aptfile"
BREWFILE="$SCRIPT_DIR/brewfile"
APTFILE_DEFAULT_CONTENT='
# Repo bootstrap packages for Debian-family hosts.
build-essential
ca-certificates
cpanminus
curl
git
libexpat1-dev
libssl-dev
npm
nodejs
perl
perlbrew
pkg-config
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
'
INSTALL_ROOT="${HOME:?Missing HOME}/perl5"
CPAN_TARGET="${DD_INSTALL_CPAN_TARGET:-Developer::Dashboard}"
OS_OVERRIDE="${DD_INSTALL_OS_OVERRIDE:-}"
PERLBREW_ROOT="${PERLBREW_ROOT:-$INSTALL_ROOT/perlbrew}"
PERLBREW_HOME="${PERLBREW_HOME:-$PERLBREW_ROOT}"
PERLBREW_PERL="${DD_INSTALL_PERLBREW_PERL:-perl-5.38.5}"
MIN_PERL_VERSION='5.038'
PERL_BIN=''
CPANM_SCRIPT=''
RC_FILE=''

say() {
    printf '%s\n' "$*"
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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
        brewfile)
            printf '%s\n' "$BREWFILE_DEFAULT_CONTENT" | sed \
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
                    *ubuntu*|*debian*)
                        printf '%s\n' "${os_id:-linux}"
                        return 0
                        ;;
                esac
            fi
            [ -f /etc/debian_version ] && {
                printf '%s\n' 'debian'
                return 0
            }
            ;;
    esac

    fail "Unsupported platform. Supported platforms are Debian, Ubuntu, and macOS."
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
    shell_name=$(basename "${SHELL:-sh}")
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

install_apt_packages() {
    prefix=$(package_runner_prefix)
    packages=$(manifest_packages "$APTFILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    say "Installing Debian-family packages from $APTFILE: $packages"
    if [ -n "$prefix" ]; then
        $prefix apt-get update
        $prefix apt-get install -y $packages
    else
        apt-get update
        apt-get install -y $packages
    fi
}

install_brew_packages() {
    require_command brew
    packages=$(manifest_packages "$BREWFILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$packages" ] || return 0
    say "Installing Homebrew packages from $BREWFILE: $packages"
    brew install $packages
}

ensure_node_toolchain() {
    require_command node
    require_command npm
    require_command npx
}

bootstrap_perlbrew_perl() {
    export PERLBREW_ROOT
    export PERLBREW_HOME

    if ! command -v perlbrew >/dev/null 2>&1; then
        require_command cpanm
        say "perlbrew is not on PATH; installing App::perlbrew into $INSTALL_ROOT"
        run_cpanm --local-lib-contained "$INSTALL_ROOT" App::perlbrew
        PATH="$INSTALL_ROOT/bin:$PATH"
        export PATH
    fi

    require_command perlbrew

    say "System Perl is older than $MIN_PERL_VERSION; bootstrapping $PERLBREW_PERL with perlbrew under $PERLBREW_ROOT"
    mkdir -p "$PERLBREW_ROOT"
    perlbrew init
    if ! perlbrew list | grep -Fq "$PERLBREW_PERL"; then
        perlbrew install "$PERLBREW_PERL"
    fi

    PERL_BIN="$PERLBREW_ROOT/perls/$PERLBREW_PERL/bin/perl"
    [ -x "$PERL_BIN" ] || fail "perlbrew did not create $PERL_BIN"
    if [ ! -x "$PERLBREW_ROOT/bin/cpanm" ]; then
        perlbrew install-cpanm
    fi
    CPANM_SCRIPT="$PERLBREW_ROOT/bin/cpanm"
    [ -x "$CPANM_SCRIPT" ] || fail "perlbrew did not create $CPANM_SCRIPT"

    PERLBREW_PATH_LINE=$(printf 'export PATH="%s/perls/%s/bin:$PATH"' "$PERLBREW_ROOT" "$PERLBREW_PERL")
    append_once "$RC_FILE" "$PERLBREW_PATH_LINE"
    PATH="$PERLBREW_ROOT/bin:$PERLBREW_ROOT/perls/$PERLBREW_PERL/bin:$PATH"
    export PATH
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
        debian|ubuntu)
            bootstrap_perlbrew_perl
            return 0
            ;;
    esac

    fail "Perl $MIN_PERL_VERSION or newer is required."
}

run_cpanm() {
    cpanm_script=${CPANM_SCRIPT:-$(command -v cpanm)}
    [ -n "$cpanm_script" ] || fail "Missing required command: cpanm"
    "$cpanm_script" "$@"
}

bootstrap_local_lib() {
    require_command cpanm
    resolve_perl

    mkdir -p "$INSTALL_ROOT"
    run_cpanm --local-lib-contained "$INSTALL_ROOT" local::lib App::cpanminus

    LOCAL_LIB_LINE=$(printf 'eval "$("%s" -I "%s/lib/perl5" -Mlocal::lib)"' "$PERL_BIN" "$INSTALL_ROOT")
    append_once "$RC_FILE" "$LOCAL_LIB_LINE"

    # shellcheck disable=SC2046
    eval "$("$PERL_BIN" -I "$INSTALL_ROOT/lib/perl5" -Mlocal::lib)"
}

install_dashboard() {
    run_cpanm --notest "$CPAN_TARGET"
    require_command dashboard
    dashboard init
}

main() {
    PLATFORM=$(platform_name)
    RC_FILE=$(choose_rc_file)
    case "$PLATFORM" in
        debian|ubuntu)
            install_apt_packages
            ;;
        darwin)
            install_brew_packages
            ;;
        *)
            fail "Unsupported platform '$PLATFORM'. Supported platforms are Debian, Ubuntu, and macOS."
            ;;
    esac
    ensure_node_toolchain
    bootstrap_local_lib
    install_dashboard
    say "Developer Dashboard is installed and initialized."
}

main "$@"
