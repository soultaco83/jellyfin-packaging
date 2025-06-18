# Docker build arguments
ARG DOTNET_VERSION=8.0
ARG NODEJS_VERSION=20
ARG OS_VERSION=bookworm

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

# Install dependencies in a single layer with cache mount
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

# Copy package files first for better caching
COPY jellyfin-web/package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --unsafe-perm

# Copy source and build
COPY jellyfin-web .
RUN npm run build:production \
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

# Copy project files first for better caching
COPY jellyfin-server/*.sln ./
COPY jellyfin-server/*/*.csproj ./
RUN for file in $(ls *.csproj); do mkdir -p ${file%.*}/ && mv $file ${file%.*}/; done

# Restore dependencies with cache
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore --runtime linux-${DOTNET_ARCH}

# Copy source and build
COPY jellyfin-server .
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish Jellyfin.Server --arch ${DOTNET_ARCH} --configuration ${CONFIG} \
    --output="${ARTIFACT_DIR}" --self-contained --no-restore \
    -p:DebugSymbols=false -p:DebugType=none

#
# Download latest plugin release (cached)
#
FROM alpine:latest as plugin

# Install tools
RUN apk add --no-cache curl jq unzip

# Download and extract plugin with cache consideration
ARG BUILDKIT_INLINE_CACHE=1
RUN --mount=type=cache,target=/plugin-cache \
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/soultaco83/Jellyfin_requests_plugin/releases/latest | jq -r '.tag_name') \
 && echo "Latest plugin version: $LATEST_RELEASE" \
 && echo "PLUGIN_VERSION=$LATEST_RELEASE" > /plugin_version \
 && CACHE_FILE="/plugin-cache/plugin-${LATEST_RELEASE}.zip" \
 && if [ ! -f "$CACHE_FILE" ]; then \
        curl -L "https://github.com/soultaco83/Jellyfin_requests_plugin/releases/download/${LATEST_RELEASE}/Jellyfin.Plugin.RequestsAddon.zip" -o "$CACHE_FILE"; \
    fi \
 && mkdir -p "/plugin/RequestsAddon_${LATEST_RELEASE}" \
 && unzip "$CACHE_FILE" -d "/plugin/RequestsAddon_${LATEST_RELEASE}/"

#
# Base runtime dependencies (cached layer)
#
FROM --platform=linux/${TARGET_ARCH} ${IMAGE_ARCH}/debian:${OS_VERSION}-slim as runtime-base

ARG OS_VERSION
ARG PACKAGE_ARCH

# Install base system dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
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
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

#
# FFMPEG and Jellyfin repo setup (separate layer for caching)
#
FROM runtime-base as jellyfin-deps

ARG FFMPEG_PACKAGE
ARG PACKAGE_ARCH
ARG OS_VERSION

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-jellyfin.gpg \
 && echo "deb [arch=${PACKAGE_ARCH}] https://repo.jellyfin.org/master/debian ${OS_VERSION} main" > /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ${FFMPEG_PACKAGE} \
 && apt-get remove gnupg apt-transport-https --yes \
 && apt-get autoremove --yes

#
# Intel OpenCL dependencies (separate cached layer)
#
FROM jellyfin-deps as intel-deps

ARG GMMLIB_VER
ARG IGC2_VER
ARG IGC2_BUILD
ARG NEO_VER
ARG IGC1_LEGACY_VER
ARG NEO_LEGACY_VER

# Intel OpenCL runtime with cache
RUN --mount=type=cache,target=/intel-cache \
    mkdir -p /intel-compute-runtime && cd /intel-compute-runtime \
 && for file in \
    "libigdgmm12_${GMMLIB_VER}_amd64.deb" \
    "intel-igc-core-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb" \
    "intel-igc-opencl-2_${IGC2_VER}+${IGC2_BUILD}_amd64.deb" \
    "intel-opencl-icd_${NEO_VER}_amd64.deb" \
    "intel-igc-core_${IGC1_LEGACY_VER}_amd64.deb" \
    "intel-igc-opencl_${IGC1_LEGACY_VER}_amd64.deb" \
    "intel-opencl-icd-legacy1_${NEO_LEGACY_VER}_amd64.deb"; do \
        if [ ! -f "/intel-cache/$file" ]; then \
            case "$file" in \
                "libigdgmm12"*) curl -L -o "/intel-cache/$file" "https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/$file" ;; \
                "intel-igc-core-2"*|"intel-igc-opencl-2"*) curl -L -o "/intel-cache/$file" "https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC2_VER}/$file" ;; \
                "intel-opencl-icd_"*) curl -L -o "/intel-cache/$file" "https://github.com/intel/compute-runtime/releases/download/${NEO_VER}/$file" ;; \
                "intel-igc-core_"*|"intel-igc-opencl_"*) curl -L -o "/intel-cache/$file" "https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC1_LEGACY_VER}/$file" ;; \
                "intel-opencl-icd-legacy1"*) curl -L -o "/intel-cache/$file" "https://github.com/intel/compute-runtime/releases/download/${NEO_LEGACY_VER}/$file" ;; \
            esac; \
        fi; \
        cp "/intel-cache/$file" .; \
    done \
 && apt-get install --no-install-recommends --no-install-suggests -f -y ./*.deb \
 && cd .. && rm -rf /intel-compute-runtime

#
# Build the final combined image
#
FROM multiarch/qemu-user-static:x86_64-${QEMU_ARCH} as qemu
FROM intel-deps as combined

ARG DOTNET_ARCH
ARG PACKAGE_ARCH

# Copy the QEMU runtime
COPY --from=qemu /usr/bin/* /usr/bin

# Set the health URL
ENV HEALTHCHECK_URL=http://localhost:8096/health

# Default environment variables
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
    NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# Setup jemalloc with optimized linking
RUN mkdir -p /usr/lib/jellyfin \
 && case "${PACKAGE_ARCH}" in \
        "amd64") JEMALLOC_PATH="/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" ;; \
        "arm64") JEMALLOC_PATH="/usr/lib/aarch64-linux-gnu/libjemalloc.so.2" ;; \
        *) JEMALLOC_PATH="" ;; \
    esac \
 && if [ -n "$JEMALLOC_PATH" ] && [ -f "$JEMALLOC_PATH" ]; then \
        ln -s "$JEMALLOC_PATH" /usr/lib/jellyfin/libjemalloc.so.2 \
        && echo "jemalloc linked for ${PACKAGE_ARCH}"; \
    else \
        echo "WARNING: jemalloc not available for ${PACKAGE_ARCH}" >&2; \
    fi

# Set LD_PRELOAD only if jemalloc is available
ENV LD_PRELOAD=/usr/lib/jellyfin/libjemalloc.so.2

# Create directories
RUN mkdir -p ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && chmod 777 ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}

# Copy artifacts from build stages
COPY --from=server /server /jellyfin
COPY --from=web /web /jellyfin/jellyfin-web
COPY --from=plugin /plugin /jellyfin/plugins
COPY --from=plugin /plugin_version /etc/environment

# Set permissions
RUN chmod 777 -R ${JELLYFIN_WEB_DIR} \
 && chmod -R 755 /jellyfin/plugins

# Copy the entrypoint script
COPY docker/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Verify plugin installation
RUN echo "Plugin setup verification:" \
 && ls -la /jellyfin/plugins \
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
