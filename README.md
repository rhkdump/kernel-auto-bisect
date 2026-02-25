# Automated Kernel Bisection Tool (kernel-auto-bisect)

A modular tool that automates `git bisect` to find commits that introduced kernel regressions. It supports bisecting both git source trees and lists of pre-built kernel RPMs, with two execution modes: local (using CRIU checkpoint/restore for reboots) and remote (over SSH).

## Architecture

The tool is composed of:

- **kab.sh** - Main orchestrator that drives the `git bisect` loop.
- **lib.sh** - Core library with configuration loading, logging, command execution (`run_cmd`), reboot management, CRIU setup, and kdump setup.
- **criu-daemon.sh** - Daemon that handles CRIU checkpoint/restore cycles for local execution. It checkpoints the bisect process before a reboot or kernel panic, then restores it after the system comes back.
- **bisect.conf** - Configuration file defining strategies and parameters.
- **reproducer.sh** - Template for user-provided test scripts.
- **handlers/** - Pluggable strategy handlers:
  - `install_handler.sh` - Kernel installation (from git source or RPM).
  - `reboot_handler.sh` - Reboot strategies (full reboot or kexec).
  - `test_handler.sh` - Test execution (kernel panic verification or simple exit-code test).

## How It Works

1. **Initialize**: Load configuration and handlers, set up CRIU and kdump (if using panic test strategy), clone the git repo (or generate a fake git repo from an RPM list).
2. **Verify**: Optionally verify that the GOOD commit actually passes and the BAD commit actually fails.
3. **Bisect loop**: For each commit selected by `git bisect`:
   - **Install**: Build and install the kernel from source, or install from RPM.
   - **Reboot**: Boot into the new kernel (via CRIU checkpoint/restore locally, or via SSH remotely).
   - **Test**: Run the reproducer script. For panic mode, trigger a kernel panic and verify vmcore creation. For simple mode, check the exit code.
   - **Mark**: Run `git bisect good` or `git bisect bad` based on the test result.
4. **Finish**: Generate a final bisect log and reboot to the original kernel.

## Execution Modes

### Local Mode (CRIU)

When no `KAB_TEST_HOST` is configured, the tool runs directly on the test machine. It uses CRIU to checkpoint the bisect process before rebooting or triggering a kernel panic, then restores it after the system comes back. A crontab entry ensures the CRIU daemon starts on every boot.

### Remote Mode (SSH)

When `KAB_TEST_HOST` is set, `kab.sh` runs on a controller machine and executes all commands on the remote test host over SSH. Reboots are handled by waiting for the remote host to go down and come back up. This avoids the need for CRIU.

## Prerequisites

- A RHEL-based system (Fedora, CentOS, RHEL) that uses `grubby` for managing boot entries.
- For local (CRIU) mode: `criu` and `cronie` packages.
- For git source bisection: kernel build dependencies (`gcc`, `make`, `flex`, `bison`, `openssl-devel`, etc.).
- For panic test strategy: `kexec-tools` (kdump) configured with `crashkernel` parameter.
- For remote mode: SSH access to the test host (password-less or key-based).

## Installation

```bash
sudo make install
```

This installs scripts to `/usr/local/bin/kernel-auto-bisect/` and copies the default configuration file.

To uninstall:

```bash
sudo make uninstall
```

## Configuration

Edit `/usr/local/bin/kernel-auto-bisect/bisect.conf` after installation.

### Core Strategies

| Variable | Values | Description |
|---|---|---|
| `INSTALL_STRATEGY` | `git`, `rpm` | Build from source or install pre-built RPMs |
| `TEST_STRATEGY` | `panic`, `simple` | Trigger kernel panic and verify vmcore, or just check exit code |
| `REBOOT_STRATEGY` | `reboot`, `kexec` | Full reboot or kexec (kexec falls back to full reboot with CRIU) |

### Git Source Mode

| Variable | Description |
|---|---|
| `GIT_REPO_URL` | URL of the kernel git repository to clone |
| `GIT_REPO_BRANCH` | Branch to clone |
| `GOOD_COMMIT` | Git commit hash of the known-good commit |
| `BAD_COMMIT` | Git commit hash of the known-bad commit |
| `MAKE_JOBS` | Number of parallel make jobs (defaults to `nproc`) |

### RPM Mode

| Variable | Description |
|---|---|
| `KERNEL_RPM_LIST` | Path to a file listing kernel RPM URLs, one per line (ordered from good to bad) |
| `RPM_CACHE_DIR` | Directory to cache downloaded RPMs |
| `GOOD_COMMIT` | Kernel release string of the known-good version (e.g. `5.14.0-162.el9.aarch64`) |
| `BAD_COMMIT` | Kernel release string of the known-bad version |

### Remote Mode

| Variable | Description |
|---|---|
| `KAB_TEST_HOST` | SSH target for the remote test host (e.g. `root@192.168.1.100`) |
| `KAB_TEST_HOST_SSH_KEY` | Path to SSH private key for authentication (optional) |

### Other Options

| Variable | Description |
|---|---|
| `REPRODUCER_SCRIPT` | Path to the reproducer script |
| `RUNS_PER_COMMIT` | Number of test runs per commit (for intermittent issues, default: 1) |
| `VERIFY_COMMITS` | Set to `yes` to skip initial good/bad commit verification |

## Reproducer Script

The reproducer script must define the following bash functions:

- **`setup_test()`** - Called before triggering a kernel panic. Use it to load modules, start services, etc. Only used in `panic` test strategy.
- **`on_test()`** - Called after reboot to verify the test result. Return 0 for GOOD (commit is OK), non-zero for BAD (commit has the regression).

See `reproducer.sh` for a template.

## Running the Bisection

```bash
sudo /usr/local/bin/kernel-auto-bisect/kab.sh
```

Progress is logged to `/var/local/kernel-auto-bisect/main.log`. The final bisect log is saved to `/var/local/kernel-auto-bisect/bisect_final_log.txt`.

## Tests

The project uses [tmt](https://tmt.readthedocs.io/) for integration testing and [ShellSpec](https://shellspec.info/) for unit tests. Three test plans are provided:

- **criu** (`plans/criu.fmf`) - Single-machine test using CRIU checkpoint/restore with RPM bisection.
- **ssh** (`plans/ssh.fmf`) - Two-machine test (client/server) using SSH with RPM bisection.
- **ssh_src** (`plans/ssh_src.fmf`) - Two-machine test using SSH with git source bisection.

Run all tests:

```bash
make tests
```

Individual targets:

```bash
make format-check       # Check formatting with shfmt
make static-analysis    # Run shellcheck
make integration-tests  # Run tmt integration tests
```

## Work Directory

Runtime state is stored in `/var/local/kernel-auto-bisect/`:

- `main.log` - Main bisect log
- `criu-daemon.log` - CRIU daemon log
- `git_repo/` - Git repository (real or generated from RPM list)
- `dump/` - CRIU checkpoint data
- `dump_logs/` - CRIU dump/restore logs
- `signal/` - IPC signal files between kab.sh and criu-daemon.sh
- `bisect_final_log.txt` - Final `git bisect log` output

## License

See the LICENSE file.
