# Every fault that reached production in these scripts was a quoting or
# expansion error inside a string handed to a remote shell. Local linting does
# not look inside those strings, so the suite runs each script against the mock,
# captures every remote command, and parses each one with a real shell.
REMOTE_CMD_DIR="$WORK/remote-cmds"
export REMOTE_CMD_DIR
rm -rf "$REMOTE_CMD_DIR"; mkdir -p "$REMOTE_CMD_DIR"

GCLOUD_LOG="$WORK/syntax-calls.log"
BWGC_WAIT_TRIES=1
BWGC_WAIT_SLEEP=0
export GCLOUD_LOG BWGC_WAIT_TRIES BWGC_WAIT_SLEEP

( cd "$WORK" && "$ROOT/utilities/upgrade-cos.sh" \
    --instance vault --zone us-central1-a --yes ) >/dev/null 2>&1 || true
( cd "$WORK" && "$ROOT/utilities/migrate-to-data-disk.sh" \
    --instance vault --zone us-central1-a --yes ) >/dev/null 2>&1 || true

count=$(find "$REMOTE_CMD_DIR" -name 'cmd-*.sh' | wc -l | tr -d ' ')
if [ "$count" -gt 0 ]; then
	pass "captured $count remote commands to parse"
else
	fail "captured $count remote commands to parse" "the mock recorded nothing"
fi

bad=0
for f in "$REMOTE_CMD_DIR"/cmd-*.sh; do
	[ -e "$f" ] || continue
	if ! err=$(sh -n "$f" 2>&1); then
		bad=$((bad + 1))
		printf '       %s\n' "$(head -c 90 "$f")"
		printf '         -> %s\n' "$err"
	fi
done
if [ "$bad" -eq 0 ]; then
	pass "every remote command parses as shell"
else
	fail "every remote command parses as shell" "$bad of $count failed to parse"
fi

# A truncated payload -- what a quoting fault produces -- can be empty or
# suspiciously short rather than syntactically invalid.
short=0
for f in "$REMOTE_CMD_DIR"/cmd-*.sh; do
	[ -e "$f" ] || continue
	if [ ! -s "$f" ]; then
		short=$((short + 1))
		printf '       empty payload: %s\n' "$(basename "$f")"
	fi
done
if [ "$short" -eq 0 ]; then
	pass "no remote command is empty"
else
	fail "no remote command is empty" "$short empty payload(s)"
fi

# Local variables must be expanded before the command is sent. A literal
# $MOUNT or $INSTANCE reaching the remote shell means the wrong quoting was
# used, and it expands to nothing there.
leaked=0
for f in "$REMOTE_CMD_DIR"/cmd-*.sh; do
	[ -e "$f" ] || continue
	for v in MOUNT DISK_NAME INSTANCE NEW_INSTANCE ZONE BOOT_SIZE IMAGE_FAMILY COMPOSE_SRC COMPOSE_HELPER; do
		if grep -q "\$$v" "$f" 2>/dev/null; then
			leaked=$((leaked + 1))
			printf '       %s reached the remote unexpanded in: %s\n' "\$$v" "$(head -c 60 "$f")"
		fi
	done
done
if [ "$leaked" -eq 0 ]; then
	pass "no local variable reaches the remote shell unexpanded"
else
	fail "no local variable reaches the remote shell unexpanded" "$leaked occurrence(s)"
fi

# The home directory is on the boot disk, which upgrade-cos.sh replaces. Every
# convenience the migration set up there -- the alias, the compose helper, the
# ~/bitwarden_gcloud symlink -- has to be reinstated on the new instance.
up=$(cat "$ROOT/utilities/upgrade-cos.sh")
assert_contains "$up" "install-alias.sh"          "reinstalls the compose alias on the new instance"
assert_contains "$up" 'install_compose_helper "$NEW_INSTANCE"' "reinstalls the compose helper"
assert_contains "$up" 'ln -sfn $MOUNT/bitwarden_gcloud ~/bitwarden_gcloud' "recreates the ~/bitwarden_gcloud symlink"

# install-alias.sh failing silently would leave the operator without the command
# every other page tells them to run.
if printf '%s' "$up" | grep -q 'install-alias.sh >/dev/null 2>&1 || true'; then
	fail "alias installation failures are visible" "still suppressed with || true"
else
	pass "alias installation failures are visible"
fi

# A shell cannot unmount the filesystem it is standing in. The unmount command
# ran "cd $MOUNT/bitwarden_gcloud && ... && umount $MOUNT", which always fails
# with "target is busy" -- and it fails after the stack is already stopped.
umount_cmd=$(printf '%s' "$up" | grep -B6 -A8 'sudo umount' | head -18)
if printf '%s' "$umount_cmd" | grep -q 'cd /;'; then
	pass "leaves the mount before unmounting it"
else
	fail "leaves the mount before unmounting it" "no 'cd /' before umount"
