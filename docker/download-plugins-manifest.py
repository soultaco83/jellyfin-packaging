#!/usr/bin/env python3
"""
Smart Plugin Downloader for Jellyfin Docker Build
Queries manifest.json and downloads plugins built for the HIGHEST server version available
"""

import json
import urllib.request
import urllib.error
import zipfile
import os
import sys
from pathlib import Path

MANIFEST_URL = "https://www.iamparadox.dev/jellyfin/plugins/manifest.json"

def download_manifest():
    """Download and parse the manifest.json file"""
    print("=== Smart Plugin Downloader ===")
    print(f"Manifest URL: {MANIFEST_URL}")
    print()
    
    try:
        print(f"Fetching manifest from {MANIFEST_URL}...")
        with urllib.request.urlopen(MANIFEST_URL) as response:
            manifest = json.loads(response.read())
        print("✓ Manifest downloaded")
        print()
        return manifest
    except Exception as e:
        print(f"✗ Failed to download manifest: {e}")
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
        return None
    
    # Sort versions by targetAbi (descending)
    versions = plugin.get('versions', [])
    if not versions:
        print(f"  ✗ No versions found for plugin")
        return None
    
    sorted_versions = sorted(
        versions,
        key=lambda v: parse_version(v['targetAbi']),
        reverse=True
    )
    
    best = sorted_versions[0]
    print(f"  ✓ Found version {best['version']} for server {best['targetAbi']}")
    print(f"  Source: {best['sourceUrl']}")
    
    return best

def download_file(url, dest_path):
    """Download a file from URL to destination path"""
    try:
        with urllib.request.urlopen(url) as response:
            with open(dest_path, 'wb') as out_file:
                out_file.write(response.read())
        return True
    except Exception as e:
        print(f"  ✗ Download failed: {e}")
        return False

def install_plugin(manifest, plugin_name, guid, plugin_dir):
    """Download and install a plugin"""
    print()
    print(f"=== Installing {plugin_name} ===")
    
    version_info = get_highest_version(manifest, guid, plugin_name)
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
        
        # Store version in environment file
        var_name_map = {
            "FileTransformation": "FILETRANS_VERSION",
            "CustomTabs": "CUSTOMTABS_VERSION",
            "Enhanced": "ENHANCED_VERSION"
        }
        var_name = var_name_map.get(plugin_name, f"{plugin_name.upper()}_VERSION")
        
        with open('/etc/environment', 'a') as f:
            f.write(f"{var_name}={version}\n")
        
        print(f"  {var_name}={version} (built for Jellyfin {target_abi})")
        return True
        
    except Exception as e:
        print(f"  ✗ Extraction failed: {e}")
        if target_dir.exists():
            import shutil
            shutil.rmtree(target_dir)
        if os.path.exists(temp_zip):
            os.remove(temp_zip)
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
        
        with open('/etc/environment', 'a') as f:
            f.write(f"ENHANCED_VERSION={version}\n")
        
        os.remove(temp_zip)
        return True
        
    except Exception as e:
        print(f"  ✗ Failed to install Enhanced: {e}")
        return False

def main():
    # Get plugin directory from command line or use default
    plugin_dir = sys.argv[1] if len(sys.argv) > 1 else "/jellyfin/plugins"
    print(f"Plugin Directory: {plugin_dir}")
    print()
    
    # Create plugin directory
    Path(plugin_dir).mkdir(parents=True, exist_ok=True)
    
    # Download manifest
    manifest = download_manifest()
    if not manifest:
        print("✗ Cannot proceed without manifest")
        sys.exit(1)
    
    # Install plugins
    success_count = 0
    fail_count = 0
    
    plugins = [
        ("CustomTabs", "fbacd0b6-fd46-4a05-b0a4-2045d6a135b0"),
        ("FileTransformation", "5e87cc92-571a-4d8d-8d98-d2d4147f9f90"),
    ]
    
    for plugin_name, guid in plugins:
        if install_plugin(manifest, plugin_name, guid, plugin_dir):
            success_count += 1
        else:
            fail_count += 1
    
    # Install Enhanced separately
    if install_enhanced_plugin(plugin_dir):
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
