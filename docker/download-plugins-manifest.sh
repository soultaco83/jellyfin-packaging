#!/bin/bash
# Smart Plugin Downloader for Jellyfin Docker Build
# Queries manifest.json and downloads plugins built for the HIGHEST server version available

set -e

MANIFEST_URL="https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
PLUGIN_DIR=${1:-"/jellyfin/plugins"}

echo "=== Smart Plugin Downloader ==="
echo "Manifest URL: ${MANIFEST_URL}"
echo "Plugin Directory: ${PLUGIN_DIR}"
echo ""

# Function to download the manifest
download_manifest() {
    echo "Fetching manifest from ${MANIFEST_URL}..."
    if ! curl -s -f "${MANIFEST_URL}" -o /tmp/manifest.json; then
        echo "✗ Failed to download manifest"
        return 1
    fi
    echo "✓ Manifest downloaded"
    echo ""
}

# Function to get the version with the highest targetAbi for a given plugin GUID
get_highest_version() {
    local guid=$1
    local plugin_name=$2
    
    echo "  Searching manifest for plugin GUID: ${guid}"
    
    # Extract all versions for this plugin and sort by targetAbi (descending)
    local best_version=$(jq -r --arg guid "$guid" '
        .[] | select(.guid == $guid) | 
        .versions[] | 
        {
            version: .version,
            targetAbi: .targetAbi,
            sourceUrl: .sourceUrl,
            checksum: .checksum,
            timestamp: .timestamp
        } | 
        # Create a sortable version string (convert 10.11.2.0 to 010.011.002.000 for sorting)
        . + {sortKey: (.targetAbi | split(".") | map(tonumber) | map(tostring | ("000" + .)[-3:]) | join("."))}
    ' /tmp/manifest.json | jq -s 'sort_by(.sortKey) | reverse | .[0]')
    
    if [ -z "$best_version" ] || [ "$best_version" = "null" ]; then
        echo "  ✗ Plugin not found in manifest"
        return 1
    fi
    
    # Parse the JSON result
    local version=$(echo "$best_version" | jq -r '.version')
    local target_abi=$(echo "$best_version" | jq -r '.targetAbi')
    local source_url=$(echo "$best_version" | jq -r '.sourceUrl')
    local checksum=$(echo "$best_version" | jq -r '.checksum')
    
    echo "  ✓ Found version ${version} for server ${target_abi}"
    echo "  Source: ${source_url}"
    
    # Return the data as a JSON string for the caller
    echo "$best_version"
}

# Function to download and install a plugin
install_plugin() {
    local plugin_name=$1
    local guid=$2
    
    echo ""
    echo "=== Installing ${plugin_name} ==="
    
    # Get the highest version info
    local version_info=$(get_highest_version "$guid" "$plugin_name")
    if [ -z "$version_info" ] || [ "$version_info" = "null" ]; then
        echo "  ✗ Failed to find plugin in manifest"
        return 1
    fi
    
    local version=$(echo "$version_info" | jq -r '.version')
    local target_abi=$(echo "$version_info" | jq -r '.targetAbi')
    local source_url=$(echo "$version_info" | jq -r '.sourceUrl')
    
    # Download
    echo "  Downloading ${plugin_name} ${version} (for server ${target_abi})..."
    if ! curl -L -f "${source_url}" -o "/tmp/${plugin_name}.zip" 2>/dev/null; then
        echo "  ✗ Download failed"
        return 1
    fi
    
    # Extract
    local target_dir="${PLUGIN_DIR}/${plugin_name}_${version}"
    mkdir -p "${target_dir}"
    
    if unzip -q "/tmp/${plugin_name}.zip" -d "${target_dir}/"; then
        echo "  ✓ Installed to ${target_dir}"
        rm "/tmp/${plugin_name}.zip"
        
        # Store version in environment for entrypoint script
        local var_name
        if [ "$plugin_name" = "FileTransformation" ]; then
            var_name="FILETRANS_VERSION"
        elif [ "$plugin_name" = "CustomTabs" ]; then
            var_name="CUSTOMTABS_VERSION"
        elif [ "$plugin_name" = "Enhanced" ]; then
            var_name="ENHANCED_VERSION"
        else
            var_name="${plugin_name^^}_VERSION"
        fi
        
        echo "${var_name}=${version}" >> /etc/environment
        echo "  ${var_name}=${version} (built for Jellyfin ${target_abi})"
        
        return 0
    else
        echo "  ✗ Extraction failed"
        rm -rf "${target_dir}" "/tmp/${plugin_name}.zip"
        return 1
    fi
}

# Create plugin directory
mkdir -p "$PLUGIN_DIR"

# Download manifest
if ! download_manifest; then
    echo "✗ Cannot proceed without manifest"
    exit 1
fi

# Install plugins using their GUIDs from the manifest
SUCCESS_COUNT=0
FAIL_COUNT=0

# Custom Tabs
# GUID: fbacd0b6-fd46-4a05-b0a4-2045d6a135b0
if install_plugin "CustomTabs" "fbacd0b6-fd46-4a05-b0a4-2045d6a135b0"; then
    ((SUCCESS_COUNT++))
else
    ((FAIL_COUNT++))
fi

# File Transformation
# GUID: 5e87cc92-571a-4d8d-8d98-d2d4147f9f90
if install_plugin "FileTransformation" "5e87cc92-571a-4d8d-8d98-d2d4147f9f90"; then
    ((SUCCESS_COUNT++))
else
    ((FAIL_COUNT++))
fi

# For Enhanced, we need to query a different manifest
echo ""
echo "=== Installing Enhanced ==="
echo "  Note: Enhanced is from n00bcodr repo, not IAmParadox manifest"

# Get latest Enhanced from GitHub API instead
ENHANCED_VERSION=$(curl -s "https://api.github.com/repos/n00bcodr/jellyfin-enhanced/releases/latest" | jq -r '.tag_name')
if [ -n "$ENHANCED_VERSION" ] && [ "$ENHANCED_VERSION" != "null" ]; then
    echo "  Latest Enhanced version: ${ENHANCED_VERSION}"
    
    # Enhanced typically uses 10.11.0 builds
    ENHANCED_URL="https://github.com/n00bcodr/Jellyfin-Enhanced/releases/download/${ENHANCED_VERSION}/Jellyfin.Plugin.JellyfinEnhanced_10.11.0.zip"
    
    echo "  Downloading from: ${ENHANCED_URL}"
    if curl -L -f "${ENHANCED_URL}" -o /tmp/enhanced.zip 2>/dev/null; then
        mkdir -p "${PLUGIN_DIR}/Enhanced_${ENHANCED_VERSION}"
        if unzip -q /tmp/enhanced.zip -d "${PLUGIN_DIR}/Enhanced_${ENHANCED_VERSION}/"; then
            echo "  ✓ Installed to ${PLUGIN_DIR}/Enhanced_${ENHANCED_VERSION}"
            echo "ENHANCED_VERSION=${ENHANCED_VERSION}" >> /etc/environment
            rm /tmp/enhanced.zip
            ((SUCCESS_COUNT++))
        else
            echo "  ✗ Extraction failed"
            ((FAIL_COUNT++))
        fi
    else
        echo "  ✗ Download failed"
        ((FAIL_COUNT++))
    fi
else
    echo "  ✗ Failed to get latest version"
    ((FAIL_COUNT++))
fi

# Cleanup
rm -f /tmp/manifest.json

echo ""
echo "=== Installation Summary ==="
echo "Successful: ${SUCCESS_COUNT}"
echo "Failed: ${FAIL_COUNT}"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    echo "⚠ Warning: Some plugins failed to install"
    exit 0  # Don't fail the build, just warn
fi

echo "✓ All plugins installed successfully"
exit 0
