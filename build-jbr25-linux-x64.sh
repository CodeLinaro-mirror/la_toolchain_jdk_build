#!/bin/bash
#
# Builds JBR25 for Linux
# Usage:
#   build-jb25-linux-x64.sh [-q]
# The JDK is built in OUT_DIR (or "out" if unset).
# The following artifacts are created in DIST_DIR (or "out/dist" if unset):
#   jdk.zip              archive of the JDK distribution
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise

source $(dirname $0)/build-jetbrainsruntime-common.sh

declare -r sources_dir="$top/external/jetbrains/JetBrainsRuntime25"
# TODO switch to JBR as boot jdk
declare -r boot_jdk="$top/prebuilts/jdk/studio/jbr25/linux/"
declare -r build_deps="$top/toolchain/jdk/deps/jbr25/linux_x64"
# Build host tools, shared with the aarch64 cross builds.
declare -r host_tools_deps="$top/toolchain/jdk/deps/jbr25/linux_host_tools"

echo "Building Linux JDK......."
echo "out_path=${out_path:-}"
echo "dist_dir=${dist_dir:-}"
echo "sysroot=${sysroot:-}"
echo "build_dir=${build_dir:-}"
echo "top=${top:-}"
echo "clang_bin=${clang_bin:-}"
echo "autoconf_dir=${autoconf_dir:-}"
echo "build_number=${build_number:-}"
echo "sources_dir=${sources_dir:-}"
echo "boot_jdk=${boot_jdk:-}"
echo "build_deps=${build_deps:-}"
echo "ldd --version:"

cat /etc/os-release
ldd --version

function dist_logs() {
	[[ -e "${build_dir}/build.log" ]] && cp "${build_dir}/build.log" "${dist_dir}/"
	[[ -e "${build_dir}/configure-support/config.log" ]] && cp "${build_dir}/configure-support/config.log" "${dist_dir}/"
}
trap dist_logs EXIT

if [ -f "$dist_dir"/jdk.zip ]; then
	echo "Re-using existing JDK $dist_dir/jdk.zip"
