-- MacLib macro UI for Anime Adventures (v3 — full feature build).
-- Core: __namecall hook recorder, money-filtered replay, unit linking.
-- Tabs: Macro | Auto Farm | Units | Dungeon | Settings

local ok_maclib, MacLib = pcall(function()
    return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok_maclib or not MacLib then
    warn("[Macro UI] MacLib failed to load: " .. tostring(MacLib))
    return
end


local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Config = {
    MaxActions = 5000,
    MaxDuration = 3600,
    VerifyWindow = 1.5,
    ReplayVerifyWindow = 4,
    RetryInterval = 0.5,
    RetryTimeout = 60,
    MaxTrackedValues = 200,
    SpawnRemote = "spawn_unit",
    UnitMatchWindow = 3,
    UnitMatchDistance = 6,
    Folder = "AAMacro",
    ListLines = 14,
    ScanMaxLines = 300,
    ScreenFill = 0.9,
    Keybind = Enum.KeyCode.LeftControl,
}
local MacroFolder = Config.Folder .. "/macros"
local ConfigFile = Config.Folder .. "/config.json"

local State = {
    recording = false,
    finalizing = false,
    finalizeAt = 0,
    replaying = false,
    retryPlacements = true,
    autoPlay = false,
    showAllMacros = false,
    actions = {},
    startedAt = 0,
    startOffset = nil,
    duration = 0,
    replayIndex = 0,
    replayLog = {},
    replayStartedAt = 0,
    macroName = "",
    stage = nil,
    tracked = {},
    snapshot = {},
    connections = {},
}

-- Auto Farm state
local AutoFarm = {
    autoReplay = false,
    autoNextStage = false,
    autoLeave = false,
    leaveAtWave = 0,
    speedMultiplier = 1,
    autoSell = false,
    sellAtWave = 0,
    sellUnitName = "",
    running = false,
}

-- Unit AI state
local UnitAI = {
    autoAbilities = false,
    abilityCooldown = 2,
    autoBuff = false,
    buffInterval = 2,
    minUnitsForBuff = 4,
}

-- Dungeon Bot state
local DungeonBot = {
    enabled = false,
    roomPriority = { "SHOP", "HOARD", "CHEST", "SHRINE", "BATTLE" },
    shrineEnabled = false,
    autoBuyBuffs = true,
    buffPriority = { "DMG", "MAGIC", "TRUE_DMG" },
    discoveryMode = false,
    remoteMap = {},
    currentDepth = 0,
    dungeonActive = false,
    statusText = "Idle",
}

-- Tools state
local Tools = {
    antiAfk = false,
    antiAfkConnection = nil,
    sessionStartedAt = os.clock(),
    totalReplays = 0,
    totalFails = 0,
    totalActions = 0,
}

-- Webhook state
local Webhook = {
    url = "",
    notifyComplete = false,
    notifyFail = false,
}

local Window
local statusParagraph, actionsParagraph, autoStatusParagraph, unitStatusParagraph
local dungeonStatusParagraph, statsText
local recordToggle, playToggle, savedDropdown, nameInput, pasteInput
local autoReplayToggle, autoNextToggle, autoLeaveToggle, autoSellToggle
local autoAbilitiesToggle, autoBuffToggle, antiAfkToggle
local Controls = {}
local applyRuntimeFeatures
local oldNamecall
local hookInstalled = false
local syncing = false

local function notify(message)
    Window:Notify({ Title = "Macro UI", Description = tostring(message), Lifetime = 5 })
end

local function formatDuration(seconds)
    seconds = math.max(0, seconds or 0)
    local whole = math.floor(seconds)
    return string.format("%02d:%02d.%d", math.floor(whole / 60), whole % 60, math.floor((seconds - whole) * 10))
end

local function setToggle(toggle, value)
    if not toggle or toggle:GetState() == value then return end
    syncing = true
    toggle:UpdateState(value)
    syncing = false
end

local function cleanName(name)
    if type(name) ~= "string" then return nil end
    local trimmed = name:match("^%s*(.-)%s*$")
    if #trimmed < 1 or #trimmed > 40 or not trimmed:match("^[%w _%-#'.!&]+$") then return nil end
    return trimmed
end

local function clip(s, n)
    if #s > n then return s:sub(1, n - 1) .. "~" end
    return s
end

-- Config persistence (auto farm / webhook / dungeon settings)
local function hasFileApi()
    return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
        and type(isfolder) == "function" and type(makefolder) == "function"
end

local function ensureFolder(path)
    local built = ""
    for segment in path:gmatch("[^/]+") do
        built = built == "" and segment or (built .. "/" .. segment)
        if not isfolder(built) then makefolder(built) end
    end
end

local ProfileFolder = Config.Folder .. "/profiles"
local Profile = { name = "" }
-- false until the UI is built and saved values are restored; control callbacks
-- that fire during construction must not overwrite the file with defaults.
local configReady = false
local pendingToggles = {}

local function buildConfigData()
    return {
        profile = Profile.name,
        webhook = { url = Webhook.url, notifyComplete = Webhook.notifyComplete, notifyFail = Webhook.notifyFail },
        dungeon = { remoteMap = DungeonBot.remoteMap, shrineEnabled = DungeonBot.shrineEnabled, autoBuyBuffs = DungeonBot.autoBuyBuffs },
        unitAI = {
            autoAbilities = UnitAI.autoAbilities,
            abilityCooldown = UnitAI.abilityCooldown,
            autoBuff = UnitAI.autoBuff,
            buffInterval = UnitAI.buffInterval,
            minUnitsForBuff = UnitAI.minUnitsForBuff,
        },
        autoFarm = {
            autoReplay = AutoFarm.autoReplay,
            autoNextStage = AutoFarm.autoNextStage,
            autoLeave = AutoFarm.autoLeave,
            leaveAtWave = AutoFarm.leaveAtWave,
            speedMultiplier = AutoFarm.speedMultiplier,
            autoSell = AutoFarm.autoSell,
            sellAtWave = AutoFarm.sellAtWave,
            sellUnitName = AutoFarm.sellUnitName,
        },
        macro = {
            retryPlacements = State.retryPlacements,
            autoPlay = State.autoPlay,
            showAllMacros = State.showAllMacros,
            lastMacro = State.macroName,
        },
        tools = { antiAfk = Tools.antiAfk },
    }
end

local function pick(value, kind, fallback)
    if type(value) == kind then return value end
    return fallback
end

local function applyConfigData(data)
    if type(data) ~= "table" then return end
    if type(data.profile) == "string" then Profile.name = data.profile end
    local w = data.webhook or {}
    Webhook.url = pick(w.url, "string", Webhook.url)
    Webhook.notifyComplete = pick(w.notifyComplete, "boolean", Webhook.notifyComplete)
    Webhook.notifyFail = pick(w.notifyFail, "boolean", Webhook.notifyFail)
    local d = data.dungeon or {}
    DungeonBot.remoteMap = pick(d.remoteMap, "table", DungeonBot.remoteMap)
    DungeonBot.shrineEnabled = pick(d.shrineEnabled, "boolean", DungeonBot.shrineEnabled)
    DungeonBot.autoBuyBuffs = pick(d.autoBuyBuffs, "boolean", DungeonBot.autoBuyBuffs)
    local u = data.unitAI or {}
    UnitAI.abilityCooldown = pick(u.abilityCooldown, "number", UnitAI.abilityCooldown)
    UnitAI.buffInterval = pick(u.buffInterval, "number", UnitAI.buffInterval)
    UnitAI.minUnitsForBuff = pick(u.minUnitsForBuff, "number", UnitAI.minUnitsForBuff)
    pendingToggles.autoAbilities = u.autoAbilities == true
    pendingToggles.autoBuff = u.autoBuff == true
    local a = data.autoFarm or {}
    AutoFarm.autoReplay = pick(a.autoReplay, "boolean", AutoFarm.autoReplay)
    AutoFarm.autoNextStage = pick(a.autoNextStage, "boolean", AutoFarm.autoNextStage)
    AutoFarm.autoLeave = pick(a.autoLeave, "boolean", AutoFarm.autoLeave)
    AutoFarm.leaveAtWave = pick(a.leaveAtWave, "number", AutoFarm.leaveAtWave)
    AutoFarm.speedMultiplier = pick(a.speedMultiplier, "number", AutoFarm.speedMultiplier)
    AutoFarm.autoSell = pick(a.autoSell, "boolean", AutoFarm.autoSell)
    AutoFarm.sellAtWave = pick(a.sellAtWave, "number", AutoFarm.sellAtWave)
    AutoFarm.sellUnitName = pick(a.sellUnitName, "string", AutoFarm.sellUnitName)
    local m = data.macro or {}
    State.retryPlacements = pick(m.retryPlacements, "boolean", State.retryPlacements)
    State.autoPlay = pick(m.autoPlay, "boolean", State.autoPlay)
    State.showAllMacros = pick(m.showAllMacros, "boolean", State.showAllMacros)
    if type(m.lastMacro) == "string" and #m.lastMacro > 0 then State.macroName = m.lastMacro end
    local t = data.tools or {}
    pendingToggles.antiAfk = t.antiAfk == true
end

local function saveConfig()
    if not configReady or not hasFileApi() then return end
    pcall(function()
        ensureFolder(Config.Folder)
        writefile(ConfigFile, HttpService:JSONEncode(buildConfigData()))
    end)
end

local ConfigProfiles = {}

local function profilePath(name)
    return ProfileFolder .. "/" .. name .. ".json"
end

function ConfigProfiles.List()
    local names = {}
    if not hasFileApi() or type(listfiles) ~= "function" or not isfolder(ProfileFolder) then return names end
    for _, file in ipairs(listfiles(ProfileFolder)) do
        local name = tostring(file):match("([^/\\]+)%.json$")
        if name then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

function ConfigProfiles.Save(name)
    name = cleanName(name)
    if not name then return false, "Type a profile name first." end
    if not hasFileApi() then return false, "This executor cannot write files." end
    Profile.name = name
    local ok = pcall(function()
        ensureFolder(ProfileFolder)
        writefile(profilePath(name), HttpService:JSONEncode(buildConfigData()))
    end)
    saveConfig()
    return ok, ok and ("Profile saved: " .. name) or "Could not write the profile file."
end

function ConfigProfiles.Load(name)
    name = cleanName(name)
    if not name then return false, "Pick a profile first." end
    if not hasFileApi() or not isfile(profilePath(name)) then return false, "Profile not found: " .. name end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(profilePath(name))) end)
    if not ok then return false, "Profile file is broken: " .. name end
    applyConfigData(data)
    Profile.name = name
    if applyRuntimeFeatures then applyRuntimeFeatures() end
    saveConfig()
    return true, "Profile loaded: " .. name
end

function ConfigProfiles.Delete(name)
    name = cleanName(name)
    if not name or not hasFileApi() or type(delfile) ~= "function" or not isfile(profilePath(name)) then
        return false, "Profile not found."
    end
    pcall(delfile, profilePath(name))
    if Profile.name == name then Profile.name = "" end
    saveConfig()
    return true, "Profile deleted: " .. name
end

local function loadConfig()
    if not hasFileApi() or not isfile(ConfigFile) then return end
    pcall(function() applyConfigData(HttpService:JSONDecode(readfile(ConfigFile))) end)
end

loadConfig()

