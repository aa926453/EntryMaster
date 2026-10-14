#!/usr/bin/env bash
#
# EntryMaster macOS 构建（GitHub Actions 用）
# 使用真 Apple Xcode 工具链编译 arm64 + arm64e（新 ABI），ldid 逐切片签名
#
set -euo pipefail

echo "[*] Xcode: $(xcode-select -p)"
xcrun clang --version | head -1

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
PF="$SDK/System/Library/PrivateFrameworks"
OUT=build
mkdir -p "$OUT"

SRC="RMStore RMPickers RMMain"
VERSION="1.5.2"
if [ -n "${RM_PROBE:-}" ]; then VERSION="1.5.2-probe"; fi
if [ -n "${RM_LEVEL:-}" ]; then VERSION="${VERSION}-l${RM_LEVEL}"; fi

COMMON=(-isysroot "$SDK" -miphoneos-version-min=14.0 -fobjc-arc -O2 -fvisibility=hidden -Wall -Wno-deprecated-declarations ${RM_PROBE:+-DRM_PROBE=1} ${RM_LEVEL:+-DRM_LEVEL=$RM_LEVEL})
FRAMEWORKS=(-framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics
            -framework UniformTypeIdentifiers -framework PhotosUI -framework Photos
            -framework MobileCoreServices -framework CoreFoundation -framework CoreServices)

for ARCH in arm64 arm64e; do
  echo "[*] 编译 $ARCH (Apple clang，新 ABI)..."
  OBJS=()
  for f in $SRC; do
    xcrun clang -arch "$ARCH" "${COMMON[@]}" -c "src/$f.m" -o "$OUT/$ARCH.$f.o"
    OBJS+=("$OUT/$ARCH.$f.o")
  done

  echo "[*] 链接 $ARCH..."
  xcrun clang -arch "$ARCH" -dynamiclib -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -install_name "/var/jb/Library/MobileSubstrate/DynamicLibraries/EntryMaster.dylib" \
    -Wl,-undefined,dynamic_lookup "${FRAMEWORKS[@]}" "${OBJS[@]}" -o "$OUT/EntryMaster.$ARCH.dylib"

  echo "[*] ldid 签名 $ARCH 切片..."
  ldid -S "$OUT/EntryMaster.$ARCH.dylib"
done

echo "[*] 合成双架构 fat..."
xcrun lipo -create "$OUT/EntryMaster.arm64.dylib" "$OUT/EntryMaster.arm64e.dylib" -o "$OUT/EntryMaster.dylib"
xcrun lipo -info "$OUT/EntryMaster.dylib"

echo "[*] 签名自检..."
for ARCH in arm64 arm64e; do
  xcrun lipo -thin "$ARCH" -output "$OUT/_check.dylib" "$OUT/EntryMaster.dylib"
  N=$(otool -l "$OUT/_check.dylib" | grep -c LC_CODE_SIGNATURE || true)
  rm -f "$OUT/_check.dylib"
  if [ "${N:-0}" -lt 1 ]; then
    echo "[!] 致命: $ARCH 切片没有代码签名！"
    exit 1
  fi
  echo "[√] $ARCH 切片已签名"
done

echo "[*] 打包 deb..."
STAGE="$OUT/pkg"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
cp control "$STAGE/DEBIAN/control"
sed -i "" "s/^Version:.*/Version: $VERSION/" "$STAGE/DEBIAN/control"
cp "$OUT/EntryMaster.dylib" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp EntryMaster.plist "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
chmod -R 0755 "$STAGE/var"
chmod 0644 "$STAGE/DEBIAN/control" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/EntryMaster.plist"
chmod 0755 "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/EntryMaster.dylib"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "EntryMaster_${VERSION}_iphoneos-arm64.deb"

echo "[+] 构建完成: EntryMaster_${VERSION}_iphoneos-arm64.deb"
ls -la *.deb
