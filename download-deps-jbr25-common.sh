#!/bin/bash
#
# Helpers shared by the download-deps-jbr25-* scripts.

# Extracts the Debian copyright file out of a .deb and prints it to stdout.
deb_to_license() {
	local data=$(ar t $1 | grep data.tar)
	local decompress
	if [ "${data}" = "data.tar.xz" ]; then
		decompress="-J"
	elif [ "${data}" = "data.tar.bz2" ]; then
		decompress="-j"
	elif [ "${data}" = "data.tar.gz" ]; then
		decompress="-z"
	elif [ "${data}" = "data.tar.zst" ]; then
		decompress="-I zstd"
	else
		echo "Unrecognized data file '${data}' in $1" >&2
		exit 1
	fi

	ar p $1 ${data} | tar x ${decompress} -O --wildcards "./usr/share/doc/*/copyright" 2>/dev/null || true
}

# Writes a LICENSE file in the current directory, concatenating the copyright
# file of every .deb found there.
write_deb_licenses() {
	rm -f LICENSE LICENSE.tmp
	for i in *.deb; do
		deb_to_license $i >LICENSE.tmp
		if [ -s LICENSE.tmp ]; then
			(
				echo $i
				printf '=%.0s' $(seq 1 ${#i})
				echo
				cat LICENSE.tmp
				echo
			) >>LICENSE
		fi
		rm -f LICENSE.tmp
	done
}

# True when two source packages hold the same content.
#
# Debian source tarballs are downloaded verbatim and compare byte for byte, but
# Alpine's abuild repacks its .src.tar.gz on every run, so the gzip and tar
# timestamps differ even when the packaged files are identical. Fall back to
# comparing the extracted trees in that case.
same_source() {
	if cmp -s "$1" "$2"; then return 0; fi
	case "$1" in
	*.tar.gz | *.tgz) ;;
	*) return 1 ;;
	esac

	local tmp=$(mktemp -d)
	local rc=1
	mkdir -p "$tmp/a" "$tmp/b"
	if tar xzf "$1" -C "$tmp/a" && tar xzf "$2" -C "$tmp/b"; then
		diff -r "$tmp/a" "$tmp/b" >/dev/null 2>&1 && rc=0
	fi
	rm -rf "$tmp"
	return $rc
}

# Moves the source packages a target just downloaded into the shared source
# tree and leaves a relative symlink behind.
#
# Source packages are architecture independent, so every target that uses a
# given library downloads a byte for byte identical tarball. Storing one copy
# and symlinking to it keeps the per-target record of which sources correspond
# to which shipped artifact, which is what the source tree is there for, without
# checking the same 160 MB kernel tarball into the repository once per target.
#
#   $1  the target's own src directory, e.g. <deps>/linux_x64/src
#   $2  the shared source directory, e.g. <deps>/linux_src
share_sources() {
	local target_src="$1"
	local shared_src="$2"
	local shared_name=$(basename "$shared_src")

	mkdir -p "$shared_src" "$target_src"

	for f in "$target_src"/*; do
		[ -e "$f" ] || continue
		# Already shared by an earlier run.
		if [ -L "$f" ]; then continue; fi

		local name=$(basename "$f")
		if [ -e "$shared_src/$name" ]; then
			# Same file name is expected to mean the same source. Verify
			# rather than assume, because silently keeping the wrong source
			# tarball would only be noticed during a license audit.
			if ! same_source "$f" "$shared_src/$name"; then
				echo "Source package $name differs between targets, refusing to share it" >&2
				exit 1
			fi
			rm -f "$f"
		else
			mv "$f" "$shared_src/$name"
		fi
		ln -sfn "../../$shared_name/$name" "$f"
	done
}
