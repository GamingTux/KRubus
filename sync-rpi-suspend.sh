#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/packages/rpi-suspend"
UPSTREAM_URL="https://github.com/GamingTux/rpi-suspend.git"

echo "🔍 Prüfe Upstream-Repository ($UPSTREAM_URL)..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

git clone --depth 1 "$UPSTREAM_URL" "$TMP_DIR" >/dev/null

if [[ ! -d "$TMP_DIR/pkg/DEBIAN" ]]; then
  echo "❌ Kein pkg/DEBIAN im Upstream-Repository gefunden."
  exit 1
fi

UP_VER="$(grep -i '^Version:' "$TMP_DIR/pkg/DEBIAN/control" | awk '{print $2}')"
CUR_VER="$(grep -i '^Version:' "$TARGET_DIR/DEBIAN/control" 2>/dev/null | awk '{print $2}' || echo 'none')"

echo "Upstream-Version: $UP_VER"
echo "Lokale Version:   $CUR_VER"

if [[ "$UP_VER" != "$CUR_VER" ]] || ! diff -rq "$TARGET_DIR/etc" "$TMP_DIR/pkg/etc" >/dev/null 2>&1 || ! diff -rq "$TARGET_DIR/usr" "$TMP_DIR/pkg/usr" >/dev/null 2>&1; then
  echo "📦 Aktualisiere packages/rpi-suspend..."
  rm -rf "$TARGET_DIR"
  cp -a "$TMP_DIR/pkg" "$TARGET_DIR"
  chmod 0755 "$TARGET_DIR/DEBIAN/postinst" \
             "$TARGET_DIR/DEBIAN/prerm" \
             "$TARGET_DIR/DEBIAN/postrm" \
             "$TARGET_DIR/usr/bin/rpi-suspend" 2>/dev/null || true
  echo "✅ packages/rpi-suspend erfolgreich auf Version $UP_VER aktualisiert!"
else
  echo "✔ packages/rpi-suspend ist bereits auf dem neuesten Stand."
fi
