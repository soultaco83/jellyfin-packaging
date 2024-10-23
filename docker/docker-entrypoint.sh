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

# Check if zip is installed
if ! command -v zip &> /dev/null; then
    echo "Error: zip is not installed. Cannot perform backup."
    touch "$CONTAINER_MARKER"  # Still create marker to prevent repeated attempts
    # Continue with rest of script instead of exiting
else
    # Check if this is a new container instance
    if [ ! -f "$CONTAINER_MARKER" ]; then
        echo "New container detected, performing database backup..."
        
        # Create backup directory if it doesn't exist
        mkdir -p "${BACKUP_DIR}"

        # Check if any database files exist
        DB_FILES_EXIST=false
        for db_file in "${DB_FILES[@]}"; do
            if [ -f "$db_file" ]; then
                DB_FILES_EXIST=true
                break
            fi
        done

        # Create zip backup if any database files exist
        if [ "$DB_FILES_EXIST" = true ]; then
            echo "Creating database backup: jellyfinDB-${BACKUP_TIMESTAMP}.zip"
            cd /config/data
            if zip "${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip" \
                $(for f in "${DB_FILES[@]}"; do basename "$f" 2>/dev/null; done | xargs -I {} test -f {} && echo {}) \
                2>/dev/null; then
                echo "Backup created successfully"
                
                # Keep only the last 5 zip backups
                find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
            else
                echo "Warning: Backup creation failed, but continuing with container startup"
            fi
        else
            echo "No database files found to backup"
        fi

        # Create marker file for next time
        touch "$CONTAINER_MARKER"
    else
        echo "Existing container detected, skipping database backup..."
    fi
fi

# Rest of your original script...
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