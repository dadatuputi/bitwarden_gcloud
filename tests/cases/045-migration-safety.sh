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
# Stopping an instance releases its ephemeral external address, so the vault
# would come back on a different IP with DNS still pointing at the old one. An
# in-guest reboot is graceful and leaves the instance running.
assert_not_contains "$mig_code" "instances stop"  "does not stop the instance to reboot it"
assert_not_contains "$mig_code" "instances start" "does not start it again, having not stopped it"
assert_contains "$mig" "sudo systemctl reboot"    "reboots from inside the guest"
assert_contains "$mig" "sync; sudo systemctl reboot" "flushes in the same command that reboots"
# ssh answers again before the old boot has finished going down, so a changed
# boot id is what proves the reboot happened.
assert_contains "$mig" "boot_id"                  "verifies the reboot by boot id"

# The timers and the stack are brought up in cloud-init runcmd, after the mount.
assert_contains "$mig" "cloud-init status --wait" "waits for cloud-init before checking its work"
assert_contains "$upg" "cloud-init status --wait" "the upgrade waits too"

# A run that copied the data but never wrote the metadata is not a finished
# migration: nothing remounts the disk on the next boot.
assert_contains "$mig" "Finish the interrupted migration?" "offers to finish an interrupted run"
assert_contains "$mig" 'RESUME=0'                 "a normal run does not take the resume path"
assert_contains "$mig" 'if [ "$RESUME" -eq 0 ]; then' "the copy steps are skipped when resuming"

# The old instructions built a 30 GB boot disk, so the free-tier arithmetic has
# to use the disk the instance actually has.
assert_contains "$mig" "disks describe" "reads the real boot disk size"
assert_not_contains "$mig" "BOOT_MIN"   "does not treat the image minimum as the boot size"
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

# Iteration 3: both scripts started the stack themselves as a fallback when
# bwgc.service "was not active yet". That check is a point-in-time sample, and
# on a real run both sides created a network named bitwarden_gcloud_default one
# millisecond apart. Every container start then failed with "network ... is
# ambiguous (2 matches found on name)", and the supervise timer failed the same
# way every five minutes indefinitely.
for f in migrate-to-data-disk.sh upgrade-cos.sh; do
	body=$(grep -vE '^[[:space:]]*#' "$ROOT/utilities/$f")
	if printf '%s' "$body" | grep -q 'is-active bwgc.service.*compose up'; then
		fail "$f: does not start the stack alongside bwgc.service"
	else
		pass "$f: does not start the stack alongside bwgc.service"
	fi
	assert_contains "$(cat "$ROOT/utilities/$f")" "waiting for bwgc.service to start the stack" \
		"$f: waits for bwgc.service instead"
	assert_contains "$(cat "$ROOT/utilities/$f")" 'STACK_STATE" != active' \
		"$f: fails loudly when the stack never comes up"
done

# upgrade-cos.sh defaulted the data disk to bwgc-data and aborted after stopping
# the stack and the instance. In a project holding a bwgc-data disk in the same
# zone it would have carried over the wrong disk without asking.
# DISK_NAME must start empty, or the derivation never runs and the default is
# used blindly again.
if grep -qE '^DISK_NAME=$' "$ROOT/utilities/upgrade-cos.sh"; then
	pass "the disk name starts unset so it can be derived"
else
	fail "the disk name starts unset so it can be derived" "$(grep -n '^DISK_NAME=' "$ROOT/utilities/upgrade-cos.sh" | head -1)"
fi
assert_contains "$upg" 'DISK_NAME_DEFAULT'          "keeps the fallback separate from what was asked for"
assert_contains "$upg" 'data disk read from'        "reads the data disk off the instance"
assert_contains "$upg" 'No disk named $DISK_NAME'   "checks the disk exists"
first_disk_check=$(printf '%s' "$upg" | grep -n 'No disk named' | head -1 | cut -d: -f1)
stop_stack=$(printf '%s' "$upg" | grep -n 'stop the stack and release the data disk' | head -1 | cut -d: -f1)
if [ -n "$first_disk_check" ] && [ -n "$stop_stack" ] && [ "$first_disk_check" -lt "$stop_stack" ]; then
	pass "the disk check runs before the stack is stopped"
else
	fail "the disk check runs before the stack is stopped" "check at $first_disk_check, stop at $stop_stack"
fi

# rclone is optional, and the ERROR landed in the step described as "back up and
# verify before touching anything", immediately before the instance is deleted.
assert_not_contains "$upg" "backup.sh local,rclone" "the upgrade does not demand an rclone backup"

# DNS may not point at the instance yet. That must not become the exit status of
# an upgrade that otherwise worked.
assert_contains "$upg" "external check above is informational" "the external check cannot fail the run"

# A reader who presses Enter should get the cautious answer at every prompt. The
# prompt guarding "sudo rm -rf ~/bitwarden_gcloud" defaulted to yes.
for f in migrate-to-data-disk.sh upgrade-cos.sh; do
	if grep -q '\[Y/n\]' "$ROOT/utilities/$f"; then
		fail "$f: every prompt defaults to no" "$(grep -n '\[Y/n\]' "$ROOT/utilities/$f" | head -1)"
	else
		pass "$f: every prompt defaults to no"
	fi
done
# A step called "verify" that prints a bare header gives no signal either way.
assert_contains "$upg" "no DOMAIN in .env, skipped" "the vault check reports when it is skipped"
assert_contains "$upg" "no answer yet" "the vault check reports when it gets nothing"
# The step numbering announced 6/6 and then 7/7.
if printf '%s' "$upg" | grep -q 'Step [0-9]/6:'; then
	fail "the upgrade uses one step denominator" "$(printf '%s' "$upg" | grep -o 'Step [0-9]/6:' | head -1)"
else
	pass "the upgrade uses one step denominator"
fi

# Iteration 5: the plan printed before the prerequisite checks, so it could
# advertise creating a disk on a host that already had one, and a reader could
# not see that anything had been verified before being asked to approve.
plan_line=$(printf '%s' "$mig" | grep -n 'say "Plan"' | head -1 | cut -d: -f1)
guard_line=$(printf '%s' "$mig" | grep -n 'already mounted, holds a deployment' | head -1 | cut -d: -f1)
pre_line=$(printf '%s' "$mig" | grep -n 'backup container is not running' | head -1 | cut -d: -f1)
if [ -n "$plan_line" ] && [ -n "$guard_line" ] && [ "$guard_line" -lt "$plan_line" ]; then
	pass "the re-entry guard runs before the plan is printed"
else
	fail "the re-entry guard runs before the plan is printed" "guard=$guard_line plan=$plan_line"
fi
if [ -n "$plan_line" ] && [ -n "$pre_line" ] && [ "$pre_line" -lt "$plan_line" ]; then
	pass "the backup preflight runs before the plan is printed"
else
	fail "the backup preflight runs before the plan is printed" "preflight=$pre_line plan=$plan_line"
fi

# A space between the command substitution and the path made curl treat
# /api/version as a second URL, in a command printed for the user to paste.
if printf '%s' "$mig" | grep -q ') /api/version'; then
	fail "the printed curl has no stray space before the path"
else
	pass "the printed curl has no stray space before the path"
fi
