# Bitwarden self-hosted on Google Cloud for Free

Bitwarden installation optimized for Google Cloud's 'always free' f1-micro compute instance

> _Note: if you follow these instructions the end product is a self-hosted instance of Bitwarden running in the cloud and will be free **unless** you exceed the 1GB egress per month or have egress to China or Australia. I talk about best practices to help avoid China/AUS egress, but there's a chance you can get charges from that so please keep that in mind._

This is a quick-start guide. Read about this project in more detail [here](https://bradford.la/2020/self-host-bitwarden-on-google-cloud).

---

## Features

* Bitwarden self-hosted
* Automatic https certificate management through Caddy 2 proxy
* Dynamic DNS updates through ddclient
* Blocking brute-force attempts with fail2ban
* Country-wide blocking through iptables and ipset

## Pre-requisites

Before you start, ensure you have the following:

1. A Google Cloud account
2. A Cloudflare-managed DNS site with an A record ready for Bitwarden

## Step 1: Set up Google Cloud `f1-micro` Compute Engine Instance

Google Cloud offers an '[always free](https://cloud.google.com/free/)' tier of their Compute Engine with one virtual core and ~600 MB of RAM (about 150 MB free depending on which OS you installed). [Vaultwarden](https://github.com/dani-garcia/vaultwarden) runs well under these constraints; it's written in Rust and an ideal candidate for a micro instance. 

Go to [Google Compute Engine](https://cloud.google.com/compute) and open a Cloud Shell. You may also create the instance manually following [the constraints of the free tier](https://cloud.google.com/free/docs/gcp-free-tier). In the Cloud Shell enter the following command to build the properly spec'd machine: 

```bash
$ gcloud compute instances create bitwarden \
    --machine-type f1-micro \
    --zone us-central1-a \
    --image-project cos-cloud \
    --image-family cos-stable \
    --boot-disk-size=30GB \
    --tags http-server,https-server \
    --scopes compute-ro
```

You may change the zone to be closer to you or customize the name (`bitwarden`), but most of the other values should remain the same. 

## Step 2: Pull and Configure Project

Enter a shell on the new instance and clone this repo:

```bash
$ git clone https://github.com/dadatuputi/bitwarden_gcloud.git
$ cd bitwarden_gcloud
```

Set up the docker-compose alias by using the included script:

```bash
$ sh utilities/install-alias.sh
$ source ~/.bashrc
$ docker-compose --version
docker-compose version 1.25.5, build 8a1c60f
```

### Configure Environmental Variables with `.env`

I provide `.env.template` which should be copied to `.env` and filled out; filling it out is self-explanitory and requires certain values such as a domain name, Cloudflare API tokens, etc. 

### Configure `fail2ban` (_optional_)

`fail2ban` stops brute-force attempts at your vault. To configure how long a ban is and how many attempts will trigger a ban, edit `fail2ban/jail.d/jail.local`:

```conf
bantime = 6h <- how long to enforce the ip ban
maxretry = 5  <- number of times to retry until a ban occurs
```

This will work out of the box - no `fail2ban` configuration is needed unless you want e-mail alerts of bans. To enable this, enter the SMTP settings in `.env`, and follow the instructions in `fail2ban/jail.d/jail.local` by uncommenting and entering `destemail` and `sender` and uncommenting the `action_mwl` action in the `bitwarden` and `bitwarden-admin` jails in the same file.

### Configure Country-wide Blocking (_optional_)

The `countryblock` container will block ip addresses from countries specified in `.env` under `COUNTRIES`. China, Hong Kong, and Australia (CN, HK, AU) are blocked by default because Google Cloud will charge egress to those countries under the free tier. You may add any country you like to that list, or clear it out entirely if you don't want to block those countries. Be aware, however, you'll probably be charged for any traffic to those countries, even from bots or crawlers. 

This country-wide blocklist will be updated daily at midnight, but you can change the `COUNTRYBLOCK_SCHEDULE` variable in `.env` to suit your needs. 

These block-lists are pulled from <www.ipdeny.com> on each update. 

### Configure Automatic Rebooting After Updates (_optional_)

Container-Optimized OS will automatically update itself, but the update will only be applied after a reboot. In order to ensure that you are using the most current operating system software, you can set a boot script that waits until an update has been applied to schedule a reboot.

Before you start, ensure you have `compute-rw` scope for your bitwarden compute vm. If you used the `gcloud` command above, it includes that scope. If not, go to your Google Cloud console and edit the "Cloud API access scopes" to have "Compute Engine" show "Read Write". You need to shut down your compute vm in order to change this.

Modify the script to set your local timezone and the time to schedule reboots: set the `TZ=` and `TIME=` variables in `utilities/reboot-on-update.sh`. By default the script will schedule reboots for 06:00 UTC. 

From within your compute vm console, type the command `toolbox`. From within `toolbox`, find the `utilities` folder within `bitwarden_gcloud`. `toolbox` mounts the host filesystem under `/media/root`, so go there to find the folder. It will likely be in `/media/root/home/<google account name>/bitwarden_gcloud/utilities` - `cd` to that folder.

Next, use `gcloud` to add the `reboot-on-update.sh` script to your vm's boot script metadata with the `add-metadata` [command](https://cloud.google.com/compute/docs/startupscript#startupscriptrunninginstances):

```bash
gcloud compute instances add-metadata <instance> --metadata-from-file startup-script=reboot-on-update.sh
```

You can confirm that your startup script has been added in your instance details under "Custom metadata" on the Compute Engine Console. 

Next, restart your vm with the command `$ sudo reboot`. Once your vm has rebooted, you can confirm that the startup script was run with the command:

```bash
$ sudo journalctl -u google-startup-scripts.service
```

Now the script will wait until a reboot is pending and then schedule a reboot for the time configured in the script.

## Step 3: Start Services

To start up, use `docker-compose`:

```bash
$ docker-compose up
```

You can now use your browser to visit your new Bitwarden site. 
