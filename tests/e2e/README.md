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
7. Deletes everything it created, whatever happened, unless `--keep`.

About 20 minutes and about a cent. Every resource carries the label
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

### 4. First run

Actions → End-to-end on GCE → Run workflow. Read the log: each check prints
`ok` or `FAIL`, and the migration and upgrade scripts print their own steps.
If it fails, the resources are already deleted; re-run with `keep` ticked to
inspect the instance, then delete it by hand or let the next run's sweep do
it.

## What it does not cover

- Caddy, ddns, countryblock and fail2ban: no hostname, so no certificate. The
  Caddyfile is validated in `tests/cases/065-caddyfile.sh` instead.
- The Cloudflare tunnel path: needs a real tunnel token.
- A staged COS update actually rebooting the instance: cannot be forced.
- Restoring from the backup the migration downloads: the backup image's own
  suite covers restore.
