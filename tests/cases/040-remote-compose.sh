# docker-compose on these instances is a shell alias in ~/.bash_alias. A
# non-interactive "gcloud compute ssh --command" never sources it, so a remote
# command relying on the alias fails with "command not found" partway through a
# migration. Every remote command that needs compose must carry its own
# definition.
for script in "$ROOT/utilities/migrate-to-data-disk.sh" "$ROOT/utilities/upgrade-cos.sh"; do
	rel=${script#"$ROOT"/}
	src=$(cat "$script")

	assert_not_contains "$src" "docker-compose " "$rel does not call the aliased docker-compose"
	assert_contains "$src" "COMPOSE_FN=" "$rel defines a self-contained compose"

	# The definition must handle both a real plugin and its absence.
	assert_contains "$src" "docker compose version >/dev/null" "$rel probes for the compose plugin"
	assert_contains "$src" "docker:cli compose" "$rel falls back to the containerised compose"

	# Every on_vm block invoking compose must carry the definition.
	missing=$(awk '
		/^on_vm /            { blk=$0; inblk=1; if ($0 !~ /\\$/) { check(); inblk=0 } ; next }
		inblk                { blk=blk "\n" $0; if ($0 !~ /\\$/) { check(); inblk=0 } }
		function check() {
			if (blk ~ /[^-]compose / && blk !~ /COMPOSE_FN/) { print substr(blk,1,50) }
		}
	' "$script")
	if [ -z "$missing" ]; then
		pass "$rel: every remote compose call carries the definition"
	else
		fail "$rel: every remote compose call carries the definition" "$missing"
	fi
done

# Reclaiming space before the copy has to cover the build cache as well as
# images. "docker image prune" does not touch it, and on a host that has ever
# built locally it is often the largest single item.
mig=$(cat "$ROOT/utilities/migrate-to-data-disk.sh")
assert_contains "$mig" "docker image prune -af"   "prunes unused images"
assert_contains "$mig" "docker builder prune -af" "prunes the build cache"
assert_contains "$mig" "bitwarden.log"            "clears the unrotated vault log"

# The vault is stopped for the copy, so any failure there must not leave it
# offline. And the copy must run as root: containers write attachments, RSA keys
# and Caddy's certificate store as root, which the invoking user cannot read.
assert_contains "$mig" "sudo rsync -a --delete" "copies as root, so container-written files are readable"
assert_contains "$mig" "compose up -d\" ||"     "restarts the vault if the copy fails"
assert_contains "$mig" "Nothing on the data disk is trusted after a partial copy" \
  "says a partial copy is not usable"

# A bare rsync would hit permission errors on exactly those paths.
if printf '%s' "$mig" | grep -qE '^\s*rsync -a'; then
	fail "no unprivileged rsync of the deployment" "found a bare 'rsync -a'"
else
	pass "no unprivileged rsync of the deployment"
fi
