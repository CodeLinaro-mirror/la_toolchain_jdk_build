#!/bin/bash
#
# Cross-compiles a headless-only JBR25 for Linux aarch64 against musl libc on a
# linux-x86_64 build host.
# Usage:
#   build-jbr25-linux-musl-aarch64-headless.sh [-q]
# The JDK is built in OUT_DIR (or "out" if unset).
# The following artifacts are created in DIST_DIR (or "out/dist" if unset):
#   jdk.zip              archive of the JDK distribution
#   jdk-runtime.zip      archive of the jlinked runtime
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise
#
# References:
#   https://github.com/openjdk/jdk/blob/master/doc/building.md#cross-compiling
#   https://github.com/openjdk/jdk/blob/master/doc/building.md#building-for-musl
#
# This is the third Linux aarch64 flavour, next to the glibc build in
# build-jbr25-linux-aarch64.sh. It exists for the Android CLI tools, which run
# the JVM headless and need a runtime that does not depend on the host's libc
# or desktop libraries. It follows build-openjdk25-linux-musl.sh, the musl JDK
# the Android platform build uses, with the JBR configuration of the other
# JBR25 scripts. Differences worth noting:
#
#   * --enable-headless-only: no X11 or Wayland toolkit is built, so the image
#     has no libawt_xawt, libawt_wlawt or libsplashscreen (libjawt remains, as
#     a -DHEADLESS build on top of libawt_headless), and none of the X11 and
#     Wayland libraries are needed, neither at build time nor on the target
#     machine. java.desktop is still present and works headless.
#
#   * The libc comes from the hermetic musl sysroot in prebuilts/build-tools and
#     is shipped in lib/ together with jemalloc, which that sysroot links in as
#     its malloc. The JDK's own loader rpaths find them there, so the runtime
#     does not need a musl installed on the machine.
#
#   * freetype, libpng and zlib are the versions bundled with the JDK sources.
#     The musl loader only searches /lib and /usr/lib, so on a glibc
#     distribution (Debian multiarch, for instance) a system freetype would
#     neither be found nor be loadable. libasound is the one library still
#     taken from the system; it is only loaded when sound is used.
#
#   * The only Alpine packages involved are the ALSA, CUPS, dbus and fontconfig
#     headers plus the ALSA library; see download-deps-jbr25-musl-arm64-headless.sh.
#
#   * build-openjdk25-linux-musl.sh only builds natively, for whichever
#     architecture it happens to run on. This one always cross-compiles to
#     aarch64, so the boot JDK and the build JDK are x64 while everything shipped
#     is aarch64.
#
#   * A prebuilt build JDK is supplied with --with-build-jdk instead of letting
#     the build compile an interim one for the build host. configure derives
#     -DMUSL_LIBC from the *target* libc and puts it in OS_CFLAGS, which
#     flags-cflags.m4 feeds into both the target and the build-platform flag
#     sets. Compiling the build JDK's hotspot with it fails, because
#     os_linux.cpp then defines a static dlvsym fallback that clashes with the
#     glibc declaration:
#
#       os_linux.cpp:143:14: error: static declaration of 'dlvsym' follows
#       non-static declaration
#
#     Upstream musl support assumes a native Alpine build, where build libc and
#     target libc are the same, so this never shows up there. Skipping the
#     interim build JDK avoids the problem and roughly halves the build time.

source $(dirname $0)/build-jetbrainsruntime-common.sh

declare -r sources_dir="$top/external/jetbrains/JetBrainsRuntime25"
# The boot JDK runs on the build host, so it is the x64 glibc one.
declare -r boot_jdk="$top/prebuilts/jdk/studio/jbr25/linux/"
declare -r build_deps="$top/toolchain/jdk/deps/jbr25/linux_musl_arm64_headless"
declare -r build_target="x86_64-unknown-linux-gnu"
declare -r openjdk_target="aarch64-unknown-linux-musl"
declare -r musl_sysroot="$top/prebuilts/build-tools/sysroots/$openjdk_target"
# Hermetic x86_64 sysroot for the build host compiler, deliberately outside
# $sysroot so that no amd64 library can end up on the aarch64 link line.
declare -r host_tools="$out_path/host-tools"

# Shared libraries the headless musl images expect to find on the target
# system. The libc, jemalloc and freetype are shipped in lib/, so this is only
# libasound, linked by libjsound. CUPS, fontconfig and dbus are dlopen'ed and
# therefore not DT_NEEDED anywhere.
declare -r musl_headless_target_system_libraries="
  libasound.so.2
"

echo "Building Linux musl aarch64 headless JDK......."
echo "out_path=${out_path:-}"
echo "dist_dir=${dist_dir:-}"
echo "sysroot=${sysroot:-}"
echo "musl_sysroot=${musl_sysroot:-}"
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

# Only the build host is described here. The target's libc comes from the
# sysroot assembled below, not from whatever this machine happens to run.
cat /etc/os-release

# "Installs" given Alpine packages into specified directory.
function unpack_apk_dependencies() {
	local -r target_dir="$1"
	shift
	mkdir -p "$target_dir"

	for apk in "$@"; do
		# An Alpine package is actually multiple concatenated tar archives.
		cat "${apk}" | tar -C "${target_dir}" -xz
		[[ -n "${quiet:-}" ]] || printf "Unpacked %s\n" "$apk"
	done
}

