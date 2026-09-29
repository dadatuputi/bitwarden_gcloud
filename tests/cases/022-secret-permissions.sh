# The deployment directory holds .env, the vault database and its signing key.
# On the data disk nothing above it is private: the home directory that used to
# shield it is no longer on the path. The operator makes it private once,
# following utilities/README-cos-updates.md, and the stack refuses to start
# until that is done. The check runs here as the cloud-config installs it,
# against a scratch directory, and the documented commands run as written.
. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
PM="$WORK/perm-mnt"
PD="$PM/bitwarden_gcloud"
pcc=$(emit_cloud_config bwgc-data "$PM" 06:00)

# The script body as it lands on the instance: the content block under its
# write_files entry, without the four spaces of YAML indentation.
printf '%s\n' "$pcc" | awk '
	$0 == "- path: /var/lib/bwgc/check-secrets.sh" { found=1; next }
	found && /^  content: \|$/ { body=1; next }
	body && /^    / { sub(/^    /, ""); print; next }
	body && /^$/ { print; next }
	body { exit }
' > "$WORK/check-secrets.sh"
assert_contains "$(cat "$WORK/check-secrets.sh")" "DIR=$PD" "cloud-config writes check-secrets.sh for the deployment"

# The commands under "Keeping the deployment private", exactly as documented.
awk '
	/^## Keeping the deployment private/ { sec=1; next }
	sec && /^## / { exit }
	sec && /^```sh$/ && !done { code=1; next }
	code && /^```$/ { code=0; done=1; next }
	code { print }
' "$ROOT/utilities/README-cos-updates.md" > "$WORK/perm-doc-fix.sh"
assert_contains "$(cat "$WORK/perm-doc-fix.sh")" "chmod o=" "the docs give the commands that make a deployment private"
apply_doc_fix() { HOME="$PM" sh "$WORK/perm-doc-fix.sh"; }

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
perr=$(sh "$WORK/check-secrets.sh" 2>&1)
assert_status $? 1 "a deployment other users can read is refused"
assert_contains "$perr" "bwgc: other users can enter $PD" "the open directory is named"
assert_contains "$perr" "bwgc: other users can read $PD/.env" "a world-readable .env is named"
# rclone and ddclient write their own files 600; only .env is created by hand.
assert_not_contains "$perr" "rclone.conf" "files other tools write are not checked"
assert_not_contains "$perr" ".env.template" "files without secrets are not checked"
assert_contains "$perr" "Keeping the deployment private" "the refusal points to the documented fix"
assert_status "$(mode_of "$PD/.env")" 644 "the check changes nothing itself"

apply_doc_fix
assert_status "$(mode_of "$PD")" 750 "the documented fix closes the directory to other users"
assert_status "$(mode_of "$PD/.env")" 600 "the documented fix makes .env 600"
assert_status "$(mode_of "$PD/.env.template")" 644 "the documented fix leaves files without secrets alone"
perr=$(sh "$WORK/check-secrets.sh" 2>&1)
assert_status $? 0 "a private deployment starts"
[ -z "$perr" ] && pass "a private deployment starts without a word" \
	|| fail "a private deployment starts without a word" "$perr"

# Stricter than 600 is fine, and so is a group that can reach the directory.
chmod 400 "$PD/.env"
chmod 770 "$PD"
sh "$WORK/check-secrets.sh" 2>/dev/null
assert_status $? 0 "a read-only .env and a group-accessible directory are accepted"

# A .env symlinked elsewhere is judged, and fixed, where it points.
reset_perm_tree
mv "$PD/.env" "$WORK/perm-real-env"
ln -s "$WORK/perm-real-env" "$PD/.env"
chmod 600 "$WORK/perm-real-env"
apply_doc_fix
sh "$WORK/check-secrets.sh" 2>/dev/null
assert_status $? 0 "a symlink to a private .env is accepted"
chmod 644 "$WORK/perm-real-env"
sh "$WORK/check-secrets.sh" 2>/dev/null
assert_status $? 1 "a symlink to a readable .env is refused"
apply_doc_fix
assert_status "$(mode_of "$WORK/perm-real-env")" 600 "the documented fix restricts a symlinked .env at its target"
rm -f "$WORK/perm-real-env"

