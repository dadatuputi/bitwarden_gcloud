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

DISK_NAME=
DISK_NAME_DEFAULT=bwgc-data
MOUNT=/mnt/disks/bwgc
BOOT_SIZE=10GB
MACHINE_TYPE=e2-micro
BOOT_DISK_NAME=
REBOOT_TIME=06:00
INSTANCE=
NEW_INSTANCE=
ZONE=
IMAGE_FAMILY=
ASSUME_YES=0
RESERVE_IP=1
KEEP_OLD=0
DELETE_FIRST=1

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
  --boot-disk-device-name NAME
                       device name the guest sees for the boot disk (default:
                       the instance name). This is not the disk resource name,
                       which Compute Engine derives from the instance name.
  --reboot-time HH:MM  update reboot window (default: $REBOOT_TIME)
  --keep-old           leave the old instance stopped and never delete it.
                       Implies --overlap. Costs free tier allowance until you
                       remove it by hand.
  --delete-first       destroy the old instance before building the new one so
                       the two never coexist. THIS IS THE DEFAULT.
  --overlap            keep the old instance until the new one verifies. Only
                       possible when boot+boot+data fits in 30 GB, i.e. a data
                       disk of 10 GB or less. Also draws down the e2-micro
                       allowance twice over while both run.
  --no-reserve-ip      do not reserve an ephemeral external IP before deleting
                       the old instance. The replacement then comes up on a
                       different address and DNS pointing at the old one goes
                       stale.
  --yes                do not prompt

Free tier: 30 GB of pd-standard, and the boot disk holds nothing unique -- the
OS is read-only and Docker images re-pull for free. Deleting it first means only
one boot disk ever exists, so the data disk gets the rest:

    boot   whatever the image declares it needs (10 GB since 2019)
    data   15 GB, set by migrate-to-data-disk.sh

Deleting the old instance first means only one boot disk exists at a time, so
25 GB of the 30 GB allowance is in use with 5 GB spare. If a future milestone
ever needs more than 15 GB the script stops and asks.
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
	--boot-disk-device-name) BOOT_DISK_NAME="$2"; shift 2 ;;
	--reboot-time) REBOOT_TIME="$2"; shift 2 ;;
	--keep-old) KEEP_OLD=1; DELETE_FIRST=0; shift ;;
	--delete-first) DELETE_FIRST=1; shift ;;
	--overlap) DELETE_FIRST=0; shift ;;
	--no-reserve-ip) RESERVE_IP=0; shift ;;
	--yes) ASSUME_YES=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

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
# Sourced, not executed: /home is noexec. Defines compose and docker-compose.
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$(pwd -P):$(pwd -P)" -w="$(pwd -P)" \
      -e COMPOSE_DOCKER_CLI_BUILD=1 \
      -e DOCKER_BUILDKIT=1 \
      --entrypoint docker docker:cli compose "$@"
  fi
}
docker-compose() { compose "$@"; }
BWGCEOF
}
install_compose_helper() {
	compose_helper_body | gcloud compute ssh "$1" --zone "$ZONE" \
		--command "cat > $COMPOSE_HELPER" >/dev/null
}

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

# The boot disk is whatever the image declares it needs. Google has said 10 GB
# for every COS milestone since 2019.
#
# The data disk is 15 GB, and the free tier covers 30 GB of pd-standard in
# total, so a boot disk above 15 GB no longer fits alongside it. That has never
# happened; if it does, stop rather than silently start billing.
DATA_DISK_GB=15
IMAGE_MIN=$(gcloud compute images describe-from-family "$IMAGE_FAMILY" \
	--project cos-cloud --format="value(diskSizeGb)" 2>/dev/null || true)

if [ -n "$IMAGE_MIN" ]; then
	if [ "$IMAGE_MIN" -gt "$DATA_DISK_GB" ]; then
		cat >&2 <<EOF

STOPPING: $IMAGE_FAMILY requires a ${IMAGE_MIN}GB boot disk.

