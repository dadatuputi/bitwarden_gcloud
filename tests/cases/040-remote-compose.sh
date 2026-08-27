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
	aliased=$(printf '%s' "$src" | grep -nE '(on_vm|&&|;|^)[[:space:]]*docker-compose ' | grep -v 'echo ' || true)
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
