# benchmark-instance-bootstrap

Idempotent bootstrap for a Ruby benchmarking instance on **Ubuntu 26.04** running
on an **AWS c6i bare-metal** node (`c6i.metal` / `c6i.32xlarge` family).

Provisions everything needed to build arbitrary Ruby branches, run
[`ruby-bench`](https://github.com/eightbitraptor/ruby-bench), the in-tree
benchmark suite, and to gather `perf` / `bpftrace` / flamegraph data.

## Usage

```sh
git clone https://github.com/eighbitraptor/benchmark-instance-bootstrap.git
cd benchmark-instance-bootstrap
sudo ./bootstrap.sh
```

Run again any time. Every phase is idempotent and converges back to a working
setup. To re-apply only the stability tweaks (e.g. after a reboot when the
service hasn't been started yet):

```sh
sudo systemctl start bench-tuning.service
```

The script must be run with `sudo`. It uses `$SUDO_USER` (falling back to
`ubuntu`) as the **target user** that owns clones, rustup, and the per-user
`~/.rubies` directory.

## What it installs

### Toolchain

| Component | Source | Notes |
|---|---|---|
| Ruby build deps | apt | `autoconf bison build-essential libssl-dev libyaml-dev libreadline-dev libgdbm-dev libffi-dev libdb-dev libgmp-dev libncurses-dev uuid-dev zlib1g-dev` + a bootstrap `ruby` for `make` |
| clang / lld / llvm | apt | For sanitizer (`asan`/`tsan`) builds via `build-ruby` |
| chruby | source (latest GitHub release) | Installed under `/usr/local/share/chruby`. Only `chruby.sh` is sourced globally via `/etc/profile.d/chruby.sh` — `auto.sh` is **deliberately not sourced**. Skipped entirely if already installed. |
| rustup | upstream installer | Per-user under `~/.cargo`. Both `stable` and `nightly` toolchains installed. Updated in place if already present. |

### Tools

| Tool | Source | Purpose |
|---|---|---|
| `perf` | apt (`linux-tools-$(uname -r)` or `linux-tools-aws`) | Profiling |
| `valgrind` | apt | Memory checking |
| `bpftrace`, `bpfcc-tools` | apt | eBPF tracing |
| `gdb` | apt | Debugger |
| `siege` | apt | HTTP load generator |
| `autoclave` | source (`silentbicycle/autoclave`) | Crash-loop harness — built into `/usr/local/bin` |
| FlameGraph | git clone | `~/src/FlameGraph` — `stackcollapse-perf.pl` + `flamegraph.pl` |
| `vim`, `neovim`, `tmux`, `git` | apt | Editors / TUI |

### Repositories (cloned over HTTPS into `~/src/`)

| Path | `origin` | `upstream` |
|---|---|---|
| `~/src/ruby` | `https://github.com/eightbitraptor/ruby.git` | `https://github.com/ruby/ruby.git` |
| `~/src/ruby-bench` | `https://github.com/eightbitraptor/ruby-bench.git` | `https://github.com/ruby/ruby-bench.git` |
| `~/src/FlameGraph` | `https://github.com/brendangregg/FlameGraph.git` | — |

Clones use `--filter=blob:none` for fast initial fetch. Re-running the script
does **not** pull — it only ensures remotes are wired up correctly.

### `build-ruby`

The `build-ruby` script (vendored from `~/nixconf/modules/features/rubyDev/scripts/build-ruby`)
is installed to `/usr/local/bin/build-ruby`. Run it inside a Ruby source tree:

```sh
cd ~/src/ruby
build-ruby fast yjit              # release build with YJIT
build-ruby debug gc-check tsan    # debug build with full RGENGC checks + tsan
build-ruby --help
```

It writes builds into `~/.rubies/` so `chruby` picks them up.

## Benchmarking stability tweaks

All runtime tweaks are applied by `/usr/local/sbin/bench-tuning`, invoked by a
oneshot systemd unit (`bench-tuning.service`) wired to `multi-user.target`. The
unit is enabled on first run and the script is executed immediately so you
don't need to reboot.

| Setting | Path | Value |
|---|---|---|
| Turbo Boost | `/sys/devices/system/cpu/intel_pstate/no_turbo` (fallback: `cpufreq/boost`) | `1` (off) |
| CPU governor | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | `performance` |
| SMT (hyperthreading) | `/sys/devices/system/cpu/smt/control` | `off` |
| ASLR | `/proc/sys/kernel/randomize_va_space` | `0` |
| NMI watchdog | `/proc/sys/kernel/nmi_watchdog` | `0` |
| `perf_event_paranoid` | `/proc/sys/kernel/perf_event_paranoid` | `-1` (unprivileged perf) |
| `kptr_restrict` | `/proc/sys/kernel/kptr_restrict` | `0` (kernel symbols visible to perf) |
| `ptrace_scope` | `/proc/sys/kernel/yama/ptrace_scope` | `0` (attach to any process) |
| Transparent Hugepages | `/sys/kernel/mm/transparent_hugepage/enabled` | `never` |
| THP defrag | `/sys/kernel/mm/transparent_hugepage/defrag` | `never` |

**No kernel command-line changes.** This is deliberate: bad cmdline args can
render an AWS instance unbootable and we don't want to deal with that. CPU
isolation (`isolcpus`, `nohz_full`) is also intentionally omitted — use
`taskset` / `chrt` per-run when you need pinning. SMT being `off` halves
logical CPU count, which is what you want for repeatable single-threaded
numbers; if you're explicitly testing multi-threaded scaling you can flip it
back on:

```sh
echo on | sudo tee /sys/devices/system/cpu/smt/control
```

The tweaks are reapplied on every boot by the systemd unit. They are also
reapplied immediately each time you re-run `bootstrap.sh`.

## Repository layout

```
.
├── README.md
├── bootstrap.sh                # entry point — phased, idempotent
└── files/
    ├── build-ruby              # vendored copy, installed to /usr/local/bin
    ├── bench-tuning            # installed to /usr/local/sbin
    └── bench-tuning.service    # installed to /etc/systemd/system
```

## Verifying a fresh box

After `bootstrap.sh` returns, the summary at the end prints the live values of
governor / turbo / SMT / THP / ASLR / `perf_event_paranoid`. Spot-check:

```sh
perf stat -e cycles,instructions -- ruby -e '1_000_000.times{}'
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { @[comm] = count(); }'
```

If `perf` complains about `perf_event_paranoid`, the tuning service didn't run
— `sudo systemctl start bench-tuning.service` and check
`journalctl -u bench-tuning.service`.

## Updating Ruby branches

Nothing in the bootstrap manages your working trees beyond the initial clone.
Day-to-day workflow:

```sh
cd ~/src/ruby
git fetch upstream
git checkout some-branch
build-ruby fast yjit
chruby ruby-fast-yjit            # or whatever name build-ruby chose
```
