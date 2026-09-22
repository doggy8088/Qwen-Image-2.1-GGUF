#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["openai>=1.99"]
# ///
"""以官方 OpenAI Python SDK 呼叫本機 sd-server 的 OpenAI 相容圖片 API。

範例：
    uv run scripts/client.py generate "一隻戴著墨鏡的柴犬" --size 1024x1024
    uv run scripts/client.py edit "把背景換成夕陽海灘" -i outputs/input.png
    uv run scripts/client.py models

sd-server 只會讀取 OpenAI 標準欄位（prompt、n、size、output_format…）。
步數、CFG、種子等原生參數，會以 <sd_cpp_extra_args> JSON 區塊附加在
prompt 後方傳送，伺服器會在生成前將其移除。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path

from openai import OpenAI

DEFAULT_BASE_URL = "http://127.0.0.1:1234/v1"


def build_prompt(args: argparse.Namespace) -> str:
    """將 sd.cpp 原生參數以 sd_cpp_extra_args 附加到 prompt。"""
    extra: dict = {}
    sample: dict = {}
    if args.steps is not None:
        sample["sample_steps"] = args.steps
    if args.sampler:
        sample["sample_method"] = args.sampler
    if args.cfg is not None:
        sample["guidance"] = {"txt_cfg": args.cfg}
    if sample:
        extra["sample_params"] = sample
    if args.seed is not None:
        extra["seed"] = args.seed
    if args.negative:
        extra["negative_prompt"] = args.negative
    if not extra:
        return args.prompt
    return f"{args.prompt} <sd_cpp_extra_args>{json.dumps(extra, ensure_ascii=False)}</sd_cpp_extra_args>"


def save_images(resp, out_dir: Path, kind: str, fmt: str) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    ext = "jpg" if fmt == "jpeg" else fmt
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    paths = []
    for i, item in enumerate(resp.data or []):
        if not item.b64_json:
            continue
        path = out_dir / f"{stamp}-{kind}-{i + 1}.{ext}"
        path.write_bytes(base64.b64decode(item.b64_json))
        paths.append(path)
    return paths


def cmd_generate(client: OpenAI, args: argparse.Namespace) -> list[Path]:
    resp = client.images.generate(
        model=args.model,
        prompt=build_prompt(args),
        n=args.n,
        size=args.size,
        output_format=args.format,
    )
    return save_images(resp, args.out_dir, "t2i", args.format)


def cmd_edit(client: OpenAI, args: argparse.Namespace) -> list[Path]:
    with ExitStack() as stack:
        images = [stack.enter_context(open(p, "rb")) for p in args.image]
        params = {
            "model": args.model,
            "prompt": build_prompt(args),
            "image": images if len(images) > 1 else images[0],
            "n": args.n,
            "output_format": args.format,
        }
        if args.size:
            params["size"] = args.size
        if args.mask:
            params["mask"] = stack.enter_context(open(args.mask, "rb"))
        resp = client.images.edit(**params)
    return save_images(resp, args.out_dir, "edit", args.format)


def add_gen_options(p: argparse.ArgumentParser, size_default: str | None, formats: list[str]) -> None:
    p.add_argument("prompt", help="提示詞")
    p.add_argument("--size", default=size_default, help="圖片尺寸 WIDTHxHEIGHT，建議為 32 的倍數")
    p.add_argument("-n", type=int, default=1, help="產生張數（預設：1）")
    p.add_argument("--format", choices=formats, default="png", help="輸出格式（預設：png）")
    p.add_argument("--steps", type=int, help="取樣步數（覆寫伺服器預設值）")
    p.add_argument("--cfg", type=float, help="CFG scale；> 1 才會啟用 negative prompt")
    p.add_argument("--seed", type=int, help="隨機種子；< 0 代表每次隨機")
    p.add_argument("--sampler", help="取樣器，例如 euler、euler_a、dpm++2m")
    p.add_argument("--negative", help="負面提示詞（需搭配 --cfg 大於 1）")
    p.add_argument("-o", "--out-dir", type=Path, default=Path("outputs"), help="輸出目錄（預設：outputs）")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Qwen-Image 2.1 GGUF 的 OpenAI 相容圖片 API 用戶端")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("OPENAI_BASE_URL", DEFAULT_BASE_URL),
        help=f"API 位址（環境變數 OPENAI_BASE_URL，預設：{DEFAULT_BASE_URL}）",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("OPENAI_API_KEY", "sk-no-key-required"),
        help="API 金鑰；sd-server 不驗證，任意值皆可",
    )
    parser.add_argument("--model", default="sd-cpp-local", help="模型名稱；sd-server 會忽略此欄位")
    parser.add_argument("--timeout", type=float, default=1800, help="請求逾時秒數（預設：1800）")
    sub = parser.add_subparsers(dest="command", required=True)

    generate = sub.add_parser("generate", help="文字生成圖片（/v1/images/generations）")
    add_gen_options(generate, "1024x1024", ["png", "jpeg", "webp"])

    edit = sub.add_parser("edit", help="圖片編輯（/v1/images/edits）")
    # sd-server 的 /v1/images/edits 僅支援 png 與 jpeg
    add_gen_options(edit, None, ["png", "jpeg"])
    edit.add_argument("-i", "--image", action="append", required=True, help="參考圖片，可重複指定多張")
    edit.add_argument("--mask", help="遮罩圖片（選用）")

    sub.add_parser("models", help="列出模型（/v1/models）")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    client = OpenAI(base_url=args.base_url, api_key=args.api_key, timeout=args.timeout, max_retries=0)

    if args.command == "models":
        for m in client.models.list():
            print(m.id)
        return 0

    print(f"→ {args.base_url}  {args.command}: {args.prompt}", file=sys.stderr)
    started = time.monotonic()
    paths = cmd_generate(client, args) if args.command == "generate" else cmd_edit(client, args)
    elapsed = time.monotonic() - started
    if not paths:
        print("伺服器沒有回傳任何圖片", file=sys.stderr)
        return 1
    for path in paths:
        print(path)
    print(f"完成：{len(paths)} 張，耗時 {elapsed:.1f} 秒", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
