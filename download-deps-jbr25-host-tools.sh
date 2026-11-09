#!/bin/bash -e

# Downloads the build host tools, as opposed to target libraries. Expects to be
# run inside the Ubuntu container built from Dockerfile.jbr25_deps, via
# download-deps-jbr25-in-docker.sh.
#
# These are code generators invoked during the build, so they must be binaries
# that run on the build host rather than on the target. Every Linux JBR25 build
# uses the same copies.
#
# libwayland-bin provides wayland-scanner. The cross builds unpack it into a
# host-tools tree kept outside the sysroot, and the native x64 build unpacks it
# into its sysroot like any other amd64 package.
#
# glslang provides glslangValidator, which compiles the Vulkan shaders
# (src/java.desktop/share/glsl/vulkan) into SPIR-V for --with-vulkan. JBR runs
# it with --target-env vulkan1.2, which focal's glslang 8.13 does not support,
# and newer packaged builds need a newer glibc than the Ubuntu 14.04 CI hosts
# have. The builds therefore compile it from source (install_vulkan_shader_compiler
# in build-jetbrainsruntime-common.sh). The 11.1.0 source tarball is the one
# Ubuntu 21.04 shipped, fetched from Launchpad like wayland-protocols.

host_pkgs=$(
	echo \
		libwayland-bin
)

source $(dirname $0)/download-deps-jbr25-common.sh

# The caller bind-mounts toolchain/jdk/deps/jbr25 here.
deps_root=$(cd $(dirname $0)/../deps && pwd)
target_dir=$deps_root/linux_host_tools

rm -rf $target_dir
mkdir -p $target_dir/src
cd $target_dir

echo "Requested host packages: $host_pkgs"

wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/glslang/11.1.0-3build1/glslang_11.1.0.orig.tar.gz

apt-get download $(for p in $host_pkgs; do echo $p:amd64; done)
(cd src && apt-get source --download-only $host_pkgs)

share_sources "$target_dir/src" "$deps_root/linux_src"
write_deb_licenses
