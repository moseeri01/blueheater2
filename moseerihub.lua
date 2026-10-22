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
    abilityCooldown = 5,
    autoBuff = false,
    buffInterval = 10,
    minUnitsForBuff = 4,
    autoPlaceFollow = false,
    running = false,
    abilityConnection = nil,
    buffConnection = nil,
    placeConnection = nil,
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
local autoAbilitiesToggle, autoBuffToggle, autoPlaceToggle, antiAfkToggle
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

local function saveConfig()
    if not hasFileApi() then return end
    pcall(function()
        ensureFolder(Config.Folder)
        writefile(ConfigFile, HttpService:JSONEncode({
            webhook = { url = Webhook.url, notifyComplete = Webhook.notifyComplete, notifyFail = Webhook.notifyFail },
            dungeon = { remoteMap = DungeonBot.remoteMap, shrineEnabled = DungeonBot.shrineEnabled, autoBuyBuffs = DungeonBot.autoBuyBuffs },
            unitAI = {
                autoAbilities = UnitAI.autoAbilities,
                abilityCooldown = UnitAI.abilityCooldown,
                autoBuff = UnitAI.autoBuff,
                buffInterval = UnitAI.buffInterval,
                minUnitsForBuff = UnitAI.minUnitsForBuff,
                autoPlaceFollow = UnitAI.autoPlaceFollow,
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
            tools = {
                antiAfk = Tools.antiAfk,
            },
        }))
    end)
end

local pendingToggles = {}

local function loadConfig()
    if not hasFileApi() or not isfile(ConfigFile) then return end
    pcall(function()
        local data = HttpService:JSONDecode(readfile(ConfigFile))
        if data.webhook then
            Webhook.url = data.webhook.url or ""
            Webhook.notifyComplete = data.webhook.notifyComplete == true
            Webhook.notifyFail = data.webhook.notifyFail == true
        end
        if data.dungeon then
            if type(data.dungeon.remoteMap) == "table" then DungeonBot.remoteMap = data.dungeon.remoteMap end
            if data.dungeon.shrineEnabled ~= nil then DungeonBot.shrineEnabled = data.dungeon.shrineEnabled end
            if data.dungeon.autoBuyBuffs ~= nil then DungeonBot.autoBuyBuffs = data.dungeon.autoBuyBuffs end
        end
        if data.unitAI then
            if type(data.unitAI.abilityCooldown) == "number" then UnitAI.abilityCooldown = data.unitAI.abilityCooldown end
            if type(data.unitAI.buffInterval) == "number" then UnitAI.buffInterval = data.unitAI.buffInterval end
            if type(data.unitAI.minUnitsForBuff) == "number" then UnitAI.minUnitsForBuff = data.unitAI.minUnitsForBuff end
            if data.unitAI.autoAbilities then pendingToggles.autoAbilities = true end
            if data.unitAI.autoBuff then pendingToggles.autoBuff = true end
            if data.unitAI.autoPlaceFollow then pendingToggles.autoPlaceFollow = true end
        end
        if data.autoFarm then
            if type(data.autoFarm.speedMultiplier) == "number" then AutoFarm.speedMultiplier = data.autoFarm.speedMultiplier end
            if data.autoFarm.autoReplay then AutoFarm.autoReplay = true end
            if data.autoFarm.autoNextStage then AutoFarm.autoNextStage = true end
            if data.autoFarm.autoLeave then AutoFarm.autoLeave = true end
            if type(data.autoFarm.leaveAtWave) == "number" then AutoFarm.leaveAtWave = data.autoFarm.leaveAtWave end
            if data.autoFarm.autoSell then AutoFarm.autoSell = true end
            if type(data.autoFarm.sellAtWave) == "number" then AutoFarm.sellAtWave = data.autoFarm.sellAtWave end
            if type(data.autoFarm.sellUnitName) == "string" then AutoFarm.sellUnitName = data.autoFarm.sellUnitName end
        end
        if data.macro then
            if data.macro.retryPlacements ~= nil then State.retryPlacements = data.macro.retryPlacements end
            if data.macro.autoPlay then State.autoPlay = true end
            if data.macro.showAllMacros then State.showAllMacros = true end
            if type(data.macro.lastMacro) == "string" and #data.macro.lastMacro > 0 then
                State.macroName = data.macro.lastMacro
            end
        end
        if data.tools then
            if data.tools.antiAfk then pendingToggles.antiAfk = true end
        end
    end)
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
local function findScreenButton(keywords)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextButton") and d.Visible and d.Text ~= "" then
            local lower = string.lower(d.Text)
            for _, kw in ipairs(keywords) do
                if lower:find(kw, 1, true) then return d end
            end
        end
    end
    return nil
end

local function clickButton(btn)
    if not btn or not btn:IsA("GuiButton") then return false end
    local ok = pcall(function()
        if type(firesignal) == "function" then
            firesignal(btn.Activated)
        elseif type(fireclick) == "function" then
            fireclick(btn)
        else
            local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
        end
    end)
    return ok
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

local function isResultsShowing()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    local results = gui:FindFirstChild("ResultsUI")
    return results and results.Enabled == true
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

function AutoFarmModule.OnGameEnd()
    if State.recording or State.finalizing then return end
    task.wait(2)

    local voteRemote = getAARemote("set_game_finished_vote")

    if AutoFarm.autoLeave and not AutoFarm.autoReplay and not AutoFarm.autoNextStage then
        notify("Auto leave: returning to lobby.")
        pcall(function()
            game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer)
        end)
        return
    end

    if AutoFarm.autoNextStage then
        if voteRemote then
            notify("Auto next stage.")
            pcall(function() voteRemote:InvokeServer("next_story") end)
            return
        end
    end

    if AutoFarm.autoReplay then
        if voteRemote then
            notify("Auto replay: starting again.")
            pcall(function() voteRemote:InvokeServer("replay") end)
            return
        end
    end
