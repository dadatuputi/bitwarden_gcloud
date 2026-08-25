#!/usr/bin/env sh
#
# DEPRECATED. Nothing invokes this script: Container-Optimized OS ships no cron
# and no unit referenced it, so it never ran unattended. It is kept for
# reference only.
#
# Use the systemd timer instead:  ./utilities/install-cos-update-reboot.sh
# See README-cos-updates.md.

# Local timezone - use the TZ database name from https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
# e.g., Etc/UTC, America/New_York, etc
TZ=Etc/UTC

# Local time to schedule reboot
TIME=06:00

SCHEDULED=$(TZ="$TZ" date -d "$TIME" +%H:%M)

sleep 60 && update_engine_client --block_until_reboot_is_needed
shutdown -r $SCHEDULED
