#!/bin/sh
# Build both debs into packages/:
#   iphoneos-arm64   rootless, ldid-signed (stock Theos). Dopamine/roothide installs it through the
#                    RootHide Patcher, which converts and re-signs it.
#   iphoneos-arm64e  native roothide, signed with codesign (roothide Theos). Installs with Sileo or
#                    plain dpkg -i, no Patcher.
# Both use the iOS 15.5 SDK (CAFrameRateRange); deployment target 15.0, because 16.0 on an older SDK
# fails to link objc_claimAutoreleasedReturnValue.
# Then checks each deb's paths, slices, filter plist mode and, for arm64e, the signatures.
set -eu
cd "$(dirname "$0")"
TARGET=iphone:clang:15.5:15.0

rm -rf .theos packages
env -i HOME="$HOME" PATH="$PATH" make package THEOS="$HOME/theos" TARGET=$TARGET FINALPACKAGE=1

rm -rf .theos
env -i HOME="$HOME" PATH="$PATH" make package THEOS="$HOME/theos-roothide" TARGET=$TARGET \
    FINALPACKAGE=1 DEBUG=0 THEOS_PACKAGE_SCHEME=roothide TARGET_CODESIGN=codesign \
    MetalFG_CODESIGN_FLAGS="-f -s -"

fail() { echo "build.sh: $*" >&2; exit 1; }
version=$(sed -n 's/^Version: //p' control)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for arch in iphoneos-arm64 iphoneos-arm64e; do
    deb="packages/com.dnullptr.metalfg_${version}_${arch}.deb"
    [ -f "$deb" ] || fail "missing $deb"
    dir="$work/$arch"
    dpkg-deb -x "$deb" "$dir"
    case $arch in iphoneos-arm64) jb="$dir/var/jb" ;; *) jb="$dir" ;; esac
    [ $arch = iphoneos-arm64e ] && [ -e "$dir/var/jb" ] && fail "$deb: roothide deb contains var/jb"
    lib="$jb/Library/MobileSubstrate/DynamicLibraries"
    bin="$lib/MetalFG.dylib"
    [ -f "$bin" ] || fail "$deb: no ${bin#"$dir"/}"
    lipo "$bin" -verify_arch arm64 arm64e || fail "$deb: MetalFG.dylib needs arm64 and arm64e slices"
    if [ $arch = iphoneos-arm64e ]; then
        for a in arm64 arm64e; do
            codesign --verify --arch "$a" "$bin" || fail "$deb: MetalFG.dylib $a slice not signed"
        done
    fi
    # ElleKit silently skips a filter plist that is not world-readable.
    [ "$(stat -f %Lp "$lib/MetalFG.plist")" = 644 ] || fail "$deb: MetalFG.plist is not 644"
    echo "ok  $deb"
done
