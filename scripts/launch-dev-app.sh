#!/bin/zsh

set -euo pipefail


skip_setup=false
for arg in "$@"; do
  case "$arg" in
    --skip-setup) skip_setup=true ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
brand_script="$repo_root/scripts/generate_brand_icons.py"
brand_icon="$repo_root/Assets/Brand/AgentIsland.icns"
bundle_dir="$HOME/Applications/Agent Island.app"
plist_path="$bundle_dir/Contents/Info.plist"
bundle_binary="$bundle_dir/Contents/MacOS/AgentIslandApp"

cd "$repo_root"

swift build -c debug --product AgentIslandApp
swift build -c debug --product AgentIslandHooks
swift build -c debug --product AgentIslandSetup

build_root="$(swift build -c debug --show-bin-path)"
app_binary="$build_root/AgentIslandApp"
hooks_binary="$build_root/AgentIslandHooks"
setup_binary="$build_root/AgentIslandSetup"

python3 "$brand_script"
if [ "$skip_setup" = false ]; then
  "$setup_binary" install --hooks-binary "$hooks_binary"
fi

mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Helpers" "$bundle_dir/Contents/Resources" "$bundle_dir/Contents/Frameworks"

# Kill any running instance before copying so the binary isn't locked.
osascript -e 'tell application "Agent Island" to quit' 2>/dev/null || true
pkill -9 -f "Agent Island" 2>/dev/null || true
sleep 2

command cp "$app_binary" "$bundle_binary"
command cp "$hooks_binary" "$bundle_dir/Contents/Helpers/AgentIslandHooks"
command cp "$setup_binary" "$bundle_dir/Contents/Helpers/AgentIslandSetup"
command cp "$brand_icon" "$bundle_dir/Contents/Resources/AgentIsland.icns"
chmod +x "$bundle_binary" "$bundle_dir/Contents/Helpers/AgentIslandHooks" "$bundle_dir/Contents/Helpers/AgentIslandSetup"

# Add rpath so the binary can find Sparkle.framework in Contents/Frameworks/.
install_name_tool -add_rpath @loader_path/../Frameworks "$bundle_binary" 2>/dev/null || true

# Copy every SPM resource bundle used at runtime into the signed resource
# directory. AgentIsland and the pinned SwiftMath fork both search here before
# falling back to their local SwiftPM build paths.
resource_bundle_names=(
    "AgentIsland_AgentIslandApp.bundle"
    "SwiftMath_SwiftMath.bundle"
)
for resource_bundle_name in "${resource_bundle_names[@]}"; do
    resource_bundle="$build_root/$resource_bundle_name"
    if [ ! -d "$resource_bundle" ]; then
        echo "Missing required SPM resource bundle: $resource_bundle" >&2
        exit 1
    fi

    rm -rf \
        "$bundle_dir/$resource_bundle_name" \
        "$bundle_dir/Contents/Resources/$resource_bundle_name"
    command cp -R "$resource_bundle" "$bundle_dir/Contents/Resources/"
done

# Copy Sparkle.framework for auto-update support.
sparkle_framework="$repo_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$sparkle_framework" ]; then
    rm -rf "$bundle_dir/Contents/Frameworks/Sparkle.framework"
    command cp -R "$sparkle_framework" "$bundle_dir/Contents/Frameworks/"
fi

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AgentIslandApp</string>
    <key>CFBundleIdentifier</key>
    <string>app.agentisland.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AgentIsland</string>
    <key>CFBundleName</key>
    <string>Agent Island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agent-Island needs automation access to focus Terminal and iTerm sessions for jump-back.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/Octane0411/agent-island/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>3IF8txq9RRNanzE2FNhyGRcwhslTucCcJHpTkpxcgBQ=</string>
</dict>
</plist>
EOF

# Detect a local stable signing identity so the dev bundle's cdhash
# stays stable across rebuilds and macOS TCC grants (Accessibility,
# Automation) persist. Without it we fall back to ad-hoc signing, which
# changes the cdhash every build and silently invalidates any TCC
# grants the developer had approved — extremely disruptive when
# iterating on features that need AX permission. See
# scripts/setup-dev-signing.sh for a one-time setup that creates this
# identity locally with zero Apple Developer Program involvement.
sign_identity="-"
if security find-identity -p codesigning -v "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
       | grep -q '"Agent Island Local"'; then
    sign_identity="Agent Island Local"
else
    echo
    echo "⚠ Using ad-hoc signing. macOS TCC grants (Accessibility, Automation)"
    echo "  will be invalidated on every rebuild. Run once to fix:"
    echo "    zsh scripts/setup-dev-signing.sh"
    echo
fi

codesign --force --deep --sign "$sign_identity" "$bundle_dir" 2>/dev/null || true

open -na "$bundle_dir"
