#!/usr/bin/env sh
#
# Reboot this Container-Optimized OS host if, and only if, update-engine has
# already staged an update that needs a reboot to take effect.
#
# Invoked by cos-update-reboot.timer, which defines the reboot window. See
# README-cos-updates.md for installation and for what this does not cover.
#
# Containers come back on their own: every service in docker-compose.yml sets
# restart: always or restart: on-failure.

set -eu

STATUS="$(update_engine_client --status 2>/dev/null || true)"

if [ -z "$STATUS" ]; then
	echo "cos-update-reboot: could not query update_engine, doing nothing" >&2
	exit 0
fi

CURRENT_OP="$(printf '%s\n' "$STATUS" | sed -n 's/^CURRENT_OP=//p')"
NEW_VERSION="$(printf '%s\n' "$STATUS" | sed -n 's/^NEW_VERSION=//p')"

echo "cos-update-reboot: CURRENT_OP=${CURRENT_OP:-unknown} NEW_VERSION=${NEW_VERSION:-unknown}"

if [ "${CURRENT_OP:-}" = "UPDATE_STATUS_UPDATED_NEED_REBOOT" ]; then
	echo "cos-update-reboot: staged update ${NEW_VERSION:-unknown}, rebooting now"
	systemctl reboot
else
	echo "cos-update-reboot: nothing staged, not rebooting"
fi
