#!/usr/bin/env python3

# build.py - Build packages in a Docker wrapper
#
# Part of the Jellyfin CI system
###############################################################################

from argparse import ArgumentParser
from datetime import datetime
from email.utils import format_datetime, localtime
from git import Repo
from os import getenv
import os.path
from packaging.version import Version
from subprocess import run, PIPE
import sys
from yaml import load, SafeLoader

# Determine top level directory of this repository ("jellyfin-packaging")
revparse = run(["git", "rev-parse", "--show-toplevel"], stdout=PIPE)
repo_root_dir = revparse.stdout.decode().strip()

# Base Docker commands
docker_build_cmd = "docker buildx build --progress=plain --no-cache"
docker_run_cmd = "docker run --rm"


def log(message):
    print(message, flush=True)


# Configuration loader
try:
    with open("build.yaml", encoding="utf-8") as fh:
        configurations = load(fh, Loader=SafeLoader)
except Exception as e:
    log(f"Error: Failed to find 'build.yaml' configuration: {e}")
    exit(1)


# Shared functions
def _determine_arch(build_type, build_arch, build_version):
    PACKAGE_ARCH = (
        configurations[build_type]["archmaps"][build_arch]["PACKAGE_ARCH"]
        if build_arch in configurations[build_type]["archmaps"].keys()
        else None
    )
    if PACKAGE_ARCH is None:
        raise ValueError(
            f"{build_arch} is not a valid {build_type} {build_version} architecture in {configurations[build_type]['archmaps'].keys()}"
        )
    else:
        return PACKAGE_ARCH

def _determine_framework_versions():
    # Prepare repo object for this repository
    this_repo = Repo(repo_root_dir)

    framework_args = dict()

    submodules = dict()
    for submodule in this_repo.submodules:
        if submodule.name in configurations["frameworks"].keys():
            for framework_arg in configurations["frameworks"][submodule.name].keys():
                framework_args[framework_arg] = None
                def sort_versions(input_dict):
                    return dict(sorted(input_dict.items(), key=lambda item: Version(str(item[1]))))
                for commit_hash in sort_versions(configurations["frameworks"][submodule.name][framework_arg]):
                    try:
                        commit = submodule.module().commit(commit_hash)
                        if commit in submodule.module().iter_commits('HEAD'):
                            framework_args[framework_arg] = configurations["frameworks"][submodule.name][framework_arg][commit_hash]
                    except ValueError:
                        continue

    log(f"Determined the following framework versions based on current HEAD values:")
    for k, v in framework_args.items():
        log(f"  * {k}: {v}")
    log("")

    return framework_args

