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

local Words = {} -- keyword lists, grouped to stay under Lua's 200-locals limit

local Config = {
    MaxActions = 5000,
    MaxDuration = 3600,
    VerifyWindow = 1.5,
    ReplayVerifyWindow = 1.5,
    RetryInterval = 0.3,
    RetryTimeout = 180,
    MaxPlaceMisses = 8,
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
    buffGap = 0, -- seconds between casts of one buff type; 0 = cooldown / unit count
    buffDuration = 0, -- how long one buff lasts, for the coverage verdict; 0 = measure it
    minUnitsForBuff = 4,
    learned = {},
}

-- Auto Place state: places the team along the path the enemies walk.
local AutoPlace = {
    enabled = false,
    upgrade = false,
    slots = { 8, 8, 8, 8, 8, 8 }, -- how many of each team slot to place (0 = none)
    moneyPath = nil,              -- tracked value that pays for units, found on the first placement
    paths = {},                   -- [stage] = { {x,y,z}, ... } learned from enemy movement
    caps = {},                    -- [unit name] = how many the game lets you place, learned once
    roles = {},                   -- [unit name] = "farm" | "buff" | "dps", learned from placed units
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
            buffGap = UnitAI.buffGap,
            buffDuration = UnitAI.buffDuration,
            minUnitsForBuff = UnitAI.minUnitsForBuff,
            learned = next(UnitAI.learned) and UnitAI.learned or nil,
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
        autoPlace = {
            enabled = AutoPlace.enabled, upgrade = AutoPlace.upgrade, slots = AutoPlace.slots,
            moneyPath = AutoPlace.moneyPath, paths = next(AutoPlace.paths) and AutoPlace.paths or nil,
            caps = next(AutoPlace.caps) and AutoPlace.caps or nil,
            roles = next(AutoPlace.roles) and AutoPlace.roles or nil,
        },
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
    UnitAI.buffGap = pick(u.buffGap, "number", UnitAI.buffGap)
    UnitAI.buffDuration = pick(u.buffDuration, "number", UnitAI.buffDuration)
    UnitAI.minUnitsForBuff = pick(u.minUnitsForBuff, "number", UnitAI.minUnitsForBuff)
    UnitAI.learned = type(u.learned) == "table" and u.learned or {}
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
    local ap = data.autoPlace or {}
    pendingToggles.autoPlace = ap.enabled == true
    AutoPlace.upgrade = pick(ap.upgrade, "boolean", AutoPlace.upgrade)
    if type(ap.slots) == "table" then
        for i = 1, 6 do AutoPlace.slots[i] = tonumber(ap.slots[i]) or AutoPlace.slots[i] end
    end
    AutoPlace.moneyPath = pick(ap.moneyPath, "string", AutoPlace.moneyPath)
    if type(ap.paths) == "table" then AutoPlace.paths = ap.paths end
    if type(ap.caps) == "table" then AutoPlace.caps = ap.caps end
    if type(ap.roles) == "table" then AutoPlace.roles = ap.roles end
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
    local mark = ""
    if action.spent == true then
        mark = type(action.cost) == "number" and string.format(" [$%d]", math.floor(action.cost + 0.5)) or " [$]"
    end
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

-- Paths are stored relative to the local player ("LP.") so a macro works on any account.
local function trackedPath(entry)
    local ok, path = pcall(function() return entry.obj:GetFullName() end)
    if not ok or type(path) ~= "string" then return nil end
    local lpOk, lpPath = pcall(function() return Players.LocalPlayer:GetFullName() end)
    if lpOk and path:sub(1, #lpPath) == lpPath then path = "LP" .. path:sub(#lpPath + 1) end
    if entry.attr then path = path .. "@" .. entry.attr end
    return path
end

local function readCostValue(path)
    if type(path) ~= "string" then return nil end
    local instPath, attr = path:match("^(.-)@(.+)$")
    instPath = instPath or path
    local ok, value = pcall(function()
        local current
        local rest = instPath
        if instPath:sub(1, 2) == "LP" then
            current = Players.LocalPlayer
            rest = instPath:sub(3)
        else
            current = game
        end
        for segment in rest:gmatch("[^%.]+") do
            if not (current == game and segment == "game") then
                current = current:FindFirstChild(segment)
                if not current then return nil end
            end
        end
        if attr then return current:GetAttribute(attr) end
        return current.Value
    end)
    return ok and tonumber(value) or nil
end

Words.SPEND = { spawn_unit = true, upgrade_unit_ingame = true }

-- A drop in a tracked value is charged to ONE action: the earliest still-unresolved
-- spend remote (spawn/upgrade), else the earliest unresolved action. Charging every
-- nearby action made unrelated remotes look like purchases and stall replay.
-- Values that go down while no action is waiting (timers, countdowns) are not money.
local noisyTracked = {}

local function attributeSpending(prev, snap)
    if not prev then return end
    -- AA only takes money through spawn/upgrade; once those show up, nothing else is charged.
    local spendSeen, pendingSpend, pendingAny = false, nil, nil
    for _, a in ipairs(State.actions) do
        if Words.SPEND[a.name] then
            spendSeen = true
            if a.spent == nil and not pendingSpend then pendingSpend = a end
        end
        if a.spent == nil and not pendingAny then pendingAny = a end
    end
    local chosen = pendingSpend or (not spendSeen and pendingAny) or nil
    local bestIdx, bestDrop = nil, 0
    for idx, old in pairs(prev) do
        local new = snap[idx]
        if old and new and new < old - 1e-6 then
            if not chosen then
                noisyTracked[idx] = true
            elseif not noisyTracked[idx] and old - new > bestDrop then
                bestIdx, bestDrop = idx, old - new
            end
        end
    end
    if bestIdx and chosen then
        chosen.spent = true
        chosen.cost = bestDrop
        chosen.costPath = trackedPath(State.tracked[bestIdx])
    end
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
    local stats = unit:FindFirstChild("_stats")
    local base = stats and stats:FindFirstChild("base")
    if base and tostring(base.Value) == "pve" then return false end
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
local learnCapture -- set by the Unit AI module; receives remotes the game fires while learning

local function installHook()
    if hookInstalled then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        notify("This executor has no hookmetamethod/getnamecallmethod, so recording cannot work.")
        return false
    end
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        local method = getnamecallmethod()
        if (State.recording or State.learning) and (method == "FireServer" or method == "InvokeServer")
            and not (type(checkcaller) == "function" and checkcaller()) then
            local ok, className = pcall(function() return typeof(self) == "Instance" and self.ClassName end)
            if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
            if ok and (className == "RemoteEvent" or className == "RemoteFunction") and State.learning and learnCapture then
                learnCapture(self, method, table.pack(...))
            end
            if State.recording and ok and (className == "RemoteEvent" or className == "RemoteFunction") then
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
        and (action.cost == nil or (type(action.cost) == "number" and action.cost >= 0))
        and (action.costPath == nil or type(action.costPath) == "string")
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
            cost = action.spent == true and tonumber(action.cost) or nil,
            costPath = action.spent == true and action.costPath or nil,
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
    attributeSpending(State.snapshot, snap)
    local spendSeen = false
    for _, action in ipairs(State.actions) do
        if Words.SPEND[action.name] then spendSeen = true break end
    end
    for _, action in ipairs(State.actions) do
        if action.spent == nil then action.spent = false end
        if spendSeen and action.spent and not Words.SPEND[action.name] then
            action.spent, action.cost, action.costPath = false, nil, nil
        end
        action.before = nil
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
    noisyTracked = {}
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
local playGen = 0

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

local function claimSpawnedUnit(i, action, firedAt, alive)
    if action.name ~= Config.SpawnRemote then return end
    local target = actionPosition(action)
    if not target then return end
    local deadline = os.clock() + Config.UnitMatchWindow
    while alive() and os.clock() < deadline do
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

local function decreaseIgnoring(before, now, noisy)
    for i, old in pairs(before) do
        local new = now[i]
        if old and new and new < old - 1e-6 and not (noisy and noisy[i]) then return true end
    end
    return false
end

-- Macros saved without a cost: fire, and count it as bought when a tracked value drops.
-- ctx.noisy holds values seen dropping on their own (timers), which do not count.
local function fireUntilSpent(i, action, alive, ctx)
    ctx = ctx or {}
    local firstFire = os.clock()
    local giveUpAt = firstFire + Config.RetryTimeout
    local lastFire = firstFire
    while alive() do
        local before = readTracked()
        lastFire = os.clock()
        ctx.firing = true
        local fired = fireAction(i, action)
        if not fired and action.unitRefs then
            ctx.firing = false
            return false, lastFire - firstFire, lastFire
        end
        local verifyUntil = lastFire + Config.ReplayVerifyWindow
        while alive() and os.clock() < verifyUntil do
            task.wait(0.1)
            if decreaseIgnoring(before, readTracked(), ctx.noisy) then
                ctx.firing = false
                return true, lastFire - firstFire, lastFire
            end
        end
        ctx.firing = false
        if os.clock() >= giveUpAt then break end
        addReplayLog(string.format("#%d %s: money did not go down, retrying", i, action.name))
        task.wait(Config.RetryInterval)
    end
    ctx.firing = false
    return false, os.clock() - firstFire, lastFire
end

-- Macros recorded with a cost: wait until the money value reaches that cost, then fire
-- at once and confirm by the money dropping. Waits as long as the macro is playing.
local function placeWhenAffordable(i, action, alive, ctx)
    local firstFire = os.clock()
    local lastFire = firstFire
    local misses = 0
    local loggedWait = false
    while alive() do
        local money = readCostValue(action.costPath)
        if money == nil then
            return fireUntilSpent(i, action, alive, ctx)
        end
        if money + 1e-6 < action.cost then
            if not loggedWait then
                addReplayLog(string.format("#%d %s: waiting for money (%s / %s)", i, action.name,
                    tostring(math.floor(money)), tostring(math.floor(action.cost))))
                loggedWait = true
            end
            task.wait(0.05)
        else
            lastFire = os.clock()
            if not fireAction(i, action) and action.unitRefs then
                return false, lastFire - firstFire, lastFire
            end
            local verifyUntil = lastFire + Config.ReplayVerifyWindow
            while alive() and os.clock() < verifyUntil do
                local now = readCostValue(action.costPath)
                if now and now < money - 1e-6 then
                    return true, lastFire - firstFire, lastFire
                end
                task.wait(0.05)
            end
            misses = misses + 1
            if misses >= Config.MaxPlaceMisses then break end
            addReplayLog(string.format("#%d %s: money did not go down, retrying (%d/%d)", i, action.name, misses, Config.MaxPlaceMisses))
            task.wait(Config.RetryInterval)
        end
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

    playGen = playGen + 1
    local gen = playGen
    local function alive() return State.replaying and gen == playGen end

    State.replaying = true
    State.replayIndex = 0
    State.replayLog = {}
    State.replayStartedAt = os.clock()
    State.tracked = buildTracked()
    replayUnits, replayNewUnits = {}, {}
    local conn
    local folder = unitsFolder()
    if folder then
        conn = folder.ChildAdded:Connect(function(unit)
            if gen == playGen then table.insert(replayNewUnits, { unit = unit, at = os.clock() }) end
        end)
        replayUnitConnection = conn
    end
    local canRetry = State.retryPlacements and #State.tracked > 0
    local speedMul = math.max(0.1, AutoFarm.speedMultiplier)
    addReplayLog(string.format("play %s, %d actions, retry %s, speed %.1fx, %s",
        cleanName(State.macroName) or "?", #State.actions, canRetry and "on" or "off", speedMul,
        fromGameStart and "started by game start" or "started by hand"))
    setToggle(playToggle, true)
    refreshStatus()
    notify(string.format("Playing %s (%d actions).", cleanName(State.macroName) or "macro", #State.actions))

    -- Two tracks. Purchases run one after another, each the moment money allows,
    -- without waiting behind the noise remotes the client fired while the player was
    -- waiting. Everything else keeps its recorded timing; actions that point at a unit
    -- wait until the purchases before them are done and that unit is on the map.
    local actions = State.actions
    local actionCount = #actions
    local startTime = os.clock()
    local base = fromGameStart and -(State.startOffset or 0) or 0
    local failed = 0
    local purchaseDone = 0
    local lanesLeft = 2

    local function hasCost(a)
        return State.retryPlacements and a.spent == true and type(a.cost) == "number" and type(a.costPath) == "string"
    end
    local function isPurchase(a) return hasCost(a) or (canRetry and a.spent == true) end
    local function waitForRefs(a)
        if not a.unitRefs then return end
        local deadline = os.clock() + Config.UnitMatchWindow + 2
        while alive() and os.clock() < deadline do
            local ready = true
            for _, r in ipairs(a.unitRefs) do
                local u = replayUnits[r.ref]
                if not (u and u.Parent) then ready = false break end
            end
            if ready then return end
            task.wait(0.05)
        end
    end
    local function markProgress(i)
        if i > State.replayIndex then State.replayIndex = i end
        Tools.totalActions = Tools.totalActions + 1
    end

    -- Values that drop while no purchase is being fired are timers, not money.
    local ctx = { noisy = {}, firing = false }
    if canRetry then
        task.spawn(function()
            local prev = readTracked()
            while alive() do
                task.wait(0.1)
                local now = readTracked()
                if not ctx.firing then
                    for idx, old in pairs(prev) do
                        local new = now[idx]
                        if old and new and new < old - 1e-6 then ctx.noisy[idx] = true end
                    end
                end
                prev = now
            end
        end)
    end

    task.spawn(function()
        local watched = false
        for i = 1, actionCount do
            if not alive() then break end
            local a = actions[i]
            if isPurchase(a) then
                markProgress(i)
                waitForRefs(a)
                local ok, _, firedAt
                if hasCost(a) then
                    ok, _, firedAt = placeWhenAffordable(i, a, alive, ctx)
                else
                    if not watched then
                        watched = true
                        task.wait(1)
                    end
                    ok, _, firedAt = fireUntilSpent(i, a, alive, ctx)
                end
                if ok then
                    task.spawn(claimSpawnedUnit, i, a, firedAt, alive)
                elseif alive() then
                    failed = failed + 1
                    addReplayLog(string.format("#%d %s: gave up", i, a.name))
                end
            end
            purchaseDone = i
        end
        lanesLeft = lanesLeft - 1
    end)

    task.spawn(function()
        for i = 1, actionCount do
            if not alive() then break end
            local a = actions[i]
            if not isPurchase(a) then
                local waitTime = startTime + (a.t + base) / speedMul - os.clock()
                if waitTime > 0.01 then task.wait(waitTime) end
                if a.unitRefs then
                    while alive() and purchaseDone < i - 1 do task.wait(0.05) end
                    waitForRefs(a)
                end
                if not alive() then break end
                markProgress(i)
                local skillPress = a.name == "use_active_attack"
                for _, e in pairs(UnitAI.learned) do
                    if e.name == a.name then skillPress = true end
                end
                if UnitAI.autoBuff and skillPress then
                    -- skill presses recorded by hand would break the buff rotation's turn order
                    addReplayLog(string.format("#%d %s: skipped, buff rotation handles skills", i, a.name))
                else
                    local firedAt = os.clock()
                    if fireAction(i, a) then
                        task.spawn(claimSpawnedUnit, i, a, firedAt, alive)
                    else
                        failed = failed + 1
                    end
                end
            end
        end
        lanesLeft = lanesLeft - 1
    end)

    task.spawn(function()
        while lanesLeft > 0 and alive() do
            task.wait(0.1)
            refreshStatus()
        end
        if conn then conn:Disconnect() end
        if replayUnitConnection == conn then replayUnitConnection = nil end
        if gen ~= playGen then return end
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
Words.BUTTON = { "replay", "retry", "next", "lobby", "return", "leave", "victory", "defeat", "clear", "ready", "act ", "wave", "stage", "shop", "hoard", "battle", "boss", "shrine", "room", "depth" }

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
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Visible and d.Text ~= "" and matchesAny(d.Text, Words.BUTTON) then
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

Words.END = { "victory", "defeat", "game over", "waves completed", "total time" }

local function isResultsShowing()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    local results = gui:FindFirstChild("ResultsUI")
    if results and results:IsA("LayerCollector") and results.Enabled then return true end
    for _, d in ipairs(gui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text > 0 then
            local lower = string.lower(d.Text)
            for _, word in ipairs(Words.END) do
                if lower:find(word, 1, true) and isOnScreen(d) and not isOwnGui(d) then return true end
            end
        end
    end
    return false
end

local function resultIsVictory()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and string.lower(d.Text):find("victory", 1, true) and isOnScreen(d) and not isOwnGui(d) then
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
    if AutoFarm.autoLeave then table.insert(parts, "Leave when you lose: ON") end
    if AutoFarm.leaveAtWave > 0 then table.insert(parts, "Leave at wave " .. AutoFarm.leaveAtWave) end
    if AutoFarm.autoSell and AutoFarm.sellAtWave > 0 then table.insert(parts, "Sell at wave " .. AutoFarm.sellAtWave) end
    if AutoFarm.speedMultiplier ~= 1 then table.insert(parts, string.format("Speed: %.1fx", AutoFarm.speedMultiplier)) end
    if #parts == 0 then table.insert(parts, "All off") end
    autoStatusParagraph:UpdateBody(table.concat(parts, "\n"))
end

Words.REPLAY = { "replay", "retry", "play again", "restart" }
Words.NEXT_STAGE = { "next stage", "next act", "next level", "next story" }
Words.LEAVE = { "lobby", "leave", "return", "exit" }
-- Pages in front of the final choice (AA shows Victory -> "Next" -> Replay / Next Stage / Lobby).
Words.ADVANCE = { "next", "continue", "skip" }
Words.ADVANCE_EXCLUDE = { "next stage", "next act", "next level", "next story", "lobby", "leave", "return", "exit" }

local endHandling = false

-- Decides what to do with this result screen; nil = leave it for the player.
local function endGoal()
    local victory = resultIsVictory()
    if AutoFarm.autoNextStage and victory then return "next_story", Words.NEXT_STAGE end
    if AutoFarm.autoReplay then return "replay", Words.REPLAY end
    if AutoFarm.autoLeave and not victory then return "leave", Words.LEAVE end
    return nil
end

function AutoFarmModule.OnGameEnd()
    if endHandling or State.recording or State.finalizing then return end
    local goal, words = endGoal()
    if not goal then return end
    endHandling = true
    notify("Match ended: auto " .. goal .. "...")
    task.wait(1.5)

    local voteRemote = getAARemote("set_game_finished_vote")
    if voteRemote and goal ~= "leave" then
        task.spawn(function() pcall(function() voteRemote:InvokeServer(goal) end) end)
    end

    -- The goal is fixed now, while Victory/Defeat is visible: the next page of the result
    -- screen no longer shows it, and re-deciding there would turn a win into "leave".
    local giveUpAt = os.clock() + 45
    local advanced = 0
    local done = false
    while os.clock() < giveUpAt and not State.unloaded do
        if not (AutoFarm.autoReplay or AutoFarm.autoNextStage or AutoFarm.autoLeave) then break end
        local target = findScreenButton(words)
        if target then
            clickButton(target)
            task.wait(2)
            if not target.Parent or not isOnScreen(target) then
                done = true
                break
            end
        elseif isResultsShowing() then
            local nextBtn = advanced < 6 and findScreenButton(Words.ADVANCE, Words.ADVANCE_EXCLUDE)
            if nextBtn then
                clickButton(nextBtn)
                advanced = advanced + 1
            end
            task.wait(1)
        else
            task.wait(0.5)
        end
    end

    if not done and goal == "leave" then
        pcall(function() game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer) end)
        done = true
    end
    if not done then
        notify("Auto " .. tostring(goal) .. ": could not find the button. Run Settings > Scan game on the result screen and send me the log.")
    end
    endHandling = false
end

-- Polls for the result screen: works even when _DATA.GameFinished does not exist.
local lastEndAttempt = 0
task.spawn(function()
    while not State.unloaded do
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
        notify("Leave at wave " .. AutoFarm.leaveAtWave .. ": leaving.")
        local btn = findScreenButton({ "lobby", "return", "leave" })
        if btn then
            clickButton(btn)
        else
            pcall(function() game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer) end)
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

-- InvokeServer can hold the reply while an ability is on cooldown, so each call runs in
-- its own thread and the loop never blocks. A unit may have a few calls in flight: a lock
-- of one would delay the recast until the held reply came back.
local unitInFlight = setmetatable({}, { __mode = "k" })
local MAX_IN_FLIGHT = 6

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

-- What the last buff tick did, shown on the Units page so a silent failure is visible.
local BuffInfo = { at = nil, fired = 0, via = "-", reply = "-", problem = nil }

-- unitInFlight[unit] = { [callId] = startTime }. A call the game never answers stops counting
-- after 8 s; before, unanswered calls piled up and the unit was never cast again after ~6 rounds.
local IN_FLIGHT_TTL = 8
local callSeq = 0

local function sendSkill(unit, remote, method, args, n)
    local calls = unitInFlight[unit] or {}
    unitInFlight[unit] = calls
    local now, live = os.clock(), 0
    for id, started in pairs(calls) do
        if now - started > IN_FLIGHT_TTL then calls[id] = nil else live = live + 1 end
    end
    if live >= MAX_IN_FLIGHT then return false end
    callSeq = callSeq + 1
    local id = callSeq
    calls[id] = now
    task.spawn(function()
        local ok, reply = pcall(function()
            if method == "FireServer" then
                remote:FireServer(table.unpack(args, 1, n))
                return "sent"
            end
            return describeValue(remote:InvokeServer(table.unpack(args, 1, n)), 0, SHORT)
        end)
        BuffInfo.reply = ok and tostring(reply) or ("error: " .. tostring(reply))
        calls[id] = nil
    end)
    return true
end

local function fireActiveAttack(unit)
    local remote = getAARemote("use_active_attack")
    if not remote then
        BuffInfo.problem = "use_active_attack does not exist in this game - use Learn buff"
        return false
    end
    BuffInfo.via = "use_active_attack"
    return sendSkill(unit, remote, "InvokeServer", { unit }, 1)
end

-- ---------------------------------------------------------------- learned buffs
-- The player clicks a buff skill once while learning; the remote and its arguments are
-- stored per unit type and replayed for every unit of that type.
Words.LEARN_SKIP = { "upgrade", "sell", "spawn", "priority", "target", "select", "place", "vote" }

local function unitType(unit)
    local stats = unit:FindFirstChild("_stats")
    local id = stats and stats:FindFirstChild("id")
    if id and tostring(id.Value) ~= "" then return tostring(id.Value) end
    return unit.Name
end

local function ownedUnits()
    local folder = unitsFolder()
    if not folder then return {} end
    local mine, all, anyOwnerField = {}, {}, false
    for _, unit in ipairs(folder:GetChildren()) do
        local stats = unit:FindFirstChild("_stats")
        local base = stats and stats:FindFirstChild("base")
        if not (base and tostring(base.Value) == "pve") then table.insert(all, unit) end
        if stats and stats:FindFirstChild("player") then anyOwnerField = true end
        if isMyUnit(unit) then table.insert(mine, unit) end
    end
    if #mine == 0 and not anyOwnerField then return all end
    return mine
end

-- Learn internals live in their own block (Lua 5.1 allows 200 active locals per function).
do
local function unitFromArg(value)
    if typeof(value) ~= "Instance" then return nil end
    local folder = unitsFolder()
    if not folder then return nil end
    local node = value
    while node and node.Parent ~= folder do
        node = node.Parent
        if node == game or node == nil then return nil end
    end
    return node
end

local learnGen = 0

Words.LEARN_SKILL = { "attack", "abil", "skill", "buff", "ult", "enchant", "active", "cast" }
local learnFallback -- a unit remote without a skill-like name, kept in case no better one comes

local function commitLearn(c, guessed)
    State.learning = false
    learnFallback = nil
    UnitAI.learned[c.kind] = c.entry
    task.spawn(function()
        saveConfig()
        if UnitAIModule.refreshLearnedUI then UnitAIModule.refreshLearnedUI() end
        notify(string.format("Learned buff for %s (%s)%s. Every %s will now be recast.",
            c.kind, c.entry.name, guessed and " - best guess" or "", c.kind))
    end)
end

-- Called inside the namecall hook: no yielding here.
learnCapture = function(remote, method, packed)
    local name = string.lower(remote.Name)
    for _, word in ipairs(Words.LEARN_SKIP) do
        if name:find(word, 1, true) then return end
    end
    local unitArg, unit
    for j = 1, packed.n do
        local u = unitFromArg(packed[j])
        if u then unitArg, unit = j, u break end
    end
    if not unitArg then return end
    local args = {}
    for j = 1, packed.n do
        args[j] = (j == unitArg) and { _t = "unit" } or serializeValue(packed[j])
    end
    local c = {
        kind = unitType(unit),
        entry = { path = remote:GetFullName(), name = remote.Name, method = method,
            argCount = packed.n, unitArg = unitArg, args = args },
    }
    for _, word in ipairs(Words.LEARN_SKILL) do
        if name:find(word, 1, true) then
            commitLearn(c, false)
            return
        end
    end
    if not learnFallback then
        learnFallback = c
        local gen = learnGen
        task.delay(3, function()
            if State.learning and learnFallback == c and gen == learnGen then commitLearn(c, true) end
        end)
    end
end

function UnitAIModule.StartLearn()
    if not installHook() then return end
    learnGen = learnGen + 1
    local gen = learnGen
    learnFallback = nil
    State.learning = true
    notify("Learn buff: open a unit in game and click its buff skill now (30 s).")
    task.delay(30, function()
        if State.learning and gen == learnGen then
            State.learning = false
            notify("Learn buff: no skill click seen. Open the unit panel first, then press Learn, then click the skill.")
        end
    end)
end

function UnitAIModule.ForgetLearned()
    UnitAI.learned = {}
    saveConfig()
    if UnitAIModule.refreshLearnedUI then UnitAIModule.refreshLearnedUI() end
    notify("Learned buffs cleared; the buff loop uses use_active_attack again.")
end
end

local function fireLearned(unit, entry)
    local remote = resolveInstance(entry.path)
    if not remote then
        BuffInfo.problem = entry.name .. " not found any more - learn the buff again"
        return false
    end
    local n = entry.argCount or #entry.args
    local args = {}
    for j = 1, n do
        if j == entry.unitArg then args[j] = unit else args[j] = deserializeValue(entry.args[j]) end
    end
    BuffInfo.via = entry.name .. " (learned)"
    return sendSkill(unit, remote, entry.method, args, n)
end

function UnitAIModule.BuffReport()
    local lines = { "[Buff report] " .. os.date("%H:%M:%S") }
    local cts = ReplicatedStorage:FindFirstChild("endpoints")
    cts = cts and cts:FindFirstChild("client_to_server")
    if cts then
        local names = {}
        for _, r in ipairs(cts:GetChildren()) do
            local lower = string.lower(r.Name)
            for _, w in ipairs({ "attack", "abil", "skill", "buff", "ult", "enchant", "active", "auto", "toggle", "use" }) do
                if lower:find(w, 1, true) then table.insert(names, r.Name .. "(" .. r.ClassName .. ")") break end
            end
        end
        table.insert(lines, "skill-like remotes: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    else
        table.insert(lines, "ReplicatedStorage.endpoints.client_to_server: NOT FOUND")
    end
    table.insert(lines, string.format("last tick: fired %d via %s, reply %s, problem %s",
        BuffInfo.fired, BuffInfo.via, BuffInfo.reply, tostring(BuffInfo.problem)))
    for kind, e in pairs(UnitAI.learned) do
        table.insert(lines, string.format("learned %s: %s:%s arg#%d of %d", kind, e.path, e.method, e.unitArg, e.argCount or 0))
    end
    local shown = 0
    for _, unit in ipairs(ownedUnits()) do
        if shown >= 8 then break end
        shown = shown + 1
        local parts = {}
        local stats = unit:FindFirstChild("_stats")
        for _, v in ipairs(stats and stats:GetChildren() or {}) do
            local ok, val = pcall(function() return v.Value end)
            table.insert(parts, v.Name .. "=" .. (ok and clip(tostring(val), 24) or "?"))
        end
        local attrs = {}
        for k, val in pairs(unit:GetAttributes()) do table.insert(attrs, k .. "=" .. clip(tostring(val), 16)) end
        table.insert(lines, string.format("unit %s mine=%s: %s%s", unit.Name, tostring(isMyUnit(unit)),
            table.concat(parts, " "), #attrs > 0 and (" | attr " .. table.concat(attrs, " ")) or ""))
    end
    if shown == 0 then table.insert(lines, "no units of yours on the map") end
    local text = table.concat(lines, "\n")
    print(text)
    if type(setclipboard) == "function" and pcall(setclipboard, text) then
        notify("Buff report copied to clipboard - paste it to me.")
    else
        notify("Buff report printed to the console (F9).")
    end
end

-- Buff rotation. Buff units of one type (e.g. 4x Wendy, 64 s cooldown) cast ONE AT A TIME,
-- a gap apart (cooldown / count by default), so one buff is always running. Casting them
-- all together puts them on cooldown together and leaves a long gap with no buff.
local BuffRot = { groups = {}, autoActive = 0, buffUnits = 0 }
do
local function statNum(unit, name)
    local stats = unit:FindFirstChild("_stats")
    local v = stats and stats:FindFirstChild(name)
    return v and tonumber(v.Value) or nil
end

function BuffRot.isBuffUnit(unit)
    if UnitAI.learned[unitType(unit)] then return true end
    local stats = unit:FindFirstChild("_stats")
    local a = stats and stats:FindFirstChild("active_attack")
    return a ~= nil and string.lower(tostring(a.Value)):find("buff", 1, true) ~= nil
end

-- When WE last cast each unit (os.clock). The game's last_active_cast may not update for
-- every cast, so both are used: whichever is more recent wins.
local ourCast = setmetatable({}, { __mode = "k" })

-- last_active_cast is NOT compared with any clock: in the real game it runs about 7 h
-- (timezone) ahead of GetServerTimeNow, which made every unit look on cooldown forever.
-- Instead, the local moment the value CHANGES is taken as the cast time.
local seenCast = setmetatable({}, { __mode = "k" })

local function observeCast(unit)
    local v = statNum(unit, "last_active_cast")
    local s = seenCast[unit]
    if not s then
        seenCast[unit] = { value = v }
    elseif v ~= s.value then
        s.value, s.at = v, os.clock()
    end
end

-- Seconds since this unit last cast (nil = never seen casting).
local function castAge(unit)
    local age
    local s = seenCast[unit]
    if s and s.at then age = os.clock() - s.at end
    if ourCast[unit] then
        local mine = os.clock() - ourCast[unit]
        if not age or mine < age then age = mine end
    end
    return age
end

-- Seconds until this unit's skill is off cooldown (0 = ready, also when the game gives no data).
local function readyIn(unit)
    local cd = statNum(unit, "active_attack_cooldown")
    local age = castAge(unit)
    if not cd or not age then return 0 end
    return math.max(0, cd - age)
end

-- Buff effect on the team: numbers on our units that a buff changes (damage/buff multipliers).
local function effectSnapshot()
    local snap = {}
    for _, u in ipairs(ownedUnits()) do
        local stats = u:FindFirstChild("_stats")
        for _, v in ipairs(stats and stats:GetChildren() or {}) do
            local n = string.lower(v.Name)
            if (v:IsA("NumberValue") or v:IsA("IntValue"))
                and (n:find("multiplier", 1, true) or n:find("buff", 1, true) or n:find("potency", 1, true))
                and not n:find("cooldown", 1, true) then
                snap[v] = v.Value
            end
        end
    end
    return snap
end

local function effectChanged(base)
    for v, old in pairs(base) do
        if v.Parent and math.abs((tonumber(v.Value) or 0) - (tonumber(old) or 0)) > 1e-6 then return true end
    end
    return false
end

-- Measures how long one buff lasts, from the first cast of a game (team not buffed yet).
local function measureTick(g, now)
    local m = g.measure
    if not m then return end
    local changed = effectChanged(m.base)
    if changed and not m.startAt then m.startAt = now end
    if m.startAt and not changed then
        g.duration, g.durationAtLeast, g.measure = now - m.startAt, nil, nil
    elseif not m.startAt and now - m.castAt > 10 then
        g.measure, g.noEffect = nil, true
    end
end

local function cast(unit)
    local entry = UnitAI.learned[unitType(unit)]
    if entry then return fireLearned(unit, entry) end
    return fireActiveAttack(unit)
end

-- One pass over every buff type; called a few times per second.
function BuffRot.tick()
    local byType, order = {}, {}
    BuffRot.autoActive, BuffRot.buffUnits = 0, 0
    for _, unit in ipairs(ownedUnits()) do
        if BuffRot.isBuffUnit(unit) then
            local kind = unitType(unit)
            if not byType[kind] then byType[kind] = {} table.insert(order, kind) end
            table.insert(byType[kind], unit)
            BuffRot.buffUnits = BuffRot.buffUnits + 1
            if unit:GetAttribute("_auto_active") == true then BuffRot.autoActive = BuffRot.autoActive + 1 end
        end
    end
    local now = os.clock()
    for kind, g in pairs(BuffRot.groups) do
        if not byType[kind] then BuffRot.groups[kind] = nil end
    end
    for _, kind in ipairs(order) do
        local list = byType[kind]
        local g = BuffRot.groups[kind] or { nextAt = 0, ok = 0, failed = 0 }
        BuffRot.groups[kind] = g
        local cd = statNum(list[1], "active_attack_cooldown")
        g.count = #list
        g.auto = not (UnitAI.buffGap and UnitAI.buffGap > 0)
        g.gap = g.auto and ((cd and cd > 0) and (cd / #list) or 20) or UnitAI.buffGap
        g.cd = cd

        for _, unit in ipairs(list) do observeCast(unit) end
        measureTick(g, now)
        if g.pending then
            local last = statNum(g.pending.unit, "last_active_cast")
            if g.pending.before == nil or (last and last > g.pending.before + 1e-3) then
                g.pending = nil
                g.ok = g.ok + 1
            elseif now - g.pending.at > 3 then
                -- the game did not confirm; it may still have cast. Keep the turn order and
                -- the gap (firing the next unit at once is what made all of them cast together)
                g.pending = nil
                g.unconfirmed = (g.unconfirmed or 0) + 1
            end
        elseif now >= g.nextAt then
            local best, bestAge, soonest
            for _, unit in ipairs(list) do
                local wait = readyIn(unit)
                if wait <= 0 then
                    local age = castAge(unit) or math.huge
                    if not best or age > bestAge then best, bestAge = unit, age end
                elseif not soonest or wait < soonest then
                    soonest = wait
                end
            end
            g.waitReady = (not best) and soonest or nil
            if best then
                local base = (not g.duration and not g.measure and not g.noEffect and g.ok == 0) and effectSnapshot() or nil
                if cast(best) then
                    ourCast[best] = now
                    g.pending = { unit = best, at = now, before = statNum(best, "last_active_cast") }
                    g.lastCastAt = now
                    g.nextAt = now + g.gap
                    if base then g.measure = { base = base, castAt = now } end
                end
            end
        end
        if g.measure and g.measure.startAt and g.lastCastAt and g.lastCastAt > g.measure.castAt then
            -- the next cast came while the first buff was still on: it lasts at least the gap
            g.durationAtLeast, g.measure = now - g.measure.startAt, nil
        end
    end
end

-- "4 cover 75%, need 6 for 100%" from the buff length and cooldown.
function BuffRot.coverageText(g)
    local dur = (UnitAI.buffDuration and UnitAI.buffDuration > 0) and UnitAI.buffDuration or g.duration
    if not g.cd or g.cd <= 0 then return nil end
    if dur and dur > 0 then
        local cover = math.min(1, (g.count or 0) * dur / g.cd)
        local need = math.ceil(g.cd / dur - 1e-6)
        if cover >= 0.999 then
            return string.format("buff lasts %.1fs: %d keep it on 100%% of the time", dur, g.count or 0)
        end
        return string.format("Max possible %d%%: each buff lasts %.1fs, cooldown %.0fs. Place %d for 100%% (have %d)",
            math.floor(cover * 100), dur, g.cd, need, g.count or 0)
    end
    if g.durationAtLeast then return string.format("buff lasts over %.0fs: kept on 100%% of the time", g.durationAtLeast) end
    if g.noEffect then return "buff length not measurable - set 'Buff lasts' to see coverage" end
    return "measuring buff length..."
end
end

local function myUnitsWithAbility()
    local list = {}
    for _, unit in ipairs(ownedUnits()) do
        if hasActiveAttack(unit) and not (UnitAI.autoBuff and BuffRot.isBuffUnit(unit)) then
            table.insert(list, unit)
        end
    end
    return list
end

local function refreshUnitStatus()
    if not unitStatusParagraph then return end
    local parts = {}
    if UnitAI.autoAbilities then table.insert(parts, "Abilities: ON (every " .. UnitAI.abilityCooldown .. "s)") end
    if UnitAI.autoBuff then
        local mine = #ownedUnits()
        if mine < UnitAI.minUnitsForBuff then
            table.insert(parts, string.format("Buff rotation: waiting %d/%d units", mine, UnitAI.minUnitsForBuff))
        else
            table.insert(parts, "Buff rotation: running")
        end
        local kinds = {}
        for kind in pairs(BuffRot.groups) do table.insert(kinds, kind) end
        table.sort(kinds)
        for _, kind in ipairs(kinds) do
            local g = BuffRot.groups[kind]
            local nextText
            if g.waitReady then nextText = string.format("cooldown %ds", math.ceil(g.waitReady))
            else nextText = string.format("next in %ds", math.max(0, math.ceil(g.nextAt - os.clock()))) end
            table.insert(parts, string.format("%s x%d: every %.1fs%s, %s, cast %d ok%s",
                kind, g.count or 0, g.gap or 0, g.auto and " (auto)" or "", nextText, g.ok,
                (g.unconfirmed or 0) > 0 and string.format(" / %d unconfirmed", g.unconfirmed) or ""))
            local cover = BuffRot.coverageText(g)
            if cover then table.insert(parts, "  " .. cover) end
        end
        if BuffRot.autoActive > 0 then
            table.insert(parts, string.format("Problem: in-game Auto skill is ON for %d buff unit(s) - set it Off (the On/Off button next to the skill) so they take turns", BuffRot.autoActive))
        end
        if mine >= UnitAI.minUnitsForBuff and BuffRot.buffUnits == 0 then
            table.insert(parts, "Problem: no buff unit found - use Learn buff")
        end
        if BuffInfo.problem then table.insert(parts, "Problem: " .. BuffInfo.problem) end
        if BuffInfo.reply ~= "-" then table.insert(parts, "Last reply: " .. clip(BuffInfo.reply, 30)) end
    end
    table.insert(parts, "My units on map: " .. #ownedUnits())
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

function UnitAIModule.StartBuff()
    buffGen = buffGen + 1
    local gen = buffGen
    BuffRot.groups = {}
    task.spawn(function()
        while UnitAI.autoBuff and gen == buffGen do
            if isGameRunning() and #ownedUnits() >= UnitAI.minUnitsForBuff then
                BuffInfo.problem = nil
                local ok, err = pcall(BuffRot.tick)
                if not ok then BuffInfo.problem = "rotation error: " .. clip(tostring(err), 80) end
            end
            task.wait(0.25)
        end
    end)
end

function UnitAIModule.StopBuff()
    UnitAI.autoBuff = false
    buffGen = buffGen + 1
end

--------------------------------------------------------------------------------
-- MODULE: Auto Place (team units along the enemy path)
--------------------------------------------------------------------------------
-- Learns the path from where enemies walk (saved per stage), scores spots beside it by how
-- much path they cover, and places team slot 1..6 as soon as money allows. The team is read
-- fresh every game, so changing units in game needs no setup.
local AutoPlaceModule = { team = {}, status = "Off", problem = nil, placed = {}, full = {} }
do
local PATH_CELL = 2.5      -- path points closer than this are merged
local SIDE_DIST = { 5, 8 } -- how far beside the path to try
local MIN_FROM_PATH = 4    -- never closer than this to the path (that is the road)
local MIN_SPACING = 3      -- distance kept between own units
local DEFAULT_RANGE = 15
local apGen = 0
local badSpots = {}
local candidates, candidatesFor = nil, -1
local failsInRow = 0
local recentBad = {}
local unknownTries = 0

local function stageKey() return State.stage or "unknown" end

local function pathPoints()
    local key = stageKey()
    AutoPlace.paths[key] = AutoPlace.paths[key] or {}
    return AutoPlace.paths[key]
end

local function rootPos(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    if root then
        local ok, p = pcall(function() return root.Position end)
        if ok and p then return p end
    end
    local ok, pivot = pcall(function() return model:GetPivot() end)
    return ok and pivot.Position or nil
end

local function isEnemy(unit)
    local stats = unit:FindFirstChild("_stats")
    if not stats then return false end
    local base = stats:FindFirstChild("base")
    if base then return tostring(base.Value) == "pve" end
    return stats:FindFirstChild("player") == nil and unit:FindFirstChild("HumanoidRootPart") ~= nil
end

-- Adds where the enemies are now to the stage path; returns true when it grew.
local function samplePath()
    local folder = unitsFolder()
    if not folder then return false end
    local pts = pathPoints()
    local grew = false
    for _, unit in ipairs(folder:GetChildren()) do
        if #pts >= 400 then break end
        if isEnemy(unit) then
            local p = rootPos(unit)
            if p then
                local near = false
                for _, q in ipairs(pts) do
                    local dx, dz = q[1] - p.X, q[3] - p.Z
                    if dx * dx + dz * dz < PATH_CELL * PATH_CELL then near = true break end
                end
                if not near then
                    table.insert(pts, { math.floor(p.X * 2 + 0.5) / 2, math.floor(p.Y * 2 + 0.5) / 2, math.floor(p.Z * 2 + 0.5) / 2 })
                    grew = true
                end
            end
        end
    end
    return grew
end

local function groundAt(x, y, z)
    local ok, hit = pcall(function()
        local params = RaycastParams.new()
        params.FilterDescendantsInstances = { unitsFolder() }
        params.FilterType = Enum.RaycastFilterType.Exclude
        return workspace:Raycast(Vector3.new(x, y + 12, z), Vector3.new(0, -40, 0), params)
    end)
    if ok and hit then return hit.Position.Y end
    return y - 2
end

local function buildCandidates(pts)
    local list = {}
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.71, 0.71 }, { -0.71, 0.71 }, { 0.71, -0.71 }, { -0.71, -0.71 } }
    local step = math.max(1, math.floor(#pts / 120))
    for i = 1, #pts, step do
        local p = pts[i]
        for _, d in ipairs(dirs) do
            for _, dist in ipairs(SIDE_DIST) do
                local x, z = p[1] + d[1] * dist, p[3] + d[2] * dist
                local nearest, score = math.huge, 0
                for _, q in ipairs(pts) do
                    local dx, dz = q[1] - x, q[3] - z
                    local d2 = dx * dx + dz * dz
                    if d2 < nearest then nearest = d2 end
                    if d2 <= DEFAULT_RANGE * DEFAULT_RANGE then score = score + 1 end
                end
                if nearest >= MIN_FROM_PATH * MIN_FROM_PATH then
                    table.insert(list, { x = x, y = p[2], z = z, score = score })
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

local function spotKey(c) return string.format("%d,%d", math.floor(c.x + 0.5), math.floor(c.z + 0.5)) end

-- Role of a unit already on the map, from its own stats; remembered by unit name.
local function unitRole(u)
    local stats = u:FindFirstChild("_stats")
    if not stats then return "dps" end
    local id = stats:FindFirstChild("id")
    local name = id and tostring(id.Value) or u.Name
    local farm = stats:FindFirstChild("farm_amount")
    local act = stats:FindFirstChild("active_attack")
    local role = "dps"
    if farm and (tonumber(farm.Value) or 0) > 0 then
        role = "farm"
    elseif (act and string.lower(tostring(act.Value)):find("buff", 1, true)) or UnitAI.learned[name] then
        role = "buff"
    end
    if AutoPlace.roles[name] ~= role then
        AutoPlace.roles[name] = role
        saveConfig()
    end
    return role
end

local BUFF_REACH = 12

-- skip = how many good free spots to pass over (used to rotate while the price is unknown).
-- role: "farm" takes the spots that cover the least road (farms earn anywhere), "buff"
-- the spots next to the most damage units, anything else the spots covering the most road.
local function bestSpot(skip, role)
    skip = skip or 0
    local pts = pathPoints()
    if not candidates or #pts >= candidatesFor + math.max(10, math.floor(candidatesFor * 0.1)) or #pts < candidatesFor then
        candidates, candidatesFor = buildCandidates(pts), #pts
    end
    local mine, helpers = {}, {}
    for _, u in ipairs(ownedUnits()) do
        local p = rootPos(u)
        if p then
            table.insert(mine, p)
            if unitRole(u) == "dps" then table.insert(helpers, p) end
        end
    end
    local free = {}
    for _, c in ipairs(candidates) do
        if not badSpots[spotKey(c)] then
            local ok = true
            for _, p in ipairs(mine) do
                local dx, dz = p.X - c.x, p.Z - c.z
                if dx * dx + dz * dz < MIN_SPACING * MIN_SPACING then ok = false break end
            end
            if ok then table.insert(free, c) end
        end
    end
    if role == "farm" then
        return free[#free - skip]
    end
    if role == "buff" and #helpers > 0 then
        local scored = {}
        for _, c in ipairs(free) do
            local near = 0
            for _, p in ipairs(helpers) do
                local dx, dz = p.X - c.x, p.Z - c.z
                if dx * dx + dz * dz <= BUFF_REACH * BUFF_REACH then near = near + 1 end
            end
            table.insert(scored, { c = c, k = near * 100000 + c.score })
        end
        table.sort(scored, function(a, b) return a.k > b.k end)
        return scored[skip + 1] and scored[skip + 1].c
    end
    return free[skip + 1]
end

-- Team = equipped units { slot -> {uuid, name} }: from the game's own data (getgc), plus
-- any unit of ours already on the map (its _stats.uuid), so it works without getgc too.
function AutoPlaceModule.RefreshTeam()
    local team = {}
    if type(getgc) == "function" then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and rawget(v, "uuid") and rawget(v, "equipped_slot") and rawget(v, "unit_id") then
                    local slot = tonumber(rawget(v, "equipped_slot"))
                    if slot and slot >= 1 and slot <= 6 then
                        team[slot] = { uuid = tostring(rawget(v, "uuid")), name = tostring(rawget(v, "unit_id")) }
                    end
                end
            end
        end)
    end
    local known = {}
    for _, t in pairs(team) do known[(tostring(t.uuid):gsub("[{}%s]", ""))] = true end
    for _, u in ipairs(ownedUnits()) do
        local stats = u:FindFirstChild("_stats")
        local uuidVal = stats and stats:FindFirstChild("uuid")
        local uuid = uuidVal and tostring(uuidVal.Value)
        local key = uuid and (uuid:gsub("[{}%s]", ""))
        if uuid and not known[key] then
            for s = 1, 6 do
                if not team[s] then
                    local id = stats:FindFirstChild("id")
                    team[s] = { uuid = uuid, name = id and tostring(id.Value) or u.Name }
                    known[key] = true
                    break
                end
            end
        end
    end
    for s, t in pairs(team) do
        local old = AutoPlaceModule.team[s]
        if old and old.uuid == t.uuid then t.cost = old.cost end
        -- price and placement limit straight from the game's unit data, when it has them
        local def = AutoPlaceModule.UnitDef(t.name)
        if def then
            t.cost = t.cost or tonumber(def.cost)
            if not AutoPlace.caps[t.name] then
                for k, v in pairs(def) do
                    local key = string.lower(tostring(k))
                    if type(v) == "number" and v >= 1 and v <= 20 and (key:find("cap", 1, true) or key:find("limit", 1, true)) then
                        AutoPlace.caps[t.name] = v
                        break
                    end
                end
            end
        end
    end
    AutoPlaceModule.team = team
    return team
end

-- The game's unit definitions (ReplicatedStorage.src.Data.Units.*), read once.
local unitDefsCache
function AutoPlaceModule.UnitDef(name)
    if not unitDefsCache then
        unitDefsCache = {}
        pcall(function()
            local src = ReplicatedStorage:FindFirstChild("src")
            local data = src and src:FindFirstChild("Data")
            local units = data and data:FindFirstChild("Units")
            for _, m in ipairs(units and units:GetDescendants() or {}) do
                if m:IsA("ModuleScript") then
                    local ok, defs = pcall(require, m)
                    if ok and type(defs) == "table" then
                        for id, def in pairs(defs) do
                            if type(def) == "table" then unitDefsCache[tostring(id)] = def end
                        end
                    end
                end
            end
        end)
    end
    return unitDefsCache[name]
end

local function normUuid(u) return (tostring(u):gsub("[{}%s]", "")) end

local function placedOf(uuid)
    local list = {}
    local want = normUuid(uuid)
    for _, u in ipairs(ownedUnits()) do
        local stats = u:FindFirstChild("_stats")
        local v = stats and stats:FindFirstChild("uuid")
        if v and normUuid(v.Value) == want then table.insert(list, u) end
    end
    return list
end

local function numbersOnPlayer()
    local out = {}
    for _, d in ipairs(Players.LocalPlayer:GetDescendants()) do
        if d:IsA("IntValue") or d:IsA("NumberValue") then
            local path = trackedPath({ obj = d })
            if path then out[path] = tonumber(d.Value) end
        end
    end
    return out
end

-- Fires spawn_unit and waits for the unit to appear; learns its price and the money value.
local function tryPlace(t, spot)
    local remote = getAARemote("spawn_unit")
    if not remote then
        AutoPlaceModule.problem = "spawn_unit not found in this game"
        return false
    end
    local before = numbersOnPlayer()
    local count = #placedOf(t.uuid)
    local y = groundAt(spot.x, spot.y, spot.z)
    local repliedAt
    task.spawn(function()
        pcall(function() remote:InvokeServer(t.uuid, CFrame.new(spot.x, y, spot.z)) end)
        repliedAt = os.clock()
    end)
    -- Success = the unit shows up. A refusal is known once the server has answered and
    -- nothing appeared shortly after, so a refused spot costs well under a second.
    local deadline = os.clock() + 2
    while os.clock() < deadline and not (repliedAt and os.clock() - repliedAt > 0.3) do
        task.wait(0.1)
        local now = placedOf(t.uuid)
        if #now > count then
            local stats = now[#now]:FindFirstChild("_stats")
            local spent = stats and stats:FindFirstChild("total_spent")
            if spent and tonumber(spent.Value) and tonumber(spent.Value) > 0 then t.cost = tonumber(spent.Value) end
            if t.cost then
                local after = numbersOnPlayer()
                local bestPath, bestErr
                for path, old in pairs(before) do
                    local new = after[path]
                    if new and old and new < old then
                        local err = math.abs((old - new) - t.cost)
                        if not bestErr or err < bestErr then bestPath, bestErr = path, err end
                    end
                end
                if bestPath and bestErr <= math.max(1, t.cost * 0.05) and bestPath ~= AutoPlace.moneyPath then
                    AutoPlace.moneyPath = bestPath
                    saveConfig()
                end
            end
            return true
        end
    end
    return false
end

local function upgradeStep()
    local remote = getAARemote("upgrade_unit_ingame")
    if not remote then return end
    -- farms first (they pay for the rest), then damage, buffs last; lowest level first
    local RANK = { farm = 1, dps = 2, buff = 3 }
    local pick, pickLevel, pickRank
    for _, u in ipairs(ownedUnits()) do
        local stats = u:FindFirstChild("_stats")
        local lvl = stats and stats:FindFirstChild("upgrade")
        local maxLvl = stats and stats:FindFirstChild("max_upgrade")
        local level = lvl and tonumber(lvl.Value) or 0
        if not (maxLvl and tonumber(maxLvl.Value) and level >= tonumber(maxLvl.Value)) then
            local rank = RANK[unitRole(u)] or 2
            if not pick or rank < pickRank or (rank == pickRank and level < pickLevel) then
                pick, pickLevel, pickRank = u, level, rank
            end
        end
    end
    if not pick then
        AutoPlaceModule.status = "All units placed and fully upgraded"
        return
    end
    AutoPlaceModule.status = string.format("Upgrading %s (level %d)", pick.Name, pickLevel)
    pcall(function() remote:InvokeServer(pick) end)
end

-- The game shows each team slot's price on the hotbar ("800 ¥") and the cash just above it
-- ("10175¥"). Reading them means the first placement of a game needs no guessing, and a
-- "Cannot place unit here!" spot is skipped at once instead of retried.
local function parseYen(text)
    local num = tostring(text):match("^%s*([%d,]+)%s*¥%s*$")
    return num and tonumber((num:gsub(",", ""))) or nil
end

function AutoPlaceModule.ReadHud()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil, {} end
    local labels = {}
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local v = parseYen(d.Text)
            if v and isOnScreen(d) and not isOwnGui(d) then
                local p = d.AbsolutePosition
                table.insert(labels, { v = v, x = p.X, y = p.Y })
            end
        end
    end
    local rowY, rowN = nil, 0
    for _, a in ipairs(labels) do
        local n = 0
        for _, b in ipairs(labels) do if math.abs(a.y - b.y) <= 6 then n = n + 1 end end
        if n > rowN then rowY, rowN = a.y, n end
    end
    local prices, money, moneyDist = {}, nil, nil
    if rowN >= 2 then
        local row = {}
        for _, a in ipairs(labels) do if math.abs(a.y - rowY) <= 6 then table.insert(row, a) end end
        table.sort(row, function(p, q) return p.x < q.x end)
        local slots = {}
        for s in pairs(AutoPlaceModule.team) do table.insert(slots, s) end
        table.sort(slots)
        if #slots == #row then
            for i, a in ipairs(row) do prices[slots[i]] = a.v end
        end
    end
    for _, a in ipairs(labels) do
        if not (rowN >= 2 and math.abs(a.y - rowY) <= 6) then
            local dist = rowY and math.abs(rowY - a.y) or 0
            if not moneyDist or dist < moneyDist then money, moneyDist = a.v, dist end
        end
    end
    return money, prices
end

-- Why the game refused a placement, from the message it flashes on screen.
local function refusalReason()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and #d.Text > 0 and #d.Text < 60 then
            local t = string.lower(d.Text)
            local kind
            if t:find("not enough", 1, true) then kind = "money"
            elseif t:find("cannot place", 1, true) or t:find("can't place", 1, true) or t:find("invalid", 1, true) then kind = "spot"
            elseif t:find("max", 1, true) or t:find("limit", 1, true) then kind = "cap" end
            if kind and isOnScreen(d) and not isOwnGui(d) then return kind end
        end
    end
    return nil
end

-- Role of a team unit before it is placed: remembered from earlier games, else guessed from
-- the game's unit data (a farm/income number = farm, a buff skill = buff). nil = not known.
function AutoPlaceModule.RoleOf(t)
    if AutoPlace.roles[t.name] then return AutoPlace.roles[t.name] end
    if UnitAI.learned[t.name] then return "buff" end
    local def = AutoPlaceModule.UnitDef(t.name)
    if not def then return nil end
    local function hasFarm(tbl)
        for k, v in pairs(tbl) do
            local key = string.lower(tostring(k))
            if (key:find("farm", 1, true) or key:find("income", 1, true)) and ((type(v) == "number" and v > 0) or v == true) then
                return true
            end
        end
        return false
    end
    local up = def.upgrade or def.upgrades
    if hasFarm(def) or (type(up) == "table" and type(up[1]) == "table" and hasFarm(up[1])) then return "farm" end
    for k, v in pairs(def) do
        if type(v) == "string" and string.lower(tostring(k)):find("active", 1, true) and string.lower(v):find("buff", 1, true) then
            return "buff"
        end
    end
    return nil
end

-- Picks the next unit from the WHOLE team: first one cheap damage unit (to hold wave 1),
-- then every farm, then the rest spread evenly with damage before buffs.
local function chooseNext(prices)
    local list, dpsPlaced = {}, 0
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local placed = #placedOf(t.uuid)
            local role = AutoPlaceModule.RoleOf(t) or "dps"
            if role == "dps" then dpsPlaced = dpsPlaced + placed end
            local target = math.min(AutoPlace.slots[s] or 0, tonumber(AutoPlace.caps[t.name]) or 99)
            if not AutoPlaceModule.full[t.uuid] and placed < target then
                table.insert(list, { slot = s, t = t, role = role, placed = placed, target = target,
                    cost = t.cost or prices[s] or math.huge })
            end
        end
    end
    if #list == 0 then return nil end
    local function cheapest(role)
        local best
        for _, e in ipairs(list) do
            if e.role == role and (not best or e.cost < best.cost or (e.cost == best.cost and e.slot < best.slot)) then best = e end
        end
        return best
    end
    local pick = (dpsPlaced == 0 and cheapest("dps")) or cheapest("farm")
    if not pick then
        table.sort(list, function(a, b)
            local ra, rb = a.placed / math.max(1, a.target), b.placed / math.max(1, b.target)
            if math.abs(ra - rb) > 1e-6 then return ra < rb end
            if a.role ~= b.role then return a.role == "dps" end
            return a.slot < b.slot
        end)
        pick = list[1]
    end
    return pick.slot, pick.t, pick.role
end

local function tick()
    if State.replaying then AutoPlaceModule.status = "Paused while the macro plays" return 1 end
    if not isGameRunning() or isResultsShowing() then AutoPlaceModule.status = "Waiting for a game" return 1 end
    local grew = samplePath()
    if grew and #pathPoints() % 20 == 0 then saveConfig() end
    if not next(AutoPlaceModule.team) then AutoPlaceModule.RefreshTeam() end
    if not next(AutoPlaceModule.team) then
        AutoPlaceModule.problem = "team not found yet - place one unit by hand, or press Refresh team"
        return 2
    end
    if #pathPoints() < 8 then
        AutoPlaceModule.status = string.format("Learning the enemy path (%d points)", #pathPoints())
        return 0.5
    end
    if not AutoPlace.moneyPath then
        -- a recorded macro already knows which value is the money
        for _, a in ipairs(State.actions) do
            if type(a.costPath) == "string" then AutoPlace.moneyPath = a.costPath break end
        end
    end
    local hudMoney, hudPrices = AutoPlaceModule.ReadHud()
    local slot, t, role = chooseNext(hudPrices)
    if not t then
        if AutoPlace.upgrade then upgradeStep() return 1.5 end
        AutoPlaceModule.status = "Everything placed"
        return 1
    end
    local cost = t.cost or hudPrices[slot]
    local money = (AutoPlace.moneyPath and readCostValue(AutoPlace.moneyPath)) or hudMoney
    if cost and money and money < cost then
        AutoPlaceModule.status = string.format("Slot %d %s: waiting for money %d / %d", slot, t.name, math.floor(money), math.floor(cost))
        return 0.1
    end
    local unknown = not (cost and money)
    local spot = bestSpot(unknown and (unknownTries % 3) or 0, role) or bestSpot(0, role)
    if not spot then
        AutoPlaceModule.problem = "no free spot beside the path - the path may still be short"
        return 1
    end
    AutoPlaceModule.status = string.format("Slot %d %s (%s): placing", slot, t.name, role)
    if tryPlace(t, spot) then
        failsInRow, recentBad = 0, {}
        AutoPlaceModule.problem = nil
        return 0.2
    end
    local why = refusalReason()
    if why == "money" then return 0.5 end
    if why == "spot" then
        badSpots[spotKey(spot)] = true
        return 0.1
    end
    if why == "cap" then
        AutoPlaceModule.full[t.uuid] = true
        AutoPlace.caps[t.name] = #placedOf(t.uuid)
        saveConfig()
        return 0.1
    end
    if cost and money and money >= cost then
        -- enough money but refused: the spot is not allowed; several in a row = unit limit
        local key = spotKey(spot)
        badSpots[key] = true
        recentBad[#recentBad + 1] = key
        failsInRow = failsInRow + 1
        if failsInRow >= 4 then
            -- refused on 4 different spots with money in hand: this unit is at its limit,
            -- and those spots were fine for other units
            AutoPlaceModule.full[t.uuid] = true
            AutoPlace.caps[t.name] = #placedOf(t.uuid)
            saveConfig()
            for _, k in ipairs(recentBad) do badSpots[k] = nil end
            recentBad, failsInRow = {}, 0
        end
        return 0.2
    end
    -- price or money not known yet: a refusal may just mean "not enough money", so keep
    -- every spot and rotate between the top three until one placement succeeds
    unknownTries = unknownTries + 1
    return 1
end

function AutoPlaceModule.Start()
    apGen = apGen + 1
    local gen = apGen
    AutoPlaceModule.full, badSpots, failsInRow, unknownTries, recentBad = {}, {}, 0, 0, {}
    task.spawn(function()
        local lastGame
        while AutoPlace.enabled and gen == apGen and not State.unloaded do
            local data = workspace:FindFirstChild("_DATA")
            local started = data and data:FindFirstChild("GameStarted")
            local gameNow = started and started.Value
            if gameNow and not lastGame then
                AutoPlaceModule.full, badSpots, failsInRow, unknownTries, recentBad = {}, {}, 0, 0, {}
                AutoPlaceModule.RefreshTeam()
            end
            lastGame = gameNow
            local ok, waitFor = pcall(tick)
            if not ok then
                AutoPlaceModule.problem = "error: " .. clip(tostring(waitFor), 60)
                waitFor = 2
            end
            task.wait(waitFor or 1)
        end
    end)
end

function AutoPlaceModule.Stop()
    AutoPlace.enabled = false
    apGen = apGen + 1
    AutoPlaceModule.status = "Off"
end

function AutoPlaceModule.ForgetPath()
    AutoPlace.paths[stageKey()] = nil
    AutoPlace.caps = {}
    candidates, candidatesFor = nil, -1
    badSpots = {}
    saveConfig()
    notify("Saved enemy path for " .. stageKey() .. " and unit limits cleared.")
end

function AutoPlaceModule.StatusText()
    local lines = { "Status: " .. AutoPlaceModule.status }
    local team = {}
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local cap = tonumber(AutoPlace.caps[t.name])
            local target = math.min(AutoPlace.slots[s] or 0, cap or 99)
            local full = (cap and target == cap) and " (limit)" or ""
            local role = AutoPlaceModule.RoleOf(t)
            table.insert(team, string.format("%d %s%s %d/%d%s", s, t.name, role and ("[" .. role .. "]") or "",
                #placedOf(t.uuid), target, full))
        end
    end
    table.insert(lines, "Team: " .. (#team > 0 and table.concat(team, ", ") or "not read yet"))
    table.insert(lines, string.format("Path: %d points for %s", #pathPoints(), stageKey()))
    if AutoPlaceModule.problem then table.insert(lines, "Problem: " .. AutoPlaceModule.problem) end
    return table.concat(lines, "\n")
end

function AutoPlaceModule.MapReport()
    local lines = { "[Map report] " .. os.date("%H:%M:%S") .. " stage " .. stageKey() }
    table.insert(lines, "getgc: " .. tostring(type(getgc) == "function") .. ", Raycast: " .. tostring(pcall(function() return RaycastParams.new() end)))
    AutoPlaceModule.RefreshTeam()
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then table.insert(lines, string.format("slot %d: %s uuid %s cost %s", s, t.name, clip(t.uuid, 14), tostring(t.cost))) end
    end
    table.insert(lines, "money value: " .. tostring(AutoPlace.moneyPath) .. " = " .. tostring(AutoPlace.moneyPath and readCostValue(AutoPlace.moneyPath)))
    local top = {}
    for _, c in ipairs(workspace:GetChildren()) do table.insert(top, c.Name) end
    table.insert(lines, "workspace: " .. clip(table.concat(top, ", "), 400))
    local bases = workspace:FindFirstChild("_BASES")
    if bases then
        local names = {}
        for _, d in ipairs(bases:GetDescendants()) do
            if #names >= 20 then break end
            table.insert(names, (d:GetFullName():gsub("^Workspace%._BASES%.", "")))
        end
        table.insert(lines, "_BASES: " .. table.concat(names, ", "))
    end
    local enemies, sample = 0, nil
    local folder = unitsFolder()
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(u) then
            enemies = enemies + 1
            if not sample then
                local p = rootPos(u)
                local stats = u:FindFirstChild("_stats")
                local bend = stats and stats:FindFirstChild("last_reached_bend")
                sample = string.format("%s at %s bend %s", u.Name, p and string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) or "?", bend and tostring(bend.Value) or "?")
            end
        end
    end
    table.insert(lines, string.format("enemies now: %d %s", enemies, sample or ""))
    table.insert(lines, string.format("path points: %d", #pathPoints()))
    local spot = #pathPoints() >= 8 and bestSpot()
    if spot then table.insert(lines, string.format("best spot: (%.1f, %.1f, %.1f) covers %d path points", spot.x, spot.y, spot.z, spot.score)) end

    local hudMoney, hudPrices = AutoPlaceModule.ReadHud()
    local priceText = {}
    for s = 1, 6 do if hudPrices[s] then table.insert(priceText, s .. "=" .. hudPrices[s]) end end
    table.insert(lines, string.format("screen: money %s, hotbar prices %s", tostring(hudMoney), table.concat(priceText, " ")))

    -- The game's own unit definitions: price, limit, farm, hill/ground, buff numbers.
    local src = ReplicatedStorage:FindFirstChild("src")
    local data = src and src:FindFirstChild("Data")
    local unitsData = data and data:FindFirstChild("Units")
    table.insert(lines, "src.Data.Units: " .. (unitsData and unitsData:GetFullName() or "not found"))
    if unitsData then
        local wanted = {}
        for s = 1, 6 do
            local t = AutoPlaceModule.team[s]
            if t then wanted[t.name] = s end
        end
        local function short(v)
            if type(v) == "table" then
                local keys, n = {}, 0
                for k in pairs(v) do
                    n = n + 1
                    if #keys < 6 then table.insert(keys, tostring(k)) end
                end
                return "{" .. n .. ": " .. table.concat(keys, ",") .. "}"
            end
            return clip(tostring(v), 30)
        end
        for _, m in ipairs(unitsData:GetDescendants()) do
            if not next(wanted) then break end
            if m:IsA("ModuleScript") then
                local ok, defs = pcall(require, m)
                if ok and type(defs) == "table" then
                    for id, def in pairs(defs) do
                        if wanted[id] and type(def) == "table" then
                            local parts = {}
                            for k, v in pairs(def) do table.insert(parts, tostring(k) .. "=" .. short(v)) end
                            table.sort(parts)
                            local up = def.upgrade or def.upgrades
                            if type(up) == "table" and type(up[1]) == "table" then
                                local first = {}
                                for k, v in pairs(up[1]) do table.insert(first, tostring(k) .. "=" .. short(v)) end
                                table.sort(first)
                                table.insert(parts, "upgrade[1]: " .. table.concat(first, " "))
                            end
                            table.insert(lines, string.format("data slot %d %s (%s): %s", wanted[id], id, m.Name, clip(table.concat(parts, " "), 1200)))
                            wanted[id] = nil
                        end
                    end
                end
            end
        end
        for id in pairs(wanted) do table.insert(lines, "data for " .. id .. ": not found") end
    end

    -- What each of our units shows over its head (buff %) and its buff-related numbers.
    for _, u in ipairs(ownedUnits()) do
        local texts = {}
        for _, d in ipairs(u:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text > 0 then
                table.insert(texts, clip(d.Text, 16))
            end
        end
        local nums = {}
        local stats = u:FindFirstChild("_stats")
        for _, v in ipairs(stats and stats:GetChildren() or {}) do
            local n = string.lower(v.Name)
            if n:find("buff", 1, true) or n:find("multiplier", 1, true) or n:find("active", 1, true) then
                local ok, val = pcall(function() return v.Value end)
                table.insert(nums, v.Name .. "=" .. (ok and clip(tostring(val), 14) or "?"))
            end
        end
        table.insert(lines, string.format("unit %s labels [%s] %s", u.Name, table.concat(texts, " | "), table.concat(nums, " ")))
    end

    local text = table.concat(lines, "\n")
    print(text)
    if type(setclipboard) == "function" and pcall(setclipboard, text) then
        notify("Game data report copied to clipboard - paste it to me.")
    else
        notify("Game data report printed to the console (F9).")
    end
end
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

local antiAfkGen = 0

function ToolsModule.StartAntiAfk()
    antiAfkGen = antiAfkGen + 1
    local gen = antiAfkGen
    task.spawn(function()
        while Tools.antiAfk and gen == antiAfkGen do
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            task.wait(60)
        end
    end)
end

function ToolsModule.StopAntiAfk()
    Tools.antiAfk = false
    antiAfkGen = antiAfkGen + 1
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
-- Each tab is built inside its own do-block: Lua 5.1 allows only 200 active locals per
-- function, and the section variables are not needed once a tab is built.
local macroTab, refreshProfileUI

-- TAB 1: Macro (record / play / files)
do
macroTab = tabGroup:Tab({ Name = "Macro", Image = "rbxassetid://10734950309" })

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
Controls.autoPlay = controlSection:Toggle({
    Name = "Wait for wave start (auto play)",
    Default = State.autoPlay,
    Callback = function(on) State.autoPlay = on; saveConfig() end,
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

end

-- TAB 2: Auto Farm (replay automation)
do
local autoTab = tabGroup:Tab({ Name = "Auto Farm", Image = "rbxassetid://10734950309" })
AutoPlaceModule.farmTab = autoTab -- Auto Place sections are added to this tab further down

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
    Name = "Auto leave (when you lose)",
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

end

-- TAB 3: Units (AI)
do
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

buffSection:Header({ Text = "Buff rotation" })
autoBuffToggle = buffSection:Toggle({
    Name = "Auto use buffs",
    Default = false,
    Callback = function(on)
        UnitAI.autoBuff = on
        if on then UnitAIModule.StartBuff() else UnitAIModule.StopBuff() end
        refreshUnitStatus(); saveConfig()
    end,
}, "AutoBuff")
Controls.buffGap = buffSection:Slider({
    Name = "Gap between casts (0 = auto)",
    Minimum = 0,
    Maximum = 60,
    Default = UnitAI.buffGap,
    Callback = function(v) UnitAI.buffGap = v; refreshUnitStatus(); saveConfig() end,
}, "BuffGap")
Controls.buffDuration = buffSection:Slider({
    Name = "Buff lasts (s, 0 = measure)",
    Minimum = 0,
    Maximum = 60,
    Default = UnitAI.buffDuration,
    Callback = function(v) UnitAI.buffDuration = v; refreshUnitStatus(); saveConfig() end,
}, "BuffDuration")
Controls.minUnitsForBuff = buffSection:Slider({
    Name = "Min units before buff starts",
    Minimum = 1,
    Maximum = 10,
    Default = UnitAI.minUnitsForBuff,
    Callback = function(v) UnitAI.minUnitsForBuff = v; refreshUnitStatus(); saveConfig() end,
}, "MinUnitsForBuff")
buffSection:Paragraph({ Header = "", Body = "Buff units of the same type cast one at a\ntime, a gap apart, so one buff is always on.\nAuto gap = cooldown / number of that unit\n(4 Wendy, 64 s cooldown -> every 16 s).\nSet the in-game Auto skill button to Off\nfor buff units, or they all cast together." })

buffSection:Header({ Text = "Learn buff (if the loop does nothing)" })
local learnedParagraph = buffSection:Paragraph({ Header = "Learned", Body = "" })
local function refreshLearnedUI()
    local kinds = {}
    for kind, e in pairs(UnitAI.learned) do table.insert(kinds, kind .. "  (" .. e.name .. ")") end
    table.sort(kinds)
    pcall(function()
        learnedParagraph:UpdateBody(#kinds > 0 and table.concat(kinds, "\n")
            or "Nothing yet - the loop uses use_active_attack.")
    end)
end
UnitAIModule.refreshLearnedUI = refreshLearnedUI
refreshLearnedUI()
buffSection:Button({ Name = "Learn buff (then click the skill)", Callback = UnitAIModule.StartLearn })
buffSection:Paragraph({ Header = "", Body = "1. Click a buff unit (e.g. Windsong) in game.\n2. Press Learn buff.\n3. Click its skill (e.g. Sky Enchantment).\nRepeat for each buff unit type." })
buffSection:Button({ Name = "Forget learned buffs", Callback = UnitAIModule.ForgetLearned })
buffSection:Button({ Name = "Copy buff report", Callback = UnitAIModule.BuffReport })

end

-- Auto Place: sections on the Auto Farm tab (below the stage automation ones)
do
local placeTab = AutoPlaceModule.farmTab
local placeMain = placeTab:Section({ Side = "Left" })
local placeSlots = placeTab:Section({ Side = "Right" })

placeMain:Header({ Text = "Auto place along the enemy path" })
local placeStatus = placeMain:Paragraph({ Header = "Status", Body = "Off" })
AutoPlaceModule.refreshUI = function()
    pcall(function() placeStatus:UpdateBody(AutoPlaceModule.StatusText()) end)
end
Controls.autoPlace = placeMain:Toggle({
    Name = "Auto place units",
    Default = false,
    Callback = function(on)
        AutoPlace.enabled = on
        if on then AutoPlaceModule.Start() else AutoPlaceModule.Stop() end
        AutoPlaceModule.refreshUI(); saveConfig()
    end,
}, "AutoPlace")
Controls.autoPlaceUpgrade = placeMain:Toggle({
    Name = "Upgrade after everything is placed",
    Default = AutoPlace.upgrade,
    Callback = function(on) AutoPlace.upgrade = on; saveConfig() end,
}, "AutoPlaceUpgrade")
placeMain:Button({ Name = "Refresh team", Callback = function() AutoPlaceModule.RefreshTeam(); AutoPlaceModule.refreshUI() end })
placeMain:Button({ Name = "Forget path and unit limits", Callback = function() AutoPlaceModule.ForgetPath(); AutoPlaceModule.refreshUI() end })
placeMain:Button({ Name = "Copy game data report", Callback = AutoPlaceModule.MapReport })
placeMain:Paragraph({ Header = "", Body = "Watches where enemies walk (saved per stage),\nthen places your team beside the path where\nit covers the most road, as soon as money\nallows. Uses whatever team you have equipped." })

placeSlots:Header({ Text = "How many per team slot (0 = none)" })
Controls.placeSlots = {}
for s = 1, 6 do
    Controls.placeSlots[s] = placeSlots:Slider({
        Name = "Slot " .. s,
        Minimum = 0,
        Maximum = 8,
        Default = AutoPlace.slots[s] or 0,
        Callback = function(v) AutoPlace.slots[s] = v; saveConfig() end,
    }, "PlaceSlot" .. s)
end
placeSlots:Paragraph({ Header = "", Body = "Slots follow your in-game team order and are\nfilled from slot 1 down. 8 = as many as the\ngame allows. Buff units placed here join the\nbuff rotation on the Units page." })
end

-- TAB 4: Dungeon
do
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

end

-- TAB 5: Settings
do
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

refreshProfileUI = function()
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
end

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
        attributeSpending(State.snapshot, snap)
        for _, action in ipairs(State.actions) do
            if action.spent == nil and now - action.at >= Config.VerifyWindow then
                action.spent = false
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
        if UnitAI.autoBuff or UnitAI.autoAbilities then refreshUnitStatus() end
        if AutoPlace.enabled and AutoPlaceModule.refreshUI then AutoPlaceModule.refreshUI() end
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
        if isResultsShowing() then
            addReplayLog("result screen shown, stopping playback")
            PlaybackModule.Stop()
        else
            task.spawn(AutoFarmModule.CheckWaveLeave)
            AutoFarmModule.CheckAutoSell()
        end
    end
end))

-- Cleanup: runs once, when the window closes or when the script is run again.
local function shutdown()
    if State.unloaded then return end
    saveConfig()
    configReady = false
    State.unloaded = true
    State.recording = false
    State.finalizing = false
    State.replaying = false
    UnitAI.autoAbilities = false
    UnitAI.autoBuff = false
    Tools.antiAfk = false
    AutoPlace.enabled = false
    DungeonBot.enabled = false
    DungeonBot.dungeonActive = false
    for _, connection in ipairs(State.connections) do connection:Disconnect() end
    if viewportConnection then viewportConnection:Disconnect() end
    if recordUnitConnection then recordUnitConnection:Disconnect() end
    if replayUnitConnection then replayUnitConnection:Disconnect() end
    AutoFarm.autoReplay, AutoFarm.autoNextStage, AutoFarm.autoLeave = false, false, false
end
Window.onUnloaded(shutdown)

-- Running the script again closes the copy that is already running, so two copies
-- never click the result screen or fire abilities at the same time.
do
    local env = (type(getgenv) == "function" and getgenv()) or _G
    if type(env.__MacroLabShutdown) == "function" then pcall(env.__MacroLabShutdown) end
    env.__MacroLabShutdown = function()
        if not pcall(function() Window:Unload() end) then shutdown() end
        shutdown()
    end
end

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
    setControl(Controls.buffGap, UnitAI.buffGap)
    setControl(Controls.buffDuration, UnitAI.buffDuration)
    setControl(Controls.minUnitsForBuff, UnitAI.minUnitsForBuff)
    setControl(Controls.autoPlay, State.autoPlay)
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
    setControl(Controls.autoPlaceUpgrade, AutoPlace.upgrade)
    for s = 1, 6 do setControl(Controls.placeSlots and Controls.placeSlots[s], AutoPlace.slots[s]) end
    AutoPlace.enabled = pendingToggles.autoPlace == true
    setControl(Controls.autoPlace, AutoPlace.enabled)
    if AutoPlace.enabled then AutoPlaceModule.Start() else AutoPlaceModule.Stop() end

    refreshUnitStatus()
    refreshAutoStatus()
    refreshDungeonStatus()
    refreshProfileUI()
    configReady = wasReady
end

-- Restore saved toggle states and auto-start features (right away, so nothing the
-- player clicks in the first moments gets overwritten by the restore).
task.spawn(function()
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
    if AutoPlace.enabled then table.insert(restored, "Auto Place") end
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
