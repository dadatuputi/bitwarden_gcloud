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
bad_umount=$(printf '%s' "$up" | grep -n "cd $MOUNT.*umount $MOUNT" || true)
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
