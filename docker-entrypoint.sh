#!/bin/bash

set -o pipefail

# Check for a stale lock file every 5 minutes.
LOCK_CHECK_INTERVAL=300
# Even if NEXUS_BACKUP_DIRECTORY is ill-defined, we define this up here and let validation below do the rest.
LOCK_FILE="${NEXUS_BACKUP_DIRECTORY}/.nexus-backup-lock"
# Set a timeout of 12 hours for the backup procedure.
LOCK_TIMEOUT=43200
# The name of the file used to trigger the backup procedure.
TRIGGER_FILE_NAME=".backup"

function backup {
    # Store the current timestamp (in seconds) in the lock file for future reference...
    echo "$(date +%s)" >! "${LOCK_FILE}"

    local TIMESTAMP;

    # The timestamp of the backup (we chose ISO-8601 for clarity).
    TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    echo "==> Attempting to backup the 'default' blobstore."
    tar c "${NEXUS_DATA_DIRECTORY}/blobs/default/" | rclone rcat "${RCLONE_REMOTE}:${TARGET_BUCKET}/${TIMESTAMP}/blobstore.tar" --streaming-upload-cutoff ${STREAMING_UPLOAD_CUTOFF}

    local EXIT_CODE_1=$?

    if [ ${EXIT_CODE_1} -ne 0 ]; then
        echo "(!) Couldn't backup the blobstore. Manual intervention is advised."
    else
        echo "(✓) Blobstore successfully backed-up."
    fi

    echo "==> Attempting to backup the Nexus databases."
    tar c "${NEXUS_BACKUP_DIRECTORY}/" | rclone rcat "${RCLONE_REMOTE}:${TARGET_BUCKET}/${TIMESTAMP}/databases.tar" --streaming-upload-cutoff ${STREAMING_UPLOAD_CUTOFF}

    local EXIT_CODE_2=$?

    if [ ${EXIT_CODE_2} -ne 0 ]; then
        echo "(!) Couldn't backup the databases. Manual intervention is advised."
    else
        find "${NEXUS_BACKUP_DIRECTORY}" -name "*.bak" -exec rm {} \; # Cleanup leftovers so that they don't get picked up next time.
        echo "(✓) Databases successfully backed-up."
    fi

    # Remove the lock file...
    rm -f "${LOCK_FILE}"
}

function maybe_start_backup {
    # Check for the presence of a lock file with size greater than zero. If it
    # exists it means that a backup process is already in place, and we should
    # not start a new one.
    echo "==> Checking if a backup is currently in progress."
    if [[ -s "${LOCK_FILE}" ]]; then
        echo "(!) A lock file is present."
        echo "(!) Maybe another backup process is already in place."
        echo "(!) The timeout for the backup process is $((LOCK_TIMEOUT / 3600))h."
        return 1;
    fi

    echo "==> Checking whether Nexus is reachable."
    nc -z -w1 "${NEXUS_LOCAL_HOST_PORT}"

    local EXIT_CODE=$?

    if [ ${EXIT_CODE} -ne 0 ]; then
        echo "(!) Nexus isn't responding. Maybe it's starting up or a backup procedure is in place."
        return 1;
    fi

    echo "==> Starting the backup procedure @ $(date)."

    backup & wait

    echo "==> Finished the backup procedure @ $(date)."
}

function compare_and_sleep {
    # Check for the presence of a lock file with size greater than zero.
    if [[ -s "${LOCK_FILE}" ]]; then
        # Read the timestamp it contains.
        LOCK_TIMESTAMP="$(cat "${LOCK_FILE}")"
        # Grab the current timestamp.
        THIS_TIMESTAMP="$(date +%s)"

        # Compare the difference between the timestamps with the value of
        # LOCK_TIMEOUT. If this difference is greater than the timeout it
        # means that the previous backup process did not complete.
        if (( THIS_TIMESTAMP - LOCK_TIMESTAMP > LOCK_TIMEOUT )); then
            echo "(!) Found a stale lock file."
            echo "(!) The previous backup did not complete successfully."
            echo "(!) The lock file will now be removed so that backups can proceed."
            rm -f "${LOCK_FILE}"
        fi
    fi
    sleep "${LOCK_CHECK_INTERVAL}"
}

function monitor_lock_file {
    while true; do
        compare_and_sleep
    done
}

if [[ ! -d "${NEXUS_BACKUP_DIRECTORY}" ]];
then
    echo "Backup directory not present. Is the volume mounted?"
    exit 1
fi

if [[ ! -d "${NEXUS_DATA_DIRECTORY}" ]];
then
    echo "Data directory not present. Is the volume mounted?"
    exit 1
fi

if [[ -z "${NEXUS_LOCAL_HOST_PORT}" ]];
then
    echo "Nexus pod-local host and port are not defined."
    exit 1
fi

if [[ -z "${TARGET_BUCKET}" ]];
then
    echo "Target bucket is not defined."
    exit 1
fi

monitor_lock_file &

echo "==> Monitoring '${NEXUS_BACKUP_DIRECTORY}/${TRIGGER_FILE_NAME}'..."

inotifywait -e attrib,create --format "%f" -m -q "${NEXUS_BACKUP_DIRECTORY}" | while read -r FILE
do
    if [[ "${FILE}" == "${TRIGGER_FILE_NAME}" ]];
    then
        maybe_start_backup
    fi
done
