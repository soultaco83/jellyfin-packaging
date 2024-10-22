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

# Verify source directory exists
if [ ! -d "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}" ]; then
    echo "Error: Source directory /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION} does not exist"
    echo "Available directories in /jellyfin/plugins:"
    ls -la /jellyfin/plugins
    exit 1
fi

# Create directory with version
mkdir -p "/config/plugins/RequestsAddon_${PLUGIN_VERSION}"

echo "Copying plugin files..."
cp -Rv "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/"* "/config/plugins/RequestsAddon_${PLUGIN_VERSION}/"
chown -R root:root "/config/plugins/RequestsAddon_${PLUGIN_VERSION}"
chmod -R 777 "/config/plugins/RequestsAddon_${PLUGIN_VERSION}"
echo "RequestsAddon plugin version ${PLUGIN_VERSION} installed or updated."

echo "Final contents of /config/plugins:"
ls -R /config/plugins

exec "$@"