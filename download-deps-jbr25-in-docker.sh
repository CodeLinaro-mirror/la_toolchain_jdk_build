#!/bin/bash -e

# Central entry point for downloading every dependency needed to hermetically
# build JBR25 on Linux.
#
# Usage:
#   download-deps-jbr25-in-docker.sh [target...]
#
# Targets:
#   host-tools   build host binaries used by the cross builds (wayland-scanner)
#   x64          linux-x86_64, glibc
#   arm64        linux-aarch64, glibc
#   all          all of the above (the default)
#
# References:
#   OpenJDK build intructions : https://github.com/openjdk/jdk/blob/master/doc/building.md
#   OpenJDK cross-compiling   : https://github.com/openjdk/jdk/blob/master/doc/building.md#cross-compiling
#   JBR build intructions: https://github.com/JetBrains/JetBrainsRuntime/tree/jbr25
#   Android Studio system requirements: https://developer.android.com/studio/install
#   libraries versions in Ununtu: https://distrowatch.com/table.php?distribution=ubuntu
#
# Android Studio should works with glibc 2.31, at the same time it is prefered to use latest wayland version (as it is under active development)
# Use 20.04 as a base because of glibc
#
# Layout produced under toolchain/jdk/deps/jbr25:
#
#   linux_src/           source packages, shared by every target
#   linux_host_tools/    amd64 packages that run on the build host
#   linux_x64/           amd64 packages
#   linux_arm64/         arm64 packages
#
# Each target directory has its own src/ whose entries are relative symlinks
# into linux_src. Source packages are architecture independent, so the targets
# would otherwise hold byte for byte identical copies of the same tarballs.
#
# One Ubuntu image serves every job: it has arm64 enabled as a foreign dpkg
# architecture, so it can download amd64 and arm64 packages alike.

top=$(realpath "$(dirname "$0")/../../..")
build_dir=$top/toolchain/jdk/build
deps_dir=$top/toolchain/jdk/deps/jbr25

ubuntu_image=jbr25-deps

targets=("$@")
if [ ${#targets[@]} -eq 0 ] || [ "${targets[0]}" = "all" ]; then
	targets=(host-tools x64 arm64)
fi

for t in "${targets[@]}"; do
	case "$t" in
	host-tools | x64 | arm64) ;;
	*)
		echo "Unknown target '$t'. Valid targets: host-tools x64 arm64 all" >&2
		exit 1
		;;
	esac
done

mkdir -p "$deps_dir"

# Runs one download script inside a container, with the whole jbr25 dependency
# directory mounted so the script can reach both its own target directory and
# the shared source tree.
#   $1 image, $2 script
function run_download_job() {
	local -r image="$1"
	local -r script="$2"
	(
		cd $top
		docker run \
			--rm \
			-v $build_dir:/home/build/build:ro \
			-v $deps_dir:/home/build/deps \
			-t \
			-e USER_ID=$(id -u) \
			-e GROUP_ID=$(id -g) \
			-w /home/build/build \
			"$image" \
			"./$script"
	)
}

echo "Building Ubuntu Docker image"
(cd $build_dir && docker build . -f Dockerfile.jbr25_deps -t $ubuntu_image)

for t in "${targets[@]}"; do
	case "$t" in
	host-tools)
		echo "Downloading build host tools"
		run_download_job $ubuntu_image download-deps-jbr25-host-tools.sh
		;;
	x64)
		echo "Downloading necessary dependencies to hermetically build JBR25 for linux-x86_64"
		run_download_job $ubuntu_image download-deps-jbr25-x64.sh
		;;
	arm64)
		echo "Downloading necessary dependencies to hermetically build JBR25 for linux-aarch64"
		run_download_job $ubuntu_image download-deps-jbr25-arm64.sh
		;;
	esac
done

# Drop source packages that no target references any more, which is what is
# left behind when a package list changes or a target is refreshed on its own.
echo "Pruning unreferenced source packages"
if [ -d "$deps_dir/linux_src" ]; then
	for f in "$deps_dir"/linux_src/*; do
		[ -e "$f" ] || continue
		name=$(basename "$f")
		referenced=
		for link in "$deps_dir"/*/src/"$name"; do
			if [ -L "$link" ]; then referenced=1; break; fi
		done
		if [ -z "$referenced" ]; then
			echo "  removing unreferenced $name"
			rm -f "$f"
		fi
	done
fi

echo "Downloading dependencies done."
