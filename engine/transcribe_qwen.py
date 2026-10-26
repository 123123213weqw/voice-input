#!/usr/bin/env python3
"""本地语音输入：独立录音会话、录音时预加载、无有效人声则不生成文字。"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time
import uuid

from qwen_engine import QwenEngine, ROOT, has_speech, read_pcm


def recognize(samples, language=None):
    """保留旧的命令行调用方式；没有人声时不加载大模型。"""
    if not has_speech(samples):
        return "", {"status": "no_speech"}
    return QwenEngine().recognize(samples, language)


def validate_session(pcm: Path, ready: Path, request_id: str):
    if str(uuid.UUID(request_id)) != request_id:
        raise ValueError("录音会话编号无效")
    recordings = (ROOT / "recordings").resolve()
    if pcm.parent.resolve() != recordings or pcm.name != request_id + ".pcm":
        raise ValueError("录音文件不属于本次独立会话")
    if ready.parent.resolve() != recordings or ready.name != request_id + ".ready":
        raise ValueError("录音结束标记不属于本次独立会话")
    if pcm.is_symlink() or ready.is_symlink():
        raise ValueError("录音会话文件不能是符号链接")


def wait_for_recording(ready: Path, request_id: str, parent_pid: int, timeout=600):
    deadline = time.monotonic() + timeout
    while not ready.exists():
        if os.getppid() != parent_pid:
            raise RuntimeError("录音宿主已退出")
        if time.monotonic() >= deadline:
            raise TimeoutError("等待本次录音结束超时")
        time.sleep(0.02)
    request = json.loads(ready.read_text())
    if request.get("request_id") != request_id or request.get("action") != "transcribe":
        raise ValueError("录音结束标记与当前会话不匹配")


def run_preloaded(args) -> int:
    validate_session(args.pcm, args.ready_file, args.request_id)
    parent_pid = os.getppid()
    payload = {"protocol": 1, "request_id": args.request_id, "status": "error", "text": ""}
    code = 0
    try:
        # 一按键就加载；录音结束标记出现前绝不读取/识别音频文件。
        engine = QwenEngine()
        print(json.dumps({"event": "ready", "request_id": args.request_id,
                          "load_seconds": round(engine.load_seconds, 3)}), file=sys.stderr, flush=True)
        wait_for_recording(args.ready_file, args.request_id, parent_pid)
        started = time.perf_counter()
        samples = read_pcm(args.pcm)
        if not has_speech(samples):
            payload["status"] = "no_speech"
        else:
            text, metrics = engine.recognize(samples, None if args.language == "auto" else args.language)
            payload.update(status="ok" if text else "no_speech", text=text, metrics=metrics)
        payload["after_ready_seconds"] = round(time.perf_counter() - started, 3)
    except Exception as exc:
        print(f"[qwen-mlx] {type(exc).__name__}: {exc}", file=sys.stderr)
        code = 1
    finally:
        # 只清理已验证属于本次 UUID 的文件；不会读写旧的 clip.pcm。
        args.pcm.unlink(missing_ok=True)
        args.ready_file.unlink(missing_ok=True)
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcm", type=Path)
    parser.add_argument("--language", default="auto")
    parser.add_argument("--metrics", action="store_true")
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--request-id")
    args = parser.parse_args()
    try:
        if args.ready_file is not None:
            if not args.request_id:
                raise ValueError("预加载模式必须提供 request-id")
            return run_preloaded(args)
        text, metrics = recognize(read_pcm(args.pcm), None if args.language == "auto" else args.language)
        if args.metrics:
            print(json.dumps(metrics, ensure_ascii=False), file=sys.stderr)
        if text:
            print(text, end="")
        return 0
    except Exception as exc:
        print(f"[qwen-mlx] {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
