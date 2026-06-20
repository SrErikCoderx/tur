TERMUX_PKG_HOMEPAGE=https://openjdk.org
TERMUX_PKG_DESCRIPTION="Java 8 development kit and runtime (OpenJDK 8)"
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@SrErikCoderx"
TERMUX_PKG_VERSION="8.0.502"
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://github.com/openjdk/jdk8u/archive/refs/heads/master.tar.gz
TERMUX_PKG_SHA256=SKIP_CHECKSUM
TERMUX_PKG_DEPENDS="libandroid-shmem, libandroid-spawn, libiconv, libjpeg-turbo, zlib, littlecms, alsa-plugins, freetype, libpng, fontconfig"
TERMUX_PKG_BUILD_DEPENDS="cups, fontconfig, libxrandr, libxt, xorgproto, alsa-lib"
TERMUX_PKG_RECOMMENDS="ca-certificates-java, resolv-conf"
TERMUX_PKG_SUGGESTS="cups"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_HAS_DEBUG=false
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_HOSTBUILD=true

_NDK_R10E_URL="https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip"
_NDK_R10E_SHA256="ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c"

_download_ndk_r10e() {
	if [ ! -f "$TERMUX_COMMON_CACHEDIR/older-ndk/.placeholder-android-ndk-r10e" ]; then
		echo "Downloading Android NDK r10e (needed for OpenJDK 8 hotspot build)..."
		mkdir -p "$TERMUX_COMMON_CACHEDIR/older-ndk/"
		local _archive="$TERMUX_COMMON_CACHEDIR/older-ndk/android-ndk-r10e-linux-x86_64.zip"
		termux_download "$_NDK_R10E_URL" "$_archive" "$_NDK_R10E_SHA256"
		unzip -q -d "$TERMUX_COMMON_CACHEDIR/older-ndk/" "$_archive"
		touch "$TERMUX_COMMON_CACHEDIR/older-ndk/.placeholder-android-ndk-r10e"
	fi
}

_setup_standalone_toolchain_ndk_r10e() {
	_download_ndk_r10e

	local _ndk_arch
	case "$TERMUX_ARCH" in
		aarch64) _ndk_arch="arm64" ;;
		arm)     _ndk_arch="arm" ;;
		x86_64)  _ndk_arch="x86_64" ;;
		i686)    _ndk_arch="x86" ;;
	esac

	export NDK_R10E_TOOLCHAIN="$TERMUX_PKG_CACHEDIR/ndk-r10e-toolchain-$TERMUX_ARCH"
	if [ ! -d "$NDK_R10E_TOOLCHAIN" ]; then
		"$TERMUX_COMMON_CACHEDIR/older-ndk/android-ndk-r10e/build/tools/make-standalone-toolchain.sh" \
			--arch="$_ndk_arch" \
			--platform=android-21 \
			--install-dir="$NDK_R10E_TOOLCHAIN"
		# Create devkit.info for OpenJDK's --with-devkit
		cat > "$NDK_R10E_TOOLCHAIN/devkit.info" <<-EOF
		DEVKIT_NAME="Android ${_ndk_arch}"
		DEVKIT_TOOLCHAIN_PATH="\$DEVKIT_ROOT/bin"
		DEVKIT_SYSROOT="\$DEVKIT_ROOT/sysroot"
		EOF
	fi
}

termux_step_host_build() {
	JDK_BINURL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u492-b09/OpenJDK8U-jdk_x64_linux_hotspot_8u492b09.tar.gz"
	JDK_BINARCHIVE="${TERMUX_PKG_CACHEDIR}/openjdk-8u492-b09-linux-x64.tar.gz"
	JDK_BINSHA256="da257f161d7f8c6ca5b0e5d9e4090f65ac28c5e398072e68b8ae87988b1d1a2e"
	termux_download "$JDK_BINURL" "$JDK_BINARCHIVE" "$JDK_BINSHA256"
	tar -xf "$JDK_BINARCHIVE" --strip-components=1 -C "$TERMUX_PKG_HOSTBUILD_DIR"
}

