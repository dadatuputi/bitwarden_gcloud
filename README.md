# Bitwarden self-hosted on Google Cloud for Free

Bitwarden installation optimized for Google Cloud's 'always free' f1-micro compute instance

This is a quick-start guide. Read about this project in more detail [here](https://bradford.la/2020/self-host-bitwarden-on-google-cloud).

---

## Pre-requisites

Before you start, ensure you have the following:

1. A Google Cloud account
2. A Cloudflare-managed DNS site with an A record ready for Bitwarden

## Step 1: Set up Google Cloud `f1-micro` Compute Engine Instance

Google Cloud offers an '[always free](https://cloud.google.com/free/)' tier of their Compute Engine with one virtual core and ~600 MB of RAM (about 150 MB free depending on which OS you installed). [Bitwarden RS](https://github.com/dani-garcia/bitwarden_rs) runs well under these constraints; it's written in Rust and an ideal candidate for a micro instance. 

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

This file is self-explanitory and requires certain values such as a domain name, Cloudflare API tokens, etc. 

## Step 3: Start Services

To start up, use `docker-compose`:

```bash
$ docker-compose up
```

You can now use your browser to visit your new Bitwarden site. 