-- Serialization (used only when saving / loading)
local function serializeValue(v)
    local t = typeof(v)
    if v == nil then return { _t = "nil" }
    elseif t == "number" or t == "string" or t == "boolean" then return { _t = t, v = v }
    elseif t == "Vector3" then return { _t = "Vector3", x = v.X, y = v.Y, z = v.Z }
    elseif t == "Vector2" then return { _t = "Vector2", x = v.X, y = v.Y }
    elseif t == "CFrame" then return { _t = "CFrame", c = { v:GetComponents() } }
    elseif t == "Color3" then return { _t = "Color3", r = v.R, g = v.G, b = v.B }
    elseif t == "EnumItem" then return { _t = "EnumItem", s = tostring(v) }
    elseif t == "Instance" then
        local pathOk, path = pcall(function() return v:GetFullName() end)
        return { _t = "Instance", p = pathOk and path or "destroyed" }
    elseif t == "table" then
        local out = {}
        for k, val in pairs(v) do out[tostring(k)] = serializeValue(val) end
        return { _t = "table", v = out }
    end
    return { _t = "unsupported", s = tostring(v) }
end

local function resolveInstance(path)
    if type(path) ~= "string" then return nil end
    local ok, result = pcall(function()
        local current = game
        for segment in path:gmatch("[^%.]+") do
            if segment ~= "game" then
                current = current:FindFirstChild(segment)
                if not current then return nil end
            end
        end
        return current
    end)
    return ok and result or nil
end

local function deserializeValue(data)
    if type(data) ~= "table" or not data._t then return data end
    local t = data._t
    if t == "nil" then return nil
    elseif t == "number" or t == "string" or t == "boolean" then return data.v
    elseif t == "Vector3" then return Vector3.new(data.x, data.y, data.z)
    elseif t == "Vector2" then return Vector2.new(data.x, data.y)
    elseif t == "CFrame" then return CFrame.new(unpack(data.c))
    elseif t == "Color3" then return Color3.new(data.r, data.g, data.b)
    elseif t == "EnumItem" then return data.s
    elseif t == "Instance" then return resolveInstance(data.p)
    elseif t == "table" then
        local result = {}
        for k, val in pairs(data.v) do result[tonumber(k) or k] = deserializeValue(val) end
        return result
    end
    return nil
end

-- Readable descriptions (raw and serialized values)
local SHORT = { depth = 2, items = 4, str = 24 }
local FULL = { depth = 6, items = 100, str = 500 }

local describeValue

local function describeTable(tbl, depth, limits)
    if depth >= limits.depth then return "{...}" end
    local parts, count = {}, 0
    for k, v in pairs(tbl) do
        count = count + 1
        if count > limits.items then
            table.insert(parts, "...")
            break
        end
        local key = tostring(k)
        if tonumber(key) then
            table.insert(parts, describeValue(v, depth + 1, limits))
        else
            table.insert(parts, key .. "=" .. describeValue(v, depth + 1, limits))
        end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

describeValue = function(v, depth, limits)
    depth = depth or 0
    limits = limits or SHORT
    local t = typeof(v)
    if t == "table" and v._t then
        local k = v._t
        if k == "nil" then return "nil" end
        if k == "number" or k == "string" or k == "boolean" then return describeValue(v.v, depth, limits) end
        if k == "Vector3" then return string.format("(%.1f, %.1f, %.1f)", v.x, v.y, v.z) end
        if k == "Vector2" then return string.format("(%.1f, %.1f)", v.x, v.y) end
        if k == "CFrame" then return string.format("@(%.1f, %.1f, %.1f)", v.c[1], v.c[2], v.c[3]) end
        if k == "Instance" then return tostring(v.p):match("([^%.]+)$") or "?" end
        if k == "table" then return describeTable(v.v, depth, limits) end
        return tostring(v.s or k)
    end
    if t == "string" then return '"' .. clip(v, limits.str) .. '"' end
    if t == "number" then return string.format("%.4g", v) end
    if t == "boolean" or t == "nil" then return tostring(v) end
    if t == "Vector3" then return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
    if t == "Vector2" then return string.format("(%.1f, %.1f)", v.X, v.Y) end
    if t == "CFrame" then return string.format("@(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
    if t == "Instance" then return v.Name end
    if t == "table" then return describeTable(v, depth, limits) end
    return t
end

local function describeAction(i, action, limits)
    local args = action.rawArgs or action.args or {}
    local nArgs = action.argCount or #args
    local refs = {}
    for _, r in ipairs(action.unitRefs or {}) do refs[r.arg] = r.ref end
    local parts = {}
    for j = 1, nArgs do
        parts[j] = refs[j] and ("<unit from #" .. refs[j] .. ">") or describeValue(args[j], 0, limits)
    end
    local mark = action.spent == true and " [$]" or ""
    return string.format("%d. %s  %s%s  %s", i, formatDuration(action.t), action.name, mark, table.concat(parts, ", "))
end

-- Stage detection: workspace._MAP_CONFIG (IsLobby, GetLevelData, Level)
local Stage = { data = nil }

local function mapConfig()
    return workspace:FindFirstChild("_MAP_CONFIG")
end

function Stage.levelData()
    if Stage.data ~= nil then return Stage.data end
    local config = mapConfig()
    local getLevelData = config and config:FindFirstChild("GetLevelData")
    if getLevelData and getLevelData:IsA("RemoteFunction") then
        local ok, data = pcall(function() return getLevelData:InvokeServer() end)
        Stage.data = ok and data or false
    else
        Stage.data = false
    end
    return Stage.data
end

function Stage.nameFromLevelData(data)
    local function text(key)
        local v = data[key]
        return type(v) == "string" and v ~= "" and v or nil
    end
    local parts = {}
    local location = text("_location_name") or text("world")
    if location then table.insert(parts, location) end
    local level = text("name") or text("id")
    if level then table.insert(parts, level) end
    local mode = text("_gamemode")
    if mode and mode ~= "story" and not string.lower(level or ""):find(string.lower(mode), 1, true) then
        table.insert(parts, mode)
    end
    local difficulty = text("_difficulty")
    if difficulty and difficulty ~= "Normal" then table.insert(parts, difficulty) end
    if #parts == 0 then return text("map") end
    return table.concat(parts, " ")
end

function Stage.detect()
    local config = mapConfig()
    if not config then return nil end
    local isLobby = config:FindFirstChild("IsLobby")
    if isLobby and isLobby.Value == true then return nil end
    local name
    local data = Stage.levelData()
    if type(data) == "table" then
        name = Stage.nameFromLevelData(data)
    end
    if not name then
        local level = config:FindFirstChild("Level")
        local value = level and level.Value
        if type(value) == "string" and value ~= "" and value ~= "nil" then name = value end
    end
    if not name then return nil end
    name = name:gsub("[^%w _%-]", " "):gsub("%s+", " ")
    return cleanName(name:sub(1, 34))
end

local function stageMacroPattern(stage)
    return "^" .. stage:gsub("[%-%.%+%*%?%[%]%^%$%(%)%%]", "%%%0") .. " #%d+$"
end

local function refreshStatus()
    if not statusParagraph then return end
    local stateText
    if State.recording then stateText = "Recording"
    elseif State.finalizing then stateText = "Saving..."
    elseif State.replaying then stateText = string.format("Playing %d / %d", State.replayIndex, #State.actions)
    elseif #State.actions > 0 then stateText = "Ready"
    else stateText = "Idle" end
    local elapsed = State.recording and (os.clock() - State.startedAt) or State.duration
    statusParagraph:UpdateBody(string.format(
        "%s   |   %s\nStage: %s\nTime: %s   Actions: %d",
        stateText, cleanName(State.macroName) or "(no macro)", State.stage or "not detected (lobby?)",
        formatDuration(elapsed), #State.actions
    ))
end

local function refreshActionList()
    if not actionsParagraph then return end
    local n = #State.actions
    if n == 0 then
        actionsParagraph:UpdateBody("Nothing recorded yet.")
        return
    end
    local first = math.max(1, n - Config.ListLines + 1)
    local lines = {}
    if first > 1 then table.insert(lines, string.format("(%d earlier actions hidden)", first - 1)) end
    for i = first, n do table.insert(lines, describeAction(i, State.actions[i], SHORT)) end
    actionsParagraph:UpdateBody(table.concat(lines, "\n"))
end

-- Money tracking: numeric values on the local player, read outside the hook.
local function buildTracked()
    local list = {}
    local player = Players.LocalPlayer
    for _, d in ipairs(player:GetDescendants()) do
        if #list >= Config.MaxTrackedValues then break end
        if d:IsA("IntValue") or d:IsA("NumberValue") then
            table.insert(list, { obj = d })
        end
    end
    for key, value in pairs(player:GetAttributes()) do
        if #list >= Config.MaxTrackedValues then break end
        if type(value) == "number" then
            table.insert(list, { obj = player, attr = key })
        end
    end
    return list
end

local function readTracked()
    local snap = {}
    for i, entry in ipairs(State.tracked) do
        local ok, value = pcall(function()
            if entry.attr then return entry.obj:GetAttribute(entry.attr) end
            return entry.obj.Value
        end)
        snap[i] = ok and tonumber(value) or nil
    end
    return snap
end

local function anyDecrease(before, now)
    if not before then return false end
    for i, old in pairs(before) do
        local new = now[i]
        if old and new and new < old - 1e-6 then return true end
    end
    return false
end

-- Placed units: match units appearing in workspace._UNITS to the spawn action at that spot.
local function unitsFolder()
    return workspace:FindFirstChild("_UNITS")
end

local function actionPosition(action)
    for _, a in ipairs(action.rawArgs or action.args or {}) do
        local t = typeof(a)
        if t == "CFrame" then return a.Position end
        if t == "Vector3" then return a end
        if t == "table" and a._t == "CFrame" then return Vector3.new(a.c[1], a.c[2], a.c[3]) end
        if t == "table" and a._t == "Vector3" then return Vector3.new(a.x, a.y, a.z) end
    end
    return nil
end

local function unitPosition(unit)
    local ok, pivot = pcall(function() return unit:GetPivot() end)
    return ok and pivot.Position or nil
end

local function matchesSpot(unit, target)
    local pos = target and unitPosition(unit)
    return pos ~= nil and (pos - target).Magnitude <= Config.UnitMatchDistance
end

local function onUnitAddedWhileRecording(unit)
    task.delay(0.1, function()
        if not State.recording then return end
        local now = os.clock()
        for i = #State.actions, 1, -1 do
            local action = State.actions[i]
            if now - action.at > Config.UnitMatchWindow then break end
            if action.name == Config.SpawnRemote and not action.unit and matchesSpot(unit, actionPosition(action)) then
                action.unit = unit
                return
            end
        end
    end)
end

-- Hook
local function installHook()
    if hookInstalled then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        notify("This executor has no hookmetamethod/getnamecallmethod, so recording cannot work.")
        return false
    end
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        local method = getnamecallmethod()
        if State.recording and (method == "FireServer" or method == "InvokeServer")
            and not (type(checkcaller) == "function" and checkcaller()) then
            local ok, className = pcall(function() return typeof(self) == "Instance" and self.ClassName end)
            if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
            if ok and (className == "RemoteEvent" or className == "RemoteFunction") then
                local elapsed = os.clock() - State.startedAt
                if elapsed < Config.MaxDuration and #State.actions < Config.MaxActions then
                    table.insert(State.actions, {
                        t = elapsed,
                        at = os.clock(),
                        remote = self,
                        name = self.Name,
                        method = method,
                        rawArgs = { ... },
                        argCount = select("#", ...),
                        before = State.snapshot,
                    })
                end
            end
        end
        return oldNamecall(self, ...)
    end))
    hookInstalled = true
    return true
end

-- Files
local Files = {}
local MacroFolder_path = MacroFolder

function Files.path(name)
    return MacroFolder_path .. "/" .. name .. ".json"
end

