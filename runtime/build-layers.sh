#!/usr/bin/env bash
# build-layers.sh — 档二变体通道：三层（base/node/engine）层包构建 driver。
#
# 产出一个 runtime-layers release 的全部内容：
#   out/layers-index.json                    变体目录（schema 3，App 端选择页消费）
#   out/<abi>/assets/runtime/*.tar.xz        全部层包（跨变体去重：base/node 内容寻址）
#
# 为什么不跑 termux proot：官方池已轮换掉 pin 的 deb（全镜像 404），容器四件套
# 从官方 release APK 1:1 还原（与层内容无关，仅 manifest 元数据需要它的 sha/bytes）。
#
# 用法（CI 或本地）：
#   RUNTIME_VARIANTS="ubuntu-24.04.5:24.22.1 debian-12:24.22.1 debian-13:24.22.1 ubuntu-26.04.1:24.22.1" \
#   bash runtime/build-layers.sh
# DSH_VERSION 留空（默认）= 构建时拉 npm 上游 latest；要回滚时设具体版本号 pin。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/build-runtime.sh"

RUNTIME_LAYERS=3
: "${RUNTIME_VARIANTS:?set RUNTIME_VARIANTS, e.g. 'ubuntu-24.04.5:24.22.1 debian-12:24.22.1'}"
OFFICIAL_APK_URL="${OFFICIAL_APK_URL:-https://github.com/ccch1mneyyy/dsh-Go/releases/download/v1.0.15/dsh-go-1.0.15-arm64.apk}"

mkdir -p "$CACHE" "$WORK" "$OUT"
abi=arm64-v8a

# -- 官方 APK 还原 jniLibs（proot 四件套；一次性） --
restore_dir="$WORK/restore-jni/$abi"
if [[ ! -f "$restore_dir/.done" ]]; then
  mkdir -p "$restore_dir"
  log "restoring container libs from official release"
  apk_cached="$CACHE/release/dsh-go-1.0.15-arm64.apk"
  mkdir -p "$CACHE/release"
  if [[ ! -s "$apk_cached" ]]; then
    curl -fSL --retry 3 -o "$apk_cached" "$OFFICIAL_APK_URL"
    curl -fSL --retry 3 -o "$CACHE/release/dsh-go-1.0.15-arm64.apk.sha256" "${OFFICIAL_APK_URL%.apk}.sha256" 2>/dev/null || true
  fi
  unzip -o -q "$apk_cached" 'lib/arm64-v8a/*' -d "$restore_dir/unzipped"
  cp "$restore_dir"/unzipped/lib/arm64-v8a/libproot.so \
     "$restore_dir"/unzipped/lib/arm64-v8a/libproot-loader.so \
     "$restore_dir"/unzipped/lib/arm64-v8a/libtalloc.so \
     "$restore_dir"/unzipped/lib/arm64-v8a/libandroid-shmem.so \
     "$restore_dir/"
  rm -rf "$restore_dir/unzipped"
  touch "$restore_dir/.done"
fi
export JNILIBS_RESTORE_DIR="$restore_dir"

# DSH pin: empty = resolve the latest published version from the npm registry.
if [[ -z "$DSH_VERSION" ]]; then
  bin="$(host_npm)"
  DSH_VERSION="$(PATH="$bin:$PATH" npm view @deepseek-ai/dsh version --registry "$NPM_REGISTRY" 2>/dev/null)" \
    || die "cannot resolve @deepseek-ai/dsh latest version from $NPM_REGISTRY"
  [[ "$DSH_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "npm returned a suspicious DSH version: $DSH_VERSION"
  log "DSH unpinned: resolved upstream latest @deepseek-ai/dsh@$DSH_VERSION"
fi

# -- 变体循环（BASE/NODE_VERSION 由 build_abi 消费） --
for pair in $RUNTIME_VARIANTS; do
  base_spec="${pair%%:*}"; NODE_VERSION="${pair##*:}"
  BASE="$base_spec"
  [[ "$BASE" != *-* ]] && BASE="ubuntu-$BASE"
  DISTRO="${BASE%%-*}"; BASE_VER="${BASE#*-}"
  case "$DISTRO" in
    ubuntu) UBUNTU_VERSION="$BASE_VER"; APT_CODENAME="$([[ "$BASE_VER" == 24.* ]] && echo noble || echo resolute)"
            UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/${BASE_VER%.*}/release" ;;
    debian) UBUNTU_VERSION=""; APT_CODENAME="$([[ "$BASE_VER" == 12 ]] && echo bookworm || echo trixie)" ;;
    *) die "unsupported BASE distro: $BASE" ;;
  esac
  log "=== variant base=$BASE node=$NODE_VERSION dsh=$DSH_VERSION ==="
  build_abi "$abi"
done

write_layers_index "$abi"
log "done: $OUT/layers-index.json"
