#!/usr/bin/env sh
#
# Test harness for the bitwarden_gcloud utility scripts.
#
#   ./tests/run-tests.sh            run everything
#   ./tests/run-tests.sh sequence   run cases whose name matches "sequence"
#
# No dependencies beyond a POSIX shell. gcloud is replaced by tests/mocks/gcloud,
# which records every call, so the scripts run end to end without touching
# Google Cloud and the ORDER of operations can be asserted -- which is the point.
# shellcheck and a YAML parser are used when present and skipped when not.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ROOT
FILTER="${1:-}"

. "$ROOT/tests/lib-assert.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export WORK

# Put the mocks ahead of anything real.
export PATH="$ROOT/tests/mocks:$PATH"

printf '\nbitwarden_gcloud utility tests\n\n'

for case_file in "$ROOT"/tests/cases/*.sh; do
	name=$(basename "$case_file" .sh)
	if [ -n "$FILTER" ]; then
		case "$name" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	printf '%s\n' "$name"
	# shellcheck disable=SC1090
	. "$case_file"
	printf '\n'
done

printf 'ran %d assertions, %d failed\n\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
