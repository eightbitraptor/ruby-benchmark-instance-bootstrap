#!/usr/bin/env bash
set -euo pipefail
if [[ ${BENCH_DEBUG:-0} == 1 ]]; then
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
FILES_DIR="$REPO_DIR/files"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "error: must be run with sudo" >&2
    exit 1
fi

TARGET_USER=${SUDO_USER:-ubuntu}
if ! id "$TARGET_USER" &> /dev/null; then
    echo "error: target user '$TARGET_USER' does not exist" >&2
    exit 1
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
SRC_DIR="$TARGET_HOME/src"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warn: %s\033[0m\n' "$*"; }

as_user() {
    sudo -u "$TARGET_USER" -H bash -lc "$*"
}

ensure_dir() {
    install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$1"
}

phase_preflight() {
    step "preflight"
    info "user=$TARGET_USER  home=$TARGET_HOME"

    . /etc/os-release
    if [[ ${ID:-} != ubuntu ]]; then
        warn "expected Ubuntu, got ID=${ID:-unknown}"
    fi
    if [[ ${VERSION_ID:-} != 26.04 ]]; then
        warn "expected Ubuntu 26.04, got ${VERSION_ID:-unknown} — continuing"
    fi

    ensure_dir "$SRC_DIR"
}

phase_packages() {
    step "apt packages"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local pkgs=(
        autoconf
        bison
        build-essential
        ca-certificates
        clang
        cmake
        curl
        gdb
        git
        libdb-dev
        libffi-dev
        libgdbm-compat-dev
        libgdbm-dev
        libgmp-dev
        libncurses-dev
        libreadline-dev
        libssl-dev
        libyaml-dev
        libz3-dev
        lld
        llvm
        neovim
        pkg-config
        rsync
        ruby
        ruby-dev
        siege
        sudo
        tmux
        uuid-dev
        valgrind
        vim
        zlib1g-dev

        bpfcc-tools
        bpftrace
        libbpfcc

        linux-tools-common
        linux-tools-generic
    )

    apt-get install -y -qq --no-install-recommends "${pkgs[@]}"

    local kver perf_pkg
    kver=$(uname -r)
    perf_pkg="linux-tools-$kver"
    if apt-cache show "$perf_pkg" &> /dev/null; then
        apt-get install -y -qq --no-install-recommends "$perf_pkg" || \
            warn "could not install $perf_pkg"
    elif [[ $kver == *-aws ]]; then
        apt-get install -y -qq --no-install-recommends linux-tools-aws || \
            warn "could not install linux-tools-aws"
    else
        warn "no kernel-specific perf package for $kver"
    fi
}

phase_chruby() {
    step "chruby"

    if [[ -f /usr/local/share/chruby/chruby.sh ]]; then
        info "chruby already installed, skipping download"
    else
        local tag tarball workdir
        tag=$(curl -fsSL https://api.github.com/repos/postmodern/chruby/releases/latest \
            | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
        if [[ -z $tag ]]; then
            echo "error: could not resolve latest chruby release" >&2
            exit 1
        fi
        info "installing chruby $tag"
        workdir=$(mktemp -d)
        trap 'rm -rf "$workdir"' RETURN
        tarball="$workdir/chruby-$tag.tar.gz"
        curl -fsSL "https://github.com/postmodern/chruby/releases/download/v$tag/chruby-$tag.tar.gz" \
            -o "$tarball"
        tar -xzf "$tarball" -C "$workdir"
        ( cd "$workdir/chruby-$tag" && make install )
    fi

    cat > /etc/profile.d/chruby.sh <<'EOF'
if [ -f /usr/local/share/chruby/chruby.sh ]; then
    . /usr/local/share/chruby/chruby.sh
fi
EOF
    chmod 0644 /etc/profile.d/chruby.sh
    info "/etc/profile.d/chruby.sh installed (auto.sh intentionally not sourced)"

    ensure_dir "$TARGET_HOME/.rubies"
}

phase_rustup() {
    step "rustup (stable + nightly)"

    cat > /etc/profile.d/cargo.sh <<'EOF'
if [ -d "$HOME/.cargo/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.cargo/bin:"*) ;;
        *) PATH="$HOME/.cargo/bin:$PATH" ;;
    esac
fi
EOF
    chmod 0644 /etc/profile.d/cargo.sh

    if as_user 'command -v rustup >/dev/null'; then
        info "rustup present, updating toolchains"
        as_user 'rustup self update >/dev/null 2>&1 || true'
        as_user 'rustup update stable nightly'
    else
        info "installing rustup"
        as_user 'curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable'
        as_user 'rustup toolchain install nightly'
    fi
}

clone_or_update() {
    local target=$1 origin=$2 upstream=$3
    if [[ -d $target/.git ]]; then
        info "exists: $target"
    else
        info "cloning $origin -> $target"
        as_user "git clone --filter=blob:none '$origin' '$target'"
    fi
    as_user "cd '$target' && git remote set-url origin '$origin'"
    if as_user "cd '$target' && git remote get-url upstream" &> /dev/null; then
        as_user "cd '$target' && git remote set-url upstream '$upstream'"
    else
        as_user "cd '$target' && git remote add upstream '$upstream'"
    fi
}

phase_repos() {
    step "repositories"
    ensure_dir "$SRC_DIR"

    clone_or_update "$SRC_DIR/ruby" \
        https://github.com/eightbitraptor/ruby.git \
        https://github.com/ruby/ruby.git

    clone_or_update "$SRC_DIR/ruby-bench" \
        https://github.com/eightbitraptor/ruby-bench.git \
        https://github.com/ruby/ruby-bench.git

    if [[ ! -d $SRC_DIR/FlameGraph/.git ]]; then
        info "cloning FlameGraph"
        as_user "git clone --depth 1 https://github.com/brendangregg/FlameGraph.git '$SRC_DIR/FlameGraph'"
    else
        info "exists: $SRC_DIR/FlameGraph"
    fi
}

phase_build_ruby() {
    step "build-ruby script"
    install -d /usr/local/bin
    install -m 0755 "$FILES_DIR/build-ruby" /usr/local/bin/build-ruby
    info "/usr/local/bin/build-ruby installed"
}

phase_autoclave() {
    step "autoclave"
    if command -v autoclave &> /dev/null; then
        info "autoclave already installed"
        return
    fi
    local workdir
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' RETURN
    git clone --depth 1 https://github.com/silentbicycle/autoclave "$workdir/autoclave"
    install -d /usr/local/share/man/man1
    ( cd "$workdir/autoclave" && make && make install PREFIX=/usr/local )
}

phase_tuning() {
    step "benchmarking stability tweaks"
    install -d /usr/local/sbin /etc/systemd/system
    install -m 0755 "$FILES_DIR/bench-tuning" /usr/local/sbin/bench-tuning
    install -m 0644 "$FILES_DIR/bench-tuning.service" /etc/systemd/system/bench-tuning.service
    systemctl daemon-reload
    systemctl enable bench-tuning.service >/dev/null
    /usr/local/sbin/bench-tuning
}

phase_summary() {
    step "summary"
    cat <<EOF
    target user      : $TARGET_USER
    repos            : $SRC_DIR/{ruby,ruby-bench,FlameGraph}
    build-ruby       : /usr/local/bin/build-ruby
    chruby           : /usr/local/share/chruby (sourced via /etc/profile.d/chruby.sh)
    tuning service   : systemctl status bench-tuning.service
    perf paranoid    : $(cat /proc/sys/kernel/perf_event_paranoid)
    governor         : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
    turbo (no_turbo) : $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo unknown)
    SMT              : $(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo unknown)
    THP              : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo unknown)
    ASLR             : $(cat /proc/sys/kernel/randomize_va_space)

Re-run this script any time. To apply tuning without re-running everything:
    sudo systemctl start bench-tuning.service
EOF
}

main() {
    phase_preflight
    phase_packages
    phase_chruby
    phase_rustup
    phase_repos
    phase_build_ruby
    phase_autoclave
    phase_tuning
    phase_summary
}

main "$@"
