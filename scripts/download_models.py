#!/usr/bin/env python3
"""下载固定 revision 的 Qwen MLX 和 Silero VAD；推理阶段不访问网络。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MANIFEST = Path(__file__).with_name("model-manifest.json")


def matches(path: Path, expected: str) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == expected


def install_models(prefix: Path, verify_only=False) -> None:
    manifest = json.loads(MANIFEST.read_text())
    for item in manifest["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("模型清单包含非法路径")
        target = prefix / "models" / relative
        if matches(target, item["sha256"]):
            print(f"OK {relative}", flush=True)
            continue
        if verify_only:
            raise ValueError(f"模型缺失或 SHA256 不匹配：{target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + ".download")
        print(f"下载 {relative}", flush=True)
        try:
            # TLS 校验保持默认开启；只从清单中的官方 HTTPS 源下载。
            subprocess.run([
                "curl", "--fail", "--location", "--proto", "=https",
                "--proto-redir", "=https", "--retry", "3", "--retry-delay", "2",
                "--connect-timeout", "20", "--max-time", "1800",
                "--output", str(temporary), item["url"],
            ], check=True)
            if not matches(temporary, item["sha256"]):
                raise ValueError(f"下载文件 SHA256 不匹配：{relative}")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / "voice-input")
    parser.add_argument("--verify-only", action="store_true", help="只校验本地文件，不下载")
    args = parser.parse_args()
    install_models(args.prefix.expanduser().resolve(), args.verify_only)


if __name__ == "__main__":
    main()