local function validUnitRefs(refs, index)
    if refs == nil then return true end
    if type(refs) ~= "table" then return false end
    for _, r in ipairs(refs) do
        if type(r) ~= "table" or type(r.arg) ~= "number" or type(r.ref) ~= "number" or r.ref < 1 or r.ref >= index then
            return false
        end
    end
    return true
end

local function validAction(action, lastTime, index)
    return type(action) == "table"
        and type(action.t) == "number" and action.t >= lastTime and action.t <= Config.MaxDuration
        and type(action.path) == "string" and #action.path > 0
        and type(action.name) == "string"
        and (action.method == "FireServer" or action.method == "InvokeServer")
        and type(action.args) == "table"
        and (action.spent == nil or type(action.spent) == "boolean")
        and validUnitRefs(action.unitRefs, index)
end

function Files.parse(text, fallbackName)
    local ok, data = pcall(function() return HttpService:JSONDecode(text) end)
    if not ok or type(data) ~= "table" then error("not valid macro JSON") end
    if (data.version ~= 2 and data.version ~= 3) or type(data.actions) ~= "table" then
        error("not a macro file (version 2 or 3 expected)")
    end
    if #data.actions > Config.MaxActions then error("more than " .. Config.MaxActions .. " actions") end
    if data.version == 2 then
        for _, action in ipairs(data.actions) do
            if action.spent == nil then action.spent = false end
            if action.unitRefs == nil then action.unitRefs = nil end
            if action.argCount == nil then action.argCount = action.args and #action.args or 0 end
        end
    end
    local previous = 0
    for i, action in ipairs(data.actions) do
        if not validAction(action, previous, i) then error("action #" .. i .. " is invalid") end
        previous = action.t
    end
    local duration = tonumber(data.duration) or previous
    if duration < previous or duration > Config.MaxDuration then error("invalid duration") end
    local startOffset = tonumber(data.startOffset)
    if startOffset and (startOffset < 0 or startOffset > duration) then error("invalid start offset") end
    local name = cleanName(data.name) or cleanName(data.stage) or cleanName(fallbackName)
    return { name = name, duration = duration, startOffset = startOffset, actions = data.actions }
end

function Files.encode(name, duration, startOffset, actions)
    local out = {}
    for i, action in ipairs(actions) do
        local sArgs = action.args
        local nArgs = action.argCount
        if action.rawArgs then
            sArgs = {}
            nArgs = action.argCount or #action.rawArgs
            for j = 1, nArgs do sArgs[j] = serializeValue(action.rawArgs[j]) end
        end
        out[i] = {
            t = action.t,
            path = action.path or action.remote:GetFullName(),
            name = action.name,
            method = action.method,
            spent = action.spent == true or nil,
            unitRefs = action.unitRefs,
            argCount = nArgs,
            args = sArgs,
        }
    end
    return HttpService:JSONEncode({
        version = 3,
        game = "AA",
        name = name,
        duration = duration,
        startOffset = startOffset,
        actions = out,
    })
end

function Files.list()
    if not hasFileApi() or type(listfiles) ~= "function" then return {} end
    local pattern = (State.stage and not State.showAllMacros) and stageMacroPattern(State.stage) or nil
    local names = {}
    local ok, files = pcall(function()
        ensureFolder(MacroFolder_path)
        return listfiles(MacroFolder_path)
    end)
    if ok and type(files) == "table" then
        for _, file in ipairs(files) do
            local name = tostring(file):match("([^/\\]+)%.json$")
            if name and (not pattern or name:match(pattern) or name == State.stage) then
                table.insert(names, name)
            end
        end
    end
    table.sort(names)
    return names
end

local function refreshSavedList(select)
    if not savedDropdown then return end
    syncing = true
    savedDropdown:ClearOptions()
    savedDropdown:InsertOptions(Files.list())
    if select then savedDropdown:UpdateSelection(select) end
    syncing = false
end

local function setMacroName(name)
    State.macroName = name or ""
    if nameInput and nameInput:GetInput() ~= State.macroName then nameInput:UpdateText(State.macroName) end
    refreshStatus()
end

local function nextStageMacroName(stage)
    local n = 1
    while hasFileApi() and isfile(Files.path(stage .. " #" .. n)) do n = n + 1 end
    return stage .. " #" .. n
end

local ProfilesModule = {}

function ProfilesModule.Save()
    local name = cleanName(State.macroName)
    if not name or #State.actions == 0 then return false end
    if not hasFileApi() then
        notify("This executor has no file functions, so the macro stays in memory only.")
        return false
    end
    local ok, err = pcall(function()
        ensureFolder(MacroFolder_path)
        writefile(Files.path(name), Files.encode(name, State.duration, State.startOffset, State.actions))
    end)
    if not ok then
        notify("Save failed: " .. tostring(err))
        return false
    end
    refreshSavedList(name)
    return true
end

local function applyProfile(profile)
    State.actions = profile.actions
    State.duration = profile.duration
    State.startOffset = profile.startOffset
    setMacroName(profile.name or State.macroName)
    refreshActionList()
end

