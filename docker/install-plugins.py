#!/usr/bin/env python3
"""
Install the third-party plugins bundled into the Jellyfin Docker image.

Strategy: always install the newest published build of every plugin, and for
that build pick the release variant with the highest targetAbi, i.e. the build
made for the newest Jellyfin server version the plugin supports.

The primary source is the upstream plugin repository manifest (the same
manifest the image registers in Jellyfin), because it carries the version, the
targetAbi and a checksum for every published build. If that manifest cannot be
reached, the newest GitHub release of the plugin is used instead.

Usage: install-plugins.py [PLUGIN_DIR] [ENVIRONMENT_FILE]
"""

import glob
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

MANIFEST_URL = "https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
GITHUB_LATEST_RELEASE_URL = "https://api.github.com/repos/{repo}/releases/latest"
GITHUB_ASSET_URL = "https://github.com/{repo}/releases/download/{tag}/{asset}"

HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; wget/1.21)"}

# Plugins bundled into the image.
#   directory: folder name inside the plugins directory, suffixed with the version
#   env_var:   written to /etc/environment so the entrypoint knows what to install
PLUGINS = (
    {
        "directory": "FileTransformation",
        "guid": "5e87cc92-571a-4d8d-8d98-d2d4147f9f90",
        "name": "File Transformation",
        "repo": "IAmParadox27/jellyfin-plugin-file-transformation",
        "env_var": "FILETRANSFORMATION_VERSION",
        "description": "Jellyfin plugin to intercept and transform web content without custom builds.",
        "overview": "Intercept and transform Jellyfin web files.",
        "category": "General",
    },
)

VERSION_PATTERN = re.compile(r"^\d+(?:\.\d+)*$")
ASSET_VERSION_PATTERN = re.compile(r"[Rr]elease-(\d+(?:\.\d+)*)\.zip$")


def parse_version(version_str):
    """Convert a version string into a comparable tuple of integers."""
    return tuple(int(part) for part in version_str.split("."))


def fetch_json(url, name):
    """Download and parse a JSON document."""
    print(f"=== Fetching {name} ===")
    print(f"URL: {url}")
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())


def download_file(url, destination):
    """Download a file to the given destination path."""
    print(f"  Downloading from: {url}")
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=300) as response:
        with open(destination, "wb") as out_file:
            shutil.copyfileobj(response, out_file)


def pick_newest_version(plugin_versions):
    """Newest version of a plugin and, for it, the build with the highest targetAbi."""
    candidates = [
        version
        for version in plugin_versions
        if VERSION_PATTERN.match(str(version.get("version", "")))
        and VERSION_PATTERN.match(str(version.get("targetAbi", "")))
    ]

    if not candidates:
        return None

    return max(
        candidates,
        key=lambda version: (
            parse_version(version["version"]),
            parse_version(version["targetAbi"]),
        ),
    )


def newest_release_variant(repo):
    """Fallback source: newest GitHub release, highest Release-<targetAbi>.zip asset."""
    release = fetch_json(
        GITHUB_LATEST_RELEASE_URL.format(repo=repo),
        f"latest release of {repo}",
    )

    candidates = [
        (match.group(1), asset)
        for asset in release.get("assets", [])
        for match in [ASSET_VERSION_PATTERN.search(asset["name"])]
        if match
    ]

    if not candidates:
        return None

    target_abi, asset = max(
        candidates,
        key=lambda candidate: parse_version(candidate[0]),
    )

    return {
        "version": release["tag_name"].lstrip("v"),
        "targetAbi": target_abi,
        "changelog": release.get("body") or "",
        "timestamp": release.get("published_at", ""),
        "checksum": None,
        "sourceUrl": GITHUB_ASSET_URL.format(
            repo=repo,
            tag=release["tag_name"],
            asset=asset["name"],
        ),
    }


def verify_checksum(path, checksum):
    """Verify the MD5 checksum published in the upstream manifest."""
    if not checksum:
        print("  No checksum published for this build, skipping verification")
        return True

    digest = hashlib.md5()  # noqa: S324 - the checksum comes from the upstream manifest
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)

    actual = digest.hexdigest().upper()
    expected = checksum.upper()
    if actual != expected:
        print(f"  ✗ Checksum mismatch (expected {expected}, got {actual})")
        return False

    print("  ✓ Checksum verified")
    return True


def find_image_file(target_dir, plugin_dir):
    """Find an image file in the plugin directory for imagePath."""
    for extension in ("*.png", "*.jpg", "*.jpeg", "*.svg", "*.gif"):
        matches = sorted(glob.glob(str(target_dir / extension)))
        if matches:
            # Report the path as it will exist inside the container at runtime
            return matches[0].replace(plugin_dir, "/config/plugins", 1)

    return ""


