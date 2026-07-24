#!/usr/bin/env bash

set -e

target="${1:-release}"

export ARCHS='arm64 x86_64'
export BUILD_UNIVERSAL=1

# octagram 八股文语法模型数据：master=配置(grammar.yaml)，@hans=简体 gram(zh-hans-t-essay-bgw.gram, 9MB)，
# @hant=繁体 gram。Famo 默认 rime_ice 为简体，必须含 @hans（Squirrel 原默认仅 hant，繁体倾向遗留）。
export SQUIRREL_BUNDLED_RECIPES='
  lotem/rime-octagram-data
  lotem/rime-octagram-data@hans
  lotem/rime-octagram-data@hant
'

# preinstall
./action-install.sh

# build dependencies
# make deps

# build Squirrel
make "${target}"

echo 'Installer package:'
find package -type f -name '*.pkg' -or -name '*.zip'
