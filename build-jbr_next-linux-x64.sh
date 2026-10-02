#!/bin/bash
#
# Builds JBR21 for Linux
# Usage:
#   build-jbr_next-linux-x64.sh [-q]
# The JDK is built in OUT_DIR (or "out" if unset).
# The following artifacts are created in DIST_DIR (or "out/dist" if unset):
#   jdk.zip              archive of the JDK distribution
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise

source $(dirname $0)/build-jetbrainsruntime-common.sh

declare -r sources_dir="$top/external/jetbrains/JetBrainsRuntime-next"
declare -r boot_jdk="$top/prebuilts/jdk/studio/jbr-next/linux"

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

# "Installs" given Debian packages into specified directory.
function unpack_dependencies() {
  local -r target_dir="$1"
  local -r ar="$clang_bin/llvm-ar"
  shift
  mkdir -p "$target_dir"
  for deb in "$@"; do
    # Debian package is actually 'ar' archive. The package files are in data.tar.<type>
    # member. Extract and untar it.
    case $("$ar" -t "$deb" | grep data.tar) in
      data.tar.xz)
        "$ar" -p "$deb" data.tar.xz | (cd "$target_dir" && tar -Jx) ;;
      data.tar.bz2)
        "$ar" -p "$deb" data.tar.bz2 | (cd "$target_dir" && tar -jx) ;;
      data.tar.gz)
        "$ar" -p "$deb" data.tar.gz | (cd "$target_dir" && tar -zx) ;;
      *)
        printf "%s does not contain expected archive\n" "$deb"
        exit 1
        ;;
    esac
    [[ -n "${quiet:-}" ]] || printf "Unpacked %s\n" "$deb"
  done

  # Rewrite absolute symlinks that point outside the sysroot to relative
  # symlinks to the corresponding files in the sysroot.
  for link in $(find "${target_dir}" -type l -lname '/*'); do
    target=$(readlink ${link})
    relative_target_dir=$(python -c 'import os.path, sys; print(os.path.relpath(*sys.argv[1:]))' ${target_dir} $(dirname ${link}))
    relative_target=${relative_target_dir}/${target}
    echo "Rewriting sysroot symlink ${link} from ${target} to ${relative_target}"
    ln -sfn ${relative_target} ${link}
  done
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

  # Prepare
  unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/*.deb
  declare -r disable_compiler_warnings_flags="\
    -Wno-pointer-arith \
    -Wno-format-nonliteral \
    "

  # Configure tools needed to build the JDK
  mkdir -p "$build_dir"
  (cd "$build_dir" &&
   bash +x "$sources_dir/configure" \
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
        --with-debug-level=release \
        --disable-jvm-feature-epsilongc \
        --disable-jvm-feature-shenandoahgc \
        --disable-jvm-feature-zgc \
        --disable-jvm-feature-dtrace \
        --with-boot-jdk="$boot_jdk" \
        --disable-warnings-as-errors \
        --with-alsa-include="$sysroot/usr/include" \
        --with-alsa-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
        --with-cups-include="$sysroot/usr/include" \
        --with-toolchain-type=clang \
        --with-libpng=bundled \
        --with-stdc++lib=static \
        --with-toolchain-path="$clang_bin" \
        --with-zlib=bundled \
        --x-libraries="$sysroot/usr/lib/x86_64-linux-gnu" \
        --x-includes="$sysroot/usr/include" \
        --with-native-debug-symbols=zipped \
        --with-freetype-include="$top/external/jetbrains/JetBrainsRuntime-next/src/java.desktop/share/native/libfreetype/include" \
        --with-freetype-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
        --with-freetype=system \
        --with-sysroot="$sysroot" \
        --with-extra-cflags="--sysroot=$sysroot $disable_compiler_warnings_flags" \
        --with-extra-cxxflags="--sysroot=$sysroot $disable_compiler_warnings_flags" \
        --with-extra-ldflags="--sysroot=$sysroot -fuse-ld=lld $disable_compiler_warnings_flags" \
        AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  )

  echo "Configure done"
  echo "Making images ...."

  # Make
  declare -r make_log_level=${quiet:+warn}
  make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images

  # Dist
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
    --module-path="${jbr_jdk_dir}/jmods" \
    --add-modules ${modules} \
    --output "${runtime_image_dir}"

  grep -v "^JAVA_VERSION" "${jbr_jdk_dir}/release" | grep -v "^MODULES" >> "${runtime_image_dir}/release"
  cp "${runtime_image_dir}/release" "${dist_dir}"

  cd ${runtime_image_dir}
  zip -9rDy${quiet:+q} "${dist_dir}/jdk-runtime.zip" .
  echo "Java Runtime Done"
)

echo "All Done!"