The data disk is ${DATA_DISK_GB}GB and the free tier covers 30GB of pd-standard
in total, so a ${IMAGE_MIN}GB boot disk alongside it would bill.

This needs a decision rather than a default. Either accept the charge:

    $0 --instance $INSTANCE --zone $ZONE --boot-size ${IMAGE_MIN}GB

or shrink the data disk first. Disks cannot be shrunk in place, so that means
creating a smaller one and restoring the vault onto it.
EOF
		exit 1
	fi
	REQUESTED=$(printf '%s' "$BOOT_SIZE" | sed 's/[^0-9]//g')
	if [ -n "$REQUESTED" ] && [ "$REQUESTED" -lt "$IMAGE_MIN" ]; then
		echo "$IMAGE_FAMILY requires at least ${IMAGE_MIN}GB; raising boot disk to ${IMAGE_MIN}GB" >&2
		BOOT_SIZE="${IMAGE_MIN}GB"
	fi
fi

[ -n "$NEW_INSTANCE" ] || NEW_INSTANCE="${INSTANCE}-${MILESTONE}"

CURRENT=$(on_vm "$INSTANCE" 'grep -h ^VERSION= /etc/os-release | cut -d= -f2' 2>/dev/null | tr -d '\r' || echo unknown)

# Read the data disk off the instance rather than assuming the default name.
# The migration accepts --disk-name, so a user who used it arrives here with a
# disk this script would otherwise fail to find -- after it has already stopped
# the stack and the instance. Worse, in a project that happens to hold a disk
# called bwgc-data in this zone, the default would have detached the wrong one
# and the plan would have read as though that were intended.
if [ -z "$DISK_NAME" ]; then
	DISK_NAME=$(gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
		--format="value(disks[].deviceName)" 2>/dev/null \
		| tr ';' '\n' | tr '\t' '\n' | grep -v '^$' | tail -n +2 | head -1 || true)
	if [ -n "$DISK_NAME" ]; then
		echo "data disk read from $INSTANCE: $DISK_NAME"
	else
		DISK_NAME=$DISK_NAME_DEFAULT
		echo "could not read a data disk from $INSTANCE; assuming $DISK_NAME"
	fi
fi

# Fail before anything is stopped, not after.
if ! gcloud compute disks describe "$DISK_NAME" --zone "$ZONE" >/dev/null 2>&1; then
	cat >&2 <<EOF

No disk named $DISK_NAME in $ZONE.

This script needs the data disk the migration created. Pass it explicitly:

    ./upgrade-cos.sh --instance $INSTANCE --zone $ZONE --disk-name NAME

The disks attached to $INSTANCE are:

$(gcloud compute instances describe "$INSTANCE" --zone "$ZONE" --format="value(disks[].deviceName)" 2>/dev/null | tr ';' '\n' | sed 's/^/    /')

Nothing has been changed.
EOF
	exit 1
fi

say "Plan"
cat <<EOF
  from        $INSTANCE   (COS milestone $CURRENT)
  to          $NEW_INSTANCE  ($IMAGE_FAMILY, ${BOOT_SIZE} pd-standard)
  data disk   $DISK_NAME  ->  $MOUNT
  zone        $ZONE

EOF
if [ "$DELETE_FIRST" -eq 1 ]; then
	echo "  $INSTANCE and its boot disk are DELETED before the replacement is built."
	echo "  $DISK_NAME is detached first and keeps your vault. There is no way back"
	echo "  to the old milestone afterwards."
else
	echo "  $INSTANCE is stopped, not deleted. Rollback is starting it again."
fi
[ "$CURRENT" = "$MILESTONE" ] && echo "  NOTE: already on milestone $MILESTONE."
confirm "Proceed?"

install_compose_helper "$INSTANCE"

say "Step 1/6: back up and verify before touching anything"
on_vm "$INSTANCE" "cd $MOUNT/bitwarden_gcloud && docker exec backup ash /backup.sh local"
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