rm -f "$PD/.env"
sh "$WORK/check-secrets.sh" 2>/dev/null
assert_status $? 0 "a missing .env is left to the stack to report"
rm -rf "$PM"

# Both entry points check before starting anything, and stop if it fails. At
# boot that has to happen before the stack is torn down, or a refusal would
# take a running vault down with it.
pst=$(printf '%s\n' "$pcc" | sed -n '/^- path: \/var\/lib\/bwgc\/start-stack.sh$/,/^- path: /p')
psup=$(printf '%s\n' "$pcc" | sed -n '/^- path: \/var\/lib\/bwgc\/supervise-stack.sh$/,/^- path: /p')
assert_contains "$pst" "check-secrets.sh || exit 1" "the boot start stops when the check fails"
assert_before "$pst" "check-secrets.sh" "compose.sh down" "the boot start checks before tearing anything down"
assert_contains "$psup" "check-secrets.sh || exit 1" "the supervisor stops when the check fails"
assert_before "$psup" "check-secrets.sh" "compose.sh up -d" "the supervisor checks before restarting anything"

# upgrade-cos.sh and migrate-to-data-disk.sh run the same check on the instance
# before they change anything, so a run cannot end with a vault that refuses to
# start.
GCLOUD_LOG="$WORK/perm-calls.log"
BWGC_WAIT_TRIES=1
BWGC_WAIT_SLEEP=0
MOCK_DISK_EXISTS=1
MOCK_OPEN_SECRETS=/mnt/disks/bwgc/bitwarden_gcloud/.env
export GCLOUD_LOG BWGC_WAIT_TRIES BWGC_WAIT_SLEEP MOCK_DISK_EXISTS MOCK_OPEN_SECRETS
: > "$GCLOUD_LOG"
pout=$( cd "$WORK" && "$ROOT/utilities/upgrade-cos.sh" \
	--instance vault --zone us-central1-a --yes 2>&1 )
assert_status $? 1 "upgrade-cos.sh stops when other users can read the deployment"
assert_contains "$pout" "can read /mnt/disks/bwgc/bitwarden_gcloud/.env" "upgrade-cos.sh names what is open"
assert_contains "$pout" "Nothing has been changed." "upgrade-cos.sh says nothing was changed"
assert_contains "$(cat "$GCLOUD_LOG")" "sudo env DIR=/mnt/disks/bwgc/bitwarden_gcloud sh -s" "upgrade-cos.sh checks the deployment on the data disk"
assert_not_contains "$(cat "$GCLOUD_LOG")" "backup.sh" "upgrade-cos.sh stops before the backup"
assert_not_contains "$(cat "$GCLOUD_LOG")" "instances stop" "upgrade-cos.sh stops before touching the instance"

unset MOCK_DISK_EXISTS
MOCK_OPEN_SECRETS=/home/tester/bitwarden_gcloud/.env
: > "$GCLOUD_LOG"
pout=$( cd "$WORK" && "$ROOT/utilities/migrate-to-data-disk.sh" \
	--instance vault --zone us-central1-a --yes 2>&1 )
# The mock cannot carry a migration to the end, so the exit status alone would
# prove nothing here; the refusal itself is what is checked.
assert_contains "$pout" "can read /home/tester/bitwarden_gcloud/.env" "migrate-to-data-disk.sh names what is open"
assert_contains "$pout" "Nothing has been changed." "migrate-to-data-disk.sh says nothing was changed"
assert_contains "$(cat "$GCLOUD_LOG")" "sudo env DIR=/home/tester/bitwarden_gcloud sh -s" "migrate-to-data-disk.sh checks the deployment it is about to copy"
assert_not_contains "$pout" "Step 1/7" "migrate-to-data-disk.sh stops before its first step"
unset MOCK_OPEN_SECRETS
