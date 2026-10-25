-- 语音输入：按住右 Cmd 说话，松开出字
-- 引擎：~/voice-input/ 里的 SenseVoice-Small int8
hs.allowAppleScript(true)  -- 允许远程诊断

local WORK = os.getenv("HOME") .. "/voice-input"
local AUDIO_DEV = ":1"  -- 麦克风索引；换麦克风用 `ffmpeg -f avfoundation -list_devices true -i ""` 查
local RAW = WORK .. "/clip.pcm"  -- 裸 PCM，不需要文件尾，强杀也不损坏
local SND = WORK .. "/sounds"
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local PY = WORK .. "/.venv/bin/python3"
local SCRIPT = WORK .. "/transcribe.py"

-- 预加载提示音，按键零延迟
local sounds = {}
for _, n in ipairs({"start.wav", "stop.wav", "done.wav", "error.wav"}) do
  sounds[n] = hs.sound.getByFile(SND .. "/" .. n)
end
local function play(name)
  if sounds[name] then sounds[name]:play() end
end

local recTask = nil

local function finishTranscribe(code, stdout, stderr)
  local text = stdout and stdout:gsub("%s+$", "") or ""
  if text ~= "" then
    play("done.wav")
    hs.pasteboard.setContents(text)  -- 顺便留一份在剪贴板备用
    hs.eventtap.keyStrokes(text)
  else
    play("error.wav")
    hs.alert.show("没听清，再试一次", 1)
  end
end

local function startRec()
  if recTask then return end  -- 状态就靠这个变量，不可能卡住
  play("start.wav")
  recTask = hs.task.new(FFMPEG, nil, {
    "-hide_banner", "-loglevel", "error",
    "-f", "avfoundation", "-i", AUDIO_DEV,
    "-ac", "1", "-ar", "16000",
    "-f", "s16le", "-y", RAW,
  })
  recTask:start()
end

local function stopAndType()
  if not recTask then return end
  local task = recTask
  recTask = nil
  play("stop.wav")
  task:sendSignal(2)  -- 先礼貌退出
  hs.timer.doAfter(0.5, function()
    pcall(function() task:sendSignal(9) end)  -- 没退就强杀；已退无害
    hs.timer.doAfter(0.15, function()
      local t = hs.task.new(PY, finishTranscribe, {SCRIPT, RAW})
      t:start()
    end)
  end)
end

-- 用事件监听直接盯右 Cmd（键码 54）的按下/抬起，比 hs.hotkey 可靠
keylog = keylog or {}   -- 记录其他修饰键按键，诊断用
local cmdDown = false
keyTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  local code = e:getKeyCode()
  local isDown = e:getFlags()["cmd"] == true
  if code == 54 then  -- 右 Cmd
    if isDown and not cmdDown then
      cmdDown = true
      startRec()
    elseif not isDown and cmdDown then
      cmdDown = false
      stopAndType()
    end
  else
    keylog[#keylog+1] = tostring(code) .. ":" .. tostring(isDown)
  end
  return false  -- 不吞事件，右 Cmd 的其他功能不受影响
end)
keyTap:start()

hs.alert.show("语音输入就绪：按住空格右边的 Cmd 说话", 2)
