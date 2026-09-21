# CI Files for klp-built Kernel

This repository holds GitHub Actions CI configuration for the `linux/` kernel repository at `Linux-Live-Patching-CI/linux.git`.

## Layout

- **`.github/workflows/`** — GitHub Actions workflow definitions (`.yml` files). These define what tests run on each push/PR.
- **`ci/diffs/`** — Kernel patches to be applied before building (if any). The sync script copies these into `linux/` as well.
- **`ci/configs/`** — Kernel configuration fragments for CI builds (if any).
- **`ci/scripts/`** — Helper scripts invoked by workflows (if any).
- **`sync.sh`** — The synchronization script (see below).

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

**Matrix:** Builds and tests with both `gcc` and `clang`.

**What it does:**
1. Installs build dependencies: `build-essential`, `flex`, `bison`, `bc`, `libssl-dev`, `libelf-dev`, `clang`, `llvm`.
2. Builds the kernel with a `defconfig` (into a separate `build-$TOOLCHAIN/` directory to enable caching).
3. Runs `make -C tools/objtool tests` to exercise objtool's live-patch validation logic.

**Caching:** Kernel build output is cached per toolchain/commit to speed up re-runs and handle GitHub's free-runner resource constraints.

## Maintenance

When adding new CI jobs or modifying workflows:
1. Edit the `.github/workflows/*.yml` files here in `ci_files`.
2. Run `sync.sh` to apply changes to `linux/`.
3. Verify the workflow runs correctly on `Linux-Live-Patching-CI/linux.git`.

If new patches or config fragments are needed:
1. Add them to `ci/diffs/` or `ci/configs/`.
2. Ensure the workflow references them (e.g., patch paths in step commands).
3. Run `sync.sh` again.
