#!/bin/bash
set -e

echo "Contents of /etc/environment:"
cat /etc/environment

source /etc/environment

echo "PLUGIN_VERSION: ${PLUGIN_VERSION}"

echo "Contents of /jellyfin/plugins:"
ls -R /jellyfin/plugins

echo "Searching for all .dll files in /jellyfin/plugins:"
find /jellyfin/plugins -name "*.dll"

echo "Checking for plugin at: /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll"
if [ -f "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll" ]; then
    echo "Plugin file exists in the source location."
    ls -l "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/Jellyfin.Plugin.RequestsAddon.dll"
else
    echo "Plugin file does not exist in the source location."
    echo "Contents of /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}:"
    ls -R "/jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}"
fi

mkdir -p /config/plugins/RequestsAddon_${PLUGIN_VERSION}

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

echo "Final contents of /config/plugins:"
ls -R /config/plugins

exec "$@"