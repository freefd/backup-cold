#!/usr/bin/env bash

echo "Backup-Hook-Finish is triggered"

_scriptDirectory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
test -f "${_scriptDirectory}/backup-cold.cfg" && source "${_scriptDirectory}/backup-cold.cfg"

_backup_path=$1

[ -z "${TELEGRAM_BOT_TOKEN}" -o -z "${TELEGRAM_CHAT_ID}" ] && true || curl -sq -d parse_mode=HTML -d chat_id=${TELEGRAM_CHAT_ID} \
    -d text="<b>$(hostname -s): cold backup notification</b>%0ACold backup of ${_backup_path} has <i>finished</i>" \
    -X POST https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage >/dev/null 2>&1

[ -z "${NTFY_SERVER}" -o -z "${NTFY_TOPIC}" -o -z "${NTFY_TOKEN}" ] && true || curl -sq -o /dev/null -H "Authorization: Bearer ${NTFY_TOKEN}" \
    -H "X-Priority: 3" -H "X-Title: $(hostname -f): cold backup" -H "X-Tags: package, dvd" \
    -d "Cold backup of ${_backup_path} has finished" ${NTFY_SERVER}/${NTFY_TOPIC} >/dev/null 2>&1
