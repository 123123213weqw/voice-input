-- 按住右 Cmd：录音与 Qwen 1.7B MLX 加载并行；松手后只识别本次独立录音。
hs.allowAppleScript(true)

local WORK = os.getenv("HOME") .. "/voice-input"
local AUDIO_DEV = ":1"
local RECORDINGS = WORK .. "/recordings"
local SND = WORK .. "/sounds"
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local PY = WORK .. "/.venv-mlx/bin/python3"
local SCRIPT = WORK .. "/transcribe_qwen.py"
hs.fs.mkdir(RECORDINGS)

local sounds = {}
for _, name in ipairs({"start.wav", "stop.wav", "done.wav", "error.wav"}) do
  sounds[name] = hs.sound.getByFile(SND .. "/" .. name)
end
local function play(name)
  if sounds[name] then sounds[name]:play() end
end

local controller = {active = nil, killers = {}, lastClipboardChange = nil}
voiceInputController = controller

local function killOwnedTask(task)
  if not task or not task:isRunning() then return end
  -- 本次请求被取消时无需保留音频；只结束我们持有的具体 PID。
  local killer
  killer = hs.task.new("/bin/kill", function() controller.killers[killer] = nil end,
    {"-KILL", tostring(task:pid())})
  if killer then
    controller.killers[killer] = true
    if not killer:start() then controller.killers[killer] = nil end
  end
end

local function clearPreviousVoiceClipboard()
  -- 仅清理仍由上次语音输入持有的剪贴板，不动用户另外复制的内容。
  if controller.lastClipboardChange and
      hs.pasteboard.changeCount() == controller.lastClipboardChange then
    hs.pasteboard.clearContents()
  end
  controller.lastClipboardChange = nil
end

local function finish(session, status, text, detail)
  if controller.active ~= session or session.finished then return end
  session.finished = true
  controller.active = nil
  if session.stopTimer then session.stopTimer:stop() end
  if session.timeout then session.timeout:stop() end
  killOwnedTask(session.recorder)
  killOwnedTask(session.worker)
  os.remove(session.raw)
  os.remove(session.ready)
  os.remove(session.ready .. ".tmp")
  if status == "ok" and text and text:match("%S") then
    hs.pasteboard.setContents(text)
    controller.lastClipboardChange = hs.pasteboard.changeCount()
    play("done.wav")
    hs.eventtap.keyStrokes(text)
  else
    clearPreviousVoiceClipboard()
    play("error.wav")
    if status == "no_speech" then
      hs.alert.show("未检测到有效人声，没有输入文字", 1)
    else
      print("[voice-input] " .. tostring(detail or "录音/识别失败"))
      hs.alert.show("语音输入失败，本次没有输入文字", 2)
    end
  end
end

local function workerFinished(session, code, stdout, stderr)
  if controller.active ~= session or session.finished then return end
  if code ~= 0 then
    finish(session, "error", nil, stderr)
    return
  end
  local ok, result = pcall(hs.json.decode, stdout or "")
  if not ok or type(result) ~= "table" or result.protocol ~= 1 or
      result.request_id ~= session.id or session.phase ~= "recognizing" then
    finish(session, "error", nil, "识别响应不属于当前录音，已丢弃")
    return
  end
  if result.status == "no_speech" then
    finish(session, "no_speech")
  elseif result.status == "ok" and type(result.text) == "string" then
    finish(session, result.text:match("%S") and "ok" or "no_speech", result.text)
  else
    finish(session, "error", nil, "识别进程没有返回有效的新结果")
  end
end

local function recordingFinished(session, code, stdout, stderr)
  if controller.active ~= session or session.finished then return end
  if session.stopTimer then session.stopTimer:stop(); session.stopTimer = nil end
  if session.phase ~= "stopping" or
      (code ~= 0 and code ~= 255 and code ~= 9 and code ~= 2) then
    finish(session, "error", nil, stderr ~= "" and stderr or "麦克风录音意外结束")
    return
  end
  -- 每次都是新 UUID 路径；没有新文件就直接结束，绝不读取旧的 clip.pcm。
  local attributes = hs.fs.attributes(session.raw)
  if not attributes or attributes.mode ~= "file" or attributes.size < 8000 then
    finish(session, "no_speech")
    return
  end
  if attributes.size % 2 ~= 0 then
    finish(session, "error", nil, "本次录音文件不完整")
    return
  end
  local file, err = io.open(session.ready .. ".tmp", "w")
  if not file then finish(session, "error", nil, err); return end
  local written, writeError = file:write(hs.json.encode({request_id = session.id, action = "transcribe"}))
  file:close()
  if not written then finish(session, "error", nil, writeError); return end
  session.phase = "recognizing"
  local renamed, renameError = os.rename(session.ready .. ".tmp", session.ready)
  if not renamed then finish(session, "error", nil, renameError); return end
  session.timeout = hs.timer.doAfter(90, function()
    finish(session, "error", nil, "本次语音识别超时")
  end)
end

local function startRec()
  if controller.active then
    hs.alert.show("上一段正在处理，请稍候", 1)
    return
  end
  local id = hs.host.uuid():lower()
  local session = {id = id, raw = RECORDINGS .. "/" .. id .. ".pcm",
    ready = RECORDINGS .. "/" .. id .. ".ready", phase = "recording"}
  controller.active = session
  play("start.wav")
  session.recorder = hs.task.new(FFMPEG, function(code, stdout, stderr)
    recordingFinished(session, code, stdout, stderr)
  end, {"-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", AUDIO_DEV,
    "-ac", "1", "-ar", "16000", "-f", "s16le", "-n", session.raw})
  if not session.recorder or not session.recorder:start() then
    finish(session, "error", nil, "无法启动麦克风录音")
    return
  end
  -- 与录音同时启动模型；只有录音进程退出并写好 ready 标记后才开始 generate。
  session.worker = hs.task.new(PY, function(code, stdout, stderr)
    workerFinished(session, code, stdout, stderr)
  end, {SCRIPT, session.raw, "--ready-file", session.ready, "--request-id", session.id})
  if not session.worker or not session.worker:start() then
    finish(session, "error", nil, "无法启动模型预加载进程")
  end
end

local function stopAndType()
  local session = controller.active
  if not session or session.phase ~= "recording" then return end
  session.phase = "stopping"
  play("stop.wav")
  session.recorder:interrupt()
  session.stopTimer = hs.timer.doAfter(0.5, function()
    if controller.active == session then killOwnedTask(session.recorder) end
  end)
end

controller.status = function()
  return controller.active and controller.active.phase or "idle"
end
controller.cancel = function()
  if controller.active then finish(controller.active, "error", nil, "已取消本次录音") end
end
hs.shutdownCallback = function()
  local session = controller.active
  if not session then return end
  session.finished = true
  if session.stopTimer then session.stopTimer:stop() end
  if session.timeout then session.timeout:stop() end
  killOwnedTask(session.recorder)
  killOwnedTask(session.worker)
  os.remove(session.raw)
  os.remove(session.ready)
  os.remove(session.ready .. ".tmp")
end

local cmdDown = false
keyTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
  if event:getKeyCode() ~= 54 then return false end
  local down = event:getFlags()["cmd"] == true
  if down and not cmdDown then
    cmdDown = true
    startRec()
  elseif not down and cmdDown then
    cmdDown = false
    stopAndType()
  end
  return false
end)
keyTap:start()
hs.alert.show("语音输入就绪：Qwen 录音时预加载，空录音不输入", 2)
