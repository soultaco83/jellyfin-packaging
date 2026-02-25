#!/usr/bin/env python3
"""
Smart Plugin Downloader for Jellyfin Docker Build
Queries manifest.json and downloads plugins built for the HIGHEST server version available
Generates meta.json files for proper plugin management
"""

import json
import urllib.request
import urllib.error
import zipfile
import os
import sys
import glob
from pathlib import Path

MANIFEST_URL = "https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
MEILISEARCH_MANIFEST_URL = "https://raw.githubusercontent.com/arnesacnussem/jellyfin-plugin-meilisearch/refs/heads/master/manifest.json"

HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; wget/1.21)"}

def download_manifest(url, name="manifest"):
    """Download and parse a manifest.json file"""
    print(f"=== Downloading {name} ===")
    print(f"URL: {url}")
    print()

    try:
        print(f"Fetching {name}...")
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req) as response:
            manifest = json.loads(response.read())
        print(f"✓ {name} downloaded")
        print()
        return manifest
    except Exception as e:
        print(f"✗ Failed to download {name}: {e}")
        return None

def parse_version(version_str):
    """Convert version string to tuple of integers for comparison"""
    return tuple(int(x) for x in version_str.split('.'))

def get_highest_version(manifest, guid, plugin_name):
    """Get the version with the highest targetAbi for a given plugin GUID"""
    print(f"  Searching manifest for plugin GUID: {guid}")
    
    # Find the plugin
    plugin = None
    for p in manifest:
        if p.get('guid') == guid:
            plugin = p
            break
    
    if not plugin:
        print(f"  ✗ Plugin not found in manifest")
        return None, None
    
    # Sort versions by targetAbi (descending)
    versions = plugin.get('versions', [])
    if not versions:
        print(f"  ✗ No versions found for plugin")
        return None, None
    
    sorted_versions = sorted(
        versions,
        key=lambda v: parse_version(v['targetAbi']),
        reverse=True
    )
    
    best = sorted_versions[0]
    print(f"  ✓ Found version {best['version']} for server {best['targetAbi']}")
    print(f"  Source: {best['sourceUrl']}")
    
    # Return both version info and plugin metadata
    return best, plugin

def download_file(url, dest_path):
    """Download a file from URL to destination path"""
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req) as response:
            with open(dest_path, 'wb') as out_file:
                out_file.write(response.read())
        return True
    except Exception as e:
        print(f"  ✗ Download failed: {e}")
        return False

def find_image_file(target_dir):
    """Find an image file in the plugin directory for imagePath"""
    image_extensions = ['*.png', '*.jpg', '*.jpeg', '*.svg', '*.gif']
    for ext in image_extensions:
        matches = glob.glob(str(target_dir / ext))
        if matches:
            # Return the path relative to /config/plugins
            return matches[0].replace('/jellyfin/plugins', '/config/plugins')
    return ""

def create_meta_json(target_dir, plugin_metadata, version_info, plugin_name):
    """Create meta.json file for the plugin"""
    
    # Find image file in the extracted plugin
    image_path = find_image_file(target_dir)
    
    meta = {
        "category": plugin_metadata.get('category', 'General'),
        "changelog": version_info.get('changelog', ''),
        "description": plugin_metadata.get('description', ''),
        "guid": plugin_metadata.get('guid', ''),
        "name": plugin_metadata.get('name', plugin_name),
        "overview": plugin_metadata.get('overview', ''),
        "owner": plugin_metadata.get('owner', ''),
        "targetAbi": version_info.get('targetAbi', '10.11.0.0'),
        "timestamp": version_info.get('timestamp', ''),
        "version": version_info.get('version', ''),
        "status": "Active",
        "autoUpdate": True,
        "imagePath": image_path,
        "assemblies": []
    }
    
    meta_path = target_dir / "meta.json"
    try:
        with open(meta_path, 'w') as f:
            json.dump(meta, f, indent=2)
        print(f"  ✓ Created meta.json")
        return True
    except Exception as e:
        print(f"  ✗ Failed to create meta.json: {e}")
        return False

