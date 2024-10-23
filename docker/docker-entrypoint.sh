#!/bin/bash
set -e

# Create a marker file to detect container recreation and version changes
CONTAINER_MARKER="/config/.container_marker"
VERSION_FILE="/config/.last_version"
CURRENT_VERSION="${JELLYFIN_VERSION:-unknown}"
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
            find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
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

# Check if this is a new container or version update
if [ ! -f "$CONTAINER_MARKER" ]; then
    perform_db_backup "New container detected"
    perform_config_backup
    echo "$CURRENT_VERSION" > "$VERSION_FILE"
elif [ -f "$VERSION_FILE" ]; then
    LAST_VERSION=$(cat "$VERSION_FILE")
    if [ "$LAST_VERSION" != "$CURRENT_VERSION" ]; then
        perform_db_backup "Version update detected (${LAST_VERSION} -> ${CURRENT_VERSION})"
        perform_config_backup
        echo "$CURRENT_VERSION" > "$VERSION_FILE"
    else
        echo "Same version detected, skipping backups..."
    fi
else
    perform_db_backup "No version history found"
    perform_config_backup
    echo "$CURRENT_VERSION" > "$VERSION_FILE"
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

exec "$@"