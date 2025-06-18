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
    local files_to_backup=()
    for db_file in "${DB_FILES[@]}"; do
        if [ -f "$db_file" ]; then
            files_to_backup+=("$(basename "$db_file")")
        fi
    done

    # Only attempt zip if we found files to backup
    if [ ${#files_to_backup[@]} -gt 0 ]; then
        echo "$(date '+%H:%M:%S') - Found database files to backup: ${files_to_backup[*]}"
        cd /config/data
        # Use fastest compression level (-1) for speed
        if zip -1 "${BACKUP_DIR}/jellyfinDB-${BACKUP_TIMESTAMP}.zip" "${files_to_backup[@]}" 2>/dev/null; then
            echo "$(date '+%H:%M:%S') - Database backup created successfully"
            
            # Keep only the last 5 database backups (run in background)
            (find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f -printf '%T@ %p\n' | sort -rn | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f 2>/dev/null) &
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
            (find "${BACKUP_DIR}" -name "configs-*.zip" -type f | sort -r | tail -n +6 | xargs -r rm -f 2>/dev/null) &
        else
            echo "$(date '+%H:%M:%S') - Warning: Config backup creation failed, but continuing with container startup"
        fi
    else
        echo "$(date '+%H:%M:%S') - No config files found to backup"
    fi
}

# Function to setup plugin (simplified since plugin is now pre-downloaded)
setup_plugin() {
    # Get plugin version from the build
    local plugin_version
    plugin_version=$(grep -oP 'PLUGIN_VERSION=\K.*' /etc/environment 2>/dev/null)

    if [ -z "$plugin_version" ]; then
        echo "$(date '+%H:%M:%S') - Error: Could not determine plugin version"
        return 1
    fi

    echo "$(date '+%H:%M:%S') - Setting up RequestsAddon plugin version: $plugin_version"

    # Clean existing installations
    rm -rf /config/plugins/RequestsAddon_* 2>/dev/null || true

    # Set up paths
    local source_dir="/jellyfin/plugins/RequestsAddon_${plugin_version}"
    local target_dir="/config/plugins/RequestsAddon_${plugin_version}"

    # Check if the pre-built plugin exists
    if [ ! -d "$source_dir" ] || [ ! -f "${source_dir}/Jellyfin.Plugin.RequestsAddon.dll" ]; then
        echo "$(date '+%H:%M:%S') - Error: Plugin directory or DLL not found at $source_dir"
        return 1
    fi

    # Install plugin by copying the entire directory
    mkdir -p "${target_dir}"
    cp -r "${source_dir}"/* "${target_dir}/"
    chown -R root:root "${target_dir}"
    chmod -R 755 "${target_dir}"
    
    echo "$(date '+%H:%M:%S') - RequestsAddon plugin installed successfully"
    return 0
}

# Function to setup cron and cleanup script
setup_cron() {
    # Create cleanup script (fix for subtitles not playing)
    cat > /usr/local/bin/cleanup-db.sh << 'EOF'
#!/bin/bash
sqlite3 /config/data/jellyfin.db "delete from AttachmentStreamInfos" 2>/dev/null || true
echo "$(date) - Cleaned AttachmentStreamInfos table" >> /config/log/db-cleanup.log
EOF

    # Make it executable and set up cron job
    chmod +x /usr/local/bin/cleanup-db.sh
    echo "0 * * * * /usr/local/bin/cleanup-db.sh" > /etc/cron.d/db-cleanup
    chmod 0644 /etc/cron.d/db-cleanup

    # Apply cron job and start service (suppress output)
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
backup_needed=false
backup_reason=""

if [ ! -f "$CONTAINER_MARKER" ]; then
    backup_needed=true
    backup_reason="New container detected"
elif [ -f "$DOCKER_BUILD_FILE" ]; then
    last_build_time=$(cat "$DOCKER_BUILD_FILE")
    if [ "$last_build_time" != "$CURRENT_BUILD_TIME" ]; then
        backup_needed=true
        backup_reason="Docker image update detected (Build signature changed)"
    else
        echo "$(date '+%H:%M:%S') - Same Docker image detected, skipping backups..."
    fi
else
    backup_needed=true
    backup_reason="No Docker image history found"
fi

# Start parallel operations that don't require database to be stopped
echo "$(date '+%H:%M:%S') - Starting parallel setup operations..."

# Start all non-critical operations in background
{
    setup_cron
    echo "$(date '+%H:%M:%S') - Cron setup completed"
} &

{
    apply_temp_fixes
    echo "$(date '+%H:%M:%S') - Temp fixes applied"
} &

# Setup plugin (this is critical and must complete before Jellyfin starts)
if ! setup_plugin; then
    echo "$(date '+%H:%M:%S') - CRITICAL: Plugin setup failed. Container will continue but plugin may not work."
fi

# Perform backups if needed (these MUST complete before Jellyfin starts)
if [ "$backup_needed" = true ]; then
    echo "$(date '+%H:%M:%S') - Performing critical backups..."
    perform_db_backup "$backup_reason"
    perform_config_backup
    
    # Update build signature
    echo "$CURRENT_BUILD_TIME" > "$DOCKER_BUILD_FILE"
    echo "$(date '+%H:%M:%S') - Critical backups completed"
fi

# Wait for all background operations to complete
wait

# Update marker file
touch "$CONTAINER_MARKER"

echo "$(date '+%H:%M:%S') - All setup operations completed"
echo "$(date '+%H:%M:%S') - Starting Jellyfin at $@..."

# Start Jellyfin
exec "$@"
