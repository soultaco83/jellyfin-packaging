# Docker build arguments
ARG DOTNET_VERSION=10.0
ARG NODEJS_VERSION=24

# Combined image version (Debian)
ARG OS_VERSION=trixie

# Jellyfin FFMPEG package
ARG FFMPEG_PACKAGE=jellyfin-ffmpeg8

# https://github.com/intel/vpl-gpu-rt/releases
ARG VPL_GPU_RT_VER=intel-onevpl-25.3.4

# https://github.com/intel/compute-runtime/releases
ARG GMMLIB_VER=22.10.0
# >= Gen12 graphics (current) - Battlemage requires these newer versions
ARG IGC2_VER=2.40.13
ARG IGC2_BUILD=22418
ARG NEO_VER=26.31.39395.13
# <= Gen11 graphics (legacy)
ARG IGC1_LEGACY_VER=1.0.17537.24
ARG NEO_LEGACY_VER=24.35.30872.36

# https://github.com/tsukumijima/libmali-rockchip
ARG MALI_PKG_VER=1.9-1_arm64
ARG MALI_PKG_TAG=v1.9-1-20260312-bd33ee2
ARG MALI_PKG_CFG=valhall-g610-g24p0-gbm

# Debian architecture (amd64, arm64, armhf), set by build script
ARG PACKAGE_ARCH
# Dotnet architeture (x64, arm64, arm), set by build script
ARG DOTNET_ARCH
# Base Image architecture (amd64, arm64v8, arm32v7), set by build script
ARG IMAGE_ARCH
# Target platform architecture (amd64, arm64/v8, arm/v7), set by build script
ARG TARGET_ARCH

# Jellyfin version
ARG JELLYFIN_VERSION

#
# Build the web artifacts
#
FROM node:${NODEJS_VERSION}-alpine AS web

ARG SOURCE_DIR=/src
ARG ARTIFACT_DIR=/web

ARG JELLYFIN_VERSION
ENV JELLYFIN_VERSION=${JELLYFIN_VERSION}

RUN apk add \
    autoconf \
    g++ \
    make \
    libpng-dev \
    gifsicle \
    alpine-sdk \
    automake \
    libtool \
    gcc \
    musl-dev \
    nasm \
    python3 \
    git \
 && git config --global --add safe.directory /jellyfin/jellyfin-web

WORKDIR ${SOURCE_DIR}
COPY jellyfin-web .

RUN npm ci --no-audit --unsafe-perm \
 && npm run build:production \
 && mv dist ${ARTIFACT_DIR}

#
# Build the server artifacts
#
FROM debian:${OS_VERSION}-slim AS server

ARG DOTNET_ARCH
ARG DOTNET_VERSION

ARG SOURCE_DIR=/src
ARG ARTIFACT_DIR=/server

ARG CONFIG=Release
ENV CONFIG=${CONFIG}

WORKDIR ${SOURCE_DIR}
COPY jellyfin-server .
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

# Apply any .patch files from the .forgejo/patches/ directory
# (e.g., adding the OriginalLanguage column migration)
RUN for patch in .forgejo/patches/*.patch .forgejo/patches/*/*.patch; do \
        [ -f "$patch" ] && echo "Applying $patch" && git apply "$patch" || true; \
    done

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    curl \
    ca-certificates \
    libicu76 \
 && curl -fsSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel ${DOTNET_VERSION} --install-dir /usr/local/bin

RUN dotnet publish Jellyfin.Server --arch ${DOTNET_ARCH} --configuration ${CONFIG} \
    --output="${ARTIFACT_DIR}" --self-contained \
    -p:DebugSymbols=false -p:DebugType=none

#
# Build the Moonfin web app (Flutter) for the Moonbase plugin
#
FROM debian:${OS_VERSION}-slim AS moonfin-web

ARG MOONFIN_WEB_REPO=http://10.10.10.220:3000/soultaco83/moonfin-core.git
ARG FLUTTER_VERSION=3.47.6