# Everything the replacement needs that is not implied by the image or the
# disks. Deleting the old instance destroys all of it, so it is captured first
# and a full copy is saved locally as the record of what was there.
INSTANCE_SNAPSHOT="$LOCAL_BACKUP_DIR/instance-$INSTANCE.json"
gcloud compute instances describe "$INSTANCE" --zone "$ZONE" --format=json \
	> "$INSTANCE_SNAPSHOT" 2>/dev/null || true
[ -s "$INSTANCE_SNAPSHOT" ] && echo "instance configuration saved to $INSTANCE_SNAPSHOT"

_field() {
	gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
		--format="value($1)" 2>/dev/null | tr -d ' ' | tr ';' ',' || true
}

# gcloud's .list() joins with semicolons; --tags, --scopes and --labels take
# commas.
OLD_TAGS=$(_field "tags.items.list()")
OLD_SCOPES=$(_field "serviceAccounts[0].scopes.list()")
OLD_SA=$(_field "serviceAccounts[0].email")
OLD_LABELS=$(_field "labels.list()")
OLD_MACHINE=$(_field "machineType.basename()")
OLD_NETWORK=$(_field "networkInterfaces[0].network.basename()")
OLD_SUBNET=$(_field "networkInterfaces[0].subnetwork.basename()")
OLD_NATIP=$(_field "networkInterfaces[0].accessConfigs[0].natIP")

# The machine type is not hardcoded: an instance that was resized would
# otherwise be silently put back to e2-micro.
if [ -n "$OLD_MACHINE" ] && [ "$OLD_MACHINE" != "$MACHINE_TYPE" ]; then
	echo "keeping the current machine type: $OLD_MACHINE"
	MACHINE_TYPE=$OLD_MACHINE
fi

echo "carrying over:"
echo "  machine type     ${MACHINE_TYPE}"
echo "  tags             ${OLD_TAGS:-none}"
echo "  scopes           ${OLD_SCOPES:-default}"
echo "  service account  ${OLD_SA:-default}"
echo "  labels           ${OLD_LABELS:-none}"
echo "  network          ${OLD_NETWORK:-default}/${OLD_SUBNET:-default}"

if [ -z "$OLD_TAGS" ]; then
	echo "" >&2
	echo "WARNING: this instance has no network tags. The firewall rules this" >&2
	echo "project creates target http-server and https-server, so a replacement" >&2
	echo "without them serves only on localhost." >&2
	confirm "Continue with no network tags?"
fi

# A reserved address survives instance deletion; an ephemeral one does not.
if [ -n "$OLD_NATIP" ]; then
	IP_KIND=$(gcloud compute addresses list --filter="address=$OLD_NATIP" \
		--format="value(name)" 2>/dev/null | head -1 || true)
	if [ -n "$IP_KIND" ]; then
		echo "  external IP      $OLD_NATIP (reserved as '$IP_KIND', will be reattachable)"
		RESERVED_IP=$IP_KIND
	elif [ "$RESERVE_IP" -eq 1 ]; then
		# Promoting an in-use ephemeral address converts it in place: the running
		# instance keeps serving, and the address now survives the delete. An
		# attached static address is billed the same as an ephemeral one.
		REGION=${ZONE%-*}
		PROMOTED_IP_NAME="${INSTANCE}-ip"
		if gcloud compute addresses create "$PROMOTED_IP_NAME" \
			--addresses "$OLD_NATIP" --region "$REGION" >/dev/null 2>&1; then
			echo "  external IP      $OLD_NATIP (was ephemeral, now reserved as '$PROMOTED_IP_NAME')"
			RESERVED_IP=$PROMOTED_IP_NAME
		else
			echo "" >&2
			echo "WARNING: $OLD_NATIP could not be reserved, so it is released when" >&2
			echo "this instance is deleted and the replacement comes up on a different" >&2
			echo "address. Any DNS record pointing here goes stale until you update it." >&2
			confirm "Continue and let the external IP change?"
		fi
	else
		echo "" >&2
		echo "NOTE: $OLD_NATIP is ephemeral and --no-reserve-ip was given, so it is" >&2
		echo "released when this instance is deleted. The replacement gets a different" >&2
		echo "address and any DNS record pointing here goes stale." >&2
	fi
