TERMUX_PKG_HOMEPAGE=https://openjdk.org
TERMUX_PKG_DESCRIPTION="Java 8 development kit and runtime (OpenJDK 8)"
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@SrErikCoderx"
TERMUX_PKG_VERSION=8.0.502
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://github.com/SrErikCoderx/android-openjdk_8-build/archive/refs/tags/v8u502-build4.tar.gz
TERMUX_PKG_SHA256=SKIP_CHECKSUM
TERMUX_PKG_DEPENDS="libandroid-shmem, libandroid-spawn, libiconv, libjpeg-turbo, zlib, littlecms, alsa-plugins, freetype, libpng, fontconfig"
TERMUX_PKG_BUILD_DEPENDS="cups, fontconfig, libxrandr, libxt, xorgproto, alsa-lib"
TERMUX_PKG_RECOMMENDS="ca-certificates-java, resolv-conf"
TERMUX_PKG_SUGGESTS="cups"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_HAS_DEBUG=false
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_UNDEF_SYMBOLS_FILES="all"

_ensure_patchelf() {
	[ -x "$TERMUX_PKG_CACHEDIR/patchelf-0.18.0/bin/patchelf" ] && return
	local url="https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz"
	local arc="$TERMUX_PKG_CACHEDIR/patchelf.tar.gz"
	curl -fsSL "$url" -o "$arc"
	mkdir -p "$TERMUX_PKG_CACHEDIR/patchelf-0.18.0/bin"
	tar -xzf "$arc" -C "$TERMUX_PKG_CACHEDIR/patchelf-0.18.0"
}

termux_step_host_build() {
	local url="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u492-b09/OpenJDK8U-jdk_x64_linux_hotspot_8u492b09.tar.gz"
	local arc="$TERMUX_PKG_CACHEDIR/jdk8-boot-x64.tar.gz"
	local sha="da257f161d7f8c6ca5b0e5d9e4090f65ac28c5e398072e68b8ae87988b1d1a2e"
	termux_download "$url" "$arc" "$sha"
	tar -xf "$arc" --strip-components=1 -C "$TERMUX_PKG_HOSTBUILD_DIR"
}

termux_step_setup_toolchain() {
	export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	export JAVA_HOME="$TERMUX_PKG_HOSTBUILD_DIR"
	mkdir -p "$TERMUX_PKG_SRCDIR/termux-elf-cleaner/build"
	cp "$TERMUX_ELF_CLEANER" "$TERMUX_PKG_SRCDIR/termux-elf-cleaner/build/termux-elf-cleaner"
	_ensure_patchelf
	export PATH="$TERMUX_PKG_CACHEDIR/patchelf-0.18.0/bin:$PATH"
}

termux_step_pre_configure() {
	local _arch
	case "$TERMUX_ARCH" in
		aarch64) _arch="aarch64" ;;
		arm)     _arch="aarch32" ;;
		x86_64)  _arch="x86_64" ;;
		i686)    _arch="x86" ;;
	esac
	export TARGET_JDK="$_arch"
	cd "$TERMUX_PKG_SRCDIR"
	bash "ci_build_arch_${_arch}.sh"
}

termux_step_configure() { :; }
termux_step_make() { :; }

termux_step_make_install() {
	local _jdkout_dir
	case "$TERMUX_ARCH" in
		aarch64) _jdkout_dir="arm64" ;;
		arm)     _jdkout_dir="arm" ;;
		x86_64)  _jdkout_dir="x86_64" ;;
		i686)    _jdkout_dir="x86" ;;
	esac

	local jdk_home="$TERMUX_PREFIX/lib/jvm/java-8-openjdk"
	rm -rf "$jdk_home"
	mkdir -p "$jdk_home"
	cp -r "$TERMUX_PKG_SRCDIR/jdkout/$_jdkout_dir/"* "$jdk_home/"

	local jdk_lib_arch
	jdk_lib_arch=$(basename "$(find "$jdk_home/lib" -maxdepth 1 -type d ! -name lib | head -1)")

	local rpath="${jdk_home}/lib/${jdk_lib_arch}:${jdk_home}/lib/${jdk_lib_arch}/jli"
	rpath+=":${jdk_home}/jre/lib/${jdk_lib_arch}:${jdk_home}/jre/lib/${jdk_lib_arch}/jli"
	rpath+=":${jdk_home}/jre/lib/${jdk_lib_arch}/server:${jdk_home}/jre/lib/${jdk_lib_arch}/client"
	rpath+=":${jdk_home}/lib:${jdk_home}/jre/lib"
	rpath+=":${TERMUX_PREFIX}/lib"

	find "$jdk_home/bin" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' bin; do
		patchelf --set-rpath "$rpath" "$bin" || echo "WARN: patchelf failed on $bin" >&2
	done

	find "$jdk_home" -name "*.so" -print0 | while IFS= read -r -d '' lib; do
		patchelf --set-rpath "$rpath" "$lib" || echo "WARN: patchelf failed on $lib" >&2
	done

	for dir in "$jdk_home/lib/$jdk_lib_arch" \
		"$jdk_home/jre/lib/$jdk_lib_arch"; do
		rm -f "$dir/librt.so"
		case "$TERMUX_ARCH" in
			aarch64|x86_64) ln -sf /system/lib64/libc.so "$dir/librt.so" ;;
			*)              ln -sf /system/lib/libc.so  "$dir/librt.so" ;;
		esac
	done

	mkdir -p "$jdk_home/etc/profile.d"
	echo "export JAVA_HOME=$jdk_home/" > "$jdk_home/etc/profile.d/java.sh"
}

termux_step_post_make_install() {
	cd "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/man/man1" 2>/dev/null || return 0
	for manpage in *.1; do
		gzip "$manpage"
	done

	local failure=false
	for binary in $(find "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/bin" -executable -type f -exec basename {} \;); do
		grep -q "lib/jvm/java-8-openjdk/bin/${binary}[[:space:]]" \
			"$TERMUX_PKG_BUILDER_DIR"/openjdk-8.alternatives || {
			echo "ERROR: Missing entry for binary: $binary in openjdk-8.alternatives"
			failure=true
		}
	done
	if [[ "$failure" = true ]]; then
		termux_error_exit "openjdk-8.alternatives is not up to date, please update it."
	fi
}
