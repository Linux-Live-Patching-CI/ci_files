# CI Files for klp-built Kernel

This repository holds GitHub Actions CI configuration for the `linux/` kernel repository at `Linux-Live-Patching-CI/linux.git`.

## Layout

- **`.github/workflows/`** — what runs on each push and PR.
- **`.github/actions/`** — composite actions the workflows share.
- **`patches/`** — changes to the kernel tree itself, reapplied on every sync.
- **`sync.sh`** — the synchronization script (see below).

`patches/` exists because `sync.sh` resets `linux/` to upstream, which throws away anything that is not upstream: a fix to the kernel tree cannot simply be committed there, it would last until the next sync. Patches here are applied with `git am` after the reset, and are deleted from here once upstream carries the change. A patch that stops applying aborts the sync rather than pushing a half-applied tree — that is the signal it has landed upstream, or that upstream moved under it.

`sync.sh` also copies a top-level `ci/` directory if one exists, for the things a workflow needs but cannot keep under `.github/` — patches to apply before building, kernel config fragments, helper scripts. Nothing needs it yet, so it is not there; create it when something does. This is worth knowing about in advance because workflows in comparable trees (`libbpf/libbpf`, `kernel-patches/vmtest`) reach for exactly such a directory via `${{ github.workspace }}/ci/...`, and copying only `.github/` would leave them broken.

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
| `kernel-build` | `defconfig` plus a full build, as a smoke test | ~25 minutes |

They are separate because the tests do not consume the kernel build: objtool is a host tool and the tests compile their own fixtures. Sequencing them would only mean a broken kernel build costs the test results too.

Both are driven by the same list of names, and `.github/actions/setup-toolchain` turns a name into packages and make arguments, so the two jobs cannot disagree about what `gcc-11` means. Adding a compiler is one entry in each list.

Dependencies come from that action: `build-essential`, `flex`, `bison`, `bc`, `libssl-dev`, `libelf-dev`, `libxxhash-dev`. The last is easy to miss — without it objtool still builds, and then every test bails with "objtool was built without klp support".

**Selecting the compiler:** the action emits `CC=gcc-11`, or `LLVM=-18` for clang (the kernel's documented form for a versioned LLVM toolchain, which also points `ld.lld`, `llvm-objcopy` and `llvm-readelf` at the matching version). It is passed **as a make argument, never through the environment**. `CC=gcc-11 make …` does not work: the kernel's Makefile assigns `CC` itself and a makefile assignment beats the environment, so the job silently builds with the runner's default compiler and the matrix tests one toolchain four times over. That happened, and nothing caught it — so each job now asserts the compiler it ended up with, and fails loudly on a mismatch rather than going quietly green.

**Caching:** the kernel build output is cached per entry and commit. A miss only slows `kernel-build`; `objtool-tests` does not use it.

**Failure Handling:**
- `fail-fast: false`, so one toolchain's failure is a result about that toolchain rather than a reason to cancel the others.
- On a test failure the job uploads the per-test working directories (`/tmp/klp-tests.*`: the fixtures, `out.o` and `diff.log` of whichever test failed), the `objtool` binary and the test log, kept for 7 days. That set is what makes a CI-only failure debuggable offline — the fixture objects feed straight back into a local `objtool klp diff`, which is how the IBT failure below was diagnosed.

**Reading the results:** each run prints a preflight banner recording the objtool path, the compiler, the architecture and the `-fcf-protection` setting the fixtures were built with. When a test only fails on one toolchain, that banner is the first place to look.

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

If new patches or config fragments are needed:
1. Add them to `ci/diffs/` or `ci/configs/`.
2. Ensure the workflow references them (e.g., patch paths in step commands).
3. Run `sync.sh` again.
