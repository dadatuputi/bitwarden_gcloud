#!/usr/bin/env sh
#
# Draft release notes from the Changelog and Upgrade-Action trailers.
#
#   release-notes.sh [FROM [TO]]
#
# FROM defaults to the latest tag reachable from TO, and TO to HEAD. Only the
# commits on master's own line (--first-parent) are read: each pull request's
# merge commit carries its description, trailers included, so a pull request is
# counted once however many commits it had. Prints Markdown to stdout.

set -eu

PARSE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/parse-trailers.sh"
TO=${2:-HEAD}
FROM=${1:-$(git describe --tags --abbrev=0 "$TO")}

changes=""
actions=""
nl='
'

for c in $(git rev-list --first-parent --reverse "$FROM..$TO"); do
	msg=$(git log -1 --format=%B "$c")
	subject=$(printf '%s\n' "$msg" | head -1)
	ref=$(printf '%s\n' "$subject" | sed -n 's/^Merge pull request \(#[0-9][0-9]*\).*/ (\1)/p')
	trailers=$(printf '%s\n' "$msg" | sh "$PARSE")
	while IFS= read -r line; do
		key=$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')
		val=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$val" ] || continue
		case "$key" in
			changelog)
				case "$val" in [Nn][Oo][Nn][Ee]) continue ;; esac
				changes="$changes- $val$ref$nl" ;;
			upgrade-action)
				actions="$actions- $val$ref$nl" ;;
		esac
	done <<TRAILERS
$trailers
TRAILERS
done

printf '## Changes since %s\n\n' "$FROM"
if [ -n "$changes" ]; then printf '%s' "$changes"; else printf 'No user-facing changes recorded.\n'; fi
if [ -n "$actions" ]; then
	printf '\n## Before you update an existing deployment\n\n%s' "$actions"
fi
