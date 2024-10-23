#!/bin/bash
set -e

# Create a marker file to detect container recreation
CONTAINER_MARKER="/config/.container_marker"
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

# Check if this is a new container instance
if [ ! -f "$CONTAINER_MARKER" ]; then
    echo "New container detected, performing database backup..."
    
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
        echo "Found files to backup: $FILES_TO_BACKUP"
        cd /config/data
        if zip "${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip" ${FILES_TO_BACKUP}; then
            echo "Backup created successfully at ${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip"
            
            # Keep only the last 5 zip backups
            find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
        else
            echo "Warning: Backup creation failed, but continuing with container startup"
        fi
    else
        echo "No database files found to backup, skipping backup creation"
    fi

    # Create marker file for next time
    touch "$CONTAINER_MARKER"
else
    echo "Existing container detected, skipping database backup..."
fi

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

exec "$@"