end

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

local function useActiveAttack(unit)
    local stats = unit:FindFirstChild("_stats")
    if not stats then return false end
    local id = stats:FindFirstChild("id")
    local idVal = id and tostring(id.Value) or ""
    if idVal == "pucci_heaven" then return false end
    local activeAtk = stats:FindFirstChild("active_attack")
    if activeAtk and tostring(activeAtk.Value) == "nil" then return false end
    local stateVal = stats:FindFirstChild("state")
    if stateVal and stateVal.Value ~= "attack" then return false end
    local remote = getAARemote("use_active_attack")
    if not remote then return false end
    local ok = pcall(function() remote:InvokeServer(unit) end)
    return ok
end

local function refreshUnitStatus()
    if not unitStatusParagraph then return end
    local parts = {}
    if UnitAI.autoAbilities then table.insert(parts, "Abilities: ON (every " .. UnitAI.abilityCooldown .. "s)") end
    if UnitAI.autoBuff then table.insert(parts, "Buff loop: ON (every " .. UnitAI.buffInterval .. "s, min " .. UnitAI.minUnitsForBuff .. " units)") end
    if UnitAI.autoPlaceFollow then table.insert(parts, "Auto-place: ON") end
    local folder = unitsFolder()
    local unitCount = folder and #folder:GetChildren() or 0
    table.insert(parts, "Units on map: " .. unitCount)
    if #parts == 0 then table.insert(parts, "All off") end
    unitStatusParagraph:UpdateBody(table.concat(parts, "\n"))
end

function UnitAIModule.StartAbilities()
    if UnitAI.abilityConnection then return end
    UnitAI.abilityConnection = task.spawn(function()
        while UnitAI.autoAbilities do
            if isGameRunning() then
                local folder = unitsFolder()
                if folder then
                    for _, unit in ipairs(folder:GetChildren()) do
                        if not UnitAI.autoAbilities then break end
                        if isMyUnit(unit) then
                            pcall(useActiveAttack, unit)
                        end
                    end
                end
            end
            task.wait(UnitAI.abilityCooldown)
        end
        UnitAI.abilityConnection = nil
    end)
end

function UnitAIModule.StopAbilities()
    UnitAI.autoAbilities = false
    UnitAI.abilityConnection = nil
end

function UnitAIModule.StartBuff()
    if UnitAI.buffConnection then return end
    UnitAI.buffConnection = task.spawn(function()
        while UnitAI.autoBuff do
            if isGameRunning() then
                local folder = unitsFolder()
                if folder then
                    local myUnits = {}
                    for _, unit in ipairs(folder:GetChildren()) do
                        if isMyUnit(unit) then
                            table.insert(myUnits, unit)
                        end
                    end
                    if #myUnits >= UnitAI.minUnitsForBuff then
                        for _, unit in ipairs(myUnits) do
                            if not UnitAI.autoBuff then break end
                            pcall(useActiveAttack, unit)
                        end
                    end
                end
            end
            task.wait(UnitAI.buffInterval)
        end
        UnitAI.buffConnection = nil
    end)
