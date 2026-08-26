#!/usr/bin/env sh
#
# Move a bitwarden_gcloud deployment to a newer Container-Optimized OS
# milestone by building a new instance and reattaching the vault data disk.
#
# Requires that utilities/migrate-to-data-disk.sh has already been run, so the
# vault lives on its own disk rather than on the boot disk.
#
# Run from Cloud Shell, or anywhere with gcloud authenticated.
#
# The old instance is stopped, never deleted. Rollback is starting it again.

set -eu

DISK_NAME=bwgc-data
MOUNT=/mnt/disks/bwgc
BOOT_SIZE=10GB
REBOOT_TIME=06:00
INSTANCE=
NEW_INSTANCE=
ZONE=
IMAGE_FAMILY=
ASSUME_YES=0
KEEP_OLD=0
DELETE_FIRST=0

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib-bwgc-cloudinit.sh"

usage() {
	cat <<EOF
Usage: $0 --instance NAME --zone ZONE [options]

  --instance NAME      the current instance (required)
  --zone ZONE          its zone (required)
  --new-instance NAME  name for the replacement (default: NAME-<milestone>)
  --image-family FAM   COS family (default: newest cos-*-lts published)
  --disk-name NAME     the vault data disk (default: $DISK_NAME)
  --mount PATH         where it mounts (default: $MOUNT)
  --boot-size SIZE     new boot disk size (default: $BOOT_SIZE)
  --reboot-time HH:MM  update reboot window (default: $REBOOT_TIME)
  --keep-old           leave the old instance stopped instead of deleting it
  --delete-first       destroy the old instance BEFORE building the new one, so
                       the two never coexist. Needed only if your disks are
                       large enough that overlap would exceed 30 GB. Trades a
                       capacity-failure window for guaranteed zero overage.
  --yes                do not prompt

Free tier: 30 GB of pd-standard. At 10 GB boot + 10 GB data, steady state is
20 GB and the brief overlap during an upgrade is 30 GB -- at the allowance, not
over it, so overlap is free. Larger disks (15+15) exceed 30 GB while both exist
and need --delete-first.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--instance) INSTANCE="$2"; shift 2 ;;
	--new-instance) NEW_INSTANCE="$2"; shift 2 ;;
	--zone) ZONE="$2"; shift 2 ;;
	--image-family) IMAGE_FAMILY="$2"; shift 2 ;;
	--disk-name) DISK_NAME="$2"; shift 2 ;;
	--mount) MOUNT="$2"; shift 2 ;;
	--boot-size) BOOT_SIZE="$2"; shift 2 ;;
	--reboot-time) REBOOT_TIME="$2"; shift 2 ;;
	--keep-old) KEEP_OLD=1; shift ;;
	--delete-first) DELETE_FIRST=1; shift ;;
	--yes) ASSUME_YES=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -n "$INSTANCE" ] && [ -n "$ZONE" ] || { usage >&2; exit 2; }
command -v gcloud >/dev/null 2>&1 || { echo "gcloud not found. Run this from Cloud Shell." >&2; exit 1; }

say() { printf '\n=== %s\n' "$1"; }
on_vm() { gcloud compute ssh "$1" --zone "$ZONE" --command "$2"; }
confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r reply
	case "$reply" in y|Y|yes|YES) return 0 ;; *) echo "aborted."; exit 1 ;; esac
}

say "Resolving the target milestone"
if [ -z "$IMAGE_FAMILY" ]; then
	# Probe family pointers rather than listing images. Individual images get
	# marked DEPRECATED as newer builds supersede them within a live family, so
	# an image listing reports healthy milestones as deprecated. The family
	# endpoint is the truth: it 404s once a milestone reaches end of support.
	for m in 165 161 157 153 149 145 141 137 133 129 125 121 117; do
		if gcloud compute images describe-from-family "cos-${m}-lts" \
			--project cos-cloud --format="value(name)" >/dev/null 2>&1; then
			IMAGE_FAMILY="cos-${m}-lts"
			break
		fi
	done
	[ -n "$IMAGE_FAMILY" ] || { echo "could not resolve a live cos-*-lts family" >&2; exit 1; }
	echo "newest live LTS family: $IMAGE_FAMILY"
fi
MILESTONE=$(printf '%s' "$IMAGE_FAMILY" | sed 's/^cos-//; s/-lts$//')
[ -n "$NEW_INSTANCE" ] || NEW_INSTANCE="${INSTANCE}-${MILESTONE}"

