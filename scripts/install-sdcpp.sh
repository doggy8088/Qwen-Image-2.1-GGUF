#!/usr/bin/env bash
#
# 下載 stable-diffusion.cpp 預先編譯的執行檔（sd-server / sd-cli）到 BIN_DIR。
#
# 環境變數：
#   SDCPP_VERSION  GitHub Release tag，或 latest（預設：master-898-2bb7294）
#   SDCPP_VARIANT  auto | cpu | vulkan | rocm（僅 Linux 有差異，預設：auto）
#   BIN_DIR        安裝目錄（預設：./bin）
#
set -euo pipefail

REPO="leejet/stable-diffusion.cpp"
SDCPP_VERSION="${SDCPP_VERSION:-master-898-2bb7294}"
SDCPP_VARIANT="${SDCPP_VARIANT:-auto}"
BIN_DIR="${BIN_DIR:-./bin}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m錯誤：\033[0m%s\n' "$*" >&2; exit 1; }

for cmd in curl unzip; do
  command -v "$cmd" >/dev/null 2>&1 || die "找不到 $cmd，請先安裝。"
done

os="$(uname -s)"
arch="$(uname -m)"

# 依作業系統與 CPU 架構挑選 Release 中對應的壓縮檔名稱（正規表示式）
case "$os/$arch" in
  Darwin/arm64)
    pattern='bin-Darwin-.*-arm64\.zip$'
    ;;
  Linux/x86_64)
    variant="$SDCPP_VARIANT"
    [ "$variant" = "auto" ] && variant="cpu"
    case "$variant" in
      cpu)    pattern='bin-Linux-Ubuntu-[0-9.]+-x86_64\.zip$' ;;
      vulkan) pattern='bin-Linux-Ubuntu-[0-9.]+-x86_64-vulkan\.zip$' ;;
      rocm)   pattern='bin-Linux-Ubuntu-[0-9.]+-x86_64-rocm-[0-9.]+\.zip$' ;;
      *)      die "不支援的 SDCPP_VARIANT：$variant（可用值：cpu、vulkan、rocm）" ;;
    esac
    ;;
  *)
    die "官方未提供 $os/$arch 的預先編譯版本，請改用 make build-sdcpp 從原始碼編譯。"
    ;;
esac

if [ "$SDCPP_VERSION" = "latest" ]; then
  api_url="https://api.github.com/repos/$REPO/releases/latest"
else
  api_url="https://api.github.com/repos/$REPO/releases/tags/$SDCPP_VERSION"
fi

log "查詢 $REPO 的 Release：$SDCPP_VERSION"
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
release_json="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} "$api_url")" \
  || die "無法取得 Release 資訊：$api_url"

tag="$(printf '%s' "$release_json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
url="$(printf '%s' "$release_json" \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | sed 's/.*"\(https[^"]*\)"$/\1/' \
  | grep -E "$pattern" | head -1 || true)"
[ -n "$url" ] || die "在 Release $tag 中找不到符合 $os/$arch 的檔案（pattern：$pattern）"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "下載 ${url##*/}"
curl -fL --retry 5 --retry-all-errors --progress-bar -o "$tmp/sdcpp.zip" "$url"

log "解壓縮到 $BIN_DIR"
mkdir -p "$BIN_DIR"
unzip -o -q "$tmp/sdcpp.zip" -d "$tmp/extract"
# 部分壓縮檔會多包一層目錄，一律攤平到 BIN_DIR
find "$tmp/extract" -type f -exec cp -f {} "$BIN_DIR"/ \;
chmod +x "$BIN_DIR"/sd-* 2>/dev/null || true

if [ "$os" = "Darwin" ]; then
  # 移除 Gatekeeper 隔離屬性，避免 macOS 阻擋未簽署的執行檔
  xattr -dr com.apple.quarantine "$BIN_DIR" 2>/dev/null || true
fi

printf '%s\n' "$tag" > "$BIN_DIR/.sdcpp-version"

[ -x "$BIN_DIR/sd-server" ] || die "安裝後找不到 $BIN_DIR/sd-server"
log "完成：$("$BIN_DIR/sd-server" -h 2>&1 | head -1)"
