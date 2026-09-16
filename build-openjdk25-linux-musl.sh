#!/bin/bash
#
# Builds JDK25 against musl libc, optionally creating distribution artifacts
# for it.  Uses packages fetched from Alpine linux via the download-deps-musl.sh
# script for dependencies, and the sysroots in prebuilts/build-tools/sysroots
# for the hermetic relinterp-enabled musl.
#
# Usage:
#   build_openjdk25-linux-musl.sh [-q] [-d <dist_dir>] build_dir
# The JDK is built in <build_dir>.
# With -d, creates the following artifacts in <dist_dir>:
#   jdk.zip              archive of the JDK distribution
#   jdk-debuginfo.zip    .debuginfo files for JDK's shared libraries
#   configure.log
#   build.log
# Specify -q to suppress most of the output noise

set -eu
declare -r prog="${0##*/}"

function usage() {
  cat <<EOF
Usage:
    $prog [-q] [-d <dist_dir>] <build_dir>
JDK is built in <build_dir>.
With -d, creates the artifacts in <dist_dir>.
With -q, runs with minimum noise.
EOF
  exit 1
}

# Creates the directory if it does not exist and returns its absolute path
function make_target_dir() {
  mkdir -p "$1" && realpath "$1"
}

while getopts 'qd:' opt; do
  case $opt in
    d) dist_dir=$(make_target_dir $OPTARG) ;;
    q) quiet=t ;;
    *) usage ;;
  esac
done
shift $(($OPTIND-1))
(($#==1)) || usage

case "$(uname -m)" in
  aarch64)
    declare -r prebuilt_arch=arm64
    declare -r deps_arch=arm64
    ;;
  x86_64)
    declare -r prebuilt_arch=x86
    declare -r deps_arch=x86_64
    ;;
esac

declare -r top=$(realpath "$(dirname "$0")/../../..")
declare -r out_path=$(make_target_dir "$1")
declare -r target="$(uname -m)-unknown-linux-musl"
declare -r musl_sysroot="$top/prebuilts/build-tools/sysroots/${target}"
declare -r sysroot="$out_path/sysroot"
declare -r build_dir="$out_path/build"
declare -r clang_bin="$top/prebuilts/clang/host/linux-${prebuilt_arch}/clang-r584948b/bin"
declare -r autoconf_dir=$(make_target_dir "$out_path/autoconf")

mkdir -p ${sysroot}
cp -rp ${musl_sysroot}/* ${sysroot}/

# "Installs" given Alpine packages into specified directory.
function unpack_dependencies() {
  local -r target_dir="$1"
  shift
  mkdir -p "$target_dir"

  for apk in "$@"; do
    # An Alpine package is actually multiple tar archives.
    cat ${apk} | tar -C ${target_dir} -xz
    [[ -n "${quiet:-}" ]] || printf "Unpacked %s\n" "$apk"
  done

  # Rewrite absolute symlinks that point outside the sysroot to relative
  # symlinks to the corresponding files in the sysroot.
  for link in $(find "${target_dir}" -type l -lname '/*'); do
    target=$(readlink ${link})
    relative_target_dir=$(python -c 'import os.path, sys; print(os.path.relpath(*sys.argv[1:]))' ${target_dir} $(dirname ${link}))
    relative_target=${relative_target_dir}/${target}
    ln -sfn ${relative_target} ${link}
  done
}

# Installs autoconf into specified directory. The second argument is working directory.
function install_autoconf() {
  local -r workdir=$(make_target_dir "$2")
  local -r installdir=$(make_target_dir "$1")
  tar -C "$workdir" -xzf ${top}/toolchain/jdk/deps/src/autoconf-2.69.tar.gz
  (cd "$workdir"/autoconf-2.69 &&
     M4=${top}/prebuilts/build-tools/linux-${prebuilt_arch}/bin/m4 \
     ./configure --prefix="$installdir" ${quiet:+--quiet} &&
     make ${quiet:+-s} install
  )
}

# Prepare
unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/linux_musl_${deps_arch}/*.apk
install_autoconf "$autoconf_dir" "$out_path"

function dist_logs() {
    [[ -n "${dist_dir:-}" && -e "${build_dir}/build.log" ]] && cp "${build_dir}/build.log" "${dist_dir}/"
    [[ -n "${dist_dir:-}" && -e "${build_dir}/configure-support/config.log" ]] && cp "${build_dir}/configure-support/config.log" "${dist_dir}/"
}
trap dist_logs EXIT

export LD_LIBRARY_PATH=$sysroot/lib

# Configure
mkdir -p "$build_dir"
[[ -n "${quiet:-}" ]] || set -x
(cd "$build_dir" &&
   AUTOCONF=${autoconf_dir}/bin/autoconf \
   bash +x "$top/toolchain/jdk/jdk25/configure" \
     "${quiet:+--quiet}" \
     --build ${target} \
     --host ${target} \
     --target ${target} \
     --disable-full-docs \
     --disable-warnings-as-errors \
     --with-boot-jdk="$top/prebuilts/jdk/jdk25/linux-${prebuilt_arch}" \
     --with-sysroot="$sysroot" \
     --with-freetype=bundled \
     --with-libpng=bundled \
     --with-native-debug-symbols=external \
     --with-stdc++lib=static \
     --with-toolchain-type=clang \
     --with-tools-dir="$clang_bin" \
     --with-version-pre= \
     --with-version-opt=${BUILD_NUMBER:-0} \
     --with-vendor-version-string=Android_PDK \
     --with-zlib=system \
     --with-alsa-include="$sysroot/usr/include" \
     --with-alsa-lib="$sysroot/usr/lib" \
     --with-cups-include="$sysroot/usr/include" \
     --with-fontconfig-include="$sysroot/usr/include" \
     --x-libraries="$sysroot/usr/lib" \
     --x-includes="$sysroot/usr/include" \
     --with-extra-cflags="--sysroot=$sysroot -fno-delete-null-pointer-checks -flto=full -stdlib=libc++ --target=${target}" \
     --with-extra-cxxflags="--sysroot=$sysroot -fno-delete-null-pointer-checks -flto=full -stdlib=libc++ --target=${target}" \
     --with-extra-ldflags="--sysroot=$sysroot -fuse-ld=lld -flto=full -rtlib=compiler-rt -stdlib=libc++ --target=${target} -ljemalloc5" \
     AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip CXXFILT=llvm-cxxfilt
)

# Make
declare -r make_log_level=${quiet:+warn}
make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images \
    ADLC_LANGSTD_CXXFLAGS="-std=c++14 -stdlib=libc++ --target=${target}" \
    ADLC_LDFLAGS="-stdlib=libc++ -rtlib=compiler-rt -fuse-ld=lld --target=${target} -static-libstdc++"

# Add musl libc to the output directory
cp "${sysroot}/lib/libc_musl.so" "$build_dir/images/jdk/lib/"
cp "${sysroot}/lib/libjemalloc5.so" "$build_dir/images/jdk/lib/"
mkdir -p "$build_dir/images/jdk/legal/musl/"
cp ${sysroot}/LICENSE "$build_dir/images/jdk/legal/musl/"

[[ -n "${dist_dir:-}" ]] || exit 0

# Dist
rm -rf "$dist_dir"/{jdk.zip,jdk-debuginfo.zip,build.log,configure.log}
(cd "$build_dir/images/jdk" &&
  zip -9rDy${quiet:+q} "$dist_dir"/jdk.zip . -x 'demo/*' -x'man/*' -x'*.debuginfo' &&
  zip -9rDy${quiet:+q} "$dist_dir"/jdk-debuginfo.zip . -i'*.debuginfo'
)
