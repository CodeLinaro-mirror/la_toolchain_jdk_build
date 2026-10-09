# Building JetBrains Runtime (JBR) in the Android OpenJDK Repository

This document records the architecture, hermeticity requirements, dependency management, cross-compilation design choices, and known gotchas for building JetBrains Runtime 25 (`JBR25`) in `toolchain/jdk/build/`.

---

## 1. Build Matrix & Scripts

All build scripts reside in `toolchain/jdk/build/` and accept common flags parsed by `build-jetbrainsruntime-common.sh`:
- `-o <out_path>`: Build working directory (default: `$top/out`).
- `-d <dist_dir>`: Output directory for packaged `.zip` artifacts and logs (default: `$out_path/dist`).
- `-b <build_number>`: Build identifier embedded in version strings (default: `dev`).
- `-q`: Quiet mode (`LOG=warn`, `zip -q`, `unzip -q`).

| Target Platform | Script | Compilation Mode | Libc & Floor | Sysroot Source |
| :--- | :--- | :--- | :--- | :--- |
| `linux-x86_64` | `build-jbr25-linux-x64.sh` | Native (`x86_64` host) | `glibc` 2.19 | Ubuntu 20.04 amd64 debs (`deps/jbr25/linux_x64`) + Ubuntu 14.04 `libc6`/`libgcc`/`libstdc++` overlay (`deps/`) |
| `linux-aarch64` (glibc) | `build-jbr25-linux-aarch64.sh` | Cross (`x86_64` host) | `glibc` 2.31 (symbols $\le$ `2.29`) | Ubuntu 20.04 arm64 debs (`deps/jbr25/linux_arm64`) |
| `linux-musl-aarch64-headless` (musl, headless-only) | `build-jbr25-linux-musl-aarch64-headless.sh` | Cross (`x86_64` host) | `musl` 1.2.6, shipped in `lib/` | `prebuilts/build-tools/sysroots/aarch64-unknown-linux-musl` + Alpine 3.23 aarch64 apks (`deps/jbr25/linux_musl_arm64_headless`) |
| `mac-x64` | `build-jbr25-mac-x64.sh` | Native (`x86_64` macOS) | macOS SDK | Xcode macOS SDK |
| `mac-aarch64` | `build-jbr25-mac-aarch64.sh` | Native (`arm64` macOS) | macOS SDK | Xcode macOS SDK |
| `win-x64` | `build-jbr25-win-x64.{sh,cmd}` | Native (`x86_64` Windows) | MSVC CRT | Visual Studio toolchain |

Each build produces three primary archives in `<dist_dir>`:
1. `jdk.zip`: Full JDK image (`images/jdk` without `demo/` and `man/`, debuginfo stripped to `.diz`).
2. `jdk-debuginfo.zip`: Zip archive containing all `.diz` symbol files from `images/jdk`.
3. `jdk-runtime.zip`: Stripped JRE runtime image created via `jlink` using the module list combined from `jb/project/tools/common/modules.list` and `toolchain/jdk/build/studio-modules.list` (excluding deprecated experimental AOT/JIT compiler modules `jdk.aot`, `jdk.internal.vm.compiler`, and `jdk.internal.vm.compiler.management`).

---

## 2. Hermeticity Policy

**Core Rule:** Nothing from the build host's system libraries, headers, or compilers may be linked into or used to configure or compile build artifacts.

