#!/bin/zsh
set -euo pipefail

# 先由 package_app.sh 生成基线；此测试只验证中途失败会原样恢复该基线。
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/packaging/package_app.sh"
APP="$ROOT/dist/BattCycle.app"
ARCHIVE="$ROOT/dist/BattCycle.app.zip"

[[ -d "$APP" && -f "$ARCHIVE" ]] || {
  print -u2 -- "packaging rollback: 缺少基线 App 或 ZIP"
  exit 1
}

original_dist_mode="$(/usr/bin/stat -f '%Lp' "$ROOT/dist")"
acl_probe_root=""
restore_dist_mode() {
  /bin/chmod -N "$ROOT/dist" 2>/dev/null || true
  /bin/chmod "$original_dist_mode" "$ROOT/dist" 2>/dev/null || true
  if [[ -n "$acl_probe_root" && "$acl_probe_root" == /tmp/battcycle-package-acl-test.* ]]; then
    /bin/rm -rf "$acl_probe_root"
  fi
}
trap restore_dist_mode EXIT

before_app_inode="$(/usr/bin/stat -f '%i' "$APP")"
before_archive_inode="$(/usr/bin/stat -f '%i' "$ARCHIVE")"
before_archive_sha="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"

# 仓库根即使 POSIX mode 安全，只要带扩展 ACL 也必须在构建前拒绝。
acl_probe_root="$(mktemp -d /tmp/battcycle-package-acl-test.XXXXXX)"
mkdir -p "$acl_probe_root/packaging"
/bin/cp "$PACKAGE" "$acl_probe_root/packaging/package_app.sh"
/bin/chmod +a "everyone allow add_file,delete_child" "$acl_probe_root"
acl_output=""
if acl_output="$(/bin/zsh "$acl_probe_root/packaging/package_app.sh" 2>&1)"; then
  print -u2 -- "packaging rollback: 带 ACL 的仓库根目录未被拒绝"
  exit 1
fi
[[ "$acl_output" == *"仓库根目录不得包含扩展 ACL"* ]] || {
  print -u2 -- "packaging rollback: 未报告仓库根目录 ACL"
  exit 1
}
/bin/rm -rf "$acl_probe_root"
acl_probe_root=""

# 不安全的输出目录必须在 Swift 构建和任何替换前被拒绝。
/bin/chmod 0777 "$ROOT/dist"
insecure_output=""
if insecure_output="$(/bin/zsh "$PACKAGE" 2>&1)"; then
  print -u2 -- "packaging rollback: 可写输出目录未被拒绝"
  exit 1
fi
[[ "$insecure_output" == *"输出目录不得允许组或其他用户写入"* ]] || {
  print -u2 -- "packaging rollback: 未报告不安全输出目录"
  exit 1
}
[[ "$insecure_output" != *"构建 BattCycle release"* ]] || {
  print -u2 -- "packaging rollback: 不安全输出目录仍进入 Swift 构建"
  exit 1
}
/bin/chmod 0700 "$ROOT/dist"
[[ "$(/usr/bin/stat -f '%i' "$APP")" == "$before_app_inode" ]] || {
  print -u2 -- "packaging rollback: 拒绝不安全目录时改动了旧 App"
  exit 1
}
[[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" == "$before_archive_sha" ]] || {
  print -u2 -- "packaging rollback: 拒绝不安全目录时改动了旧 ZIP"
  exit 1
}

# 项目内 dist ACL 会在打包前清除，随后继续使用 0700 权限。
/bin/chmod +a "everyone allow add_file,delete_child" "$ROOT/dist"
if BATTCYCLE_TEST_FAIL_AFTER_APP_PUBLISH=1 /bin/zsh "$PACKAGE" >/dev/null 2>&1; then
  print -u2 -- "packaging rollback: 故障注入未使打包失败"
  exit 1
fi
dist_acl_listing="$(/bin/ls -lde "$ROOT/dist")"
[[ "$dist_acl_listing" != *$'\n'* ]] || {
  print -u2 -- "packaging rollback: 输出目录 ACL 未被清除"
  exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$ROOT/dist")" == "700" ]] || {
  print -u2 -- "packaging rollback: 输出目录未规范化为 0700"
  exit 1
}

after_app_inode="$(/usr/bin/stat -f '%i' "$APP")"
after_archive_inode="$(/usr/bin/stat -f '%i' "$ARCHIVE")"
after_archive_sha="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"

[[ "$after_app_inode" == "$before_app_inode" ]] || {
  print -u2 -- "packaging rollback: 旧 App 未原样恢复"
  exit 1
}
[[ "$after_archive_inode" == "$before_archive_inode" ]] || {
  print -u2 -- "packaging rollback: 旧 ZIP 被替换"
  exit 1
}
[[ "$after_archive_sha" == "$before_archive_sha" ]] || {
  print -u2 -- "packaging rollback: 旧 ZIP 内容发生变化"
  exit 1
}

/usr/bin/codesign --verify --deep --verbose=2 "$APP"
print -- "packaging rollback: ok"
