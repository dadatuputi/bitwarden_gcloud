#!/usr/bin/env sh
#
# End-to-end test of migrate-to-data-disk.sh and upgrade-cos.sh on a real
# Container-Optimized OS instance. Everything in tests/cases runs the scripts
# against a mock gcloud and proves what they say; this proves what COS does
# with it: the disk mounts at boot, the stack comes up from the mounted path
# and not from the phantom containers docker starts first, the data survives
# a reboot and a milestone upgrade.
#
#   tests/e2e/gce-smoke.sh --project P --zone Z [options]
#
# Builds a deployment the way instances looked before the data disk existed
# (repository in the home directory, no user-data, containers restarted by the
# daemon), seeds it, then runs the two scripts from this checkout against it.
# Every resource carries the label bwgc-e2e=<id> and is deleted at the end,
# whatever happened, unless --keep is given.
#
# Needs gcloud authenticated against a project that holds nothing else. Costs
# about a cent per run; a run that is killed leaves an e2-micro behind, which
# --sweep removes.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
PROJECT=
ZONE=
ID=
LEGACY_FAMILY=
TARGET_FAMILY=
REF=master
KEEP=0
MODE=run

usage() {
	cat <<EOF
Usage: $0 --project PROJECT --zone ZONE [options]
  --project ID        GCP project that holds nothing but this test (required)
  --zone ZONE         e.g. us-central1-a (required)
  --id ID             name suffix for every resource (default: a timestamp)
  --legacy-family F   COS family for the instance being migrated
                      (default: the second-newest live cos-*-lts)
  --target-family F   COS family the upgrade moves to
                      (default: the newest live cos-*-lts)
  --ref REF           git ref the instance clones (default: master). The
                      scripts under test always come from this checkout.
  --keep              leave the resources up for inspection
  --cleanup-only      delete this --id's resources and exit
  --sweep             delete every bwgc-e2e resource older than three hours
EOF
}
while [ $# -gt 0 ]; do
	case "$1" in
	--project) PROJECT="$2"; shift 2 ;;
	--zone) ZONE="$2"; shift 2 ;;
	--id) ID="$2"; shift 2 ;;
	--legacy-family) LEGACY_FAMILY="$2"; shift 2 ;;
	--target-family) TARGET_FAMILY="$2"; shift 2 ;;
	--ref) REF="$2"; shift 2 ;;
	--keep) KEEP=1; shift ;;
	--cleanup-only) MODE=cleanup; shift ;;
	--sweep) MODE=sweep; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
[ -n "$PROJECT" ] && [ -n "$ZONE" ] || { usage >&2; exit 2; }
command -v gcloud >/dev/null 2>&1 || { echo "gcloud not found" >&2; exit 1; }
export CLOUDSDK_CORE_PROJECT="$PROJECT"
# Never prompt: key generation, host keys, confirmations.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
REGION=${ZONE%-*}

# ---------------------------------------------------------------------------
# Reporting. Same shape as tests/lib-assert.sh, kept local so this file runs
# on its own from any directory.
TESTS_RUN=0
TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2" "${3:-}"; fi; }
expect() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi; }
# A step the rest of the run depends on: reported either way, and a failure
# ends the run (the EXIT trap still cleans up).
must() { desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; exit 1; fi; }
say() { printf '\n=== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Resources. The sweep and the cleanup work from the label, so a run that
# died before naming everything still gets tidied.
label_filter() { printf 'labels.bwgc-e2e=%s' "$1"; }

cleanup_id() {
	say "Cleaning up bwgc-e2e=$1"
	for inst in $(gcloud compute instances list --filter="$(label_filter "$1")" --format='value(name)' 2>/dev/null); do
		echo "deleting instance $inst"
		gcloud compute instances delete "$inst" --zone "$ZONE" --quiet >/dev/null 2>&1 || echo "  (already gone)"
	done
	for disk in $(gcloud compute disks list --filter="$(label_filter "$1") OR name~^bwgc-e2e-$1" --format='value(name)' 2>/dev/null); do
		echo "deleting disk $disk"
		gcloud compute disks delete "$disk" --zone "$ZONE" --quiet >/dev/null 2>&1 || echo "  (already gone)"
	done
	for addr in $(gcloud compute addresses list --filter="name~^bwgc-e2e-$1" --format='value(name)' 2>/dev/null); do
		echo "deleting address $addr"
		gcloud compute addresses delete "$addr" --region "$REGION" --quiet >/dev/null 2>&1 || echo "  (already gone)"
	done
}

sweep() {
	say "Sweeping bwgc-e2e resources older than three hours"
	cutoff=$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-3H +%Y-%m-%dT%H:%M:%S)
	ids=$(
		gcloud compute instances list --filter="labels.bwgc-e2e:* AND creationTimestamp<$cutoff" --format='value(labels.bwgc-e2e)' 2>/dev/null
		gcloud compute disks list --filter="labels.bwgc-e2e:* AND creationTimestamp<$cutoff" --format='value(labels.bwgc-e2e)' 2>/dev/null
	)
	# Disks the migration script creates carry no label, only the name.
	old_disks=$(gcloud compute disks list --filter="name~^bwgc-e2e- AND creationTimestamp<$cutoff" --format='value(name)' 2>/dev/null)
	for d in $old_disks; do ids="$ids
$(printf '%s' "$d" | sed -E 's/^bwgc-e2e-([^-]+)-.*/\1/')"; done
	ids=$(printf '%s\n' "$ids" | grep -v '^$' | sort -u)
	if [ -z "$ids" ]; then echo "nothing to sweep"; return 0; fi
	for id in $ids; do cleanup_id "$id"; done
}

