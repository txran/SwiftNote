#!/bin/zsh
# 构建并打包 SwiftNote.app（本机无 Xcode，用 SwiftPM 产物手工组 bundle）
#
# 用法:
#   ./tools/build-app.sh            # 发行版 → dist/SwiftNote.app（id: cn.swiftnote.app）
#   ./tools/build-app.sh dev        # 开发版 → ~/Library/Caches/SwiftNote-dev/SwiftNote Dev.app
#                                   #   （独立 bundle id，且 Caches 不进 Spotlight 索引）
#   ./tools/build-app.sh clean      # 注销注册 + 删除两份产物 + 重启 Dock
#
# 为什么 dev 版不能放 dist：macOS 认应用靠磁盘上存不存在这个 bundle（P-30），
# 同 id 的第二份会立刻变成「两个图标 / 两个 ⌘Tab 条目」。放 Caches 且换 id 只是压住，
# 真正的收尾仍然是 clean（R-03）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-release}"

APP_NAME="SwiftNote"
REL_ID="cn.swiftnote.app"
DEV_ID="cn.swiftnote.app.dev"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="$(uname -m)"

DIST_DIR="${ROOT}/dist"
REL_APP="${DIST_DIR}/${APP_NAME}.app"
DEV_DIR="${HOME}/Library/Caches/SwiftNote-dev"
DEV_APP="${DEV_DIR}/${APP_NAME} Dev.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-${ARCH}.zip"

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CLT_PLUGIN_PATH="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

# 注销 + 删除；「磁盘上不留第二份 bundle」是唯一稳定的去重手段（R-03 / P-31）
unregister_and_remove() {
  local target="${1}"
  if [[ -d "${target}" ]]; then
    "${LSREG}" -u "${target}" >/dev/null 2>&1 || true
    rm -rf "${target}"
    echo "  已移除 ${target}"
  fi
}

clean_all() {
  echo "▶ 清理产物与注册"
  unregister_and_remove "${REL_APP}"
  unregister_and_remove "${DEV_APP}"
  rm -f "${ZIP_PATH}"
  killall Dock 2>/dev/null || true
  echo "✅ 清理完成（等待 45 秒后 mdfind 应查不到残留）"
}

if [[ "${MODE}" == "clean" ]]; then
  clean_all
  exit 0
fi

if [[ "${MODE}" != "dev" && "${MODE}" != "release" ]]; then
  echo "未知模式: ${MODE}（可用: dev / release / clean）" >&2
  exit 2
fi

if [[ "${MODE}" == "dev" ]]; then
  CONFIG="debug"
  APP="${DEV_APP}"
  BUNDLE_ID="${DEV_ID}"
  DISPLAY_NAME="${APP_NAME} Dev"
else
  CONFIG="release"
  APP="${REL_APP}"
  BUNDLE_ID="${REL_ID}"
  DISPLAY_NAME="${APP_NAME}"
fi

echo "▶ 构建（${CONFIG}，${BUNDLE_ID}）"
# --disable-sandbox: SPM 沙箱在 CLT-only 环境里会拒绝写 .build
# -plugin-path:      CLT 的宏插件目录（本工程目前不用 @State 等宏，但保留以免后续引入即失败）
swift build -c "${CONFIG}" --disable-sandbox --package-path "${ROOT}" \
  -Xswiftc -plugin-path -Xswiftc "${CLT_PLUGIN_PATH}"

BIN="${ROOT}/.build/${CONFIG}/${APP_NAME}"
if [[ ! -x "${BIN}" ]]; then
  echo "✗ 未找到构建产物: ${BIN}" >&2
  exit 1
fi

# 图标：CLT 没有 actool，必须走传统 .icns（P-03）
ICON="${ROOT}/build/icon/AppIcon.icns"
if [[ ! -f "${ICON}" ]]; then
  echo "▶ 生成图标"
  swift "${ROOT}/tools/make-icon.swift" "${ROOT}/build/icon" >/dev/null
  iconutil -c icns "${ROOT}/build/icon/AppIcon.iconset" -o "${ICON}"
fi

echo "▶ 组装 bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SwiftNote 文本文件</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>json</string>
                <string>xml</string>
                <string>properties</string>
                <string>props</string>
                <string>conf</string>
                <string>ini</string>
                <string>cfg</string>
                <string>txt</string>
                <string>log</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ad-hoc 签名（无开发者账号时的唯一选择，见 README 的 Gatekeeper 说明）
codesign --force --sign - "${APP}" >/dev/null 2>&1 || true

# 发行版额外打 zip：必须用真实路径，不能用符号链接（P-05/R-06）
if [[ "${MODE}" == "release" ]]; then
  mkdir -p "${DIST_DIR}"
  rm -f "${ZIP_PATH}"
  ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP_PATH}"
  # 解包验证：空壳/符号链接会在这里暴露
  SMOKE_DIR="$(mktemp -d)"
  ditto -x -k "${ZIP_PATH}" "${SMOKE_DIR}"
  if [[ ! -x "${SMOKE_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" ]]; then
    echo "✗ 解包验证失败：zip 内可执行文件缺失" >&2
    rm -rf "${SMOKE_DIR}"
    exit 1
  fi
  rm -rf "${SMOKE_DIR}"
  echo "✅ 已生成: ${APP}"
  echo "✅ 已打包: ${ZIP_PATH}"
else
  echo "✅ 已生成: ${APP}"
  echo "   运行: open \"${APP}\""
fi
