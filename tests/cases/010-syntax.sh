# Every shipped script must parse, and pass shellcheck when it is available.
for f in "$ROOT"/utilities/*.sh "$ROOT"/tests/run-tests.sh "$ROOT"/tests/mocks/gcloud; do
	rel=${f#"$ROOT"/}
	if sh -n "$f" 2>/dev/null; then pass "parses: $rel"; else fail "parses: $rel"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
	for f in "$ROOT"/utilities/*.sh; do
		rel=${f#"$ROOT"/}
		if out=$(shellcheck -S warning -e SC1091 "$f" 2>&1); then pass "shellcheck: $rel"
		else fail "shellcheck: $rel" "$(printf '%s' "$out" | head -4)"; fi
	done
else
	printf '  skip shellcheck (not installed)\n'
fi