fi

say "Step 2/6: stop the stack and release the data disk"
# cd out of the mount before unmounting it: a shell cannot unmount the
# filesystem it is standing in. Docker also keeps the directory referenced
# briefly after containers are removed, so retry rather than failing on the
# first attempt, and say what is holding it if it never releases.
on_vm "$INSTANCE" "$COMPOSE_SRC set -e; cd $MOUNT/bitwarden_gcloud && compose down; cd /; \
  for i in 1 2 3 4 5 6; do \
    if sudo umount $MOUNT 2>/dev/null; then echo UNMOUNTED; exit 0; fi; \
    sleep 5; \
  done; \
  echo 'could not unmount $MOUNT after 30 seconds' >&2; \
  sudo lsof +f -- $MOUNT 2>/dev/null | head -10 >&2 || true; \
  ls -l /proc/*/cwd 2>/dev/null | grep $MOUNT >&2 || true; \
  exit 1"
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
	--machine-type "$MACHINE_TYPE" \
	--image-family "$IMAGE_FAMILY" \
	--image-project cos-cloud \
	--boot-disk-size "$BOOT_SIZE" \
	--boot-disk-type pd-standard \
	--boot-disk-device-name "${BOOT_DISK_NAME:-$NEW_INSTANCE}" \
	--disk "name=$DISK_NAME,device-name=$DISK_NAME,mode=rw,boot=no" \
	--metadata-from-file user-data="$CC" \
	${OLD_TAGS:+--tags "$OLD_TAGS"} \
	${OLD_SCOPES:+--scopes "$OLD_SCOPES"} \
	${OLD_SA:+--service-account "$OLD_SA"} \
	${OLD_LABELS:+--labels "$OLD_LABELS"} \
	${OLD_NETWORK:+--network "$OLD_NETWORK"} \
	${OLD_SUBNET:+--subnet "$OLD_SUBNET"} \
	${RESERVED_IP:+--address "$RESERVED_IP"}

say "Step 4/6: waiting for the new instance"
# Tunable so the test harness does not wait five minutes for a mocked host.
WAIT_TRIES="${BWGC_WAIT_TRIES:-30}"
WAIT_SLEEP="${BWGC_WAIT_SLEEP:-10}"
i=0
while [ $i -lt "$WAIT_TRIES" ]; do
	[ "$WAIT_SLEEP" -gt 0 ] && sleep "$WAIT_SLEEP"
	if on_vm "$NEW_INSTANCE" 'true' >/dev/null 2>&1; then break; fi
	i=$((i + 1))
done
# SSH answers before cloud-init has finished. The data disk mount is done by a
# bootcmd, so a reachable instance is not yet a ready one -- checking too early
# reports "No such file or directory" for a disk that mounts a few seconds
# later.
if on_vm "$NEW_INSTANCE" "true" >/dev/null 2>&1; then
	printf 'waiting for cloud-init to mount %s' "$MOUNT"
	m=0
	while [ $m -lt "${BWGC_MOUNT_TRIES:-30}" ]; do
		if on_vm "$NEW_INSTANCE" "mountpoint -q $MOUNT" >/dev/null 2>&1; then
			printf ' mounted\n'
			break
		fi
		printf '.'
		[ "${BWGC_WAIT_SLEEP:-10}" -gt 0 ] && sleep "${BWGC_WAIT_SLEEP:-10}"
		m=$((m + 1))
	done
	if ! on_vm "$NEW_INSTANCE" "mountpoint -q $MOUNT" >/dev/null 2>&1; then
		cat >&2 <<EOF

$MOUNT never mounted on $NEW_INSTANCE.

