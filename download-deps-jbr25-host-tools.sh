#!/bin/bash -e

# Downloads the amd64 packages that provide build host tools, as opposed to
# target libraries. Expects to be run inside the Ubuntu container built from
# Dockerfile.jbr25_deps, via download-deps-jbr25-in-docker.sh.
#
# Currently this is just libwayland-bin, which provides wayland-scanner. That is
# a code generator invoked during the build, so it must be a binary that runs on
# the build host rather than on the target. Every Linux JBR25 build uses the
# same copy: the cross builds unpack it into a host-tools tree kept outside the
# sysroot, and the native x64 build unpacks it into its sysroot like any other
# amd64 package.

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

apt-get download $(for p in $host_pkgs; do echo $p:amd64; done)
(cd src && apt-get source --download-only $host_pkgs)

share_sources "$target_dir/src" "$deps_root/linux_src"
write_deb_licenses
