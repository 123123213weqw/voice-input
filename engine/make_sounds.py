#!/usr/bin/env python3
"""合成语音输入的四个提示音（木质叮声，自然衰减）"""
import sys, os, wave
import numpy as np

SR = 48000

def note(freq, dur, decay=18.0):
    t = np.linspace(0, dur, int(SR * dur), endpoint=False)
    # 基音 + 一点八度泛音，更像"木质叮"
    return (np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(4 * np.pi * freq * t)) * np.exp(-decay * t)

def seq(*notes):
    total = sum(len(n) for n in notes)
    out = np.zeros(total)
    pos = 0
    for n in notes:
        out[pos:pos + len(n)] += n
        pos += len(n) // 2  # 每个音错半拍进入，听感连贯
    return out

def save(path, sig):
    sig = np.clip(sig, -1, 1)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((sig * 32767 * 0.35).astype(np.int16).tobytes())

def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    save(os.path.join(outdir, "start.wav"), seq(note(880, .12), note(1174.66, .22)))   # A5→D6 上扬：开始
    save(os.path.join(outdir, "done.wav"),  seq(note(880, .1),  note(1318.5, .3)))     # A5→E6 五度：出字成功
    save(os.path.join(outdir, "stop.wav"),  seq(note(1174.66, .12), note(880, .2)))    # 下行：停止
    save(os.path.join(outdir, "error.wav"), note(233, .25, decay=12))                  # 低音短促：没听清
    print(f"4 个提示音已生成到 {outdir}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sounds")
