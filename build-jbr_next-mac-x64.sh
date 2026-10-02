#!/bin/bash
#
# Builds JBR21 for Intel Mac
# Usage:
#   build-jbr_next-mac-x64.sh [-q]
# The JDK is built in OUT_DIR (or "out" if unset).
# The following artifacts are created in DIST_DIR (or "out/dist" if unset):
#   jdk.zip              archive of the JDK distribution
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise

source $(dirname $0)/build-jetbrainsruntime-common.sh

declare -r sources_dir="${top}/external/jetbrains/JetBrainsRuntime-next"
declare -r boot_jdk="${top}/prebuilts/jdk/studio/jbr-next/mac/Contents/Home"

echo "Building Mac JDK......."
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
echo "Xcode sdk version=$(xcrun --show-sdk-version)"
xcodebuild -version

function dist_logs() {
    [[ -e "${build_dir}/build.log" ]] && cp "${build_dir}/build.log" "${dist_dir}/"
    [[ -e "${build_dir}/configure-support/config.log" ]] && cp "${build_dir}/configure-support/config.log" "${dist_dir}/"
}
trap dist_logs EXIT

#TODO check all available env variables if they could be used for reproducible build opts
#TODO use date from  make/conf/version-numbers.conf for reproducible build opts

if [ -f "${dist_dir}"/jdk.zip ]; then
  echo "Re-using existing JDK ${dist_dir}/jdk.zip"
else
  declare -r jbr_tag="$(sed 's/^.*b//' "${sources_dir}/build.txt")"
  export SOURCE_DATE_EPOCH=$(source_date_epoch $sources_dir)

  # Darwin lacks autoconf, install it for this build.
  install_autoconf "$autoconf_dir" "$out_path"

  # disable 'gnu-folding-constant' for SystemHotkey.m
  declare -r disable_compiler_warnings_flags="\
    -Wno-gnu-folding-constant \
    "

  # Configure
  mkdir -p "$build_dir"
  (cd "$build_dir" &&
     PATH="$autoconf_dir/bin":$PATH bash +x "$sources_dir/configure" \
     "${quiet:+--quiet}" \
     --with-vendor-name="JetBrains s.r.o." \
     --with-vendor-vm-bug-url=https://youtrack.jetbrains.com/issues/JBR \
     --with-version-pre=$([ "$build_number" == "dev" ] && echo "dev" || echo "") \
     --without-version-build \
     --with-version-opt="$(numeric_build_number $build_number)-b$jbr_tag" \
     --enable-cds=yes \
     --disable-full-docs \
     --disable-absolute-paths-in-output \
     --with-build-user=builder \
     --with-freetype=bundled \
     --with-libpng=bundled \
     --with-zlib=bundled \
     --with-native-debug-symbols=zipped \
     --with-debug-level=release \
     --disable-jvm-feature-epsilongc \
     --disable-jvm-feature-shenandoahgc \
     --disable-jvm-feature-zgc \
     --disable-jvm-feature-dtrace \
     --with-boot-jdk="$boot_jdk" \
     --with-sysroot="$sysroot" \
     --with-stdc++lib=static \
     --with-toolchain-type=clang \
     --with-tools-dir="$clang_bin" \
     --with-extra-cflags="$disable_compiler_warnings_flags -mmacosx-version-min=11.0" \
     --with-extra-cxxflags="$disable_compiler_warnings_flags -mmacosx-version-min=11.0" \
     AR=llvm-ar NM=llvm-nm OBJDUMP=llvm-objdump STRIP=llvm-strip
  )

  echo "Configure done"
  echo "Making images ...."

  # Make
  declare -r make_log_level=${quiet:+warn}
  make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images

  rm -rf "$dist_dir"/{jdk.zip,jdk-debuginfo.zip,jdk-runtime.zip,build.log,configure.log}
  declare -r bundle_dir=$(find $build_dir/images/jdk-bundle/ -type d -depth 1 -name 'jdk-*.jdk')
  (
    cd "$bundle_dir"
    rm -rf Contents/Home/demo
    rm -rf Contents/Home/man
    zip -9rDy${quiet:+q} "$dist_dir"/jdk.zip . --exclude '*.diz'
    zip -9rDy${quiet:+q} "$dist_dir"/jdk-debuginfo.zip . --include '*.diz'
  )
fi


echo "Creating java runtime ...."
(
  rm -rf "${out_path}/java-runtime" &&  mkdir "${out_path}/java-runtime"
  cd  "${out_path}/java-runtime"

  jbr_jdk_dir=$(make_target_dir "jdk")
  runtime_image_dir="${out_path}/java-runtime/image"
  unzip ${quiet:+-q} $dist_dir/jdk.zip -d $jbr_jdk_dir

  # 1. add studio modules to jb/project/tools/common/modules.list
  # 2. remove trailing comas, and remove duplicates
  # 3. JBR-3398 JDK-8263327 Remove the Experimental AOT and JIT Compiler
  # 4. trim, and convert lines to coma-separated list
 declare modules=$(
   cat ${sources_dir}/jb/project/tools/common/modules.list ${top}/toolchain/jdk/build/studio-modules.list \
   | sed s/","/" "/g | sort | uniq \
   | grep -v 'jdk.aot' \
   | grep -v 'jdk.internal.vm.compiler' \
   | grep -v 'jdk.internal.vm.compiler.management' \
   | xargs | sed s/" "/,/g
 )

  "${boot_jdk}/bin/jlink" \
    --no-header-files \
    --no-man-pages \
    --strip-debug \
    --compress=zip-9 \
    --module-path="${jbr_jdk_dir}/Contents/Home/jmods" \
    --add-modules ${modules} \
    --output "${runtime_image_dir}/Contents/Home"


  grep -v "^JAVA_VERSION" "${jbr_jdk_dir}/Contents/Home/release" | grep -v "^MODULES" >> "${runtime_image_dir}/Contents/Home/release"
  cp "${runtime_image_dir}/Contents/Home/release" "${dist_dir}"

  ditto ${jbr_jdk_dir}/Contents/MacOS ${runtime_image_dir}/Contents/MacOS
  ditto ${jbr_jdk_dir}/Contents/Info.plist ${runtime_image_dir}/Contents/Info.plist

  cd ${runtime_image_dir}
  zip -9rDy${quiet:+q} "${dist_dir}/jdk-runtime.zip" .
  echo "Java Runtime Done"
)

echo "All Done!"