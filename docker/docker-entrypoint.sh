#!/bin/bash
set -e

# Ensure PLUGIN_VERSION is set
if [ -z "$PLUGIN_VERSION" ]; then
    export PLUGIN_VERSION=$(cat /plugin_version)
fi

echo "PLUGIN_VERSION: ${PLUGIN_VERSION}"

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