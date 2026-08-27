# Findings from an end-to-end run of the published documentation. Each assertion
# here corresponds to a defect that reached a real instance.
mig=$(cat "$ROOT/utilities/migrate-to-data-disk.sh")
upg=$(cat "$ROOT/utilities/upgrade-cos.sh")

# A power cycle neither flushes page cache nor unmounts, so a file written
# seconds earlier reaches the disk short and the fsck in bootcmd zero-fills the
# tail. That corrupted .env on the data disk and left the vault dead.
# Matched against code only: a comment explains why reset is not used.
mig_code=$(grep -vE '^[[:space:]]*#' "$ROOT/utilities/migrate-to-data-disk.sh")
assert_not_contains "$mig_code" "instances reset" "never hard-resets the instance"
assert_contains "$mig" "instances stop"       "shuts down before the power cycle"
assert_contains "$mig" "instances start"      "starts it again afterwards"
assert_contains "$mig" "on_vm 'sync'"         "flushes before shutting down"
if printf '%s' "$mig" | grep -q 'sync"$'; then
	pass "flushes again after writing to the data disk"
else
	fail "flushes again after writing to the data disk"
fi

# vaultwarden runs as root unless PUID/PGID are set, so its log is root-owned on
# a stock install and ": >" cannot truncate it.
assert_contains "$mig" "sudo truncate -s 0 bitwarden/bitwarden.log" \
	"truncates the root-owned vault log with sudo"
assert_not_contains "$mig" ": > bitwarden/bitwarden.log" \
	"does not truncate the log as the login user"
# The vault is stopped either side of that truncate.
if printf '%s' "$mig" | grep -q 'compose start bitwarden >/dev/null; \\'; then
	pass "restarts the vault if clearing the log fails"
else
	fail "restarts the vault if clearing the log fails" "no restart on the failure path"
fi

# Step 2 backs up through the backup container, and BACKUP ships commented out.
# The check has to happen before Step 1, which stops the vault and prunes images.
assert_contains "$mig" "The backup container is not running" \
	"explains an unconfigured backup rather than failing on docker exec"
assert_contains "$mig" "BACKUP_ENCRYPTION_KEY is not set" \
	"checks the key the verify and the downloaded copy both need"
first_check=$(printf '%s' "$mig" | grep -n "backup container is not running" | head -1 | cut -d: -f1)
step_one=$(printf '%s' "$mig" | grep -n "Step 1/7" | head -1 | cut -d: -f1)
if [ -n "$first_check" ] && [ -n "$step_one" ] && [ "$first_check" -lt "$step_one" ]; then
	pass "the preflight runs before anything is changed"
else
	fail "the preflight runs before anything is changed" "check at $first_check, Step 1 at $step_one"
fi

# ssh answers before cloud-init mounts the disk, so waiting on ssh and then
# running df reports a failure that is really a race.
assert_contains "$mig" "waiting for cloud-init to mount" "waits for the mount, not just for ssh"
assert_contains "$mig" "never mounted after the reboot"  "reports a mount that never appears"

# cloud-init starts the stack as soon as the disk mounts, so an unconditional
# compose up loses a race with it on the container names.
assert_contains "$mig" "systemctl is-active bwgc.service" "migration defers to bwgc.service"
assert_contains "$upg" "systemctl is-active bwgc.service" "upgrade defers to bwgc.service"

# rclone is optional; asking for it unconditionally prints an ERROR at exactly
# the moment a user is watching for a backup failure.
assert_not_contains "$mig" "backup.sh local,rclone" "does not demand an rclone backup"

# The plan block described --overlap regardless of the mode actually chosen,
# and delete-first is the default.
assert_contains "$upg" "and its boot disk are DELETED" "the plan says when the old instance is deleted"
assert_not_contains "$upg" "The old instance is stopped, not deleted. Rollback" \
	"the plan does not promise a rollback that delete-first removes"

# Container-written files are root-owned, so a bare rm -rf leaves a partial tree.
if printf '%s' "$mig" | grep -q "[^o] rm -rf ~/bitwarden_gcloud"; then
	fail "every documented rm -rf uses sudo"
else
	pass "every documented rm -rf uses sudo"
fi