termux_step_pre_configure() {
	unset JAVA_HOME

	_setup_standalone_toolchain_ndk_r10e

	local target_phys
	case "$TERMUX_ARCH" in
		aarch64) target_phys="aarch64-linux-android" ;;
		arm)     target_phys="arm-linux-androideabi" ;;
		x86_64)  target_phys="x86_64-linux-android" ;;
		i686)    target_phys="i686-linux-android" ;;
	esac
	export _JDK8_TARGET_PHYS="$target_phys"

	local _android_include="$NDK_R10E_TOOLCHAIN/sysroot/usr/include"
	ln -s -f /usr/include/X11 "$_android_include/"
	ln -s -f /usr/include/fontconfig "$_android_include/"
	ln -s -f "$TERMUX_PREFIX/include/freetype2" "$_android_include/"

	mkdir -p "$TERMUX_PKG_CACHEDIR/dummy_libs"
	ar cru "$TERMUX_PKG_CACHEDIR/dummy_libs/libpthread.a"
	ar cru "$TERMUX_PKG_CACHEDIR/dummy_libs/libthread_db.a"

	# For ARM (32-bit), use aarch32-port-jdk8u which has the arm-specific files
	if [ "$TERMUX_ARCH" = "arm" ]; then
		echo "Cloning aarch32-port-jdk8u for ARM build..."
		local _aarch32_clone="$TERMUX_PKG_CACHEDIR/aarch32-port-jdk8u-master"
		if [ ! -d "$_aarch32_clone" ]; then
			git clone --depth 1 https://github.com/openjdk/aarch32-port-jdk8u "$_aarch32_clone"
		fi
		rsync -a --delete "$_aarch32_clone/" "$TERMUX_PKG_SRCDIR/"
	fi

	local _patch_dir="$TERMUX_PKG_BUILDER_DIR/patches"

	# Universal patches (applied to all arches)
	for patch in jdk8u_android.diff ipv6_support.diff jdk8u_android_distags.diff; do
		if [ -f "$_patch_dir/$patch" ]; then
			echo "Applying patch: $patch"
			git apply --reject --whitespace=fix "$_patch_dir/$patch" || \
				echo "Warning: git apply had rejects for: $patch"
		fi
	done

	# Architecture-specific patches
	if [ "$TERMUX_ARCH" = "arm" ]; then
		echo "Applying aarch32-specific patch"
		git apply --reject --whitespace=fix "$_patch_dir/jdk8u_android_aarch32.diff" || \
			echo "Warning: git apply had rejects for: jdk8u_android_aarch32.diff"
	else
		echo "Applying main (non-aarch32) patch"
		git apply --reject --whitespace=fix "$_patch_dir/jdk8u_android_main.diff" || \
			echo "Warning: git apply had rejects for: jdk8u_android_main.diff"
	fi

	# x86 page trap fix
	if [ "$TERMUX_ARCH" = "i686" ]; then
		git apply --reject --whitespace=fix "$_patch_dir/jdk8u_android_page_trap_fix.diff" || \
			echo "Warning: git apply had rejects for: jdk8u_android_page_trap_fix.diff"
	fi

	if [ "$TERMUX_ARCH" = "aarch64" ]; then
		sed -i 's/if test $COMPILER_VERSION_NUMBER_MAJOR -lt 5; then/if false; then/' \
			common/autoconf/toolchain.m4 common/autoconf/generated-configure.sh
		sed -i 's/CLS"\[B\["OBJ/CLS "[B[" OBJ/' \
			hotspot/src/share/vm/prims/unsafe.cpp
		sed -i 's/"INT64_FORMAT/" INT64_FORMAT/g' \
			hotspot/src/share/vm/gc_implementation/parallelScavenge/psMarkSweep.cpp \
			hotspot/src/share/vm/gc_implementation/parallelScavenge/psParallelCompact.cpp \
			hotspot/src/share/vm/memory/referenceProcessor.cpp \
			hotspot/src/share/vm/memory/genCollectedHeap.cpp
		sed -i 's/"SIZE_FORMAT/" SIZE_FORMAT/g' \
			hotspot/src/share/vm/gc_implementation/shared/parGCAllocBuffer.cpp
		sed -i 's/"PTR_FORMAT/" PTR_FORMAT/g' \
			hotspot/src/cpu/aarch64/vm/vtableStubs_aarch64.cpp
		sed -i 's/"PRIX64/" PRIX64/g; s/"PRIX32/" PRIX32/g' \
			hotspot/src/cpu/aarch64/vm/macroAssembler_aarch64.cpp
	fi
}

