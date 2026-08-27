#!/usr/bin/env sh
#
# Install a docker-compose alias. Container-Optimized OS ships no compose
# binary, so it runs in a container against the host's Docker socket.
#
# Safe to run more than once: an existing definition is replaced rather than
# appended to.

set -eu

ALIAS_FILE=~/.bash_alias
BASHRC=~/.bashrc

# pwd -P, not $PWD. If the deployment is reached through a symlink -- which it
# is after migrate-to-data-disk.sh -- $PWD is the symlink path, and compose
# would resolve ${PWD} in docker-compose.yml to a different source than the
# running containers were created with, recreating every container on each
# switch between the two paths.
NEW_ALIAS="alias docker-compose='docker run --rm \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v \"\$(pwd -P):\$(pwd -P)\" \\
    -w=\"\$(pwd -P)\" \\
    -e COMPOSE_DOCKER_CLI_BUILD=1 \\
    -e DOCKER_BUILDKIT=1 \\
    --entrypoint docker \\
    docker:cli compose'"

touch "$ALIAS_FILE"

if grep -q "alias docker-compose=" "$ALIAS_FILE"; then
	# Drop every existing definition, including multi-line ones, then re-add.
	awk '
		/^#?[[:space:]]*alias docker-compose=/ { skip=1 }
		skip { if ($0 !~ /\\$/) { skip=0 }; next }
		{ print }
	' "$ALIAS_FILE" > "$ALIAS_FILE.tmp"
	mv "$ALIAS_FILE.tmp" "$ALIAS_FILE"
	echo "Replaced the existing docker-compose alias."
else
	echo "Adding a docker-compose alias."
fi

printf '%s\n' "$NEW_ALIAS" >> "$ALIAS_FILE"

if ! grep -q '.bash_alias' "$BASHRC" 2>/dev/null; then
	cat >> "$BASHRC" <<'EOF'
if [ -f ~/.bash_alias ]; then
    . ~/.bash_alias
fi
EOF
	echo "Sourced ~/.bash_alias from ~/.bashrc."
fi

cat <<EOF

Done. Start a new shell, or run:

    . ~/.bashrc

Then check it:

    docker-compose version
EOF
