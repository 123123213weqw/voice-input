-- 实际配置在隔离 mock 中运行，不使用真实麦克风、剪贴板或键盘。
local source = debug.getinfo(1, "S").source:sub(2)
local config = assert(source:match("^(.*[/\\])")) .. "../hammerspoon/init.lua"
local json = hs.json
local results = {}

local function setup()
  local state = {tasks = {}, files = {}, typed = {}, alerts = {}, timers = {}, count = 1, serial = 0}
  local mock = {
    allowAppleScript = function() end,
    sound = {getByFile = function() return {play = function() end} end},
    alert = {show = function(msg) table.insert(state.alerts, msg) end},
    host = {uuid = function() state.serial = state.serial + 1; return "session-" .. state.serial end},
    fs = {mkdir = function() return true end}, json = json, task = {}, timer = {},
    eventtap = {event = {types = {flagsChanged = 1}}}, pasteboard = {},
  }
  mock.fs.attributes = function(path)
    local x = state.files[path]
    return x and {mode = "file", size = type(x) == "number" and x or #x} or nil
  end
  mock.pasteboard.setContents = function(text) state.clipboard = text; state.count = state.count + 1 end
  mock.pasteboard.changeCount = function() return state.count end
  mock.pasteboard.clearContents = function() state.clipboard = nil; state.count = state.count + 1 end
  mock.eventtap.keyStrokes = function(text) table.insert(state.typed, text) end
  mock.eventtap.new = function(_, callback)
    state.listener = callback
    return {start = function() end, isEnabled = function() return true end}
  end
  mock.timer.doAfter = function(delay, callback)
    local timer = {delay = delay, callback = callback}
    function timer:stop() self.stopped = true end
    table.insert(state.timers, timer)
    return timer
  end
  mock.task.new = function(path, callback, args)
    local task = {path = path, callback = callback, args = args, running = false}
    function task:start() self.running = state.failPath ~= self.path; return self.running and self or false end
    function task:isRunning() return self.running end
    function task:interrupt() self.interrupted = true end
    function task:pid() return 1000 end
    function task:complete(code, out, err)
      self.running = false
      if self.callback then self.callback(code or 0, out or "", err or "") end
    end
    table.insert(state.tasks, task)
    return task
  end
  local mockOs = setmetatable({
    remove = function(path) state.files[path] = nil; return true end,
    rename = function(a, b) state.files[b] = state.files[a]; state.files[a] = nil; return true end,
  }, {__index = os})
  local mockIo = {open = function(path)
    return {write = function(self, content) state.files[path] = content; return self end,
      close = function() return true end}
  end}
  state.env = setmetatable({hs = mock, os = mockOs, io = mockIo, print = function() end}, {__index = _G})
  assert(loadfile(config, "t", state.env))()
  state.controller = state.env.voiceInputController
  function state:key(down)
    self.listener({getKeyCode = function() return 54 end, getFlags = function() return {cmd = down} end})
  end
  function state:begin(size)
    self:key(true)
    local s = assert(self.controller.active)
    if size then self.files[s.raw] = size end
    return s
  end
  function state:release(s)
    self:key(false)
    s.recorder:complete(255)
  end
  function state:result(s, status, text, id)
    s.worker:complete(0, json.encode({protocol = 1, request_id = id or s.id, status = status, text = text or ""}))
  end
  return state
end

local s = setup()
local a = s:begin(32000)
assert(a.recorder.running and a.worker.running and #s.tasks == 2, "预加载必须在录音期间启动")
assert(s.files[a.ready] == nil, "录音未结束不能触发识别")
s:release(a)
assert(a.phase == "recognizing" and s.files[a.ready] and a.recorder.interrupted)
s:result(a, "ok", "上一句")
assert(s.typed[1] == "上一句" and s.clipboard == "上一句")
s:result(a, "ok", "上一句")
assert(#s.typed == 1, "重复回调不能重复输入")
table.insert(results, "PASS: model preloads while recording; final audio gate; exactly-once typing")

local b = s:begin(0)
s:key(false)
s:key(true); s:key(false) -- 连续快按第二次，第一段尚在收尾时不创建新录音。
assert(s.controller.active == b)
b.recorder:complete(255)
assert(s.controller.active == nil and #s.typed == 1 and s.clipboard == nil)
assert(s.files[b.ready] == nil)
s:result(b, "ok", "上一句") -- 被取消进程晚到的结果也必须丢弃。
assert(#s.typed == 1)
table.insert(results, "PASS: rapid double tap + empty capture never repeats previous text")

s = setup()
a = s:begin(32000); s:release(a); s:result(a, "ok", "上一句")
b = s:begin(32000); s:release(b); s:result(b, "no_speech", "上一句")
assert(#s.typed == 1 and s.clipboard == nil, "no_speech 不得使用响应内的旧文字")
table.insert(results, "PASS: no_speech ignores text and clears only the prior voice-owned clipboard")

a = s:begin(32000); s:release(a); s:result(a, "ok", "语音结果")
s.clipboard = "用户另外复制的内容"; s.count = s.count + 1
b = s:begin(32000); s:release(b); s:result(b, "no_speech")
assert(s.clipboard == "用户另外复制的内容")
table.insert(results, "PASS: unrelated user clipboard content is preserved")

s = setup()
s.files[os.getenv("HOME") .. "/voice-input/clip.pcm"] = 999999 -- 留着上一条旧录音。
a = s:begin(nil); s:release(a)
assert(s.controller.active == nil and #s.typed == 0 and not s.files[a.ready])
assert(s.files[os.getenv("HOME") .. "/voice-input/clip.pcm"] == 999999)
table.insert(results, "PASS: absent new recording cannot fall back to legacy clip.pcm")

a = s:begin(32000); s:release(a); s:result(a, "ok", "旧响应", "wrong-session")
assert(#s.typed == 0 and s.controller.active == nil)
b = s:begin(32000); s:release(b); s:result(a, "ok", "迟到的旧响应")
assert(s.controller.active == b and #s.typed == 0)
s:result(b, "ok", "新响应"); assert(s.typed[1] == "新响应")
table.insert(results, "PASS: wrong-session and stale callbacks cannot type into a newer request")

s = setup()
a = s:begin(32000); s:release(a); s:result(a, "ok", "重复说的同一句")
b = s:begin(32000); s:release(b); s:result(b, "ok", "重复说的同一句")
assert(#s.typed == 2, "不能用文字去重误伤用户真正重复说的话")
table.insert(results, "PASS: legitimate repeated speech remains allowed")

s = setup()
s.failPath = os.getenv("HOME") .. "/voice-input/.venv-mlx/bin/python3"
s:key(true); s:key(false)
assert(s.controller.active == nil and #s.typed == 0)
s.failPath = nil
a = s:begin(32000); s:release(a)
a.worker:complete(1, "上一句", "test failure")
assert(#s.typed == 0 and s.controller.active == nil)
table.insert(results, "PASS: preload and decode failures release state without typing stdout")

return table.concat(results, "\n")
