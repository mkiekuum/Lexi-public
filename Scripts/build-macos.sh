#!/usr/bin/env bash
# Build, verify and install Lexi locally without touching the existing user database.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="3.7.0"
BUILD_NUMBER="371"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS上で実行してください。" >&2; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "XcodeとmacOS SDKが必要です。" >&2; exit 1
fi
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
  echo "Xcodeを選択してください: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
command -v swift >/dev/null || { echo "Swiftが見つかりません。" >&2; exit 1; }
if pgrep -x LexiDesktop >/dev/null 2>&1; then
  echo "Lexiが実行中です。ノートを保存してアプリを終了してから、再度インストールしてください。" >&2
  exit 1
fi

SWIFT_FLAGS=(--build-system native --jobs 2 --scratch-path .build)

printf '\n[1/7] Swift自動テストを実行しています…\n'
swift test "${SWIFT_FLAGS[@]}"
printf '\n[2/7] GUIとMCP ServerをReleaseビルドしています…\n'
swift build "${SWIFT_FLAGS[@]}" -c release --product LexiDesktop
swift build "${SWIFT_FLAGS[@]}" -c release --product LexiMCP
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)"
GUI="$BIN_DIR/LexiDesktop"
MCP="$BIN_DIR/LexiMCP"
[[ -f "$GUI" && -f "$MCP" ]] || { echo "Release実行ファイルが見つかりません。" >&2; exit 1; }
printf '\n[3/7] Swift/Python/MCP回帰テストを実行しています…\n'
LEXI_MCP_BINARY="$MCP" python3 -m unittest discover -s Tests -p 'test_*.py'

INSTALL_ROOT="$HOME/Desktop/Lexi"
mkdir -p "$INSTALL_ROOT"

APP="$INSTALL_ROOT/Lexi.app"
STAGE="$INSTALL_ROOT/.Lexi-install-$$.app"
BACKUP=""
JSON_SOURCE_DIR=""
cleanup() {
  if [[ -d "$STAGE" ]]; then rm -rf "$STAGE"; fi
  if [[ -n "$JSON_SOURCE_DIR" && -d "$JSON_SOURCE_DIR" ]]; then rm -rf "$JSON_SOURCE_DIR"; fi
}
trap cleanup EXIT
printf '\n[4/7] 新しい.appを一時フォルダで作成しています…\n'
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$GUI" "$STAGE/Contents/MacOS/LexiDesktop"
cp "$MCP" "$STAGE/Contents/Resources/LexiMCP"
chmod +x "$STAGE/Contents/MacOS/LexiDesktop" "$STAGE/Contents/Resources/LexiMCP"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleExecutable</key><string>LexiDesktop</string>
  <key>CFBundleIdentifier</key><string>app.local.lexi</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Lexi</string>
  <key>CFBundleDisplayName</key><string>Lexi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>LexiIcon</string>
</dict></plist>
PLIST
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
if command -v iconutil >/dev/null 2>&1; then
  if ! iconutil -c icns "$ROOT/Assets/LexiIcon.iconset" -o "$STAGE/Contents/Resources/LexiIcon.icns"; then
    echo "注意: アイコンの生成に失敗しましたが、アプリのビルドは継続します。" >&2
  fi
fi
cp "$ROOT/Assets/LexiEmblem.png" "$STAGE/Contents/Resources/LexiEmblem.png"
cp "$ROOT/Scripts/daijisen_parser.py" "$STAGE/Contents/Resources/daijisen_parser.py"
cp "$ROOT/Scripts/repair_dictionary_sections.py" "$STAGE/Contents/Resources/repair_dictionary_sections.py"
bash "$ROOT/Scripts/build-native-dictionary.sh"
NATIVE_BUILD_DIR="${LEXI_NATIVE_BUILD_DIR:-$ROOT/.build-native}"
cp "$NATIVE_BUILD_DIR/build/lexi-dictionary-reader" "$STAGE/Contents/Resources/lexi-dictionary-reader"
cp "$ROOT/NativeDictionary/LICENSE" "$STAGE/Contents/Resources/NativeDictionary-LICENSE.txt"
cp "$ROOT/NativeDictionary/README.md" "$STAGE/Contents/Resources/NativeDictionary-README.md"
mkdir -p "$STAGE/Contents/Resources/NativeDictionarySource"
cp "$ROOT/NativeDictionary/main.cpp" "$ROOT/NativeDictionary/CMakeLists.txt" "$STAGE/Contents/Resources/NativeDictionarySource/"

plutil -lint "$STAGE/Contents/Info.plist"

printf '\n[5/7] 署名とパッケージを確認しています…\n'
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$STAGE/Contents/Resources/LexiMCP"
  codesign --force --sign - "$STAGE/Contents/Resources/lexi-dictionary-reader"
  codesign --force --sign - "$STAGE"
  codesign --verify --deep "$STAGE"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$STAGE/Contents/Info.plist")" == "LexiDesktop" ]] || {
  echo "アプリの起動ファイルが誤っています。" >&2; exit 1;
}

printf '\n[6/7] データの安全バックアップを作成しています…\n'
DATA="$HOME/Library/Application Support/Lexi/Lexi.sqlite"
if [[ -f "$DATA" ]]; then
  BACKUP_DIR="$HOME/Documents/Lexi Backups"
  mkdir -p "$BACKUP_DIR"
    DATA_BACKUP="$BACKUP_DIR/Lexi-before-v${VERSION}-$(date '+%Y%m%d-%H%M%S')-$$.sqlite"
    JSON_BACKUP="$BACKUP_DIR/Lexi-before-v${VERSION}-$(date '+%Y%m%d-%H%M%S')-$$.json"
  python3 - "$DATA" "$DATA_BACKUP" <<'PY'