termux_step_configure() {
	if [ ! -d "$TERMUX_PKG_CACHEDIR/cups-2.2.4" ]; then
		termux_download \
			"https://github.com/apple/cups/releases/download/v2.2.4/cups-2.2.4-source.tar.gz" \
			"$TERMUX_PKG_CACHEDIR/cups-2.2.4-source.tar.gz"
		tar xf "$TERMUX_PKG_CACHEDIR/cups-2.2.4-source.tar.gz" -C "$TERMUX_PKG_CACHEDIR"
	fi

	local jvm_variants
	case "$TERMUX_ARCH" in
		aarch64|x86_64) jvm_variants="server" ;;
		arm|i686)       jvm_variants="client" ;;
	esac

	local jdk_extra_cflags="-DLE_STANDALONE -D__ANDROID__=1 -D__TERMUX__=1 -O3"
	local jdk_ldflags="-L${TERMUX_PREFIX}/lib \
		-Wl,-rpath=$TERMUX_PREFIX/lib/jvm/java-8-openjdk/lib \
		-Wl,-rpath=${TERMUX_PREFIX}/lib -Wl,--enable-new-dtags \
		-L$TERMUX_PKG_CACHEDIR/dummy_libs"

	# Debug: test GCC cross-compiler
	echo "=== Testing NDK r10e GCC ==="
	ls -la "$NDK_R10E_TOOLCHAIN/bin/${_JDK8_TARGET_PHYS}-gcc" 2>&1 || true
	echo 'int main(){return 0;}' > /tmp/test_gcc_$$.c
	"$NDK_R10E_TOOLCHAIN/bin/${_JDK8_TARGET_PHYS}-gcc" -v -o /tmp/test_gcc_$$ /tmp/test_gcc_$$.c 2>&1 || true
	rm -f /tmp/test_gcc_$$ /tmp/test_gcc_$$.c
	echo "=== End GCC test ==="

	bash ./configure \
		--openjdk-target="$_JDK8_TARGET_PHYS" \
		--with-boot-jdk="$TERMUX_PKG_HOSTBUILD_DIR" \
		--with-devkit="$NDK_R10E_TOOLCHAIN" \
		--with-extra-cflags="$jdk_extra_cflags" \
		--with-extra-cxxflags="$jdk_extra_cflags" \
		--with-extra-ldflags="$jdk_ldflags" \
		--enable-option-checking=fatal \
		--with-jdk-variant=normal \
		--with-jvm-variants="$jvm_variants" \
		--with-debug-level=release \
		--with-cups-include="$TERMUX_PKG_CACHEDIR/cups-2.2.4" \
		--with-fontconfig-include="$TERMUX_PREFIX/include" \
		--with-freetype-include="$TERMUX_PREFIX/include/freetype2" \
		--with-freetype-lib="$TERMUX_PREFIX/lib" \
		--with-vendor-name="Termux" \
		--x-includes="$TERMUX_PREFIX/include" \
		--x-libraries="$TERMUX_PREFIX/lib" \
	|| {
		echo "CONFIGURE ERROR, dumping config.log:"
		cat config.log
		termux_error_exit "configure failed for openjdk-8"
	}
}

