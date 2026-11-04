#!/usr/bin/env sh
#
# Check that a pull request description ends with the release-note trailers.
#
#   check-pr-trailers.sh [FILE]     read the description from FILE, or stdin
#
# The last paragraph of the description must be a block of git trailers with
# at least one Changelog line:
#
#   Changelog: Secrets under the stack directory are private before every start.
#   Upgrade-Action: Run utilities/update.sh once on an existing deployment.
#
# "Changelog: none" says the change is not one a user would notice, and must
# then be the only Changelog line, with no Upgrade-Action. Upgrade-Action is
# optional, and may repeat, as may Changelog.
#
# The repository's merge commit message is set to the pull request's title and
# description, so these trailers end up in the merge commit on master, where
# release-notes.sh reads them back with the same parser.
#
# Exits 0 when the trailers are acceptable and 1 when they are not, printing
# one line per problem.

set -u

if [ $# -gt 0 ]; then
	BODY=$(cat -- "$1")
else
	BODY=$(cat)
fi

# GitHub stores descriptions typed in the web editor with CRLF line endings.
# --no-divider: a line starting with "---" (a Markdown rule) must not be taken
# for the start of a patch, which would hide everything after it.
TRAILERS=$(printf '%s\n' "$BODY" | tr -d '\r' | git interpret-trailers --parse --no-divider)

# Trailer keys are matched without regard to case, as git does.
values() {
	printf '%s\n' "$TRAILERS" | awk -v key="$1" '
		{ i = index($0, ":"); if (i == 0) next
		  k = tolower(substr($0, 1, i - 1))
		  if (k != tolower(key)) next
		  v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
		  print (v == "" ? "<empty>" : v) }'
}

CHANGELOG=$(values Changelog)
UPGRADE=$(values Upgrade-Action)

problems=0
problem() { printf '%s\n' "$1"; problems=$((problems + 1)); }

if [ -z "$CHANGELOG" ]; then
	if printf '%s\n' "$BODY" | grep -qi '^[[:space:]]*changelog[[:space:]]*:'; then
		problem "A Changelog line is there, but not in the last paragraph of the description, so git does not read it as a trailer. Move the trailers to the very end, after everything else, with a blank line above them."
	else
		problem "No Changelog trailer. End the description with \"Changelog: <one line for the release notes>\", or \"Changelog: none\" if users would not notice the change."
	fi
fi

if printf '%s\n' "$CHANGELOG" | grep -qx '<empty>'; then
	problem "A Changelog trailer is empty. Write the release-note line, or \"none\"."
fi
if printf '%s\n' "$UPGRADE" | grep -qx '<empty>'; then
	problem "An Upgrade-Action trailer is empty. Say what an existing deployment must do, or remove the line."
fi

# The pull request template's placeholders, left as they were.
if printf '%s\n' "$CHANGELOG" | grep -v -x '<empty>' | grep -q '^<.*>$'; then
	problem "The Changelog line is still the template's placeholder. Write the release-note line, or \"none\"."
fi
if printf '%s\n' "$UPGRADE" | grep -v -x '<empty>' | grep -q '^<.*>$'; then
	problem "The Upgrade-Action line is still the template's placeholder. Say what an existing deployment must do, or delete the line."
fi

if printf '%s\n' "$CHANGELOG" | grep -qix 'none'; then
	if [ "$(printf '%s\n' "$CHANGELOG" | grep -c .)" -gt 1 ]; then
		problem "\"Changelog: none\" is there alongside other Changelog lines. Keep one or the other."
	fi
	if [ -n "$UPGRADE" ]; then
		problem "\"Changelog: none\" with an Upgrade-Action: a change existing deployments must act on belongs in the release notes."
	fi
fi

if [ "$problems" -eq 0 ]; then
	printf 'Release-note trailers found:\n'
	printf '%s\n' "$TRAILERS" | grep -i -e '^changelog[[:space:]]*:' -e '^upgrade-action[[:space:]]*:'
fi
[ "$problems" -eq 0 ]
