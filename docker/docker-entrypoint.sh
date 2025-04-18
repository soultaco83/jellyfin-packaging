#!/bin/bash
set -e

# Create a marker file to detect container recreation and version changes
CONTAINER_MARKER="/config/.container_marker"
DOCKER_BUILD_FILE="/config/.last_docker_build"
# Use multiple files to generate a build signature
CURRENT_BUILD_TIME=$(stat -c %Y /jellyfin/jellyfin.dll && stat -c %Y /jellyfin/jellyfin-web/index.html | sha256sum | cut -d' ' -f1)
BACKUP_DIR="/config/backups"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DB_FILES=(
    "/config/data/jellyfin.db"
    "/config/data/jellyfin.db-shm"
    "/config/data/jellyfin.db-wal"
    "/config/data/library.db"
    "/config/data/library.db-shm"
    "/config/data/library.db-wal"
)

# Function to perform database backup
perform_db_backup() {
    local reason="$1"
    echo "Performing database backup... (Reason: $reason)"
    
    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"

    # Create a list of existing files to backup
    FILES_TO_BACKUP=""
    for db_file in "${DB_FILES[@]}"; do
        if [ -f "$db_file" ]; then
            FILES_TO_BACKUP="${FILES_TO_BACKUP} $(basename "$db_file")"
        fi
    done

    # Only attempt zip if we found files to backup
    if [ ! -z "$FILES_TO_BACKUP" ]; then
        echo "Found database files to backup: $FILES_TO_BACKUP"
        cd /config/data
        if zip "${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip" ${FILES_TO_BACKUP}; then
            echo "Database backup created successfully at ${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip"
            
            # Keep only the last 5 database backups
            find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f -printf '%T@ %p\n' | sort -rn | tail -n +16 | cut -d' ' -f2- | xargs rm -f 2>/dev/null || true
        else
            echo "Warning: Database backup creation failed, but continuing with container startup"
        fi
    else
        echo "No database files found to backup"
    fi
}

# Function to perform config backup
perform_config_backup() {
    echo "Performing config backup..."
    
    # Check if config directory exists and has files
    if [ -d "/config/config" ] && [ "$(ls -A /config/config)" ]; then
        echo "Found config files to backup"
        cd /config
        if zip -r "${BACKUP_DIR}/configs-${BACKUP_TIMESTAMP}.zip" config/; then
            echo "Config backup created successfully at ${BACKUP_DIR}/configs-${BACKUP_TIMESTAMP}.zip"
            
            # Keep only the last 5 config backups
            find "${BACKUP_DIR}" -name "configs-*.zip" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
        else
            echo "Warning: Config backup creation failed, but continuing with container startup"
        fi
    else
        echo "No config files found to backup"
    fi
}

# Debug info
echo "Current Docker Build Signature: $CURRENT_BUILD_TIME"
if [ -f "$DOCKER_BUILD_FILE" ]; then
    echo "Previous Docker Build Signature: $(cat $DOCKER_BUILD_FILE)"
fi

# Check if this is a new container or docker update
if [ ! -f "$CONTAINER_MARKER" ]; then
    perform_db_backup "New container detected"
    perform_config_backup
    echo "$CURRENT_BUILD_TIME" > "$DOCKER_BUILD_FILE"
elif [ -f "$DOCKER_BUILD_FILE" ]; then
    LAST_BUILD_TIME=$(cat "$DOCKER_BUILD_FILE")
    if [ "$LAST_BUILD_TIME" != "$CURRENT_BUILD_TIME" ]; then
        perform_db_backup "Docker image update detected (Build signature changed)"
        perform_config_backup
        echo "$CURRENT_BUILD_TIME" > "$DOCKER_BUILD_FILE"
    else
        echo "Same Docker image detected, skipping backups..."
    fi
else
    perform_db_backup "No Docker image history found"
    perform_config_backup
    echo "$CURRENT_BUILD_TIME" > "$DOCKER_BUILD_FILE"
fi

# Update marker file
touch "$CONTAINER_MARKER"

# Get plugin version silently
PLUGIN_VERSION=$(grep -oP 'PLUGIN_VERSION=\K.*' /etc/environment)

# Exit if version not found
if [ -z "$PLUGIN_VERSION" ]; then
    echo "Error: Could not determine plugin version"
    exit 1
fi

# Clean existing installations silently
rm -rf /config/plugins/RequestsAddon_* 2>/dev/null || true

# Set up paths
SOURCE_DIR="/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}"
DLL_FILE="${SOURCE_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
TARGET_DIR="/config/plugins/RequestsAddon_${PLUGIN_VERSION}"

# Verify DLL exists
if [ ! -f "$DLL_FILE" ]; then
    echo "Error: Plugin DLL not found"
    exit 1
fi

# Install plugin
mkdir -p "${TARGET_DIR}"
cp "${DLL_FILE}" "${TARGET_DIR}/"
chown root:root "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
chmod 755 "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
echo "RequestsAddon plugin installed successfully"

# Create cleanup script
cat > /usr/local/bin/cleanup-db.sh << 'EOF'
#!/bin/bash
sqlite3 /config/data/jellyfin.db "delete from AttachmentStreamInfos"
echo "$(date) - Cleaned AttachmentStreamInfos table" >> /config/log/db-cleanup.log
EOF

# Make it executable
chmod +x /usr/local/bin/cleanup-db.sh

# Set up cron job to run hourly
echo "0 * * * * /usr/local/bin/cleanup-db.sh" > /etc/cron.d/db-cleanup
chmod 0644 /etc/cron.d/db-cleanup

# Apply cron job
crontab /etc/cron.d/db-cleanup

# Start cron service in background
service cron start

exec "$@"
