#!/usr/bin/env sh
#
# Superseded by the cos-update-reboot timer in the instance's cloud-config.
#
# On instances configured through GCE startup-script metadata this still runs at
# every boot, holding a blocking update_engine_client for the life of the boot.
# migrate-to-data-disk.sh removes that metadata key.
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
