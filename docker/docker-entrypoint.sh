#!/bin/bash
set -e

# Enable debug mode for more verbose output
if [ "${DEBUG:-false}" = "true" ]; then
    set -x
fi

echo "==== Starting Jellyfin Docker entrypoint script ===="

# Create a marker file to detect container recreation and version changes
CONTAINER_MARKER="/config/.container_marker"
DOCKER_BUILD_FILE="/config/.last_docker_build"
# Use multiple files to generate a build signature
CURRENT_BUILD_TIME=$(stat -c %Y /jellyfin/jellyfin.dll && stat -c %Y /jellyfin/jellyfin-web/index.html | sha256sum | cut -d' ' -f1)
BACKUP_DIR="/config/backups"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/config/log"
DB_FILES=(
    "/config/data/jellyfin.db"
    "/config/data/jellyfin.db-shm"
    "/config/data/jellyfin.db-wal"
    "/config/data/library.db"
    "/config/data/library.db-shm"
    "/config/data/library.db-wal"
)

# Create required directories
echo "Creating required directories if they don't exist..."
mkdir -p /config/data
mkdir -p /config/config
mkdir -p "${LOG_DIR}"
mkdir -p /config/plugins
mkdir -p /config/data/attachments
mkdir -p /config/data/subtitles

# Fix permissions on directories
echo "Setting correct permissions on directories..."
chmod 755 -R /config

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
            
            # Keep only the last 15 database backups
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

echo "Setting up RequestsAddon plugin..."

# Get plugin version
PLUGIN_VERSION=$(grep -oP 'PLUGIN_VERSION=\K.*' /etc/environment || echo "")

# Check if plugin version was found
if [ -z "$PLUGIN_VERSION" ]; then
    echo "Warning: Could not determine plugin version from environment. Using plugin directory search as fallback."
    # Try to find any RequestsAddon directories
    PLUGIN_DIR=$(find /jellyfin/plugins -name "RequestsAddon_*" -type d | head -n 1)
    if [ -n "$PLUGIN_DIR" ]; then
        PLUGIN_VERSION=$(basename "$PLUGIN_DIR" | sed 's/RequestsAddon_//')
        echo "Found plugin directory: $PLUGIN_DIR, extracted version: $PLUGIN_VERSION"
    else
        echo "Error: No RequestsAddon plugin directories found in /jellyfin/plugins"
        echo "Plugin installation will be skipped. Jellyfin will still start."
        PLUGIN_VERSION=""
    fi
fi

if [ -n "$PLUGIN_VERSION" ]; then
    # Clean existing installations in target directory
    echo "Cleaning existing plugin installations in /config/plugins..."
    rm -rf /config/plugins/RequestsAddon_* 2>/dev/null || true
    
    # Set up paths
    SOURCE_DIR="/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}"
    DLL_FILE="${SOURCE_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
    TARGET_DIR="/config/plugins/RequestsAddon_${PLUGIN_VERSION}"
    
    # Verify DLL exists
    if [ ! -f "$DLL_FILE" ]; then
        echo "Error: Plugin DLL not found at ${DLL_FILE}"
        echo "Available plugin files:"
        find /jellyfin/plugins -type f -name "*.dll" | sort
        echo "WARNING: Plugin installation failed, but Jellyfin will still start."
    else
        # Install plugin
        echo "Installing plugin from ${DLL_FILE} to ${TARGET_DIR}..."
        mkdir -p "${TARGET_DIR}"
        cp "${DLL_FILE}" "${TARGET_DIR}/"
        chmod 755 "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
        echo "RequestsAddon plugin installed successfully"
    fi
fi

# Create cleanup script
echo "Creating database cleanup script..."
mkdir -p "${LOG_DIR}"
cat > /usr/local/bin/cleanup-db.sh << 'EOF'
#!/bin/bash
# Check if database exists before attempting to clean
if [ -f "/config/data/jellyfin.db" ]; then
    # Try to execute the SQL command safely
    if sqlite3 /config/data/jellyfin.db "delete from AttachmentStreamInfos"; then
        echo "$(date) - Successfully cleaned AttachmentStreamInfos table" >> /config/log/db-cleanup.log
    else
        echo "$(date) - Failed to clean AttachmentStreamInfos table" >> /config/log/db-cleanup.log
    fi
else
    echo "$(date) - jellyfin.db not found, skipping cleanup" >> /config/log/db-cleanup.log
fi
EOF

# Make it executable
chmod +x /usr/local/bin/cleanup-db.sh

# Set up cron job to run hourly
echo "Setting up cron job..."
echo "0 * * * * /usr/local/bin/cleanup-db.sh" > /etc/cron.d/db-cleanup
chmod 0644 /etc/cron.d/db-cleanup

# Apply cron job
crontab /etc/cron.d/db-cleanup

# Create troubleshooting script
echo "Creating troubleshooting script..."
cat > /usr/local/bin/jellyfin-troubleshoot.sh << 'EOF'
#!/bin/bash
echo "===== Jellyfin Troubleshooter ====="
echo "Checking directories:"
ls -la /jellyfin
ls -la /config
echo -e "\nChecking plugin directory:"
find /jellyfin/plugins -type f | sort
echo -e "\nChecking installed plugins:"
find /config/plugins -type f | sort
echo -e "\nChecking environment:"
env | sort
echo -e "\nChecking for running processes:"
ps aux
echo -e "\nChecking for errors in logs:"
find /config/log -type f -exec grep -l "Error\|Exception" {} \; -exec head -n 20 {} \;
echo -e "\nChecking SQLite database status:"
if [ -f "/config/data/jellyfin.db" ]; then
    sqlite3 /config/data/jellyfin.db "PRAGMA integrity_check;" || echo "Database integrity check failed"
else
    echo "Database not found"
fi
EOF

chmod +x /usr/local/bin/jellyfin-troubleshoot.sh

# Start cron service in background
echo "Starting cron service..."
service cron start

# Check for required directories
echo "Checking for required directories..."
if [ ! -d "/config/data/attachments" ]; then
    echo "Creating missing directory: /config/data/attachments"
    mkdir -p "/config/data/attachments"
    chmod 755 "/config/data/attachments"
fi

if [ ! -d "/config/data/subtitles" ]; then
    echo "Creating missing directory: /config/data/subtitles"
    mkdir -p "/config/data/subtitles"
    chmod 755 "/config/data/subtitles"
fi

# Set permissions recursively
echo "Setting permissions on Jellyfin directories..."
chmod -R 755 /jellyfin
chmod -R 755 /config

echo "==== Jellyfin entrypoint initialization complete ===="
echo "Starting Jellyfin server..."
echo "Command to be executed: $@"

# Launch Jellyfin with appropriate parameters
if [[ "$@" == "/jellyfin/jellyfin" ]]; then
    echo "Launching Jellyfin with additional parameters..."
    exec "$@" --log-level=Info
else
    exec "$@"
fi
