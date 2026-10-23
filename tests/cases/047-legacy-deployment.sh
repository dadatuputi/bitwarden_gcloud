# A deployment installed before mid-2023 differs from a current one in two ways
# that the migration has to account for (issue #110): its docker-compose.yml has
# no backup service, and its ~/.bash_alias points docker-compose at the unpinned
# docker/compose image, whose latest tag is Compose 1.26.2 and cannot parse the
# current docker-compose.yml.
mig_script="$ROOT/utilities/migrate-to-data-disk.sh"
mig=$(cat "$mig_script")

# The two causes of "no backup container" need different advice, so the
# missing-service check has to come first.
assert_contains "$mig" 'grep -qE "^  backup:" ~/bitwarden_gcloud/docker-compose.yml' \
	"checks the deployment's compose file for a backup service"
assert_before "$mig" 'has no backup service' 'The backup container is not running' \
	"tells an old deployment to update before telling it to start the container"
n=$(printf '%s\n' "$mig" | grep -c 'The backup container is not running' || true)
assert_eq "$n" "1" "checks the backup container once"

# The pattern has to match the service in the file this repository ships.
if grep -qE '^  backup:' "$ROOT/docker-compose.yml"; then
	pass "the backup-service check matches the current docker-compose.yml"
else
	fail "the backup-service check matches the current docker-compose.yml"
fi

# The advice to start the stack must use the shim, not whatever docker-compose
# resolves to in the operator's shell.
assert_contains "$mig" '. ~/.bwgc-compose.sh; docker-compose up -d' \
	"tells the operator to start the stack through the shim"

# Run the removal the script sends to the instance against an alias file in the
# form the old install-alias.sh wrote.
home="$WORK/legacy-home"
mkdir -p "$home"
cat > "$home/.bash_alias" <<'EOF'
alias ll='ls -l'
alias docker-compose='docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PWD:$PWD" \
    -w="$PWD" \
    docker/compose'
alias la='ls -a'
EOF
body=$(sed -n '/^strip_old_alias_body() {/,/^}/p' "$mig_script")
out=$(eval "$body"; strip_old_alias_body | HOME="$home" sh -s)
after=$(cat "$home/.bash_alias")
assert_not_contains "$after" "docker-compose" "removes the multi-line docker/compose alias"
assert_not_contains "$after" "docker/compose" "leaves no continuation line behind"
assert_contains "$after" "alias ll='ls -l'" "keeps the operator's other aliases before it"
assert_contains "$after" "alias la='ls -a'" "keeps the operator's other aliases after it"
assert_contains "$out" "Removed the old docker-compose alias" "says what it removed"

out=$(eval "$body"; strip_old_alias_body | HOME="$home" sh -s)
assert_eq "$out" "" "does nothing on a second run"

# The migration runs it every time it installs the shim.
inst=$(sed -n '/^install_compose_helper() {/,/^}/p' "$mig_script")
assert_contains "$inst" "strip_old_alias_body |" "installing the shim also removes the old alias"
