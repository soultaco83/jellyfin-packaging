#!/bin/bash
set -e

# Source the environment file to get the PLUGIN_VERSION
source /etc/environment

# Ensure the plugin directory exists
mkdir -p /config/plugins/RequestsAddon_${PLUGIN_VERSION}

# Copy the plugin files if they don't exist or if the image version is newer
if [ ! -f /config/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll ] || \
   [ "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" -nt "/config/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" ]; then
    cp -r /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/* /config/plugins/RequestsAddon_${PLUGIN_VERSION}/
    chown -R root:root /config/plugins/RequestsAddon_${PLUGIN_VERSION}
    chmod -R 755 /config/plugins/RequestsAddon_${PLUGIN_VERSION}
    echo "RequestsAddon plugin version ${PLUGIN_VERSION} installed or updated."
else
    echo "RequestsAddon plugin version ${PLUGIN_VERSION} is up to date."
fi

# Execute the main container command
exec "$@"
