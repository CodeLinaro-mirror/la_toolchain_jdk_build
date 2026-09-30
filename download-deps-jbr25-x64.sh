#!/bin/bash -e

# Downloads the amd64 dependencies needed to hermetically build JBR25 for
# linux-x86_64. Expects to be run inside the Ubuntu container built from
# Dockerfile.jbr25_deps, via download-deps-jbr25-in-docker.sh.
#
# libwayland-bin is not listed here. wayland-scanner is a build host tool rather
# than a target library, so it is shared with the cross builds through
# download-deps-jbr25-host-tools.sh.

pkgs=$(
	echo \
		libasound2 \
		libasound2-dev \
		libcups2-dev \
		libcupsimage2-dev \
		libdbus-1-dev \
		libfontconfig1-dev \
		libfreetype6 \
		libfreetype6-dev \
		libpng-dev \
		libspeechd-dev \
		libspeechd2 \
		libwayland-client0 \
		libwayland-cursor0 \
		libwayland-dev \
		libx11-6 \
		libx11-dev \
		libxau-dev \
		libxau6 \
		libxcb1 \
		libxcb1-dev \
		libxdmcp-dev \
		libxdmcp6 \
		libxext-dev \
		libxext6 \
		libxfixes-dev \
		libxi-dev \
		libxi6 \
		libxkbcommon-dev \
		libxkbcommon-x11-0 \
		libxkbcommon0 \
		libxrandr-dev \
		libxrender-dev \
		libxrender1 \
		libxt-dev \
		libxtst-dev \
		libxtst6 \
		linux-libc-dev \
		wayland-protocols \
		x11proto-dev
)

source $(dirname $0)/download-deps-jbr25-common.sh

# The caller bind-mounts toolchain/jdk/deps/jbr25 here.
deps_root=$(cd $(dirname $0)/../deps && pwd)
target_dir=$deps_root/linux_x64

rm -rf $target_dir
mkdir -p $target_dir/src
cd $target_dir

echo "Requested packages: $pkgs"

# Ubuntu 20.04 have too old version of wayland-protocols
# Directly download newer one separatelly
wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/wayland-protocols/1.45-1~ubuntu0.24.04.1/wayland-protocols_1.45.orig.tar.xz

apt-get download $pkgs
(cd src && apt-get source --download-only $pkgs)

share_sources "$target_dir/src" "$deps_root/linux_src"
write_deb_licenses