end

function UnitAIModule.StopBuff()
    UnitAI.autoBuff = false
    UnitAI.buffConnection = nil
end

function UnitAIModule.StartAutoPlace()
    if UnitAI.placeConnection then return end
    UnitAI.placeConnection = task.spawn(function()
        while UnitAI.autoPlaceFollow do
            local spawnRemote = getAARemote("spawn_unit")
            if not spawnRemote or not isGameRunning() then
                task.wait(1)
            else
                local inventory = Players.LocalPlayer:FindFirstChild("_stats")
                local units = inventory and inventory:FindFirstChild("units")
                if units then
                    for _, child in ipairs(units:GetChildren()) do
                        if not UnitAI.autoPlaceFollow then break end
                        local uuid = child.Name
                        local bases = workspace:FindFirstChild("_BASES")
                        if bases then
                            for _, base in ipairs(bases:GetChildren()) do
                                if not base:GetAttribute("occupied") then
                                    pcall(function()
                                        local pos = base:GetPivot().Position
                                        spawnRemote:InvokeServer(uuid, CFrame.new(pos))
                                    end)
                                    task.wait(0.3)
                                    break
                                end
                            end
                        end
                    end
                end
                task.wait(2)
            end
        end
        UnitAI.placeConnection = nil
    end)
end

function UnitAIModule.StopAutoPlace()
    UnitAI.autoPlaceFollow = false
    UnitAI.placeConnection = nil
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
    Default = false,
    Callback = function(on) AutoFarm.autoReplay = on; refreshAutoStatus(); saveConfig() end,
}, "AutoReplay")
autoNextToggle = autoReplaySection:Toggle({
    Name = "Auto next stage (on victory)",
    Default = false,
    Callback = function(on) AutoFarm.autoNextStage = on; refreshAutoStatus(); saveConfig() end,
}, "AutoNext")
autoLeaveToggle = autoReplaySection:Toggle({
    Name = "Auto leave (on defeat)",
    Default = false,
    Callback = function(on) AutoFarm.autoLeave = on; refreshAutoStatus(); saveConfig() end,
}, "AutoLeave")

autoExtraSection:Header({ Text = "Wave controls" })
autoExtraSection:Slider({
    Name = "Leave at wave (0 = off)",
    Minimum = 0,
    Maximum = 50,
    Default = 0,
    Callback = function(v) AutoFarm.leaveAtWave = v; refreshAutoStatus() end,
}, "LeaveWave")
autoSellToggle = autoExtraSection:Toggle({
    Name = "Auto sell unit at wave",
    Default = false,
    Callback = function(on) AutoFarm.autoSell = on; refreshAutoStatus(); saveConfig() end,
}, "AutoSell")
autoExtraSection:Slider({
    Name = "Sell at wave (0 = off)",
    Minimum = 0,
    Maximum = 50,
    Default = 0,
    Callback = function(v) AutoFarm.sellAtWave = v; refreshAutoStatus() end,
}, "SellWave")
autoExtraSection:Input({
    Name = "Unit name to sell",
    Placeholder = "e.g. Farmer",
    AcceptedCharacters = "All",
    Callback = function(text) AutoFarm.sellUnitName = text or "" end,
}, "SellUnitName")

