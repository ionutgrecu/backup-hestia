#!/bin/bash

cd "$(dirname "$0")"

set -o allexport
source .env
set +o allexport

DATE=$(date +"%Y%m%d_%H%M")
IFS=',' read -ra hosts <<< "$HOSTS"

for host in "${hosts[@]}"; do
    IFS='|' read -r SOURCE DESTINATION <<< "$host"

    echo "Backing up $SOURCE to $DESTINATION"

    if [[ $SOURCE == *:* ]]; then
        IFS=':' read -r SOURCE_HOST_NAME SOURCE_PORT <<< "$SOURCE"
    else
        port=22
    fi

    SSH_COMMAND="ssh $SOURCE_HOST_NAME -p $SOURCE_PORT"

    USERS=$($SSH_COMMAND "sudo /usr/local/hestia/bin/v-list-users list")
    for user in $USERS; do
        echo "Backing up $user"

        $SSH_COMMAND "sudo /usr/local/hestia/bin/v-backup-user $user"
        $SSH_COMMAND "sudo chown admin:backup /backup/$user*.tar"

        rsync -av -P --info=progress2 --size-only -e "ssh -p $SOURCE_PORT" "$SOURCE_HOST_NAME:/backup/$user*.tar" "$TMP_PATH/"
        7za a -t7z -mhe=on -mx=0 -p"$ENCRYPTION_PASSWORD" $TMP_PATH/"$user"_"$DATE".7z "$TMP_PATH/$user*.tar"
        rm -rf "$TMP_PATH/$user*.tar"
        output=$(rclone move --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress --stats-unit bytes "$TMP_PATH" --include "/$user*.7z" "$DESTINATION/" 2>&1 | tee /dev/tty)
    done

    if [[ -n "$DELETE_OLD_FILES_THRESHOLD_DAYS" && "$DELETE_OLD_FILES_THRESHOLD_DAYS" -gt 0 ]]; then
        echo "Deleting files older than $DELETE_OLD_FILES_THRESHOLD_DAYS days from $DESTINATION"
        output+=$(rclone delete --min-age "$DELETE_OLD_FILES_THRESHOLD_DAYS"d "$DESTINATION/" 2>&1 | tee /dev/tty)
    fi
done