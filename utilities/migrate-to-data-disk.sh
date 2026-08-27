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
DEFAULT_DATA_GB=15
DISK_SIZE="${DEFAULT_DATA_GB}GB"
MOUNT=/mnt/disks/bwgc
REBOOT_TIME=06:00
INSTANCE=
ZONE=
ASSUME_YES=0
PRINT_ONLY=0
FORCE=0

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib-bwgc-cloudinit.sh"

usage() {
	cat <<EOF
Usage: $0 --instance NAME --zone ZONE [options]

  --instance NAME     the instance running bitwarden_gcloud (required)
  --zone ZONE         its zone, e.g. us-central1-a (required)
  --disk-name NAME    data disk to create (default: $DISK_NAME)
  --disk-size SIZE    override the automatic size (default: $DISK_SIZE)
  --mount PATH        where to mount it (default: $MOUNT)
  --reboot-time HH:MM daily window for OS update reboots (default: $REBOOT_TIME)
  --print-cloud-config  print the generated cloud-config and exit
  --yes               do not prompt for confirmation
  --force             size the disk past the free tier anyway, accepting the
                      charge

Sizing is automatic. The vault is measured, and if it comes within 3GB of
filling the default the disk is expanded to whatever the free tier allows
beside the boot disk -- with a warning, because that consumes the margin. If
even that will not hold it, the script stops and points at --force.

Free tier: 30GB of pd-standard total, and only pd-standard is free.
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
	--force) FORCE=1; shift ;;
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

# compose on these instances is a shell alias in ~/.bash_alias, which a
# non-interactive ssh command never sources. Every remote command that needs
# compose carries this definition instead of relying on the caller's shell.
# docker-compose on these instances is a shell alias in ~/.bash_alias, which a
# non-interactive ssh command never sources. The definition is written to the
# instance once and sourced by each remote command that needs it. Carrying it
# inline instead means nesting quotes inside quotes at every call site.
COMPOSE_HELPER='~/.bwgc-compose.sh'
COMPOSE_SRC=". $COMPOSE_HELPER;"

# Heredoc body is quoted, so nothing in it is expanded locally.
compose_helper_body() {
	cat <<'BWGCEOF'
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$(pwd -P):$(pwd -P)" -w="$(pwd -P)" \
      --entrypoint docker docker:cli compose "$@"
  fi
}
BWGCEOF
}
install_compose_helper() {
	compose_helper_body | gcloud compute ssh "$INSTANCE" --zone "$ZONE" \
		--command "cat > $COMPOSE_HELPER" >/dev/null
}

say() { printf '\n=== %s\n' "$1"; }
on_vm() { gcloud compute ssh "$INSTANCE" --zone "$ZONE" --command "$1"; }

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r reply
	case "$reply" in y|Y|yes|YES) return 0 ;; *) echo "aborted."; exit 1 ;; esac
}

# Same, but proceeding is the default. Used where stopping is the unusual
# choice and the change has already been shown in full.
confirm_default_yes() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '%s [Y/n] ' "$1"
	read -r reply
	case "$reply" in n|N|no|NO) echo "aborted."; exit 1 ;; *) return 0 ;; esac
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

install_compose_helper

say "Step 1/7: reclaim space before copying"
on_vm 'cd ~/bitwarden_gcloud \
  && echo "--- before ---" && docker system df \
  && docker image prune -af >/dev/null 2>&1 || true; \
  docker builder prune -af >/dev/null 2>&1 || true; \
  echo "--- after ---"; docker system df; \
  echo "--- restoring the docker:cli image the prune removed ---"; \
  docker pull -q docker:cli >/dev/null 2>&1 || true'
on_vm "$COMPOSE_SRC cd ~/bitwarden_gcloud \
  && if [ -s bitwarden/bitwarden.log ]; then \
       ls -lh bitwarden/bitwarden.log; \
       compose stop bitwarden >/dev/null 2>&1 || true; \
       : > bitwarden/bitwarden.log; \
       compose start bitwarden >/dev/null 2>&1 || true; \
       echo "vault log cleared"; \
     else echo 'vault log already small'; fi" || true

say "Step 2/7: back up and verify"
on_vm 'docker exec backup ash /backup.sh local,rclone'
on_vm 'set -e; cd ~/bitwarden_gcloud; \
  LATEST=$(ls -t bitwarden/backups/*.aes256 2>/dev/null | head -1); \
  [ -n "$LATEST" ] || { echo "no backup produced" >&2; exit 1; }; \
  echo "verifying $LATEST"; \
  docker exec backup sh -c "openssl enc -d -aes256 -salt -pbkdf2 \
    -pass pass:\"\$BACKUP_ENCRYPTION_KEY\" -in /data/backups/$(basename "$LATEST") \
    | tar tzf - | grep -qx db.sqlite3" \
  && echo "BACKUP_VERIFIED: archive decrypts and contains db.sqlite3"'

