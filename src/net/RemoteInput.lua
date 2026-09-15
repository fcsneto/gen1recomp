-- Windows-only, loopback-only receiver for a livestream bridge.
--
-- The native DLL owns HTTP parsing on a background thread. Lua never touches
-- sockets: it drains a bounded queue at the fixed-step boundary and uses an
-- independent Input source, so neither a physical keyboard nor a gamepad can
-- be overwritten by remote chat commands.

local RemoteInput = {}

local ACTIONS = {
  up = true, down = true, left = true, right = true,
  a = true, b = true, start = true, select = true,
}
local MAX_COMMANDS_PER_STEP = 16
local STEP_MS = 1000 / 60

local lib
local started = false
local stepNo = 0
local sourceNo = 0
local scheduled = {}

local function exeDir()
  if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
    local base = love.filesystem.getSourceBaseDirectory()
    if type(base) == "string" and base ~= "" then return base end
  end
  if type(arg) == "table" and type(arg[0]) == "string" then
    local dir = arg[0]:match("^(.*)[/\\]")
    if dir and dir ~= "" then return dir end
  end
  return "."
end

local function workingDir()
  if love and love.filesystem and love.filesystem.getWorkingDirectory then
    local cwd = love.filesystem.getWorkingDirectory()
    if type(cwd) == "string" and cwd ~= "" then return cwd end
  end
  return nil
end

local function readable(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

local function isWindows()
  return love and love.system and love.system.getOS
    and love.system.getOS() == "Windows"
end

local function log(level, message)
  local Logger = require("src.core.Logger")
  Logger[level](message)
end

local function loadNative()
  local okFfi, ffi = pcall(require, "ffi")
  if not okFfi or type(ffi) ~= "table" then return nil end
  ffi.cdef[[
    int gen1remote_start(int port, const char *token);
    int gen1remote_next(char *action, int action_max, int *duration_ms);
    void gen1remote_clear(void);
    void gen1remote_stop(void);
    int gen1remote_error(char *buffer, int max);
  ]]

  local base = exeDir()
  local cwd = workingDir()
  -- The first path is the packaged build. The second is the output location
  -- used by scripts/build_windows.ps1, which keeps source-tree testing easy.
  -- LOVE can report its own install directory as the source base when started
  -- with `love .`, so also try the process working directory.
  local candidates = {
    base .. "/gen1remoteinput.dll",
    base .. "/dist/native/win-x64/gen1remoteinput.dll",
  }
  if cwd and cwd ~= base then
    candidates[#candidates + 1] = cwd .. "/gen1remoteinput.dll"
    candidates[#candidates + 1] = cwd .. "/dist/native/win-x64/gen1remoteinput.dll"
  end
  candidates[#candidates + 1] = "gen1remoteinput.dll"
  for _, path in ipairs(candidates) do
    if path == "gen1remoteinput.dll" or readable(path) then
      local ok, loaded = pcall(ffi.load, path)
      if ok then return loaded, ffi end
    end
  end
  return nil, nil, table.concat(candidates, "; ")
end

local function nativeError(ffi)
  local buffer = ffi.new("char[512]")
  if lib and lib.gen1remote_error(buffer, 512) ~= 0 then
    return ffi.string(buffer)
  end
  return nil
end

-- Enable deliberately: POKEPORT_REMOTE_INPUT=1. The token never has a
-- default; an accidentally enabled receiver therefore never listens.
function RemoteInput.start()
  if started then return true end
  if os.getenv("POKEPORT_REMOTE_INPUT") ~= "1" then return false end
  if not isWindows() then
    log("warn", "remote input is Windows-only; receiver was not started")
    return false
  end

  local token = os.getenv("POKEPORT_REMOTE_TOKEN")
  if type(token) ~= "string" or token == "" then
    log("warn", "remote input requires POKEPORT_REMOTE_TOKEN; receiver was not started")
    return false
  end
  local port = tonumber(os.getenv("POKEPORT_REMOTE_PORT")) or 38101
  port = math.floor(port)
  if port < 1024 or port > 65535 then
    log("warn", "remote input port must be between 1024 and 65535")
    return false
  end

  local loaded, ffi, searched = loadNative()
  if not loaded then
    log("warn", "gen1remoteinput.dll was not found; receiver was not started. Searched: "
      .. tostring(searched or "no compatible LuaJIT FFI runtime"))
    return false
  end
  lib = loaded
  local result = lib.gen1remote_start(port, token)
  if result ~= 1 then
    log("warn", "remote input failed to listen on 127.0.0.1:" .. port
      .. ": " .. tostring(nativeError(ffi) or "native start failed"))
    lib = nil
    return false
  end
  started = true
  stepNo, sourceNo, scheduled = 0, 0, {}
  log("info", "remote input listening on 127.0.0.1:" .. port)
  return true
end

local function releaseDue(input)
  local keep = {}
  for _, item in ipairs(scheduled) do
    if item.releaseStep <= stepNo then
      input:sourceRelease(item.action, item.source)
    else
      keep[#keep + 1] = item
    end
  end
  scheduled = keep
end

-- Call before Input:step: a remote edge is then visible to this exact logic
-- frame, matching real controls and the existing mod input seam.
function RemoteInput.step(input)
  if not started or not lib or not input then return end
  stepNo = stepNo + 1
  releaseDue(input)

  local okFfi, ffi = pcall(require, "ffi")
  if not okFfi then return end
  local actionBuf = ffi.new("char[16]")
  local duration = ffi.new("int[1]")
  for _ = 1, MAX_COMMANDS_PER_STEP do
    local result = lib.gen1remote_next(actionBuf, 16, duration)
    if result <= 0 then break end
    local action = ffi.string(actionBuf)
    if ACTIONS[action] then
      sourceNo = sourceNo + 1
      local source = "remote:" .. sourceNo
      input:sourcePress(action, source)
      local holdSteps = math.max(1, math.ceil(tonumber(duration[0]) / STEP_MS))
      scheduled[#scheduled + 1] = {
        action = action, source = source, releaseStep = stepNo + holdSteps,
      }
    end
  end
end

-- Lifecycle resets intentionally discard commands that arrived while the
-- window was hidden or unfocused; resuming must never replay an old chat.
function RemoteInput.reset(input)
  if input then
    for _, item in ipairs(scheduled) do
      input:sourceRelease(item.action, item.source)
    end
  end
  scheduled = {}
  if started and lib then lib.gen1remote_clear() end
end

function RemoteInput.stop(input)
  RemoteInput.reset(input)
  if lib then pcall(function() lib.gen1remote_stop() end) end
  lib, started = nil, false
  stepNo, sourceNo = 0, 0
end

function RemoteInput.isStarted()
  return started
end

require("src.core.SessionLifecycle").registerProcessShutdown(function()
  RemoteInput.stop()
end)

return RemoteInput
