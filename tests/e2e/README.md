# End-to-end test on Google Compute Engine

`gce-smoke.sh` runs `migrate-to-data-disk.sh` and `upgrade-cos.sh` from this
checkout against a real Container-Optimized OS instance, and checks what COS
did with them. The suite under `tests/cases` proves what the scripts *say* to
gcloud; this proves the disk mounts at boot, the stack starts from the mounted
path and not from the containers the daemon started first, and the vault's
data survives a reboot and a milestone upgrade.

It builds the deployment the way instances looked before the data disk
existed: repository in the home directory, no `user-data`, containers restarted
by the daemon. That is what the migration is for.

## What one run does

1. Creates an e2-micro from the second-newest live `cos-*-lts` family, with
   no data disk and no `user-data`.
2. Clones the repository into the home directory, selects the
   `docker-compose.e2e.yml` overlay (bitwarden and backup only; Caddy has no
   hostname to get a certificate for) and starts the stack the old way.
3. Registers an account through the API and writes a marker file among the
   attachments, so a fresh empty vault cannot pass for the real one.
4. Runs `migrate-to-data-disk.sh --yes` and verifies: the mount, the three
   systemd units, that the running containers bind the data disk and were
   started by `bwgc.service`, that `/alive` answers, that the account and the
   marker are what the containers see.
5. Reboots once more and verifies the same. This is the boot every later
   reboot looks like, including the unattended weekly one.
6. Runs `upgrade-cos.sh --yes --no-reserve-ip` to the newest LTS and verifies
   the same on the replacement, plus that the old instance is gone and the
   new one reports the requested milestone.
7. Switches the replacement to the Cloudflare tunnel path, back to Caddy, and
   to the tunnel again, with the commands the wiki gives for each direction
   ([Switching to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel)
   and its "Going back to Caddy"). Each end checks the container set (three
   on the tunnel, six on Caddy, no orphan from the other), that the seeded
   account is still there, that a supervisor run does not undo the switch,
   and that the `http-server`/`https-server` tags open and close ports 80
   and 443 from outside. On the Caddy path it also fetches the vault over
   TLS with the security headers applied and the `Server` header removed,
   and sees port 80 redirect.
8. Deletes everything it created, whatever happened, unless `--keep`.

About 25 minutes and about a cent. Every resource carries the label
`bwgc-e2e=<id>`; `--cleanup-only --id ID` removes one run's resources and
`--sweep` removes any older than three hours.

## Running it yourself

From a machine with `gcloud` authenticated against the test project:

```sh
tests/e2e/gce-smoke.sh --project my-bwgc-test --zone us-central1-a
```

`--keep` leaves the instances up to look at; `--legacy-family` and
`--target-family` pick the milestones; `--ref` is what the instance clones
(the scripts under test always come from this checkout).

The project must be one that holds nothing else. The script deletes by label
and by name prefix, never anything it did not create, but a dedicated project
is the only setting in which a mistake is harmless.

## Running it from GitHub Actions

`.github/workflows/e2e-gce.yml` runs on `workflow_dispatch` and on the first of
each month. It never runs on pull requests. It authenticates with Workload
Identity Federation, so no key is stored in the repository.

### 1. Project

```sh
PROJECT=my-bwgc-test           # holds nothing but this test
gcloud projects create "$PROJECT"
gcloud config set project "$PROJECT"
gcloud services enable compute.googleapis.com iamcredentials.googleapis.com
```

Link a billing account to it. Set a budget alert on it (Billing → Budgets),
at $5: a run costs a cent, so the alert firing means a run left something
behind.

Leave the default network and its `default-allow-ssh` rule in place: the
runner reaches the instance over its ephemeral external address. Do not
enable OS Login at project level; the script disables it per instance so the
ssh user is the local one and has sudo.

The Caddy phase of the test opens ports 80 and 443 on the instance with the
same tags Installation uses and closes them again. The tags are covered by
`compute.instanceAdmin.v1`; the firewall rules they select are not, and a
project created on the command line has none. Create them once:

```sh
gcloud compute firewall-rules create bitwarden-http-ingress --action allow --target-tags http-server --rules tcp:80 --source-ranges 0.0.0.0/0
gcloud compute firewall-rules create bitwarden-https-ingress --action allow --target-tags https-server --rules tcp:443 --source-ranges 0.0.0.0/0
```

### 2. Service account and Workload Identity Federation

```sh
SA=bwgc-e2e
gcloud iam service-accounts create "$SA" --display-name "bwgc end-to-end test"
SA_EMAIL="$SA@$PROJECT.iam.gserviceaccount.com"
for role in roles/compute.instanceAdmin.v1 roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA_EMAIL" --role "$role"
done

gcloud iam workload-identity-pools create github --location global --display-name GitHub
gcloud iam workload-identity-pools providers create-oidc github \
  --location global --workload-identity-pool github \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition "assertion.repository == 'dadatuputi/bitwarden_gcloud'"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/dadatuputi/bitwarden_gcloud"

echo "projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github"
```

`compute.instanceAdmin.v1` covers instances, disks, addresses and metadata;
`serviceAccountUser` lets the runner create instances that run as the default
compute service account, which `upgrade-cos.sh` carries over from the old
instance. The attribute condition limits the pool to this repository, so a
fork's workflow cannot use it.

### 3. Repository variables

Settings → Secrets and variables → Actions → Variables (not secrets; none of
these is secret):

| Variable | Value |
|---|---|
| `GCP_PROJECT` | the project id |
| `GCP_WIF_PROVIDER` | the `projects/…/providers/github` path printed above |
| `GCP_SA_EMAIL` | `bwgc-e2e@<project>.iam.gserviceaccount.com` |

Without `GCP_PROJECT` the job is skipped, so forks without a project see
nothing fail.

### 4. Cloudflare, optional

Without these the switches in step 7 still run: the tunnel gets a token that
connects to nothing, Caddy issues itself an internal certificate
(`EMAIL=internal`), and the checks stop at the instance's own address. With
them, the vault is also fetched through Cloudflare on the tunnel path and
over a real Let's Encrypt certificate on the Caddy path, and `ddclient` is
seen updating the record with the token.

Nothing here can touch anything but one hostname in one zone:

1. In Zero Trust → Networks → Tunnels, create a tunnel for the test (the
   dashboard flow; no `cloudflared` install needed) with one public hostname,
   say `e2e.example.com`, pointing at `http://bitwarden:80`. Copy the token
   from the install command; it lets a `cloudflared` connect as this tunnel
   and nothing else.
2. In My Profile → API Tokens, create a token with `Zone / DNS / Edit` and
   `Zone / Zone / Read`, restricted to that one zone. The test rewrites the
   hostname's record to an A record for the Caddy phase and puts the tunnel's
   CNAME back afterwards; `--cleanup-only` puts it back too if a run died in
   between.
3. Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `CF_TUNNEL_TOKEN` | the tunnel's run token |
| Secret | `CF_DNS_TOKEN` | the zone-scoped DNS token |
| Variable | `CF_ZONE_ID` | the zone id (Overview page of the zone) |
| Variable | `CF_TEST_HOSTNAME` | `e2e.example.com` |

Every Let's Encrypt certificate issued counts against the hostname's rate
limit (50 per registered domain per week); one run issues one.

### 5. First run

Actions → End-to-end on GCE → Run workflow. Read the log: each check prints
`ok` or `FAIL`, and the migration and upgrade scripts print their own steps.
If it fails, the resources are already deleted; re-run with `keep` ticked to
inspect the instance, then delete it by hand or let the next run's sweep do
it.

## What it does not cover

- Without the Cloudflare secrets: a real certificate, the tunnel actually
  carrying traffic, and ddclient against a real provider. The Caddyfile
  itself is validated in `tests/cases/065-caddyfile.sh`.
- countryblock and fail2ban doing anything: they run on the Caddy path, but
  nothing attacks the instance.
- A staged COS update actually rebooting the instance: cannot be forced.
- Restoring from the backup the migration downloads: the backup image's own
  suite covers restore.
