#!/bin/bash -e

# Downloads the arm64 dependencies needed to hermetically build JBR25 for
# linux-aarch64. Expects to be run inside the Ubuntu container built from
# Dockerfile.jbr25_deps, which has arm64 enabled as a foreign dpkg architecture
# pointing at ports.ubuntu.com, via download-deps-jbr25-in-docker.sh.
#
# This is the arm64 counterpart of download-deps-jbr25-x64.sh. The package list
# is deliberately kept in sync with that script so both targets link against the
# same set of libraries, with one difference: libc6/libgcc/libstdc++ are
# downloaded here as well. The x64 build takes them from the Ubuntu 14.04 debs
# in toolchain/jdk/deps to reach a glibc 2.19 floor, but Ubuntu 14.04 has no
# usable arm64 port, so linux-aarch64 settles on the focal glibc 2.31 floor
# instead.
#
# Build host tools are not listed here; see download-deps-jbr25-host-tools.sh.

# Packages taken for the target (arm64).
target_pkgs=$(
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
		libxkbcommon-dev \
		libxkbcommon-x11-0 \
		libxkbcommon0 \
		libxrandr-dev \
		libxrender-dev \
		libxrender1 \
		libxt-dev \
		libxtst-dev \
		linux-libc-dev
)

# Runtime libraries matching the -dev packages above.
#
# A Debian -dev package ships an unversioned .so symlink (libXtst.so) pointing
# at the versioned shared object (libXtst.so.6) that lives in the runtime
# package. Without the runtime package that symlink dangles, and the linker
# quietly falls back to the static archive from the -dev package instead. On
# x86_64 that still links; on aarch64 it fails outright with
#
#   relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol
#   '__stack_chk_guard'; recompile with -fPIC
#
# because those archives are not built as position independent code and cannot
# go into a shared library. So these are required, not merely nice to have.
#
# Only libraries that actually reach a link line need their runtime package.
# libXt, libXrandr, libICE, libSM and libpng deliberately have none: the build
# needs their headers (X11/Intrinsic.h and X11/extensions/Xrandr.h are checked
# by lib-x11.m4 and are fatal if missing) but never links them. libpng is
# bundled, and AC_PATH_XTRA's -lSM -lICE end up in X_PRE_LIBS, which this build
# does not AC_SUBST. Their unversioned .so symlinks dangle in the sysroot, which
# is harmless as long as nothing references them, and matches what the x64 build
# already does.
target_runtime_pkgs=$(
	echo \
		libcups2 \
		libcupsimage2 \
		libdbus-1-3 \
		libfontconfig1 \
		libxfixes3 \
		libxi6 \
		libxtst6
)

# Architecture independent packages ("Architecture: all"), which cannot be
# qualified with :arm64 because apt has no per-architecture candidate for them.
arch_independent_pkgs=$(
	echo \
		wayland-protocols \
		x11proto-dev
)

# C runtime and C++ standard library for the target. The x64 build sources these
# from the Ubuntu 14.04 debs; see the comment at the top of this file.
target_toolchain_pkgs=$(
	echo \
		libc6 \
		libc6-dev \
		libgcc-9-dev \
		libstdc++-9-dev
)

# Toolchain packages that are needed to link but whose code is never
# redistributed, so their source is not collected.
#
# libgcc-9-dev ships /usr/lib/gcc/aarch64-linux-gnu/9/libgcc_s.so as the linker
# script `GROUP ( libgcc_s.so.1 -lgcc )`, so libgcc_s.so.1 has to be present or
# even configure's "can the C compiler create executables" probe fails with
#
#   ld.lld: error: .../libgcc_s.so:4: unable to find libgcc_s.so.1
#
# libstdc++-9-dev's unversioned .so symlink needs libstdc++6 for the same
# reason. Neither library ends up in the shipped artifact: the build links both
# statically (--with-stdc++lib=static) and nothing in the JDK image has
# libgcc_s.so.1 or libstdc++.so.6 in its DT_NEEDED.
#
# Keeping them out of the source download matters because on focal both are
# built from the gcc-10 source package, which is an 87 MB tarball for code we
# do not ship. The statically linked libgcc.a and libstdc++.a that we do ship
# come from libgcc-9-dev and libstdc++-9-dev, whose gcc-9 source is collected.
target_toolchain_linkonly_pkgs=$(
	echo \
		libgcc-s1 \
		libstdc++6
)

source $(dirname $0)/download-deps-jbr25-common.sh

# The caller bind-mounts toolchain/jdk/deps/jbr25 here.
deps_root=$(cd $(dirname $0)/../deps && pwd)
target_dir=$deps_root/linux_arm64

rm -rf $target_dir
mkdir -p $target_dir/src
cd $target_dir

echo "Requested target packages: $target_pkgs $target_runtime_pkgs $target_toolchain_pkgs $target_toolchain_linkonly_pkgs"
echo "Requested architecture independent packages: $arch_independent_pkgs"

# Ubuntu 20.04 have too old version of wayland-protocols
# Directly download newer one separatelly
wget https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/wayland-protocols/1.45-1~ubuntu0.24.04.1/wayland-protocols_1.45.orig.tar.xz

apt-get download $(for p in $target_pkgs $target_runtime_pkgs $target_toolchain_pkgs $target_toolchain_linkonly_pkgs; do echo $p:arm64; done)
apt-get download $arch_independent_pkgs

# Source packages are architecture independent, so they are fetched once without
# an architecture qualifier. target_toolchain_linkonly_pkgs is excluded on
# purpose; see the comment on that list.
(cd src && apt-get source --download-only \
	$target_pkgs $target_runtime_pkgs $target_toolchain_pkgs $arch_independent_pkgs)

share_sources "$target_dir/src" "$deps_root/linux_src"
write_deb_licenses
