# docker-compose on these instances is a shell alias in ~/.bash_alias, which a
# non-interactive "gcloud compute ssh --command" never sources. A remote command
# relying on it fails with "command not found" partway through a migration.
for script in "$ROOT/utilities/migrate-to-data-disk.sh" "$ROOT/utilities/upgrade-cos.sh"; do
	rel=${script#"$ROOT"/}
	src=$(cat "$script")

	assert_contains "$src" "COMPOSE_HELPER=" "$rel installs a compose helper on the instance"
	assert_contains "$src" "docker compose version >/dev/null" "$rel probes for the compose plugin"
	assert_contains "$src" "docker:cli compose" "$rel falls back to the containerised compose"

	# No remote command may invoke the aliased name. Mentions in prose telling a
	# human what to type are fine, so only executable positions count.
	aliased=$(printf '%s' "$src" | grep -nE '^[[:space:]]*(on_vm |if ! on_vm ).*docker-compose ' || true)
	if [ -z "$aliased" ]; then
		pass "$rel: no remote command calls the aliased docker-compose"
	else
		fail "$rel: no remote command calls the aliased docker-compose" "$aliased"
	fi

	# Every on_vm block using compose must source the helper.
	missing=$(awk '
		/^on_vm |^if ! on_vm / { blk=$0; inblk=1; if ($0 !~ /\\$/) { check(); inblk=0 } ; next }
		inblk { blk=blk "\n" $0; if ($0 !~ /\\$/) { check(); inblk=0 } }
		function check() {
			if (blk ~ /[^-]compose / && blk !~ /COMPOSE_SRC/) { print substr(blk,1,60) }
		}
	' "$script")
	if [ -z "$missing" ]; then
		pass "$rel: every remote compose call sources the helper"
	else
		fail "$rel: every remote compose call sources the helper" "$missing"
	fi
done

# Reclaiming space before the copy must cover the build cache as well as images.
mig=$(cat "$ROOT/utilities/migrate-to-data-disk.sh")
assert_contains "$mig" "docker image prune -af"   "prunes unused images"
assert_contains "$mig" "docker builder prune -af" "prunes the build cache"
assert_contains "$mig" "bitwarden.log"            "clears the unrotated vault log"

# Containers write attachments, RSA keys and Caddy's certificate store as root,
# so the copy has to be privileged. And it runs with the vault stopped, so a
# failure there must not leave it offline.
assert_contains "$mig" "sudo rsync -a --delete" "copies as root"
assert_contains "$mig" "compose up -d\" ||"     "restarts the vault if the copy fails"
assert_contains "$mig" "Nothing on the data disk is trusted after a partial copy" \
  "says a partial copy is not usable"

if printf '%s' "$mig" | grep -qE '^[[:space:]]*rsync -a'; then
	fail "no unprivileged rsync of the deployment" "found a bare 'rsync -a'"
else
	pass "no unprivileged rsync of the deployment"
fi

# The helper has to exist before it is sourced, and survive the reboot the
# migration performs. /tmp is tmpfs on COS.
for script in "$ROOT/utilities/migrate-to-data-disk.sh" "$ROOT/utilities/upgrade-cos.sh"; do
	rel=${script#"$ROOT"/}
	src=$(cat "$script")
	assert_not_contains "$src" "COMPOSE_HELPER=/tmp/" "$rel does not keep the helper on tmpfs"
	first_use=$(grep -n 'COMPOSE_SRC ' "$script" | head -1 | cut -d: -f1)
	first_install=$(grep -n '^install_compose_helper' "$script" | head -1 | cut -d: -f1)
	if [ -n "$first_install" ] && [ "$first_install" -lt "$first_use" ]; then
		pass "$rel installs the helper before sourcing it"
	else
		fail "$rel installs the helper before sourcing it" "install=$first_install first use=$first_use"
	fi
done

# A reboot the instance never returns from, and a copy that silently drops
# files, both need to be caught rather than assumed away.
assert_contains "$mig" "did not come back after the reboot" "reports an instance that never returns"
assert_contains "$mig" "get-serial-port-output"             "points at the serial console"
assert_contains "$mig" "database size differs"              "compares the database size"
assert_contains "$mig" "fewer files on the data disk"       "compares the file count"
assert_contains "$mig" "MISSING:"                           "checks key files are present"

# Running compose through the ~/bitwarden_gcloud symlink must resolve to the
# same paths the containers were created with, or every switch between the
# symlink and the real path recreates the stack.
for script in "$ROOT/utilities/migrate-to-data-disk.sh" "$ROOT/utilities/upgrade-cos.sh" "$ROOT/utilities/install-alias.sh"; do
	rel=${script#"$ROOT"/}
	assert_contains "$(cat "$script")" 'pwd -P' "$rel resolves symlinks before invoking compose"
done

# The prune removes docker:cli, which the copy step needs immediately after.
assert_contains "$mig" "docker pull -q docker:cli" "restores the compose image the prune removed"
assert_contains "$mig" "already matches what this script would write" "skips the metadata prompt when nothing changes"
assert_contains "$mig" 'ln -s $MOUNT/bitwarden_gcloud' "symlinks the familiar path to the data disk"
assert_contains "$mig" "gcloud compute scp" "downloads the backup before removing the old copy"

# The backup must reach the operator's machine before anything destructive
# happens. Between the backup and the end of the run the script stops
# containers, formats a disk and reboots the instance.
scp_line=$(grep -n 'gcloud compute scp' "$ROOT/utilities/migrate-to-data-disk.sh" | head -1 | cut -d: -f1)
for danger in 'compose down' 'mkfs.ext4' 'instances reset' 'rm -rf ~/bitwarden_gcloud'; do
	d_line=$(grep -nF "$danger" "$ROOT/utilities/migrate-to-data-disk.sh" | head -1 | cut -d: -f1)
	if [ -n "$d_line" ] && [ "$scp_line" -lt "$d_line" ]; then
		pass "backup is downloaded before: $danger"
	else
		fail "backup is downloaded before: $danger" "scp at $scp_line, $danger at ${d_line:-none}"
	fi
done

# Same property in the upgrade script.
up_scp=$(grep -n 'gcloud compute scp' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
up_del=$(grep -n 'instances delete' "$ROOT/utilities/upgrade-cos.sh" | head -1 | cut -d: -f1)
if [ -n "$up_scp" ] && [ -n "$up_del" ] && [ "$up_scp" -lt "$up_del" ]; then
	pass "upgrade downloads the backup before deleting the instance"
else
	fail "upgrade downloads the backup before deleting the instance" "scp=$up_scp delete=$up_del"
fi