def build_docker(
    jellyfin_version, build_type, build_arch, _build_version, local=False, debug=False
):
    """
    Build Docker images for one or all architectures and combining manifests
    """
    log("> Building Docker images...")

    if build_arch:
        log(f"NOTE: Building only for arch {build_arch}")

    # We build all architectures simultaneously to push a single tag, so no conditional checks
    architectures = configurations["docker"]["archmaps"].keys()

    if build_arch:
        if build_arch not in architectures:
            log(f"Error: Archtecture {build_arch} is not valid.")
            exit(1)
        else:
            architectures = [build_arch]

    # Set the dockerfile
    dockerfile = configurations[build_type]["dockerfile"]

    # Determine if this is a "latest"-type image (v in jellyfin_version) or not
    if "v" in jellyfin_version and not "rc" in jellyfin_version: 
        is_stable = True
        is_preview = False
    elif "rc" in jellyfin_version:
        is_stable = False
        is_preview = True
    else:
        is_stable = False
        is_preview = False

    jellyfin_version = jellyfin_version.replace("v", "")

    log(f"NOTE: Build type is {'stable' if is_stable else 'preview/unstable'} for version {jellyfin_version}")
    log("")

    # Set today's date in a convenient format for use as an image suffix
    date = datetime.now().strftime("%Y%m%d-%H%M%S")

    images_hub = list()
    images_ghcr = list()
    for _build_arch in architectures:
        log(f">> Building Docker image for {_build_arch}...")
        log("")

        # Get our ARCH variables from the archmaps
        PACKAGE_ARCH = configurations["docker"]["archmaps"][_build_arch]["PACKAGE_ARCH"]
        DOTNET_ARCH = configurations["docker"]["archmaps"][_build_arch]["DOTNET_ARCH"]
        QEMU_ARCH = configurations["docker"]["archmaps"][_build_arch]["QEMU_ARCH"]
        IMAGE_ARCH = configurations["docker"]["archmaps"][_build_arch]["IMAGE_ARCH"]
        TARGET_ARCH = configurations["docker"]["archmaps"][_build_arch]["TARGET_ARCH"]

        # Use a unique docker image name for consistency
        if is_stable or is_preview:
            imagename = f"{configurations['docker']['imagename']}:{jellyfin_version}-{_build_arch}.{date}"
        else:
            imagename = f"{configurations['docker']['imagename']}:{jellyfin_version}-{_build_arch}"

        # Clean up any existing qemu static image
        log(
            f">>> {docker_run_cmd} --privileged multiarch/qemu-user-static:register --reset"
        )
        os.system(
            f"{docker_run_cmd} --privileged multiarch/qemu-user-static:register --reset"
        )
        log("")

        # Prepare the list of build-args
        build_args = list()
        build_args.append(f"--build-arg PACKAGE_ARCH={PACKAGE_ARCH}")
        build_args.append(f"--build-arg DOTNET_ARCH={DOTNET_ARCH}")
        build_args.append(f"--build-arg QEMU_ARCH={QEMU_ARCH}")
        build_args.append(f"--build-arg IMAGE_ARCH={IMAGE_ARCH}")
        build_args.append(f"--build-arg TARGET_ARCH={TARGET_ARCH}")
        build_args.append(f"--build-arg JELLYFIN_VERSION={jellyfin_version}")
        build_args.append(f"--build-arg CONFIG={'Debug' if debug else 'Release'}")
        build_args.append(f"--build-arg OS_VERSION=bookworm")

        # Determine framework versions
        framework_versions = _determine_framework_versions()
        for arg in framework_versions.keys():
            if framework_versions[arg] is not None:
                build_args.append(
                    f"--build-arg {arg}={framework_versions[arg]}"
                )

        build_args = ' '.join(build_args)

        # Build the dockerfile
        log(
            f">>> {docker_build_cmd} {build_args} --file {repo_root_dir}/{dockerfile} --tag {imagename} {repo_root_dir}"
        )
        ret = os.system(
            f"{docker_build_cmd} {build_args} --file {repo_root_dir}/{dockerfile} --tag {imagename} {repo_root_dir}"
        )
        if ret > 0:
            exit(1)
        images_hub.append(imagename)

        if not local:
            os.system(f"docker image tag {imagename} ghcr.io/{imagename}")
            images_ghcr.append(f"ghcr.io/{imagename}")

        log("")

    if local:
        return

    if not getenv('DOCKER_USERNAME') or not getenv('DOCKER_TOKEN'):
        log("Warning: No DOCKER_USERNAME or DOCKER_TOKEN in environment; skipping manifest build and push (DockerHub and GHCR).")
        return

    def build_manifests(server, images):
        # Build the manifests
        log(f">> Building Docker manifests for {server}...")
        manifests = list()

        if is_stable or is_preview:
            log(">>> Building X.Y.Z dated version manifest...")
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:{jellyfin_version}.{date} {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:{jellyfin_version}.{date} {' '.join(images)}"
            )
            manifests.append(
                f"{server}/{configurations['docker']['imagename']}:{jellyfin_version}.{date}"
            )

        log(">>> Building X.Y.Z version manifest...")
        log(
            f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:{jellyfin_version} {' '.join(images)}"
        )
        os.system(
            f"docker manifest create {server}/{configurations['docker']['imagename']}:{jellyfin_version} {' '.join(images)}"
        )
        manifests.append(f"{server}/{configurations['docker']['imagename']}:{jellyfin_version}")

        if is_stable:
            # Build major-minor point version
            log(">>> Building X.Y version manifest...")
            manifest_version_xy = '.'.join(jellyfin_version.split('.')[0:2])
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:{manifest_version_xy} {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:{manifest_version_xy} {' '.join(images)}"
            )
            manifests.append(f"{server}/{configurations['docker']['imagename']}:{manifest_version_xy}")

            # Build major-only point version
            log(">>> Building X version manifest...")
            manifest_version_x = '.'.join(jellyfin_version.split('.')[0:1])
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:{manifest_version_x} {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:{manifest_version_x} {' '.join(images)}"
            )
            manifests.append(f"{server}/{configurations['docker']['imagename']}:{manifest_version_x}")

            log(">>> Building latest manifest...")
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:latest {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:latest {' '.join(images)}"
            )
            manifests.append(f"{server}/{configurations['docker']['imagename']}:latest")
        elif is_preview:
            log(">>> Building preview manifest...")
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:preview {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:preview {' '.join(images)}"
            )
            manifests.append(f"{server}/{configurations['docker']['imagename']}:preview")
        else:
            log(">>> Building unstable manifest...")
            log(
                f">>>> docker manifest create {server}/{configurations['docker']['imagename']}:unstable {' '.join(images)}"
            )
            os.system(
                f"docker manifest create {server}/{configurations['docker']['imagename']}:unstable {' '.join(images)}"
            )
            manifests.append(f"{server}/{configurations['docker']['imagename']}:unstable")

        return manifests

    # Log in to DockerHub
    os.system(
        f"docker login -u {getenv('DOCKER_USERNAME')} -p {getenv('DOCKER_TOKEN')} 2>&1"
    )

    # Push the images to DockerHub
    for image in images_hub:
        log(f">>> Pushing image {image} to DockerHub")
        log(f">>>> docker push {image} 2>&1")
        os.system(f"docker push {image} 2>&1")

    manifests_hub = build_manifests("docker.io", images_hub)

    # Push the images and manifests to DockerHub
    for manifest in manifests_hub:
        log(f">>> Pushing manifest {manifest} to DockerHub")
        log(f">>>> docker manifest push --purge {manifest} 2>&1")
        os.system(f"docker manifest push --purge {manifest} 2>&1")

    # Log out of DockerHub
    os.system("docker logout")

    # Log in to GHCR
    os.system(
        f"docker login -u {getenv('GHCR_USERNAME')} -p {getenv('GHCR_TOKEN')} ghcr.io 2>&1"
    )

    # Push the images to GHCR
    for image in images_ghcr:
        log(f">>> Pushing image {image} to GHCR")
        log(f">>>> docker push {image} 2>&1")
        os.system(f"docker push {image} 2>&1")

    manifests_ghcr = build_manifests("ghcr.io", images_ghcr)

    # Push the images and manifests to GHCR
    for manifest in manifests_ghcr:
        log(f">>> Pushing manifest {manifest} to GHCR")
        log(f">>>> docker manifest push --purge {manifest} 2>&1")
        os.system(f"docker manifest push --purge {manifest} 2>&1")

    # Log out of GHCR
    os.system("docker logout")

