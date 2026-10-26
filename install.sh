#!/usr/bin/env bash
# 安装当前非驻留版本；只安装预编译 Python wheel，不在本机编译依赖。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HOME/voice-input"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Qwen MLX 版本需要 Apple Silicon Mac（请使用原生 arm64 终端）。" >&2
  exit 1
fi
command -v brew >/dev/null || { echo "请先安装 Homebrew。" >&2; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
[[ -d /Applications/Hammerspoon.app ]] || brew install --cask hammerspoon
command -v "$PYTHON_BIN" >/dev/null || {
  echo "请先 brew install python@3.11，或设置 PYTHON_BIN 指向 Python 3.11。" >&2
  exit 1
}
"$PYTHON_BIN" -c 'import platform, sys; assert sys.version_info[:2] == (3, 11) and platform.machine() == "arm64", "需要原生 arm64 Python 3.11"'

echo "==> 1/4 创建独立 MLX 环境（原有 SenseVoice 环境保留）"
mkdir -p "$PREFIX/recordings" "$PREFIX/sounds"
chmod 700 "$PREFIX/recordings"
[[ -x "$PREFIX/.venv-mlx/bin/python3" ]] || "$PYTHON_BIN" -m venv "$PREFIX/.venv-mlx"
PY="$PREFIX/.venv-mlx/bin/python3"
"$PY" -c 'import platform, sys; assert sys.version_info[:2] == (3, 11) and platform.machine() == "arm64", "现有 .venv-mlx 不是 arm64 Python 3.11，请手动迁移后重试"'
"$PY" -m pip install --only-binary=:all: -r "$REPO_DIR/requirements-mlx.lock"

echo "==> 2/4 复制引擎和 CC0 提示音"
cp "$REPO_DIR/engine/qwen_engine.py" "$REPO_DIR/engine/transcribe_qwen.py" \
   "$REPO_DIR/engine/transcribe.py" "$PREFIX/"
if [[ "$REPO_DIR" != "$(cd "$PREFIX" && pwd)" ]]; then
  cp "$REPO_DIR/requirements-mlx.lock" "$PREFIX/"
  cp "$REPO_DIR/sounds/"*.wav "$REPO_DIR/sounds/Kenney-License.txt" "$PREFIX/sounds/"
fi

echo "==> 3/4 下载并校验固定版本模型（Qwen 权重约 2.46 GB）"
"$PY" "$REPO_DIR/scripts/download_models.py" --prefix "$PREFIX"

echo "==> 4/4 写入 Hammerspoon 配置"
mkdir -p "$HOME/.hammerspoon"
if [[ -f "$HOME/.hammerspoon/init.lua" ]]; then
  BAK="$HOME/.hammerspoon/init.lua.bak.$(date +%s)"
  cp "$HOME/.hammerspoon/init.lua" "$BAK"
  echo "已备份原配置：$BAK"
fi
cp "$REPO_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
open -a Hammerspoon 2>/dev/null || true

cat <<'TIP'

安装完成：
1. 系统设置 → 隐私与安全性：授权 Hammerspoon 辅助功能及麦克风。
2. Hammerspoon 菜单 → Reload Config；有其他配置时请合并备份。
3. 用 ffmpeg -f avfoundation -list_devices true -i "" 确认音频设备，
   修改 ~/.hammerspoon/init.lua 顶部 AUDIO_DEV（默认 :1，不一定适合所有 Mac）。
4. 点进输入框 → 按住右 Cmd 说话 → 松开后等待识别完成。

录音时预加载模型，松开后整句识别；每段独立进程，完成即退出，不常驻。
TIP