fi
assert_contains "$up" "for i in 1 2 3 4 5 6" "retries the unmount rather than failing on the first attempt"
assert_contains "$up" "could not unmount"    "reports what is holding the mount when it never releases"

# Any command that unmounts must not have the mount as its working directory.
bad_umount=$(printf '%s' "$up" | grep -n 'cd \$MOUNT.*umount \$MOUNT' || true)
if [ -z "$bad_umount" ]; then
	pass "no command unmounts the directory it cd'd into"
else
	fail "no command unmounts the directory it cd'd into" "$bad_umount"
fi

# Tags and scopes are properties of the instance, not the image or the disks.
# Without the tags, firewall rules that target them do not apply and the
# replacement is unreachable from the internet. Without compute.readonly the
# instance cannot check whether its own milestone is still supported.
W2="$WORK/carry"; rm -rf "$W2"; mkdir -p "$W2"
GCLOUD_LOG="$W2/calls.log"; export GCLOUD_LOG
( cd "$W2" && "$ROOT/utilities/upgrade-cos.sh" --instance vault --zone us-central1-a --yes ) >/dev/null 2>&1 || true
create=$(grep 'instances create' "$W2/calls.log" | head -1)
assert_contains "$create" "--tags"            "carries network tags to the replacement"
assert_contains "$create" "http-server,https-server" "tags are comma-separated, as --tags requires"
assert_contains "$create" "--scopes"          "carries service account scopes"
assert_contains "$create" "compute.readonly"  "keeps the scope the milestone check needs"
assert_contains "$create" "--service-account" "carries the service account"
assert_not_contains "$create" "http-server;"  "no semicolon separator reaches gcloud"
assert_contains "$create" "--labels"          "carries labels"
assert_contains "$create" "--network"         "carries the network"
assert_contains "$create" "--subnet"          "carries the subnet"

# A resized instance must not be silently put back to e2-micro.
assert_contains "$create" "e2-small"          "keeps the machine type rather than hardcoding e2-micro"
assert_not_contains "$create" "e2-micro"      "does not force e2-micro over the existing type"

# A reserved address survives deletion and should be reattached; an ephemeral
# one cannot be, and the operator is told.
assert_contains "$create" "--address"         "reattaches a reserved external address"
upg=$(cat "$ROOT/utilities/upgrade-cos.sh")
assert_contains "$upg" "gcloud compute addresses create" \
  "reserves an ephemeral address so it survives the delete"
assert_contains "$upg" '--addresses "$OLD_NATIP"' \
  "promotes the address the instance already has"
assert_contains "$upg" "Continue and let the external IP change?" \
  "asks before proceeding when the address cannot be reserved"
assert_contains "$upg" "--no-reserve-ip" \
  "reserving can be declined"

# Deleting the instance destroys everything not captured first.
assert_contains "$(cat "$ROOT/utilities/upgrade-cos.sh")" "instance-\$INSTANCE.json" \
  "saves the full instance configuration before deleting it"
snap=$(grep -n 'instances describe .* --format=json' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
del=$(grep -n 'instances delete' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
if [ -n "$snap" ] && [ -n "$del" ] && [ "$snap" -lt "$del" ]; then
	pass "the configuration snapshot precedes the deletion"
else
	fail "the configuration snapshot precedes the deletion" "snapshot=$snap delete=$del"
fi

# SSH answers before cloud-init finishes. The data disk is mounted by a bootcmd,
# so a reachable instance is not a ready one: checking too early reports the
# mount missing for a disk that appears seconds later.
assert_contains "$up" "waiting for cloud-init to mount" "waits for the mount, not just for ssh"
assert_contains "$up" "never mounted on"                "reports a mount that never appears"
assert_contains "$up" "cloud-init status --long"        "points at cloud-init when the mount fails"

# The wait must come before anything that uses the mount.
wait_line=$(grep -n 'waiting for cloud-init to mount' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
use_line=$(grep -n 'waiting for bwgc.service' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
if [ -n "$wait_line" ] && [ -n "$use_line" ] && [ "$wait_line" -lt "$use_line" ]; then
	pass "the mount wait precedes waiting for the stack"
else
	fail "the mount wait precedes waiting for the stack" "wait=$wait_line use=$use_line"
fi

# And it must actually poll rather than pass on the first look.
rm -f /tmp/bwgc-mountpolls
W3="$WORK/mountwait"; rm -rf "$W3"; mkdir -p "$W3"
out=$( cd "$W3" && GCLOUD_LOG="$W3/calls.log" MOCK_MOUNT_DELAY=3 \
  "$ROOT/utilities/upgrade-cos.sh" --instance vault --zone us-central1-a --yes 2>&1 || true )
rm -f /tmp/bwgc-mountpolls
assert_contains "$out" "waiting for cloud-init to mount" "polls when the mount is not yet present"
assert_contains "$out" "mounted"                         "proceeds once the mount appears"