termux_step_make() {
	local jvm_platform_dir
	jvm_platform_dir=$(find "$TERMUX_PKG_SRCDIR/build" -maxdepth 1 -type d -name 'linux-*-normal-*-release' | head -1)
	if [ -z "$jvm_platform_dir" ]; then
		termux_error_exit "Could not find build directory matching linux-*-normal-*-release"
	fi
	cd "$jvm_platform_dir"
	make JOBS="$TERMUX_PKG_MAKE_PROCESSES" images
	cd "$TERMUX_PKG_SRCDIR"
}

termux_step_make_install() {
	local jvm_platform_dir
	jvm_platform_dir=$(find "$TERMUX_PKG_SRCDIR/build" -maxdepth 1 -type d -name 'linux-*-normal-*-release' | head -1)
	if [ -z "$jvm_platform_dir" ]; then
		termux_error_exit "Could not find build directory matching linux-*-normal-*-release"
	fi

	rm -rf "$TERMUX_PREFIX/lib/jvm/java-8-openjdk"
	mkdir -p "$TERMUX_PREFIX/lib/jvm/java-8-openjdk"
	cp -r "$jvm_platform_dir/images/j2sdk-image/"* \
		"$TERMUX_PREFIX/lib/jvm/java-8-openjdk/"

	local jdk_lib_arch
	jdk_lib_arch=$(basename "$(find "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/lib" -maxdepth 1 -type d ! -name lib | head -1)")
	if [ -f "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/jre/lib/$jdk_lib_arch/libfreetype.so.6" ]; then
		mv "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/jre/lib/$jdk_lib_arch/libfreetype.so.6" \
			"$TERMUX_PREFIX/lib/jvm/java-8-openjdk/lib/$jdk_lib_arch/libfreetype.so" || true
	fi
	if [ -f "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/jre/lib/$jdk_lib_arch/libfreetype.so" ]; then
		mv "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/jre/lib/$jdk_lib_arch/libfreetype.so" \
			"$TERMUX_PREFIX/lib/jvm/java-8-openjdk/lib/$jdk_lib_arch/libfreetype.so" || true
	fi

	for dir in "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/lib/$jdk_lib_arch" \
		"$TERMUX_PREFIX/lib/jvm/java-8-openjdk/jre/lib/$jdk_lib_arch"; do
		rm -f "$dir/librt.so"
		case "$TERMUX_ARCH" in
			aarch64|x86_64) ln -sf /system/lib64/libc.so "$dir/librt.so" ;;
			*)              ln -sf /system/lib/libc.so  "$dir/librt.so" ;;
		esac
	done

	mkdir -p "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/etc/profile.d"
	echo "export JAVA_HOME=$TERMUX_PREFIX/lib/jvm/java-8-openjdk/" > \
		"$TERMUX_PREFIX/lib/jvm/java-8-openjdk/etc/profile.d/java.sh"
}

termux_step_post_make_install() {
	cd "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/man/man1" 2>/dev/null || return 0
	for manpage in *.1; do
		gzip "$manpage"
	done

	binaries="$(find "$TERMUX_PREFIX/lib/jvm/java-8-openjdk/bin" -executable -type f \
		| xargs -I{} basename "{}" | xargs echo)"

	local failure=false
	for binary in $binaries; do
		grep -q "lib/jvm/java-8-openjdk/bin/${binary}$" \
			"$TERMUX_PKG_BUILDER_DIR"/openjdk-8.alternatives || {
			echo "ERROR: Missing entry for binary: $binary in openjdk-8.alternatives"
			failure=true
		}
	done
	if [[ "$failure" = true ]]; then
		termux_error_exit "openjdk-8.alternatives is not up to date, please update it."
	fi
}
