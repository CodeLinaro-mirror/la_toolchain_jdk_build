set -eu
set -o pipefail

case $(uname) in
  Darwin)
   # Darwin does not have realpath.
   realpath() {
     cd $1 && pwd
   }
   ;;
esac

# Shared libraries that the target system is expected to have installed, so the
# Linux (glibc) JBR images link them without shipping them: glibc itself, plus
# the X11, Wayland, font and sound libraries every desktop session has. Every
# other library an image links must be inside the image;
# verifyLinuxSharedLibraryDependencies enforces this.
declare -r linux_target_system_libraries="
  ld-linux-aarch64.so.1
  ld-linux-x86-64.so.2
  libc.so.6
  libdl.so.2
  libm.so.6
  libpthread.so.0
  librt.so.1
  libX11.so.6
  libXext.so.6
  libXrender.so.1
  libasound.so.2
  libfreetype.so.6
  libwayland-client.so.0
  libwayland-cursor.so.0
  libxkbcommon.so.0
"

# Shared libraries the Linux (glibc) JBR images ship in lib/ because the target
# system may not have them. libawt_xawt.so links libXi and libXtst, which are
# not installed everywhere (the Linux Terminal on Googlebooks has no libXi), and
# without them the X11 toolkit fails to load. libawt_xawt.so finds them next to
# itself through its $ORIGIN rpath. Both need only libX11/libXext and old glibc
# symbol versions.
declare -r linux_bundled_libraries="
  libXi.so.6
  libXtst.so.6
"

# Debian packages that provide $linux_bundled_libraries; their copyright files
# are shipped with the images.
declare -r linux_bundled_library_packages="
  libxi6
  libxtst6
"

# Creates the directory if it does not exist and returns its absolute path
function make_target_dir() {
  mkdir -p "$1" && realpath "$1"
}

# Converts version string to comparable number `12.3` -> 012003000000. Works for at most 4 fields
function ver { printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' '); }

# Sanitize build number for `--with-version-opt` configure option
# Remove all non numeric symbols, return `0` if input don't have any numbers in it
function numeric_build_number {
  local -r numbers=$(echo "$1" | tr -dc '[^0-9]')
  echo ${numbers:-"0"}
}

# Installs autoconf into specified directory. The second argument is working directory.
function install_autoconf() {
  local -r workdir=$(make_target_dir "$2")
  local -r installdir=$(make_target_dir "$1")
  tar -C "$workdir" -xzf "$top/toolchain/jdk/deps/src/autoconf-2.69.tar.gz"
  (cd "$workdir"/autoconf-2.69 &&
     ./configure --prefix="$installdir" ${quiet:+--quiet} &&
     make ${quiet:+-s} install
  )
}

function source_date_epoch() {
  cd $1
  # https://htmlpreview.github.io/?https://raw.githubusercontent.com/openjdk/jdk/master/doc/building.html#reproducible-builds
  # https://reproducible-builds.org/docs/source-date-epoch/
  if source_timestamp=$(git log -1 --pretty=%ct); then
   echo $source_timestamp
  else
   find . -type f -print0 | xargs -0 stat -f "%m %N" | sort -rn | head -1 | cut -f1 -w
  fi
}

function verifyMacBinaryCpuArchitecture() {
  declare -r binary=$1
  declare -r expected_arch=$2

  if [ ! -f "$binary" ]; then
    echo "$binary does not exists"
    exit 2
  fi

  declare -r archs=$(lipo -archs $binary)
  echo "$binary archs: $archs"
  if [[ ! "$archs" =~ "$expected_arch" ]]; then
    echo "$binary doesn't have $expected_arch architecture "
    exit 3
  fi
}

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
        "$ar" -p "$deb" data.tar.xz | (cd "$target_dir" && tar -Jx)
        ;;
      data.tar.bz2)
        "$ar" -p "$deb" data.tar.bz2 | (cd "$target_dir" && tar -jx)
        ;;
      data.tar.gz)
        "$ar" -p "$deb" data.tar.gz | (cd "$target_dir" && tar -zx)
        ;;
      data.tar.zst)
        "$ar" -p "$deb" data.tar.zst | (cd "$target_dir" && tar -I zstd -x)
        ;;
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

# Verifies that an ELF binary was built for the expected machine. Used by the
# cross builds, where a silently misconfigured toolchain would otherwise produce
# a build-host binary that looks perfectly fine until it reaches a target machine.
function verifyLinuxBinaryCpuArchitecture() {
  declare -r binary=$1
  declare -r expected_arch=$2

  if [ ! -f "$binary" ]; then
    echo "$binary does not exists"
    exit 2
  fi

  declare -r arch=$("$clang_bin/llvm-readelf" --file-header "$binary" | awk -F: '/Machine/ { print $2 }' | xargs)
  echo "$binary machine: $arch"
  if [[ ! "$arch" =~ "$expected_arch" ]]; then
    echo "$binary is not built for $expected_arch"
    exit 3
  fi
}

