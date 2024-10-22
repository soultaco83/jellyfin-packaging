#!/bin/bash
set -e

echo "Debugging version information:"
echo "PLUGIN_VERSION from ENV: ${PLUGIN_VERSION}"
echo "Contents of /etc/environment:"
cat /etc/environment
echo "Contents of /etc/profile.d/plugin_version.sh:"
cat /etc/profile.d/plugin_version.sh

mkdir -p /config/plugins/RequestsAddon_${PLUGIN_VERSION}

echo "Copying plugin files..."
cp -Rv /jellyfin/plugins/RequestsAddon_${PLUGIN_VERSION}/* /config/plugins/RequestsAddon_${PLUGIN_VERSION}/
chown -R root:root /config/plugins/RequestsAddon_${PLUGIN_VERSION}
chmod -R 777 /config/plugins/RequestsAddon_${PLUGIN_VERSION}
echo "RequestsAddon plugin version ${PLUGIN_VERSION} installed or updated."

echo "Final contents of /config/plugins:"
ls -R /config/plugins

exec "$@"