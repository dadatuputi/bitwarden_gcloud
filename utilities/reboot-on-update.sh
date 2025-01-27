#!/usr/bin/env sh

# Local timezone - use the TZ database name from https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
# e.g., Etc/UTC, America/New_York, etc
TZ=Etc/UTC

# Local time to schedule reboot
TIME=06:00

SCHEDULED=$(eval "date -d 'TZ=\"$TZ\" $TIME' +%H:%M")

sleep 60 && update_engine_client --block_until_reboot_is_needed
shutdown -r $SCHEDULED
