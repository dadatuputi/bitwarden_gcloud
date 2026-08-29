# The restart policy decides who starts the stack at boot. Docker starts an
# always, unless-stopped or on-failure container about twenty seconds before
# cloud-init mounts the data disk; only "no" keeps it out. The policy is a
# variable so an existing deployment keeps its current behaviour untouched.
compose="$ROOT/docker-compose.yml"

active=$(grep -cE '^    restart: ' "$compose" || true)
tmpl=$(grep -cE '^    restart: \$\{BWGC_RESTART_POLICY:-' "$compose" || true)
if [ "$active" -gt 0 ] && [ "$active" -eq "$tmpl" ]; then
	pass "every service takes its restart policy from BWGC_RESTART_POLICY ($tmpl services)"
else
	fail "every service takes its restart policy from BWGC_RESTART_POLICY" \
		"$tmpl of $active services parameterised"
fi

# Defaulting is what keeps a deployment that never sets the variable identical
# to what it ran before.
if grep -qE '^    restart: \$\{BWGC_RESTART_POLICY:-always\}' "$compose"; then
	pass "defaults to always when the variable is unset"
else
	fail "defaults to always when the variable is unset"
fi
if grep -qE '^    restart: \$\{BWGC_RESTART_POLICY:-on-failure\}' "$compose"; then
	pass "keeps the backup container's on-failure default"
else
	fail "keeps the backup container's on-failure default"
fi
if grep -qE '^    restart: \$\{BWGC_RESTART_POLICY(:-)?\}' "$compose"; then
	fail "no service is left without a default" "an empty .env would unset the policy"
else
	pass "no service is left without a default"
fi

assert_contains "$(cat "$ROOT/.env.template")" "BWGC_RESTART_POLICY" \
	"the variable is documented in .env.template"

# migrate-to-data-disk.sh installs the cloud-init units that start the stack, so
# it is the only thing that may set the policy.
mig=$(cat "$ROOT/utilities/migrate-to-data-disk.sh")
assert_contains "$mig" "BWGC_RESTART_POLICY=no" \
	"the migration sets the policy once the data disk exists"