case "$MODE" in
cleanup) [ -n "$ID" ] || { echo "--cleanup-only needs --id" >&2; exit 2; }; cleanup_id "$ID"; exit 0 ;;
sweep) sweep; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Names. IDs are kept short and lowercase: they end up in instance names.
[ -n "$ID" ] || ID=$(date -u +%m%d%H%M)
ID=$(printf '%s' "$ID" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')
BASE="bwgc-e2e-$ID"
INSTANCE="$BASE-vault"
NEW_INSTANCE="$BASE-up"
DISK="$BASE-data"
MOUNT=/mnt/disks/bwgc
WORK=$(mktemp -d)
LABELS="bwgc-e2e=$ID"

finish() {
	status=$?
	if [ "$KEEP" -eq 1 ]; then
		echo
		echo "--keep: leaving $INSTANCE / $NEW_INSTANCE / $DISK in $PROJECT ($ZONE)."
		echo "Remove them with: $0 --project $PROJECT --zone $ZONE --cleanup-only --id $ID"
	else
		cleanup_id "$ID"
	fi
	rm -rf "$WORK"
	printf '\nran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [ "$TESTS_FAILED" -ne 0 ]; then exit 1; fi
	exit "$status"
}
trap finish EXIT

on() { gcloud compute ssh "$1" --zone "$ZONE" --command "$2"; }
on_q() { gcloud compute ssh "$1" --zone "$ZONE" --command "$2" 2>/dev/null | tr -d '\r'; }

# BWGC_WAIT_SLEEP is the same knob the maintenance scripts honour, so a run
# against a mock gcloud does not wait on anything.
SLEEP=${BWGC_WAIT_SLEEP:-10}
wait_for() { # wait_for <what> <tries> <command...>
	what=$1; tries=$2; shift 2
	printf 'waiting for %s' "$what"
	i=0
	while [ $i -lt "$tries" ]; do
		if "$@" >/dev/null 2>&1; then printf ' ok\n'; return 0; fi
		printf '.'; sleep "$SLEEP"; i=$((i + 1))
	done
	printf ' timed out\n'
	return 1
}
ssh_ok() { on "$1" true >/dev/null 2>&1; }
vault_alive() { on "$1" 'docker exec backup curl -sf -o /dev/null http://bitwarden:80/alive' >/dev/null 2>&1; }
stack_active() { [ "$(on_q "$1" 'systemctl is-active bwgc.service')" = active ]; }

# ---------------------------------------------------------------------------
# What the instance should look like once the stack runs from the data disk.
# Called after the migration, after a further reboot, and after the upgrade.
verify_on_disk() { # verify_on_disk <instance> <phase>
	inst=$1; phase=$2
	say "Verifying $inst ($phase)"
	out=$(on_q "$inst" "mountpoint -q $MOUNT && echo mounted")
	expect "$out" mounted "$phase: $MOUNT is mounted"

	out=$(on_q "$inst" "findmnt -n -o SOURCE $MOUNT")
	case "$out" in /dev/*) is_dev=yes ;; *) is_dev=no ;; esac
	expect "$is_dev" yes "$phase: the mount is a block device ($out)"

	out=$(on_q "$inst" 'systemctl is-active bwgc.service')
	expect "$out" active "$phase: bwgc.service is active"
	out=$(on_q "$inst" 'systemctl is-active bwgc-supervise.timer')
	expect "$out" active "$phase: bwgc-supervise.timer is active"
	out=$(on_q "$inst" 'systemctl is-active cos-update-reboot.timer')
	expect "$out" active "$phase: cos-update-reboot.timer is active"

	# The containers that are running must be the ones bwgc.service created
	# against the mounted disk, not the ones the daemon started against an
	# empty directory on the boot disk before the mount existed.
	out=$(on_q "$inst" "docker inspect bitwarden --format '{{range .Mounts}}{{.Source}} {{end}}'")
	case "$out" in *"$MOUNT/bitwarden_gcloud/bitwarden"*) on_disk=yes ;; *) on_disk=no ;; esac
	expect "$on_disk" yes "$phase: vaultwarden's data mount is on the data disk ($out)"
	case "$out" in */home/*) from_home=yes ;; *) from_home=no ;; esac
	expect "$from_home" no "$phase: vaultwarden mounts nothing from the home directory"

	svc=$(on_q "$inst" "date -d \"\$(systemctl show bwgc.service -p InactiveExitTimestamp --value)\" +%s")
	ctr=$(on_q "$inst" "date -d \"\$(docker inspect bitwarden --format '{{.State.StartedAt}}')\" +%s")
	if [ -n "$svc" ] && [ -n "$ctr" ] && [ "$ctr" -ge "$svc" ]; then started_after=yes; else started_after=no; fi
	expect "$started_after" yes "$phase: the running vault was started by bwgc.service, not before it (service $svc, container $ctr)"

	out=$(on_q "$inst" 'docker exec backup curl -s -o /dev/null -w "%{http_code}" http://bitwarden:80/alive')
	expect "$out" 200 "$phase: the vault answers /alive"

	out=$(on_q "$inst" 'docker exec backup sqlite3 /data/db.sqlite3 "select email from users"')
	expect "$out" "$SEED_EMAIL" "$phase: the seeded account is in the vault the containers see"

	out=$(on_q "$inst" "sudo cat $MOUNT/bitwarden_gcloud/bitwarden/attachments/e2e-marker 2>/dev/null")
	expect "$out" "$ID" "$phase: the marker file is on the data disk"

	out=$(on_q "$inst" "sudo grep -c '^BWGC_RESTART_POLICY=no' $MOUNT/bitwarden_gcloud/.env")
	expect "$out" 1 "$phase: .env keeps the daemon from starting the stack at boot"

	out=$(on_q "$inst" 'sudo journalctl -u bwgc.service -b --no-pager | grep -cE "refusing|no deployment|not mounted"')
	expect "${out:-0}" 0 "$phase: bwgc.service logged no refusal this boot"
}

# ---------------------------------------------------------------------------
say "Resolving COS families"
live=""
for m in 165 161 157 153 149 145 141 137 133 129 125 121 117; do
	# In this zone: a family's images roll out zone by zone, and instances are
	# created from the zone's view of the family.
	if gcloud compute images describe-from-family "cos-$m-lts" --project cos-cloud --zone "$ZONE" --format='value(name)' >/dev/null 2>&1; then
		live="$live cos-$m-lts"
	fi
done
set -- $live
[ $# -ge 2 ] || { echo "need two live cos-*-lts families, found: $live" >&2; exit 1; }
[ -n "$TARGET_FAMILY" ] || TARGET_FAMILY=$1
[ -n "$LEGACY_FAMILY" ] || LEGACY_FAMILY=$2
echo "legacy instance: $LEGACY_FAMILY -> upgrade to: $TARGET_FAMILY"
echo "resources: $INSTANCE, $NEW_INSTANCE, $DISK in $PROJECT/$ZONE, label $LABELS"

say "Step 1: build a pre-data-disk deployment"
# No data disk, no user-data: the repository in the home directory and the
# daemon restarting containers, as every instance looked before the disk
# layout existed. enable-oslogin=false so the ssh user is the local one and
# is in google-sudoers.
create_legacy() {
	gcloud compute instances create "$INSTANCE" \
		--zone "$ZONE" --machine-type e2-micro \
		--image-family "$LEGACY_FAMILY" --image-project cos-cloud \
		--boot-disk-size 10GB --boot-disk-type pd-standard \
		--labels "$LABELS" --metadata enable-oslogin=false \
		--scopes compute-ro >/dev/null
}
must "instance $INSTANCE created from $LEGACY_FAMILY" create_legacy
wait_for "ssh on $INSTANCE" 30 ssh_ok "$INSTANCE" || exit 1

on "$INSTANCE" "set -e; \
  git clone -q https://github.com/dadatuputi/bitwarden_gcloud ~/bitwarden_gcloud; \
  cd ~/bitwarden_gcloud; \
  git checkout -q '$REF' 2>/dev/null || echo 'ref $REF not on upstream, staying on master'; \
  mkdir -p tests/e2e" >/dev/null
# The overlay from this checkout, whatever the instance cloned.
gcloud compute scp "$ROOT/tests/e2e/docker-compose.e2e.yml" "$INSTANCE:~/bitwarden_gcloud/tests/e2e/" --zone "$ZONE" >/dev/null
SEED_EMAIL="e2e-$ID@example.test"
start_legacy() {
	on "$INSTANCE" "set -e; cd ~/bitwarden_gcloud; \
  cp .env.template .env; \
  printf '\n# e2e\nDOMAIN=vault-$ID.e2e.invalid\nEMAIL=e2e@example.test\nBACKUP=local\nSIGNUPS_ALLOWED=true\nCOMPOSE_FILE=docker-compose.yml:tests/e2e/docker-compose.e2e.yml\n' >> .env; \
  sh utilities/install-alias.sh >/dev/null; \
  . ~/.bwgc-compose.sh; docker-compose up -d 2>&1 | tail -3"
}
must "legacy stack started from the home directory" start_legacy
wait_for "the vault" 30 vault_alive "$INSTANCE" || exit 1

say "Step 2: seed the vault"
# An account through the API, so the database holds something that would be
# missing from a fresh, empty vault, and a file among the attachments. The
# route is the one current vaultwarden serves; /api/accounts/register is gone.
out=$(on_q "$INSTANCE" "docker exec backup curl -s -o /dev/null -w '%{http_code}' -X POST http://bitwarden:80/identity/accounts/register \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"e2e\",\"email\":\"$SEED_EMAIL\",\"masterPasswordHash\":\"e2e-fixture-not-a-real-hash-0000000000000000\",\"key\":\"2.e2e-fixture|e2e-fixture|e2e-fixture\",\"kdf\":0,\"kdfIterations\":600000}'")
expect "$out" 200 "an account is registered through the API (HTTP status)"
out=$(on_q "$INSTANCE" 'docker exec backup sqlite3 /data/db.sqlite3 "select email from users"')
expect "$out" "$SEED_EMAIL" "the account is in the database"
write_marker() { on "$INSTANCE" "sudo mkdir -p ~/bitwarden_gcloud/bitwarden/attachments && printf '%s' '$ID' | sudo tee ~/bitwarden_gcloud/bitwarden/attachments/e2e-marker >/dev/null"; }
must "a marker file is written among the attachments" write_marker

say "Step 3: migrate-to-data-disk.sh"
# From a scratch directory: the script downloads the backup it takes beside
# wherever it runs.
run_migrate() {
	( cd "$WORK" && "$ROOT/utilities/migrate-to-data-disk.sh" \
		--instance "$INSTANCE" --zone "$ZONE" --disk-name "$DISK" --yes )
}
must "migrate-to-data-disk.sh exits 0" run_migrate
gcloud compute disks add-labels "$DISK" --zone "$ZONE" --labels "$LABELS" >/dev/null 2>&1 || true
if ls "$WORK"/bwgc-backups/bw_backup_* >/dev/null 2>&1; then got_backup=yes; else got_backup=no; fi
expect "$got_backup" yes "the migration downloaded a backup"
verify_on_disk "$INSTANCE" "after migration"

say "Step 4: reboot and start again from the data disk"
# The migration rebooted once and verified the mount. This is the boot every
# later reboot looks like: the daemon starts containers against an empty
# path first, and bwgc.service must replace them.
boot=$(on_q "$INSTANCE" 'cat /proc/sys/kernel/random/boot_id')
on "$INSTANCE" 'sync; sudo systemctl reboot' >/dev/null 2>&1 || true
sleep $((SLEEP * 2))
rebooted() { [ "$(on_q "$INSTANCE" 'cat /proc/sys/kernel/random/boot_id')" != "$boot" ]; }
wait_for "the reboot" 30 rebooted || exit 1
wait_for "bwgc.service" 30 stack_active "$INSTANCE" || exit 1
wait_for "the vault" 30 vault_alive "$INSTANCE" || exit 1
verify_on_disk "$INSTANCE" "after reboot"

say "Step 5: upgrade-cos.sh to $TARGET_FAMILY"
run_upgrade() {
	( cd "$WORK" && "$ROOT/utilities/upgrade-cos.sh" \
		--instance "$INSTANCE" --zone "$ZONE" --disk-name "$DISK" \
		--new-instance "$NEW_INSTANCE" --image-family "$TARGET_FAMILY" \
		--no-reserve-ip --yes )
}
must "upgrade-cos.sh exits 0" run_upgrade
if gcloud compute instances describe "$INSTANCE" --zone "$ZONE" >/dev/null 2>&1; then old_gone=no; else old_gone=yes; fi
expect "$old_gone" yes "the old instance is gone"
out=$(gcloud compute instances describe "$NEW_INSTANCE" --zone "$ZONE" --format='value(labels.bwgc-e2e)' 2>/dev/null)
expect "$out" "$ID" "the replacement carries the label"
want=$(printf '%s' "$TARGET_FAMILY" | sed 's/^cos-//; s/-lts$//')
out=$(on_q "$NEW_INSTANCE" 'grep ^VERSION= /etc/os-release | cut -d= -f2')
expect "$out" "$want" "the replacement runs milestone $want"
wait_for "the vault" 30 vault_alive "$NEW_INSTANCE" || exit 1
verify_on_disk "$NEW_INSTANCE" "after upgrade"
