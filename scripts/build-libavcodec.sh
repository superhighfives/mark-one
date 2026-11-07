#!/bin/sh
# Builds libavcodec with only the H.264 decoder, plus libavutil, as shared
# libraries for Mark One (arm64 and x86_64, macOS 14 and later). Mark One
# uses it because VideoToolbox rejects some of the E-M5's frames.
#
# The build leaves out every GPL and nonfree part, so the libraries are
# LGPL 2.1. Mark One ships them as separate dynamic libraries, unmodified,
# and says where to get the source.
#
# Output: mac/MarkOne/Vendor/ffmpeg/{include,lib}

set -eu

VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/ffmpeg
OUT=$ROOT/mac/MarkOne/Vendor/ffmpeg

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f ffmpeg-$VERSION.tar.xz ]; then
    curl -fsSLO https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz
fi
echo "$SHA256  ffmpeg-$VERSION.tar.xz" | shasum -a 256 -c -
rm -rf src && mkdir src && tar -xf ffmpeg-$VERSION.tar.xz -C src --strip-components 1

for ARCH in arm64 x86_64; do
    rm -rf "build-$ARCH" && mkdir "build-$ARCH"
    (
        cd "build-$ARCH"
        EXTRA=""
        [ "$ARCH" = x86_64 ] && EXTRA="--disable-x86asm --enable-cross-compile"
        ../src/configure \
            --prefix="$WORK/install-$ARCH" \
            --arch=$ARCH --target-os=darwin --cc="clang -arch $ARCH" \
            --extra-cflags="-mmacosx-version-min=14.0" \
            --extra-ldflags="-mmacosx-version-min=14.0" \
            --install-name-dir=@rpath \
            --enable-shared --disable-static \
            --disable-everything --enable-decoder=h264 \
            --disable-programs --disable-doc --disable-network \
            --disable-avdevice --disable-avformat --disable-avfilter \
            --disable-swscale --disable-swresample \
            --disable-autodetect --disable-debug \
            $EXTRA
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
        make install >/dev/null
    )
done

rm -rf "$OUT" && mkdir -p "$OUT/lib"
cp -R "$WORK/install-arm64/include" "$OUT/include"
for LIB in libavcodec libavutil; do
    # Name each file after its install name (libavcodec.63.dylib, ...), which
    # is how the other library and the app refer to it.
    NAME=$(basename "$(otool -D "$WORK/install-arm64/lib/$LIB.dylib" | tail -1)")
    lipo -create "$WORK/install-arm64/lib/$LIB.dylib" "$WORK/install-x86_64/lib/$LIB.dylib" -output "$OUT/lib/$NAME"
    ln -s "$NAME" "$OUT/lib/$LIB.dylib"
done
cp "$WORK/src/COPYING.LGPLv2.1" "$OUT/"
echo "Built FFmpeg $VERSION into $OUT"
