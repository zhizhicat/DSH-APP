#!/usr/bin/env python3
"""export-compose.py — v1.5 compose 块导出器（三层分源·增量合成）。

从既有构建输入（package-lock / pins / 层描述）生成 layers-index 的 compose 块：
App 端「组装模式」按此清单直连国内镜像拉原始物合成层，全量层包照常兜底。

  base  : rootfs 镜像组+sha ｜ debs 增量包 asset ｜ python 包 asset（暂不走镜像）
  node  : node tar 镜像组+sha ｜ keepTop 过滤规则 ｜ symlink 表
  engine: pnpm tarball ｜ lock 驱动 packages 清单（name/version/path/integrity）
          ｜ adapter 增量包 asset（bridge/overlay 静态部分）

用法（build-layers.sh 构建后调用）：
  python3 runtime/export-compose.py --lock runtime/locks/dsh-<v>/package-lock.json \
    --pnpm-lock runtime/locks/pnpm-<v>/package-lock.json \
    --index out/layers-index.json --out out/compose.json [--engine-version <v>]
"""
import argparse
import json
import posixpath
import sys


def npm_tarball_path(name, version):
    """npm registry 规范 tarball 路径：@scope/name → @scope/name/-/name-<v>.tgz。"""
    if name.startswith("@"):
        return "%s/-/%s-%s.tgz" % (name, name.split("/", 1)[1], version)
    return "%s/-/%s-%s.tgz" % (name, name, version)


def lock_packages(lock, dest_root="opt/dsh"):
    """package-lock(v3) packages → compose packages 数组。

    packages 键即安装路径（相对 prefix 根），与 add_tree(dsh_prefix → opt/dsh) 的
    布局一一对应：opt/dsh/<key>。link 条目（workspace alias）转为 symlinks 条目。
    """
    out, symlinks = [], []
    for key, meta in (lock.get("packages") or {}).items():
        if not key:
            continue  # 根条目（安装目标本身），由 adapter 包承载
        name, version = meta.get("name"), meta.get("version")
        if not name or not version:
            # 键名兜底解析（旧 lock 无 name 字段时）
            name = key.rstrip("/").rsplit("node_modules/", 1)[-1]
            version = meta.get("version") or ""
        if meta.get("link"):
            symlinks.append({"path": "%s/%s" % (dest_root, key), "target": str(meta.get("resolved", ""))})
            continue
        integrity = meta.get("integrity")
        if not integrity:
            raise SystemExit("lock entry without integrity (unsupported): %s" % key)
        if not integrity.startswith("sha512-"):
            raise SystemExit("unsupported integrity algo for %s: %s" % (key, integrity[:16]))
        out.append({
            "name": name,
            "version": version,
            "path": "%s/%s" % (dest_root, key),
            "tarball": npm_tarball_path(name, version),
            "integrity": integrity,
        })
    return out, symlinks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", required=True, help="DSH package-lock.json")
    ap.add_argument("--pnpm-lock", help="pnpm package-lock.json（engine 的 pnpm 包）")
    ap.add_argument("--index", help="layers-index.json（读取 base/node 层描述）")
    ap.add_argument("--engine-version")
    ap.add_argument("--compose-dir", help="build_abi 的 export_deltas 产物目录（base-*/base-debs-*/engine-adapter-* json）")
    ap.add_argument("--node-mirrors", help="空格分隔的 node 发布镜像组（附加 /v<ver>/<file>）")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    compose = {"schema": 1}
    engine = compose.setdefault("engine", {})
    if args.engine_version:
        engine["version"] = args.engine_version

    dsh_lock = json.load(open(args.lock))
    packages, symlinks = lock_packages(dsh_lock)
    engine["packages"] = packages
    if symlinks:
        engine["symlinks"] = symlinks

    if args.pnpm_lock:
        pnpm_lock = json.load(open(args.pnpm_lock))
        # pnpm 是 zero-dependency：取根条目（""）或唯一 packages 成员
        pkgs = pnpm_lock.get("packages") or {}
        root = pkgs.get("") or {}
        name, version = root.get("name", "pnpm"), root.get("version")
        integrity = root.get("integrity")
        if not version or not integrity:
            entries = [(k, v) for k, v in pkgs.items() if v.get("version")]
            if entries:
                _, meta = entries[0]
                name, version, integrity = meta.get("name", "pnpm"), meta.get("version"), meta.get("integrity")
        if version and integrity:
            engine["pnpm"] = {"name": name, "version": version,
                              "tarball": npm_tarball_path(name, version), "integrity": integrity}
        else:
            raise SystemExit("cannot derive pnpm tarball identity from " + args.pnpm_lock)

    # compose-dir 聚合：export_deltas 的 base 镜像组/sha、增量包描述、adapter 包
    if args.compose_dir:
        import glob, os
        for bf in sorted(glob.glob(os.path.join(args.compose_dir, "base-*.json"))):
            if "debs" in os.path.basename(bf):
                continue
            doc = json.load(open(bf))
            variant = os.path.basename(bf)[len("base-"):-len(".json")]
            compose.setdefault("baseVariants", {})[variant] = doc["base"]
            if args.node_mirrors and "node" not in compose:
                compose["node"] = doc["node"]
        for bf in sorted(glob.glob(os.path.join(args.compose_dir, "base-debs-*.json"))):
            variant = os.path.basename(bf)[len("base-debs-"):-len(".json")]
            compose.setdefault("baseVariants", {}).setdefault(variant, {})["debsDelta"] = json.load(open(bf))
        for bf in sorted(glob.glob(os.path.join(args.compose_dir, "engine-adapter-*.json"))):
            engine["adapter"] = json.load(open(bf))
        if args.node_mirrors and "node" in compose:
            nt = compose["node"]["tar"]
            nt["mirrors"] = ["%s/v%s/%s" % (m.rstrip("/"), nt.get("version", ""), nt.get("file", ""))
                             for m in args.node_mirrors.split()]

    # base/node 层的原始物镜像组：构建时由 build-layers.sh 注入（--mirror-args 或 env），
    # 这里只搭骨架；镜像路径与 sha 的权威来源是 pins.json + 变体循环。
    if args.index:
        idx = json.load(open(args.index))
        engine_key = args.engine_version or next(iter(idx["layers"]["engine"]), None)
        engine["fullLayerAsset"] = idx["layers"]["engine"].get(engine_key, {}).get("asset") if engine_key else None
        compose["indexRef"] = {"schema": idx.get("schema"), "engineKey": engine_key}

    json.dump(compose, open(args.out, "w"), indent=2, sort_keys=True)
    print("wrote %s (packages=%d, symlinks=%d)" % (args.out, len(packages), len(symlinks)))


if __name__ == "__main__":
    main()