else
	declare -r jbr_tag="$(sed 's/^.*b//' "$sources_dir/build.txt")"
	SOURCE_DATE_EPOCH=$(source_date_epoch $sources_dir)

	# Most of dependencies are from Ubuntu 20.04
	# see download-deps-jbr25-x64.sh and Dockerfile.jbr25_deps
	unpack_dependencies "$sysroot" $build_deps/*.deb

	# wayland-scanner is a code generator that runs on the build host, so it is
	# shared with the cross builds rather than listed as a target dependency.
	# For this native build the build host is the target, so it can simply go
	# into the sysroot like any other amd64 package.
	unpack_dependencies "$sysroot" $host_tools_deps/*.deb

	# Ubuntu 20.04 have too old version of wayland-protocols
	# use separatelly downloaded 1.45 version
	declare -r wayland_protocols_path=$out_path/wayland_protocols && mkdir -p $wayland_protocols_path
	(
		cd "$wayland_protocols_path"
		tar -xf $build_deps/wayland-protocols_1.45.orig.tar.xz
		cp -r wayland-protocols-1.45/stable $sysroot/usr/share/wayland-protocols
		cp -r wayland-protocols-1.45/staging $sysroot/usr/share/wayland-protocols
		cp -r wayland-protocols-1.45/unstable $sysroot/usr/share/wayland-protocols
		cp -r wayland-protocols-1.45/experimental $sysroot/usr/share/wayland-protocols
	)

	# use gcc and standart lib from Ubuntu 14.04, to link final artifacts against glibc 2.19
	unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/libc6*.deb
	unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/libgcc*.deb
	unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/libstdc*.deb

	# configure wants that library binary without version suffix
	ln -s "$sysroot/usr/lib/x86_64-linux-gnu/libfreetype.so.6" "$sysroot/usr/lib/x86_64-linux-gnu/libfreetype.so"

	mkdir -p "$build_dir"
	(
		cd "$build_dir" &&
			PATH="$autoconf_dir/bin":$PATH bash +x "$sources_dir/configure" \
				"${quiet:+--quiet}" \
				--disable-warnings-as-errors \
				--build=x86_64-unknown-linux-gnu \
				--openjdk-target=x86_64-unknown-linux-gnu \
				--with-vendor-name="JetBrains s.r.o." \
				--with-vendor-vm-bug-url=https://youtrack.jetbrains.com/issues/JBR \
				--with-version-pre=$([ "$build_number" == "dev" ] && echo "dev" || echo "") \
				--without-version-build \
				--with-version-opt="$(numeric_build_number $build_number)-b$jbr_tag" \
				--disable-absolute-paths-in-output \
				--with-build-user=builder \
				--disable-full-docs \
				--with-libpng=bundled \
				--with-zlib=bundled \
				--with-native-debug-symbols=zipped \
				--with-debug-level=release \
				--enable-jvm-feature-cds \
				--disable-jvm-feature-epsilongc \
				--disable-jvm-feature-zgc \
				--disable-jvm-feature-dtrace \
				--with-boot-jdk="$boot_jdk" \
				--with-sysroot="$sysroot" \
				--with-stdc++lib=static \
				--with-toolchain-type=clang \
				--with-tools-dir="$clang_bin" \
				--with-toolchain-path="$clang_bin" \
				--with-freetype-include="$sources_dir/src/java.desktop/share/native/libfreetype/include" \
				--with-freetype-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
				--with-freetype=system \
				--with-alsa-include="$sysroot/usr/include" \
				--with-alsa-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
				--with-cups-include="$sysroot/usr/include" \
				--with-wayland-protocols="$sysroot/usr/share/wayland-protocols" \
				--with-dbus-includes="$sysroot/usr/include/dbus-1.0 $sysroot/usr/lib/x86_64-linux-gnu/dbus-1.0/include" \
				--with-extra-cflags="--sysroot=$sysroot" \
				--with-extra-cxxflags="--sysroot=$sysroot" \
				--with-extra-ldflags="--sysroot=$sysroot" \
				AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip CXXFILT=llvm-cxxfilt WAYLAND_SCANNER="$sysroot/usr/bin/wayland-scanner"
	)

	echo "Configure done"
	echo "Making images ...."

	declare -r make_log_level=${quiet:+warn}
	make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images

	rm -rf "$dist_dir"/{jdk.zip,jdk-debuginfo.zip,jdk-runtime.zip,build.log,configure.log}
	(
		cd "$build_dir/images/jdk"
		rm -rf demo
		rm -rf man
		zip -9rDy${quiet:+q} "$dist_dir"/jdk.zip . -x'*.diz'
		zip -9rDy${quiet:+q} "$dist_dir"/jdk-debuginfo.zip . -i'*.diz'
	)
fi

echo "Creating java runtime ...."
(
	rm -rf "${out_path}/java-runtime" && mkdir "${out_path}/java-runtime"
	cd "${out_path}/java-runtime"

	jbr_jdk_dir=$(make_target_dir "jdk")
	runtime_image_dir="${out_path}/java-runtime/image"
	unzip ${quiet:+-q} $dist_dir/jdk.zip -d $jbr_jdk_dir

	# 1. add studio modules to jb/project/tools/common/modules.list
	# 2. remove trailing comas, and remove duplicates
	# 3. JBR-3398 JDK-8263327 Remove the Experimental AOT and JIT Compiler
	# 4. trim, and convert lines to coma-separated list
	declare modules=$(
		cat ${sources_dir}/jb/project/tools/common/modules.list ${top}/toolchain/jdk/build/studio-modules.list |
			sed s/","/" "/g | sort | uniq |
			grep -v 'jdk.aot' |
			grep -v 'jdk.internal.vm.compiler' |
			grep -v 'jdk.internal.vm.compiler.management' |
			xargs | sed s/" "/,/g
	)

	"${boot_jdk}/bin/jlink" \
		--no-header-files \
		--no-man-pages \
		--strip-debug \
		--compress=zip-9 \
		--module-path="${jbr_jdk_dir}/jmods" \
		--add-modules ${modules} \
		--output "${runtime_image_dir}"

	grep -v "^JAVA_VERSION" "${jbr_jdk_dir}/release" | grep -v "^MODULES" >>"${runtime_image_dir}/release"
	cp "${runtime_image_dir}/release" "${dist_dir}"

	cd ${runtime_image_dir}
	zip -9rDy${quiet:+q} "${dist_dir}/jdk-runtime.zip" .
	echo "Java Runtime Done"
)

# Temporary: run the aarch64 cross build during the x64 CI job to verify both
# Linux JBR25 targets on the CI environment.
echo "=== Temporary CI test: Building Linux aarch64 (glibc) ==="
"$(dirname "$0")/build-jbr25-linux-aarch64.sh" \
	${quiet:+-q} \
	-b "$build_number" \
	-o "$out_path/linux-aarch64" \
	-d "$dist_dir/linux-aarch64"

echo "All Done!"
