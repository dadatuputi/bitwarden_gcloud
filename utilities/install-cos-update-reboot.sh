#!/usr/bin/env sh
#
# Apply the Container-Optimized OS staged-update reboot timer.
#
# This does NOT install anything onto the instance's filesystem. On COS, /etc is
# a tmpfs overlay: units written to /etc/systemd/system work until the first
# reboot and then silently disappear, which is the opposite of what an
# update-and-reboot timer needs. Google's documented mechanism is cloud-init,
# which reapplies configuration on every boot.
#
# So this prints the cloud-config to apply, and the command to apply it. Run it
# from Cloud Shell, or anywhere gcloud is authenticated.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib-bwgc-cloudinit.sh"

DISK_NAME="${BWGC_DISK_NAME:-bwgc-data}"
MOUNT="${BWGC_MOUNT:-/mnt/disks/bwgc}"
REBOOT_TIME="${BWGC_REBOOT_TIME:-06:00}"

if [ -r /etc/os-release ] && grep -q '^ID=cos' /etc/os-release 2>/dev/null; then
	cat >&2 <<'EOF'
You are running this on the Container-Optimized OS instance itself.

Nothing can be installed from here that survives a reboot: /etc is stateless on
COS, and gcloud is not available to set instance metadata. Run this from Cloud
Shell instead, or apply the cloud-config below by hand.

EOF
fi

OUT=$(mktemp)
emit_cloud_config "$DISK_NAME" "$MOUNT" "$REBOOT_TIME" > "$OUT"

cat <<EOF
Write this cloud-config to your instance metadata:

    gcloud compute instances add-metadata INSTANCE --zone ZONE \\
        --metadata-from-file user-data=$OUT

Then reboot so cloud-init applies it:

    gcloud compute instances reset INSTANCE --zone ZONE

Verify afterwards:

    systemctl list-timers cos-update-reboot.timer --no-pager

If you already have user-data set, merge rather than replace it. Save the
current value first:

    gcloud compute instances describe INSTANCE --zone ZONE \\
        --format="value(metadata.items.filter(\"key:user-data\").extract(value))"

The generated cloud-config is at: $OUT

--- begin cloud-config ---
EOF
cat "$OUT"
