#!/bin/bash
set -e

# Global variables
MEILI_PID=""

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
    
    # Get plugin versions from the build
    local customtabs_version=$(grep -oP 'CUSTOMTABS_VERSION=\K.*' /etc/environment 2>/dev/null)
    local filetrans_version=$(grep -oP 'FILETRANS_VERSION=\K.*' /etc/environment 2>/dev/null)
    local enhanced_version=$(grep -oP 'ENHANCED_VERSION=\K.*' /etc/environment 2>/dev/null)
    local meilisearch_version=$(grep -oP 'MEILISEARCH_PLUGIN_VERSION=\K.*' /etc/environment 2>/dev/null)

    local all_success=true

    # Install CustomTabs (only if needed or if newer)
    if [ -n "$customtabs_version" ]; then
        local source_dir="/jellyfin/plugins/CustomTabs_${customtabs_version}"
        local target_dir="/config/plugins/CustomTabs_${customtabs_version}"
        local installed_version=$(get_installed_version "CustomTabs")
        
        if [ -n "$installed_version" ]; then
            if version_gt "$customtabs_version" "$installed_version"; then
                echo "$(date '+%H:%M:%S') - Newer CustomTabs version available ($customtabs_version > $installed_version), updating..."
                # Clean old versions
                rm -rf /config/plugins/CustomTabs_* 2>/dev/null || true
                
                if [ -d "$source_dir" ]; then
                    mkdir -p "${target_dir}"
                    cp -r "${source_dir}"/* "${target_dir}/"
                    chmod -R 755 "${target_dir}"
                    validate_meta_json "${target_dir}"
                    echo "$(date '+%H:%M:%S') - CustomTabs plugin updated to version $customtabs_version"
                else
                    echo "$(date '+%H:%M:%S') - Warning: CustomTabs plugin source not found at $source_dir"
                    all_success=false
                fi
            else
                echo "$(date '+%H:%M:%S') - CustomTabs plugin version $installed_version already installed (>= $customtabs_version), skipping..."
            fi
        else
            echo "$(date '+%H:%M:%S') - Installing CustomTabs plugin version: $customtabs_version"
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                validate_meta_json "${target_dir}"
                echo "$(date '+%H:%M:%S') - CustomTabs plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: CustomTabs plugin not found at $source_dir"
                all_success=false
            fi
        fi
    fi

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

    # Install Enhanced (only if needed or if newer)
    if [ -n "$enhanced_version" ]; then
        local source_dir="/jellyfin/plugins/Enhanced_${enhanced_version}"
        local target_dir="/config/plugins/Enhanced_${enhanced_version}"
        local installed_version=$(get_installed_version "Enhanced")
        
        if [ -n "$installed_version" ]; then
            if version_gt "$enhanced_version" "$installed_version"; then
                echo "$(date '+%H:%M:%S') - Newer Enhanced version available ($enhanced_version > $installed_version), updating..."
                # Clean old versions
                rm -rf /config/plugins/Enhanced_* 2>/dev/null || true
                
                if [ -d "$source_dir" ]; then
                    mkdir -p "${target_dir}"
                    cp -r "${source_dir}"/* "${target_dir}/"
                    chmod -R 755 "${target_dir}"
                    validate_meta_json "${target_dir}"
                    echo "$(date '+%H:%M:%S') - Enhanced plugin updated to version $enhanced_version"
                else
                    echo "$(date '+%H:%M:%S') - Warning: Enhanced plugin source not found at $source_dir"
                    all_success=false
                fi
            else
                echo "$(date '+%H:%M:%S') - Enhanced plugin version $installed_version already installed (>= $enhanced_version), skipping..."
            fi
        else
            echo "$(date '+%H:%M:%S') - Installing Enhanced plugin version: $enhanced_version"
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                validate_meta_json "${target_dir}"
                echo "$(date '+%H:%M:%S') - Enhanced plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: Enhanced plugin not found at $source_dir"
                all_success=false
            fi
        fi
    fi

    # Install Meilisearch plugin (only if needed or if newer)
    if [ -n "$meilisearch_version" ]; then
        local source_dir="/jellyfin/plugins/Meilisearch_${meilisearch_version}"
        local target_dir="/config/plugins/Meilisearch_${meilisearch_version}"
        local installed_version=$(get_installed_version "Meilisearch")
        
        if [ -n "$installed_version" ]; then
            if version_gt "$meilisearch_version" "$installed_version"; then
                echo "$(date '+%H:%M:%S') - Newer Meilisearch plugin version available ($meilisearch_version > $installed_version), updating..."
                # Clean old versions
                rm -rf /config/plugins/Meilisearch_* 2>/dev/null || true
                
                if [ -d "$source_dir" ]; then
                    mkdir -p "${target_dir}"
                    cp -r "${source_dir}"/* "${target_dir}/"
                    chmod -R 755 "${target_dir}"
                    validate_meta_json "${target_dir}"
                    echo "$(date '+%H:%M:%S') - Meilisearch plugin updated to version $meilisearch_version"
                else
                    echo "$(date '+%H:%M:%S') - Warning: Meilisearch plugin source not found at $source_dir"
                    all_success=false
                fi
            else
                echo "$(date '+%H:%M:%S') - Meilisearch plugin version $installed_version already installed (>= $meilisearch_version), skipping..."
            fi
        else
            echo "$(date '+%H:%M:%S') - Installing Meilisearch plugin version: $meilisearch_version"
            
            if [ -d "$source_dir" ]; then
                mkdir -p "${target_dir}"
                cp -r "${source_dir}"/* "${target_dir}/"
                chmod -R 755 "${target_dir}"
                validate_meta_json "${target_dir}"
                echo "$(date '+%H:%M:%S') - Meilisearch plugin installed successfully"
            else
                echo "$(date '+%H:%M:%S') - Warning: Meilisearch plugin not found at $source_dir"
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

    # Add Enhanced repository if not present (check using full URL)
    local enhanced_repo_url="https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/10.11/manifest.json"
    if ! grep -qF "$enhanced_repo_url" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding Enhanced plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <Name>n00bcodr repo</Name>\n      <Url>'"$enhanced_repo_url"'</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    else
        echo "$(date '+%H:%M:%S') - Enhanced plugin repository already exists, skipping..."
    fi

    # Add IAmParadox repository if not present (check using full URL)
    local paradox_repo_url="https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
    if ! grep -qF "$paradox_repo_url" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding IAmParadox plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <Name>iamparadox repo</Name>\n      <Url>'"$paradox_repo_url"'</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    else
        echo "$(date '+%H:%M:%S') - IAmParadox plugin repository already exists, skipping..."
    fi

    # Add Meilisearch plugin repository if not present
    local meilisearch_repo_url="https://raw.githubusercontent.com/arnesacnussem/jellyfin-plugin-meilisearch/refs/heads/master/manifest.json"
    if ! grep -qF "$meilisearch_repo_url" "$system_xml"; then
        echo "$(date '+%H:%M:%S') - Adding Meilisearch plugin repository"
        sed -i 's|  </PluginRepositories>|    <RepositoryInfo>\n      <Name>Meilisearch Plugin</Name>\n      <Url>'"$meilisearch_repo_url"'</Url>\n      <Enabled>true</Enabled>\n    </RepositoryInfo>\n  </PluginRepositories>|' "$system_xml"
    else
        echo "$(date '+%H:%M:%S') - Meilisearch plugin repository already exists, skipping..."
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

# Function to apply temp fixes
apply_temp_fixes() {
    # Temp fix for webos
    if [ ! -f /jellyfin/jellyfin-web/manifest.json ]; then
        cp /jellyfin/jellyfin-web/manifest.*.json /jellyfin/jellyfin-web/manifest.json 2>/dev/null || true
    fi
    
    # Temp fix for tmp folder requirement
    mkdir -p /tmp/jellyfin
}

# Function to disable Meilisearch plugin
disable_meilisearch_plugin() {
    echo "$(date '+%H:%M:%S') - Disabling Meilisearch plugin..."
    
    # Find Meilisearch plugin directory
    local plugin_dir=$(find /config/plugins -maxdepth 1 -type d -name "Meilisearch_*" 2>/dev/null | head -n1)
    
    if [ -z "$plugin_dir" ]; then
        echo "$(date '+%H:%M:%S') - Meilisearch plugin not found in /config/plugins, skipping disable"
        return 0
    fi
    
    local meta_file="${plugin_dir}/meta.json"
    
    if [ ! -f "$meta_file" ]; then
        echo "$(date '+%H:%M:%S') - meta.json not found in $plugin_dir, skipping disable"
        return 0
    fi
    
    # Update status from Active to Disabled
    if python3 -c "
import json
with open('$meta_file', 'r') as f:
    data = json.load(f)
data['status'] = 'Disabled'
with open('$meta_file', 'w') as f:
    json.dump(data, f, indent=2)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        echo "$(date '+%H:%M:%S') - Meilisearch plugin disabled successfully"
    else
        echo "$(date '+%H:%M:%S') - Warning: Failed to disable Meilisearch plugin"
    fi
}

# Function to start Meilisearch
start_meilisearch() {
    echo "$(date '+%H:%M:%S') - Starting Meilisearch..."
    
    # Check if Meilisearch binary exists
    if [ ! -x /usr/local/bin/meilisearch ]; then
        echo "$(date '+%H:%M:%S') - WARNING: Meilisearch binary not found, skipping Meilisearch startup"
        disable_meilisearch_plugin
        return 0  # Return success so container doesn't fail
    fi
    
    # Create Meilisearch data and log directories
    mkdir -p "${MEILI_DB_PATH:-/config/meilisearch/data}"
    mkdir -p /config/log
    mkdir -p /config/ScheduledTasks
    
    # Copy Meilisearch scheduled task if it doesn't exist
    local task_file="/config/ScheduledTasks/c75bc4c1-e1c5-1364-0532-019143c0fb27.js"
    local task_source="/usr/share/jellyfin/scheduled-tasks/c75bc4c1-e1c5-1364-0532-019143c0fb27.js"
    if [ ! -f "$task_file" ] && [ -f "$task_source" ]; then
        cp "$task_source" "$task_file"
        echo "$(date '+%H:%M:%S') - Installed Meilisearch scheduled task (weekly indexing on Sunday)"
    fi
    
    # Test the binary first
    echo "$(date '+%H:%M:%S') - Testing Meilisearch binary..."
    if ! /usr/local/bin/meilisearch --version > /config/log/meilisearch.log 2>&1; then
        echo "$(date '+%H:%M:%S') - WARNING: Meilisearch binary test failed. Error output:"
        cat /config/log/meilisearch.log
        echo "$(date '+%H:%M:%S') - Continuing without Meilisearch..."
        disable_meilisearch_plugin
        return 0  # Return success so container doesn't fail
    fi
    echo "$(date '+%H:%M:%S') - Meilisearch binary OK: $(cat /config/log/meilisearch.log)"
    
    # Clear log for fresh start
    > /config/log/meilisearch.log
    
    # Start Meilisearch in background with full error capture
    echo "$(date '+%H:%M:%S') - Launching Meilisearch daemon..."
    
    # Check if we have a master key configured or stored
    local key_file="/config/meilisearch/.master_key"
    MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-}"
    
    if [ -z "$MEILI_MASTER_KEY" ]; then
        # Check if we have a previously generated key
        if [ -f "$key_file" ]; then
            MEILI_MASTER_KEY=$(cat "$key_file")
            echo "$(date '+%H:%M:%S') - Using stored Meilisearch master key"
        else
            # Generate a new key and store it
            MEILI_MASTER_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
            echo "$MEILI_MASTER_KEY" > "$key_file"
            chmod 600 "$key_file"
            echo "$(date '+%H:%M:%S') - Generated new Meilisearch master key"
        fi
    fi
    
    # Export the key so the Meilisearch plugin can use it
    export MEILI_MASTER_KEY
    
    /usr/local/bin/meilisearch \
        --db-path "${MEILI_DB_PATH:-/config/meilisearch/data}" \
        --http-addr 127.0.0.1:7700 \
        --env "${MEILI_ENV:-production}" \
        --master-key "$MEILI_MASTER_KEY" \
        --no-analytics \
        >> /config/log/meilisearch.log 2>&1 &
    MEILI_PID=$!
    
    echo "$(date '+%H:%M:%S') - Meilisearch started with PID: $MEILI_PID"
    
    # Wait for Meilisearch to be ready
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        # Check if process is still running
        if ! kill -0 "$MEILI_PID" 2>/dev/null; then
            echo "$(date '+%H:%M:%S') - WARNING: Meilisearch process died. Log output:"
            cat /config/log/meilisearch.log
            echo "$(date '+%H:%M:%S') - Continuing without Meilisearch..."
            MEILI_PID=""
            disable_meilisearch_plugin
            return 0  # Return success so container doesn't fail
        fi
        
        if curl -sf http://127.0.0.1:7700/health > /dev/null 2>&1; then
            echo "$(date '+%H:%M:%S') - Meilisearch is ready (PID: $MEILI_PID)"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    
    echo "$(date '+%H:%M:%S') - WARNING: Meilisearch failed to respond within ${max_attempts} seconds"
    echo "$(date '+%H:%M:%S') - Meilisearch log output:"
    cat /config/log/meilisearch.log
    echo "$(date '+%H:%M:%S') - Continuing without Meilisearch..."
    disable_meilisearch_plugin
    return 0  # Return success so container doesn't fail
}

# Function to stop Meilisearch gracefully
stop_meilisearch() {
    if [ -n "$MEILI_PID" ] && kill -0 "$MEILI_PID" 2>/dev/null; then
        echo "$(date '+%H:%M:%S') - Stopping Meilisearch (PID: $MEILI_PID)..."
        kill -TERM "$MEILI_PID" 2>/dev/null || true
        wait "$MEILI_PID" 2>/dev/null || true
        echo "$(date '+%H:%M:%S') - Meilisearch stopped"
    fi
}

# Trap to handle container shutdown
cleanup() {
    echo "$(date '+%H:%M:%S') - Received shutdown signal, cleaning up..."
    stop_meilisearch
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

# Start Meilisearch before Jellyfin
start_meilisearch

# Update marker file
touch "$CONTAINER_MARKER"

echo "$(date '+%H:%M:%S') - All setup operations completed"
echo "$(date '+%H:%M:%S') - Starting Jellyfin at $@..."

# Start Jellyfin
exec "$@"
