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

# Function to get installed plugin version
get_installed_version() {
    local plugin_name=$1
    local installed_version=""
    
    # Find the highest version installed
    for dir in /config/plugins/${plugin_name}_*; do
        if [ -d "$dir" ]; then
            local dir_version="${dir##*/config/plugins/${plugin_name}_}"
            if [ -z "$installed_version" ] || version_gt "$dir_version" "$installed_version"; then
                installed_version="$dir_version"
            fi
        fi
    done
    
    echo "$installed_version"
}

# Function to validate and fix meta.json
validate_meta_json() {
    local plugin_dir="$1"
    local meta_file="${plugin_dir}/meta.json"
    
    if [ ! -f "$meta_file" ]; then
        echo "$(date '+%H:%M:%S') - Warning: meta.json not found in $plugin_dir"
        return 1
    fi
    
    # Check if category is empty or missing using python for reliable JSON parsing
    local category=$(python3 -c "import json; print(json.load(open('$meta_file')).get('category', ''))" 2>/dev/null)
    
    if [ -z "$category" ] || [ "$category" = "None" ]; then
        echo "$(date '+%H:%M:%S') - Warning: meta.json in $plugin_dir has empty category, setting to 'General'"
        python3 -c "
import json
with open('$meta_file', 'r') as f:
    data = json.load(f)
data['category'] = 'General'
with open('$meta_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
    fi
    
    return 0
}

# Function to setup plugins (simplified since plugins are now pre-downloaded)
setup_plugins() {
    echo "$(date '+%H:%M:%S') - Checking pre-installed plugins..."

    # Ensure plugin directory exists
    mkdir -p /config/plugins

    # Remove the legacy hand-built FileTransformation fork, it is superseded by
    # the upstream release bundled in the image
    if [ -d "/config/plugins/FileTransformation_Taco" ]; then
        echo "$(date '+%H:%M:%S') - Removing legacy FileTransformation_Taco plugin folder..."
        rm -rf /config/plugins/FileTransformation_Taco
    fi

    # Get plugin versions from the build
    local filetrans_version=$(grep -oP 'FILETRANSFORMATION_VERSION=\K.*' /etc/environment 2>/dev/null)

    local all_success=true

    # Install FileTransformation (only if needed or if newer)
    if [ -n "$filetrans_version" ]; then
        local source_dir="/jellyfin/plugins/FileTransformation_${filetrans_version}"
        local target_dir="/config/plugins/FileTransformation_${filetrans_version}"
        local installed_version=$(get_installed_version "FileTransformation")
        
        if [ -n "$installed_version" ]; then
            if version_gt "$filetrans_version" "$installed_version"; then
                echo "$(date '+%H:%M:%S') - Newer FileTransformation version available ($filetrans_version > $installed_version), updating..."
                # Clean old versions
                rm -rf /config/plugins/FileTransformation_* 2>/dev/null || true
                
                if [ -d "$source_dir" ]; then
                    mkdir -p "${target_dir}"
                    cp -r "${source_dir}"/* "${target_dir}/"
                    chmod -R 755 "${target_dir}"
                    validate_meta_json "${target_dir}"
                    echo "$(date '+%H:%M:%S') - FileTransformation plugin updated to version $filetrans_version"
                else
                    echo "$(date '+%H:%M:%S') - Warning: FileTransformation plugin source not found at $source_dir"
                    all_success=false
                fi
            else
                echo "$(date '+%H:%M:%S') - FileTransformation plugin version $installed_version already installed (>= $filetrans_version), skipping..."
            fi
        else
            echo "$(date '+%H:%M:%S') - Installing FileTransformation plugin version: $filetrans_version"
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                validate_meta_json "${target_dir}"
                echo "$(date '+%H:%M:%S') - FileTransformation plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: FileTransformation plugin not found at $source_dir"
                all_success=false
            fi
        fi
    fi

    # Install/upgrade the custom Moonbase plugin (Moonbase_Taco)
    local moonbase_version=$(grep -oP 'MOONBASE_VERSION=\K.*' /etc/environment 2>/dev/null)
    if [ -n "$moonbase_version" ]; then
        local mb_source_dir="/jellyfin/plugins/Moonbase_Taco_${moonbase_version}"
        local mb_target_dir="/config/plugins/Moonbase_Taco_${moonbase_version}"
        local mb_installed=$(get_installed_version "Moonbase_Taco")

        # Remove any catalog-installed Moonbase (its folder has no version suffix).
        if [ -d "/config/plugins/Moonbase" ]; then
            echo "$(date '+%H:%M:%S') - Removing catalog-installed Moonbase plugin (superseded by Moonbase_Taco)..."
            rm -rf /config/plugins/Moonbase
        fi

        if [ -n "$mb_installed" ]; then
            if version_gt "$moonbase_version" "$mb_installed"; then
                echo "$(date '+%H:%M:%S') - Newer Moonbase version available ($moonbase_version > $mb_installed), updating..."
                rm -rf /config/plugins/Moonbase_Taco_* 2>/dev/null || true
                if [ -d "$mb_source_dir" ]; then
                    mkdir -p "$mb_target_dir"
                    cp -r "$mb_source_dir"/* "$mb_target_dir/"
                    chmod -R 755 "$mb_target_dir"
                    validate_meta_json "$mb_target_dir"
                    echo "$(date '+%H:%M:%S') - Moonbase plugin updated to version $moonbase_version"
                else
                    echo "$(date '+%H:%M:%S') - Warning: Moonbase plugin source not found at $mb_source_dir"
                    all_success=false
                fi
            else
                echo "$(date '+%H:%M:%S') - Moonbase plugin version $mb_installed already installed (>= $moonbase_version), skipping..."
            fi
        else
            echo "$(date '+%H:%M:%S') - Installing Moonbase plugin version: $moonbase_version"
            if [ -d "$mb_source_dir" ]; then
                mkdir -p "$mb_target_dir"
                cp -r "$mb_source_dir"/* "$mb_target_dir/"
                chmod -R 755 "$mb_target_dir"
                validate_meta_json "$mb_target_dir"
                echo "$(date '+%H:%M:%S') - Moonbase plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: Moonbase plugin not found at $mb_source_dir"
                all_success=false
            fi
        fi
    fi

    if [ "$all_success" = false ]; then
        echo "$(date '+%H:%M:%S') - Warning: Some plugins failed to install. Container will continue but plugins may not work."
        return 1
    fi
    
    echo "$(date '+%H:%M:%S') - Plugin setup complete"
    return 0
}

# Function to update system.xml with plugin repositories
update_plugin_repositories() {
    local system_xml="/config/config/system.xml"
    
    # Wait for system.xml to exist (Jellyfin creates it on first run)
    if [ ! -f "$system_xml" ]; then
        echo "$(date '+%H:%M:%S') - system.xml not found yet, will be added on next restart after Jellyfin initializes"
        return 0
    fi

    echo "$(date '+%H:%M:%S') - Checking plugin repositories in system.xml..."
    
    # Check if PluginRepositories section exists
    if ! grep -q "<PluginRepositories>" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding PluginRepositories section to system.xml"
        # Insert before </ServerConfiguration> tag
        sed -i 's|</ServerConfiguration>|  <PluginRepositories>\n  </PluginRepositories>\n</ServerConfiguration>|' "$system_xml"
    fi

    # Add IAmParadox repository if not present (check using full URL)
    local paradox_repo_url="https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
    if ! grep -qF "$paradox_repo_url" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding IAmParadox plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <Name>iamparadox repo</Name>\n      <Url>'"$paradox_repo_url"'</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    else
        echo "$(date '+%H:%M:%S') - IAmParadox plugin repository already exists, skipping..."
    fi

    echo "$(date '+%H:%M:%S') - Plugin repositories configured"
}

#Temp Fix for Jellyseerr/Infuse/Swiftfin auth - https://github.com/jellyfin/jellyfin/issues/15730
enable_legacy_authorization() {
    local system_xml="/config/config/system.xml"
    if [ ! -f "$system_xml" ]; then
        echo "$(date '+%H:%M:%S') - system.xml not found yet, legacy authorization will be enabled on next restart"
        return 0
    fi
    echo "$(date '+%H:%M:%S') - Checking EnableLegacyAuthorization setting..."
    if grep -q "<EnableLegacyAuthorization>false</EnableLegacyAuthorization>" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - EnableLegacyAuthorization is false, enabling for third-party client compatibility..."
        sed -i 's|<EnableLegacyAuthorization>false</EnableLegacyAuthorization>|<EnableLegacyAuthorization>true</EnableLegacyAuthorization>|g' "$system_xml"
        echo "$(date '+%H:%M:%S') - EnableLegacyAuthorization set to true"
    elif grep -q "<EnableLegacyAuthorization>true</EnableLegacyAuthorization>" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - EnableLegacyAuthorization already enabled, skipping..."
    elif ! grep -q "<EnableLegacyAuthorization>" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - EnableLegacyAuthorization not found, adding it..."
        awk '/<\/ServerConfiguration>/ { print "  <EnableLegacyAuthorization>true</EnableLegacyAuthorization>" } { print }' "$system_xml" > "${system_xml}.tmp" && mv "${system_xml}.tmp" "$system_xml"
        echo "$(date '+%H:%M:%S') - EnableLegacyAuthorization added and set to true"
    fi
}

# Function to fix missing database columns before Jellyfin starts
fix_missing_db_columns() {
    # Check if sqlite3 is available
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "$(date '+%H:%M:%S') - sqlite3 not available, skipping DB column fixes"
        return 0
    fi

    # Fix columns on all database files that exist
    for db_path in /config/data/jellyfin.db /config/data/library.db; do
        if [ ! -f "$db_path" ]; then
            continue
        fi

        echo "$(date '+%H:%M:%S') - Checking DB: $db_path for missing columns..."

        # Add IsOriginal column to MediaStreamInfos if table exists and column is missing
        if sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name='MediaStreamInfos';" 2>/dev/null | grep -q 'MediaStreamInfos'; then
            if ! sqlite3 "$db_path" "PRAGMA table_info('MediaStreamInfos');" 2>/dev/null | grep -q 'IsOriginal'; then
                echo "$(date '+%H:%M:%S') - Adding missing IsOriginal column to MediaStreamInfos in $(basename "$db_path")..."
                sqlite3 "$db_path" "ALTER TABLE \"MediaStreamInfos\" ADD COLUMN \"IsOriginal\" INTEGER NOT NULL DEFAULT 0;" 2>/dev/null && \
                    echo "$(date '+%H:%M:%S') - IsOriginal column added successfully" || \
                    echo "$(date '+%H:%M:%S') - Warning: Failed to add IsOriginal column"
            fi
        fi

        # Add OriginalLanguage column to BaseItems if table exists and column is missing
        if sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name='BaseItems';" 2>/dev/null | grep -q 'BaseItems'; then
            if ! sqlite3 "$db_path" "PRAGMA table_info('BaseItems');" 2>/dev/null | grep -q 'OriginalLanguage'; then
                echo "$(date '+%H:%M:%S') - Adding missing OriginalLanguage column to BaseItems in $(basename "$db_path")..."
                sqlite3 "$db_path" "ALTER TABLE \"BaseItems\" ADD COLUMN \"OriginalLanguage\" TEXT NULL;" 2>/dev/null && \
                    echo "$(date '+%H:%M:%S') - OriginalLanguage column added successfully" || \
                    echo "$(date '+%H:%M:%S') - Warning: Failed to add OriginalLanguage column"
            fi
        fi
    done
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

# Trap to handle container shutdown
cleanup() {
    echo "$(date '+%H:%M:%S') - Received shutdown signal, cleaning up..."
    exit 0
}

trap cleanup SIGTERM SIGINT

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

# Setup plugins (this is critical and must complete before Jellyfin starts)
if ! setup_plugins; then
    echo "$(date '+%H:%M:%S') - CRITICAL: Plugin setup failed. Container will continue but plugins may not work."
fi

update_plugin_repositories
enable_legacy_authorization

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

# Fix any missing database columns before Jellyfin starts
echo "$(date '+%H:%M:%S') - Checking for missing database columns..."
fix_missing_db_columns

# Update marker file
touch "$CONTAINER_MARKER"

echo "$(date '+%H:%M:%S') - All setup operations completed"
echo "$(date '+%H:%M:%S') - Starting Jellyfin at $@..."

# Start Jellyfin
exec "$@"
