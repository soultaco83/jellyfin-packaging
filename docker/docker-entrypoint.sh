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

# Function to setup plugins (simplified since plugins are now pre-downloaded)
setup_plugins() {
    echo "$(date '+%H:%M:%S') - Checking pre-installed plugins..."
    
    # Ensure plugin directory exists
    mkdir -p /config/plugins
    
    # Get plugin versions from the build
    local customtabs_version=$(grep -oP 'CUSTOMTABS_VERSION=\K.*' /etc/environment 2>/dev/null)
    local filetrans_version=$(grep -oP 'FILETRANS_VERSION=\K.*' /etc/environment 2>/dev/null)
    local enhanced_version=$(grep -oP 'ENHANCED_VERSION=\K.*' /etc/environment 2>/dev/null)

    local all_success=true

    # Install CustomTabs (only if needed)
    if [ -n "$customtabs_version" ]; then
        local source_dir="/jellyfin/plugins/CustomTabs_${customtabs_version}"
        local target_dir="/config/plugins/CustomTabs_${customtabs_version}"
        
        if [ -d "$target_dir" ] && [ -f "${target_dir}/Jellyfin.Plugin.CustomTabs.dll" ]; then
            echo "$(date '+%H:%M:%S') - CustomTabs plugin version $customtabs_version already installed, skipping..."
        else
            echo "$(date '+%H:%M:%S') - Installing CustomTabs plugin version: $customtabs_version"
            # Clean old versions
            rm -rf /config/plugins/CustomTabs_* 2>/dev/null || true
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                echo "$(date '+%H:%M:%S') - CustomTabs plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: CustomTabs plugin not found at $source_dir"
                all_success=false
            fi
        fi
    fi

    # Install FileTransformation (only if needed)
    if [ -n "$filetrans_version" ]; then
        local source_dir="/jellyfin/plugins/FileTransformation_${filetrans_version}"
        local target_dir="/config/plugins/FileTransformation_${filetrans_version}"
        
        if [ -d "$target_dir" ] && [ -f "${target_dir}/Jellyfin.Plugin.FileTransformation.dll" ]; then
            echo "$(date '+%H:%M:%S') - FileTransformation plugin version $filetrans_version already installed, skipping..."
        else
            echo "$(date '+%H:%M:%S') - Installing FileTransformation plugin version: $filetrans_version"
            # Clean old versions
            rm -rf /config/plugins/FileTransformation_* 2>/dev/null || true
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                echo "$(date '+%H:%M:%S') - FileTransformation plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: FileTransformation plugin not found at $source_dir"
                all_success=false
            fi
        fi
    fi

    # Install Enhanced (only if needed)
    if [ -n "$enhanced_version" ]; then
        local source_dir="/jellyfin/plugins/Enhanced_${enhanced_version}"
        local target_dir="/config/plugins/Enhanced_${enhanced_version}"
        
        if [ -d "$target_dir" ] && [ -f "${target_dir}/Jellyfin.Plugin.Enhanced.dll" ]; then
            echo "$(date '+%H:%M:%S') - Enhanced plugin version $enhanced_version already installed, skipping..."
        else
            echo "$(date '+%H:%M:%S') - Installing Enhanced plugin version: $enhanced_version"
            # Clean old versions
            rm -rf /config/plugins/Enhanced_* 2>/dev/null || true
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                echo "$(date '+%H:%M:%S') - Enhanced plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: Enhanced plugin not found at $source_dir"
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

    # Add Enhanced repository if not present (updated URL for 10.11)
    if ! grep -q "n00bcodr/jellyfin-plugins" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding Enhanced plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <n>n00bcodr repo</n>\n      <Url>https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/10.11/manifest.json</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    fi

    # Add IAmParadox repository if not present
    if ! grep -q "iamparadox.dev" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding IAmParadox plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <n>iamparadox repo</n>\n      <Url>https://www.iamparadox.dev/jellyfin/plugins/manifest.json</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    fi

    echo "$(date '+%H:%M:%S') - Plugin repositories configured"
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

# Setup plugins (this is critical and must complete before Jellyfin starts)
if ! setup_plugins; then
    echo "$(date '+%H:%M:%S') - CRITICAL: Plugin setup failed. Container will continue but plugins may not work."
fi

# Update plugin repositories in system.xml
update_plugin_repositories

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