# Install the Flutter SDK (bundles the matching Dart SDK). Moonfin needs Flutter >= 3.47.
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ca-certificates curl git xz-utils \
 && curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      -o /tmp/flutter.tar.xz \
 && tar xf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz \
 && apt-get clean autoclean --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*
ENV PATH="/opt/flutter/bin:${PATH}"

WORKDIR /src
RUN git config --global --add safe.directory /src \
 && git clone --depth 1 ${MOONFIN_WEB_REPO} .
RUN flutter config --no-analytics \
 && flutter pub get \
 && flutter build web --wasm --release --base-href "/Moonfin/Web/"

#
# Build the Moonbase plugin (Jellyfin) from source, bundling the web app
#
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS moonbase

ARG MOONBASE_REPO=http://10.10.10.220:3000/soultaco83/Moonbase_Taco.git
ARG MOONBASE_VERSION=3.0.0.0

WORKDIR /src
RUN git config --global --add safe.directory /src \
 && git clone --depth 1 ${MOONBASE_REPO} .

# Bundle the Flutter web output into the plugin's frontend directory
COPY --from=moonfin-web /src/build/web/ ./Jellyfin/frontend/
COPY --from=moonfin-web /src/web/theme/ ./Jellyfin/frontend/theme/

RUN dotnet publish Jellyfin/backend/Moonfin.Server.csproj \
    -c Release \
    -o /plugin \
    -p:AssemblyVersion=${MOONBASE_VERSION} \
    -p:FileVersion=${MOONBASE_VERSION} \
    -p:Version=${MOONBASE_VERSION}

# Assemble the plugin folder: DLL + bundled dependencies + web assets + metadata
RUN mkdir -p /plugin/frontend \
 && cp -R Jellyfin/frontend/. /plugin/frontend/ \
 && printf '{\n  "category": "General",\n  "guid": "8c5d0e91-4f2a-4b6d-9e3f-1a7c8d9e0f2b",\n  "name": "Moonbase",\n  "version": "%s",\n  "targetAbi": "10.10.0.0",\n  "assemblies": ["Moonfin.Server.dll"]\n}\n' "${MOONBASE_VERSION}" > /plugin/meta.json

#
# Build the final combined image
#
FROM --platform=linux/${TARGET_ARCH} debian:${OS_VERSION}-slim AS combined

ARG OS_VERSION
ARG FFMPEG_PACKAGE

ARG VPL_GPU_RT_VER
ARG GMMLIB_VER
ARG IGC2_VER
ARG IGC2_BUILD
ARG NEO_VER
ARG IGC1_LEGACY_VER
ARG NEO_LEGACY_VER

ARG MALI_PKG_VER
ARG MALI_PKG_TAG
ARG MALI_PKG_CFG

ARG PACKAGE_ARCH

# Set the health URL
ENV HEALTHCHECK_URL=http://localhost:8096/health

# Default environment variables for the Jellyfin invocation
ENV DEBIAN_FRONTEND="noninteractive" \
    LC_ALL="en_US.UTF-8" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    JELLYFIN_DATA_DIR="/config" \
    JELLYFIN_CACHE_DIR="/cache" \
    JELLYFIN_CONFIG_DIR="/config/config" \
    JELLYFIN_LOG_DIR="/config/log" \
    JELLYFIN_WEB_DIR="/jellyfin/jellyfin-web" \
    JELLYFIN_FFMPEG="/usr/lib/jellyfin-ffmpeg/ffmpeg"

ENV JELLYFIN_PLUGIN_PATH="/usr/lib/jellyfin/plugins:${JELLYFIN_DATA_DIR}/plugins"

# required for fontconfig cache
ENV XDG_CACHE_HOME=${JELLYFIN_CACHE_DIR}

# https://github.com/dlemstra/Magick.NET/issues/707#issuecomment-785351620
ENV MALLOC_TRIM_THRESHOLD_=131072

