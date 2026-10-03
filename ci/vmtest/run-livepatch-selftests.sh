#!/bin/bash
# Run the livepatch kselftests inside the vmtest VM and decide whether the run
# passed.  vmtest hands this script's exit status back to the job.
#
# $1 - the kselftest-install output directory
#
# Writes livepatch-selftests.log and dmesg.txt to the current directory, which
# is shared with the runner, for the job to upload when the run fails.
#
# Not every failure makes run_kselftest.sh exit non-zero, so the verdict also
# weighs the KTAP totals and the kernel log:
#
#   - a skip fails the run.  Every skip in this suite is the environment
#     falling short -- a missing config option, a missing KDIR -- and a run
#     where every test skips exits 0, which would leave CI green having tested
#     nothing.  Nothing here is expected to skip; fix the environment.
#   - an xfail fails the run.  No test here expects to fail; xfail is what
#     the runner makes of exit status 2, which is also what bash exits with
#     on a syntax error, so a test script broken outright would pass.
#   - a kernel splat fails the run.  A WARN or a lockdep report leaves the
#     tests running, and they look only at kernel-log lines that mention
#     livepatch or their own modules, so a splat can go right past them.

set -euo pipefail

ksft=$(realpath "$1")
log=$PWD/livepatch-selftests.log
dmesg=$PWD/dmesg.txt

# Seconds a single test may run.  The suite's settings file sets no limit, so
# a hung test would hold the VM until the step timeout killed the job, with no
# record of which test it was.  The slowest test takes under half a minute,
# and with every test hung to the cap the run still ends inside the step's
# timeout.
timeout=120

# functions.sh skips every test unless $KDIR is a directory: it expects a
# build tree to compile the test modules against, and defaults to
# /lib/modules/$(uname -r)/build.  The VM runs on the runner's root filesystem,
# which has no such tree for this kernel, and the modules came prebuilt with
# kselftest-install anyway.  Any directory satisfies the check.
export KDIR=$ksft

# The runner writes each test's own output -- check_result's diff of expected
# against actual kernel log among it -- to /dev/stdout.  The guest's /dev is a
# bare devtmpfs, with /dev/fd from vmtest's init but none of the links udev
# would add, so that output would go to a regular file nobody reads.
[ -e /dev/stdin ] || ln -s /proc/self/fd/0 /dev/stdin
[ -e /dev/stdout ] || ln -s /proc/self/fd/1 /dev/stdout
[ -e /dev/stderr ] || ln -s /proc/self/fd/2 /dev/stderr

fail() {
	echo "::error::livepatch selftests: $*"
	failed=1
}
failed=0

status=0
"$ksft/run_kselftest.sh" -c livepatch -o "$timeout" 2>&1 | tee "$log" || status=$?

dmesg > "$dmesg"

[ "$status" = 0 ] || fail "run_kselftest.sh exited with $status"

# "# Totals: pass:8 fail:0 xfail:0 xpass:0 skip:0 error:0"
totals=$(grep '^# Totals: ' "$log" | tail -n 1 || true)
if [ -z "$totals" ]; then
	fail "no KTAP totals in the output; the runner did not finish"
else
	count() {
		local n=${totals##* "$1":}
		echo "${n%% *}"
	}
	pass=$(count pass)
	[ "$pass" -gt 0 ] || fail "no test passed"
	for k in fail xfail xpass error skip; do
		n=$(count "$k")
		[ "$n" = 0 ] || fail "$n test(s) reported $k"
	done
	# Name them: the counts alone send everyone digging through the log.
	grep -E '^not ok |^ok .* # (SKIP|XFAIL)' "$log" | sed 's/^/::error::/' || true
fi

# The signatures BPF CI fails a run on (kernel-patches/vmtest SPLAT_DENYLIST).
# The leading group eats the timestamp, so the patterns match the start of the
# message.  WARNING: covers WARN(), and with it lockdep and list corruption;
# BUG: covers sleeping in atomic context, and KASAN were it enabled.  The
# kernel only reports what its config detects: see ci/configs/livepatch.config.
# An oops panics the VM (oops=panic), which fails the job on its own.
splats=$(grep -E \
	-e '^(\[[^]]*\] *)*(BUG|WARNING|UBSAN|Oops)[: ]' \
	-e '^(\[[^]]*\] *)*kernel BUG at' \
	-e '^(\[[^]]*\] *)*watchdog: .*(soft lockup|hard LOCKUP)' \
	-e '^(\[[^]]*\] *)*(rcu: )?INFO: (task .* blocked for more than|[_a-z]+ (self-)?detected stall)' \
	"$dmesg" || [ $? = 1 ])
if [ -n "$splats" ]; then
	fail "kernel splat: ${splats%%$'\n'*}"
	echo "--- kernel log around the splat ---"
	grep -n -C 30 -F -f <(printf '%s\n' "$splats") "$dmesg" || true
fi

[ "$failed" = 0 ] && echo "livepatch selftests: $totals"
exit "$failed"
