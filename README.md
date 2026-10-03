# CI Files for klp-built Kernel

This repository holds GitHub Actions CI configuration for the `linux/` kernel repository at `Linux-Live-Patching-CI/linux.git`.

## Layout

- **`.github/workflows/`** — what runs on each push and PR.
- **`.github/actions/`** — composite actions the workflows share.
- **`ci/`** — what the workflows use from the tree outside `.github/`: kernel config fragments (`ci/configs/`) and the script the test VM runs (`ci/vmtest/`).
- **`patches/`** — changes to the kernel tree itself, reapplied on every sync.
- **`sync.sh`** — the synchronization script (see below).

`patches/` exists because `sync.sh` resets `linux/` to upstream, which throws away anything that is not upstream: a fix to the kernel tree cannot simply be committed there, it would last until the next sync. Patches here are applied with `git am` after the reset, and are deleted from here once upstream carries the change. A patch that stops applying aborts the sync rather than pushing a half-applied tree — that is the signal it has landed upstream, or that upstream moved under it.

`sync.sh` also copies the top-level `ci/` directory, for the things a workflow needs but cannot keep under `.github/` — kernel config fragments and scripts that run inside the test VM. Workflows refer to it by workspace-relative path (`ci/...`), the same arrangement as in comparable trees (`libbpf/libbpf`, `kernel-patches/vmtest`).

## Workflow

The `linux/` repository tracks an upstream kernel branch (`tip/objtool/core`) and must remain a clean mirror of it. Since upstream branches get rebased frequently, we cannot store CI configuration directly in `linux/` — it would conflict with force-push/rebase cycles.

Instead, CI config lives here in `ci_files`, and a script (`sync.sh`) re-applies it on top of fresh upstream source each time.

### Synchronizing with Upstream

To pick up new upstream commits and re-apply CI files:

```bash
cd /path/to/ci_files
./sync.sh /path/to/linux
```

The script will:
1. Fetch `tip/objtool/core` from kernel.org.
2. Reset `linux/main` to match upstream.
3. Copy `.github/` and `ci/` from `ci_files` into `linux/`.
4. Create a commit: `Add CI files from ci_files@<SHA>`.
5. Force-push to `origin/main` (i.e., `Linux-Live-Patching-CI/linux.git`).

The script prompts for confirmation before each destructive operation (reset, force-push).

## CI Jobs

### `objtool-klp-tests` workflow

**Trigger:** On every push or PR to `linux/` `main`.

**Compiler Matrix:** `gcc-11`, `gcc-13`, `clang-18` — all from the `ubuntu-latest` (24.04) archive.

Adding a version the archive does not carry takes more than an entry in the list: it needs `apt.llvm.org`, and specifically their `llvm.sh`, which installs the signing key — adding that repository by hand leaves apt rejecting it as unsigned. Until then the setup action refuses it up front, naming the package and printing its `apt-cache policy`, rather than letting `apt-get` report a bare "no installation candidate".

**Two independent jobs, run in parallel:**

| Job | What it does | Roughly |
| --- | --- | --- |
| `objtool-tests` | `make -C tools/objtool tests` | a few minutes |
| `kernel` | builds a kernel configured for livepatch, boots it and runs the livepatch selftests | ~25 minutes, plus a few for the VM |

They are separate because the tests do not consume the kernel build: objtool is a host tool and the tests compile their own fixtures. Sequencing them would only mean a broken kernel build costs the test results too.

Both are driven by the same list of names, and `.github/actions/setup-toolchain` turns a name into packages and make arguments, so the two jobs cannot disagree about what `gcc-11` means. Adding a compiler is one entry in each list.

Dependencies come from that action: `build-essential`, `flex`, `bison`, `bc`, `libssl-dev`, `libelf-dev`, `libxxhash-dev`. The last is easy to miss — without it objtool still builds, and then every test bails with "objtool was built without klp support".

