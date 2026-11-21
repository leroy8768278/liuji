#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

native_only=false
if [[ $# -eq 1 && $1 == --native ]]; then
    native_only=true
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--native]\n' "$0" >&2
    exit 2
fi

build_binary() {
    swift build --configuration release --product PacketScope "$@" >&2 || return
    local bin_dir
    bin_dir="$(swift build --configuration release --show-bin-path "$@")" || return
    printf '%s/PacketScope\n' "$bin_dir"
}

if "$native_only"; then
    native_binary="$(build_binary)"
else
    arm_binary="$(build_binary --triple arm64-apple-macosx14.0 --scratch-path .build/packaging/arm64)"
    intel_binary="$(build_binary --triple x86_64-apple-macosx14.0 --scratch-path .build/packaging/x86_64)"
fi

mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.app-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

app_name="流迹.app"
staged_app="$staging_dir/$app_name"
contents="$staged_app/Contents"
iconset="$staging_dir/PacketScope.iconset"
mkdir -p "$contents/MacOS" "$contents/Resources" "$iconset"

install -m 0644 "$project_dir/LICENSE" "$contents/Resources/LICENSE.txt"
sed 's/](LICENSE)/](LICENSE.txt)/g' "$project_dir/README.md" > "$contents/Resources/使用说明.md"
mkdir -p "$contents/Resources/docs"
for guide in "$project_dir"/docs/charles-5.2.3-*.md; do
    sed -E -e 's#\]\(\.\./LICENSE\)#](../LICENSE.txt)#g' \
        -e 's#\[([^]]+)\]\(\.\./(Sources|Tests)/[^)]+\)#\1#g' \
        "$guide" > "$contents/Resources/docs/${guide##*/}"
done

binary="$contents/MacOS/PacketScope"
if "$native_only"; then
    install -m 0755 "$native_binary" "$binary"
else
    xcrun lipo -create "$arm_binary" "$intel_binary" -output "$binary"
    xcrun lipo "$binary" -verify_arch arm64 x86_64
    chmod 0755 "$binary"
fi
swift "$project_dir/scripts/generate-app-icon.swift" "$iconset"
iconutil -c icns -o "$contents/Resources/PacketScope.icns" "$iconset"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>流迹</string>
    <key>CFBundleExecutable</key>
    <string>PacketScope</string>
    <key>CFBundleIconFile</key>
    <string>PacketScope.icns</string>
    <key>CFBundleIdentifier</key>
    <string>local.packetscope.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>流迹</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.5.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>流迹会话</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>local.packetscope.mac.session</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>local.packetscope.mac.session</string>
            <key>UTTypeDescription</key>
            <string>流迹会话</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>flowsession</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>local.packetscope.mac.har</string>
            <key>UTTypeDescription</key>
            <string>HTTP Archive</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>har</string></array>
                <key>public.mime-type</key>
                <array><string>application/har+json</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>local.packetscope.mac.rules</string>
            <key>UTTypeDescription</key>
            <string>流迹代理规则</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>flowrules</string></array>
            </dict>
        </dict>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>流迹需要连接局域网中的开发服务，以转发通过本机代理发送的请求。</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$contents/Info.plist"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$staged_app"
    codesign --verify --strict "$staged_app"
fi

app_path="$project_dir/dist/$app_name"
rm -rf "$app_path"
mv "$staged_app" "$app_path"
printf '%s\n' "$app_path"
