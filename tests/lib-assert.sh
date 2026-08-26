#!/usr/bin/env sh
# Minimal assertions. No dependencies: this must run wherever the scripts do.

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
}

assert_contains() {
	if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"
	else fail "$3" "expected to find: $2"; fi
}

assert_not_contains() {
	if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3" "did not expect: $2"
	else pass "$3"; fi
}

# assert_before HAYSTACK EARLIER LATER LABEL
# Both must appear, and EARLIER must appear on a lower line than LATER.
assert_before() {
	_e=$(printf '%s' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1)
	_l=$(printf '%s' "$1" | grep -nF -- "$3" | head -1 | cut -d: -f1)
	if [ -z "$_e" ]; then fail "$4" "never happened: $2"; return; fi
	if [ -z "$_l" ]; then fail "$4" "never happened: $3"; return; fi
	if [ "$_e" -lt "$_l" ]; then pass "$4"
	else fail "$4" "'$2' (line $_e) should precede '$3' (line $_l)"; fi
}

assert_status() {
	if [ "$1" -eq "$2" ]; then pass "$3"
	else fail "$3" "expected exit $2, got $1"; fi
}