**Selecting the compiler:** the action emits `CC=gcc-11`, or `LLVM=-18` for clang (the kernel's documented form for a versioned LLVM toolchain, which also points `ld.lld`, `llvm-objcopy` and `llvm-readelf` at the matching version). It is passed **as a make argument, never through the environment**. `CC=gcc-11 make …` does not work: the kernel's Makefile assigns `CC` itself and a makefile assignment beats the environment, so the job silently builds with the runner's default compiler and the matrix tests one toolchain four times over. That happened, and nothing caught it — so each job now asserts the compiler it ended up with, and fails loudly on a mismatch rather than going quietly green.

**Caching:** the kernel build output is cached per entry and commit. A miss only slows `kernel`; `objtool-tests` does not use it.

**Failure Handling:**
- `fail-fast: false`, so one toolchain's failure is a result about that toolchain rather than a reason to cancel the others.
- On a test failure the job uploads the per-test working directories (`/tmp/klp-tests.*`: the fixtures, `out.o` and `diff.log` of whichever test failed), the `objtool` binary and the test log, kept for 7 days. That set is what makes a CI-only failure debuggable offline — the fixture objects feed straight back into a local `objtool klp diff`, which is how the IBT failure below was diagnosed.

**Reading the results:** each run prints a preflight banner recording the objtool path, the compiler, the architecture and the `-fcf-protection` setting the fixtures were built with. When a test only fails on one toolchain, that banner is the first place to look.

### The `kernel` job: livepatch selftests

`kernel` calls the reusable workflow `kernel-build-test.yml` once per toolchain. Inside, two jobs run in sequence and show up as `kernel gcc-11 / build` and `kernel gcc-11 / livepatch selftests`:

1. **`build`** configures `defconfig` + `tools/testing/selftests/livepatch/config` + `ci/configs/livepatch.config`, builds the kernel, builds the selftests and their test modules against it (`kselftest-install` with `KDIR` pointing at the build), and uploads the image, the `.config` and the installed selftests as one artifact, `livepatch-selftests-<toolchain>`.
2. **`livepatch selftests`** boots that kernel under [vmtest](https://github.com/danobi/vmtest) — QEMU, with the runner's own root filesystem shared into the guest — and runs `ci/vmtest/run-livepatch-selftests.sh` there.

It is a reusable workflow rather than two matrix jobs because a job can only wait on a *whole* matrix: every toolchain's tests would wait for the slowest build, and be skipped outright if any one build failed.

This kernel has `CONFIG_LIVEPATCH`, and with it `CONFIG_KLP_BUILD`, which the old `defconfig` smoke build never had.

Each of these fails the run, because each is a way for it to go green having tested nothing:

- **An option the fragments ask for is not in the final `.config`.** Kconfig drops an option whose dependencies are unmet without a word. The selftests fragment asks for `CONFIG_LIVEPATCH=y`, which `defconfig` cannot satisfy — it needs the function tracer — so without `ci/configs/livepatch.config` the kernel builds, every test skips, and the run passes. The configure step names every option that did not survive.
- **A test skips.** Every skip in this suite is the environment falling short, and `run_kselftest.sh` exits 0 when everything skips. For one, `functions.sh` skips every test unless `$KDIR` names a directory, and its default — the running kernel's `/lib/modules/*/build` — does not exist in the VM, so the guest script sets it.
- **A test reports xfail.** No test here expects to fail; xfail is what the runner makes of exit status 2, which is also what bash exits with on a syntax error, so a test script broken outright would pass.
- **The kernel logs a splat** — a `WARNING:` (lockdep, list corruption, any WARN), a `BUG:` (sleeping in atomic context, among others), a soft lockup, an RCU stall, a hung task. The tests look only at kernel-log lines that mention livepatch or their own modules, so a splat can go right past them. The patterns are the ones BPF CI uses, and `ci/configs/livepatch.config` turns on the detectors behind them; KASAN is left out for its cost. An oops panics the VM (`oops=panic`), which fails the step on its own.
- **No KVM.** vmtest falls back to emulation without `/dev/kvm`. The tests give up on a livepatch transition after a fixed minute, so there they would fail at random rather than say KVM is gone; the action refuses to start instead.

Each test is capped at 120 seconds, so a hang reports which test hung; the slowest test takes under half a minute, and the suite about a minute and a half, boot included.

On failure the job uploads `livepatch-selftests.log` (the KTAP output, with each failed check's expected-against-actual kernel log) and `dmesg.txt` (the full kernel log). Both are in the step output too, but interleaved with the kernel console.

**Reproducing a failure locally:** the build artifact is all the VM needs. From a checkout of `linux/`, with `vmtest`, `qemu-system-x86` and `qemu-guest-agent` installed:

```bash
gh run download <run-id> -R Linux-Live-Patching-CI/linux -n livepatch-selftests-gcc-11
mkdir vm && tar --zstd -xf livepatch-selftests.tar.zst -C vm
vmtest -k vm/bzImage --kargs oops=panic "ci/vmtest/run-livepatch-selftests.sh vm/kselftest"
```

(Downloaded from the web UI instead, the artifact is a zip with the tarball inside.) It is a tarball rather than plain files because `upload-artifact` drops file modes, and the selftests are scripts run by path.

## Past finding: the IBT failure

Worth keeping, because it is the shape of bug this CI exists to catch and it took a while to pin down.

`test-local-to-global-flip` failed on CI and passed everywhere locally. The cause was not the kernel code and not objtool: `FIXTURE_CFLAGS` did not pin `-fcf-protection`, so the fixtures inherited whatever the distribution had configured its compiler with. Ubuntu builds GCC with CET on, the Red Hat toolchains used locally do not.

With CET on, promoting a function from `static` to external gains it an `ENDBR64` landing pad — the compiler must assume an externally visible function could be an indirect-call target, where a static one reachable only by direct calls needs no pad. So the function's instructions really did change, objtool correctly reported a changed function, and the test's expectation that a pure linkage change leaves the function alone no longer held.

Fixed upstream in the tree by pinning the flag and adding `tests/x86/test-ibt-linkage-flip.sh`, which covers the IBT behaviour deliberately instead of leaving it to the compiler's default. Cloning the function is also the *safe* answer: an indirect call has to land on an `ENDBR`, and the kernel's copy is the one without it.

The lesson for this CI: a test that passes locally and fails on a runner is usually a difference in how the toolchain was *configured*, not in its version. That is why the preflight banner now records the CET setting.

## Maintenance

When adding new CI jobs or modifying workflows:
1. Edit the `.github/workflows/*.yml` files here in `ci_files`.
2. Run `sync.sh` to apply changes to `linux/`.
3. Verify the workflow runs correctly on `Linux-Live-Patching-CI/linux.git`.

If new config fragments or helper scripts are needed:
1. Add them under `ci/` — fragments to `ci/configs/`, scripts the VM runs to `ci/vmtest/`.
2. Ensure the workflow references them (e.g., fragment paths in the configure step).
3. Run `sync.sh` again.

Changes to the kernel tree itself go in `patches/` instead (see Layout).
