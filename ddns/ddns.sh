#!/usr/bin/env bash

########################################################################################################
# This script is designed to be run within a gcr.io/google.com/cloudsdktool/cloud-sdk container
# The GCLOUD* and CLOUDFLARE* variables are environment variables and should be set in 
# docker-compose.yml but can be set here as well.
#
# DOMAIN=<>
#
# The gcloud instance; e.g. instance-1
# GCLOUD_INSTANCE=<>
# 
# The gcloud zone; e.g., us-central1-a
# GCLOUD_ZONE=<>
# 
# Get from the Cloudflare overview page, under API 
# CLOUDFLARE_ZONE_ID=<>
# 
# Get from the Cloudflare profile, under API Tokens
# CLOUDFLARE_ZONE_TOKEN=<> 
#
# You can run this script outside a gcloud container in Container Optimized OS using toolbox by 
# uncommenting the lines below and ensuring the proper GCLOUD* and CLOUDFLARE* variables are set.
# shopt -s expand_aliases
# TOOLBOX="2>/dev/null /usr/bin/toolbox -q"               # Pipe stderr to /dev/null to keep output clean
# alias gcloud="$TOOLBOX /google-cloud-sdk/bin/gcloud"
# alias jq="$TOOLBOX /usr/bin/jq"
########################################################################################################

LOG=/var/log/ddns.log

# If `-d` is passed, print debug messages to the log
if [[ $1 == "-d" ]]; then
    DBG=$LOG
    printf "Debugging is on\n" > $LOG
else
    DBG=/dev/null
fi

# GET EXTERNAL IP FROM GCLOUD
EXT_IP_CMD="gcloud compute instances describe $GCLOUD_INSTANCE --zone=$GCLOUD_ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)'"
EXT_IP=$(eval $EXT_IP_CMD 2>/dev/null)
printf "DBG: External IP Command: %b\n" "$EXT_IP_CMD" > $DBG
if [[ -z $EXT_IP ]]; then
    printf "Failed to get external IP, check your GCLOUD variables\n" > $LOG
    exit 6
fi
printf "External IP is: %b\n" "$EXT_IP" > $LOG



# CLOUDFLARE
## Get DNS Identifier
## https://api.cloudflare.com/#dns-records-for-a-zone-list-dns-records
DNS_RECORD_RRESPONSE_CMD="curl -s -X GET \"https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$DOMAIN\" \
    -H \"Authorization: Bearer $CLOUDFLARE_ZONE_TOKEN\" \
    -H \"Content-Type: application/json\""
DNS_RECORDS_RESPONSE=$(eval $DNS_RECORD_RRESPONSE_CMD)
printf "DBG: CURL for Cloudflare DNS Records:\n%b\n" "$DNS_RECORD_RRESPONSE_CMD" > $DBG
printf "DBG: Cloudflare DNS Records Response:\n%b\n" "$(echo $DNS_RECORDS_RESPONSE | jq)" > $DBG

RECORD_ID=$(echo $DNS_RECORDS_RESPONSE | jq '.result[0].id' -r 2>/dev/null)
CURRENT_IP=$(echo $DNS_RECORDS_RESPONSE | jq '.result[0].content' -r 2>/dev/null)
if [[ -z $RECORD_ID || -z $CURRENT_IP || $RECORD_ID == "null" || $CURRENT_IP == "null" ]]; then
    printf "Failed to get DNS record zone, check your CLOUDFLARE variables\n" > $LOG
    exit 6
fi
printf "Current IP is: %b (Record ID: %b)\n" $CURRENT_IP $RECORD_ID > $LOG

if [[ $EXT_IP == $CURRENT_IP ]]; then
    printf "DNS record is already set to the external IP\n" > $LOG
else
    ## Update DNS Record
    ## https://api.cloudflare.com/#dns-records-for-a-zone-update-dns-record
    printf "Updating current IP (%b) with new IP (%b)\n" "$CURRENT_IP $EXT_IP" > $LOG

    DNS_UPDATE_RESPONSE_CMD="curl -s -X PUT \"https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$RECORD_ID\" \
        -H \"Authorization: Bearer $CLOUDFLARE_ZONE_TOKEN\" \
        -H \"Content-Type: application/json\" \
        --data '{\"type\":\"A\",\"name\":\"'$DOMAIN'\",\"content\":\"'$EXT_IP'\",\"ttl\":1,\"proxied\":false}'"
    DNS_UPDATE_RESPONSE=$(eval $DNS_UPDATE_RESPONSE_CMD)
    printf "DBG: CURL for Cloudflare DNS Update:\n%b\n" "$DNS_UPDATE_RESPONSE_CMD" > $DBG
    printf "DBG: Cloudflare DNS Update Response:\n%b\n" "$(echo $DNS_UPDATE_RESPONSE | jq)" > $DBG

    DNS_UPDATE_SUCCESS=$(echo "$DNS_UPDATE_RESPONSE" | jq '.success' -r 2>/dev/null)

    if [[ $DNS_UPDATE_SUCCESS == "true" ]]; then
        printf "DNS update succeeded\n" > $LOG
    else
        printf "DNS update failed; DNS response: %b\n" "$(echo $DNS_UPDATE_RESPONSE | jq)" > $LOG
    fi
fi
