## Third-Party Components

This Docker image includes the following third-party plugin:

### File Transformation Plugin
- **Author**: IAmParadox27
- **Repository**: https://github.com/IAmParadox27/jellyfin-plugin-file-transformation
- **License**: GPL-3.0
- **Version**: the newest release published by the upstream repository at image build time
- **Modifications**: None - the plugin is installed exactly as published by upstream

The plugin is downloaded from the upstream plugin repository manifest during the image build
(`docker/install-plugins.py`) and installed unmodified.

All plugins are used in compliance with their respective licenses.
