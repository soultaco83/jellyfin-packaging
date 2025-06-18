# Docker build arguments
ARG DOTNET_VERSION=8.0
ARG NODEJS_VERSION=20

# Updated to Debian 13 (trixie)
ARG OS_VERSION=trixie

# Jellyfin FFMPEG package
ARG FFMPEG_PACKAGE=jellyfin-ffmpeg7

# https://github.com/intel/compute-runtime/releases
ARG GMMLIB_VER=22.7.0
# >= Gen12 graphics (current)
ARG IGC2_VER=2.10.8
ARG IGC2_BUILD=18926
ARG NEO_VER=25.13.33276.16
# <= Gen11 graphics (legacy)
ARG IGC1_LEGACY_VER=1.0.17537.20
ARG NEO_LEGACY_VER=24.35.30872.22

# Debian architecture (amd64, arm64, armhf), set by build script
ARG PACKAGE_ARCH
# Dotnet architeture (x64, arm64, arm), set by build script
ARG DOTNET_ARCH
# QEMU architecture (x86_64, aarch64, arm), set by build script
ARG QEMU_ARCH
# Base Image architecture (amd64, arm64v8, arm32v7), set by build script
ARG IMAGE_ARCH
# Target platform architecture (amd64, arm64/v8, arm/v7), set by build script
ARG TARGET_ARCH

# Jellyfin version
ARG JELLYFIN_VERSION

#
# Build the web artifacts
#
FROM node:${NODEJS_VERSION}-alpine as web

ARG SOURCE_DIR=/src
ARG ARTIFACT_DIR=/web
ARG JELLYFIN_VERSION
ENV JELLYFIN_VERSION=${JELLYFIN_VERSION}

# Install all dependencies in one layer
RUN apk add --no-cache \
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

# Build web assets
RUN npm ci --no-audit --unsafe-perm \
 && npm run build:production \
 && mv dist ${ARTIFACT_DIR}

#
# Build the server artifacts
#
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-${OS_VERSION}-slim as server

ARG DOTNET_ARCH
ARG SOURCE_DIR=/src
ARG ARTIFACT_DIR=/server
ARG CONFIG=Release
ENV CONFIG=${CONFIG}
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

WORKDIR ${SOURCE_DIR}
COPY jellyfin-server .

# Build server in one step
RUN dotnet publish Jellyfin.Server --arch ${DOTNET_ARCH} --configuration ${CONFIG} \
    --output="${ARTIFACT_DIR}" --self-contained \
    -p:DebugSymbols=false -p:DebugType=none

#
# Download latest plugin release
#
FROM alpine:latest as plugin

RUN apk add --no-cache curl jq unzip

# Download and extract the latest plugin release
RUN LATEST_RELEASE=$(curl -s https://api.github.com/repos/soultaco83/Jellyfin_requests_plugin/releases/latest | jq -r '.tag_name') \
 && echo "Latest plugin version: $LATEST_RELEASE" \
 && echo "PLUGIN_VERSION=$LATEST_RELEASE" > /plugin_version \
 && curl -L "https://github.com/soultaco83/Jellyfin_requests_plugin/releases/download/${LATEST_RELEASE}/Jellyfin.Plugin.RequestsAddon.zip" -o /plugin.zip \
 && mkdir -p "/plugin/RequestsAddon_${LATEST_RELEASE}" \
 && unzip /plugin.zip -d "/plugin/RequestsAddon_${LATEST_RELEASE}/" \
 && ls -la "/plugin/RequestsAddon_${LATEST_RELEASE}/"

#
# Build the final combined image
#
FROM multiarch/qemu-user-static:x86_64-${QEMU_ARCH} as qemu
FROM --platform=linux/${TARGET_ARCH} ${IMAGE_ARCH}/debian:${OS_VERSION}-slim as combined

ARG OS_VERSION
ARG FFMPEG_PACKAGE
ARG GMMLIB_VER
ARG IGC2_VER
ARG IGC2_BUILD
ARG NEO_VER
ARG IGC1_LEGACY_VER
ARG NEO_LEGACY_VER
ARG PACKAGE_ARCH
ARG DOTNET_ARCH
ARG QEMU_ARCH

# Copy the QEMU runtime
COPY --from=qemu /usr/bin/* /usr/bin

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
    JELLYFIN_FFMPEG="/usr/lib/jellyfin-ffmpeg/ffmpeg" \
    JELLYFIN_PLUGIN_PATH="/usr/lib/jellyfin/plugins:${JELLYFIN_DATA_DIR}/plugins" \
    XDG_CACHE_HOME=${JELLYFIN_CACHE_DIR} \
    MALLOC_TRIM_THRESHOLD_=131072 \
    NVIDIA_VISIBLE_DEVICES="all" \
    NVIDIA_DRIVER_CAPABILITIES="compute,video,utility" \
    LD_PRELOAD=/usr/lib/jellyfin/libjemalloc.so.2

# Install base dependencies in one optimized layer
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ca-certificates \
    gnupg \
    curl \
    apt-transport-https \
    zip \
    cron \
    openssl \
    locales \
    libfontconfig1 \
    libfreetype6 \
    libjemalloc2 \
    sqlite3 \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-jellyfin.gpg \
 && echo "deb [arch=${PACKAGE_ARCH}] https://repo.jellyfin.org/master/debian ${OS_VERSION} main" > /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ${FFMPEG_PACKAGE} \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && apt-get remove gnupg apt-transport-https --yes \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Intel OpenCL Tone mapping dependencies (amd64 only)
RUN mkdir intel-compute-runtime \
 && cd intel-compute-runtime \
 && curl -L --parallel --parallel-immediate --parallel-max 7 \
    -O https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/libigdgmm12_${GMMLIB_VER}_amd64.deb \
    -O https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC2_VER}/intel-igc-core-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb \
    -O https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC2_VER}/intel-igc-opencl-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb \
    -O https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/intel-opencl-icd_${NEO_VER}_amd64.deb \
    -O https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC1_LEGACY_VER}/intel-igc-core_${IGC1_LEGACY_VER}_amd64.deb \
    -O https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC1_LEGACY_VER}/intel-igc-opencl_${IGC1_LEGACY_VER}_amd64.deb \
    -O https://github.com/intel/compute-runtime/releases/download/${NEO_LEGACY_VER}/intel-opencl-icd-legacy1_${NEO_LEGACY_VER}_amd64.deb \
 && apt-get install --no-install-recommends --no-install-suggests -f -y ./*.deb \
 && cd .. \
 && rm -rf intel-compute-runtime \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Setup jemalloc (amd64 only)
RUN mkdir -p /usr/lib/jellyfin \
 && if [ -f "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" ]; then \
        ln -s /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/jellyfin/libjemalloc.so.2; \
        echo "jemalloc library linked successfully for amd64."; \
    else \
        echo "WARNING: jemalloc library not found for amd64." >&2; \
    fi

# Create directories and copy artifacts
RUN mkdir -p ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && chmod 777 ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}

COPY --from=server /server /jellyfin
COPY --from=web /web /jellyfin/jellyfin-web
COPY --from=plugin /plugin /jellyfin/plugins
COPY --from=plugin /plugin_version /etc/environment

# Set permissions in one layer
RUN chmod 777 -R ${JELLYFIN_WEB_DIR} \
 && chmod -R 755 /jellyfin/plugins

# Copy the optimized entrypoint script
COPY docker/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Verify plugin installation
RUN echo "Contents of /jellyfin/plugins after setup:" \
 && ls -R /jellyfin/plugins \
 && echo "Plugin version:" \
 && cat /etc/environment

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
