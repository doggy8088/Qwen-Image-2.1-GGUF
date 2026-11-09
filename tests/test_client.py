"""scripts/client.py 的單元測試（parse_lora 與 build_prompt）。

client.py 是以 uv script 形式執行的單檔腳本，不是套件，
因此以檔案路徑載入模組後直接測試其純函式。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("client", REPO_ROOT / "scripts" / "client.py")
assert _spec is not None and _spec.loader is not None
client = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(client)


def extra_of(prompt_text: str) -> dict:
    """取出 build_prompt 輸出中的 sd_cpp_extra_args JSON。"""
    return json.loads(prompt_text.split("<sd_cpp_extra_args>")[1].split("</sd_cpp_extra_args>")[0])


class ParseLoraTests(unittest.TestCase):
    def test_plain_path_defaults_to_weight_1(self):
        self.assertEqual(
            client.parse_lora("style.safetensors"),
            {"path": "style.safetensors", "multiplier": 1.0, "is_high_noise": False},
        )

    def test_path_with_weight(self):
        self.assertEqual(
            client.parse_lora("style.safetensors:0.8"),
            {"path": "style.safetensors", "multiplier": 0.8, "is_high_noise": False},
        )

    def test_subdirectory_path_with_weight(self):
        self.assertEqual(
            client.parse_lora("sub/dir/lora.safetensors:1"),
            {"path": "sub/dir/lora.safetensors", "multiplier": 1.0, "is_high_noise": False},
        )

    def test_non_numeric_suffix_is_part_of_path(self):
        self.assertEqual(client.parse_lora("weird:name.safetensors")["path"], "weird:name.safetensors")

    def test_non_finite_weight_is_not_a_weight(self):
        for suffix in ("nan", "inf", "-inf"):
            with self.subTest(suffix=suffix):
                result = client.parse_lora(f"a.safetensors:{suffix}")
                self.assertEqual(result["path"], f"a.safetensors:{suffix}")
                self.assertEqual(result["multiplier"], 1.0)


class BuildPromptTests(unittest.TestCase):
    def test_no_extra_args_returns_prompt_unchanged(self):
        args = client.parse_args(["generate", "一隻柴犬"])
        self.assertIsNone(args.lora)
        self.assertEqual(client.build_prompt(args), "一隻柴犬")

    def test_existing_sample_args_preserved(self):
        args = client.parse_args(["generate", "貓", "--steps", "30", "--seed", "42"])
        extra = extra_of(client.build_prompt(args))
        self.assertEqual(extra["sample_params"]["sample_steps"], 30)
        self.assertEqual(extra["seed"], 42)
        self.assertNotIn("lora", extra)

    def test_single_lora_with_steps(self):
        args = client.parse_args(
            ["generate", "一隻柴犬", "--lora", "pytorch_lora_weights.safetensors:1.0", "--steps", "4"]
        )
        extra = extra_of(client.build_prompt(args))
        self.assertEqual(
            extra["lora"],
            [{"path": "pytorch_lora_weights.safetensors", "multiplier": 1.0, "is_high_noise": False}],
        )
        self.assertEqual(extra["sample_params"]["sample_steps"], 4)

    def test_edit_with_multiple_loras(self):
        args = client.parse_args(
            ["edit", "改背景", "-i", "in.png", "--lora", "a.safetensors:0.6", "--lora", "b.safetensors"]
        )
        extra = extra_of(client.build_prompt(args))
        self.assertEqual(
            extra["lora"],
            [
                {"path": "a.safetensors", "multiplier": 0.6, "is_high_noise": False},
                {"path": "b.safetensors", "multiplier": 1.0, "is_high_noise": False},
            ],
        )

    def test_namespace_without_lora_attribute(self):
        ns = argparse.Namespace(prompt="x", steps=None, sampler=None, cfg=None, seed=None, negative=None)
        self.assertEqual(client.build_prompt(ns), "x")


if __name__ == "__main__":
    unittest.main()
