# caddy/Caddyfile is mounted into the proxy container as shipped. It is
# validated here by the image that will serve it when Docker is available,
# and by a local caddy otherwise; the Caddyfile's own {$VAR} placeholders are
# checked against what compose actually passes to that container.
caddyfile="$ROOT/caddy/Caddyfile"

# Placeholders in live (uncommented) lines, and the proxy service's
# environment as compose declares it.
placeholders=$(grep -v '^[[:space:]]*#' "$caddyfile" | grep -oE '\{\$[A-Z_]+\}' | tr -d '{$}' | sort -u)
awk '
	/^  proxy:/ { insvc = 1; next }
	insvc && /^  [a-z]/ { insvc = 0 }
	insvc && /^    environment:/ { inenv = 1; next }
	insvc && inenv && /^    - / { sub(/^    - /, ""); sub(/[=[:space:]].*/, ""); print; next }
	insvc && inenv && !/^    -/ { inenv = 0 }
' "$ROOT/docker-compose.yml" | sort -u > "$WORK/proxy-env"
unmet=$(printf '%s\n' "$placeholders" | grep -vxF -f "$WORK/proxy-env" || true)
[ -z "$unmet" ] && pass "every {\$VAR} in the Caddyfile is passed to the proxy by compose" \
	|| fail "every {\$VAR} in the Caddyfile is passed to the proxy by compose" "not in proxy environment: $(printf '%s' "$unmet" | tr '\n' ' ')"

validate=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	image=$(grep -oE 'ghcr.io/dadatuputi/bwgc_caddy:[A-Za-z0-9._-]+' "$ROOT/docker-compose.yml" | head -1)
	validate="docker run --rm -e DOMAIN=vault.example.test -e EMAIL=admin@example.test \
		-v $caddyfile:/etc/caddy/Caddyfile:ro $image \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
	how="with $image"
elif command -v caddy >/dev/null 2>&1; then
	validate="env DOMAIN=vault.example.test EMAIL=admin@example.test caddy validate --config $caddyfile --adapter caddyfile"
	how="with local caddy $(caddy version 2>/dev/null | cut -d' ' -f1)"
fi

if [ -n "$validate" ]; then
	# shellcheck disable=SC2086
	if out=$(eval $validate 2>&1); then
		pass "the Caddyfile validates ($how)"
	else
		fail "the Caddyfile validates ($how)" "$(printf '%s' "$out" | grep -v '^{' | tail -3)"
	fi
	assert_contains "$out" "Valid configuration" "caddy reports the configuration valid"
else
	printf '  skip caddy validate (no docker daemon and no caddy binary)\n'
fi