autoExtraSection:Header({ Text = "Playback" })
autoExtraSection:Slider({
    Name = "Speed multiplier",
    Minimum = 0.5,
    Maximum = 5,
    Default = 1,
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
abilitySection:Slider({
    Name = "Cooldown (seconds)",
    Minimum = 1,
    Maximum = 30,
    Default = 5,
    Callback = function(v) UnitAI.abilityCooldown = v; refreshUnitStatus(); saveConfig() end,
}, "AbilityCooldown")

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
buffSection:Slider({
    Name = "Buff interval (seconds)",
    Minimum = 3,
    Maximum = 60,
    Default = 10,
    Callback = function(v) UnitAI.buffInterval = v; refreshUnitStatus(); saveConfig() end,
}, "BuffInterval")
buffSection:Slider({
    Name = "Min units before buff starts",
    Minimum = 1,
    Maximum = 10,
    Default = 4,
    Callback = function(v) UnitAI.minUnitsForBuff = v; refreshUnitStatus(); saveConfig() end,
}, "MinUnitsForBuff")

buffSection:Header({ Text = "Auto place" })
buffSection:Toggle({
    Name = "Auto place on open bases",
    Default = false,
    Callback = function(on)
        UnitAI.autoPlaceFollow = on
        if on then UnitAIModule.StartAutoPlace() else UnitAIModule.StopAutoPlace() end
        refreshUnitStatus(); saveConfig()
    end,
}, "AutoPlace")
buffSection:Paragraph({ Header = "", Body = "Places units on available _BASES spots.\nRequires money + units in your inventory." })

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
dungeonConfigSection:Toggle({
    Name = "Allow shrine rooms",
    Default = false,
    Callback = function(on) DungeonBot.shrineEnabled = on; refreshDungeonStatus(); saveConfig() end,
}, "Shrine")
dungeonConfigSection:Toggle({
    Name = "Auto buy buffs in shop",
    Default = true,
    Callback = function(on) DungeonBot.autoBuyBuffs = on; refreshDungeonStatus(); saveConfig() end,
}, "AutoBuyBuffs")

-- TAB 5: Settings
local settingsTab = tabGroup:Tab({ Name = "Settings", Image = "rbxassetid://10734950309" })

local optionsSection = settingsTab:Section({ Side = "Left" })
local webhookSection = settingsTab:Section({ Side = "Left" })
local toolsSection = settingsTab:Section({ Side = "Right" })
local logSection = settingsTab:Section({ Side = "Right" })

optionsSection:Header({ Text = "Macro options" })
optionsSection:Toggle({
    Name = "Retry placements until money spent",
    Default = true,
    Callback = function(on) State.retryPlacements = on; saveConfig() end,
}, "RetryPlacements")
optionsSection:Toggle({
    Name = "Saved list: show all stages",
    Default = false,
    Callback = function(on)
        State.showAllMacros = on
        refreshSavedList(cleanName(State.macroName))
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
webhookSection:Input({
    Name = "Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    AcceptedCharacters = "All",
    Callback = function(text) Webhook.url = text or ""; saveConfig() end,
}, "WebhookUrl")
webhookSection:Toggle({
    Name = "Notify on complete",
    Default = false,
    Callback = function(on) Webhook.notifyComplete = on; saveConfig() end,
}, "WebhookComplete")
webhookSection:Toggle({
    Name = "Notify on fail",
    Default = false,
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
    State.recording = false
    State.finalizing = false
    State.replaying = false
    UnitAI.autoAbilities = false
    UnitAI.autoBuff = false
    UnitAI.autoPlaceFollow = false
    Tools.antiAfk = false
    DungeonBot.enabled = false
    DungeonBot.dungeonActive = false
    for _, connection in ipairs(State.connections) do connection:Disconnect() end
    if viewportConnection then viewportConnection:Disconnect() end
    if recordUnitConnection then recordUnitConnection:Disconnect() end
    if replayUnitConnection then replayUnitConnection:Disconnect() end
    saveConfig()
end)

-- Restore saved toggle states and auto-start features
task.spawn(function()
    task.wait(0.5)
    if State.macroName ~= "" then
        local ok = ProfilesModule.Load(State.macroName)
        if ok then setMacroName(State.macroName) end
    end
    if AutoFarm.autoReplay or AutoFarm.autoNextStage or AutoFarm.autoLeave or AutoFarm.autoSell then
        refreshAutoStatus()
    end
    if AutoFarm.autoReplay then setToggle(autoReplayToggle, true) end
    if AutoFarm.autoNextStage then setToggle(autoNextToggle, true) end
    if AutoFarm.autoLeave then setToggle(autoLeaveToggle, true) end
    if AutoFarm.autoSell then setToggle(autoSellToggle, true) end
    if pendingToggles.autoAbilities then
        UnitAI.autoAbilities = true
        setToggle(autoAbilitiesToggle, true)
        UnitAIModule.StartAbilities()
    end
    if pendingToggles.autoBuff then
        UnitAI.autoBuff = true
        setToggle(autoBuffToggle, true)
        UnitAIModule.StartBuff()
    end
    if pendingToggles.autoPlaceFollow then
        UnitAI.autoPlaceFollow = true
        UnitAIModule.StartAutoPlace()
    end
    if pendingToggles.antiAfk then
        Tools.antiAfk = true
        setToggle(antiAfkToggle, true)
        ToolsModule.StartAntiAfk()
    end
    refreshUnitStatus()
    refreshAutoStatus()
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
