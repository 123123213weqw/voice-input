# 按-说-出字：Mac 本地语音输入

按住快捷键说话，松开后文字自动打进当前光标处。全程离线，语音数据不出电脑。

- 引擎：[SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice)（int8 量化，234M 参数）+ [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 推理
- 外壳：Hammerspoon（全局热键 + 模拟键入）+ ffmpeg（麦克风采集）
- 中文/中英混说效果好，支持英/日/韩/粤语自动检测，自带标点

## 实测性能（Apple M5 / 16GB）

| 指标 | 数值 |
|---|---|
| 10 秒语音识别 | 0.12 秒（实时率 0.014） |
| 1 分钟语音识别 | 0.9 秒（实时率 0.017） |
| 冷启动全流程（启动+加载+识别） | 0.7 秒 |
| 空闲内存占用 | **0**（无常驻进程，识别完即退出） |
| 识别瞬间内存 | 峰值约 0.9GB，1 秒内释放 |

## 安装

```bash
git clone https://github.com/123123213weqw/voice-input.git
cd voice-input
bash install.sh
```

安装脚本完成后还有两步手动授权（macOS 安全设计，软件无法代办）：

1. 系统设置 → 隐私与安全性 → **辅助功能** → 打开 Hammerspoon
2. 第一次按住快捷键说话时，在弹窗里允许**麦克风**

## 用法

点到任意输入框 → **按住右 Cmd** 说话 → 松开 → 约 1 秒后出字。

- 说话不足 0.25 秒视为误触，自动忽略
- 识别结果同时存入剪贴板，打错了直接 ⌘V 重贴
- 反馈音：上扬叮 = 开始录音，下行音 = 停止，温暖确认音 = 已出字，低音 = 没听清

## 自定义

**换热键**：编辑 `~/.hammerspoon/init.lua` 里的 `code == 54`（54 = 右 Cmd，键码表见 `hs.keycodes.map`）。

**换麦克风**：脚本默认用索引 `:1`（MacBook 内置麦）。外接麦克风时先查索引再改配置：

```bash
ffmpeg -f avfoundation -list_devices true -i ""   # 看音频设备列表
# 编辑 ~/.hammerspoon/init.lua 顶部 AUDIO_DEV = ":2"
```

**重新生成提示音**：`python3 engine/make_sounds.py sounds/`

## 目录结构

```
hammerspoon/init.lua   # Hammerspoon 配置：热键、录音调度、模拟键入
engine/transcribe.py   # 识别引擎：裸 PCM → 文本
engine/make_sounds.py  # 提示音合成脚本
sounds/*.wav           # 预生成的提示音
install.sh             # 一键安装
```

## 实现备注（踩过的坑）

- ffmpeg 输出裸 PCM（`-f s16le`）而不是 wav：AVFoundation 设备上 SIGINT 优雅退出可能卡住不退，裸流即使强杀也不损坏数据
- 录音结束先 SIGINT、0.5 秒后补 SIGKILL，保证麦克风必然释放，连续按压不出错
- 热键用 `hs.eventtap` 监听 flagsChanged 键码（54），比 `hs.hotkey` 绑定修饰键可靠
- 识别按需启动进程而非常驻服务：冷启动只要 0.7 秒，换来 99% 时间零内存占用

## 许可证

- 本仓库代码：MIT（见 [LICENSE](LICENSE)）
- SenseVoice-Small 模型权重：以官方模型卡标注为准（个人使用无限制，严格商用前请自行核对 [FunASR 模型许可](https://github.com/FunAudioLLM/SenseVoice)）
