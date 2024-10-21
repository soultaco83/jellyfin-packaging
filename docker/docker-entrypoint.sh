#!/bin/bash
set -e

# Debug: Print the contents of /etc/environment
echo "Contents of /etc/environment:"
cat /etc/environment

# Source the environment file to get the PLUGIN_VERSION
source /etc/environment

echo "PLUGIN_VERSION: ${PLUGIN_VERSION}"

# Debug: List the contents of /jellyfin/plugins
echo "Contents of /jellyfin/plugins:"
ls -R /jellyfin/plugins
find /jellyfin/plugins -name "*.dll"

echo "Checking for plugin at: /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll"
if [ -f "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" ]; then
    echo "Plugin file exists in the source location."
else
    echo "Plugin file does not exist in the source location."
fi

# Ensure the plugin directory exists
mkdir -p /config/plugins/RequestsAddon_${PLUGIN_VERSION}

# Copy the plugin files if they don't exist or if the image version is newer
if [ ! -f /config/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll ] || \
   [ -f "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" ] && \
   [ "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" -nt "/config/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" ]; then
    echo "Copying plugin files..."
    cp -rv /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/* /config/plugins/RequestsAddon_${PLUGIN_VERSION}/
    chown -R root:root /config/plugins/RequestsAddon_${PLUGIN_VERSION}
    chmod -R 755 /config/plugins/RequestsAddon_${PLUGIN_VERSION}
    echo "RequestsAddon plugin version ${PLUGIN_VERSION} installed or updated."
else
    echo "RequestsAddon plugin version ${PLUGIN_VERSION} is up to date."
fi

# Debug: List the contents of /config/plugins
echo "Contents of /config/plugins:"
ls -R /config/plugins

# Execute the main container command
exec "$@"