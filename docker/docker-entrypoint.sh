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

# Function to perform database backup with optimizations
perform_db_backup() {
    local reason="$1"
    echo "$(date '+%H:%M:%S') - Starting database backup... (Reason: $reason)"
    
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
        echo "$(date '+%H:%M:%S') - Found database files to backup: $FILES_TO_BACKUP"
        cd /config/data
        # Use fastest compression level (-1) for speed
        if zip -1 "${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip" ${FILES_TO_BACKUP} 2>/dev/null; then
            echo "$(date '+%H:%M:%S') - Database backup created successfully"
            
            # Keep only the last 5 database backups (run in background)
            (find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f -printf '%T@ %p\n' | sort -rn | tail -n +6 | cut -d' ' -f2- | xargs rm -f 2>/dev/null || true) &
        else
            echo "$(date '+%H:%M:%S') - Warning: Database backup creation failed, but continuing with container startup"
        fi
    else
        echo "$(date '+%H:%M:%S') - No database files found to backup"
    fi
}

# Function to perform config backup with optimizations
perform_config_backup() {
    echo "$(date '+%H:%M:%S') - Starting config backup..."
    
    # Check if config directory exists and has files
    if [ -d "/config/config" ] && [ "$(ls -A /config/config 2>/dev/null)" ]; then
        echo "$(date '+%H:%M:%S') - Found config files to backup"
        cd /config
        # Use fastest compression level (-1) for speed
        if zip -1 -r "${BACKUP_DIR}/configs-${BACKUP_TIMESTAMP}.zip" config/ 2>/dev/null; then
            echo "$(date '+%H:%M:%S') - Config backup created successfully"
            
            # Keep only the last 5 config backups (run in background)
            (find "${BACKUP_DIR}" -name "configs-*.zip" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true) &
        else
            echo "$(date '+%H:%M:%S') - Warning: Config backup creation failed, but continuing with container startup"
        fi
    else
        echo "$(date '+%H:%M:%S') - No config files found to backup"
    fi
}

# Function to setup plugin (can run in parallel with other non-DB operations)
setup_plugin() {
    # Get plugin version silently
    PLUGIN_VERSION=$(grep -oP 'PLUGIN_VERSION=\K.*' /etc/environment 2>/dev/null)

    # Exit if version not found
    if [ -z "$PLUGIN_VERSION" ]; then
        echo "$(date '+%H:%M:%S') - Error: Could not determine plugin version"
        return 1
    fi

    # Clean existing installations silently
    rm -rf /config/plugins/RequestsAddon_* 2>/dev/null || true

    # Set up paths
    SOURCE_DIR="/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}"
    DLL_FILE="${SOURCE_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
    TARGET_DIR="/config/plugins/RequestsAddon_${PLUGIN_VERSION}"

    # Verify DLL exists
    if [ ! -f "$DLL_FILE" ]; then
        echo "$(date '+%H:%M:%S') - Error: Plugin DLL not found"
        return 1
    fi

    # Install plugin
    mkdir -p "${TARGET_DIR}"
    cp "${DLL_FILE}" "${TARGET_DIR}/"
    chown root:root "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
    chmod 755 "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
    echo "$(date '+%H:%M:%S') - RequestsAddon plugin installed successfully"
}

# Function to setup cron and cleanup script
setup_cron() {
    # Create cleanup script (fix for subtitles not playing)
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

    # Apply cron job and start service
    crontab /etc/cron.d/db-cleanup &> /dev/null
    service cron start &> /dev/null
}

# Function to apply temp fixes
apply_temp_fixes() {
    # Temp fix for webos
    if [ ! -f /jellyfin/jellyfin-web/manifest.json ]; then
        cp /jellyfin/jellyfin-web/manifest.*.json /jellyfin/jellyfin-web/manifest.json 2>/dev/null || true
    fi
    touch /jellyfin/jellyfin-web/notification.txt
    
    # Temp fix for tmp folder requirement
    mkdir -p /tmp/jellyfin
    
    # Set permissions
    chmod 777 -R /jellyfin
}

# Main execution starts here
echo "$(date '+%H:%M:%S') - Container startup initiated"
echo "$(date '+%H:%M:%S') - Current Docker Build Signature: $CURRENT_BUILD_TIME"

if [ -f "$DOCKER_BUILD_FILE" ]; then
    echo "$(date '+%H:%M:%S') - Previous Docker Build Signature: $(cat $DOCKER_BUILD_FILE)"
fi

# Determine if backup is needed
BACKUP_NEEDED=false
BACKUP_REASON=""

if [ ! -f "$CONTAINER_MARKER" ]; then
    BACKUP_NEEDED=true
    BACKUP_REASON="New container detected"
elif [ -f "$DOCKER_BUILD_FILE" ]; then
    LAST_BUILD_TIME=$(cat "$DOCKER_BUILD_FILE")
    if [ "$LAST_BUILD_TIME" != "$CURRENT_BUILD_TIME" ]; then
        BACKUP_NEEDED=true
        BACKUP_REASON="Docker image update detected (Build signature changed)"
    else
        echo "$(date '+%H:%M:%S') - Same Docker image detected, skipping backups..."
    fi
else
    BACKUP_NEEDED=true
    BACKUP_REASON="No Docker image history found"
fi

# Start parallel operations that don't require database to be stopped
echo "$(date '+%H:%M:%S') - Starting parallel setup operations..."

# Start non-critical operations in background
(
    setup_cron
    echo "$(date '+%H:%M:%S') - Cron setup completed"
) &
CRON_PID=$!

(
    apply_temp_fixes
    echo "$(date '+%H:%M:%S') - Temp fixes applied"
) &
FIXES_PID=$!

# Setup plugin (this touches filesystem but not the database)
setup_plugin &
PLUGIN_PID=$!

# Perform backups if needed (these MUST complete before Jellyfin starts)
if [ "$BACKUP_NEEDED" = true ]; then
    # Both database and config backups are CRITICAL and must complete before Jellyfin starts
    echo "$(date '+%H:%M:%S') - Performing critical backups..."
    perform_db_backup "$BACKUP_REASON"
    perform_config_backup
    
    # Update build signature
    echo "$CURRENT_BUILD_TIME" > "$DOCKER_BUILD_FILE"
    echo "$(date '+%H:%M:%S') - Critical backups completed"
fi

# Wait for critical operations to complete
echo "$(date '+%H:%M:%S') - Waiting for setup operations to complete..."

# Wait for plugin setup (critical for Jellyfin)
wait $PLUGIN_PID
echo "$(date '+%H:%M:%S') - Plugin setup completed"

# Wait for other background operations
wait $CRON_PID 2>/dev/null || true
wait $FIXES_PID 2>/dev/null || true

# Config backup is now handled synchronously above, so no waiting needed here

# Update marker file
touch "$CONTAINER_MARKER"

echo "$(date '+%H:%M:%S') - All setup operations completed"
echo "$(date '+%H:%M:%S') - Starting Jellyfin at $@..."

# Start Jellyfin
exec "$@"