def write_meta_json(target_dir, plugin_metadata, version_info, plugin_dir):
    """Write the meta.json Jellyfin needs to load and manage the plugin."""
    meta = {
        "category": plugin_metadata.get("category") or "General",
        "changelog": version_info.get("changelog", ""),
        "description": plugin_metadata.get("description", ""),
        "guid": plugin_metadata.get("guid", ""),
        "name": plugin_metadata.get("name", ""),
        "overview": (
            plugin_metadata.get("overview") or plugin_metadata.get("description", "")
        ),
        "owner": plugin_metadata.get("owner", ""),
        "targetAbi": version_info.get("targetAbi", ""),
        "timestamp": version_info.get("timestamp", ""),
        "version": version_info.get("version", ""),
        "status": "Active",
        "autoUpdate": True,
        "imagePath": find_image_file(target_dir, plugin_dir),
        "assemblies": [],
    }

    try:
        with open(target_dir / "meta.json", "w", encoding="utf-8") as handle:
            json.dump(meta, handle, indent=2)
        print("  ✓ Created meta.json")
        return True
    except OSError as exception:
        print(f"  ✗ Failed to create meta.json: {exception}")
        return False


def install_plugin(plugin, manifest, plugin_dir, environment_file="/etc/environment"):
    """Download and install a single plugin from the upstream repository."""
    print()
    print(f"=== Installing {plugin['name']} ===")

    plugin_metadata = dict(plugin)
    version_info = None

    if manifest is not None:
        manifest_plugin = next(
            (entry for entry in manifest if entry.get("guid") == plugin["guid"]),
            None,
        )
        if manifest_plugin is None:
            print("  ✗ Plugin not found in the upstream manifest")
        else:
            plugin_metadata = manifest_plugin
            version_info = pick_newest_version(manifest_plugin.get("versions", []))

    if version_info is None:
        print("  Falling back to the newest GitHub release")
        try:
            version_info = newest_release_variant(plugin["repo"])
        except Exception as exception:  # pylint: disable=broad-except
            print(f"  ✗ Failed to fetch the newest release: {exception}")
            version_info = None

    if version_info is None:
        print(f"  ✗ No installable build found for {plugin['name']}")
        return False

    version = version_info["version"]
    target_abi = version_info["targetAbi"]
    print(f"  Newest build: {version} (built for Jellyfin {target_abi})")

    target_dir = Path(plugin_dir) / f"{plugin['directory']}_{version}"
    temp_zip = Path("/tmp") / f"{plugin['directory']}_{version}.zip"

    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    try:
        download_file(version_info["sourceUrl"], temp_zip)
    except Exception as exception:  # pylint: disable=broad-except
        print(f"  ✗ Download failed: {exception}")
        shutil.rmtree(target_dir, ignore_errors=True)
        return False

    if not verify_checksum(temp_zip, version_info.get("checksum")):
        os.remove(temp_zip)
        shutil.rmtree(target_dir, ignore_errors=True)
        return False

    with zipfile.ZipFile(temp_zip, "r") as zip_ref:
        zip_ref.extractall(target_dir)
    os.remove(temp_zip)

    if not write_meta_json(target_dir, plugin_metadata, version_info, plugin_dir):
        shutil.rmtree(target_dir, ignore_errors=True)
        return False

    with open(environment_file, "a", encoding="utf-8") as handle:
        handle.write(f"{plugin['env_var']}={version}\n")

    print(f"  {plugin['env_var']}={version}")
    print(f"  ✓ Installed to {target_dir}")
    return True


def main():
    plugin_dir = sys.argv[1] if len(sys.argv) > 1 else "/jellyfin/plugins"
    environment_file = sys.argv[2] if len(sys.argv) > 2 else "/etc/environment"
    print(f"Plugin Directory: {plugin_dir}")
    print(f"Environment File: {environment_file}")
    print()

    Path(plugin_dir).mkdir(parents=True, exist_ok=True)

    try:
        manifest = fetch_json(MANIFEST_URL, "IAmParadox manifest")
    except Exception as exception:  # pylint: disable=broad-except
        print(f"✗ Failed to download the upstream manifest: {exception}")
        manifest = None
        print("⚠ Falling back to the newest GitHub release of every plugin")

    success_count = 0
    fail_count = 0

    for plugin in PLUGINS:
        if install_plugin(plugin, manifest, plugin_dir, environment_file):
            success_count += 1
        else:
            fail_count += 1

    print()
    print("=== Installation Summary ===")
    print(f"Successful: {success_count}")
    print(f"Failed: {fail_count}")
    print()

    if fail_count > 0:
        print("⚠ Warning: Some plugins failed to install")
    else:
        print("✓ All plugins installed successfully")

    # Never fail the image build over a plugin download, the entrypoint logs it.
    sys.exit(0)


if __name__ == "__main__":
    main()