def install_plugin(manifest, plugin_name, guid, plugin_dir, env_var_name=None):
    """Download and install a plugin"""
    print()
    print(f"=== Installing {plugin_name} ===")
    
    version_info, plugin_metadata = get_highest_version(manifest, guid, plugin_name)
    if not version_info:
        print(f"  ✗ Failed to find plugin in manifest")
        return False
    
    version = version_info['version']
    target_abi = version_info['targetAbi']
    source_url = version_info['sourceUrl']
    
    # Download
    print(f"  Downloading {plugin_name} {version} (for server {target_abi})...")
    temp_zip = f"/tmp/{plugin_name}.zip"
    
    if not download_file(source_url, temp_zip):
        return False
    
    # Extract
    target_dir = Path(plugin_dir) / f"{plugin_name}_{version}"
    target_dir.mkdir(parents=True, exist_ok=True)
    
    try:
        with zipfile.ZipFile(temp_zip, 'r') as zip_ref:
            zip_ref.extractall(target_dir)
        print(f"  ✓ Installed to {target_dir}")
        os.remove(temp_zip)
        
        # Create meta.json
        create_meta_json(target_dir, plugin_metadata, version_info, plugin_name)
        
        # Store version in environment file
        if env_var_name is None:
            var_name_map = {
                "FileTransformation": "FILETRANS_VERSION",
                "CustomTabs": "CUSTOMTABS_VERSION",
                "Enhanced": "ENHANCED_VERSION",
                "PluginPages": "PLUGINPAGES_VERSION",
                "Meilisearch": "MEILISEARCH_PLUGIN_VERSION"
            }
            env_var_name = var_name_map.get(plugin_name, f"{plugin_name.upper()}_VERSION")
        
        with open('/etc/environment', 'a') as f:
            f.write(f"{env_var_name}={version}\n")
        
        print(f"  {env_var_name}={version} (built for Jellyfin {target_abi})")
        return True
        
    except Exception as e:
        print(f"  ✗ Extraction failed: {e}")
        if target_dir.exists():
            import shutil
            shutil.rmtree(target_dir)
        if os.path.exists(temp_zip):
            os.remove(temp_zip)
        return False

def install_customtabs_plugin(plugin_dir):
    """Install CustomTabs plugin from soultaco83 repo (always latest release)"""
    print()
    print("=== Installing CustomTabs ===")
    print("  Note: CustomTabs is from soultaco83 repo for master branch compatibility")
    
    try:
        # Get latest release from GitHub API
        api_url = "https://api.github.com/repos/soultaco83/jellyfin-plugin-custom-tabs/releases/latest"
        print(f"  Fetching latest release from GitHub API...")
        
        with urllib.request.urlopen(api_url) as response:
            release_info = json.loads(response.read())
        
        release_tag = release_info['tag_name']
        print(f"  Latest release: {release_tag}")
        
        # Find the zip asset in the release
        download_url = None
        for asset in release_info.get('assets', []):
            if asset['name'].endswith('.zip'):
                download_url = asset['browser_download_url']
                print(f"  Found asset: {asset['name']}")
                break
        
        if not download_url:
            print("  ✗ No zip file found in release assets")
            return False
        
        # Use fixed version for consistency
        version = "1.0.0.0"
        
        print(f"  Version: {version}")
        print(f"  Downloading from: {download_url}")
        temp_zip = "/tmp/customtabs.zip"
        
        if not download_file(download_url, temp_zip):
            return False
        
        target_dir = Path(plugin_dir) / f"CustomTabs_{version}"
        target_dir.mkdir(parents=True, exist_ok=True)
        
        with zipfile.ZipFile(temp_zip, 'r') as zip_ref:
            zip_ref.extractall(target_dir)
        
        print(f"  ✓ Installed to {target_dir}")
        
        # Create meta.json for CustomTabs
        plugin_metadata = {
            "guid": "fbacd0b6-fd46-4a05-b0a4-2045d6a135b0",
            "name": "Custom Tabs",
            "description": "Allows adding custom tabs to the Jellyfin web interface.",
            "overview": "Add custom tabs to Jellyfin.",
            "owner": "soultaco83",
            "category": "General"
        }
        
        version_info = {
            "version": version,
            "targetAbi": "10.11.0.0",
            "changelog": "Soultaco83 change for master branch compatiblity",
            "timestamp": release_info.get('published_at', '')
        }
        
        create_meta_json(target_dir, plugin_metadata, version_info, "CustomTabs")
        
        with open('/etc/environment', 'a') as f:
            f.write(f"CUSTOMTABS_VERSION={version}\n")
        
        os.remove(temp_zip)
        return True
        
    except Exception as e:
        print(f"  ✗ Failed to install CustomTabs: {e}")
        return False

