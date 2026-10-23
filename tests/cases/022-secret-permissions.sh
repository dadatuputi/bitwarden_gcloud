# The deployment directory holds .env, the vault database and its signing key.
# On the data disk nothing above it is private: the home directory that used to
# shield it is no longer on the path. The stack makes it private before every
# start, and never stays down over it. make-private.sh runs here as the
# cloud-config installs it, against a scratch directory.
. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
PM="$WORK/perm-mnt"
PD="$PM/bitwarden_gcloud"
pcc=$(emit_cloud_config bwgc-data "$PM" 06:00)

# The script body as it lands on the instance: the content block under its
# write_files entry, without the four spaces of YAML indentation.
printf '%s\n' "$pcc" | awk '
	$0 == "- path: /var/lib/bwgc/make-private.sh" { found=1; next }
	found && /^  content: \|$/ { body=1; next }
	body && /^    / { sub(/^    /, ""); print; next }
	body && /^$/ { print; next }
	body { exit }
' > "$WORK/make-private.sh"
assert_contains "$(cat "$WORK/make-private.sh")" "DIR=$PD" "cloud-config writes make-private.sh for the deployment"

mode_of() { stat -L -c %a "$1"; }
reset_perm_tree() {
	rm -rf "$PM"
	mkdir -p "$PD/bitwarden/rclone" "$PD/ddns"
	chmod 755 "$PD"
	: > "$PD/.env";                          chmod 644 "$PD/.env"
	: > "$PD/bitwarden/rclone/rclone.conf";  chmod 640 "$PD/bitwarden/rclone/rclone.conf"
	: > "$PD/ddns/ddclient.conf";            chmod 600 "$PD/ddns/ddclient.conf"
	: > "$PD/.env.template";                 chmod 644 "$PD/.env.template"
}

# A fresh clone, as git and a copied template leave it under umask 022.
reset_perm_tree
perr=$(sh "$WORK/make-private.sh" 2>&1)
assert_status $? 0 "an open deployment is made private"
assert_eq "$(mode_of "$PD")" 750 "the directory is closed to other users"
assert_eq "$(mode_of "$PD/.env")" 600 "the .env is made readable by its owner only"
assert_contains "$perr" "bwgc: other users could enter $PD" "closing the directory is logged"
assert_contains "$perr" "bwgc: other users could read $PD/.env" "restricting .env is logged"
# The boot's journal is checked for refusals by tests/e2e/gce-smoke.sh.
assert_not_contains "$perr" "refusing" "nothing reads as a refusal in the journal"
# rclone and ddclient write their own files 600; only .env is created by hand.
assert_eq "$(mode_of "$PD/bitwarden/rclone/rclone.conf")" 640 "files other tools write are left alone"
assert_eq "$(mode_of "$PD/.env.template")" 644 "files without secrets are left alone"

perr=$(sh "$WORK/make-private.sh" 2>&1)
assert_status $? 0 "a private deployment is accepted"
[ -z "$perr" ] && pass "a private deployment is left alone without a word" \
	|| fail "a private deployment is left alone without a word" "$perr"

# Stricter than 600 stays as it is, and so does a group that can reach the
# directory: COS gives every login a group of its own.
chmod 400 "$PD/.env"
chmod 770 "$PD"
perr=$(sh "$WORK/make-private.sh" 2>&1)
assert_eq "$(mode_of "$PD/.env")" 400 "a read-only .env stays read-only"
assert_eq "$(mode_of "$PD")" 770 "a group-accessible directory keeps its group"
[ -z "$perr" ] && pass "neither is reported" || fail "neither is reported" "$perr"

# A .env symlinked elsewhere is judged, and fixed, where it points.
reset_perm_tree
mv "$PD/.env" "$WORK/perm-real-env"
ln -s "$WORK/perm-real-env" "$PD/.env"
sh "$WORK/make-private.sh" 2>/dev/null
assert_eq "$(mode_of "$WORK/perm-real-env")" 600 "a symlinked .env is made private at its target"
rm -f "$WORK/perm-real-env"