# https://github.com/NVIDIA/nvidia-docker/wiki/Installation-(Native-GPU-Support)
ENV NVIDIA_VISIBLE_DEVICES="all"
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# Install dependencies:
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ca-certificates \
    gnupg \
    curl \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg \
 && cat <<EOF > /etc/apt/sources.list.d/jellyfin.sources
Types: deb
URIs: https://repo.jellyfin.org/master/debian
Suites: ${OS_VERSION}
Components: main
Architectures: ${PACKAGE_ARCH}
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ${FFMPEG_PACKAGE} \
    openssl \
    locales \
    libicu76 \
    libfontconfig1 \
    libfreetype6 \
    libjemalloc2 \
    libdrm2 \
    sqlite3 \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && apt-get remove gnupg apt-transport-https --yes \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# =============================================================================
# Intel VAAPI Media Driver via MediaStack for Battlemage (B570/B580)
# Downloads pre-built binaries from Intel's vpl-gpu-rt releases
# Note: gmmlib is installed later in the OpenCL section
# =============================================================================
RUN if test "${PACKAGE_ARCH}" = "amd64"; then \
    apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    curl \
    gzip \
    vainfo \
 && curl -L -o /tmp/MediaStack.tar.gz "https://github.com/intel/vpl-gpu-rt/releases/download/${VPL_GPU_RT_VER}/MediaStack.tar.gz" \
 # Extract - it's a double-compressed archive: .tar.gz contains .tar
 && cd /tmp \
 && gzip -d MediaStack.tar.gz \
 && tar -xf MediaStack.tar \
 && cd MediaStack \
 # Copy the iHD driver to jellyfin-ffmpeg's dri path
 && cp -v opt/intel/media/lib64/iHD_drv_video.so /usr/lib/jellyfin-ffmpeg/lib/dri/iHD_drv_video.so \
 # Cleanup
 && cd / \
 && rm -rf /tmp/MediaStack* \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/* \
 ; fi

# Intel VAAPI environment variables - ensure iHD driver is used
ENV LIBVA_DRIVER_NAME=iHD
ENV LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri

# Intel OpenCL Tone mapping dependencies:
# Note: This section installs compute runtime for OpenCL-based tone mapping
# The media driver above handles VAAPI encode/decode
# Also installs gmmlib which is required for Battlemage
RUN if test "${PACKAGE_ARCH}" = "amd64"; then \
    mkdir intel-compute-runtime \
 && cd intel-compute-runtime \
 && curl -LO https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/libigdgmm12_${GMMLIB_VER}_amd64.deb \
 && curl -LO https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC2_VER}/intel-igc-core-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb \
 && curl -LO https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC2_VER}/intel-igc-opencl-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb \
 && curl -LO https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/intel-opencl-icd_${NEO_VER}-0_amd64.deb \
 && curl -LO https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC1_LEGACY_VER}/intel-igc-core_${IGC1_LEGACY_VER}_amd64.deb \
 && curl -LO https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC1_LEGACY_VER}/intel-igc-opencl_${IGC1_LEGACY_VER}_amd64.deb \
 && curl -LO https://github.com/intel/compute-runtime/releases/download/${NEO_LEGACY_VER}/intel-opencl-icd-legacy1_${NEO_LEGACY_VER}_amd64.deb \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -f -y ./*.deb \
 && cd .. \
 && rm -rf intel-compute-runtime \
 # Copy gmmlib to jellyfin-ffmpeg lib path (required for Battlemage)
 && cp -L /usr/lib/x86_64-linux-gnu/libigdgmm.so.12 /usr/lib/jellyfin-ffmpeg/lib/libigdgmm.so.12 \
 && ln -sf libigdgmm.so.12 /usr/lib/jellyfin-ffmpeg/lib/libigdgmm.so \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/* \
 ; fi

# Rockchip RK3588 libmali OpenCL dependencies:
RUN if test "${PACKAGE_ARCH}" = "arm64"; then \
    mkdir libmali-rockchip \
 && cd libmali-rockchip \
 && curl -LO https://github.com/tsukumijima/libmali-rockchip/releases/download/${MALI_PKG_TAG}/libmali-${MALI_PKG_CFG}_${MALI_PKG_VER}.deb \
 && apt-get install --no-install-recommends --no-install-suggests -f -y ./*.deb \
 && cd .. \
 && rm -rf libmali-rockchip \
 ; fi \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Add fonts for East Asian subtitle rendering
RUN apt-get update --yes \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    fonts-wqy-zenhei \
    fonts-wqy-microhei \
    fonts-arphic-ukai \
    fonts-arphic-uming \
    fonts-noto-cjk \
    fonts-ipafont-mincho \
    fonts-ipafont-gothic \
    fonts-unfonts-core \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Setup jemalloc: link the library to a path owned by us to handle arch specific library paths
RUN mkdir -p /usr/lib/jellyfin \
  && JEMALLOC_LINKED=0 \
  && if [ "${PACKAGE_ARCH}" = "amd64" ]; then \
         if [ -f "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" ]; then \
             ln -s /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/jellyfin/libjemalloc.so.2 && JEMALLOC_LINKED=1; \
         fi; \
     elif [ "${PACKAGE_ARCH}" = "arm64" ]; then \
         if [ -f "/usr/lib/aarch64-linux-gnu/libjemalloc.so.2" ]; then \
             ln -s /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 /usr/lib/jellyfin/libjemalloc.so.2 && JEMALLOC_LINKED=1; \
         fi; \
     fi \
  && if [ "$JEMALLOC_LINKED" -eq 1 ]; then \
         echo "jemalloc library linked successfully for ${PACKAGE_ARCH}." ; \
     else \
         echo "WARNING: jemalloc library .so file not found for PACKAGE_ARCH ${PACKAGE_ARCH}. Either the arch is not supported or copy failed. LD_PRELOAD might not work as expected." >&2; \
     fi

# Set LD_PRELOAD to use the linked jemalloc library
ENV LD_PRELOAD=/usr/lib/jellyfin/libjemalloc.so.2

RUN mkdir -p ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && chmod 777 -R ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}

COPY --from=server /server /jellyfin
COPY --from=web /web /jellyfin/jellyfin-web

RUN chmod 777 -R ${JELLYFIN_WEB_DIR}

# Install bundled plugins (newest upstream release, highest targetAbi).
# Python is only needed for the download step and is removed afterwards.
COPY docker/install-plugins.py /tmp/install-plugins.py
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes python3 \
 && python3 /tmp/install-plugins.py "/jellyfin/plugins" \
 && apt-get remove --yes python3 \
 && apt-get autoremove --yes \
 && apt-get clean autoclean --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/* \
 && rm /tmp/install-plugins.py

# Bundle the custom Moonbase plugin (Moonbase_Taco). The entrypoint installs it
# into /config/plugins on first boot and upgrades over any older Moonbase build.
ARG MOONBASE_VERSION=3.0.0.0
COPY --from=moonbase /plugin /jellyfin/plugins/Moonbase_Taco_${MOONBASE_VERSION}
RUN echo "MOONBASE_VERSION=${MOONBASE_VERSION}" >> /etc/environment

# Copy entrypoint
COPY docker/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ARG JELLYFIN_VERSION
LABEL "org.opencontainers.image.source"="https://github.com/soultaco83/jellyfin-packaging"
LABEL "org.opencontainers.image.title"="Jellyfin with request"
LABEL "org.opencontainers.image.description"="The Free Software Media System"
LABEL "org.opencontainers.image.documentation"="https://jellyfin.org/docs/"
LABEL "org.opencontainers.image.version"="${JELLYFIN_VERSION}"
LABEL "org.opencontainers.image.url"="https://jellyfin.org"

EXPOSE 8096
VOLUME ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/jellyfin/jellyfin"]
HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
     CMD curl --noproxy 'localhost' -Lk -fsS "${HEALTHCHECK_URL}" || exit 1
