---
# Build definitions for `build.py`

# Upstream Framework versions
# This section defines target commits after which a particular framework is required.
# This is used by build.py to automatically determine which framework version to use
# within the build containers based on whatever HEAD the project is at (from checkout.py).
# Target commits should be a merge commit!
# Target commits should be in order from oldest to newest!
# HOW THIS WORKS:
#   For each submodule, and then for each upstream framework version ARG to Docker...
#   Provide a commit hash as a key, and a version as a value...
#   If the given commit is in the commit tree of the current HEAD of the repo...
#   Use the given version. Otherwise use the default.
frameworks:
  jellyfin-web:
    NODEJS_VERSION:
      6c0a64ef12b9eb40a7c4ee4b9d43d0a5f32f2287: 20  # Default
  jellyfin-server:
    DOTNET_VERSION:
      6d1abf67c36379f0b061095619147a3691841e21: 8.0  # Default
      ceb850c77052c465af8422dcf152f1d1d1530457: 9.0

# Docker images
docker:
  build_function: build_docker
  archmaps:
    amd64:
      DOTNET_ARCH: x64
      IMAGE_ARCH: amd64
      PACKAGE_ARCH: amd64
      QEMU_ARCH: x86_64
      TARGET_ARCH: amd64
  dockerfile: docker/Dockerfile
  imagename: soultaco83/jellyfin

# Nuget packages
nuget:
  build_function: build_nuget
  projects:
    - Jellyfin.Data/Jellyfin.Data.csproj
    - MediaBrowser.Common/MediaBrowser.Common.csproj
    - MediaBrowser.Controller/MediaBrowser.Controller.csproj
    - MediaBrowser.Model/MediaBrowser.Model.csproj
    - Emby.Naming/Emby.Naming.csproj
    - src/Jellyfin.Extensions/Jellyfin.Extensions.csproj
    - src/Jellyfin.Database/Jellyfin.Database.Implementations/Jellyfin.Database.Implementations.csproj
    - src/Jellyfin.MediaEncoding.Keyframes/Jellyfin.MediaEncoding.Keyframes.csproj
  feed_urls:
    stable: https://api.nuget.org/v3/index.json
    unstable: https://nuget.pkg.github.com/jellyfin/index.json