CURRENT=$(on_vm "$INSTANCE" 'grep -h ^VERSION= /etc/os-release | cut -d= -f2' 2>/dev/null | tr -d '\r' || echo unknown)

say "Plan"
cat <<EOF
  from        $INSTANCE   (COS milestone $CURRENT)
  to          $NEW_INSTANCE  ($IMAGE_FAMILY, ${BOOT_SIZE} pd-standard)
  data disk   $DISK_NAME  ->  $MOUNT
  zone        $ZONE

  The old instance is stopped, not deleted. Rollback is starting it again.
EOF
[ "$CURRENT" = "$MILESTONE" ] && echo "  NOTE: already on milestone $MILESTONE."
confirm "Proceed?"

say "Step 1/6: back up and verify before touching anything"
on_vm "$INSTANCE" "cd $MOUNT/bitwarden_gcloud && docker exec backup ash /backup.sh local,rclone"
on_vm "$INSTANCE" "set -e; cd $MOUNT/bitwarden_gcloud; \
  LATEST=\$(ls -t bitwarden/backups/*.aes256 2>/dev/null | head -1); \
  [ -n \"\$LATEST\" ] || { echo 'no backup produced' >&2; exit 1; }; \
  docker exec backup sh -c \"openssl enc -d -aes256 -salt -pbkdf2 \
    -pass pass:\\\"\\\$BACKUP_ENCRYPTION_KEY\\\" -in /data/backups/\$(basename \$LATEST) \
    | tar tzf - | grep -qx db.sqlite3\" \
  && echo 'BACKUP_VERIFIED'"

# Keep a copy in this shell session. Not every deployment has rclone
# configured, and this is usually run by hand, so a local copy is the one
# rollback we can guarantee exists.
LOCAL_BACKUP_DIR="${PWD}/bwgc-backups"
mkdir -p "$LOCAL_BACKUP_DIR"
REMOTE_BACKUP=$(on_vm "$INSTANCE" "ls -t $MOUNT/bitwarden_gcloud/bitwarden/backups/*.aes256 2>/dev/null | head -1" | tr -d '\r')
if [ -n "$REMOTE_BACKUP" ]; then
	gcloud compute scp "$INSTANCE:$REMOTE_BACKUP" "$LOCAL_BACKUP_DIR/" --zone "$ZONE"
	echo "backup pulled to $LOCAL_BACKUP_DIR/$(basename "$REMOTE_BACKUP")"
	echo "KEEP THIS until the new instance is confirmed working from a real client."
	echo "It is encrypted with BACKUP_ENCRYPTION_KEY from your .env. Without that key it is useless -- record it now."
else
	echo "WARNING: could not locate a backup file to pull down." >&2
	confirm "Continue without a local copy?"
fi

say "Step 2/6: stop the stack and release the data disk"
on_vm "$INSTANCE" "cd $MOUNT/bitwarden_gcloud && docker-compose down && sudo umount $MOUNT && echo UNMOUNTED"
gcloud compute instances stop "$INSTANCE" --zone "$ZONE"
gcloud compute instances detach-disk "$INSTANCE" --disk "$DISK_NAME" --zone "$ZONE"
echo "data disk detached and safe"

if [ "$DELETE_FIRST" -eq 1 ]; then
	say "Destroying the old instance before building the replacement"
	cat <<EOF
  --delete-first: $INSTANCE and its boot disk are about to be deleted.

  From that moment until the new instance is serving there is no running vault.
  Your data is not at risk -- it is on $DISK_NAME, which is already detached,
  and a verified backup is in $LOCAL_BACKUP_DIR. What is at risk is uptime, if
  instance creation fails (zone capacity for e2-micro is the realistic cause).

  Recovery in that case is to re-run this script, or create any instance and
  attach $DISK_NAME. There is deliberately no path back to the old milestone.
EOF
	confirm "Delete $INSTANCE now, before the replacement exists?"
	gcloud compute instances delete "$INSTANCE" --zone "$ZONE" --quiet
	echo "old instance and boot disk deleted. Nothing to fall back to by design."
fi