The data disk is attached but cloud-init did not mount it. Your vault data is
intact on $DISK_NAME. Check what cloud-init did:

    gcloud compute ssh $NEW_INSTANCE --zone $ZONE --command 'sudo cloud-init status --long; ls -l /dev/disk/by-id/google-$DISK_NAME'
EOF
		exit 1
	fi
fi

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

# cloud-init mounts the disk in bootcmd but starts the stack and enables the
# timers later, in runcmd. Waiting only for the mount means arriving while that
# is still in flight: the timer listing comes back empty and compose races
# bwgc.service for the container names.
on_vm "$NEW_INSTANCE" 'sudo cloud-init status --wait >/dev/null 2>&1; :'

say "Step 5/6: bring the vault up on the new milestone"
on_vm "$NEW_INSTANCE" "set -e; \
  echo '--- milestone ---'; grep -E '^(VERSION|BUILD_ID)=' /etc/os-release; \
  echo '--- docker ---'; docker --version; \
  echo '--- boot disk split ---'; lsblk -o NAME,SIZE,TYPE | head -4; \
  echo '--- data disk ---'; df -h $MOUNT; \
  echo '--- reinstating the shell setup ---'; \
  cd $MOUNT/bitwarden_gcloud && ./utilities/install-alias.sh; \
  ln -sfn $MOUNT/bitwarden_gcloud ~/bitwarden_gcloud; \
  ls -ld ~/bitwarden_gcloud"
  # bwgc.service owns starting the stack. This script must not also run compose:
  # an "is it active yet" check is a point-in-time sample, and on a real run both
  # sides created a network called bitwarden_gcloud_default one millisecond
  # apart, after which every container start failed with "network ... is
  # ambiguous (2 matches found on name)". Wait for the unit instead.
  printf 'waiting for bwgc.service to start the stack'
  k=0
  STACK_STATE=
  while [ $k -lt "${BWGC_STACK_TRIES:-30}" ]; do
  	STACK_STATE=$(on_vm "$NEW_INSTANCE" 'systemctl is-active bwgc.service 2>/dev/null' 2>/dev/null | tr -d '\r')
  	case "$STACK_STATE" in
  	active) printf ' started\n'; break ;;
  	failed) printf ' failed\n'; break ;;
  	esac
  	printf '.'
  	[ "${BWGC_WAIT_SLEEP:-10}" -gt 0 ] && sleep "${BWGC_WAIT_SLEEP:-10}"
  	k=$((k + 1))
  done
  if [ "$STACK_STATE" != active ]; then
  	echo "bwgc.service did not start the stack (state: ${STACK_STATE:-unknown})." >&2
  	echo "Your vault is on $DISK_NAME. Check: gcloud compute ssh $NEW_INSTANCE --zone $ZONE --command 'sudo journalctl -u bwgc.service -b --no-pager'" >&2
  	exit 1
  fi
  install_compose_helper "$NEW_INSTANCE"
  on_vm "$NEW_INSTANCE" "docker ps --format '{{.Names}}\t{{.Status}}'"

say "Step 6/6: verify"
DOMAIN=$(on_vm "$NEW_INSTANCE" "grep -E '^DOMAIN=' $MOUNT/bitwarden_gcloud/.env | cut -d= -f2 | tr -d '\"'" 2>/dev/null | tr -d '\r' || true)
on_vm "$NEW_INSTANCE" "set +e; \
  echo '--- jails ---'; docker exec fail2ban fail2ban-client status 2>&1 | tail -2; \
  echo '--- update timer ---'; systemctl list-timers cos-update-reboot.timer --no-pager | head -3; \
  [ -n '$DOMAIN' ] && { echo '--- vault ---'; curl -sI --max-time 20 https://$DOMAIN/api/version | head -1; \
    curl -sI --max-time 20 https://$DOMAIN/admin | grep -i x-frame-options; }; \
    true"

# The external check above is informational: DNS may not point here yet, or may
# point through a proxy. Its result must not become the exit status of an
# upgrade that otherwise succeeded, which is why that remote command ends in
# "true".
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