function ProfilesModule.Load(name)
    if State.recording or State.finalizing or State.replaying then
        notify("Wait until recording / playing has stopped.")
        return false
    end
    if not hasFileApi() then
        notify("This executor has no file functions.")
        return false
    end
    local ok, result = pcall(function()
        local path = Files.path(name)
        if not isfile(path) then error("no macro named " .. name) end
        return Files.parse(readfile(path), name)
    end)
    if not ok then
        notify("Load failed: " .. tostring(result))
        return false
    end
    applyProfile(result)
    notify(string.format("Loaded %s (%d actions).", name, #State.actions))
    return true
end

function ProfilesModule.DeleteCurrent()
    local name = cleanName(State.macroName)
    if not name or not hasFileApi() or not isfile(Files.path(name)) then
        notify("Pick a saved macro on the Macro page first.")
        return
    end
    if type(delfile) ~= "function" then
        notify("This executor has no delfile. Delete " .. Files.path(name) .. " by hand.")
        return
    end
    Window:Dialog({
        Title = "Delete macro",
        Description = "Delete " .. name .. "? This cannot be undone.",
        Buttons = {
            {
                Name = "Delete",
                Callback = function()
                    local ok, err = pcall(delfile, Files.path(name))
                    if ok then
                        State.actions = {}
                        State.duration = 0
                        State.startOffset = nil
                        setMacroName("")
                        refreshActionList()
                    end
                    refreshSavedList()
                    notify(ok and ("Deleted " .. name .. ".") or ("Delete failed: " .. tostring(err)))
                end,
            },
            { Name = "Cancel" },
        },
    })
end

function ProfilesModule.Export()
    local name = cleanName(State.macroName)
    if #State.actions == 0 or not name then
        notify("Pick or record a macro first.")
        return false
    end
    local json = Files.encode(name, State.duration, State.startOffset, State.actions)
    local savedTo
    if hasFileApi() then
        local ok = pcall(function()
            ensureFolder(Config.Folder .. "/exports")
            savedTo = Config.Folder .. "/exports/" .. name .. ".json"
            writefile(savedTo, json)
        end)
        if not ok then savedTo = nil end
    end
    local copied = type(setclipboard) == "function" and pcall(setclipboard, json)
    if savedTo and copied then
        notify("Exported to " .. savedTo .. " and copied to clipboard.")
    elseif savedTo then
        notify("Exported to " .. savedTo)
    elseif copied then
        notify("Copied macro JSON to clipboard.")
    else
        notify("Export failed: this executor has no writefile or setclipboard.")
        return false
    end
    return true
end

local function storeImported(profile)
    if not profile.name then error("file has no macro name") end
    ensureFolder(MacroFolder_path)
    writefile(Files.path(profile.name), Files.encode(profile.name, profile.duration, profile.startOffset, profile.actions))
end

function ProfilesModule.ImportFolder()
    if not hasFileApi() or type(listfiles) ~= "function" then
        notify("This executor has no file functions.")
        return false
    end
    local folder = Config.Folder .. "/imports"
    ensureFolder(folder)
    local imported, failed = 0, 0
    for _, file in ipairs(listfiles(folder)) do
        local base = tostring(file):match("([^/\\]+)%.json$")
        if base then
            local ok, err = pcall(function()
                storeImported(Files.parse(readfile(file), base:match("__(.+)$") or base))
            end)
            if ok then imported = imported + 1 else
                failed = failed + 1
                warn("[Macro Import] " .. base .. ": " .. tostring(err))
            end
        end
    end
    refreshSavedList()
    if imported == 0 and failed == 0 then
        notify("Put exported .json files into " .. folder .. " and press Import again.")
    else
        notify(string.format("Imported %d macro(s)%s.", imported, failed > 0 and (", " .. failed .. " failed (see console)") or ""))
    end
    return imported > 0
end

function ProfilesModule.ImportText(text)
    if type(text) ~= "string" or #text < 2 then return end
    local ok, result = pcall(function()
        local profile = Files.parse(text, State.macroName)
        if hasFileApi() then storeImported(profile) end
        return profile
    end)
    if pasteInput then pasteInput:UpdateText("") end
    if not ok then
        notify("Import failed: " .. tostring(result))
        return
    end
    applyProfile(result)
    refreshSavedList(result.name)
    notify(string.format("Imported %s (%d actions).", tostring(result.name), #State.actions))
end

-- Recording
local RecordingModule = {}
local recordUnitConnection

local function linkUnitArguments(actions)
    local unitIndex = {}
    for i, action in ipairs(actions) do
        if action.unit then unitIndex[action.unit] = i end
    end
    for i, action in ipairs(actions) do
        local raw = action.rawArgs or {}
        local nArgs = action.argCount or #raw
        for j = 1, nArgs do
            local arg = raw[j]
            local ref = typeof(arg) == "Instance" and unitIndex[arg]
            if ref and ref < i then
                action.unitRefs = action.unitRefs or {}
                table.insert(action.unitRefs, { arg = j, ref = ref })
            end
        end
    end
end

local function finalizeRecording()
    State.finalizing = false
    if recordUnitConnection then
        recordUnitConnection:Disconnect()
        recordUnitConnection = nil
    end
    local snap = readTracked()
    for _, action in ipairs(State.actions) do
        if action.spent == nil then action.spent = anyDecrease(action.before, snap) end
    end
    local costRemotes = {}
    for _, action in ipairs(State.actions) do
        if action.spent then costRemotes[action.name] = true end
    end
    local kept, dropped = {}, 0
    for _, action in ipairs(State.actions) do
        if costRemotes[action.name] and not action.spent then
            dropped = dropped + 1
        else
            table.insert(kept, action)
        end
    end
    linkUnitArguments(kept)
    State.actions = kept
    refreshStatus()
    refreshActionList()

    local summary = string.format("Recorded %d actions in %s.", #kept, formatDuration(State.duration))
    if #State.tracked == 0 then
        summary = summary .. " No money value found, so failed placements were not filtered."
    elseif dropped > 0 then
        summary = summary .. string.format(" Dropped %d that spent no money.", dropped)
    end
    if not State.startOffset then summary = summary .. " Game start was not seen, so Auto play starts from action 1." end
    if #kept > 0 and ProfilesModule.Save() then summary = summary .. " Saved as " .. cleanName(State.macroName) .. "." end
    notify(summary)
end

local function finishRecording(message)
    if not State.recording then return false end
    State.duration = math.min(Config.MaxDuration, os.clock() - State.startedAt)
    State.recording = false
    setToggle(recordToggle, false)
    refreshStatus()
    if message then notify(message) end
    finalizeRecording()
    return true
end

function RecordingModule.Start()
    if State.recording then return true end
    if State.replaying or State.finalizing then
        notify("Wait until playing / saving has finished.")
        return false
    end
    if not cleanName(State.macroName) and State.stage then
        setMacroName(nextStageMacroName(State.stage))
    end
    if not cleanName(State.macroName) then
        notify("Stage not detected. Type a macro name first (e.g. Namak 1).")
        return false
    end
    if not installHook() then return false end
    State.tracked = buildTracked()
    State.snapshot = readTracked()
    State.actions = {}
    State.startedAt = os.clock()
    State.startOffset = nil
    State.duration = 0
    State.recording = true
    local folder = unitsFolder()
    if folder then recordUnitConnection = folder.ChildAdded:Connect(onUnitAddedWhileRecording) end
    refreshStatus()
    refreshActionList()
    notify("Recording " .. cleanName(State.macroName) .. ". Switch Record off when done; it saves automatically.")
    return true
end

function RecordingModule.Stop()
    if not State.recording then return false end
    return finishRecording(nil)
end

-- Playback
local PlaybackModule = {}
local replayUnits, replayNewUnits = {}, {}
local replayUnitConnection

local function addReplayLog(line)
    if #State.replayLog >= 300 then return end
    line = formatDuration(os.clock() - State.replayStartedAt) .. "  " .. line
    table.insert(State.replayLog, line)
    print("[Macro Replay] " .. line)
end

local function buildArgs(action)
    local args
    local nArgs = action.argCount
    if action.rawArgs then
        nArgs = nArgs or #action.rawArgs
        args = {}
        for j = 1, nArgs do args[j] = action.rawArgs[j] end
    else
        local serialized = action.args or {}
        nArgs = nArgs or #serialized
        args = {}
        for j = 1, nArgs do args[j] = deserializeValue(serialized[j]) end
    end
    for _, r in ipairs(action.unitRefs or {}) do
        local unit = replayUnits[r.ref]
        if not unit or not unit.Parent then
            return nil, "the unit placed by #" .. r.ref .. " is not on the map"
        end
        args[r.arg] = unit
    end
    return args
end

local function fireAction(i, action)
    local remote = action.remote or resolveInstance(action.path)
    if not remote then
        addReplayLog(string.format("#%d %s: remote not found (%s)", i, action.name, tostring(action.path)))
        return false
    end
    local args, why = buildArgs(action)
    if not args then
        addReplayLog(string.format("#%d %s: skipped, %s", i, action.name, why))
        return false
    end
    local nArgs = action.argCount or #args
    local ok, result = pcall(function()
        if action.method == "FireServer" then
            remote:FireServer(table.unpack(args, 1, nArgs))
            return "sent"
        end
        local packed = table.pack(remote:InvokeServer(table.unpack(args, 1, nArgs)))
        local parts = {}
        for k = 1, packed.n do parts[k] = describeValue(packed[k], 0, SHORT) end
        return "returned " .. (#parts > 0 and table.concat(parts, ", ") or "nothing")
    end)
    addReplayLog(string.format("#%d %s: %s", i, action.name, ok and result or ("error " .. tostring(result))))
    return ok
end

local function claimSpawnedUnit(i, action, firedAt)
    if action.name ~= Config.SpawnRemote then return end
    local target = actionPosition(action)
    if not target then return end
    local deadline = os.clock() + Config.UnitMatchWindow
    while State.replaying and os.clock() < deadline do
        local staleThreshold = os.clock() - Config.UnitMatchWindow * 2
        local j = 1
        while j <= #replayNewUnits do
            local entry = replayNewUnits[j]
            if entry.at < staleThreshold then
                table.remove(replayNewUnits, j)
            else
                if entry.at >= firedAt - 0.2 and matchesSpot(entry.unit, target) then
                    replayUnits[i] = entry.unit
                    table.remove(replayNewUnits, j)
                    return
                end
                j = j + 1
            end
        end
        task.wait(0.1)
    end
    addReplayLog(string.format("#%d %s: could not find the placed unit", i, action.name))
end

local function fireUntilSpent(i, action)
    local firstFire = os.clock()
    local giveUpAt = firstFire + Config.RetryTimeout
    local lastFire = firstFire
    while State.replaying do
        local before = readTracked()
        lastFire = os.clock()
        if not fireAction(i, action) and action.unitRefs then
            return false, lastFire - firstFire, lastFire
        end
        local verifyUntil = lastFire + Config.ReplayVerifyWindow
        while State.replaying and os.clock() < verifyUntil do
            task.wait(0.1)
            if anyDecrease(before, readTracked()) then
                return true, lastFire - firstFire, lastFire
            end
        end
        if os.clock() >= giveUpAt then break end
        addReplayLog(string.format("#%d %s: money did not go down, retrying", i, action.name))
        task.wait(Config.RetryInterval)
    end
    return false, os.clock() - firstFire, lastFire
end

-- Webhook helper
local function sendWebhook(title, message)
    if #Webhook.url < 10 then return end
    pcall(function()
        local body = HttpService:JSONEncode({
            embeds = {{
                title = title,
                description = message,
                color = title:find("Fail") and 15158332 or 3066993,
                footer = { text = "Macro UI // " .. os.date("%H:%M:%S") },
            }}
        })
        local httpRequest = (syn and syn.request) or (http and http.request) or request or http_request
        if type(httpRequest) == "function" then
            httpRequest({ Url = Webhook.url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
        end
    end)
end

function PlaybackModule.Play(fromGameStart)
    if State.replaying then return true end
    if State.recording or State.finalizing then
        notify("Stop recording before playing.")
        return false
    end
    if #State.actions == 0 then
        notify("Nothing to play. Pick a saved macro or record one first.")
        return false
    end

    State.replaying = true
    State.replayIndex = 0
    State.replayLog = {}
    State.replayStartedAt = os.clock()
    State.tracked = buildTracked()
    replayUnits, replayNewUnits = {}, {}
    local folder = unitsFolder()
    if folder then
        replayUnitConnection = folder.ChildAdded:Connect(function(unit)
            table.insert(replayNewUnits, { unit = unit, at = os.clock() })
        end)
    end
    local canRetry = State.retryPlacements and #State.tracked > 0
    local speedMul = math.max(0.1, AutoFarm.speedMultiplier)
    addReplayLog(string.format("play %s, %d actions, retry %s, speed %.1fx, %s",
        cleanName(State.macroName) or "?", #State.actions, canRetry and "on" or "off", speedMul,
        fromGameStart and "started by game start" or "started by hand"))
    setToggle(playToggle, true)
    refreshStatus()
    notify(string.format("Playing %s (%d actions).", cleanName(State.macroName) or "macro", #State.actions))

    task.spawn(function()
        local startTime = os.clock()
        local shift = fromGameStart and -(State.startOffset or 0) or 0
        local failed = 0
        local actionCount = #State.actions
        for i = 1, actionCount do
            local action = State.actions[i]
            if not State.replaying then break end
            State.replayIndex = i
            refreshStatus()
            Tools.totalActions = Tools.totalActions + 1

            local scheduledTime = startTime + (action.t + shift) / speedMul
            local waitTime = scheduledTime - os.clock()
            if canRetry and action.spent == true then
                -- placement: don't wait, fire now (fireUntilSpent retries until money spent)
                if waitTime > 0.01 then
                    shift = shift - (waitTime * speedMul)
                end
            else
                if waitTime > 0.01 then task.wait(waitTime) end
            end
            if not State.replaying then break end

            if canRetry and action.spent == true then
                local ok, delay, firedAt = fireUntilSpent(i, action)
                shift = shift + delay * speedMul
                if ok then
                    claimSpawnedUnit(i, action, firedAt)
                elseif State.replaying then
                    failed = failed + 1
                    addReplayLog(string.format("#%d %s: gave up", i, action.name))
                end
            else
                local firedAt = os.clock()
                if fireAction(i, action) then
                    claimSpawnedUnit(i, action, firedAt)
                else
                    failed = failed + 1
                end
            end
        end

        if replayUnitConnection then
            replayUnitConnection:Disconnect()
            replayUnitConnection = nil
        end
        local finished = State.replaying
        State.replaying = false
        State.replayIndex = 0
        setToggle(playToggle, false)
        refreshStatus()
        addReplayLog(finished and string.format("finished, %d failed", failed) or "stopped")

        if finished then
            Tools.totalReplays = Tools.totalReplays + 1
            if failed > 0 then
                Tools.totalFails = Tools.totalFails + 1
                if Webhook.notifyFail then sendWebhook("Macro Failed", string.format("%s: %d action(s) failed.", cleanName(State.macroName) or "macro", failed)) end
                notify(string.format("Finished, %d action(s) failed.", failed))
            else
                if Webhook.notifyComplete then sendWebhook("Macro Complete", string.format("%s finished (%d actions).", cleanName(State.macroName) or "macro", #State.actions)) end
                notify("Finished.")
            end
        else
            notify("Stopped.")
        end
    end)
    return true
end

function PlaybackModule.Stop()
    State.replaying = false
end

function RecordingModule.CopyLog()
    if #State.actions == 0 and #State.replayLog == 0 then
        notify("Nothing recorded or played yet.")
        return
    end
    local lines = { string.format("[Macro] %s, stage %s, %d actions, %d money values tracked, start offset %s",
        cleanName(State.macroName) or "?", State.stage or "-", #State.actions, #State.tracked,
        State.startOffset and string.format("%.1fs", State.startOffset) or "none") }
    for i, action in ipairs(State.actions) do
        local path = action.path or (action.remote and action.remote:GetFullName()) or "?"
        table.insert(lines, string.format("%s  [%s %s]", describeAction(i, action, FULL), action.method, path))
    end
    if #State.replayLog > 0 then
        table.insert(lines, "[Last play]")
        for _, line in ipairs(State.replayLog) do table.insert(lines, line) end
    end
    local text = table.concat(lines, "\n")
    print(text)
    if type(setclipboard) == "function" and pcall(setclipboard, text) then
        notify("Log copied to clipboard and printed to console.")
    else
        notify("Log printed to console.")
    end
end

-- Scan
local Scan = {}
local STAGE_WORDS = { "map", "level", "stage", "world", "act", "mode", "difficulty", "wave", "chapter", "story", "infinite", "raid", "challenge", "dungeon" }
local BUTTON_WORDS = { "replay", "retry", "next", "lobby", "return", "leave", "victory", "defeat", "clear", "ready", "act ", "wave", "stage", "shop", "hoard", "battle", "boss", "shrine", "room", "depth" }

local function matchesAny(s, words)
    s = string.lower(tostring(s))
    for _, word in ipairs(words) do
        if s:find(word, 1, true) then return true end
    end
    return false
end

function Scan.Run()
    local lines = {}
    local function add(s)
        if #lines < Config.ScanMaxLines then table.insert(lines, s) end
    end
    local function addAttributes(inst, label)
        for key, value in pairs(inst:GetAttributes()) do
            add(string.format("  attr %s.%s = %s", label, key, clip(tostring(value), 80)))
        end
    end
    local function addValue(v)
        local ok, value = pcall(function() return v.Value end)
        add(string.format("  %s = %s", v:GetFullName(), ok and clip(tostring(value), 80) or "?"))
    end

    add(string.format("[Scan] PlaceId %d, macro %s, detected stage %s", game.PlaceId, cleanName(State.macroName) or "-", State.stage or "-"))

    Stage.data = nil
    local data = Stage.levelData()
    add("-- _MAP_CONFIG.GetLevelData() = " .. (data == false and "(not available)" or describeValue(data, 0, FULL)))

    add("-- workspace._DATA")
    local dataFolder = workspace:FindFirstChild("_DATA")
    if dataFolder then
        for _, d in ipairs(dataFolder:GetDescendants()) do
            if d:IsA("ValueBase") then addValue(d) end
        end
    end

    add("-- workspace children")
    for _, child in ipairs(workspace:GetChildren()) do
        if not child:IsA("Terrain") and not child:IsA("Camera") and child.Name ~= "_map" and child.Name ~= "_terrain" then
            add("  " .. child.Name .. " (" .. child.ClassName .. ")")
            if child.Name:sub(1, 1) == "_" then
                local shown = 0
                for _, sub in ipairs(child:GetChildren()) do
                    shown = shown + 1
                    if shown > 15 then add("      ...") break end
                    add("      " .. sub.Name .. " (" .. sub.ClassName .. ")")
                    if sub:IsA("ValueBase") then addValue(sub) end
                end
            end
        end
    end

    add("-- attributes")
    addAttributes(workspace, "workspace")
    addAttributes(ReplicatedStorage, "ReplicatedStorage")
    addAttributes(Players.LocalPlayer, "LocalPlayer")

    add("-- remotes in ReplicatedStorage (for discovery)")
    for _, child in ipairs(ReplicatedStorage:GetDescendants()) do
        if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
            add(string.format("  %s [%s]", child:GetFullName(), child.ClassName))
        end
    end

    add("-- visible screen text about stage / wave / buttons")
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Visible and d.Text ~= "" and matchesAny(d.Text, BUTTON_WORDS) then
                add(string.format("  %s [%s] = %q", d:GetFullName(), d.ClassName, clip(d.Text, 60)))
            end
        end
    end

    if #lines >= Config.ScanMaxLines then table.insert(lines, "(cut at " .. Config.ScanMaxLines .. " lines)") end
    local text = table.concat(lines, "\n")
    print(text)
    if type(setclipboard) == "function" and pcall(setclipboard, text) then
        notify("Scan copied to clipboard (" .. #lines .. " lines).")
    else
        notify("Scan printed to console (" .. #lines .. " lines).")
    end
end

--------------------------------------------------------------------------------
-- MODULE: GUI Button Scanner (shared utility)
--------------------------------------------------------------------------------
local function getAARemote(name)
    local endpoints = ReplicatedStorage:FindFirstChild("endpoints")
    if not endpoints then return nil end
    local cts = endpoints:FindFirstChild("client_to_server")
    if not cts then return nil end
    return cts:FindFirstChild(name)
end

local function isMyUnit(unit)
    local stats = unit:FindFirstChild("_stats")
    if not stats then return false end
    local playerVal = stats:FindFirstChild("player")
    if not playerVal then return false end
    return tostring(playerVal.Value) == Players.LocalPlayer.Name
end

-- Visible means the object, every GuiObject ancestor and its ScreenGui are shown.
local function isOnScreen(obj)
    local node = obj
    while node and node ~= game do
        if node:IsA("GuiObject") and not node.Visible then return false end
        if node:IsA("LayerCollector") then return node.Enabled end
        node = node.Parent
    end
    return false
end

-- A button's label may be its own Text or a TextLabel inside an ImageButton.
local function buttonText(btn)
    local parts = { string.lower(btn.Name) }
    if btn:IsA("TextButton") then table.insert(parts, string.lower(btn.Text)) end
    for _, d in ipairs(btn:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then table.insert(parts, string.lower(d.Text)) end
    end
    return table.concat(parts, " | ")
end

local ownGuiCache = setmetatable({}, { __mode = "k" })
local function isOwnGui(obj)
    local layer = obj:FindFirstAncestorWhichIsA("LayerCollector")
    if not layer then return false end
    if ownGuiCache[layer] == nil then
        local mine = false
        for _, d in ipairs(layer:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == "MACRO // LAB" then mine = true break end
        end
        ownGuiCache[layer] = mine
    end
    return ownGuiCache[layer]
end

local function containsAny(text, words)
    for _, w in ipairs(words or {}) do
        if text:find(w, 1, true) then return true end
    end
    return false
end

local function findScreenButton(keywords, exclude)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, kw in ipairs(keywords) do
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("GuiButton") and isOnScreen(d) and not isOwnGui(d) then
                local text = buttonText(d)
                if text:find(kw, 1, true) and not containsAny(text, exclude) then return d end
            end
        end
    end
    return nil
end

local function fireSignalSafe(signal)
    if type(firesignal) ~= "function" then return false end
    return pcall(firesignal, signal)
end

local function clickButton(btn)
    if not btn or not btn:IsA("GuiButton") then return false end
    local fired = false
    if type(getconnections) == "function" then
        for _, signalName in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down" }) do
            pcall(function()
                for _, conn in ipairs(getconnections(btn[signalName])) do
                    if conn.Function then conn.Function() fired = true
                    elseif conn.Fire then conn:Fire() fired = true end
                end
            end)
        end
    end
    if not fired then
        fired = fireSignalSafe(btn.MouseButton1Click) or fired
        fired = fireSignalSafe(btn.Activated) or fired
    end
    if not fired then
        pcall(function()
            local inset = game:GetService("GuiService"):GetGuiInset()
            local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2 + inset
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
            fired = true
        end)
    end
    return fired
end

local function getCurrentWave()
    local dataFolder = workspace:FindFirstChild("_DATA")
    if not dataFolder then return 0 end
    local waveValue = dataFolder:FindFirstChild("Wave") or dataFolder:FindFirstChild("CurrentWave")
    if waveValue and (waveValue:IsA("IntValue") or waveValue:IsA("NumberValue")) then
        return waveValue.Value or 0
    end
    return 0
end

local function isGameOver()
    local dataFolder = workspace:FindFirstChild("_DATA")
    if not dataFolder then return false end
    local gameFinished = dataFolder:FindFirstChild("GameFinished") or dataFolder:FindFirstChild("GameOver") or dataFolder:FindFirstChild("GameEnded")
    if gameFinished and gameFinished:IsA("BoolValue") then return gameFinished.Value == true end
    return false
end

local END_WORDS = { "victory", "defeat", "game over", "waves completed", "total time" }

local function isResultsShowing()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    local results = gui:FindFirstChild("ResultsUI")
    if results and results:IsA("LayerCollector") and results.Enabled then return true end
    for _, d in ipairs(gui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text > 0 then
            local lower = string.lower(d.Text)
            for _, word in ipairs(END_WORDS) do
                if lower:find(word, 1, true) and isOnScreen(d) then return true end
            end
        end
    end
    return false
end

local function resultIsVictory()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and string.lower(d.Text):find("victory", 1, true) and isOnScreen(d) then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- MODULE: Auto Farm (Replay Automation)
--------------------------------------------------------------------------------
local AutoFarmModule = {}

local function refreshAutoStatus()
    if not autoStatusParagraph then return end
    local parts = {}
    if AutoFarm.autoReplay then table.insert(parts, "Replay: ON") end
    if AutoFarm.autoNextStage then table.insert(parts, "Next stage: ON") end
    if AutoFarm.autoLeave then table.insert(parts, "Leave on defeat: ON") end
    if AutoFarm.leaveAtWave > 0 then table.insert(parts, "Leave at wave " .. AutoFarm.leaveAtWave) end
    if AutoFarm.autoSell and AutoFarm.sellAtWave > 0 then table.insert(parts, "Sell at wave " .. AutoFarm.sellAtWave) end
    if AutoFarm.speedMultiplier ~= 1 then table.insert(parts, string.format("Speed: %.1fx", AutoFarm.speedMultiplier)) end
    if #parts == 0 then table.insert(parts, "All off") end
    autoStatusParagraph:UpdateBody(table.concat(parts, "\n"))
end

local REPLAY_WORDS = { "replay", "retry", "play again", "restart" }
local NEXT_STAGE_WORDS = { "next stage", "next act", "next level", "next story" }
local LEAVE_WORDS = { "lobby", "leave", "return", "exit" }
-- Pages in front of the final choice (AA shows Victory -> "Next" -> Replay / Next Stage / Lobby).
local ADVANCE_WORDS = { "next", "continue", "skip" }
local ADVANCE_EXCLUDE = { "next stage", "next act", "next level", "next story", "lobby", "leave", "return", "exit" }

local endHandling = false

-- Decides what to do with this result screen; nil = leave it for the player.
local function endGoal()
    local victory = resultIsVictory()
    if AutoFarm.autoNextStage and victory then return "next_story", NEXT_STAGE_WORDS end
    if AutoFarm.autoReplay then return "replay", REPLAY_WORDS end
    if AutoFarm.autoLeave and not victory then return "leave", LEAVE_WORDS end
    return nil
end

function AutoFarmModule.OnGameEnd()
    if endHandling or State.recording or State.finalizing then return end
    local goal, words = endGoal()
    if not goal then return end
    endHandling = true
    notify("Game over: auto " .. goal .. "...")
    task.wait(1.5)

    local voteRemote = getAARemote("set_game_finished_vote")
    if voteRemote and goal ~= "leave" then
        task.spawn(function() pcall(function() voteRemote:InvokeServer(goal) end) end)
    end

    local giveUpAt = os.clock() + 45
    local advanced = 0
    while os.clock() < giveUpAt and isResultsShowing() do
        goal, words = endGoal()
        if not goal then break end
        local target = findScreenButton(words)
        if target then
            clickButton(target)
            task.wait(2)
        else
            local nextBtn = advanced < 6 and findScreenButton(ADVANCE_WORDS, ADVANCE_EXCLUDE)
            if nextBtn then
                clickButton(nextBtn)
                advanced = advanced + 1
            end
            task.wait(1)
        end
    end

    if goal == "leave" and isResultsShowing() then
        pcall(function() game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer) end)
    end
    if isResultsShowing() then
        notify("Auto " .. tostring(goal) .. ": could not find the button. Run Settings > Scan game on the result screen and send me the log.")
    end
    endHandling = false
end

-- Polls for the result screen: works even when _DATA.GameFinished does not exist.
local lastEndAttempt = 0
task.spawn(function()
    while true do
        task.wait(1)
        if (AutoFarm.autoReplay or AutoFarm.autoNextStage or AutoFarm.autoLeave)
            and not endHandling and os.clock() - lastEndAttempt > 20 and isResultsShowing() then
            lastEndAttempt = os.clock()
            task.spawn(AutoFarmModule.OnGameEnd)
        end
    end
end)

function AutoFarmModule.CheckWaveLeave()
    if AutoFarm.leaveAtWave <= 0 then return end
    local wave = getCurrentWave()
    if wave >= AutoFarm.leaveAtWave then
        PlaybackModule.Stop()
        task.wait(0.5)
        local btn = findScreenButton({ "lobby", "return", "leave" })
        if btn then
            notify("Leave at wave " .. AutoFarm.leaveAtWave .. ": leaving.")
            clickButton(btn)
        end
    end
end

function AutoFarmModule.CheckAutoSell()
    if not AutoFarm.autoSell or AutoFarm.sellAtWave <= 0 or #AutoFarm.sellUnitName < 1 then return end
    local wave = getCurrentWave()
    if wave < AutoFarm.sellAtWave then return end
    local folder = unitsFolder()
    if not folder then return end
    local targetName = string.lower(AutoFarm.sellUnitName)
    for _, unit in ipairs(folder:GetChildren()) do
        if string.lower(unit.Name):find(targetName, 1, true) and isMyUnit(unit) then
            local sellRemote = getAARemote("sell_unit_ingame")
            if sellRemote then
                pcall(function() sellRemote:InvokeServer(unit) end)
                addReplayLog("Auto sold " .. unit.Name)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- MODULE: Unit AI (Abilities, Buffs, Auto-Place)
--------------------------------------------------------------------------------
local UnitAIModule = {}

local function isGameRunning()
    if State.replaying then return true end
    local _data = workspace:FindFirstChild("_DATA")
    if _data then
        local gameStarted = _data:FindFirstChild("GameStarted")
        if gameStarted and gameStarted.Value == true then return true end
        local wave = _data:FindFirstChild("Wave") or _data:FindFirstChild("CurrentWave")
        if wave and (wave:IsA("IntValue") or wave:IsA("NumberValue")) and wave.Value > 0 then return true end
    end
    local folder = unitsFolder()
    if folder and #folder:GetChildren() > 0 then return true end
    return false
end

-- InvokeServer can hold the reply while an ability is on cooldown, so each unit
-- fires in its own thread with a busy lock; the loop itself never blocks.
local unitBusy = setmetatable({}, { __mode = "k" })
local UNIT_INVOKE_TIMEOUT = 8

local function hasActiveAttack(unit)
    local stats = unit:FindFirstChild("_stats")
    if not stats then return false end
    local id = stats:FindFirstChild("id")
    if id and tostring(id.Value) == "pucci_heaven" then return false end
    local activeAtk = stats:FindFirstChild("active_attack")
    if activeAtk and tostring(activeAtk.Value) == "nil" then return false end
    return true
end

local function inAttackState(unit)
    local stats = unit:FindFirstChild("_stats")
    local stateVal = stats and stats:FindFirstChild("state")
    return not stateVal or stateVal.Value == "attack"
end

local function fireActiveAttack(unit)
    local busyUntil = unitBusy[unit]
    if busyUntil and os.clock() < busyUntil then return end
    local remote = getAARemote("use_active_attack")
    if not remote then return end
    unitBusy[unit] = os.clock() + UNIT_INVOKE_TIMEOUT
    task.spawn(function()
        pcall(function() remote:InvokeServer(unit) end)
        unitBusy[unit] = nil
    end)
end

local function myUnitsWithAbility()
    local list = {}
    local folder = unitsFolder()
    if not folder then return list end
    for _, unit in ipairs(folder:GetChildren()) do
        if unit.Parent and isMyUnit(unit) and hasActiveAttack(unit) then
            table.insert(list, unit)
        end
    end
    return list
end

local function countMyUnits()
    local n = 0
    local folder = unitsFolder()
    if not folder then return 0 end
    for _, unit in ipairs(folder:GetChildren()) do
        if isMyUnit(unit) then n = n + 1 end
    end
    return n
end

local function refreshUnitStatus()
    if not unitStatusParagraph then return end
    local parts = {}
    if UnitAI.autoAbilities then table.insert(parts, "Abilities: ON (every " .. UnitAI.abilityCooldown .. "s)") end
    if UnitAI.autoBuff then
        local mine = countMyUnits()
        local waiting = mine < UnitAI.minUnitsForBuff and string.format(" - waiting %d/%d units", mine, UnitAI.minUnitsForBuff) or " - looping"
        table.insert(parts, "Buff loop: ON (every " .. UnitAI.buffInterval .. "s)" .. waiting)
    end
    table.insert(parts, "My units on map: " .. countMyUnits())
    unitStatusParagraph:UpdateBody(table.concat(parts, "\n"))
end

local abilityGen, buffGen = 0, 0

function UnitAIModule.StartAbilities()
    abilityGen = abilityGen + 1
    local gen = abilityGen
    task.spawn(function()
        while UnitAI.autoAbilities and gen == abilityGen do
            if isGameRunning() then
                for _, unit in ipairs(myUnitsWithAbility()) do
                    if inAttackState(unit) then fireActiveAttack(unit) end
                end
            end
            task.wait(math.max(1, UnitAI.abilityCooldown))
        end
    end)
end

function UnitAIModule.StopAbilities()
    UnitAI.autoAbilities = false
    abilityGen = abilityGen + 1
end

-- Buff units (Windsong etc.) are re-fired every tick with no attack-state check;
-- the server ignores calls during cooldown, so each buff is recast as soon as it is ready.
function UnitAIModule.StartBuff()
    buffGen = buffGen + 1
    local gen = buffGen
    task.spawn(function()
        while UnitAI.autoBuff and gen == buffGen do
            if isGameRunning() and countMyUnits() >= UnitAI.minUnitsForBuff then
                for _, unit in ipairs(myUnitsWithAbility()) do
                    fireActiveAttack(unit)
                end
            end
            task.wait(math.max(1, UnitAI.buffInterval))
        end
    end)
end

function UnitAIModule.StopBuff()
    UnitAI.autoBuff = false
    buffGen = buffGen + 1
end

--------------------------------------------------------------------------------
-- MODULE: Dungeon Bot
--------------------------------------------------------------------------------
local DungeonBotModule = {}

local function refreshDungeonStatus()
    if not dungeonStatusParagraph then return end
    local parts = { "Status: " .. DungeonBot.statusText }
    if DungeonBot.currentDepth > 0 then table.insert(parts, "Depth: " .. DungeonBot.currentDepth) end
    table.insert(parts, "Shrine: " .. (DungeonBot.shrineEnabled and "ON" or "OFF"))
    table.insert(parts, "Auto buy buffs: " .. (DungeonBot.autoBuyBuffs and "ON" or "OFF"))
    if next(DungeonBot.remoteMap) then
        table.insert(parts, "Known remotes: " .. #(DungeonBot.remoteMap or {}))
    else
        table.insert(parts, "No remotes discovered yet (run Scan or Discovery)")
    end
    dungeonStatusParagraph:UpdateBody(table.concat(parts, "\n"))
end

function DungeonBotModule.DiscoverRemotes()
    DungeonBot.statusText = "Discovering..."
    refreshDungeonStatus()
    notify("Discovery mode: scanning ReplicatedStorage for dungeon remotes.")
    local found = {}
    for _, child in ipairs(ReplicatedStorage:GetDescendants()) do
        if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
            local lower = string.lower(child.Name)
            if lower:find("dungeon") or lower:find("room") or lower:find("shop") or lower:find("depth")
                or lower:find("chest") or lower:find("shrine") or lower:find("hoard") then
                found[child.Name] = child:GetFullName()
            end
        end
    end
    DungeonBot.remoteMap = found
    saveConfig()
    local count = 0
    for _ in pairs(found) do count = count + 1 end
    DungeonBot.statusText = "Idle"
    refreshDungeonStatus()
    notify(string.format("Discovery found %d dungeon-related remotes. Saved to config.", count))
end

function DungeonBotModule.ReadRoomChoices()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return {} end
    local rooms = {}
    for _, d in ipairs(gui:GetDescendants()) do
        if (d:IsA("TextButton") or d:IsA("TextLabel") or d:IsA("Frame")) and d.Visible then
            local name = string.lower(d.Name)
            local text = d:IsA("TextButton") and string.lower(d.Text) or name
            for _, roomType in ipairs({ "shop", "hoard", "battle", "boss", "shrine", "chest" }) do
                if text:find(roomType, 1, true) or name:find(roomType, 1, true) then
                    table.insert(rooms, { type = string.upper(roomType), button = d:IsA("TextButton") and d or nil, name = d.Name })
                end
            end
        end
    end
    return rooms
end

function DungeonBotModule.PickRoom(rooms)
    if #rooms == 0 then return nil end
    local priority = DungeonBot.roomPriority
    for _, pType in ipairs(priority) do
        if not (pType == "SHRINE" and not DungeonBot.shrineEnabled) then
            for _, room in ipairs(rooms) do
                if room.type == pType then return room end
            end
        end
    end
    return rooms[1]
end

function DungeonBotModule.HandleShop()
    if not DungeonBot.autoBuyBuffs then return end
    task.wait(1)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextButton") and d.Visible then
            local lower = string.lower(d.Text)
            for _, buff in ipairs(DungeonBot.buffPriority) do
                if lower:find(string.lower(buff), 1, true) or lower:find("buy", 1, true) or lower:find("purchase", 1, true) then
                    clickButton(d)
                    task.wait(0.5)
                end
            end
        end
    end
end

function DungeonBotModule.HandleBattle()
    if #State.actions > 0 then
        PlaybackModule.Play(true)
        while State.replaying do task.wait(1) end
    end
    local deadline = os.clock() + 600
    while os.clock() < deadline and DungeonBot.enabled do
        if isGameOver() then break end
        task.wait(2)
    end
end

function DungeonBotModule.RunLoop()
    DungeonBot.dungeonActive = true
    DungeonBot.currentDepth = 0
    DungeonBot.statusText = "Running"
    refreshDungeonStatus()

    while DungeonBot.enabled and DungeonBot.dungeonActive do
        task.wait(2)
        local rooms = DungeonBotModule.ReadRoomChoices()
        if #rooms == 0 then
            if isGameOver() then
                DungeonBot.statusText = "Run ended"
                DungeonBot.dungeonActive = false
                refreshDungeonStatus()
                notify("Dungeon run ended.")
                if Webhook.notifyComplete then sendWebhook("Dungeon Complete", "Reached depth " .. DungeonBot.currentDepth) end
                break
            end
            task.wait(2)
        else
            DungeonBot.currentDepth = DungeonBot.currentDepth + 1
            local pick = DungeonBotModule.PickRoom(rooms)
            if not pick then
                DungeonBot.statusText = "No room to pick"
                refreshDungeonStatus()
                task.wait(3)
            else
                DungeonBot.statusText = "Entering " .. pick.type .. " (depth " .. DungeonBot.currentDepth .. ")"
                refreshDungeonStatus()
                notify("Dungeon depth " .. DungeonBot.currentDepth .. ": picking " .. pick.type)

                if pick.button then
                    clickButton(pick.button)
                end
                task.wait(2)

                if pick.type == "SHOP" then
                    DungeonBotModule.HandleShop()
                elseif pick.type == "BATTLE" or pick.type == "BOSS" then
                    DungeonBotModule.HandleBattle()
                elseif pick.type == "HOARD" or pick.type == "CHEST" then
                    task.wait(5)
                    local collectBtn = findScreenButton({ "collect", "claim", "open", "take" })
                    if collectBtn then clickButton(collectBtn) end
                    task.wait(2)
                elseif pick.type == "SHRINE" then
                    local acceptBtn = findScreenButton({ "accept", "yes", "confirm" })
                    if acceptBtn then clickButton(acceptBtn) end
                    task.wait(2)
                end

                local continueBtn = findScreenButton({ "continue", "next", "proceed" })
                if continueBtn then
                    clickButton(continueBtn)
                    task.wait(1)
                end
            end
        end
    end

    DungeonBot.dungeonActive = false
    DungeonBot.statusText = "Idle"
    refreshDungeonStatus()
end

function DungeonBotModule.Start()
    if DungeonBot.dungeonActive then return end
    DungeonBot.enabled = true
    task.spawn(DungeonBotModule.RunLoop)
end

function DungeonBotModule.Stop()
    DungeonBot.enabled = false
    DungeonBot.dungeonActive = false
    DungeonBot.statusText = "Stopped"
    refreshDungeonStatus()
end

--------------------------------------------------------------------------------
-- MODULE: Tools (Anti-AFK, Session Stats)
--------------------------------------------------------------------------------
local ToolsModule = {}

function ToolsModule.StartAntiAfk()
    if Tools.antiAfkConnection then return end
    Tools.antiAfkConnection = task.spawn(function()
        while Tools.antiAfk do
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            task.wait(60)
        end
        Tools.antiAfkConnection = nil
    end)
end

function ToolsModule.StopAntiAfk()
    Tools.antiAfk = false
    Tools.antiAfkConnection = nil
end

function ToolsModule.RefreshStats()
    if not statsText then return end
    local elapsed = os.clock() - Tools.sessionStartedAt
    statsText:UpdateBody(string.format(
        "Session time: %s\nTotal replays: %d\nFailed replays: %d\nTotal actions fired: %d",
        formatDuration(elapsed), Tools.totalReplays, Tools.totalFails, Tools.totalActions
    ))
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
Window = MacLib:Window({
    Title = "MACRO // LAB",
    Subtitle = "AA macro + auto farm",
    Size = UDim2.fromOffset(868, 650),
    DragStyle = 1,
    DisabledWindowControls = {},
    ShowUserInfo = false,
    Keybind = Config.Keybind,
    AcrylicBlur = false,
})

local function fitWindowToScreen()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    if viewport.X < 1 or viewport.Y < 1 then return end
    local scale = math.min(viewport.X * Config.ScreenFill / 868, viewport.Y * Config.ScreenFill / 650)
    Window:SetScale(math.clamp(scale, 0.5, 1.5))
end

local viewportConnection
local function watchCamera()
    if viewportConnection then viewportConnection:Disconnect() end
    local camera = workspace.CurrentCamera
    if camera then
        viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindowToScreen)
    end
    fitWindowToScreen()
end
watchCamera()
table.insert(State.connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))

local tabGroup = Window:TabGroup()

-- TAB 1: Macro (record / play / files)
local macroTab = tabGroup:Tab({ Name = "Macro", Image = "rbxassetid://10734950309" })

local controlSection = macroTab:Section({ Side = "Left" })
local fileSection = macroTab:Section({ Side = "Right" })

controlSection:Header({ Text = "Record & Play" })
statusParagraph = controlSection:Paragraph({ Header = "Status", Body = "" })
recordToggle = controlSection:Toggle({
    Name = "Record",
    Default = false,
    Callback = function(on)
        if syncing then return end
        if on then
            if not RecordingModule.Start() then setToggle(recordToggle, false) end
        else
            RecordingModule.Stop()
        end
    end,
}, "RecordToggle")
playToggle = controlSection:Toggle({
    Name = "Play",
    Default = false,
    Callback = function(on)
        if syncing then return end
        if on then
            if not PlaybackModule.Play(false) then setToggle(playToggle, false) end
        else
            PlaybackModule.Stop()
        end
    end,
}, "PlayToggle")
controlSection:Toggle({
    Name = "Wait for wave start (auto play)",
    Default = false,
    Callback = function(on) State.autoPlay = on end,
}, "AutoPlay")

fileSection:Header({ Text = "Macro file" })
savedDropdown = fileSection:Dropdown({
    Name = "Saved",
    Multi = false,
    Required = false,
    Options = {},
    Callback = function(selected)
        if syncing or type(selected) ~= "string" then return end
        ProfilesModule.Load(selected)
    end,
}, "SavedMacros")
nameInput = fileSection:Input({
    Name = "Name",
    Placeholder = "auto from stage",
    AcceptedCharacters = "All",
    Callback = function(text)
        if type(text) == "string" then
            State.macroName = text
            refreshStatus()
        end
    end,
}, "MacroName")
fileSection:Button({ Name = "Save", Callback = ProfilesModule.Save })
fileSection:Button({ Name = "Delete", Callback = ProfilesModule.DeleteCurrent })
fileSection:Button({ Name = "Export", Callback = ProfilesModule.Export })
fileSection:Button({ Name = "Import folder", Callback = ProfilesModule.ImportFolder })
pasteInput = fileSection:Input({
    Name = "Paste JSON",
    Placeholder = "paste here",
    AcceptedCharacters = "All",
    Callback = ProfilesModule.ImportText,
}, "PasteJSON")

-- TAB 2: Auto Farm (replay automation)
local autoTab = tabGroup:Tab({ Name = "Auto Farm", Image = "rbxassetid://10734950309" })

local autoReplaySection = autoTab:Section({ Side = "Left" })
local autoExtraSection = autoTab:Section({ Side = "Right" })

autoReplaySection:Header({ Text = "Stage automation" })
autoStatusParagraph = autoReplaySection:Paragraph({ Header = "Status", Body = "All off" })

autoReplayToggle = autoReplaySection:Toggle({
    Name = "Auto replay (same stage)",
    Default = AutoFarm.autoReplay,
    Callback = function(on) AutoFarm.autoReplay = on; refreshAutoStatus(); saveConfig() end,
}, "AutoReplay")
autoNextToggle = autoReplaySection:Toggle({
    Name = "Auto next stage (on victory)",
    Default = AutoFarm.autoNextStage,
    Callback = function(on) AutoFarm.autoNextStage = on; refreshAutoStatus(); saveConfig() end,
}, "AutoNext")
autoLeaveToggle = autoReplaySection:Toggle({
    Name = "Auto leave (on defeat)",
    Default = AutoFarm.autoLeave,
    Callback = function(on) AutoFarm.autoLeave = on; refreshAutoStatus(); saveConfig() end,
}, "AutoLeave")

autoExtraSection:Header({ Text = "Wave controls" })
Controls.leaveAtWave = autoExtraSection:Slider({
    Name = "Leave at wave (0 = off)",
    Minimum = 0,
    Maximum = 50,
    Default = AutoFarm.leaveAtWave,
    Callback = function(v) AutoFarm.leaveAtWave = v; refreshAutoStatus(); saveConfig() end,
}, "LeaveWave")
autoSellToggle = autoExtraSection:Toggle({
    Name = "Auto sell unit at wave",
    Default = AutoFarm.autoSell,
    Callback = function(on) AutoFarm.autoSell = on; refreshAutoStatus(); saveConfig() end,
}, "AutoSell")
Controls.sellAtWave = autoExtraSection:Slider({
    Name = "Sell at wave (0 = off)",
    Minimum = 0,
    Maximum = 50,
    Default = AutoFarm.sellAtWave,
    Callback = function(v) AutoFarm.sellAtWave = v; refreshAutoStatus(); saveConfig() end,
}, "SellWave")
Controls.sellUnitName = autoExtraSection:Input({
    Name = "Unit name to sell",
    Placeholder = "e.g. Farmer",
    Default = AutoFarm.sellUnitName,
    AcceptedCharacters = "All",
    Callback = function(text) AutoFarm.sellUnitName = text or ""; saveConfig() end,
}, "SellUnitName")

autoExtraSection:Header({ Text = "Playback" })
Controls.speedMultiplier = autoExtraSection:Slider({
    Name = "Speed multiplier",
    Minimum = 0.5,
    Maximum = 5,
    Default = AutoFarm.speedMultiplier,
    Precision = 1,
    Callback = function(v) AutoFarm.speedMultiplier = v; refreshAutoStatus(); saveConfig() end,
}, "SpeedMul")

-- TAB 3: Units (AI)
local unitsTab = tabGroup:Tab({ Name = "Units", Image = "rbxassetid://10734950309" })

local abilitySection = unitsTab:Section({ Side = "Left" })
local buffSection = unitsTab:Section({ Side = "Right" })

abilitySection:Header({ Text = "Auto abilities" })
unitStatusParagraph = abilitySection:Paragraph({ Header = "Status", Body = "All off" })
autoAbilitiesToggle = abilitySection:Toggle({
    Name = "Auto use unit abilities",
    Default = false,
    Callback = function(on)
        UnitAI.autoAbilities = on
        if on then UnitAIModule.StartAbilities() else UnitAIModule.StopAbilities() end
        refreshUnitStatus(); saveConfig()
    end,
}, "AutoAbilities")
Controls.abilityCooldown = abilitySection:Slider({
    Name = "Check every (seconds)",
    Minimum = 1,
    Maximum = 30,
    Default = UnitAI.abilityCooldown,
    Callback = function(v) UnitAI.abilityCooldown = v; refreshUnitStatus(); saveConfig() end,
}, "AbilityCooldown")
abilitySection:Paragraph({ Header = "", Body = "Damage abilities: fired only while the unit\nis attacking." })

buffSection:Header({ Text = "Auto buff loop" })
autoBuffToggle = buffSection:Toggle({
    Name = "Auto use buffs",
    Default = false,
    Callback = function(on)
        UnitAI.autoBuff = on
        if on then UnitAIModule.StartBuff() else UnitAIModule.StopBuff() end
        refreshUnitStatus(); saveConfig()
    end,
}, "AutoBuff")
Controls.buffInterval = buffSection:Slider({
    Name = "Check every (seconds)",
    Minimum = 1,
    Maximum = 30,
    Default = UnitAI.buffInterval,
    Callback = function(v) UnitAI.buffInterval = v; refreshUnitStatus(); saveConfig() end,
}, "BuffInterval")
Controls.minUnitsForBuff = buffSection:Slider({
    Name = "Min units before buff starts",
    Minimum = 1,
    Maximum = 10,
    Default = UnitAI.minUnitsForBuff,
    Callback = function(v) UnitAI.minUnitsForBuff = v; refreshUnitStatus(); saveConfig() end,
}, "MinUnitsForBuff")
buffSection:Paragraph({ Header = "", Body = "Every check, each of your units with a skill\nis told to cast it. Units still on cooldown\nare skipped by the game, so every buff\n(physical or magic) is recast the moment\nits own cooldown ends." })

-- TAB 4: Dungeon
local dungeonTab = tabGroup:Tab({ Name = "Dungeon", Image = "rbxassetid://10734950309" })

local dungeonMainSection = dungeonTab:Section({ Side = "Left" })
local dungeonConfigSection = dungeonTab:Section({ Side = "Right" })

dungeonMainSection:Header({ Text = "Auto dungeon run" })
dungeonStatusParagraph = dungeonMainSection:Paragraph({ Header = "Status", Body = "Idle" })
dungeonMainSection:Toggle({
    Name = "Enable dungeon bot",
    Default = false,
    Callback = function(on)
        if on then DungeonBotModule.Start() else DungeonBotModule.Stop() end
    end,
}, "DungeonBot")
dungeonMainSection:Button({ Name = "Discover remotes", Callback = DungeonBotModule.DiscoverRemotes })
dungeonMainSection:Paragraph({ Header = "", Body = "Enter a dungeon first, then press Discover\nto find dungeon-specific remotes.\nThe bot reads room choices from the GUI\nand picks rooms by priority order." })

dungeonConfigSection:Header({ Text = "Room priority" })
dungeonConfigSection:Paragraph({ Header = "", Body = "Order: SHOP > HOARD > CHEST > SHRINE > BATTLE\nShop first = stack buffs before fights.\nBoss rooms are entered when forced." })
Controls.shrineEnabled = dungeonConfigSection:Toggle({
    Name = "Allow shrine rooms",
    Default = DungeonBot.shrineEnabled,
    Callback = function(on) DungeonBot.shrineEnabled = on; refreshDungeonStatus(); saveConfig() end,
}, "Shrine")
Controls.autoBuyBuffs = dungeonConfigSection:Toggle({
    Name = "Auto buy buffs in shop",
    Default = DungeonBot.autoBuyBuffs,
    Callback = function(on) DungeonBot.autoBuyBuffs = on; refreshDungeonStatus(); saveConfig() end,
}, "AutoBuyBuffs")

-- TAB 5: Settings
local settingsTab = tabGroup:Tab({ Name = "Settings", Image = "rbxassetid://10734950309" })

local profileSection = settingsTab:Section({ Side = "Left" })
local optionsSection = settingsTab:Section({ Side = "Left" })
local webhookSection = settingsTab:Section({ Side = "Left" })
local toolsSection = settingsTab:Section({ Side = "Right" })
local logSection = settingsTab:Section({ Side = "Right" })

profileSection:Header({ Text = "Config profile" })
local profileStatus = profileSection:Paragraph({ Header = "Active profile", Body = "" })
local profileNameText = Profile.name
local profileDropdown

local function refreshProfileUI()
    pcall(function()
        profileStatus:UpdateBody((Profile.name ~= "" and Profile.name or "(none)")
            .. "\nEvery change auto-saves and is restored\nwhen you run the script again.")
    end)
    if profileDropdown then
        pcall(function()
            profileDropdown:ClearOptions()
            profileDropdown:InsertOptions(ConfigProfiles.List())
        end)
    end
end

Controls.profileName = profileSection:Input({
    Name = "Profile name",
    Placeholder = "e.g. Namak farm",
    Default = Profile.name,
    AcceptedCharacters = "All",
    Callback = function(text) profileNameText = text or "" end,
}, "ProfileName")
profileDropdown = profileSection:Dropdown({
    Name = "Saved profiles",
    Multi = false,
    Required = false,
    Options = ConfigProfiles.List(),
    Default = Profile.name ~= "" and Profile.name or nil,
    Callback = function(value)
        if type(value) == "string" then profileNameText = value end
    end,
}, "ProfileList")
profileSection:Button({
    Name = "Save profile",
    Callback = function()
        local _, msg = ConfigProfiles.Save(profileNameText)
        notify(msg); refreshProfileUI()
    end,
})
profileSection:Button({
    Name = "Load profile",
    Callback = function()
        local _, msg = ConfigProfiles.Load(profileNameText)
        notify(msg); refreshProfileUI()
    end,
})
profileSection:Button({
    Name = "Delete profile",
    Callback = function()
        local _, msg = ConfigProfiles.Delete(profileNameText)
        notify(msg); refreshProfileUI()
    end,
})

optionsSection:Header({ Text = "Macro options" })
Controls.retryPlacements = optionsSection:Toggle({
    Name = "Retry placements until money spent",
    Default = State.retryPlacements,
    Callback = function(on) State.retryPlacements = on; saveConfig() end,
}, "RetryPlacements")
Controls.showAllMacros = optionsSection:Toggle({
    Name = "Saved list: show all stages",
    Default = State.showAllMacros,
    Callback = function(on)
        State.showAllMacros = on
        refreshSavedList(cleanName(State.macroName))
        saveConfig()
    end,
}, "ShowAllMacros")
antiAfkToggle = optionsSection:Toggle({
    Name = "Anti-AFK",
    Default = false,
    Callback = function(on)
        Tools.antiAfk = on
        if on then ToolsModule.StartAntiAfk() else ToolsModule.StopAntiAfk() end
        saveConfig()
    end,
}, "AntiAfk")

webhookSection:Header({ Text = "Discord webhook" })
Controls.webhookUrl = webhookSection:Input({
    Name = "Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default = Webhook.url,
    AcceptedCharacters = "All",
    Callback = function(text) Webhook.url = text or ""; saveConfig() end,
}, "WebhookUrl")
Controls.notifyComplete = webhookSection:Toggle({
    Name = "Notify on complete",
    Default = Webhook.notifyComplete,
    Callback = function(on) Webhook.notifyComplete = on; saveConfig() end,
}, "WebhookComplete")
Controls.notifyFail = webhookSection:Toggle({
    Name = "Notify on fail",
    Default = Webhook.notifyFail,
    Callback = function(on) Webhook.notifyFail = on; saveConfig() end,
}, "WebhookFail")
webhookSection:Button({
    Name = "Test webhook",
    Callback = function() sendWebhook("Test", "Webhook is working.") ; notify("Test sent.") end,
})

toolsSection:Header({ Text = "Session stats" })
statsText = toolsSection:Paragraph({ Header = "Stats", Body = "" })
toolsSection:Button({ Name = "Refresh stats", Callback = ToolsModule.RefreshStats })

logSection:Header({ Text = "Debug" })
actionsParagraph = logSection:Paragraph({ Header = "Last actions", Body = "Nothing recorded yet." })
logSection:Button({ Name = "Copy full log", Callback = RecordingModule.CopyLog })
logSection:Button({ Name = "Scan game", Callback = Scan.Run })
logSection:Button({ Name = "Refresh saved list", Callback = function() refreshSavedList(cleanName(State.macroName)) end })

--------------------------------------------------------------------------------
-- Runtime: game start, stage detect, heartbeat, auto farm wave checks
--------------------------------------------------------------------------------
local function onGameStarted()
    if State.recording and not State.startOffset then
        State.startOffset = os.clock() - State.startedAt
    end
    if State.autoPlay and not State.recording and not State.finalizing and not State.replaying then
        if #State.actions > 0 then
            PlaybackModule.Play(true)
        else
            notify("Game started, but no macro is picked for Auto play.")
        end
    end
end

task.spawn(function()
    local dataFolder = workspace:WaitForChild("_DATA", 30)
    local started = dataFolder and dataFolder:WaitForChild("GameStarted", 30)
    if not started then return end
    table.insert(State.connections, started.Changed:Connect(function(value)
        if value == true then onGameStarted() end
    end))
    local gameFinished = dataFolder:FindFirstChild("GameFinished") or dataFolder:FindFirstChild("GameOver") or dataFolder:FindFirstChild("GameEnded")
    if gameFinished and gameFinished:IsA("BoolValue") then
        table.insert(State.connections, gameFinished.Changed:Connect(function(value)
            if value == true then
                task.delay(2, function() AutoFarmModule.OnGameEnd() end)
            end
        end))
    end
end)

task.spawn(function()
    State.stage = Stage.detect()
    refreshStatus()
    refreshSavedList()
end)

-- Heartbeat
local nextRefresh, lastListedCount = 0, -1
local nextWaveCheck = 0
table.insert(State.connections, RunService.Heartbeat:Connect(function()
    local now = os.clock()

    -- Recording heartbeat
    if State.recording or State.finalizing then
        local snap = readTracked()
        local actionCount = #State.actions
        for idx = 1, actionCount do
            local action = State.actions[idx]
            if action.spent == nil then
                if anyDecrease(action.before, snap) then
                    action.spent = true
                elseif now - action.at >= Config.VerifyWindow then
                    action.spent = false
                end
            end
        end
        State.snapshot = snap
        if State.finalizing then
            if now >= State.finalizeAt then finalizeRecording() end
            return
        end
    end

    -- UI refresh
    if now >= nextRefresh then
        nextRefresh = now + 0.5
        refreshStatus()
        if #State.actions ~= lastListedCount then
            lastListedCount = #State.actions
            refreshActionList()
        end
    end

    -- Recording limits
    if State.recording then
        if now - State.startedAt >= Config.MaxDuration then
            finishRecording("Recording stopped at the 60 minute limit.")
        elseif #State.actions >= Config.MaxActions then
            finishRecording("Recording stopped at the " .. Config.MaxActions .. " action limit.")
        end
    end

    -- Auto farm wave checks
    if State.replaying and now >= nextWaveCheck then
        nextWaveCheck = now + 2
        AutoFarmModule.CheckWaveLeave()
        AutoFarmModule.CheckAutoSell()
    end
end))

-- Cleanup
Window.onUnloaded(function()
    saveConfig()
    configReady = false
    State.recording = false
    State.finalizing = false
    State.replaying = false
    UnitAI.autoAbilities = false
    UnitAI.autoBuff = false
    Tools.antiAfk = false
    DungeonBot.enabled = false
    DungeonBot.dungeonActive = false
    for _, connection in ipairs(State.connections) do connection:Disconnect() end
    if viewportConnection then viewportConnection:Disconnect() end
    if recordUnitConnection then recordUnitConnection:Disconnect() end
    if replayUnitConnection then replayUnitConnection:Disconnect() end
end)

local function setControl(control, value)
    if not control or value == nil then return end
    if type(value) == "boolean" then
        pcall(function() setToggle(control, value) end)
    elseif type(value) == "number" then
        if not pcall(function() control:UpdateValue(value) end) then
            pcall(function() control:SetValue(value) end)
        end
    else
        if not pcall(function() control:UpdateText(value) end) then
            pcall(function() control:SetText(value) end)
        end
    end
end

-- Pushes the current state (from config.json or a loaded profile) into every
-- control and starts/stops the running features to match.
applyRuntimeFeatures = function()
    local wasReady = configReady
    configReady = false
    setControl(autoReplayToggle, AutoFarm.autoReplay)
    setControl(autoNextToggle, AutoFarm.autoNextStage)
    setControl(autoLeaveToggle, AutoFarm.autoLeave)
    setControl(autoSellToggle, AutoFarm.autoSell)
    setControl(Controls.leaveAtWave, AutoFarm.leaveAtWave)
    setControl(Controls.sellAtWave, AutoFarm.sellAtWave)
    setControl(Controls.sellUnitName, AutoFarm.sellUnitName)
    setControl(Controls.speedMultiplier, AutoFarm.speedMultiplier)
    setControl(Controls.abilityCooldown, UnitAI.abilityCooldown)
    setControl(Controls.buffInterval, UnitAI.buffInterval)
    setControl(Controls.minUnitsForBuff, UnitAI.minUnitsForBuff)
    setControl(Controls.retryPlacements, State.retryPlacements)
    setControl(Controls.showAllMacros, State.showAllMacros)
    setControl(Controls.webhookUrl, Webhook.url)
    setControl(Controls.notifyComplete, Webhook.notifyComplete)
    setControl(Controls.notifyFail, Webhook.notifyFail)
    setControl(Controls.shrineEnabled, DungeonBot.shrineEnabled)
    setControl(Controls.autoBuyBuffs, DungeonBot.autoBuyBuffs)
    setControl(Controls.profileName, Profile.name)

    UnitAI.autoAbilities = pendingToggles.autoAbilities == true
    setControl(autoAbilitiesToggle, UnitAI.autoAbilities)
    if UnitAI.autoAbilities then UnitAIModule.StartAbilities() else UnitAIModule.StopAbilities() end
    UnitAI.autoBuff = pendingToggles.autoBuff == true
    setControl(autoBuffToggle, UnitAI.autoBuff)
    if UnitAI.autoBuff then UnitAIModule.StartBuff() else UnitAIModule.StopBuff() end
    Tools.antiAfk = pendingToggles.antiAfk == true
    setControl(antiAfkToggle, Tools.antiAfk)
    if Tools.antiAfk then ToolsModule.StartAntiAfk() else ToolsModule.StopAntiAfk() end

    refreshUnitStatus()
    refreshAutoStatus()
    refreshDungeonStatus()
    refreshProfileUI()
    configReady = wasReady
end

-- Restore saved toggle states and auto-start features
task.spawn(function()
    task.wait(0.5)
    if State.macroName ~= "" then
        local ok = ProfilesModule.Load(State.macroName)
        if ok then setMacroName(State.macroName) end
    end
    applyRuntimeFeatures()
    configReady = true
    saveConfig()
    local restored = {}
    if UnitAI.autoAbilities then table.insert(restored, "Abilities") end
    if UnitAI.autoBuff then table.insert(restored, "Buff") end
    if Tools.antiAfk then table.insert(restored, "Anti-AFK") end
    if AutoFarm.autoReplay then table.insert(restored, "Auto Replay") end
    if AutoFarm.autoNextStage then table.insert(restored, "Next Stage") end
    if AutoFarm.autoLeave then table.insert(restored, "Auto Leave") end
    if #restored > 0 then
        notify("Restored: " .. table.concat(restored, ", "))
    end
end)

refreshStatus()
refreshAutoStatus()
refreshUnitStatus()
refreshDungeonStatus()
ToolsModule.RefreshStats()
macroTab:Select()
notify("Macro UI v3 loaded — 5 tabs.")
return {
    Recording = RecordingModule,
    Playback = PlaybackModule,
    Profiles = ProfilesModule,
    Scan = Scan,
    Stage = Stage,
    AutoFarm = AutoFarmModule,
    UnitAI = UnitAIModule,
    DungeonBot = DungeonBotModule,
    Tools = ToolsModule,
}
