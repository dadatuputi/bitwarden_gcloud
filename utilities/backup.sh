#!/usr/bin/env ash

# vaultwarden backup script for docker
# Copyright (C) 2021 Bradford Law
# Licensed under the terms of MIT

LOG=/var/log/backup.log
SSMTP_CONF=/etc/ssmtp/ssmtp.conf

# Vaultwarden Email settings - usually provided as environment variables for but may be set below:
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
# Direct application of Vaultwarden SMTP settings except:
# * UseTLS - converts true to yes and false to no
# * UseSTARTTLS - Vaultwarden's SMTP_EXPLICIT_TLS is backwards, so flip from true/false to no/yes
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

  printf "Finished configuring email (%b)\n" "$SSMTP_CONF" > $LOG
}


# Send an email
# $1: subject
# $2: body
# $3: attachment
email_send() {
  if [ -n "$3" ]; then
    ATTACHMENT="-a $3 --"
  fi
  EMAIL_RESULT=$(printf "$2" | EMAIL="$BACKUP_EMAIL_FROM_NAME <$SMTP_FROM>" mutt -s "$1" $ATTACHMENT "$BACKUP_EMAIL_TO" 2>&1)
  
  if [ -n "$EMAIL_RESULT" ]; then
    printf "Email error: %b\n" "$EMAIL_RESULT" > $LOG
  else
    printf "Sent e-mail (%b) to %b\n" "$1" "$BACKUP_EMAIL_TO" > $LOG  
  fi
}


# Build email body message
# Print instructions to untar and unencrypt as needed
# $1: backup filename
email_body() {
  EXT=${1##*.}
  FILE=${1%%*.}

  # Email body messages
  EMAIL_BODY_TAR="Email backup successful.

To restore, untar in the Vaultwarden data directory:
    tar -zxf $FILE.tar.gz"

  EMAIL_BODY_AES="To decrypt an encrypted backup (.aes256), first decrypt using openssl:
    openssl enc -d -aes256 -salt -pbkdf2 -pass pass:<password> -in $FILE.tar.gz.aes256 -out $FILE.tar.gz"


  BODY=$EMAIL_BODY_TAR
  [ "$EXT" == "aes256" ] && BODY="$BODY\n\n $EMAIL_BODY_AES"

  printf "$BODY"
}


# Initialize rclone
RCLONE=/usr/bin/rclone
rclone_init() {
  # Install rclone - https://wiki.alpinelinux.org/wiki/Rclone
  curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
  unzip rclone-current-linux-amd64.zip
  cd rclone-*-linux-amd64
  cp rclone /usr/bin/
  chown root:root $RCLONE
  chmod 755 $RCLONE

  printf "Rclone installed to %b\n" "$RCLONE" > $LOG
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
  if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    BACKUP_FILE=$BACKUP_FILE.aes256
    tar -czf - -C $SQL_BACKUP_DIR $SQL_NAME -C $DATA $FILES | openssl enc -e -aes256 -salt -pbkdf2 -pass pass:${BACKUP_ENCRYPTION_KEY} -out $BACKUP_FILE
  else
    tar -czf $BACKUP_FILE -C $SQL_BACKUP_DIR $SQL_NAME -C $DATA $FILES
  fi
  printf "Backup file created at %b\n" "$BACKUP_FILE" > $LOG

  # cleanup tmp folder
  rm -f $SQL_BACKUP_NAME

  # rm any backups older than 30 days
  find $BACKUP_DIR/* -mtime +$BACKUP_DAYS -exec rm {} \;
  
  printf "$BACKUP_FILE"
}


##############################################################################################



# Initialize e-mail if (using e-mail backup OR BACKUP_EMAIL_NOTIFY is set) AND ssmtp has not been configured
if [ "$1" == "email" -o -n "$BACKUP_EMAIL_NOTIFY" ] && [ ! -f "$SSMTP_CONF" ]; then
  email_init
fi
# Initialize rclone if BACKUP=rclone and $(which rclone) is blank
if [ "$1" == "rclone" -a -z "$(which rclone)" ]; then
  rclone_init
fi 


# Handle E-mail Backup
if [ "$1" == "email" ]; then
  printf "Running email backup\n" > $LOG

  # Backup and send e-mail
  RESULT=$(make_backup)
  FILENAME=$(basename $RESULT)
  BODY=$(email_body $FILENAME)
  email_send "$BACKUP_EMAIL_FROM_NAME - $FILENAME" "$BODY" $RESULT
  

# Handle rclone Backup
elif [ "$1" == "rclone" ]; then
  printf "Running rclone backup\n" > $LOG
  
  # Only run if $BACKUP_RCLONE_CONF has been setup
  if [ -s "$BACKUP_RCLONE_CONF" ]; then
    RESULT=$(make_backup)

    # Sync with rclone
    REMOTE=$(rclone --config $BACKUP_RCLONE_CONF listremotes | head -n 1)
    rclone --config $BACKUP_RCLONE_CONF sync $BACKUP_DIR $REMOTE$BACKUP_RCLONE_DEST

    # Send email if configured
    if [ -n "$BACKUP_EMAIL_NOTIFY" ]; then
      email_send "$BACKUP_EMAIL_FROM_NAME - rclone backup completed" "Rclone backup completed"
    fi
  fi


elif [ "$1" == "local" ]; then
  printf "Running local backup\n" > $LOG
  
  RESULT=$(make_backup)

  if [ -n "$BACKUP_EMAIL_NOTIFY" ]; then
    email_send "$BACKUP_EMAIL_FROM_NAME - local backup completed" "Local backup completed"
  fi
fi
