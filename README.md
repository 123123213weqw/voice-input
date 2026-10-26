# 按-说-出字：Mac 本地语音输入

点到输入框 → **按住右 Cmd** 说话 → 松开 → 整句识别后自动输入。

当前默认引擎：**Qwen3-ASR-1.7B-8bit + MLX / Metal**，面向 Apple Silicon Mac。模型下载完成后，录音和推理均在本地进行。

## 当前版本的逻辑

```text
按住右 Cmd ─┬─ ffmpeg 采集本次 UUID 的独立录音
            └─ Python 独立进程预加载 Qwen 模型
松开 ── 等录音进程退出 ── 写入 ready 标记
     ── Silero VAD 检查有效人声 ── Qwen 整句识别
     ── 校验会话编号 ── 剪贴板 + 模拟键入 ── 进程退出
```

- **不常驻模型**：每段录音独立加载，录音期间提前加载以重叠等待时间；结果返回后进程退出。Hammerspoon 本身仍作为快捷键外壳运行。
- **不是实时流式出字**：只在松开后识别完整录音；不跨录音传递上一句、草稿或对话历史。
- **空录音不再重复上一句**：每次新 UUID 文件、录音完成屏障、VAD 门控和响应会话校验；误触、无有效人声、异常或迟到响应均不输入文字。
- 只在剪贴板仍属于上次语音结果时清理旧文字，不清空用户另外复制的内容。成功结果仍可按 ⌘V 再粘贴。
- 停止录音使用 `hs.task:interrupt()`，必要时只结束本次持有的 PID；不使用不存在的 `sendSignal()`，不全局杀进程。
- 提示音使用用户选定的 **Kenney Interface Sounds / drop_002**，四个阶段均为同一款轻水滴声，已统一音量；随附 CC0 许可。
- **未启用实验 Metal 补丁**：定制内核没有稳定提升整段识别速度，当前仍用 MLX 默认算子。也没有模型常驻服务。

## 安装 / 更新

已验证环境：Apple M5、16 GB、macOS 26.5、原生 arm64 Python 3.11。
其他 Apple Silicon 机型尚未逐一验收；Intel Mac 不适用此 MLX 安装流程。

先安装 [Homebrew](https://brew.sh/)，然后：

```bash
brew install python@3.11
git clone https://github.com/123123213weqw/voice-input.git
cd voice-input
bash install.sh
```

已有仓库可执行 `git pull --ff-only` 后重新运行安装脚本。脚本会：

1. 检查 ffmpeg、Hammerspoon，创建 `~/voice-input/.venv-mlx`，安装固定版本的预编译 wheel，不在本机编译依赖。
2. 复制引擎和提示音到 `~/voice-input/`，保留原有 SenseVoice 环境及模型。
3. 从官方 HTTPS 源下载固定 revision 的 Qwen 文件及 Silero VAD，并逐文件校验 SHA256；匹配的本地文件跳过下载。Qwen 权重约 **2.46 GB**，请预留环境和下载空间。
4. 备份原 `~/.hammerspoon/init.lua` 后写入当前配置。**有其他 Hammerspoon 功能时，请从备份合并配置。**

手动完成：

- 系统设置 → 隐私与安全性 → **辅助功能**：允许 Hammerspoon 模拟键入。
- 首次录音允许**麦克风**，必要时在隐私设置中检查实际录音宿主的授权。
- Hammerspoon 菜单 → **Reload Config**。
- 确认麦克风索引；默认 `:1` 只是本机配置，不保证对应其他 Mac 的内置麦克风：

```bash
ffmpeg -f avfoundation -list_devices true -i ""
# 查看 AVFoundation audio devices，随后修改 ~/.hammerspoon/init.lua 顶部 AUDIO_DEV
```

配置顶部还可修改 `WORK`、`FFMPEG`、`PY`、`SND`。默认 ffmpeg 路径为 `/opt/homebrew/bin/ffmpeg`。

### 模型来源与复现

- [mlx-community/Qwen3-ASR-1.7B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)，revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`。
- [sherpa-onnx 发布的 Silero VAD](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx)。
- 完整文件清单、下载地址与 SHA256：[`scripts/model-manifest.json`](scripts/model-manifest.json)。
- 实测环境依赖：[`requirements-mlx.lock`](requirements-mlx.lock)。MLX 0.32.4、mlx-audio 0.6.1。

仅校验现有模型，不联网下载：

```bash
~/voice-input/.venv-mlx/bin/python3 scripts/download_models.py --verify-only
```

## 用法与排障

- 按住右 Cmd 开始，松开停止；等待本段识别完成后再开始下一段。
- 不足 0.25 秒的录音忽略；VAD 没检测到有效人声时提示但不输入。
- 加载较慢时松手后仍需等待，不应连续快按触发新识别。
- 有提示音但无文字：先确认麦克风索引和授权，再查看 Hammerspoon Console 中的错误；安静说话可能受 VAD 门限影响。
- 有文字进入剪贴板但未打进输入框：检查辅助功能权限，以及当前输入框是否允许模拟键入。
- 临时录音只写入 `~/voice-input/recordings/`，正常完成、取消或超时后删除；异常崩溃可能留下文件，可在停止录音后手动清理。

命令行诊断（已有 16 kHz、单声道、16-bit little-endian 裸 PCM）：

```bash
~/voice-input/.venv-mlx/bin/python3 ~/voice-input/transcribe_qwen.py /path/to/audio.pcm --metrics
```

该命令只输出识别文字，不模拟键入；无有效人声时 stdout 为空。

## 测试

```bash
~/voice-input/.venv-mlx/bin/python3 -m unittest discover -s tests -v
```

Hammerspoon Console 里运行（换成当前仓库的绝对路径）：

```lua
dofile("/absolute/path/to/voice-input/tests/test_state.lua")
```

Lua 状态机测试使用隔离 mock，不操作真实麦克风、键盘或剪贴板。覆盖快速双击、空录音、迟到响应、会话串线、剪贴板归属及失败清理。

## 目录结构

```text
hammerspoon/init.lua         # 当前部署的非驻留快捷键控制器
engine/qwen_engine.py       # 本地 MLX 推理 + Silero VAD
engine/transcribe_qwen.py   # UUID 会话协议 / 录音时预加载 / 命令行入口
engine/transcribe.py        # 保留的 SenseVoice 旧版命令行入口
engine/make_sounds.py       # 旧合成音工具，默认不运行
scripts/download_models.py # 下载及 SHA256 校验工具
scripts/model-manifest.json
sounds/                    # 当前 CC0 水滴音及原许可
requirements-mlx.lock
install.sh
tests/
```

旧 `transcribe.py` 仅供已有 SenseVoice 模型的用户手动调用；默认安装不下载旧模型，也不自动切换引擎。其模型路径按安装后的脚本目录解析。

## 许可证

- 仓库代码：MIT，见 [LICENSE](LICENSE)。
- 当前提示音：Kenney Interface Sounds，CC0，见 [原许可](sounds/Kenney-License.txt) 和 [素材页面](https://kenney.nl/assets/interface-sounds)。
- Qwen、MLX、VAD 等第三方依赖与模型遵循各自上游许可；模型权重不提交到本仓库。
