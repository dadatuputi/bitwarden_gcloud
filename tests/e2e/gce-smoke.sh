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
# After the upgrade it switches the replacement to the Cloudflare tunnel path,
# back to Caddy, and to the tunnel again, with the commands the wiki gives for
# each direction. Every resource carries the label bwgc-e2e=<id> and is
# deleted at the end, whatever happened, unless --keep is given.
#
# With CF_TUNNEL_TOKEN, CF_DNS_TOKEN, CF_ZONE_ID and CF_TEST_HOSTNAME in the
# environment, the switches are also checked from outside: the vault is
# fetched through Cloudflare on the tunnel path, and over a real Let's Encrypt
# certificate on the Caddy path. Without them, the tunnel gets a token that
# connects to nothing, Caddy issues itself an internal certificate, and the
# checks stop at the instance's own address.
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

# --- Cloudflare DNS, for the checks from outside -----------------------------
# The test hostname is a CNAME to the test tunnel between runs. The Caddy
# phase replaces it with an A record to the instance and the original is put
# back afterwards; it is saved to a file first so --cleanup-only can put it
# back from a fresh process if a run died in between.
CF_API=https://api.cloudflare.com/client/v4
DNS_SAVE="$ROOT/.e2e-dns-original.json"
tier2() { [ -n "${CF_TUNNEL_TOKEN:-}" ] && [ -n "${CF_DNS_TOKEN:-}" ] && [ -n "${CF_ZONE_ID:-}" ] && [ -n "${CF_TEST_HOSTNAME:-}" ]; }
cf() { curl -sS --max-time 30 -H "Authorization: Bearer $CF_DNS_TOKEN" -H 'Content-Type: application/json' "$@"; }
cf_records() { cf "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$CF_TEST_HOSTNAME" | jq -c '.result[]'; }
cf_delete_records() { cf_records | jq -r '.id' | while IFS= read -r rid; do cf -X DELETE "$CF_API/zones/$CF_ZONE_ID/dns_records/$rid" >/dev/null; done; }
cf_set_a() { # cf_set_a <ip>
	cf_delete_records
	cf -X POST "$CF_API/zones/$CF_ZONE_ID/dns_records" \
		--data "$(jq -nc --arg n "$CF_TEST_HOSTNAME" --arg ip "$1" '{type:"A",name:$n,content:$ip,ttl:60,proxied:false}')" \
		| jq -e '.success' >/dev/null
}
cf_save_original() { cf_records | head -1 > "$DNS_SAVE"; [ -s "$DNS_SAVE" ] || { rm -f "$DNS_SAVE"; return 1; }; }
cf_restore_original() {
	[ -s "$DNS_SAVE" ] || return 0
	cur=$(cf_records | head -1 | jq -r '"\(.type) \(.content)"')
	want=$(jq -r '"\(.type) \(.content)"' "$DNS_SAVE")
	if [ "$cur" = "$want" ]; then rm -f "$DNS_SAVE"; return 0; fi
	echo "restoring $CF_TEST_HOSTNAME to $want"
	cf_delete_records
	cf -X POST "$CF_API/zones/$CF_ZONE_ID/dns_records" \
		--data "$(jq -c '{type:.type,name:.name,content:.content,ttl:.ttl,proxied:.proxied}' "$DNS_SAVE")" \
		| jq -e '.success' >/dev/null && rm -f "$DNS_SAVE"
}

