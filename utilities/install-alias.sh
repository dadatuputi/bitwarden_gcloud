#!/usr/bin/env sh
#
# Install a docker-compose shim. Container-Optimized OS ships no compose binary,
# so it runs in a container against the host's Docker socket.
#
# A shell function in a sourced file, not an alias, because of where this has to
# work:
#
#   - bash does not expand aliases in a non-interactive shell, even when the
#     alias is defined, so an alias can never serve `ssh --command`.
#   - Nothing under $HOME is on PATH, and every PATH entry COS exports is on the
#     read-only root -- /usr/local/bin does not even exist -- so the shim cannot
#     be an executable on PATH either.
#   - /home and /var are both mounted noexec, so even by absolute path the file
#     has to be handed to an interpreter rather than executed.
#   - ~/.bashrc is not sourced for `ssh --command` at all, and COS's copy
#     returns early for non-interactive shells, so `bash -lc` gets nothing.
#
# A sourced function survives all of that. Interactive shells pick it up from
# ~/.bashrc; anything non-interactive sources the file explicitly:
#
#     gcloud compute ssh $INSTANCE --zone $ZONE --command \
#       '. ~/.bwgc-compose.sh; cd ~/bitwarden_gcloud && docker-compose ps'
#
# migrate-to-data-disk.sh and upgrade-cos.sh source the same file, so running
# this script is also what puts it back after an instance is replaced.
#
# Safe to run more than once: existing definitions are replaced, not appended.

set -eu

HELPER=~/.bwgc-compose.sh
ALIAS_FILE=~/.bash_alias
BASHRC=~/.bashrc

# pwd -P, not $PWD. If the deployment is reached through a symlink -- which it
# is after migrate-to-data-disk.sh -- $PWD is the symlink path, and compose
# would resolve ${PWD} in docker-compose.yml to a different source than the
# running containers were created with, recreating every container on each
# switch between the two paths.
cat > "$HELPER" <<'BWGCEOF'
# Sourced, not executed: /home is noexec. Defines compose and docker-compose.
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$(pwd -P):$(pwd -P)" -w="$(pwd -P)" \
      -e COMPOSE_DOCKER_CLI_BUILD=1 \
      -e DOCKER_BUILDKIT=1 \
      --entrypoint docker docker:cli compose "$@"
  fi
}
docker-compose() { compose "$@"; }
BWGCEOF
echo "Wrote $HELPER."

# Drop any alias left by earlier versions, including multi-line ones. It would
# otherwise shadow the function in interactive shells.
if [ -f "$ALIAS_FILE" ] && grep -q "alias docker-compose=" "$ALIAS_FILE"; then
	awk '
		/^#?[[:space:]]*alias docker-compose=/ { skip=1 }
		skip { if ($0 !~ /\\$/) { skip=0 }; next }
		{ print }
	' "$ALIAS_FILE" > "$ALIAS_FILE.tmp"
	mv "$ALIAS_FILE.tmp" "$ALIAS_FILE"
	echo "Removed the old docker-compose alias from $ALIAS_FILE."
fi

if ! grep -q 'bwgc-compose.sh' "$BASHRC" 2>/dev/null; then
	cat >> "$BASHRC" <<'EOF'
if [ -f ~/.bwgc-compose.sh ]; then
    . ~/.bwgc-compose.sh
fi
EOF
	echo "Sourced ~/.bwgc-compose.sh from ~/.bashrc."
fi

cat <<EOF

Done. In an interactive shell, start a new one or run:

    . ~/.bashrc
    docker-compose version

Over ssh, where nothing is sourced for you, source it in the command:

    gcloud compute ssh \$INSTANCE --zone \$ZONE --command \\
      '. ~/.bwgc-compose.sh; cd ~/bitwarden_gcloud && docker-compose ps'
EOF
