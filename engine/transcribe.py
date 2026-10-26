#!/usr/bin/env python3
"""语音输入引擎：把 16k 单声道 s16le 裸 PCM 转成文字（SenseVoice-Small int8）"""
import sys
from pathlib import Path
import numpy as np
import sherpa_onnx

MODEL_DIR = Path(__file__).resolve().parent / "models" / "sense-voice"

def main():
    path = sys.argv[1]
    raw = open(path, "rb").read()
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    # 少于 0.25 秒当没说话，直接退出
    if len(samples) < 16000 * 0.25:
        return
    r = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=f"{MODEL_DIR}/model.int8.onnx",
        tokens=f"{MODEL_DIR}/tokens.txt",
        num_threads=4,
        language="",  # 自动检测中/英/日/韩/粤
        use_itn=True,
    )
    s = r.create_stream()
    s.accept_waveform(16000, samples)
    r.decode_stream(s)
    text = s.result.text.strip()
    if text:
        print(text, end="")

if __name__ == "__main__":
    main()
