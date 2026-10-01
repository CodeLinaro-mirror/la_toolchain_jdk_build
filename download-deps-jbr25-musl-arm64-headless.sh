#!/bin/bash -e

# Downloads the aarch64 musl dependencies needed to hermetically build the
# headless JBR25 for linux-aarch64 against musl libc. Expects to be run inside
# the Alpine container built from Dockerfile.musl_deps, via
# download-deps-jbr25-in-docker.sh.
#
# This is the JBR counterpart of download-deps-musl.sh, limited to what a
# --enable-headless-only build links or includes. Without X11 and Wayland the
# list is short: ALSA is linked by libjsound; CUPS, fontconfig and dbus are
# dlopen'ed at runtime, so only their headers are needed. freetype, libpng and
# zlib come bundled with the JDK sources.
#
# The container stays x86_64; `apk --arch aarch64` downloads foreign packages
# without any emulation. Nothing from these packages is executed here.

arch=aarch64

# `apk fetch` does not resolve dependencies, so every package has to be named
# explicitly.
dev_pkgs="
  alsa-lib-dev
  cups-dev
  dbus-dev
  fontconfig-dev
"

# Runtime packages for the libraries that reach a link line. An Alpine -dev
# package ships an unversioned .so symlink pointing into the runtime package;
# without the runtime package the symlink dangles and the linker falls back to
# a non-PIC static archive, which aarch64 rejects with
#
#   relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol
#   '__stack_chk_guard'; recompile with -fPIC
#
# Only libasound is linked; CUPS, fontconfig and dbus are loaded with dlopen.
runtime_pkgs="
  alsa-lib
"

pkgs="$dev_pkgs $runtime_pkgs"

source $(dirname $0)/download-deps-jbr25-common.sh

# The caller bind-mounts toolchain/jdk/deps/jbr25 here.
deps_root=$(cd $(dirname $0)/../deps && pwd)
target_dir=$deps_root/linux_musl_arm64_headless

# This container has no unprivileged-user entrypoint, so it runs as root and can
# clear whatever a previous run left behind regardless of ownership.
rm -rf "$target_dir"
mkdir -p "$target_dir/src"
cd "$target_dir"

# Alpine signs each architecture's repositories with different keys, and apk
# only trusts what is in /etc/apk/keys, which the image populates for its own
# architecture only. The keys for every architecture ship with the alpine-keys
# package under /usr/share/apk/keys/<arch>; without this copy, `apk --arch
# aarch64 update` fails with "UNTRUSTED signature".
cp /usr/share/apk/keys/${arch}/* /etc/apk/keys/

apk --arch ${arch} update

echo "Requested packages: $pkgs"
apk --arch ${arch} fetch $pkgs

# Collect the corresponding source packages. Sources are architecture
# independent, so these are built from aports at the container's Alpine release.
aports_dir=$(mktemp -d)
# Same endpoint as download-deps-musl.sh. The gitlab.alpinelinux.org HTTPS
# endpoint answers 418 from here.
git clone --depth 1 --branch v$(cat /etc/alpine-release) \
  git://git.alpinelinux.org/aports ${aports_dir}

for apk_file in *.apk; do
  origin=$(tar xf "${apk_file}" -O .PKGINFO | awk '$1 ~ /^origin$/ { print $3 }')
  [ -n "${origin}" ] || continue
  # A single origin can produce several packages (for example alsa-lib and
  # alsa-lib-dev), so only build each source package once.
  [ -z "$(ls src/${origin}-*.src.tar.gz 2>/dev/null)" ] || continue

  for repo in main community; do
    if [ -d "${aports_dir}/${repo}/${origin}" ]; then
      # abuild writes the source package into <-P>/src, so -P is $PWD here.
      abuild -F -C "${aports_dir}/${repo}/${origin}/" -P "$PWD" srcpkg
      break
    fi
  done
done

rm -rf ${aports_dir}

share_sources "$target_dir/src" "$deps_root/linux_src"

# Everything above was created as root. Hand the results back to the invoking
# user so that the host, and the Ubuntu containers that drop privileges, can
# write here afterwards.
if [ -n "${USER_ID}" ]; then
  chown -R "${USER_ID}:${GROUP_ID:-${USER_ID}}" "$target_dir" "$deps_root/linux_src"
fi