# Pull it down now, not later. Everything from here stops containers, formats a
# disk and reboots the instance; a backup that exists only on that instance is
# not a backup during any of it.
LOCAL_BACKUP_DIR="${PWD}/bwgc-backups"
mkdir -p "$LOCAL_BACKUP_DIR"
REMOTE_BACKUP=$(on_vm 'ls -t ~/bitwarden_gcloud/bitwarden/backups/*.aes256 2>/dev/null | head -1' | tr -d '\r')
if [ -n "$REMOTE_BACKUP" ]; then
	gcloud compute scp "$INSTANCE:$REMOTE_BACKUP" "$LOCAL_BACKUP_DIR/" --zone "$ZONE"
	LOCAL_COPY="$LOCAL_BACKUP_DIR/$(basename "$REMOTE_BACKUP")"
	if [ -s "$LOCAL_COPY" ]; then
		echo "backup downloaded: $LOCAL_COPY ($(du -h "$LOCAL_COPY" | cut -f1))"
		echo "Encrypted with BACKUP_ENCRYPTION_KEY. Keep that key somewhere else."
	else
		echo "The download produced nothing usable." >&2
		confirm "Continue with the backup only on the instance?"
	fi
else
	echo "Could not find the backup that was just created." >&2
	confirm "Continue with no local copy?"
fi

# Size against what the vault actually holds.
#
#   within HEADROOM of filling the default size?
#     no  -> use the default
#     yes -> is there room to expand?
#              yes -> expand, with a warning about the margin that is gone
#              no  -> stop, and offer --force
#
# The ceiling is what the free tier leaves after the boot disk, so it moves on
# its own if a COS milestone ever declares a larger minimum.
FREE_TIER_GB=30
HEADROOM_GB=3

if [ "$DISK_SIZE" = "${DEFAULT_DATA_GB}GB" ]; then
	PAYLOAD_MB=$(on_vm 'du -sm --exclude=backups ~/bitwarden_gcloud 2>/dev/null | cut -f1' | tr -d '\r')
	[ -n "$PAYLOAD_MB" ] || PAYLOAD_MB=0
	PAYLOAD_GB=$(( (PAYLOAD_MB + 1023) / 1024 ))

	BOOT_MIN=$(gcloud compute images describe-from-family cos-129-lts \
		--project cos-cloud --format="value(diskSizeGb)" 2>/dev/null || echo 10)
	[ -n "$BOOT_MIN" ] || BOOT_MIN=10
	MAX_DATA_GB=$(( FREE_TIER_GB - BOOT_MIN ))

	TARGET_GB=$DEFAULT_DATA_GB
	if [ $(( PAYLOAD_GB + HEADROOM_GB )) -ge "$TARGET_GB" ]; then
		# Within HEADROOM of the default. Room to expand?
		if [ $(( PAYLOAD_GB + HEADROOM_GB )) -le "$MAX_DATA_GB" ]; then
			TARGET_GB=$MAX_DATA_GB
			cat <<EOF

Vault is ${PAYLOAD_GB} GB, within ${HEADROOM_GB} GB of filling a ${DEFAULT_DATA_GB} GB disk.
Expanding the data disk to ${TARGET_GB} GB.

WARNING: ${TARGET_GB} GB of data plus a ${BOOT_MIN} GB boot disk is the whole
${FREE_TIER_GB} GB free tier allowance, with nothing spare. A later COS
milestone needing a larger boot disk would no longer fit, and persistent disks
cannot be shrunk -- moving to a smaller one means creating it and restoring
onto it.
EOF
			confirm "Use a ${TARGET_GB} GB data disk?"
		else
			cat >&2 <<EOF

STOPPING: vault is ${PAYLOAD_GB} GB, and no data disk both holds it and stays free.

The largest that fits alongside a ${BOOT_MIN} GB boot disk is ${MAX_DATA_GB} GB,
which leaves less than the ${HEADROOM_GB} GB of headroom this script requires.

Re-run with --force --disk-size <size> to proceed and accept the charge.
Standard persistent disk is about \$0.04 per GB per month.
EOF
			[ "$FORCE" -eq 1 ] || exit 1
			TARGET_GB=$MAX_DATA_GB
			echo "--force given: continuing at ${TARGET_GB} GB" >&2
		fi
	fi
	DISK_SIZE="${TARGET_GB}GB"
	echo "Vault is ${PAYLOAD_GB} GB; data disk will be ${DISK_SIZE} (boot ${BOOT_MIN} GB, free tier ${FREE_TIER_GB} GB)."
fi

say "Step 3/7: create and attach the data disk"
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

