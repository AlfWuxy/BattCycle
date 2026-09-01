#!/bin/zsh
set -euo pipefail

# 构建一个可重复执行的本地应用包，并固定输出到项目 dist/。
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_DIR="$ROOT/dist"
APP="$APP_DIR/BattCycle.app"
ARCHIVE="$APP_DIR/BattCycle.app.zip"
ICON_SRC="$ROOT/packaging/icon-source.png"

directory_metadata() {
  /usr/bin/stat -f '%HT:%u:%Lp:%d:%i' "$1" 2>/dev/null
}

validate_no_extended_acl() {
  local path="$1"
  local label="$2"
  local acl_listing

  acl_listing="$(/bin/ls -lde "$path" 2>/dev/null)" || {
    print -u2 -- "无法读取${label} ACL：$path"
    return 1
  }
  if [[ "$acl_listing" == *$'\n'* ]]; then
    print -u2 -- "${label}不得包含扩展 ACL：$path"
    return 1
  fi
}

validate_owned_directory() {
  local path="$1"
  local label="$2"
  local metadata
  local mode
  local mode_value
  local -a fields

  metadata="$(directory_metadata "$path")" || {
    print -u2 -- "无法读取${label}元数据：$path"
    return 1
  }
  fields=("${(@s/:/)metadata}")
  if (( ${#fields[@]} != 5 )) || [[ "${fields[1]}" != "Directory" ]]; then
    print -u2 -- "${label}必须是未跟随符号链接的真实目录：$path"
    return 1
  fi
  if [[ "${fields[2]}" != "$EUID" ]]; then
    print -u2 -- "${label}必须由当前用户拥有：$path"
    return 1
  fi
  mode="${fields[3]}"
  if [[ "$mode" != <-> ]]; then
    print -u2 -- "${label}权限无法解析：$path"
    return 1
  fi
  mode_value=$(( 8#$mode ))
  if (( (mode_value & 8#22) != 0 )); then
    print -u2 -- "${label}不得允许组或其他用户写入：$path"
    return 1
  fi
}

verify_directory_identity() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local current
  validate_no_extended_acl "$path" "$label" || return 1
  current="$(directory_metadata "$path")" || {
    print -u2 -- "${label}已消失或无法读取：$path"
    return 1
  }
  if [[ "$current" != "$expected" ]]; then
    print -u2 -- "${label}身份发生变化，拒绝继续：$path"
    return 1
  fi
}

validate_owned_directory "$ROOT" "仓库根目录"
validate_no_extended_acl "$ROOT" "仓库根目录"
mkdir -p "$APP_DIR"
validate_owned_directory "$APP_DIR" "输出目录"
/bin/chmod -N "$APP_DIR"
/bin/chmod 700 "$APP_DIR"
validate_owned_directory "$APP_DIR" "输出目录"
validate_no_extended_acl "$APP_DIR" "输出目录"

ROOT_IDENTITY="$(directory_metadata "$ROOT")"
APP_DIR_IDENTITY="$(directory_metadata "$APP_DIR")"
TEMP_ROOT="$(mktemp -d "$APP_DIR/.battcycle-package.XXXXXX")"
validate_owned_directory "$TEMP_ROOT" "临时打包目录"
validate_no_extended_acl "$TEMP_ROOT" "临时打包目录"
TEMP_ROOT_IDENTITY="$(directory_metadata "$TEMP_ROOT")"
BUILD_ROOT="$TEMP_ROOT/swift-build"
TEMP_APP="$TEMP_ROOT/BattCycle.app"
TEMP_ARCHIVE="$TEMP_ROOT/BattCycle.app.zip"
BACKUP_APP=""
BACKUP_ARCHIVE=""
TARGET_REPLACED=0
ARCHIVE_REPLACED=0
PUBLISHED=0

verify_package_roots() {
  verify_directory_identity "$ROOT" "$ROOT_IDENTITY" "仓库根目录" || return 1
  verify_directory_identity "$APP_DIR" "$APP_DIR_IDENTITY" "输出目录" || return 1
  verify_directory_identity "$TEMP_ROOT" "$TEMP_ROOT_IDENTITY" "临时打包目录" || return 1
}

cleanup() {
  if ! verify_package_roots; then
    print -u2 -- "打包目录身份异常，已跳过自动回滚和递归清理；请人工检查：$TEMP_ROOT"
    return 0
  fi
  if (( PUBLISHED == 0 )); then
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
      if [[ -e "$APP" ]]; then
        /bin/mv "$APP" "$TEMP_ROOT/failed-BattCycle.app" || true
      fi
      /bin/mv "$BACKUP_APP" "$APP" || true
    elif (( TARGET_REPLACED == 1 )) && [[ -e "$APP" ]]; then
      /bin/mv "$APP" "$TEMP_ROOT/failed-BattCycle.app" || true
    fi
    if [[ -n "$BACKUP_ARCHIVE" && -e "$BACKUP_ARCHIVE" ]]; then
      if [[ -e "$ARCHIVE" ]]; then
        /bin/mv "$ARCHIVE" "$TEMP_ROOT/failed-BattCycle.app.zip" || true
      fi
      /bin/mv "$BACKUP_ARCHIVE" "$ARCHIVE" || true
    elif (( ARCHIVE_REPLACED == 1 )) && [[ -e "$ARCHIVE" ]]; then
      /bin/mv "$ARCHIVE" "$TEMP_ROOT/failed-BattCycle.app.zip" || true
    fi
  fi
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"
verify_package_roots

echo "构建 BattCycle release…"
swift build --scratch-path "$BUILD_ROOT" -c release --product BattCycle
BIN="$(swift build --scratch-path "$BUILD_ROOT" -c release --show-bin-path)/BattCycle"

verify_package_roots
mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources/scripts"
install -m 755 "$BIN" "$TEMP_APP/Contents/MacOS/BattCycle"
install -m 644 "$ROOT/packaging/Info.plist" "$TEMP_APP/Contents/Info.plist"

RUNTIME_SCRIPTS=(
  battery_cycle_stress.sh
  mlx_gpu_stress.py
  battcycle
  start-detached.sh
  active_console_users.py
  battcycle_config.py
  bounded_exec.py
  engine_lock.py
  process_group_marker.py
  process_group_exec.py
)

for script_name in "${RUNTIME_SCRIPTS[@]}"; do
  script_path="$ROOT/scripts/$script_name"
  if [[ ! -f "$script_path" ]]; then
    echo "缺少运行时脚本：$script_path" >&2
    exit 1
  fi
  install -m 755 "$script_path" "$TEMP_APP/Contents/Resources/scripts/$script_name"
done

verify_package_roots
if [[ -f "$ICON_SRC" ]] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
  ICONSET_ROOT="$(mktemp -d "$TEMP_ROOT/icon.XXXXXX")"
  ICONSET_DIR="$ICONSET_ROOT/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  MASTER="$ICONSET_ROOT/master.png"
  sips -s format png -z 1024 1024 "$ICON_SRC" --out "$MASTER" >/dev/null
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$TEMP_APP/Contents/Resources/AppIcon.icns"
  /bin/rm -rf "$ICONSET_ROOT"
fi

verify_package_roots
# sips/iconutil 可能给临时产物附加 Finder 元数据；仅规范化本次生成的 bundle。
/usr/bin/xattr -cr "$TEMP_APP"
/usr/bin/xattr -d com.apple.FinderInfo "$TEMP_APP" 2>/dev/null || true
/usr/bin/xattr -d com.apple.ResourceFork "$TEMP_APP" 2>/dev/null || true

# 临时包签名成功并验证后，再在同一文件系统内替换目标。
codesign --force --deep --sign - "$TEMP_APP"
/usr/bin/xattr -d com.apple.FinderInfo "$TEMP_APP" 2>/dev/null || true
/usr/bin/xattr -d com.apple.ResourceFork "$TEMP_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"

# ZIP 不保留 Finder 扩展属性，作为本地可传输产物；当前公开发布仍限源码。
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$TEMP_APP" "$TEMP_ARCHIVE"
VERIFY_DIR="$TEMP_ROOT/archive-verify"
mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k --norsrc --noextattr --noqtn --noacl \
  "$TEMP_ARCHIVE" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/BattCycle.app"

verify_package_roots
if [[ -L "$APP" ]]; then
  echo "拒绝覆盖符号链接应用：$APP" >&2
  exit 1
fi
if [[ -e "$APP" ]]; then
  BACKUP_APP="$APP_DIR/.BattCycle.app.backup.$$"
  if [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
    echo "拒绝使用已存在的应用备份路径：$BACKUP_APP" >&2
    exit 1
  fi
  /bin/mv "$APP" "$BACKUP_APP"
fi
if ! /bin/mv "$TEMP_APP" "$APP"; then
  echo "应用替换失败，正在恢复上一版本" >&2
  exit 1
fi
TARGET_REPLACED=1

# Desktop 可能在移动后重新附加 Finder 元数据；裸 App 仅做普通签名校验。
# 可传输 ZIP 的 clean extraction 会在下方继续执行严格验签。
codesign --verify --deep --verbose=2 "$APP"

# 仅供回滚测试使用：在 App 已替换而 ZIP 尚未替换时模拟发布失败。
if [[ "${BATTCYCLE_TEST_FAIL_AFTER_APP_PUBLISH:-0}" == "1" ]]; then
  echo "测试故障注入：App 替换后终止发布" >&2
  exit 86
fi

verify_package_roots
if [[ -L "$ARCHIVE" ]]; then
  echo "拒绝覆盖符号链接归档：$ARCHIVE" >&2
  exit 1
fi
if [[ -e "$ARCHIVE" ]]; then
  BACKUP_ARCHIVE="$APP_DIR/.BattCycle.app.zip.backup.$$"
  if [[ -e "$BACKUP_ARCHIVE" || -L "$BACKUP_ARCHIVE" ]]; then
    echo "拒绝使用已存在的归档备份路径：$BACKUP_ARCHIVE" >&2
    exit 1
  fi
  /bin/mv "$ARCHIVE" "$BACKUP_ARCHIVE"
fi
if ! /bin/mv "$TEMP_ARCHIVE" "$ARCHIVE"; then
  echo "归档替换失败，正在恢复上一版本" >&2
  exit 1
fi
ARCHIVE_REPLACED=1

FINAL_VERIFY_DIR="$TEMP_ROOT/final-archive-verify"
mkdir -p "$FINAL_VERIFY_DIR"
/usr/bin/ditto -x -k --norsrc --noextattr --noqtn --noacl \
  "$ARCHIVE" "$FINAL_VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$FINAL_VERIFY_DIR/BattCycle.app"

verify_package_roots
PUBLISHED=1
if [[ -n "$BACKUP_APP" ]]; then
  /bin/rm -rf "$BACKUP_APP" || echo "警告：无法删除旧 App 备份：$BACKUP_APP" >&2
  BACKUP_APP=""
fi
if [[ -n "$BACKUP_ARCHIVE" ]]; then
  /bin/rm -f "$BACKUP_ARCHIVE" || echo "警告：无法删除旧 ZIP 备份：$BACKUP_ARCHIVE" >&2
  BACKUP_ARCHIVE=""
fi

echo "已生成 $APP"
echo "正式归档：$ARCHIVE"
echo "打开方式：open '$APP'"
