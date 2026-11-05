# docker-compose.yml is what a deployment runs, and .env.template is what its
# .env starts from. The two must agree, and both compose paths must render.

# Every variable the compose files read from .env must be in the template, or
# an operator following it has no way to know the setting exists. ${VAR}
# interpolations are collected from anywhere; bare "- VAR" pass-throughs only
# from environment: blocks, since cap_add: lists look the same. PWD is set by
# compose itself.
compose_vars=$(
	for f in "$ROOT/docker-compose.yml" "$ROOT/docker-compose.tunnel.yml"; do
		grep -oE '\$\{[A-Z_]+' "$f" | tr -d '${'
		awk '
			/^[[:space:]]*environment:[[:space:]]*$/ { inenv = 1; next }
			inenv && /^[[:space:]]*- [A-Z_]+[[:space:]]*(#.*)?$/ { sub(/^[[:space:]]*- /, ""); sub(/[[:space:]].*/, ""); print; next }
			inenv && !/^[[:space:]]*-/ { inenv = 0 }
		' "$f"
	done | grep -vx PWD | sort -u
)
grep -oE '^#? ?[A-Z_]+=' "$ROOT/.env.template" | tr -d '# =' | sort -u > "$WORK/template-vars"
missing=$(printf '%s\n' "$compose_vars" | grep -vxF -f "$WORK/template-vars" || true)
[ -z "$missing" ] && pass "every variable compose reads is documented in .env.template" \
	|| fail "every variable compose reads is documented in .env.template" "missing: $(printf '%s' "$missing" | tr '\n' ' ')"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
	# The template as shipped, with the two values that have no default. Any
	# other unset variable must render as empty or as its default, not warn.
	compose() {
		DOMAIN=vault.example.test EMAIL=admin@example.test \
			docker compose --project-directory "$ROOT" --env-file "$ROOT/.env.template" "$@"
	}

	# Caddy path: the default, docker-compose.yml alone.
	compose -f "$ROOT/docker-compose.yml" config >"$WORK/compose-caddy.yaml" 2>"$WORK/compose-caddy.err"
	assert_status $? 0 "the caddy path renders (docker compose config)"
	err=$(cat "$WORK/compose-caddy.err")
	assert_not_contains "$err" "is not set" "the caddy path reads no variable the template lacks"
	svcs=$(compose -f "$ROOT/docker-compose.yml" config --services 2>/dev/null | sort | tr '\n' ' ')
	assert_contains "$svcs" "proxy "   "the caddy path runs the proxy"
	assert_contains "$svcs" "ddns "    "the caddy path runs ddns"
	assert_not_contains "$svcs" "cloudflared" "the caddy path does not run cloudflared"

	# Tunnel path: what COMPOSE_FILE=docker-compose.yml:docker-compose.tunnel.yml
	# selects. The caddy-only services must drop out and cloudflared come in.
	compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.tunnel.yml" config >"$WORK/compose-tunnel.yaml" 2>"$WORK/compose-tunnel.err"
	assert_status $? 0 "the tunnel path renders (docker compose config)"
	err=$(cat "$WORK/compose-tunnel.err")
	assert_not_contains "$err" "is not set" "the tunnel path reads no variable the template lacks"
	svcs=$(compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.tunnel.yml" config --services 2>/dev/null | sort | tr '\n' ' ')
	assert_contains "$svcs" "cloudflared" "the tunnel path runs cloudflared"
	for s in proxy ddns countryblock fail2ban; do
		assert_not_contains "$svcs" "$s " "the tunnel path does not run $s"
	done
	assert_contains "$(cat "$WORK/compose-tunnel.yaml")" "pull_policy: daily" "the tunnel path re-checks for a newer cloudflared each day"
	assert_contains "$(cat "$WORK/compose-tunnel.yaml")" "IP_HEADER: CF-Connecting-IP" "the tunnel path tells vaultwarden which header carries the client IP"

	# watchtower is how security updates reach an unattended deployment, so it
	# runs by default, and WATCHTOWER_MONITOR_ONLY reaches it to turn that off.
	svcs=$(compose -f "$ROOT/docker-compose.yml" config --services 2>/dev/null | sort | tr '\n' ' ')
	assert_contains "$svcs" "watchtower " "watchtower runs by default"
	wt=$(WATCHTOWER_MONITOR_ONLY=true compose -f "$ROOT/docker-compose.yml" config watchtower 2>/dev/null)
	assert_contains "$wt" 'WATCHTOWER_MONITOR_ONLY: "true"' "WATCHTOWER_MONITOR_ONLY reaches watchtower"

	# The end-to-end overlay: bitwarden and backup only, nothing that needs a
	# hostname, and no cloudflared either.
	svcs=$(compose -f "$ROOT/docker-compose.yml" -f "$ROOT/tests/e2e/docker-compose.e2e.yml" config --services 2>/dev/null | sort | tr '\n' ' ')
	assert_eq "$svcs" "backup bitwarden " "the e2e overlay runs only bitwarden and backup"
else
	printf '  skip docker compose config (docker compose not installed)\n'
fi

# The bwgc images follow their major version tag, which moves only to a
# compatible release or a security rebuild of one. :master would also carry
# unreleased and breaking changes to every deployment.
for img in bwgc_backup bwgc_caddy bwgc_countryblock; do
	ref=$(grep -oE "ghcr.io/dadatuputi/$img:[A-Za-z0-9._-]+" "$ROOT/docker-compose.yml" | head -1)
	case "${ref##*:}" in
		[0-9]|[0-9][0-9]) assert_eq ok ok "$img follows a major version tag (${ref##*:})" ;;
		*) assert_eq "${ref##*:}" "a major version" "$img follows a major version tag" ;;
	esac
done