say "Step 4/7: format and copy the deployment"
on_vm "set -e; DEV=/dev/disk/by-id/google-$DISK_NAME; \
  if ! sudo blkid \$DEV >/dev/null 2>&1; then \
    echo 'formatting ext4'; \
    sudo mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard \$DEV; \
  else echo 'already formatted, not touching it'; fi; \
  sudo mkdir -p $MOUNT; \
  mountpoint -q $MOUNT || sudo mount -t ext4 -o discard,defaults \$DEV $MOUNT; \
  sudo chown \$(id -u):\$(id -g) $MOUNT"
# The vault is stopped for the copy, so a failure here leaves it down. Bring it
# back up at the old location and abort rather than exiting with the service
# offline.
#
# rsync runs under sudo: the containers write as root, so attachments, the RSA
# keys and Caddy's certificate store are not readable by the invoking user.
# -a preserves ownership, which vaultwarden expects to be unchanged.
if ! on_vm "$COMPOSE_SRC set -e; cd ~/bitwarden_gcloud && compose down; \
  echo 'copying deployment (excluding local backups, which are already offsite)'; \
  sudo rsync -a --delete --exclude 'bitwarden/backups/' ~/bitwarden_gcloud/ $MOUNT/bitwarden_gcloud/; \
  sudo mkdir -p $MOUNT/bitwarden_gcloud/bitwarden/backups; \
  echo '--- verifying the copy ---'; \
  for f in docker-compose.yml .env bitwarden/db.sqlite3; do \
    [ -e \"$MOUNT/bitwarden_gcloud/\$f\" ] || { echo \"MISSING: \$f\" >&2; exit 1; }; \
  done; \
  SRC_DB=\$(sudo stat -c %s ~/bitwarden_gcloud/bitwarden/db.sqlite3); \
  DST_DB=\$(sudo stat -c %s $MOUNT/bitwarden_gcloud/bitwarden/db.sqlite3); \
  [ \"\$SRC_DB\" = \"\$DST_DB\" ] || { echo \"database size differs: \$SRC_DB vs \$DST_DB\" >&2; exit 1; }; \
  SRC_N=\$(sudo find ~/bitwarden_gcloud -path '*/bitwarden/backups' -prune -o -type f -print | wc -l); \
  DST_N=\$(sudo find $MOUNT/bitwarden_gcloud -path '*/bitwarden/backups' -prune -o -type f -print | wc -l); \
  echo \"files: \$SRC_N source, \$DST_N copied\"; \
  [ \"\$DST_N\" -ge \"\$SRC_N\" ] || { echo 'fewer files on the data disk than in the source' >&2; exit 1; }; \
  sudo du -sh $MOUNT/bitwarden_gcloud"; then
	cat >&2 <<EOF

The copy failed. Restarting the vault at its original location so it is not
left offline, then stopping.

Nothing on the data disk is trusted after a partial copy. Re-running this
script starts the copy again from scratch.
EOF
	on_vm "$COMPOSE_SRC cd ~/bitwarden_gcloud && compose up -d" || \
		echo "Could not restart the vault automatically. Do it by hand: cd ~/bitwarden_gcloud && docker-compose up -d" >&2
	exit 1
fi

say "Step 5/7: record the layout in instance metadata"
BACKUP_META=$(mktemp)
gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
	--format="value(metadata.items.filter(\"key:user-data\").extract(value))" > "$BACKUP_META" 2>/dev/null || true
CC=$(mktemp)
emit_cloud_config "$DISK_NAME" "$MOUNT" "$REBOOT_TIME" > "$CC"

# On Container-Optimized OS, /etc is tmpfs. A mount written to /etc/fstab or a
# unit written to /etc/systemd/system is gone after the next reboot, so the disk
# mount and the update timer are declared in instance metadata instead, which
# cloud-init reapplies on every boot. Writing this key is how the data disk gets
# mounted at all -- without it the vault starts against an empty directory.
if [ -s "$BACKUP_META" ] && cmp -s "$BACKUP_META" "$CC"; then
	echo "user-data metadata already matches what this script would write; leaving it alone."
elif [ -s "$BACKUP_META" ]; then
	cat <<EOF

This instance already has user-data metadata. It will be replaced.

--- currently set -------------------------------------------------------
EOF
	sed 's/^/  /' "$BACKUP_META"
	cat <<EOF
--- proposed ------------------------------------------------------------
EOF
	sed 's/^/  /' "$CC"
	echo "-------------------------------------------------------------------------"
	if command -v diff >/dev/null 2>&1; then
		echo
		echo "Changes:"
		diff -u "$BACKUP_META" "$CC" | sed -n '3,$p' | sed 's/^/  /' || true
	fi
	cat <<EOF

The current value is saved to:
  $BACKUP_META

