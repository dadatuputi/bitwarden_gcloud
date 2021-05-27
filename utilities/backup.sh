#!/usr/bin/env ash

# vaultwarden backup script for docker
# Copyright (C) 2021 Bradford Law
# Licensed under the terms of MIT

LOG=/var/log/backup.log
SSMTP_CONF=/etc/ssmtp/ssmtp.conf

# Bitwarden Email settings - usually provided as environment variables for but may be set below:
# SMTP_HOST=
# SMTP_FROM=
# SMTP_PORT=
# SMTP_SSL=
# SMTP_EXPLICIT_TLS=
# SMTP_USERNAME=
# SMTP_PASSWORD
AUTH_METHOD=LOGIN

# Backup settings - provided as environment variables but may be set below:
# BACKUP_EMAIL_FROM_NAME=
# BACKUP_EMAIL_TO=


# Convert "tRuE" and "FaLsE" to "yes" and "no" for ssmtp.conf
# $1: string to convert
convert_bool() {
  case $1 in
    ([Tt][Rr][Uu][Ee]) echo yes;;
    ([Ff][Aa][Ll][Ss][Ee]) echo no;;
    (*) echo ERROR;;
  esac
}


# Initialize email settings
# Direct application of Bitwarden SMTP settings except:
# * UseTLS - converts true to yes and false to no
# * UseSTARTTLS - Bitwarden's SMTP_EXPLICIT_TLS is backwards, so flip from true/false to no/yes
#   * see https://github.com/dani-garcia/vaultwarden/issues/851
email_init() {
  # Install ssmtp
  apk --update --no-cache add ssmtp mutt

  # Copy configuration to ssmtp.conf
  cat > $SSMTP_CONF << EOF
root=$SMTP_FROM
mailhub=$SMTP_HOST:$SMTP_PORT
UseTLS=$(convert_bool $SMTP_SSL)
UseSTARTTLS=$([ $(convert_bool $SMTP_EXPLICIT_TLS) == "yes" ] && echo no || echo yes)
AuthUser=$SMTP_USERNAME
AuthPass=$SMTP_PASSWORD
AuthMethod=$AUTH_METHOD
FromLineOverride=yes
EOF
  printf "Configured %b\n" "$SSMTP_CONF" > $LOG

  printf "Finished configuring email\n" > $LOG
}


# Send an email
# $1: subject
# $2: body
# $3: attachment
email_send() {
  if [ -n $3 ]; then
    ATTACHMENT="-a $3 --"
  fi
  echo "$2" | EMAIL="$BACKUP_EMAIL_FROM_NAME <$SMTP_FROM>" mutt -s "$1" $ATTACHMENT $BACKUP_EMAIL_TO

  printf "Sent e-mail\n" > $LOG  
}


# Build email body message
# Print instructions to untar and unencrypt as needed
# $1: backup filename
email_body() {
  EXT=${1##*.}
  FILE=${1%%*.}

  # Email body messages
  EMAIL_BODY_TAR="Email backup successfully run

To restore, untar in the Bitwarden data directory:
    tar -zxf $FILE.tar.gz"

  EMAIL_BODY_AES="To decrypt an encrypted backup (.aes256), first decrypt using openssl:
    openssl enc -d -aes256 -salt -pbkdf2 -pass pass:<password> -in $FILE.tar.gz.aes256 -out $FILE.tar.gz"


  BODY=$EMAIL_BODY_TAR
  [ "$EXT" == "aes256" ] && BODY="$BODY\n\n $EMAIL_BODY_AES"

  printf $BODY
}


# Create backup and prune old backups
# Borrowed heavily from https://github.com/shivpatel/bitwarden_rs-local-backup
# with the addition of backing up:
# * attachments directory
# * sends directory
# * config.json
# * rsa_key* files
make_backup() {
  # use sqlite3 to create backup (avoids corruption if db write in progress)
  SQL_NAME="db.sqlite3"
  SQL_BACKUP_DIR="/tmp"
  SQL_BACKUP_NAME=$SQL_BACKUP_DIR/$SQL_NAME
  sqlite3 /data/$SQL_NAME ".backup '$SQL_BACKUP_NAME'"

  # build a string of files and directories to back up
  DATA="/data"
  cd $DATA
  FILES=""
  FILES="$FILES $([ -d attachments ] && echo attachments)"
  FILES="$FILES $([ -d sends ] && echo sends)"
  FILES="$FILES $([ -f config.json ] && echo sends)"
  FILES="$FILES $([ -f rsa_key.der -o -f rsa_key.pem -o -f rsa_key.pub.der ] && echo rsa_key*)"

  # tar up files and encrypt with openssl and encryption key
  BACKUP_DIR=$DATA/backups
  BACKUP_FILE=$BACKUP_DIR/"bw_backup_$(date "+%F-%H%M%S").tar.gz"

  # If a password is provided, run it through openssl
  if [ -n $BACKUP_ENCRYPTION_KEY ]; then
    BACKUP_FILE=$BACKUP_FILE.aes256
    tar -czf - -C $SQL_BACKUP_DIR $SQL_NAME -C $DATA $FILES | openssl enc -e -aes256 -salt -pbkdf2 -pass pass:${BACKUP_ENCRYPTION_KEY} -out $BACKUP_FILE
  else
    tar -czf $BACKUP_FILE -C $SQL_BACKUP_DIR $SQL_NAME -C $DATA $FILES
  fi
  printf "Backed up to %b\n" "$BACKUP_FILE" > $LOG

  # cleanup tmp folder
  rm -f $SQL_BACKUP_NAME

  # rm any backups older than 30 days
  find $BACKUP_DIR/* -mtime +$BACKUP_DAYS -exec rm {} \;
  
  printf "$BACKUP_FILE"
}


##############################################################################################



# Initialize e-mail if (using e-mail backup OR RCLONE_NOTIFY is set) AND ssmtp has not been configured
if [ "$1" == "email" -o -n "$RCLONE_NOTIFY" ] && [ ! -f "$SSMTP_CONF" ]; then
  email_init
fi


# Handle E-mail Backup
if [ "$1" == "email" ]; then
  printf "Running email backup\n" > $LOG

  # Backup and send e-mail
  RESULT=$(make_backup)
  FILENAME=$(basename $RESULT)
  BODY=$(email_body $FILENAME)
  email_send "Bitwarden Backup - $FILENAME" "$BODY" $RESULT
  

# Handle rclone Backup
elif [ "$1" == "rclone" ]; then
  printf "Rclone backup selected - not implemented yet\n" > $LOG

fi