# Copies the musl runtime out of the sysroot into an image. jlink builds the
# runtime image from jmods, which do not carry these, so it is called for both
# the JDK image and the runtime image.
#   $1 image
function copyMuslRuntime() {
	local -r image="$1"
	cp "$sysroot/lib/libc_musl.so" "$image/lib/"
	cp "$sysroot/lib/libjemalloc5.so" "$image/lib/"
	mkdir -p "$image/legal/musl"
	cp "$sysroot/LICENSE" "$image/legal/musl/"
}

# Fails if the image does not look like a headless-only build.
#   $1 image
function verifyHeadlessImage() {
	local -r image="$1"
	local lib
	if [ ! -f "$image/lib/libawt_headless.so" ]; then
		echo "$image: lib/libawt_headless.so is missing"
		exit 5
	fi
	for lib in libawt_xawt.so libawt_wlawt.so libsplashscreen.so; do
		if [ -e "$image/lib/$lib" ]; then
			echo "$image: lib/$lib must not be present in a headless-only build"
			exit 5
		fi
	done
	echo "$image: headless-only"
}

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

	# Hermetic musl libc first, then the Alpine packages on top of it.
	mkdir -p "$sysroot"
	cp -rp "$musl_sysroot"/* "$sysroot"/
	unpack_apk_dependencies "$sysroot" $build_deps/*.apk

	# Hermetic x86_64 host sysroot for BUILD_CC/BUILD_CXX (used to compile
	# build-time tools such as adlc), so that BUILD_CXX cannot fall back to the
	# build host's system libstdc++.a on older CI images.
	unpack_dependencies "$host_tools" \
		$top/toolchain/jdk/deps/libc6*.deb \
		$top/toolchain/jdk/deps/linux-libc-dev*.deb \
		$top/toolchain/jdk/deps/libgcc*.deb \
		$top/toolchain/jdk/deps/libstdc*.deb

	# See build-jbr25-linux-aarch64.sh for why the target has to be baked into
	# the compiler driver rather than passed through --with-extra-cflags.
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

	# See build-jbr25-linux-aarch64.sh for why HelloClasslist has to run on a
	# build JDK limited to java.base and java.logging.
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

	# -ljemalloc5 is spelled out because the sysroot's libc.so linker script,
	# which links it implicitly today, is losing that (b/533100825); see
	# build-openjdk25-linux-musl.sh.
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
				--enable-headless-only \
				--with-freetype=bundled \
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
				--with-alsa-include="$sysroot/usr/include" \
				--with-alsa-lib="$sysroot/usr/lib" \
				--with-cups-include="$sysroot/usr/include" \
				--with-fontconfig-include="$sysroot/usr/include" \
				--with-dbus-includes="$sysroot/usr/include/dbus-1.0 $sysroot/usr/lib/dbus-1.0/include" \
				--with-extra-cflags="--sysroot=$sysroot -stdlib=libc++" \
				--with-extra-cxxflags="--sysroot=$sysroot -stdlib=libc++" \
				--with-extra-ldflags="--sysroot=$sysroot -stdlib=libc++ -rtlib=compiler-rt -ljemalloc5" \
				AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip CXXFILT=llvm-cxxfilt \
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

	copyMuslRuntime "$build_dir/images/jdk"

	verifyLinuxBinaryCpuArchitecture "$build_dir/images/jdk/bin/java" "AArch64"
	verifyLinuxBinaryCpuArchitecture "$build_dir/images/jdk/lib/libc_musl.so" "AArch64"
	verifyLinuxBinaryCpuArchitecture "$build_dir/images/jdk/lib/libjemalloc5.so" "AArch64"
	verifyHeadlessImage "$build_dir/images/jdk"
	verifyLinuxSharedLibraryDependencies "$build_dir/images/jdk" "$musl_headless_target_system_libraries"

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

	# See build-jbr25-linux-aarch64.sh for why --strip-debug is expanded here and
	# why there is no --generate-cds-archive.
	"${boot_jdk}/bin/jlink" \
		--no-header-files \
		--no-man-pages \
		--strip-java-debug-attributes \
		--strip-native-debug-symbols "exclude-debuginfo-files:objcopy=$clang_bin/llvm-objcopy" \
		--compress=zip-9 \
		--module-path="${jbr_jdk_dir}/jmods" \
		--add-modules ${modules} \
		--output "${runtime_image_dir}"

	copyMuslRuntime "${runtime_image_dir}"

	verifyLinuxBinaryCpuArchitecture "${runtime_image_dir}/bin/java" "AArch64"
	verifyHeadlessImage "${runtime_image_dir}"
	verifyLinuxSharedLibraryDependencies "${runtime_image_dir}" "$musl_headless_target_system_libraries"

	grep -v "^JAVA_VERSION" "${jbr_jdk_dir}/release" | grep -v "^MODULES" >>"${runtime_image_dir}/release"
	cp "${runtime_image_dir}/release" "${dist_dir}"

	cd ${runtime_image_dir}
	zip -9rDy${quiet:+q} "${dist_dir}/jdk-runtime.zip" .
	echo "Java Runtime Done"
)

echo "All Done!"