Keep a copy elsewhere if you have hand-edited it -- that path is temporary.
EOF
	confirm_default_yes "Replace the user-data metadata?"
else
	echo "No existing user-data metadata; the generated cloud-config will be set."
	echo
	sed 's/^/  /' "$CC"
fi
gcloud compute instances add-metadata "$INSTANCE" --zone "$ZONE" \
	--metadata-from-file user-data="$CC"
echo "cloud-config applied. /etc is tmpfs on COS, so this is what reapplies it every boot."
gcloud compute instances remove-metadata "$INSTANCE" --zone "$ZONE" --keys startup-script >/dev/null 2>&1 \
	&& echo "removed the legacy startup-script reboot watcher, now handled by the timer" || true

say "Step 6/7: reboot and verify the mount returns"
confirm "Reboot $INSTANCE now to prove the mount survives?"
gcloud compute instances reset "$INSTANCE" --zone "$ZONE"
echo "waiting for the instance to come back..."
# Tunable so the test harness does not wait five minutes for a mocked host.
WAIT_TRIES="${BWGC_WAIT_TRIES:-30}"
WAIT_SLEEP="${BWGC_WAIT_SLEEP:-10}"
i=0
while [ $i -lt "$WAIT_TRIES" ]; do
	[ "$WAIT_SLEEP" -gt 0 ] && sleep "$WAIT_SLEEP"
	if on_vm 'true' >/dev/null 2>&1; then break; fi
	i=$((i + 1))
done

if ! on_vm 'true' >/dev/null 2>&1; then
	cat >&2 <<EOF

$INSTANCE did not come back after the reboot.

Your vault data is on $DISK_NAME and in the backup taken in Step 2. Nothing is
lost, but the instance is not serving. Check the serial console:

    gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE | tail -40
EOF
	exit 1
fi
install_compose_helper
on_vm "$COMPOSE_SRC set -e; echo '--- mount ---'; df -h $MOUNT; \
  echo '--- timer ---'; systemctl list-timers cos-update-reboot.timer --no-pager | head -3; \
  echo '--- starting the stack from its new home ---'; \
  cd $MOUNT/bitwarden_gcloud && compose up -d; sleep 20; \
  docker ps --format '{{.Names}}\t{{.Status}}'"

say "Step 7/7: retire the old copy"

OLD_SIZE=$(on_vm "sudo du -sh ~/bitwarden_gcloud 2>/dev/null | cut -f1" | tr -d '\r')
cat <<EOF

The vault is running from $MOUNT/bitwarden_gcloud. The copy at
~/bitwarden_gcloud is now redundant and holds ${OLD_SIZE:-unknown}.

The backup taken in Step 2 was downloaded to this session:

EOF
if [ -n "${LOCAL_COPY:-}" ] && [ -s "$LOCAL_COPY" ]; then
	echo "  $LOCAL_COPY ($(du -h "$LOCAL_COPY" | cut -f1))"
else
	echo "  no local copy was downloaded earlier" >&2
	confirm "Remove the old copy anyway?"
fi

cat <<EOF

Removing ~/bitwarden_gcloud and replacing it with a symlink to the data disk,
so the familiar path keeps working:

    ~/bitwarden_gcloud -> $MOUNT/bitwarden_gcloud

EOF
confirm_default_yes "Remove the old copy and create the symlink?"
on_vm "set -e; rm -rf ~/bitwarden_gcloud; ln -s $MOUNT/bitwarden_gcloud ~/bitwarden_gcloud; ls -ld ~/bitwarden_gcloud"

# Anything else left over is reported rather than removed. It is not this
# script's to delete.
STRAY=$(on_vm "for d in ~/data ~/refresh-safety; do [ -e \"\$d\" ] && printf '  %s  %s\n' \"\$(sudo du -sh \$d 2>/dev/null | cut -f1)\" \"\$d\"; done" | tr -d '\r')
if [ -n "$STRAY" ]; then
	cat <<EOF

Other directories are still in the home directory. This script did not create
them and will not remove them:

$STRAY

~/data is usually a relic of an earlier data-disk attempt. Check before deleting.
EOF
fi

say "Done"
cat <<EOF
  The vault runs from $MOUNT/bitwarden_gcloud on disk $DISK_NAME, and
  ~/bitwarden_gcloud points at it.

  Check it yourself:

      gcloud compute ssh $INSTANCE --zone $ZONE

  then, on the instance:

      df -h $MOUNT
      cd ~/bitwarden_gcloud && docker-compose ps
      curl -sI https://\$(grep '^DOMAIN=' .env | cut -d= -f2 | tr -d '"'"'"'"') /api/version | head -1

  Log in from a real client before treating this as finished.

  Next, upgrade the OS milestone:  ./upgrade-cos.sh --instance $INSTANCE --zone $ZONE
EOF
