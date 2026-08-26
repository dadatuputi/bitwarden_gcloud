#!/usr/bin/env sh
#
# One-time migration: move a bitwarden_gcloud deployment onto its own
# persistent disk, so future OS upgrades are a disk reattach rather than a data
# migration. See utilities/README-cos-updates.md.
#
# Run this from Cloud Shell, or anywhere with gcloud authenticated. It does not
# run on the instance itself: creating and attaching disks needs gcloud, which
# Container-Optimized OS does not ship.
#
# Safe to re-run: every step checks whether it has already been done.

set -eu

DISK_NAME=bwgc-data
DISK_SIZE=10GB
MOUNT=/mnt/disks/bwgc
REBOOT_TIME=06:00
INSTANCE=
ZONE=
ASSUME_YES=0
PRINT_ONLY=0

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib-bwgc-cloudinit.sh"

usage() {
	cat <<EOF
Usage: $0 --instance NAME --zone ZONE [options]

  --instance NAME     the instance running bitwarden_gcloud (required)
  --zone ZONE         its zone, e.g. us-central1-a (required)
  --disk-name NAME    data disk to create (default: $DISK_NAME)
  --disk-size SIZE    size, minimum 10GB on pd-standard (default: $DISK_SIZE)
  --mount PATH        where to mount it (default: $MOUNT)
  --reboot-time HH:MM daily window for OS update reboots (default: $REBOOT_TIME)
  --print-cloud-config  print the generated cloud-config and exit
  --yes               do not prompt for confirmation

Free tier note: pd-standard only, and 30 GB total across all disks. A 10 GB
boot disk plus a 10 GB data disk leaves room for a second boot disk during an
upgrade, which is exactly 30 GB. Anything larger will bill.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--instance) INSTANCE="$2"; shift 2 ;;
	--zone) ZONE="$2"; shift 2 ;;
	--disk-name) DISK_NAME="$2"; shift 2 ;;
	--disk-size) DISK_SIZE="$2"; shift 2 ;;
	--mount) MOUNT="$2"; shift 2 ;;
	--reboot-time) REBOOT_TIME="$2"; shift 2 ;;
	--print-cloud-config) PRINT_ONLY=1; shift ;;
	--yes) ASSUME_YES=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [ "$PRINT_ONLY" -eq 1 ]; then
	emit_cloud_config "$DISK_NAME" "$MOUNT" "$REBOOT_TIME"
	exit 0
fi

[ -n "$INSTANCE" ] && [ -n "$ZONE" ] || { usage >&2; exit 2; }
command -v gcloud >/dev/null 2>&1 || { echo "gcloud not found. Run this from Cloud Shell." >&2; exit 1; }

say() { printf '\n=== %s\n' "$1"; }
on_vm() { gcloud compute ssh "$INSTANCE" --zone "$ZONE" --command "$1"; }

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r reply
	case "$reply" in y|Y|yes|YES) return 0 ;; *) echo "aborted."; exit 1 ;; esac
}

REPO_DIR=$(on_vm 'cd ~/bitwarden_gcloud >/dev/null 2>&1 && pwd' || true)
[ -n "$REPO_DIR" ] || { echo "could not find ~/bitwarden_gcloud on $INSTANCE" >&2; exit 1; }

say "Plan"
cat <<EOF
  instance    $INSTANCE  ($ZONE)
  deployment  $REPO_DIR
  new disk    $DISK_NAME  $DISK_SIZE  pd-standard
  mounted at  $MOUNT
  This will reboot the instance to prove the mount survives.
EOF
confirm "Proceed?"

say "Step 1/6: reclaim space before copying"
on_vm 'cd ~/bitwarden_gcloud \
  && docker image prune -af >/dev/null 2>&1 || true; \
  echo "--- reclaimable now ---"; docker system df'
on_vm 'cd ~/bitwarden_gcloud \
  && if [ -s bitwarden/bitwarden.log ]; then \
       ls -lh bitwarden/bitwarden.log; \
       docker-compose stop bitwarden >/dev/null 2>&1 || true; \
       : > bitwarden/bitwarden.log; \
       docker-compose start bitwarden >/dev/null 2>&1 || true; \
       echo "vault log cleared"; \
     else echo "vault log already small"; fi' || true

