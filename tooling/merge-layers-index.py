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
for name, layer in fresh.get("layers", {}).items():
    merged_layers[name] = layer

published["layers"] = merged_layers
published["notes"] = fresh.get("notes", published.get("notes"))
json.dump(published, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