# Prints "<library> <file>" for every DT_NEEDED entry of every ELF file under
# the given directory that no ELF file under that directory provides, either by
# DT_SONAME or by file name. These are the libraries the image expects to find
# on the machine it runs on. Works for any target architecture, so a cross
# build can check its output without running it.
function listUnresolvedLinuxLibraries() {
  local -r image=$1
  local -r readelf="$clang_bin/llvm-readelf"
  local -A provided=()
  local -a needed=()
  local file name line

  while IFS= read -r -d '' file; do
    [[ "$(head -c 4 "$file" | tr -d '\0')" == $'\x7fELF' ]] || continue
    name=$(basename "$file")
    provided[$name]=1
    while IFS= read -r line; do
      case "$line" in
        *"(SONAME)"*) name=${line##*[}; provided[${name%]}]=1 ;;
        *"(NEEDED)"*) name=${line##*[}; needed+=("${name%]} ${file#$image/}") ;;
      esac
    done < <("$readelf" --dynamic-table "$file")
  done < <(find "$image" -type f -print0)

  for line in "${needed[@]}"; do
    [[ -n "${provided[${line%% *}]:-}" ]] || echo "$line"
  done | sort
}

# Fails unless every DT_NEEDED entry in the image resolves either to a library
# inside the image or to one of the given library names (the libraries the
# target system is expected to have installed).
#   $1 image, $2 whitespace-separated library names
function verifyLinuxSharedLibraryDependencies() {
  local -r image=$1
  local -A expected_from_system=()
  local lib line unresolved=""
  for lib in $2; do
    expected_from_system[$lib]=1
  done
  while IFS= read -r line; do
    [[ -n "${expected_from_system[${line%% *}]:-}" ]] || unresolved+="$line"$'\n'
  done < <(listUnresolvedLinuxLibraries "$image")
  if [[ -n "$unresolved" ]]; then
    echo "$image needs shared libraries that it does not ship:"
    printf "%s" "$unresolved"
    exit 4
  fi
  echo "$image: all DT_NEEDED entries resolve"
}

# Copies $linux_bundled_libraries from the sysroot into <image>/lib, and the
# copyright files of their Debian packages into
# <image>/legal/bundled-libraries/<package>/. Each copied library must be built
# for the expected machine, as reported by llvm-readelf ("X86-64", "AArch64").
#   $1 image, $2 sysroot, $3 library directory inside the sysroot,
#   $4 expected machine
function bundleLinuxLibraries() {
  local -r image=$1
  local -r root=$2
  local -r libdir=$3
  local -r expected_arch=$4
  local lib pkg
  for lib in $linux_bundled_libraries; do
    cp -L "$libdir/$lib" "$image/lib/$lib"
    verifyLinuxBinaryCpuArchitecture "$image/lib/$lib" "$expected_arch"
  done
  for pkg in $linux_bundled_library_packages; do
    mkdir -p "$image/legal/bundled-libraries/$pkg"
    cp "$root/usr/share/doc/$pkg/copyright" "$image/legal/bundled-libraries/$pkg/"
  done
}

# jlink builds the runtime image from jmods, which do not contain the bundled
# libraries, so they are copied over from the JDK image.
#   $1 JDK image, $2 runtime image
function copyBundledLinuxLibraries() {
  local -r jdk_image=$1
  local -r runtime_image=$2
  local lib
  for lib in $linux_bundled_libraries; do
    cp "$jdk_image/lib/$lib" "$runtime_image/lib/$lib"
  done
  cp -r "$jdk_image/legal/bundled-libraries" "$runtime_image/legal/"
}

function usage() {
  declare -r prog="${0##*/}"
  cat <<EOF
Usage:
    $prog [-q] [-d <dist_dir>] [-o <out_dit>] -b <build_number>
The JDK is built in <out_dir> (or "out" if unset).
If <dist_dir> is set, artifacts are created there.
Specify JBR build number with <build_number>
With -q, runs with minimum noise.
EOF
  exit 1
}


while getopts 'qb:d:o:' opt; do
  case $opt in
    b) build_number=$OPTARG ;;
    o) out_dir_option=$OPTARG;;
    d) dist_dir_option=$OPTARG;;
    q) quiet=t ;;
    *) usage ;;
  esac
done
shift $(($OPTIND-1))
(($#==0)) || usage

# use ENV values or defaults if command line parameters are not set
if [ -z "${out_dir_option:-}" ]; then
    out_dir_option=${OUT_DIR:-"out"}
fi

if [ -z "${build_number:-}" ]; then
    build_number=${BUILD_NUMBER:-"dev"}
fi

if [ -z "${dist_dir_option:-}" ]; then
    dist_dir_option=${DIST_DIR:-"$out_dir_option/dist"}
fi

# Create output directories
declare out_path=$(make_target_dir "${out_dir_option}")
declare dist_dir="$(make_target_dir "${dist_dir_option}")"
declare build_dir="$out_path/build"
declare top=$(realpath "$(dirname "$0")/../../..")
declare -r autoconf_dir=$(make_target_dir "$out_path/autoconf")

case $(uname) in
  Linux)
    declare -r clang_bin="$top/prebuilts/clang/host/linux-x86/clang-r614150/bin"
    declare -r sysroot="$out_path/sysroot"
    ;;
  Darwin)
    declare -r clang_bin="$top/prebuilts/clang/host/darwin-x86/clang-r487747c/bin"
    declare -r sysroot=$(xcrun --show-sdk-path)
    ;;
  CYGWIN*) # Windows Cygwin
    ;;
  *) echo "unknown OS:" $(uname) && exit 1;;
esac

[[ -n "${quiet:-}" ]] || set -x