def install_enhanced_plugin(plugin_dir):
    """Install Enhanced plugin from n00bcodr repo"""
    print()
    print("=== Installing Enhanced ===")
    print("  Note: Enhanced is from n00bcodr repo, not IAmParadox manifest")
    
    try:
        # Get latest release from GitHub API
        api_url = "https://api.github.com/repos/n00bcodr/jellyfin-enhanced/releases/latest"
        with urllib.request.urlopen(api_url) as response:
            release_info = json.loads(response.read())
        
        version = release_info['tag_name']
        print(f"  Latest Enhanced version: {version}")
        
        # Enhanced typically uses 10.11.0 builds
        download_url = f"https://github.com/n00bcodr/Jellyfin-Enhanced/releases/download/{version}/Jellyfin.Plugin.JellyfinEnhanced_10.11.0.zip"
        
        print(f"  Downloading from: {download_url}")
        temp_zip = "/tmp/enhanced.zip"
        
        if not download_file(download_url, temp_zip):
            return False
        
        target_dir = Path(plugin_dir) / f"Enhanced_{version}"
        target_dir.mkdir(parents=True, exist_ok=True)
        
        with zipfile.ZipFile(temp_zip, 'r') as zip_ref:
            zip_ref.extractall(target_dir)
        
        print(f"  ✓ Installed to {target_dir}")
        
        # Create meta.json for Enhanced
        # Get changelog from release info
        changelog = release_info.get('body', '')
        
        plugin_metadata = {
            "guid": "f69e946a-4b3c-4e9a-8f0a-8d7c1b2c4d9b",
            "name": "Jellyfin Enhanced",
            "description": "A combination of the Jellyfin Enhanced and Jellyfin Elsewhere userscripts, providing a comprehensive set of tweaks and features for Jellyfin.",
            "overview": "Jellyfin Enhanced and Jellyfin Elsewhere for a better Jellyfin experience.",
            "owner": "n00bcodr",
            "category": "General"
        }
        
        version_info = {
            "version": version,
            "targetAbi": "10.11.0.0",
            "changelog": changelog,
            "timestamp": release_info.get('published_at', '')
        }
        
        create_meta_json(target_dir, plugin_metadata, version_info, "Enhanced")
        
        with open('/etc/environment', 'a') as f:
            f.write(f"ENHANCED_VERSION={version}\n")
        
        os.remove(temp_zip)
        return True
        
    except Exception as e:
        print(f"  ✗ Failed to install Enhanced: {e}")
        return False

def install_meilisearch_plugin(plugin_dir):
    """Install Meilisearch plugin from arnesacnussem repo"""
    print()
    print("=== Installing Meilisearch Plugin ===")
    print("  Note: Meilisearch plugin is from arnesacnussem repo")
    
    manifest = download_manifest(MEILISEARCH_MANIFEST_URL, "Meilisearch manifest")
    if not manifest:
        print("  ✗ Failed to download Meilisearch manifest")
        return False
    
    # Meilisearch plugin GUID
    guid = "974395db-b31d-46a2-bc86-ef9aa5ac04dd"
    
    return install_plugin(manifest, "Meilisearch", guid, plugin_dir, "MEILISEARCH_PLUGIN_VERSION")

def main():
    # Get plugin directory from command line or use default
    plugin_dir = sys.argv[1] if len(sys.argv) > 1 else "/jellyfin/plugins"
    print(f"Plugin Directory: {plugin_dir}")
    print()
    
    # Create plugin directory
    Path(plugin_dir).mkdir(parents=True, exist_ok=True)
    
    # Download main manifest
    manifest = download_manifest(MANIFEST_URL, "IAmParadox manifest")
    if not manifest:
        print("⚠ IAmParadox manifest unavailable — skipping FileTransformation and PluginPages")

    # Install plugins
    success_count = 0
    fail_count = 0

    # Plugins from IAmParadox manifest (CustomTabs removed - using soultaco83 repo instead)
    if manifest:
        plugins = [
            ("FileTransformation", "5e87cc92-571a-4d8d-8d98-d2d4147f9f90"),
            ("PluginPages", "5b6550fa-a014-4f4c-8a2c-59a43680ac6d")
        ]

        for plugin_name, guid in plugins:
            if install_plugin(manifest, plugin_name, guid, plugin_dir):
                success_count += 1
            else:
                fail_count += 1
    
    # Install CustomTabs from soultaco83 repo (master branch compatible)
    if install_customtabs_plugin(plugin_dir):
        success_count += 1
    else:
        fail_count += 1
    
    # Install Enhanced separately (different repo)
    if install_enhanced_plugin(plugin_dir):
        success_count += 1
    else:
        fail_count += 1
    
    # Install Meilisearch plugin (different manifest)
    if install_meilisearch_plugin(plugin_dir):
        success_count += 1
    else:
        fail_count += 1
    
    # Summary
    print()
    print("=== Installation Summary ===")
    print(f"Successful: {success_count}")
    print(f"Failed: {fail_count}")
    print()
    
    if fail_count > 0:
        print("⚠ Warning: Some plugins failed to install")
        sys.exit(0)  # Don't fail the build, just warn
    
    print("✓ All plugins installed successfully")
    sys.exit(0)

if __name__ == "__main__":
    main()
