#!/bin/bash
# TokenLens 编译打包脚本
set -e
cd "$(dirname "$0")"

APP_NAME="TokenLens"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "▶ 编译 Swift 源码..."
mkdir -p "$MACOS"
swiftc -O \
    Sources/Models.swift \
    Sources/JSON.swift \
    Sources/Parser.swift \
    Sources/DateRange.swift \
    Sources/Glass.swift \
    Sources/DashboardView.swift \
    Sources/PopoverView.swift \
    Sources/FilterBar.swift \
    Sources/TokenGauge.swift \
    Sources/ToolScanner.swift \
    Sources/DirPicker.swift \
    Sources/AppSettings.swift \
    Sources/SettingsView.swift \
    Sources/BrandLogo.swift \
    Sources/TokenLensApp.swift \
    -o "$MACOS/$APP_NAME" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Combine

echo "▶ 生成 App 图标..."
# 把品牌 logo 绘制到白色圆角方块上生成 iconset → icns
mkdir -p "$CONTENTS/Resources" "$BUILD_DIR/icon_tool"
# 打包品牌 logo（透明背景 PNG）进 App 资源，供窗口内徽标与 Dock 图标共用
if [ -f "Assets/AppLogo.png" ]; then
    cp "Assets/AppLogo.png" "$CONTENTS/Resources/AppLogo.png" \
        && echo "  AppLogo.png 已就位" \
        || echo "  ⚠️ AppLogo.png 拷贝失败"
else
    echo "  ⚠️ Assets/AppLogo.png 不存在，请先运行 python3 Tools/make_logo.py"
fi
if swiftc -O -parse-as-library Sources/TokenGauge.swift Tools/main.swift -o "$BUILD_DIR/icon_tool/gen" 2>"$BUILD_DIR/icon_tool/build.log"; then
    "$BUILD_DIR/icon_tool/gen" "$BUILD_DIR" "$PWD/Assets/AppLogo.png"
    if command -v iconutil >/dev/null 2>&1 && [ -d "$BUILD_DIR/AppIcon.iconset" ]; then
        iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns" \
            && echo "  AppIcon.icns 已就位" \
            || echo "  ⚠️ iconutil 生成失败，应用将无自定义图标"
    else
        echo "  ⚠️ iconutil 不可用，跳过 icns 打包"
    fi
else
    echo "  ⚠️ 图标生成器编译失败，跳过（详见 $BUILD_DIR/icon_tool/build.log）"
fi

echo "▶ 生成 Info.plist..."
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.xiaohan.tokenlens</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>TokenLens</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>1.1.0</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>TokenLens — 本机 AI Token 用量监控</string>
</dict>
</plist>
PLIST

echo "▶ 完成: $PWD/$APP_DIR"
