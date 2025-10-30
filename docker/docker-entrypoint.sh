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
            
            # Keep only the last 10 database backups (run in background)
            (find "${BACKUP_DIR}" -name "jellyfinDB-*.zip" -type f -printf '%T@ %p\n' | sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f 2>/dev/null) &
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
            
            # Keep only the last 10 config backups (run in background)
            (find "${BACKUP_DIR}" -name "configs-*.zip" -type f | sort -r | tail -n +11 | xargs -r rm -f 2>/dev/null) &
        else
            echo "$(date '+%H:%M:%S') - Warning: Config backup creation failed, but continuing with container startup"
        fi
    else
        echo "$(date '+%H:%M:%S') - No config files found to backup"
    fi
}

# Function to compare version strings (returns 0 if v1 > v2, 1 if v1 <= v2)
version_gt() {
    local v1=$1
    local v2=$2
    
    # Remove any leading 'v' if present
    v1=${v1#v}
    v2=${v2#v}
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "$v1"
    IFS='.' read -ra V2 <<< "$v2"
    
    # Compare each segment
    for i in "${!V1[@]}"; do
        # If v2 has fewer segments, v1 is greater
        if [ -z "${V2[$i]}" ]; then
            return 0
        fi
        # Compare segments numerically
        if [ "${V1[$i]}" -gt "${V2[$i]}" ]; then
            return 0
        elif [ "${V1[$i]}" -lt "${V2[$i]}" ]; then
            return 1
        fi
    done
    
    # If v2 has more segments, v1 is not greater
    if [ "${#V2[@]}" -gt "${#V1[@]}" ]; then
        return 1
    fi
    
    # Versions are equal
    return 1
}

# Function to apply temp fixes
apply_temp_fixes() {
    # Temp fix for webos
    if [ ! -f /jellyfin/jellyfin-web/manifest.json ]; then
        cp /jellyfin/jellyfin-web/manifest.*.json /jellyfin/jellyfin-web/manifest.json 2>/dev/null || true
    fi
    
    # Temp fix for tmp folder requirement
    mkdir -p /tmp/jellyfin
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
    apply_temp_fixes
    echo "$(date '+%H:%M:%S') - Temp fixes applied"
} &

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
