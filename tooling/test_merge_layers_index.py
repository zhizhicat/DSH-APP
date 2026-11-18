"""merge-layers-index.py 的回归测试。

2026-11-19 事故：compose 块整块跟 fresh 走，pure.yml 只建 debian-12，
一跑就把已发布的 ubuntu/debian-13 组装条目抹掉。锁死：
1. compose 按变体键深合并（fresh 条目赢，published-only 存活）
2. layers 跨变体存活（既有行为）
3. schema 不匹配拒绝合并
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "tooling" / "merge-layers-index.py"


def merge(published: dict, fresh: dict) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as pf:
        json.dump(published, pf); pub_path = pf.name
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as ff:
        json.dump(fresh, ff); fresh_path = ff.name
    return json.loads(subprocess.run(
        [sys.executable, str(TOOL), pub_path, fresh_path],
        capture_output=True, text=True, check=True,
    ).stdout)


class ComposeMergeTest(unittest.TestCase):
    def test_deep_merge_keeps_published_variants(self):
        """pure(仅 debian-12 fresh)不得抹掉已发布的 ubuntu/debian-13 条目。"""
        published = {
            "schema": 3, "abis": ["arm64-v8a"],
            "layers": {"base": {"ubuntu-24.04.5": {"asset": "u"}, "debian-13": {"asset": "d13"}}},
            "compose": {"baseVariants": {
                "ubuntu-24.04.5-arm64-v8a": {"rootfs": {"sha256": "a"}},
                "debian-13-arm64-v8a": {"rootfs": {"sha256": "b"}},
            }},
        }
        fresh = {
            "schema": 3, "abis": ["arm64-v8a"],
            "layers": {"base": {"debian-12": {"asset": "d12"}}},
            "compose": {"baseVariants": {"debian-12-arm64-v8a": {"rootfs": {"sha256": "c"}}}},
        }
        merged = merge(published, fresh)
        bv = merged["compose"]["baseVariants"]
        self.assertEqual(set(bv), {
            "ubuntu-24.04.5-arm64-v8a", "debian-13-arm64-v8a", "debian-12-arm64-v8a",
        }, "fresh 只有自己的变体，另两个必须存活")
        self.assertEqual(bv["debian-12-arm64-v8a"]["rootfs"]["sha256"], "c", "fresh 条目赢")

    def test_fresh_without_compose_keeps_published(self):
        published = {"schema": 3, "abis": ["arm64-v8a"], "layers": {},
                     "compose": {"baseVariants": {"debian-12-arm64-v8a": {}}}}
        fresh = {"schema": 3, "abis": ["arm64-v8a"], "layers": {}}
        self.assertIn("debian-12-arm64-v8a", merge(published, fresh)["compose"]["baseVariants"])

    def test_layers_survive_partial_fresh(self):
        published = {"schema": 3, "abis": ["arm64-v8a"],
                     "layers": {"base": {"ubuntu-24.04.5": {"asset": "u"}, "debian-13": {"asset": "d13"}}}}
        fresh = {"schema": 3, "abis": ["arm64-v8a"],
                 "layers": {"base": {"ubuntu-24.04.5": {"asset": "u2"}}}}
        merged = merge(published, fresh)
        self.assertEqual(merged["layers"]["base"]["ubuntu-24.04.5"]["asset"], "u2")
        self.assertEqual(merged["layers"]["base"]["debian-13"]["asset"], "d13")

    def test_schema_mismatch_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            merge({"schema": 3, "abis": ["arm64-v8a"], "layers": {}},
                  {"schema": 2, "abis": ["arm64-v8a"], "layers": {}})


if __name__ == "__main__":
    unittest.main()
