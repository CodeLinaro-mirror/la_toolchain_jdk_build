#!/bin/bash
#
# Cross-compiles JBR25 for Linux aarch64 on a linux-x86_64 build host.
# Usage:
#   build-jbr25-linux-aarch64.sh [-q]
# The JDK is built in OUT_DIR (or "out" if unset).
# The following artifacts are created in DIST_DIR (or "out/dist" if unset):
#   jdk.zip              archive of the JDK distribution
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise
#
# References:
#   https://github.com/openjdk/jdk/blob/master/doc/building.md#cross-compiling
#
# Notes on cross-compiling, see build-jbr25-linux-x64.sh for the native build:
#
#   * The boot JDK has to run on the build host, so it is the x64 JBR, not an
#     aarch64 one. The build additionally produces its own "build JDK" (an
#     interim JDK for the build host) as part of `make images`, which roughly
#     doubles the build time compared to the native x64 build.
#
#   * wayland-scanner is a code generator that runs during the build, so the
#     amd64 build of it is unpacked outside the sysroot and used from there,
#     while libwayland itself is taken from the aarch64 packages.
#
#   * This targets glibc 2.31 rather than the 2.19 floor of the x64 build,
#     because Ubuntu 14.04 has no usable arm64 port to pull an older libc from.

source $(dirname $0)/build-jetbrainsruntime-common.sh

declare -r sources_dir="$top/external/jetbrains/JetBrainsRuntime25"
# The boot JDK runs on the build host, so it is the x64 one.
declare -r boot_jdk="$top/prebuilts/jdk/studio/jbr25/linux/"
declare -r build_deps="$top/toolchain/jdk/deps/jbr25/linux_arm64"
# Build host tools, shared with the other Linux JBR25 builds.
declare -r host_tools_deps="$top/toolchain/jdk/deps/jbr25/linux_host_tools"
declare -r build_target="x86_64-unknown-linux-gnu"
declare -r openjdk_target="aarch64-unknown-linux-gnu"
# Multiarch tuple used for library paths inside the sysroot, which is not the
# same string as the target triple above.
declare -r target_libdir="aarch64-linux-gnu"
# Packages that have to run on the build host are unpacked here, deliberately
# outside the sysroot so that no amd64 binary can end up on the link line.
declare -r host_tools="$out_path/host-tools"

echo "Building Linux aarch64 JDK......."
echo "out_path=${out_path:-}"
echo "dist_dir=${dist_dir:-}"
echo "sysroot=${sysroot:-}"
echo "host_tools=${host_tools:-}"
echo "build_dir=${build_dir:-}"
echo "top=${top:-}"
echo "clang_bin=${clang_bin:-}"
echo "autoconf_dir=${autoconf_dir:-}"
echo "build_number=${build_number:-}"
echo "sources_dir=${sources_dir:-}"
echo "boot_jdk=${boot_jdk:-}"
echo "build_deps=${build_deps:-}"
echo "build=${build_target:-}"
echo "openjdk-target=${openjdk_target:-}"

# Only the build host is described here. The target's glibc comes from the
# sysroot assembled below, not from whatever this machine happens to run.
cat /etc/os-release

function dist_logs() {
	[[ -e "${build_dir}/build.log" ]] && cp "${build_dir}/build.log" "${dist_dir}/"
	[[ -e "${build_dir}/configure-support/config.log" ]] && cp "${build_dir}/configure-support/config.log" "${dist_dir}/"
}
trap dist_logs EXIT

if [ -f "$dist_dir"/jdk.zip ]; then
	echo "Re-using existing JDK $dist_dir/jdk.zip"
