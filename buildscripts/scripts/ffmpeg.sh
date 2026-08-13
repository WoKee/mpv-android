#!/bin/bash -e

. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf _build$ndk_suffix
	exit 0
else
	exit 255
fi

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

# ── Build bundled AV3A audio decoder (dependency/avs3a) ──────────────
# The WoKee FFmpeg fork ships the full arcdav3a source tree inside the
# repository.  Build it as a static library and install into the prefix
# so that FFmpeg's configure can find it via pkg-config.
if [ -d ../dependency/avs3a ]; then
	case "$ndk_triple" in
		arm-linux-androideabi)   cmake_abi=armeabi-v7a ;;
		aarch64-linux-android)   cmake_abi=arm64-v8a  ;;
		i686-linux-android)      cmake_abi=x86        ;;
		x86_64-linux-android)    cmake_abi=x86_64     ;;
	esac

	ndk_dir=$(ls -d "$DIR/sdk/android-ndk-"* 2>/dev/null | head -1)
	if [ -n "$ndk_dir" ] && [ -f "$ndk_dir/build/cmake/android.toolchain.cmake" ]; then
		msg="Building bundled arcdav3a (AV3A audio)"
		printf '\e[1;34m==> %s\e[m\n' "$msg" >&2
		mkdir -p arcdav3a_build
		cmake -S ../dependency/avs3a -B arcdav3a_build \
			-DCMAKE_TOOLCHAIN_FILE="$ndk_dir/build/cmake/android.toolchain.cmake" \
			-DANDROID_ABI="$cmake_abi" \
			-DANDROID_PLATFORM=android-21 \
			-DCMAKE_INSTALL_PREFIX="$prefix_dir" \
			-DCMAKE_BUILD_TYPE=Release
		cmake --build arcdav3a_build -j$cores
		cmake --install arcdav3a_build
	else
		echo "WARNING: NDK CMake toolchain not found, skipping arcdav3a" >&2
	fi
fi

cpu=armv7-a
[[ "$ndk_triple" == "aarch64"* ]] && cpu=armv8-a
[[ "$ndk_triple" == "x86_64"* ]] && cpu=generic
[[ "$ndk_triple" == "i686"* ]] && cpu="i686 --disable-asm"

cpuflags=
[[ "$ndk_triple" == "arm"* ]] && cpuflags="$cpuflags -mfpu=neon -mcpu=cortex-a8"

args=(
	--target-os=android --enable-cross-compile
	--cross-prefix=$ndk_triple- --cc=$CC --pkg-config=pkg-config --nm=llvm-nm
	--arch=${ndk_triple%%-*} --cpu=$cpu
	--extra-cflags="-I$prefix_dir/include $cpuflags" --extra-ldflags="-L$prefix_dir/lib"

	--enable-{jni,mediacodec,mbedtls,libdav1d,libxml2,libarcdav3a} --disable-vulkan
	--disable-static --enable-shared --enable-{gpl,version3}

	# disable unneeded parts
	--disable-{stripping,doc,programs}
	# to keep the build lean we disable some feature quite aggressively:
	# - muxers, encoders: mpv-android does not have any way to use these
	# - devices: no practical use on Android
	--disable-{muxers,encoders,devices}
	# useful to taking screenshots
	--enable-encoder=mjpeg,png
	# useful for the `dump-cache` command
	--enable-muxer=mov,matroska,mpegts
)
../configure "${args[@]}"

make -j$cores
make DESTDIR="$prefix_dir" install
