#!/bin/bash
set -e

echo "Debugging information:"
echo "Contents of /etc/environment:"
cat /etc/environment

# Get the plugin version from environment file with fallback
if ! PLUGIN_VERSION=$(grep -oP 'PLUGIN_VERSION=\K.*' /etc/environment); then
    echo "Error: Could not extract PLUGIN_VERSION from /etc/environment"
    exit 1
fi

if [ -z "$PLUGIN_VERSION" ]; then
    echo "Error: PLUGIN_VERSION is empty"
    exit 1
fi

echo "PLUGIN_VERSION: ${PLUGIN_VERSION}"

# Verify source directory and DLL exist
SOURCE_DIR="/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}"
DLL_FILE="${SOURCE_DIR}/Jellyfin.Plugin.RequestsAddon.dll"

if [ ! -f "$DLL_FILE" ]; then
    echo "Error: DLL file not found at ${DLL_FILE}"
    echo "Available files in source directory:"
    ls -la "${SOURCE_DIR}"
    exit 1
fi

# Create target directory
TARGET_DIR="/config/plugins/RequestsAddon_${PLUGIN_VERSION}"
mkdir -p "${TARGET_DIR}"

echo "Copying plugin DLL..."
cp -v "${DLL_FILE}" "${TARGET_DIR}/"
chown root:root "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
chmod 755 "${TARGET_DIR}/Jellyfin.Plugin.RequestsAddon.dll"
echo "RequestsAddon plugin DLL version ${PLUGIN_VERSION} installed or updated."

echo "Final contents of plugin directory:"
ls -l "${TARGET_DIR}"

exec "$@"