### What Must Be Hermetic
- **Toolchain & Binutils:** Provided by `prebuilts/clang/host/linux-x86/clang-r614150/bin` (`clang`, `clang++`, `lld`, `llvm-ar`, `llvm-nm`, `llvm-objcopy`, `llvm-objdump`, `llvm-strip`, `llvm-cxxfilt`).
- **Target Sysroot (`$sysroot`):** All target headers and shared/static libraries (`libc`, `libm`, `libpthread`, `libstdc++.a` / `libc++.a`, X11, Wayland, ALSA, CUPS, D-Bus, Fontconfig, FreeType).
- **Host Sysroot (`$host_tools`):** Headers and libraries used when compiling build-time tools that run on the `x86_64` build host (such as Hotspot's `adlc` code generator).
- **Code Generators:**
  - `autoconf`: OpenJDK/JBR source trees in this repository do not ship a pre-generated `make/autoconf/generated-configure.sh`. `configure` regenerates it on every build. To prevent picking up the host OS's autoconf version, scripts call `install_autoconf`, building autoconf 2.69 hermetically from `toolchain/jdk/deps/src/autoconf-2.69.tar.gz`. (Tracked for older scripts in [b/561712160](http://b/561712160)).
  - `wayland-scanner`: Unpacked into `$host_tools/usr/bin/wayland-scanner` from the vendored amd64 `libwayland-bin` package (`deps/jbr25/linux_host_tools`).
- **Boot & Build JDK:** Provided by `prebuilts/jdk/studio/jbr25/linux`.

### What Is Permitted from the Host OS
Generic POSIX/OS utilities that merely move bytes around and do not link into or shape produced binaries are permitted from the host environment: `bash`, `make`, `perl`, `zip`, `unzip`, `tar`, `sed`, `grep`, `awk`, `file`, and `git`.

---

## 3. Vendored Dependency Layout (`toolchain/jdk/deps/jbr25/`)

All Linux JBR25 dependencies are fetched via Docker using a single entry point:

```bash
./toolchain/jdk/build/download-deps-jbr25-in-docker.sh [host-tools|x64|arm64|musl-arm64-headless|all]
```

### Directory Structure & Source Deduplication
```text
toolchain/jdk/deps/jbr25/
├── linux_src/          # Shared upstream source tarballs (.orig.tar.*, .debian.tar.*, .dsc) (333 MB)
├── linux_host_tools/   # amd64 packages executed on the build host (libwayland-bin) (32 KB)
├── linux_x64/          # Ubuntu 20.04 amd64 binary & -dev .deb packages (6.6 MB)
├── linux_arm64/        # Ubuntu 20.04 arm64 + all binary & -dev .deb packages (15 MB)
└── linux_musl_arm64_headless/  # Alpine 3.23 aarch64 .apk packages for the headless musl build (650 KB)
```

- **Source Sharing (`share_sources` in `download-deps-jbr25-common.sh`):**
  Upstream source packages are architecture-independent (e.g., `linux_5.4.0.orig.tar.gz` alone is 163 MB). Each target directory contains a `src/` subdirectory populated strictly with relative symlinks (`../../linux_src/<filename>`). Deduplicating `src/` across `x64` and `arm64` avoids checking in a second copy of every shared tarball.
- **Collision Verification:**
  When moving a downloaded source archive into `linux_src/`, `share_sources` refuses to replace an existing file of the same name unless `same_source` confirms identical content: `cmp -s` first, and for `.tar.gz` a comparison of the extracted trees, because Alpine's `abuild srcpkg` regenerates its `.src.tar.gz` with fresh tar/gzip timestamps on every run. Unreferenced files in `linux_src/` are pruned at the end of `download-deps-jbr25-in-docker.sh`.
- **Container Privilege Handling:**
  The Ubuntu container (`Dockerfile.jbr25_deps`) drops privileges via `docker-entrypoint.sh` using `USER_ID`/`GROUP_ID`, so downloaded files are owned by the invoking user. The same image downloads host-tools, amd64 and arm64 packages (arm64 is enabled as a foreign dpkg architecture via `ports.ubuntu.com`).
  The Alpine container (`Dockerfile.musl_deps`, shared with `download-deps-musl.sh`) has no such entrypoint and runs as root; `download-deps-jbr25-musl-arm64-headless.sh` ends with `chown -R $USER_ID:$GROUP_ID` over its target directory and `linux_src/`. Alpine is required because Ubuntu packages neither `apk-tools` nor `abuild`, which produces the Alpine source packages. `apk --arch aarch64 fetch` downloads foreign packages from an x86_64 container without emulation. Alpine signs each architecture's repositories with different keys and `apk` trusts only `/etc/apk/keys/`, which holds the image's own architecture; the script copies the aarch64 keys from `/usr/share/apk/keys/aarch64/` (shipped by the preinstalled `alpine-keys` package), otherwise the index is rejected with `UNTRUSTED signature`. `apk fetch` does not resolve dependencies, so every package is named explicitly.

### Package Selection & Pruning Decisions
1. **Toolchain Link-Only Packages (`libgcc-s1` and `libstdc++6`):**
   - On Ubuntu 20.04, `libgcc-s1` and `libstdc++6` are built from the `gcc-10` source package (87 MB tarball), whereas static C++ linking (`--with-stdc++lib=static`) consumes `libgcc.a` and `libstdc++.a` from `libgcc-9-dev` / `libstdc++-9-dev` (`gcc-9` source package).
   - `libgcc-s1` cannot be omitted because `libgcc-9-dev` ships `/usr/lib/gcc/aarch64-linux-gnu/9/libgcc_s.so` as a linker script (`GROUP ( libgcc_s.so.1 -lgcc )`); without `libgcc_s.so.1`, `lld` fails during configure's initial compiler check (`unable to find libgcc_s.so.1`).
   - Both `.deb` files are downloaded in `target_toolchain_linkonly_pkgs`, but excluded from `apt-get source` because neither `libgcc_s.so.1` nor `libstdc++.so.6` appears in `DT_NEEDED` of any shipped binary.
2. **Debian `-dev` Symlinks vs. Runtime Packages:**
   - Debian `-dev` packages ship `.so` symlinks (e.g., `libXtst.so -> libXtst.so.6`) whose targets live in runtime packages (`libxtst6`).
   - If a library is linked by OpenJDK but its runtime `.deb` is omitted, the `.so` symlink dangles and the linker falls back to the static `.a` archive. On `aarch64`, linking non-PIC `libXtst.a` into `libawt_xawt.so` fails with relocation error `R_AARCH64_ADR_PREL_PG_HI21 against symbol '__stack_chk_guard'`. (On `x86_64` this used to go unnoticed: the linker statically linked `libXi.a` and `libXtst.a` into `libawt_xawt.so`, [b/561712262](http://b/561712262). Both Linux targets now download `libxi6`/`libxtst6`.)
   - Conversely, runtime packages for libraries that are *never* linked by OpenJDK (`libpng16-16`, `libxrandr2`, `libxt6`, `libice6`, `libsm6`) are excluded. `lib-x11.m4` defines `X_PRE_LIBS="-lSM -lICE"` but never `AC_SUBST`s it, and `make/` never links `-lXt`, `-lICE`, `-lSM`, or `-lXrandr`. Header packages (`libxt-dev`, `libxrandr-dev`) are kept because `lib-x11.m4` checks for `Intrinsic.h` and `Xrandr.h` with `AC_MSG_ERROR`.
3. **Headless musl Package Set:**
   - With `--enable-headless-only`, `libraries.m4` sets `NEEDS_LIB_X11`, `NEEDS_LIB_WAYLAND` and `NEEDS_LIB_SPEECHD` to false, so no X11, Wayland or xkbcommon package is needed. ALSA, CUPS, fontconfig and dbus are still configured: `lib-dbus.m4` requires dbus headers on Linux regardless of headless mode (`libawt` compiles `dbus_interface.c`). Only `libasound` reaches a link line (`libjsound`); CUPS, fontconfig and dbus are `dlopen`ed, so their `-dev` packages suffice. The complete list is `alsa-lib`, `alsa-lib-dev`, `cups-dev`, `dbus-dev`, `fontconfig-dev`. freetype, libpng and zlib are bundled from the JDK sources.

---

## 4. Cross-Compilation Architecture & Gotchas (`linux-x86_64` $\to$ `linux-aarch64`)

### 4.1 Target-Prefixed Compiler Wrapper (`<triple>-clang`)
Android's prebuilt `clang` binary is a Go wrapper that executes `clang-real` relative to its own binary directory (`argv[0]`); creating a symlink to `clang` from another directory fails with `clang-real: no such file or directory`.

Furthermore, the target triple (`--target=aarch64-unknown-linux-gnu`) must be baked into a wrapper script named `<triple>-clang` rather than passed solely via `--with-extra-cflags`. Autoconf's early `AC_PROG_CC` and `AC_PROG_CPP` probes run before extra cflags are applied; without a target-aware driver, clang searches x86_64 multiarch include paths inside the aarch64 sysroot, failing with `'bits/libc-header-start.h' file not found`.

### 4.2 Hermetic Host Sysroot (`$host_tools`) for `BUILD_CC` / `BUILD_CXX`
OpenJDK's `toolchain.m4` hardcodes `BUILD_CC` discovery on Linux to `cc gcc` (`UTIL_REQUIRE_PROGS(BUILD_CC, cc gcc)`), picking up the host OS's system GCC and failing JBR's clang-only check unless `BUILD_CC` and `BUILD_CXX` are explicitly supplied.

Even when `--with-build-jdk` is passed, Hotspot compiles build-host tools such as `adlc` (`src/hotspot/share/adlc/`) for `x86_64` using `BUILD_CXX` with `-std=c++14 -static-libstdc++`. On CI container images where the host OS only has GCC 4.8 installed (`/usr/lib/gcc/x86_64-linux-gnu/4.8/libstdc++.a`), linking `adlc` without a host sysroot fails with:
```text
ld.lld: error: undefined symbol: operator delete(void*, unsigned long)
>>> defined in: /usr/lib/gcc/x86_64-linux-gnu/4.8/libstdc++.a(del_op.o)
```
The aarch64 build script unpacks the repository's hermetic x86_64 host packages (`toolchain/jdk/deps/{libc6,linux-libc-dev,libgcc,libstdc}*.deb`, providing GCC 8's `libstdc++.a` and glibc 2.19) into `$host_tools` and wraps `BUILD_CC` / `BUILD_CXX` (`host-clang` / `host-clang++`) with `--sysroot="$host_tools" -fuse-ld=lld`.

### 4.3 Skipping Interim `buildjdk` (`--with-build-jdk`)
By default (`CREATE_BUILDJDK=true`), cross-compiling OpenJDK compiles an entire interim x86_64 `buildjdk` (`<out>/build/buildjdk/`) before building the target JDK, roughly doubling build time.

Passing `--with-build-jdk` sets `CREATE_BUILDJDK=false`, using the prebuilt x86_64 `boot_jdk` (`prebuilts/jdk/studio/jbr25/linux`) to run `jmod` and `jlink`. This avoids compiling `buildjdk` and halves cross-build time.

### 4.4 Headless `HelloClasslist` Execution (`--limit-modules java.base,java.logging`)
During `make images`, `GenerateLinkOptData.gmk` runs `build.tools.classlist.HelloClasslist` to generate CDS and link-optimization data (`support/link_opt/classlist` and `default_jli_trace.txt`):

- When `EXTERNAL_BUILDJDK=false` (native builds), OpenJDK builds `support/interim-image` containing only `INTERIM_IMAGE_MODULES` (`java.base` and `java.logging`). When `HelloClasslist` iterates over `clear.classlist` and calls `Class.forName("sun.awt.X11GraphicsDevice")`, `ClassNotFoundException` is thrown and caught by `catch (Exception e)` in `HelloClasslist.java`.
- When `EXTERNAL_BUILDJDK=true` (`--with-build-jdk`), `GenerateLinkOptData.gmk` skips building `interim-image` and executes `HelloClasslist` directly on `BUILD_JDK/bin/java`. Because `boot_jdk` is a full JBR25 image containing `java.desktop`, `sun.awt.X11GraphicsDevice` is found and initialized.
- In JBR25, `X11GraphicsDevice.<clinit>` unconditionally calls native method `getXrmXftDpi(-1)`, defined in `libawt_xawt.so`. When `DISPLAY` is unset (headless CI containers), AWT loads `libawt_headless.so` instead of `libawt_xawt.so`, causing `X11GraphicsDevice.<clinit>` to throw `java.lang.UnsatisfiedLinkError` (a `java.lang.Error`, not caught by `catch (Exception e)`).

To make classlist generation deterministic and independent of host X11 state:
1. The cross-build script explicitly runs `unset DISPLAY`.
2. The script constructs a wrapper directory `$out_path/build-jdk` around `$boot_jdk` where `bin/java` prepends `--limit-modules java.base,java.logging` whenever invoked with `*HelloClasslist*`, matching the module set of OpenJDK's `interim-image`.
   - *Caution:* When populating `$build_jdk/bin/` with symlinks to `$boot_jdk/bin/*`, `java` must be skipped and `rm -f "$build_jdk/bin/java"` executed before writing the wrapper script. Otherwise, redirecting output (`cat > "$build_jdk/bin/java"`) follows the symlink and overwrites `$boot_jdk/bin/java` in place with a self-recursive script. Note also that `--limit-modules` must only be passed on `HelloClasslist` invocations and not on `-Xshare:dump`, which rejects `--limit-modules`.

### 4.5 Native Debug Symbol Stripping (`llvm-objcopy`)
`jlink --strip-debug` invokes `objcopy` from `PATH`. The host x86_64 GNU `objcopy` cannot parse `aarch64` ELF binaries, emitting `Unable to recognise the architecture of the input file`, leaving target `.so` files unstripped while exiting `0`. Cross-compilation scripts replace `--strip-debug` with:
```bash
--strip-java-debug-attributes \
--strip-native-debug-symbols exclude-debuginfo-files:objcopy=$clang_bin/llvm-objcopy
```

### 4.6 CDS Archive Generation in Cross-Builds
Default CDS archive dumping (`--generate-cds-archive`) is automatically disabled when cross-compiling (`checking if CDS archive is available... no (not possible with cross compilation)`) because dumping a shared archive requires executing the target `aarch64` JVM binary on the build host. Passing `--enable-jvm-feature-cds` to `configure` is still required so the compiled JVM supports CDS at runtime.

### 4.7 musl Specifics (`build-jbr25-linux-musl-aarch64-headless.sh`)
The headless musl build follows `build-openjdk25-linux-musl.sh`, the musl JDK used by the Android platform build, with the JBR configuration of the other scripts. It exists for the Android CLI tools, which run the JVM with `-Djava.awt.headless=true` and `jlink` their own runtime from the JDK's `jmods` (`tools/vendor/google/cli/jbinary` in `studio-main`), and must not depend on the host's libc or desktop libraries.
- **Sysroot:** `prebuilts/build-tools/sysroots/aarch64-unknown-linux-musl` (hermetic, relinterp-based musl 1.2.6: produced binaries have no `PT_INTERP`, which is a property of that sysroot, not a cross-compilation defect) is copied into `$sysroot`, and the Alpine apks are unpacked on top. Alpine is not multiarch, so everything is under `usr/lib`.
- **Shipped libc:** `lib/libc_musl.so` and `lib/libjemalloc5.so` are copied into both images (plus `legal/musl/LICENSE`); `bin/java` and the JDK libraries find them through their `$ORIGIN` rpaths. The sysroot's `libc.so` is the linker script `GROUP ( libc_musl.so libjemalloc5.so )`, so jemalloc is linked implicitly today; that implicit link is going away ([b/533100825](http://b/533100825)), so the script passes `-ljemalloc5` explicitly, as `build-openjdk25-linux-musl.sh` does.
- **`-DMUSL_LIBC` leak into build-host flags:** `flags-cflags.m4` derives `-DMUSL_LIBC` from the *target* libc into `OS_CFLAGS`, which ends up in both the target and the build-platform `CFLAGS_JVM_COMMON`. Compiling the interim build JDK's Hotspot on the glibc host then fails (`os_linux.cpp:143:14: error: static declaration of 'dlvsym' follows non-static declaration`). Upstream assumes a native Alpine build. `--with-build-jdk` (section 4.3) sidesteps the interim JDK entirely.
- **Headless-only:** `--enable-headless-only` drops `libawt_xawt`, `libawt_wlawt` and `libsplashscreen` (`AwtLibraries.gmk`; `libjawt` is still built, with `-DHEADLESS` and linked against `libawt_headless`), and with them every X11 and Wayland dependency, including `wayland-scanner`. `java.desktop` is still built and works in headless mode. `verifyHeadlessImage` fails the build if `libawt_headless.so` is missing or any of the toolkit libraries is present.
- **Loader search path:** the bundled musl loader searches only `/lib:/usr/local/lib:/usr/lib` (plus `LD_LIBRARY_PATH` and the `needed_by` chain's rpaths) and never Debian multiarch directories. On a glibc distribution a system library would therefore neither be found nor be loadable (it would be glibc-linked). This is why freetype is bundled here (section 5). `libasound.so.2` is the only remaining external `DT_NEEDED` (`$musl_headless_target_system_libraries`); `libjsound` loads only when sound is used. `libfontconfig.so.1` and `libcups.so.2` are `dlopen`ed and resolve only where a musl build of them is installed under `/usr/lib` (Alpine); fontconfig-dependent font lookup on other distributions is an open item.

---

## 5. Platform & Configuration Decisions

- **FreeType Policy (`JDK-8193017`):**
  Use `--with-freetype=system` on the glibc Linux targets (`x86_64`, `aarch64`) and `--with-freetype=bundled` on macOS and Windows. On Linux, `configure` checks for an unversioned `libfreetype.so` library file; scripts create `ln -sfn libfreetype.so.6 $sysroot/usr/lib[/aarch64-linux-gnu]/libfreetype.so` and pass `--with-freetype-include="$sources_dir/src/java.desktop/share/native/libfreetype/include"`. The headless musl build uses `--with-freetype=bundled`, like `build-openjdk25-linux-musl.sh`: the musl loader cannot use a glibc distribution's freetype (section 4.7), and `libfontmanager.so` links it unconditionally.
- **Bundled `libXi` / `libXtst`:**
  `libawt_xawt.so` links `libXi.so.6` and `libXtst.so.6`, which are not installed on every desktop system (the Googlebook Linux Terminal image has no `libxi6`); without them the X11 toolkit fails to load. Both Linux scripts copy them from the sysroot into `lib/` of the JDK and runtime images (`bundleLinuxLibraries`, `copyBundledLinuxLibraries`), with the Debian copyright files under `legal/bundled-libraries/`. `libawt_xawt.so` finds them through its `$ORIGIN` rpath. `verifyLinuxSharedLibraryDependencies` then fails the build if any `DT_NEEDED` entry is neither shipped in the image nor in `$linux_target_system_libraries` (glibc, `libX11`, `libXext`, `libXrender`, `libfreetype`, `libasound`, `libwayland-client`, `libwayland-cursor`, `libxkbcommon`).
- **Wayland Protocols Overlay:**
  JBR25's Wakefield/AWT implementation requires Wayland protocols (`fractional-scale-v1`, `idle-notify-v1`) introduced after Ubuntu 20.04's `wayland-protocols` 1.20 package. Both Linux builds (`x86_64` and `aarch64`) unpack `toolchain/jdk/deps/wayland-protocols-1.45.tar.xz` over `$sysroot/usr/share/wayland-protocols`.
- **Reproducible Timestamps (`SOURCE_DATE_EPOCH`):**
  `SOURCE_DATE_EPOCH` must be exported (`export SOURCE_DATE_EPOCH=$(source_date_epoch $sources_dir)`). Assigning it without `export` causes `configure` to fall back to `from 'current' (default)`, embedding wall-clock timestamps into zip/jmod archives ([b/562108269](http://b/562108269)).
- **Omission of Redundant Configure Flags:**
  - `--x-includes` and `--x-libraries` are omitted when `--with-sysroot` is provided (`lib-x11.m4` automatically derives `$sysroot/usr/include` and `$sysroot/usr/lib[/aarch64-linux-gnu]`).
  - `--with-tools-dir` is a backwards-compatibility alias for `--with-toolchain-path` (`basic.m4`); passing both duplicates entries in `TOOLCHAIN_PATH` ([b/561729389](http://b/561729389)). Only `--with-toolchain-path` is used.
- **glibc Version Floor & Upstream Devkit Evaluation:**
  - `linux-x86_64` achieves a `glibc 2.19` floor by overlaying Ubuntu 14.04 `libc6` `.deb` packages over Ubuntu 20.04 dependencies. Because Ubuntu 14.04 has no usable `arm64` port, `linux-aarch64` uses Ubuntu 20.04 packages directly (`glibc 2.31` floor; highest symbol version required by shipped binaries is `GLIBC_2.29`).
  - Upstream OpenJDK devkits (`make/devkit`) were evaluated as an alternative: `BASE_OS=Fedora` is broken for `aarch64` (404s on `fedora-secondary` URLs), while `BASE_OS=OL` (Oracle Linux 7.6 aarch64) is functional and provides `glibc 2.17`, but requires compiling GCC 14.2 and binutils twice and switching from Android's hermetic Clang toolchain to GCC.

---

## 6. Related Buganizer Issues

| Bug ID | Summary | Status |
| :--- | :--- | :--- |
| [b/561712160](http://b/561712160) | Host `autoconf` leak in older Linux OpenJDK/JBR build scripts (`install_autoconf` not called) | Open (Fixed in new `aarch64` script) |
| [b/561712262](http://b/561712262) | `build-jbr25-linux-x64.sh` statically links `libXi.a`/`libXtst.a` into `libawt_xawt.so` due to missing runtime `.deb`s | Fixed (both scripts link and bundle `libXi.so.6`/`libXtst.so.6`) |
| [b/561729389](http://b/561729389) | Duplicate `--with-tools-dir` and `--with-toolchain-path` flags in older build scripts | Open (Fixed in `aarch64` script) |
| [b/562108269](http://b/562108269) | Missing `export` on `SOURCE_DATE_EPOCH` in JBR build scripts | Fixed |