say "Step 2/6: back up and verify"
on_vm 'docker exec backup ash /backup.sh local,rclone'
on_vm 'set -e; cd ~/bitwarden_gcloud; \
  LATEST=$(ls -t bitwarden/backups/*.aes256 2>/dev/null | head -1); \
  [ -n "$LATEST" ] || { echo "no backup produced" >&2; exit 1; }; \
  echo "verifying $LATEST"; \
  docker exec backup sh -c "openssl enc -d -aes256 -salt -pbkdf2 \
    -pass pass:\"\$BACKUP_ENCRYPTION_KEY\" -in /data/backups/$(basename "$LATEST") \
    | tar tzf - | grep -qx db.sqlite3" \
  && echo "BACKUP_VERIFIED: archive decrypts and contains db.sqlite3"'

say "Step 3/6: create and attach the data disk"
if gcloud compute disks describe "$DISK_NAME" --zone "$ZONE" >/dev/null 2>&1; then
	echo "disk $DISK_NAME already exists, reusing"
else
	gcloud compute disks create "$DISK_NAME" \
		--size "$DISK_SIZE" --type pd-standard --zone "$ZONE"
fi
if on_vm "test -e /dev/disk/by-id/google-$DISK_NAME" >/dev/null 2>&1; then
	echo "already attached"
else
	gcloud compute instances attach-disk "$INSTANCE" \
		--disk "$DISK_NAME" --device-name "$DISK_NAME" --zone "$ZONE"
fi

say "Step 4/6: format and copy the deployment"
on_vm "set -e; DEV=/dev/disk/by-id/google-$DISK_NAME; \
  if ! sudo blkid \$DEV >/dev/null 2>&1; then \
    echo 'formatting ext4'; \
    sudo mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard \$DEV; \
  else echo 'already formatted, not touching it'; fi; \
  sudo mkdir -p $MOUNT; \
  mountpoint -q $MOUNT || sudo mount -t ext4 -o discard,defaults \$DEV $MOUNT; \
  sudo chown \$(id -u):\$(id -g) $MOUNT"
on_vm "set -e; cd ~/bitwarden_gcloud && docker-compose down; \
  echo 'copying deployment (excluding local backups, which are already offsite)'; \
  rsync -a --delete --exclude 'bitwarden/backups/' ~/bitwarden_gcloud/ $MOUNT/bitwarden_gcloud/; \
  mkdir -p $MOUNT/bitwarden_gcloud/bitwarden/backups; \
  du -sh $MOUNT/bitwarden_gcloud"

say "Step 5/6: record the layout in instance metadata"
BACKUP_META=$(mktemp)
gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
	--format="value(metadata.items.filter(\"key:user-data\").extract(value))" > "$BACKUP_META" 2>/dev/null || true
if [ -s "$BACKUP_META" ]; then
	echo "existing user-data saved to $BACKUP_META"
	confirm "Replace the existing user-data metadata?"
fi
CC=$(mktemp)
emit_cloud_config "$DISK_NAME" "$MOUNT" "$REBOOT_TIME" > "$CC"
gcloud compute instances add-metadata "$INSTANCE" --zone "$ZONE" \
	--metadata-from-file user-data="$CC"
echo "cloud-config applied. /etc is tmpfs on COS, so this is what reapplies it every boot."
gcloud compute instances remove-metadata "$INSTANCE" --zone "$ZONE" --keys startup-script >/dev/null 2>&1 \
	&& echo "removed the legacy startup-script reboot watcher, now handled by the timer" || true

say "Step 6/6: reboot and verify the mount returns"
confirm "Reboot $INSTANCE now to prove the mount survives?"
gcloud compute instances reset "$INSTANCE" --zone "$ZONE"
echo "waiting for the instance to come back..."
i=0
while [ $i -lt 30 ]; do
	sleep 10
	if on_vm 'true' >/dev/null 2>&1; then break; fi
	i=$((i + 1))
done
on_vm "set -e; echo '--- mount ---'; df -h $MOUNT; \
  echo '--- timer ---'; systemctl list-timers cos-update-reboot.timer --no-pager | head -3; \
  echo '--- starting the stack from its new home ---'; \
  cd $MOUNT/bitwarden_gcloud && docker-compose up -d; sleep 20; \
  docker ps --format '{{.Names}}\t{{.Status}}'"

say "Done"
cat <<EOF
  The deployment now lives at $MOUNT/bitwarden_gcloud on disk $DISK_NAME.
  The copy under ~/bitwarden_gcloud is still there. Verify the vault from a
  real client, then remove it:

      gcloud compute ssh $INSTANCE --zone $ZONE --command 'rm -rf ~/bitwarden_gcloud'

  From here, upgrade the OS with:  ./utilities/upgrade-cos.sh
EOF
