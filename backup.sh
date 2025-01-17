#!/bin/bash

cd "$(dirname "$0")"

LOCKFILE="/tmp/backup-hestia.lock"
acquire_lock() {
    if [ -e "$LOCKFILE" ]; then
        echo "Script is already running. Exiting."
        exit 1
    fi
    touch "$LOCKFILE"
}
release_lock() {
    rm -f "$LOCKFILE"
}
trap release_lock EXIT
acquire_lock

set -o allexport
source .env
set +o allexport

DATE=$(date +"%Y%m%d_%H%M")
IFS=',' read -ra hosts <<< "$HOSTS"
all_outputs=""

for host in "${hosts[@]}"; do
    IFS='|' read -r SOURCE DESTINATION <<< "$host"

    echo "Backing up $SOURCE to $DESTINATION"

    if [[ $SOURCE == *:* ]]; then
        IFS=':' read -r SOURCE_HOST_NAME SOURCE_PORT <<< "$SOURCE"
    else
        port=22
    fi

    SSH_COMMAND="ssh $SOURCE_HOST_NAME -p $SOURCE_PORT -o StrictHostKeyChecking=no"

    USERS=$($SSH_COMMAND "sudo /usr/local/hestia/bin/v-list-users list")
    for user in $USERS; do
        echo "Backing up $user"

        log_file=$(mktemp)

        echo "Source: $SOURCE" >> "$log_file"
        echo "Destination: $DESTINATION" >> "$log_file"

        $SSH_COMMAND "sudo /usr/local/hestia/bin/v-backup-user $user"
        $SSH_COMMAND "sudo chown admin:backup /backup/$user*.tar"

        rsync -av -P --info=progress2 --size-only -e "ssh -p $SOURCE_PORT  -o StrictHostKeyChecking=no" "$SOURCE_HOST_NAME:/backup/$user*.tar" "$TMP_PATH/" 2>&1 | tee /dev/tty > "$log_file"
        7za a -t7z -mhe=on -mx=0 -p"$ENCRYPTION_PASSWORD" $TMP_PATH/"$user"_"$DATE".7z "$TMP_PATH/$user*.tar" 2>&1
        $SSH_COMMAND "sudo rm /backup/$user*.tar" 2>&1 | tee /dev/tty > "$log_file"
        rm -rf $TMP_PATH/"$user"*.tar
        
        rclone move --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress --stats-unit bytes "$TMP_PATH" --include "/$user*.7z" "$DESTINATION/" 2>&1 | tee -a "$log_file" > /dev/tty
        
        output=$(tail -n 10 "$log_file")
        rm "$log_file"

        formatted_output=$(echo "$output" | sed ':a;N;$!ba;s/\n/<br>/g')
        all_outputs+="${formatted_output}<br><br>"
    done

    output=""

    if [[ -n "$DELETE_OLD_FILES_THRESHOLD_DAYS" && "$DELETE_OLD_FILES_THRESHOLD_DAYS" -gt 0 ]]; then
        echo "Deleting files older than $DELETE_OLD_FILES_THRESHOLD_DAYS days from $DESTINATION"
        output+=$(rclone delete --min-age "$DELETE_OLD_FILES_THRESHOLD_DAYS"d "$DESTINATION/" 2>&1 | tee /dev/tty)
    fi

    formatted_output=$(echo "$output" | sed ':a;N;$!ba;s/\n/<br>/g')
    all_outputs+="${formatted_output}<br><br>"
done

json_output=$(jq -Rs . <<< "$all_outputs")
current_date=$(date +"%Y-%m-%d")

json_payload=$(jq -n \
    --arg subject "Backup $HOSTNAME - $current_date" \
    --arg email "$FROM_EMAIL" \
    --arg to_emails "$ADMIN_EMAIL" \
    --arg htmlContent "<p>Backup Report for $HOSTNAME on $current_date</p>$all_outputs" \
    '{
        subject: $subject,
        sender: { email: $email },
        to: ($to_emails | split(",") | map({ email: . })),
        htmlContent: $htmlContent
    }'
)
echo $json_payload
echo $(curl -H "api-key:$BREVO_API_KEY" \
    -X POST \
    -d "$json_payload" \
    https://api.brevo.com/v3/smtp/email \
)
