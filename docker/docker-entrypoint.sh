#!/bin/bash
set -e

# Always copy the plugin to the data directory
if [ -d "/usr/lib/jellyfin/plugins/RequestsAddon_"* ]; then
    PLUGIN_DIR=$(ls -d /usr/lib/jellyfin/plugins/RequestsAddon_* | head -n 1)
    mkdir -p ${JELLYFIN_DATA_DIR}/plugins
    cp -R $PLUGIN_DIR ${JELLYFIN_DATA_DIR}/plugins/
    echo "Plugin copied to ${JELLYFIN_DATA_DIR}/plugins/"
else
    echo "Plugin directory not found in /usr/lib/jellyfin/plugins/"
fi

# Execute the main container command
exec "$@"