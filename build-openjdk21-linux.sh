#!/bin/bash
#
# Builds JDK21, optionally creating distribution artifacts for it.
# Usage:
#   build_openjdk21-linux.sh [-q] [-d <dist_dir>] build_dir
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

declare -r out_path=$(make_target_dir "$1")
declare -r sysroot="$out_path/sysroot"
declare -r build_dir="$out_path/build"
declare -r top=$(realpath "$(dirname "$0")/../../..")
declare -r clang_bin="$top/prebuilts/clang/host/linux-x86/clang-r614150/bin"
declare -r profdata="$top/toolchain/jdk/build/openjdk21.prof"

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
    ln -sfn ${relative_target} ${link}
  done
}

# Prepare
unpack_dependencies "$sysroot" $top/toolchain/jdk/deps/*.deb

function dist_logs() {
    [[ -n "${dist_dir:-}" && -e "${build_dir}/build.log" ]] && cp "${build_dir}/build.log" "${dist_dir}/"
    [[ -n "${dist_dir:-}" && -e "${build_dir}/configure-support/config.log" ]] && cp "${build_dir}/configure-support/config.log" "${dist_dir}/"
}
trap dist_logs EXIT

# Configure
mkdir -p "$build_dir"
[[ -n "${quiet:-}" ]] || set -x
(cd "$build_dir" && 
   bash +x "$top/toolchain/jdk/jdk21/configure" \
     "${quiet:+--quiet}" \
     --disable-full-docs \
     --disable-warnings-as-errors \
     --with-alsa-include="$sysroot/usr/include" \
     --with-alsa-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
     --with-boot-jdk="$top/prebuilts/jdk/jdk21/linux-x86" \
     --with-cups-include="$sysroot/usr/include" \
     --with-sysroot="$sysroot"\
     --with-freetype=system \
     --with-freetype-lib="$sysroot/usr/lib/x86_64-linux-gnu" \
     --with-freetype-include="$sysroot/usr/include/freetype2" \
     --with-libpng=bundled \
     --with-native-debug-symbols=external \
     --with-stdc++lib=static \
     --with-toolchain-type=clang \
     --with-tools-dir="$clang_bin" \
     --with-version-pre= \
     --with-version-opt=${BUILD_NUMBER:-0} \
     --with-vendor-version-string=Android_PDK \
     --with-zlib=bundled \
     --x-libraries="$sysroot/usr/lib/x86_64-linux-gnu" \
     --x-includes="$sysroot/usr/include" \
     --with-extra-cflags="--sysroot=$sysroot -fno-delete-null-pointer-checks -flto=full -gline-tables-only -fdebug-info-for-profiling -funique-internal-linkage-names  -fprofile-sample-use=$profdata" \
     --with-extra-cxxflags="--sysroot=$sysroot -fno-delete-null-pointer-checks -flto=full -gline-tables-only -fdebug-info-for-profiling -funique-internal-linkage-names  -fprofile-sample-use=$profdata" \
     --with-extra-ldflags="--sysroot=$sysroot -fuse-ld=lld -flto=full -gline-tables-only -fdebug-info-for-profiling -funique-internal-linkage-names  -fprofile-sample-use=$profdata" \
     AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
)

# Make
declare -r make_log_level=${quiet:+warn}
make -C "$build_dir" LOG=${make_log_level:-debug} ${quiet:+-s} images
[[ -n "${dist_dir:-}" ]] || exit 0

# Dist
rm -rf "$dist_dir"/{jdk.zip,jdk-debuginfo.zip,build.log,configure.log}
(cd "$build_dir/images/jdk" && 
  zip -9rDy${quiet:+q} "$dist_dir"/jdk.zip . -x 'demo/*' -x'man/*' -x'*.debuginfo' && 
  zip -9rDy${quiet:+q} "$dist_dir"/jdk-debuginfo.zip . -i'*.debuginfo'
)