import sqlite3
import sys
from pathlib import Path

source_path, backup_path = map(Path, sys.argv[1:])
source = sqlite3.connect(f"{source_path.resolve().as_uri()}?mode=ro", uri=True)
destination = sqlite3.connect(backup_path)
try:
    source.backup(destination)
    destination.commit()
    journal_mode = destination.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
    if journal_mode.lower() != "delete":
        raise SystemExit(f"バックアップの独立化に失敗しました: journal_mode={journal_mode}")
    result = destination.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        raise SystemExit(f"SQLiteバックアップの整合性検査に失敗しました: {result}")
finally:
    destination.close()
    source.close()
PY
  [[ -s "$DATA_BACKUP" ]] || { echo "データバックアップが空です。インストールを中止します。" >&2; exit 1; }
  # Export from a disposable copy because opening a legacy DB can migrate it.
  JSON_SOURCE_DIR="$(mktemp -d "$BACKUP_DIR/.lexi-json-export.XXXXXX")"
  JSON_SOURCE="$JSON_SOURCE_DIR/Lexi.sqlite"
  cp "$DATA_BACKUP" "$JSON_SOURCE"
  python3 "$ROOT/Scripts/export_lexi_portable_json.py" \
    --db "$JSON_SOURCE" --out "$JSON_BACKUP"
  [[ -s "$JSON_BACKUP" ]] || { echo "JSONバックアップが空です。インストールを中止します。" >&2; exit 1; }
  echo "SQLiteバックアップ: $DATA_BACKUP"
  echo "JSONバックアップ: $JSON_BACKUP"
else
  echo "既存データはまだありません。"
fi

printf '\n[7/7] デスクトップにインストールしています…\n'
# Keep existing user-selected dictionary files untouched. Install the parser with Lexi itself.
mkdir -p "$HOME/.local/share/lexi"
cp "$ROOT/Scripts/daijisen_parser.py" "$HOME/.local/share/lexi/daijisen_parser.py"
cp "$STAGE/Contents/Resources/lexi-dictionary-reader" "$HOME/.local/share/lexi/lexi-dictionary-reader"
python3 "$HOME/.local/share/lexi/daijisen_parser.py" --help >/dev/null
# Migrate only an already-existing legacy dictionary, without modifying its contents.
python3 - "$INSTALL_ROOT/Dictionary/DAIJISEN.J" "$DATA.dictionary-source.json" <<'PYCONFIG'
from pathlib import Path
import sys, json, os
root, config = map(Path, sys.argv[1:])
if not config.exists() and (root / "Contents").is_dir() and all((root / "Headline" / name).is_file() for name in ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"]):
    config.parent.mkdir(parents=True, exist_ok=True)
    temp = config.with_suffix(".tmp")
    temp.write_text(json.dumps({"directory": str(root.resolve())}), encoding="utf-8")
    os.replace(temp, config)
PYCONFIG
if [[ -e "$APP" ]]; then
  mkdir -p "$HOME/Documents/Lexi Backups"
  BACKUP="$HOME/Documents/Lexi Backups/Lexi-prev-$(date '+%Y%m%d-%H%M%S')-$$.app"
  mv "$APP" "$BACKUP"
fi
if ! mv "$STAGE" "$APP"; then
  echo "新しいアプリの移動に失敗しました。" >&2
  if [[ -n "$BACKUP" && -e "$BACKUP" && ! -e "$APP" ]]; then mv "$BACKUP" "$APP"; fi
  exit 1
fi
mkdir -p "$HOME/.local/bin"
cp "$MCP" "$HOME/.local/bin/lexi-mcp"
chmod +x "$HOME/.local/bin/lexi-mcp"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$HOME/.local/bin/lexi-mcp"
  codesign --verify "$HOME/.local/bin/lexi-mcp"
fi
echo
echo "Lexi v${VERSION} をインストールしました。"
echo "アプリ: $APP"
echo "ローカル MCP: $HOME/.local/bin/lexi-mcp"
echo "データ: $DATA"
echo "辞典設定: アプリ内で参照フォルダを選択"
if [[ -n "$BACKUP" ]]; then echo "以前のアプリ: $BACKUP"; fi
LEGACY_APP="$HOME/Desktop/Lexi.app"
if [[ -L "$LEGACY_APP" ]]; then
  if [[ "$(readlink "$LEGACY_APP")" != "$APP" ]]; then
    echo "旧アプリのパスが別のリンク先を参照しているため変更しません: $LEGACY_APP" >&2
  fi
elif [[ -e "$LEGACY_APP" ]]; then
  LEGACY_BACKUP="$HOME/Documents/Lexi Backups/Lexi-legacy-location-$(date '+%Y%m%d-%H%M%S')-$$.app"
  mkdir -p "$HOME/Documents/Lexi Backups"
  mv "$LEGACY_APP" "$LEGACY_BACKUP"
  ln -s "$APP" "$LEGACY_APP"
  echo "旧アプリを保存しました: $LEGACY_BACKUP"
else
  ln -s "$APP" "$LEGACY_APP"
fi
if [[ "${LEXI_NO_LAUNCH:-0}" != "1" ]]; then
  open "$APP" || echo "自動起動できませんでした。FinderからLexi.appを開いてください。" >&2
fi
