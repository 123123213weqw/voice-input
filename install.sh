#!/usr/bin/env bash
# 一键安装：Mac 本地语音输入（按住说话、松开出字）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HOME/voice-input"
MODEL_ID="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODEL_DIR="$PREFIX/models/sense-voice"

echo "==> 1/5 检查依赖"
command -v ffmpeg >/dev/null 2>&1 || brew install ffmpeg
[ -d /Applications/Hammerspoon.app ] || brew install --cask hammerspoon
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3（建议 brew install python@3.11）"; exit 1; }

echo "==> 2/5 安装识别引擎（sherpa-onnx + numpy）"
mkdir -p "$MODEL_DIR"
[ -d "$PREFIX/.venv" ] || python3 -m venv "$PREFIX/.venv"
"$PREFIX/.venv/bin/pip" install -q sherpa-onnx numpy
cp "$REPO_DIR/engine/transcribe.py" "$PREFIX/transcribe.py"

echo "==> 3/5 复制提示音"
rm -rf "$PREFIX/sounds"
cp -r "$REPO_DIR/sounds" "$PREFIX/sounds"

echo "==> 4/5 下载模型（约 230MB，国内镜像优先，失败自动切官方源）"
dl() { curl -fL --connect-timeout 15 --progress-bar -o "$2" "$1"; }
for f in model.int8.onnx tokens.txt; do
  [ -s "$MODEL_DIR/$f" ] && { echo "    $f 已存在，跳过"; continue; }
  dl "https://hf-mirror.com/$MODEL_ID/resolve/main/$f" "$MODEL_DIR/$f" \
    || dl "https://huggingface.co/$MODEL_ID/resolve/main/$f" "$MODEL_DIR/$f"
done

echo "==> 5/5 写入 Hammerspoon 配置"
mkdir -p "$HOME/.hammerspoon"
if [ -f "$HOME/.hammerspoon/init.lua" ]; then
  BAK="$HOME/.hammerspoon/init.lua.bak.$(date +%s)"
  cp "$HOME/.hammerspoon/init.lua" "$BAK"
  echo "    已备份原配置到 $BAK"
fi
cp "$REPO_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
open -a Hammerspoon 2>/dev/null || true

cat <<'TIP'

✅ 安装完成！最后两步授权是 macOS 安全设计，只能你亲手点：

  1. 系统设置 → 隐私与安全性 → 辅助功能 → 打开 Hammerspoon 开关
     （若列表没有，点 + 添加 /Applications/Hammerspoon.app）
  2. 第一次按住右 Cmd 说话时，在弹窗里允许麦克风

用法：点到任意输入框 → 按住右 Cmd 说话 → 松开 → 约 1 秒后文字自动打进光标处

TIP
