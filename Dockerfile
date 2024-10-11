FROM alpine:3.20.3

LABEL maintainer nagra-insight-bot@nagra.com

# The directory to which the Nexus 'backup-2' task will produce its output.
ENV NEXUS_BACKUP_DIRECTORY="/nexus-data/backup"

# The Nexus data directory.
ENV NEXUS_DATA_DIRECTORY="/nexus-data"

# The pod-local host and port at which Nexus can be reached.
ENV NEXUS_LOCAL_HOST_PORT "localhost:8081"

# The name of the bucket to which the resulting backups will be uploaded.
ENV TARGET_BUCKET "nexus-backup"

# Size of the file chunk before streaimg it to the remote.
ENV STREAMING_UPLOAD_CUTOFF "5000000"

# The name of the Rclone remote.
ENV RCLONE_REMOTE "aws1"

WORKDIR /tmp

RUN apk add --no-cache --update ca-certificates bash curl inotify-tools openssl fuse rclone

ADD docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