else
	declare -r jbr_tag="$(sed 's/^.*b//' "$sources_dir/build.txt")"
	export SOURCE_DATE_EPOCH=$(source_date_epoch $sources_dir)
	unset DISPLAY

	# Target dependencies are from Ubuntu 20.04 arm64
	# see download-deps-jbr25-arm64.sh and Dockerfile.jbr25_deps
	unpack_dependencies "$sysroot" $build_deps/*_arm64.deb $build_deps/*_all.deb

	# Build host tools (wayland-scanner) and hermetic x86_64 host sysroot for
	# BUILD_CC/BUILD_CXX (used to compile build-time tools such as adlc).
	# Kept out of $sysroot so the aarch64 link line cannot pick up an amd64
	# library, while preventing BUILD_CXX from falling back to the build host's
	# system /usr/lib/gcc/x86_64-linux-gnu/4.8 libstdc++.a on older CI images.
	unpack_dependencies "$host_tools" \
		$host_tools_deps/*.deb \
		$top/toolchain/jdk/deps/libc6*.deb \
		$top/toolchain/jdk/deps/linux-libc-dev*.deb \
		$top/toolchain/jdk/deps/libgcc*.deb \
		$top/toolchain/jdk/deps/libstdc*.deb

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

	# configure wants that library binary without version suffix
	ln -sfn "libfreetype.so.6" "$sysroot/usr/lib/$target_libdir/libfreetype.so"

	# When cross compiling, autoconf looks for a driver named after the target
	# triple (<target>-clang) before falling back to plain clang. Providing one
	# is what makes the target stick: configure runs a long series of compiler
	# and preprocessor probes before --with-extra-cflags is ever applied, so a
	# driver that does not already know its target resolves the build host's
	# x86_64 multiarch headers against the aarch64 sysroot and fails.
	#
	# These are generated as exec wrappers rather than symlinks because the
	# Android clang driver locates its clang-real sibling relative to its own
	# directory, which a symlink from elsewhere breaks.
	declare -r cross_bin="$out_path/cross-toolchain/bin"
	mkdir -p "$cross_bin"
	for tool in clang clang++; do
		cat >"$cross_bin/$openjdk_target-$tool" <<EOF
#!/bin/bash
exec "$clang_bin/$tool" --target=$openjdk_target "\$@"
EOF
		chmod +x "$cross_bin/$openjdk_target-$tool"

		cat >"$cross_bin/host-$tool" <<EOF
#!/bin/bash
exec "$clang_bin/$tool" --sysroot="$host_tools" -fuse-ld=lld "\$@"
EOF
		chmod +x "$cross_bin/host-$tool"
	done

	# When --with-build-jdk is passed (EXTERNAL_BUILDJDK=true), OpenJDK's
	# GenerateLinkOptData.gmk skips building interim-image (which normally only
	# contains INTERIM_IMAGE_MODULES: java.base and java.logging) and runs
	# HelloClasslist directly on BUILD_JDK/bin/java. Because $boot_jdk is a full
	# JBR25 image containing java.desktop, loading sun.awt.X11GraphicsDevice in
	# headless mode (when DISPLAY is unset on CI) throws UnsatisfiedLinkError for
	# getXrmXftDpi (defined in libawt_xawt.so, which is not loaded when headless).
	# Wrap BUILD_JDK/bin/java so HelloClasslist runs with --limit-modules
	# java.base,java.logging, matching OpenJDK's own interim-image.
	declare -r build_jdk="$out_path/build-jdk"
	rm -rf "$build_jdk"
	mkdir -p "$build_jdk/bin"
	for entry in "$boot_jdk/"*; do
		[[ "$(basename "$entry")" == "bin" ]] && continue
		ln -sfn "$entry" "$build_jdk/$(basename "$entry")"
	done
	for tool in "$boot_jdk/bin/"*; do
		[[ "$(basename "$tool")" == "java" ]] && continue
		ln -sfn "$tool" "$build_jdk/bin/$(basename "$tool")"
	done
	rm -f "$build_jdk/bin/java"
	cat >"$build_jdk/bin/java" <<EOF
#!/bin/sh
case "\$*" in
  *HelloClasslist*) exec "$boot_jdk/bin/java" --limit-modules java.base,java.logging "\$@" ;;
  *) exec "$boot_jdk/bin/java" "\$@" ;;
esac
EOF
	chmod +x "$build_jdk/bin/java"

	# JBR25 ships no generated-configure.sh, so `configure` regenerates it with
	# autoconf. Build autoconf 2.69 from the in-repo source tarball rather than
	# picking up whatever version the build host happens to have installed.
	install_autoconf "$autoconf_dir" "$out_path"

	mkdir -p "$build_dir"
	(
		cd "$build_dir" &&
			PATH="$autoconf_dir/bin":$PATH bash +x "$sources_dir/configure" \
				"${quiet:+--quiet}" \
				--disable-warnings-as-errors \
				--build=$build_target \
				--openjdk-target=$openjdk_target \
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
				--with-build-jdk="$build_jdk" \
				--with-sysroot="$sysroot" \
				--with-stdc++lib=static \
				--with-toolchain-type=clang \
				--with-toolchain-path="$cross_bin:$clang_bin" \
				--with-freetype-include="$sources_dir/src/java.desktop/share/native/libfreetype/include" \
				--with-freetype-lib="$sysroot/usr/lib/$target_libdir" \
				--with-freetype=system \
				--with-alsa-include="$sysroot/usr/include" \
				--with-alsa-lib="$sysroot/usr/lib/$target_libdir" \
				--with-cups-include="$sysroot/usr/include" \
				--with-wayland-protocols="$sysroot/usr/share/wayland-protocols" \
				--with-dbus-includes="$sysroot/usr/include/dbus-1.0 $sysroot/usr/lib/$target_libdir/dbus-1.0/include" \
				--with-extra-cflags="--sysroot=$sysroot" \
				--with-extra-cxxflags="--sysroot=$sysroot" \
				--with-extra-ldflags="--sysroot=$sysroot" \
				AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip CXXFILT=llvm-cxxfilt WAYLAND_SCANNER="$host_tools/usr/bin/wayland-scanner" \
				BUILD_CC="$cross_bin/host-clang" \
				BUILD_CXX="$cross_bin/host-clang++" \
				BUILD_LD="$cross_bin/host-clang" \
				BUILD_AR="$clang_bin/llvm-ar" \
				BUILD_NM="$clang_bin/llvm-nm" \
				BUILD_OBJCOPY="$clang_bin/llvm-objcopy" \
				BUILD_STRIP="$clang_bin/llvm-strip"
	)

	echo "Configure done"
	echo "Making images ...."

	declare -r make_log_level=${quiet:+warn}
	make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images

	verifyLinuxBinaryCpuArchitecture "$build_dir/images/jdk/bin/java" "AArch64"

	bundleLinuxLibraries "$build_dir/images/jdk" "$sysroot" "$sysroot/usr/lib/aarch64-linux-gnu" "AArch64"
	verifyLinuxSharedLibraryDependencies "$build_dir/images/jdk" "$linux_target_system_libraries"

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

	# jlink runs on the build host but reads the target's jmods, so the boot JDK
	# is used here as well. No --generate-cds-archive: dumping a CDS archive
	# requires executing the target java, which is not possible when cross-compiling.
	#
	# --strip-debug is expanded into its two underlying plugins so that the
	# native one can be pointed at llvm-objcopy. It otherwise shells out to
	# whatever objcopy is on PATH, and the host GNU objcopy only understands x86
	# targets, so it fails on every aarch64 library and leaves them unstripped
	# while the build still reports success.
	"${boot_jdk}/bin/jlink" \
		--no-header-files \
		--no-man-pages \
		--strip-java-debug-attributes \
		--strip-native-debug-symbols "exclude-debuginfo-files:objcopy=$clang_bin/llvm-objcopy" \
		--compress=zip-9 \
		--module-path="${jbr_jdk_dir}/jmods" \
		--add-modules ${modules} \
		--output "${runtime_image_dir}"

	verifyLinuxBinaryCpuArchitecture "${runtime_image_dir}/bin/java" "AArch64"

	copyBundledLinuxLibraries "${jbr_jdk_dir}" "${runtime_image_dir}"
	verifyLinuxSharedLibraryDependencies "${runtime_image_dir}" "$linux_target_system_libraries"

	grep -v "^JAVA_VERSION" "${jbr_jdk_dir}/release" | grep -v "^MODULES" >>"${runtime_image_dir}/release"
	cp "${runtime_image_dir}/release" "${dist_dir}"

	cd ${runtime_image_dir}
	zip -9rDy${quiet:+q} "${dist_dir}/jdk-runtime.zip" .
	echo "Java Runtime Done"
)

echo "All Done!"