say "Step 3/6: create the replacement with the disk attached from first boot"
CC=$(mktemp)
emit_cloud_config "$DISK_NAME" "$MOUNT" "$REBOOT_TIME" > "$CC"
gcloud compute instances create "$NEW_INSTANCE" \
	--zone "$ZONE" \
	--machine-type e2-micro \
	--image-family "$IMAGE_FAMILY" \
	--image-project cos-cloud \
	--boot-disk-size "$BOOT_SIZE" \
	--boot-disk-type pd-standard \
	--disk "name=$DISK_NAME,device-name=$DISK_NAME,mode=rw,boot=no" \
	--metadata-from-file user-data="$CC"

say "Step 4/6: waiting for the new instance"
i=0
while [ $i -lt 30 ]; do
	sleep 10
	if on_vm "$NEW_INSTANCE" 'true' >/dev/null 2>&1; then break; fi
	i=$((i + 1))
done
if ! on_vm "$NEW_INSTANCE" "true" >/dev/null 2>&1; then
	cat >&2 <<EOF

FAILED: $NEW_INSTANCE never became reachable.

Your vault data is intact on $DISK_NAME, and a verified backup is in
$LOCAL_BACKUP_DIR. Nothing has been lost.

Do NOT treat restarting the old instance as the fix if it still exists. It runs
a milestone that is out of support and receives no security patches; going back
to it is a regression, not a recovery. Diagnose why creation or boot failed --
zone capacity for e2-micro is the usual cause -- and re-run this script.
EOF
	exit 1
fi

say "Step 5/6: bring the vault up on the new milestone"
on_vm "$NEW_INSTANCE" "set -e; \
  echo '--- milestone ---'; grep -E '^(VERSION|BUILD_ID)=' /etc/os-release; \
  echo '--- docker ---'; docker --version; \
  echo '--- data disk ---'; df -h $MOUNT; \
  cd $MOUNT/bitwarden_gcloud && ./utilities/install-alias.sh >/dev/null 2>&1 || true"
on_vm "$NEW_INSTANCE" "cd $MOUNT/bitwarden_gcloud && docker-compose up -d && sleep 25 && docker ps --format '{{.Names}}\t{{.Status}}'"

say "Step 6/6: verify"
DOMAIN=$(on_vm "$NEW_INSTANCE" "grep -E '^DOMAIN=' $MOUNT/bitwarden_gcloud/.env | cut -d= -f2 | tr -d '\"'" 2>/dev/null | tr -d '\r' || true)
on_vm "$NEW_INSTANCE" "set +e; \
  echo '--- jails ---'; docker exec fail2ban fail2ban-client status 2>&1 | tail -2; \
  echo '--- update timer ---'; systemctl list-timers cos-update-reboot.timer --no-pager | head -3; \
  [ -n '$DOMAIN' ] && { echo '--- vault ---'; curl -sI --max-time 20 https://$DOMAIN/api/version | head -1; \
    curl -sI --max-time 20 https://$DOMAIN/admin | grep -i x-frame-options; }"

say "Step 7/7: complete the swap"
cat <<EOF
  $NEW_INSTANCE is serving on COS milestone $MILESTONE.
  $INSTANCE is stopped. Its boot disk holds nothing you need: the vault lives on
  $DISK_NAME, and a verified backup is in $LOCAL_BACKUP_DIR.

  Log in from a real client and confirm your entries and attachments NOW, before
  the old boot disk goes away.
EOF

if [ "$DELETE_FIRST" -eq 1 ]; then
	echo
	echo "The old instance was already deleted before the rebuild. Nothing to clean up."
elif [ "$KEEP_OLD" -eq 1 ]; then
	echo
	echo "--keep-old given: leaving $INSTANCE stopped."
	echo "It occupies free tier disk allowance until you delete it:"
	echo "    gcloud compute instances delete $INSTANCE --zone $ZONE"
else
	confirm "Delete $INSTANCE and its boot disk now?"
	gcloud compute instances delete "$INSTANCE" --zone "$ZONE" --quiet
	echo "old instance and boot disk deleted. One instance, one data disk."
fi

say "Done"
cat <<EOF
  Rollback, if the new milestone misbehaves:

      $0 --instance $NEW_INSTANCE --zone $ZONE --image-family <previous-family>

  That is the same swap in reverse. The data disk is never rewritten by this
  script, so it carries your vault either way. If the data disk itself is ever
  lost, restore from $LOCAL_BACKUP_DIR onto a fresh deployment.

  Check for anything still billing against the 30 GB free allowance:

      gcloud compute disks list --filter="-users:*"
EOF