cleanup_id() {
	say "Cleaning up bwgc-e2e=$1"
	if tier2; then cf_restore_original || echo "could not restore $CF_TEST_HOSTNAME; check the zone" >&2; fi
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
# The same discovery upgrade-cos.sh uses: listed from Google, probed in this
# zone, newest first.
. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
live=$(cos_lts_families "$ZONE" | tr '\n' ' ')
# shellcheck disable=SC2086
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
# The hostname the vault is served on. With Cloudflare it is the real test
# hostname; otherwise a name that resolves nowhere and is reached by address.
if tier2; then DOMAIN=$CF_TEST_HOSTNAME; EMAIL="e2e@${CF_TEST_HOSTNAME#*.}"; else DOMAIN="vault-$ID.e2e.invalid"; EMAIL=internal; fi
start_legacy() {
	# DOMAIN and EMAIL are set on the template's own lines, not appended: a
	# second DOMAIN= line would be read by whichever grep looks first.
	on "$INSTANCE" "set -e; cd ~/bitwarden_gcloud; \
  cp .env.template .env; \
  sed -i 's/^DOMAIN=.*/DOMAIN=$DOMAIN/; s/^EMAIL=.*/EMAIL=$EMAIL/' .env; \
  printf '\n# e2e\nBACKUP=local\nSIGNUPS_ALLOWED=true\nCOMPOSE_FILE=docker-compose.yml:tests/e2e/docker-compose.e2e.yml\n' >> .env; \
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

# ---------------------------------------------------------------------------
# The two ways the vault is reached, switched on the replacement with the
# commands the wiki gives (Switching to a Cloudflare Tunnel, and its "Going
# back to Caddy"). What is checked is the mechanics those pages warn about:
# stop the supervisor, down under the current file set, only then edit .env;
# no orphaned containers; the supervisor not undoing the switch; the tags
# opening and closing the ports. With Cloudflare, each end is also fetched
# from outside.
DEPLOY=$MOUNT/bitwarden_gcloud
containers() { on_q "$1" "docker ps --format '{{.Names}}' | sort | tr '\n' ' '"; }
seeded_ok() { [ "$(on_q "$1" 'docker exec backup sqlite3 /data/db.sqlite3 "select email from users"')" = "$SEED_EMAIL" ]; }
external_ip() { gcloud compute instances describe "$1" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)'; }
# curl writes the -w code even when it fails (000 on a timeout), so only an
# empty result is turned into 000.
http_code() { out=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null); printf '%s' "${out:-000}"; }
# Through Cloudflare, with certificate verification, as a client would.
via_cloudflare() { [ "$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' "https://$CF_TEST_HOSTNAME/alive")" = 200 ]; }
# Over a real certificate, straight at the instance.
via_letsencrypt() { [ "$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:$1" "https://$DOMAIN/alive")" = 200 ]; }

switch_to_tunnel() { # switch_to_tunnel <instance> <token>
	# The token goes over stdin, not in the command line.
	printf '%s' "$2" | on "$1" "cat > ~/.e2e-tunnel-token"
	on "$1" "set -e; cd $DEPLOY; . ~/.bwgc-compose.sh; \
  sudo systemctl stop bwgc-supervise.timer; \
  docker-compose down >/dev/null 2>&1; \
  sed -i '/^COMPOSE_FILE=/d; /^TUNNEL_TOKEN=/d' .env; \
  printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.tunnel.yml\nTUNNEL_TOKEN=%s\n' \"\$(cat ~/.e2e-tunnel-token)\" >> .env; \
  rm -f ~/.e2e-tunnel-token; \
  docker-compose up -d >/dev/null 2>&1; \
  sudo systemctl start bwgc-supervise.timer"
}

switch_to_caddy() { # switch_to_caddy <instance>
	# "Going back to Caddy", as the wiki has it: supervisor off, down under
	# the tunnel file set, then the two lines out of .env, then up.
	on "$1" "set -e; cd $DEPLOY; . ~/.bwgc-compose.sh; \
  sudo systemctl stop bwgc-supervise.timer bwgc.service; \
  docker-compose down >/dev/null 2>&1; \
  [ -z \"\$(docker ps -q)\" ] || { echo 'containers survived down:'; docker ps --format '{{.Names}}'; exit 1; }; \
  sed -i '/^COMPOSE_FILE=/d; /^TUNNEL_TOKEN=/d' .env; \
  [ \"\$(grep -cE '^(COMPOSE_FILE|TUNNEL_TOKEN)=' .env)\" = 0 ]; \
  grep -q '^EMAIL=.' .env; \
  docker-compose up -d >/dev/null 2>&1; \
  sudo systemctl start bwgc-supervise.timer"
}

# The tags, and the rules they select if the project has none (a fresh
# project has no default-allow-http/https). Creating rules needs more than
# instanceAdmin, so a project set up per the README has them already and this
# only ever adds the tags.
open_ports() { # open_ports <instance>
	gcloud compute instances add-tags "$1" --zone "$ZONE" --tags http-server,https-server >/dev/null
	if [ -z "$(gcloud compute firewall-rules list --filter='targetTags:(http-server OR https-server)' --format='value(name)' 2>/dev/null)" ]; then
		gcloud compute firewall-rules create bitwarden-http-ingress --action allow --target-tags http-server --rules tcp:80 --source-ranges 0.0.0.0/0 >/dev/null
		gcloud compute firewall-rules create bitwarden-https-ingress --action allow --target-tags https-server --rules tcp:443 --source-ranges 0.0.0.0/0 >/dev/null
	fi
}
close_ports() { gcloud compute instances remove-tags "$1" --zone "$ZONE" --tags http-server,https-server >/dev/null; }

say "Step 6: switch to the Cloudflare tunnel"
if tier2; then TUNNEL_TOKEN=$CF_TUNNEL_TOKEN; else TUNNEL_TOKEN="e2e-no-such-tunnel-$ID"; fi
must "the stack is switched to the tunnel file set" switch_to_tunnel "$NEW_INSTANCE" "$TUNNEL_TOKEN"
expect "$(containers "$NEW_INSTANCE")" "backup bitwarden cloudflared " "tunnel: bitwarden, backup and cloudflared run, nothing else"
if seeded_ok "$NEW_INSTANCE"; then seeded=yes; else seeded=no; fi
expect "$seeded" yes "tunnel: the vault still holds the seeded account"
on "$NEW_INSTANCE" 'sudo systemctl start bwgc-supervise.service' >/dev/null 2>&1
expect "$(containers "$NEW_INSTANCE")" "backup bitwarden cloudflared " "tunnel: a supervisor run leaves the container set alone"
if tier2; then
	if wait_for "the vault through Cloudflare" 18 via_cloudflare; then cf_ok=yes; else cf_ok=no; fi
	expect "$cf_ok" yes "tunnel: the vault answers through Cloudflare at $CF_TEST_HOSTNAME"
fi

say "Step 7: switch back to Caddy"
if tier2; then
	must "the original DNS record is saved" cf_save_original
	IP=$(external_ip "$NEW_INSTANCE")
	must "an A record points $CF_TEST_HOSTNAME at the instance" cf_set_a "$IP"
	# What the operator does with ddns on this path, with the same token.
	on "$NEW_INSTANCE" "cat > $DEPLOY/ddns/ddclient.conf" <<EOF
use=cmd  cmd='curl -s -H "Metadata-Flavor:Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip'
protocol=cloudflare
zone=${CF_TEST_HOSTNAME#*.}
ttl=1
login=token
password=$CF_DNS_TOKEN
$CF_TEST_HOSTNAME
EOF
fi
must "the stack is switched back to the Caddy file set" switch_to_caddy "$NEW_INSTANCE"
must "ports 80 and 443 are opened with the http-server/https-server tags" open_ports "$NEW_INSTANCE"
IP=$(external_ip "$NEW_INSTANCE")
expect "$(containers "$NEW_INSTANCE")" "backup bitwarden countryblock ddns fail2ban proxy " "caddy: the six containers run and cloudflared is gone"
if seeded_ok "$NEW_INSTANCE"; then seeded=yes; else seeded=no; fi
expect "$seeded" yes "caddy: the vault still holds the seeded account"
# Caddy answers on the instance itself first (internal certificate, or the
# real one once issued), then from here, which is what the tags and the
# firewall rules are for.
on_caddy() { [ "$(on_q "$NEW_INSTANCE" "curl -sk --max-time 10 -o /dev/null -w '%{http_code}' --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/alive")" = 200 ]; }
wait_for "caddy on the instance" 18 on_caddy || true
hdrs=$(on_q "$NEW_INSTANCE" "curl -skI --max-time 10 --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/alive")
case "$hdrs" in *"HTTP/"*" 200"*) code=200 ;; *) code=$(printf '%s' "$hdrs" | head -1) ;; esac
expect "$code" 200 "caddy: the vault answers over TLS on the instance"
case "$hdrs" in *"X-Frame-Options: DENY"*|*"x-frame-options: DENY"*) xfo=yes ;; *) xfo=no ;; esac
expect "$xfo" yes "caddy: the security headers are applied"
case "$hdrs" in *"Server:"*|*"server:"*) srv=shown ;; *) srv=hidden ;; esac
expect "$srv" hidden "caddy: the Server header is removed"
expect "$(http_code --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/alive")" 200 "caddy: the vault answers from outside at $IP:443"
expect "$(http_code "http://$IP/")" 308 "caddy: port 80 redirects to https"
if tier2; then
	if wait_for "a Let's Encrypt certificate" 24 via_letsencrypt "$IP"; then le_ok=yes; else le_ok=no; fi
	expect "$le_ok" yes "caddy: the vault answers at $DOMAIN with a certificate a client trusts"
	# ddns must have accepted the token and found the record current.
	ddlog=$(on_q "$NEW_INSTANCE" 'docker logs ddns 2>&1 | tail -20')
	case "$ddlog" in *SUCCESS*|*skipped*|*"IP address"*) dd=ok ;; *) dd=none ;; esac
	expect "$dd" ok "caddy: ddclient reached Cloudflare with the token"
fi

say "Step 8: back to the tunnel, ports closed"
must "the stack is switched to the tunnel file set again" switch_to_tunnel "$NEW_INSTANCE" "$TUNNEL_TOKEN"
close_ports "$NEW_INSTANCE"
expect "$(containers "$NEW_INSTANCE")" "backup bitwarden cloudflared " "tunnel again: bitwarden, backup and cloudflared run, nothing else"
sleep "$((SLEEP * 2))"
expect "$(http_code --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/alive")" 000 "tunnel again: nothing answers from outside on 443"
expect "$(http_code "http://$IP/")" 000 "tunnel again: nothing answers from outside on 80"
if tier2; then
	must "the original DNS record is restored" cf_restore_original
	# The A record had a 60 s TTL; a resolver may hand it out for that long
	# after the CNAME is back, and the ports are closed, so allow for it.
	if wait_for "the vault through Cloudflare again" 24 via_cloudflare; then cf_ok=yes; else cf_ok=no; fi
	expect "$cf_ok" yes "tunnel again: the vault answers through Cloudflare at $CF_TEST_HOSTNAME"
fi

