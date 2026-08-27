# The order of operations in upgrade-cos.sh is the safety property. These run
# the real script against the gcloud mock and assert on the recorded call order.

run_upgrade() {
	GCLOUD_LOG="$WORK/calls.log"
	BWGC_WAIT_TRIES=2
	BWGC_WAIT_SLEEP=0
	BWGC_STACK_TRIES=2
	# The upgrade's whole premise is that the data disk already exists.
	MOCK_DISK_EXISTS=1
	export GCLOUD_LOG BWGC_WAIT_TRIES BWGC_WAIT_SLEEP BWGC_STACK_TRIES MOCK_DISK_EXISTS
	: > "$GCLOUD_LOG"
	( cd "$WORK" && "$ROOT/utilities/upgrade-cos.sh" \
		--instance vault-old --zone us-central1-a --yes "$@" ) >"$WORK/out" 2>&1
	UPGRADE_STATUS=$?
	CALLS=$(cat "$GCLOUD_LOG")
	OUTPUT=$(cat "$WORK/out")
}

# --- default: delete first -------------------------------------------------
run_upgrade
assert_status "$UPGRADE_STATUS" 0 "default run succeeds"
assert_contains "$CALLS" "images describe-from-family cos-129-lts" "resolves the newest live LTS family"
assert_not_contains "$CALLS" "describe-from-family cos-109-lts"    "does not consider the dead 109 family"

# The whole point of delete-first.
assert_before "$CALLS" "instances delete vault-old" "instances create vault-old-129" \
	"old instance is deleted BEFORE the replacement is created"

# ...but never before the vault is safe.
assert_before "$CALLS" "backup.sh local" "instances delete vault-old" \
	"backup is taken before anything is destroyed"
assert_before "$CALLS" "compute scp" "instances delete vault-old" \
	"backup is pulled locally before anything is destroyed"
assert_before "$CALLS" "detach-disk" "instances delete vault-old" \
	"data disk is detached before the instance is deleted"

# The data disk must be present at first boot or cloud-init cannot mount it.
assert_contains "$CALLS" "name=bwgc-data,device-name=bwgc-data" \
	"replacement is created with the data disk already attached"

# --- --overlap: the reverse order -----------------------------------------
run_upgrade --overlap
assert_status "$UPGRADE_STATUS" 0 "--overlap run succeeds"
assert_before "$CALLS" "instances create vault-old-129" "instances delete vault-old" \
	"--overlap creates the replacement before deleting the old instance"

# --- --keep-old: no deletion at all ---------------------------------------
run_upgrade --keep-old
assert_not_contains "$CALLS" "instances delete vault-old" "--keep-old never deletes the old instance"

# --- failure is loud, and does not suggest going backwards ----------------
MOCK_UNREACHABLE_HOST=vault-old-129
export MOCK_UNREACHABLE_HOST
run_upgrade --overlap
unset MOCK_UNREACHABLE_HOST
assert_status "$UPGRADE_STATUS" 1 "unreachable replacement exits non-zero"
assert_contains "$OUTPUT" "never became reachable"  "says plainly what failed"
assert_contains "$OUTPUT" "regression, not a recovery" \
	"refuses to present the old milestone as a fix"