# Nothing to restrict is not a failure: a missing .env is the stack's to report.
reset_perm_tree
rm -f "$PD/.env"
sh "$WORK/make-private.sh" 2>/dev/null
assert_status $? 0 "a missing .env is left to the stack to report"
assert_eq "$(mode_of "$PD")" 750 "the directory is closed even without a .env"
rm -rf "$PM"

# Both entry points make the deployment private before starting anything, and
# start the stack whatever it returns: a vault left down at the weekly reboot
# costs more than modes fixed at the next run.
pst=$(printf '%s\n' "$pcc" | sed -n '/^- path: \/var\/lib\/bwgc\/start-stack.sh$/,/^- path: /p')
psup=$(printf '%s\n' "$pcc" | sed -n '/^- path: \/var\/lib\/bwgc\/supervise-stack.sh$/,/^- path: /p')
assert_contains "$pst" "make-private.sh || true" "the boot start goes on when make-private.sh fails"
assert_before "$pst" "make-private.sh" "compose.sh up -d" "the boot start makes the deployment private before starting it"
assert_contains "$psup" "make-private.sh || true" "the supervisor goes on when make-private.sh fails"
assert_before "$psup" "make-private.sh" "compose.sh up -d" "the supervisor makes the deployment private before restarting anything"

# upgrade-cos.sh makes the deployment private on the old instance once the run
# is approved, before anything is backed up or stopped.
GCLOUD_LOG="$WORK/perm-calls.log"
MOCK_STDIN_LOG="$WORK/perm-stdin.log"
BWGC_WAIT_TRIES=2
BWGC_WAIT_SLEEP=0
BWGC_STACK_TRIES=2
MOCK_DISK_EXISTS=1
export GCLOUD_LOG MOCK_STDIN_LOG BWGC_WAIT_TRIES BWGC_WAIT_SLEEP BWGC_STACK_TRIES MOCK_DISK_EXISTS
: > "$GCLOUD_LOG"
: > "$MOCK_STDIN_LOG"
( cd "$WORK" && "$ROOT/utilities/upgrade-cos.sh" \
	--instance vault --zone us-central1-a --yes ) >/dev/null 2>&1
assert_status $? 0 "upgrade-cos.sh runs to the end"
pcalls=$(cat "$GCLOUD_LOG")
assert_contains "$pcalls" "compute ssh vault --zone us-central1-a --command sudo env DIR=/mnt/disks/bwgc/bitwarden_gcloud sh -s" \
	"upgrade-cos.sh makes the deployment private on the old instance"
assert_contains "$(cat "$MOCK_STDIN_LOG")" 'chmod go= "$DIR/.env"' "upgrade-cos.sh pipes make_private_body"
assert_before "$pcalls" "sh -s" "backup.sh" "upgrade-cos.sh makes it private before the backup"
assert_before "$pcalls" "sh -s" "instances delete vault" "upgrade-cos.sh makes it private before touching the instance"
unset MOCK_STDIN_LOG MOCK_DISK_EXISTS

# migrate-to-data-disk.sh does it once the copy is on the data disk. The mock
# cannot carry a migration that far, so the order is read from the script.
pmig=$(grep -vE '^[[:space:]]*#' "$ROOT/utilities/migrate-to-data-disk.sh")
assert_contains "$pmig" 'make_private_body | on_vm "sudo env DIR=$MOUNT/bitwarden_gcloud sh -s"' \
	"migrate-to-data-disk.sh makes the copy on the data disk private"
assert_before "$pmig" "sudo rsync -a" "make_private_body" "migrate-to-data-disk.sh makes it private after the copy"
assert_before "$pmig" "make_private_body" "systemctl reboot" "migrate-to-data-disk.sh makes it private before the reboot"