def usage():
    """
    Print usage information on error
    """
    log(f"{sys.argv[0]} JELLYFIN_VERSION BUILD_TYPE [BUILD_ARCH] [BUILD_VERSION]")
    log("  JELLYFIN_VERSION: The Jellyfin version being built")
    log("    * Stable releases should be tag names with a 'v' e.g. v10.9.0")
    log(
        "    * Unstable releases should be 'master' or a date-to-the-hour version e.g. 2024021600"
    )
    log("  BUILD_TYPE: The type of build to execute")
    log(f"    * Valid options are: {', '.join(configurations.keys())}")
    log("  BUILD_ARCH: The CPU architecture of the build")
    log("    * Valid options are: <empty> [portable/docker only], amd64, arm64")
    log("  BUILD_VERSION: A valid OS distribution version (.deb build types only)")


# Define a map of possible build functions from the YAML configuration
function_definitions = {
    "build_docker": build_docker,
    "build_nuget": build_nuget,
}


parser = ArgumentParser(
    prog='build.py',
    description='Jellyfin build automator',
    epilog='See "README.md" and "build.yaml" for the full details of what this tool can build at this time.',
)

parser.add_argument('jellyfin_version', help='The output version')
parser.add_argument('build_type', choices=configurations.keys(), help='The build platform')
parser.add_argument('build_arch', default=None, nargs='?', help='The build architecture')
parser.add_argument('build_version', default=None, nargs='?', help='The build release version [debian/ubuntu only]')
parser.add_argument('--local', action='store_true', help='Local build, do not generate manifests or push them [docker only]')
parser.add_argument('--debug', action='store_true', help='Debug build, set .NET to use Debug instead of Release')

args = parser.parse_args()

jellyfin_version = args.jellyfin_version
build_type = args.build_type
build_arch = args.build_arch
build_version = args.build_version

if build_type not in ["portable", "docker", "nuget"] and not build_arch:
    log(f"Error: You must specify an architecture for build platform {build_type}")
    exit(1)

# Autocorrect "master" to a dated version string
if jellyfin_version in ["auto", "master"]:
    jellyfin_version = datetime.now().strftime("%Y%m%d%H")
    log(f"NOTE: Autocorrecting 'master' version to {jellyfin_version}")

# Launch the builder function
function_definitions[configurations[build_type]["build_function"]](
    jellyfin_version, build_type, build_arch, build_version, local=args.local, debug=args.debug
)
