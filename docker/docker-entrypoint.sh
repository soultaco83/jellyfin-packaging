#!/bin/bash
set -e

# Ensure the plugin is in the correct location
if [ -d "/usr/lib/jellyfin/plugins/RequestsAddon_"* ]; then
    PLUGIN_DIR=$(ls -d /usr/lib/jellyfin/plugins/RequestsAddon_* | head -n 1)
    mkdir -p ${JELLYFIN_DATA_DIR}/plugins
    cp -R $PLUGIN_DIR ${JELLYFIN_DATA_DIR}/plugins/
fi

# Execute the main container command
exec "$@"
