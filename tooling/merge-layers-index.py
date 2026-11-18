"""Merge a fresh layers build into the published runtime-layers index.

Single-variant rebuilds must not erase the other distro/node combos already
published: entries from the fresh build win on key collision, published-only
entries survive untouched. Usage: merge-layers-index.py PUBLISHED FRESH > MERGED
"""
import json
import sys

published_path, fresh_path = sys.argv[1], sys.argv[2]
published = json.load(open(published_path))
fresh = json.load(open(fresh_path))

assert published.get("schema") == fresh.get("schema"), "schema mismatch; do not merge across schemas"
pub_abis = set(published.get("abis", {}) if isinstance(published.get("abis"), dict) else published.get("abis", []))
fresh_abis = set(fresh.get("abis", {}) if isinstance(fresh.get("abis"), dict) else fresh.get("abis", []))
assert pub_abis == fresh_abis, "abi mismatch"
# The published abis block carries richer per-abi metadata; keep it verbatim.

merged_layers = dict(published.get("layers", {}))
for group, entries in fresh.get("layers", {}).items():
    # Deep merge per group (base/node/engine): fresh version keys win on
    # collision, published-only version keys (other distros/DSH versions)
    # survive. A plain top-level assignment would erase them.
    merged_layers.setdefault(group, {})
    if isinstance(entries, dict) and isinstance(merged_layers[group], dict):
        for key, layer in entries.items():
            merged_layers[group][key] = layer
    else:
        merged_layers[group] = entries

published["layers"] = merged_layers
published["notes"] = fresh.get("notes", published.get("notes"))
# compose 块（装机期组装清单）按子键深合并：fresh 的条目赢，published-only
# 的条目存活。整块赋值会像 layers 那样丢变体——曾有个 workflow 只建 debian-12，
# 一跑就把 run#3 发布的 ubuntu/debian-13 组装条目全抹了（2026-11-19 真机
# "compose has no base variant ubuntu-24.04.5-arm64-v8a" 事故根因）。
# 注：2026-11-19 装机期 npm 组装通道已撤（纯净版下线），此合并逻辑保留
# 供 base/node 的 compose（deb/官方 tar 直拉清单）继续使用。
if "compose" in fresh:
    pub_c = published.get("compose")
    if not isinstance(pub_c, dict):
        published["compose"] = fresh["compose"]
    else:
        for k, v in fresh["compose"].items():
            if isinstance(v, dict) and isinstance(pub_c.get(k), dict):
                pub_c[k].update(v)  # baseVariants 等按变体键合并
            else:
                pub_c[k] = v
json.dump(published, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
