#!/usr/bin/env bash

set -e

target="${1:-release}"

export ARCHS='arm64 x86_64'
export BUILD_UNIVERSAL=1

# NOTE: the private-era SQUIRREL_BUNDLED_RECIPES fetch of lotem/rime-octagram-data
# is retired — the grammar data ships without a redistribution license, so public
# builds and releases must not bundle it (finalize-release-bundle.py blocks *.gram).

# preinstall
./action-install.sh

# assemble the clean-room Rime seed the release bundle requires
make famo-seed

# build Squirrel
make "${target}"

echo 'Installer package:'
find package -type f -name '*.pkg' -or -name '*.zip'
