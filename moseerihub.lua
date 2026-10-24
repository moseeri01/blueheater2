-- moseeri hub: MacLib macro UI for Anime Adventures (v3 — full feature build).
-- Core: __namecall hook recorder, money-filtered replay, unit linking.
-- Tabs: Home | Lobby | Dungeon | Event | Macro | Advanced | Settings

local ok_maclib, MacLib = pcall(function()
    return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok_maclib or not MacLib then
    warn("[moseeri hub] MacLib failed to load: " .. tostring(MacLib))
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
    autoStart = false, -- vote to start the match as soon as the stage loads
    autoSkip = false,  -- vote to skip waves
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
    upgrade = true,               -- "Auto upgrade": every upgrade (farms, damage) is done by Auto Place
    slots = { 8, 8, 8, 8, 8, 8 }, -- how many of each team slot to place (0 = none, old configs: see skip)
    skip = {},                    -- [unit name] = true: never placed ("Skip these units")
    homeKeep = nil,               -- the switches as they were before Home AUTO went on (back when it goes off)
    moneyPath = nil,              -- tracked value that pays for units, found on the first placement
    paths = {},                   -- [stage] = { {x,y,z}, ... } learned from enemy movement
    caps = {},                    -- [unit name] = how many the game lets you place, learned once
    roles = {},                   -- [unit name] = "farm" | "buff" | "dps", learned from placed units
    unitInfo = {},                -- [unit uuid] = { name, traits = "golden,...", rolls } read from game data
    stageLosses = {},             -- [stage] = recent losses there (each win takes one off): play safer
    preset = "Custom",            -- last preset picked ("Fast farm" / "Safe"); Custom = set by hand
    showDetails = false,          -- full Auto Place status (team, ranking, 6 actions) instead of the short one
    placeMode = "Balanced",       -- damage units: "Safe" near our base, "Fast clear" near the enemy spawn
    lastTeam = {},                -- [slot] = { uuid, name } last read from game data (used when it is not readable)
    smartFreeze = true,           -- freeze skills (Shadowgirl timestop) only at the best moment
    sellFarmsLast = true,         -- sell farm units on the last wave and spend the yen on damage
    autoTarget = true,            -- damage units target "first", single-target ones "strongest" while a boss is out
    priorityMethod = nil,         -- how change_priority worked last time: "direct" | "capital" | "cycle"
    hillBy = {},                  -- [stage] = "height" (spots above the road took hill units) | "name" (only parts named hill/cliff/...)
}

-- Dungeon Run state (settings saved in config.json "dungeon"; Auto dungeon is never restored on)
local DungeonRun = {
    enabled = false,
    roomPriority = "HOARD > CHEST > SHOP > BATTLE > SHRINE",
    wishList = "",            -- shop items to buy, by name; empty = buy nothing
    acceptShrines = false,
    openRareAtEnd = true,
    autoContinueDeath = false,
    status = "Off",
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

-- Lobby tab (Auto join, Portals, Bag cleaner, Eggs and rewards). Phase 1: the settings and
-- Watch, which writes every remote the player fires to AAMacro/lobby_watch.txt, so the real
-- calls (and their arguments) are known before anything is automated.
local Lobby = {
    cfg = { autoJoin = false, mode = "Story", world = "", act = "1", difficulty = "Normal", joinFriends = false,
        usePortals = false, portal = "", portalTier = "1", portalFriends = false,
        clean = false, deletePortals = {}, deleteItems = {}, cleanAt = 90, cleanInStage = false,
        openEggs = false, eggs = {}, claim = false, towerRoom = 0, challenges = {}, watch = false,
        watchNoPause = false, eventCards = false, cardMode = "Most coins", voteWay = "", eventSpells = false, spellWay = "",
        -- Fool's Hunt: its own Auto Place brain, the units always placed / never placed (the rest
        -- go by the quality bar), and how many spells may wait in hand. Default lists: the strategy
        -- simulator's damage per map place at full upgrade over the owner's roster (2026-10-24).
        eventBrain = true, maxSpellsHeld = 2,
        eventAlways = { "judar_evolved", "cid_evolved", "sakamoto_evolved", "nagumo_evolved", "saber_evolved", "frieren_evolved", "monet_evolved", "jiraiya_evolved", "emilia" },
        eventNever = { "armin", "stain_evolved", "narberal_evolved", "hakari_evolved", "ghostkun_evolved", "demiurge_evolved", "sabo_evolved", "aokiji_evolved", "gildarts_evolved", "akainu_evolved", "natsu_evolved", "caesarclown_evolved", "vanilla_ice_evolved" } }, -- (config only: Watch logs without pausing the lobby automation)
    watchLog = {},
}

-- Webhook state
local Webhook = {
    url = "",
    notifyComplete = false,
    notifyFail = false,
    pingId = "",          -- Discord user id to @ping on important events; empty = no ping
    pingMythic = true, pingBagFull = true, pingDisconnect = true, pingLosses = true,
}

local Window
-- UI handles created later in the UI section (one table: Lua 5.1 allows only 200 locals)
local UIRef = {}
local Controls = {}
local applyRuntimeFeatures
local oldNamecall
local hookInstalled = false
local syncing = false

local function notify(message)
    Window:Notify({ Title = "moseeri hub", Description = tostring(message), Lifetime = 5 })
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
    if #trimmed < 1 or #trimmed > 90 or not trimmed:match("^[%w _%-#'.!&]+$") then return nil end
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
        webhook = { url = Webhook.url, notifyComplete = Webhook.notifyComplete, notifyFail = Webhook.notifyFail,
            pingId = Webhook.pingId, pingMythic = Webhook.pingMythic, pingBagFull = Webhook.pingBagFull,
            pingDisconnect = Webhook.pingDisconnect, pingLosses = Webhook.pingLosses },
        lobby = Lobby.cfg,
        dungeon = { roomPriority = DungeonRun.roomPriority, wishList = DungeonRun.wishList, shrineEnabled = DungeonRun.acceptShrines,
            openRareAtEnd = DungeonRun.openRareAtEnd, autoContinueDeath = DungeonRun.autoContinueDeath },
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
            autoStart = AutoFarm.autoStart,
            autoSkip = AutoFarm.autoSkip,
            leaveAtWave = AutoFarm.leaveAtWave,
            speedMultiplier = AutoFarm.speedMultiplier,
            autoSell = AutoFarm.autoSell,
            sellAtWave = AutoFarm.sellAtWave,
            sellUnitName = AutoFarm.sellUnitName,
        },
        macro = {
            retryPlacements = State.retryPlacements, macroFastV2 = true,
            autoPlay = State.autoPlay,
            showAllMacros = State.showAllMacros,
            lastMacro = State.macroName,
        },
        tools = { antiAfk = Tools.antiAfk, perf = Tools.perf },
        autoPlace = {
            enabled = AutoPlace.enabled, manual = AutoPlace.manual, skip = next(AutoPlace.skip) and AutoPlace.skip or nil,
            homeKeep = AutoPlace.homeKeep, upgrade = AutoPlace.upgrade, slots = AutoPlace.slots,
            moneyPath = AutoPlace.moneyPath, paths = next(AutoPlace.paths) and AutoPlace.paths or nil,
            caps = next(AutoPlace.caps) and AutoPlace.caps or nil,
            roles = next(AutoPlace.roles) and AutoPlace.roles or nil,
            unitInfo = next(AutoPlace.unitInfo or {}) and AutoPlace.unitInfo or nil,
            stageLosses = next(AutoPlace.stageLosses or {}) and AutoPlace.stageLosses or nil,
            preset = AutoPlace.preset, showDetails = AutoPlace.showDetails,
            placeMode = AutoPlace.placeMode,
            lastTeam = next(AutoPlace.lastTeam or {}) and AutoPlace.lastTeam or nil,
            smartFreeze = AutoPlace.smartFreeze,
            sellFarmsLast = AutoPlace.sellFarmsLast,
            autoTarget = AutoPlace.autoTarget, priorityMethod = AutoPlace.priorityMethod,
            hillBy = next(AutoPlace.hillBy or {}) and AutoPlace.hillBy or nil,
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
    for k, v in pairs(type(data.lobby) == "table" and data.lobby or {}) do
        if Lobby.cfg[k] ~= nil and type(v) == type(Lobby.cfg[k]) then Lobby.cfg[k] = v end
    end
    local w = data.webhook or {}
    Webhook.url = pick(w.url, "string", Webhook.url)
    Webhook.notifyComplete = pick(w.notifyComplete, "boolean", Webhook.notifyComplete)
    Webhook.notifyFail = pick(w.notifyFail, "boolean", Webhook.notifyFail)
    Webhook.pingId = pick(w.pingId, "string", Webhook.pingId)
    Webhook.pingMythic = pick(w.pingMythic, "boolean", Webhook.pingMythic)
    Webhook.pingBagFull = pick(w.pingBagFull, "boolean", Webhook.pingBagFull)
    Webhook.pingDisconnect = pick(w.pingDisconnect, "boolean", Webhook.pingDisconnect)
    Webhook.pingLosses = pick(w.pingLosses, "boolean", Webhook.pingLosses)
    local d = data.dungeon or {}
    -- (old dungeon bot keys remoteMap / autoBuyBuffs are ignored: that bot clicked any buy button)
    DungeonRun.roomPriority = pick(d.roomPriority, "string", DungeonRun.roomPriority)
    DungeonRun.wishList = pick(d.wishList, "string", DungeonRun.wishList)
    DungeonRun.acceptShrines = pick(d.shrineEnabled, "boolean", DungeonRun.acceptShrines)
    DungeonRun.openRareAtEnd = pick(d.openRareAtEnd, "boolean", DungeonRun.openRareAtEnd)
    DungeonRun.autoContinueDeath = pick(d.autoContinueDeath, "boolean", DungeonRun.autoContinueDeath)
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
    AutoFarm.autoStart = pick(a.autoStart, "boolean", AutoFarm.autoStart)
    AutoFarm.autoSkip = pick(a.autoSkip, "boolean", AutoFarm.autoSkip)
    -- macro playback extras have no controls any more (owner removed them): fixed values so an
    -- old config cannot leave one switched on with no way to turn it off
    AutoFarm.leaveAtWave, AutoFarm.speedMultiplier, AutoFarm.autoSell, AutoFarm.sellAtWave = 0, 1, false, 0
    local m = data.macro or {}
    -- purchases always go the moment money allows (in recorded order)
    State.retryPlacements = true
    State.autoPlay = pick(m.autoPlay, "boolean", State.autoPlay)
    State.showAllMacros = false
    if type(m.lastMacro) == "string" and #m.lastMacro > 0 then State.macroName = m.lastMacro end
    local t = data.tools or {}
    pendingToggles.antiAfk = t.antiAfk ~= false -- on unless the saved config turned it off
    pendingToggles.perf = type(t.perf) == "table" and t.perf or nil
    local ap = data.autoPlace or {}
    pendingToggles.autoPlace = ap.enabled == true
    AutoPlace.manual = ap.manual == true
    if type(ap.skip) == "table" then
        AutoPlace.skip = {}
        for k, v in pairs(ap.skip) do if v == true then AutoPlace.skip[tostring(k)] = true end end
    end
    AutoPlace.homeKeep = type(ap.homeKeep) == "table" and ap.homeKeep or nil
    AutoPlace.upgrade = pick(ap.upgrade, "boolean", AutoPlace.upgrade)
    if type(ap.slots) == "table" then
        for i = 1, 6 do AutoPlace.slots[i] = tonumber(ap.slots[i]) or AutoPlace.slots[i] end
    end
    AutoPlace.moneyPath = pick(ap.moneyPath, "string", AutoPlace.moneyPath)
    if type(ap.unitInfo) == "table" then AutoPlace.unitInfo = ap.unitInfo end
    if type(ap.stageLosses) == "table" then
        AutoPlace.stageLosses = {}
        for k, v in pairs(ap.stageLosses) do
            if type(k) == "string" and tonumber(v) then AutoPlace.stageLosses[k] = math.max(0, math.floor(tonumber(v))) end
        end
    end
    AutoPlace.placeMode = pick(ap.placeMode, "string", AutoPlace.placeMode)
    AutoPlace.smartFreeze = pick(ap.smartFreeze, "boolean", AutoPlace.smartFreeze)
    AutoPlace.preset = pick(ap.preset, "string", AutoPlace.preset)
    AutoPlace.showDetails = pick(ap.showDetails, "boolean", AutoPlace.showDetails)
    AutoPlace.sellFarmsLast = pick(ap.sellFarmsLast, "boolean", AutoPlace.sellFarmsLast)
    AutoPlace.autoTarget = pick(ap.autoTarget, "boolean", AutoPlace.autoTarget)
    AutoPlace.priorityMethod = pick(ap.priorityMethod, "string", AutoPlace.priorityMethod)
    if type(ap.hillBy) == "table" then AutoPlace.hillBy = ap.hillBy end
    if type(ap.lastTeam) == "table" then
        AutoPlace.lastTeam = {}
        for k, v in pairs(ap.lastTeam) do
            local slot = tonumber(k)
            if slot and type(v) == "table" and type(v.uuid) == "string" then
                AutoPlace.lastTeam[tostring(slot)] = { uuid = v.uuid, name = tostring(v.name) }
            end
        end
    end
    if type(ap.paths) == "table" then
        -- (a damaged or hand-edited config: only points made of three numbers are kept)
        AutoPlace.paths = {}
        for stage, pts in pairs(ap.paths) do
            if type(stage) == "string" and type(pts) == "table" then
                local ok = {}
                for _, p in ipairs(pts) do
                    if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number"
                        and p[1] == p[1] and p[2] == p[2] and p[3] == p[3] then
                        table.insert(ok, { p[1], p[2], p[3] })
                    end
                end
                if #ok > 0 then AutoPlace.paths[stage] = ok end
            end
        end
    end
    if type(ap.caps) == "table" then
        -- (a limit below 1 came from misread refusals: dropped)
        for k, v in pairs(ap.caps) do if tonumber(v) and tonumber(v) >= 1 then AutoPlace.caps[k] = tonumber(v) end end
    end
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
    -- (the full path: a unit on the map and a model in the game's own folders can share a name)
    if t == "Instance" then local ok, p = pcall(function() return v:GetFullName() end) return ok and p or v.Name end
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
    Stage.mode = mode
    if mode and mode ~= "story" and not string.lower(level or ""):find(string.lower(mode), 1, true)
        and not string.lower(level or ""):find((string.lower(mode):gsub("_", " ")), 1, true) then
        table.insert(parts, mode)
    end
    -- for people: "Mountain Temple — Infinity Mansion Room 12" (place, then mode / room;
    -- the difficulty goes in the report title)
    local difficulty = text("_difficulty")
    Stage.difficulty = difficulty
    if location and level then
        -- (the raw mode id like "infinite_tower" stays out of the name people read)
        Stage.pretty = location .. " — " .. level
    else
        Stage.pretty = nil
    end
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
    return cleanName(name:sub(1, 80))
end

-- Stage for people (with "—" between place and mode / room when the level data has both).
function Stage.Pretty()
    if not State.stage then return nil end
    if Stage.pretty then return Stage.pretty end
    return State.stage
end

local function stageMacroPattern(stage)
    return "^" .. stage:gsub("[%-%.%+%*%?%[%]%^%$%(%)%%]", "%%%0") .. " #%d+$"
end

local function refreshStatus()
    if not UIRef.statusParagraph then return end
    local stateText
    if State.recording then stateText = "Recording"
    elseif State.finalizing then stateText = "Saving..."
    elseif State.replaying then stateText = string.format("Playing %d / %d", State.replayIndex, #State.actions)
    elseif #State.actions > 0 then stateText = "Ready"
    else stateText = "Idle" end
    local elapsed = State.recording and (os.clock() - State.startedAt) or State.duration
    UIRef.statusParagraph:UpdateBody(string.format(
        "%s   |   %s\nStage: %s\nTime: %s   Actions: %d",
        stateText, cleanName(State.macroName) or "(no macro)", State.stage or "not detected (lobby?)",
        formatDuration(elapsed), #State.actions
    ))
end

local function refreshActionList()
    if not UIRef.actionsParagraph then return end
    local n = #State.actions
    if n == 0 then
        UIRef.actionsParagraph:UpdateBody("Nothing recorded yet.")
        return
    end
    local first = math.max(1, n - Config.ListLines + 1)
    local lines = {}
    if first > 1 then table.insert(lines, string.format("(%d earlier actions hidden)", first - 1)) end
    for i = first, n do table.insert(lines, describeAction(i, State.actions[i], SHORT)) end
    UIRef.actionsParagraph:UpdateBody(table.concat(lines, "\n"))
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
        if (State.recording or State.learning or State.watching) and (method == "FireServer" or method == "InvokeServer")
            and not (type(checkcaller) == "function" and checkcaller()) then
            local ok, className = pcall(function() return typeof(self) == "Instance" and self.ClassName end)
            if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
            if ok and (className == "RemoteEvent" or className == "RemoteFunction") and State.watching and State.onWatch then
                -- written later on its own thread: a method call in here (GetFullName) replaced
                -- the namecall method, so the game's own call (joining a stage) went out wrong
                task.spawn(State.onWatch, self, method, table.pack(...))
            end
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
            -- (anything above may have made a method call of its own: restore the game's)
            if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
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
    if not UIRef.savedDropdown then return end
    syncing = true
    UIRef.savedDropdown:ClearOptions()
    UIRef.savedDropdown:InsertOptions(Files.list())
    if select then UIRef.savedDropdown:UpdateSelection(select) end
    syncing = false
end

local function setMacroName(name)
    State.macroName = name or ""
    if UIRef.nameInput and UIRef.nameInput:GetInput() ~= State.macroName then UIRef.nameInput:UpdateText(State.macroName) end
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
    if UIRef.pasteInput then UIRef.pasteInput:UpdateText("") end
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
    setToggle(UIRef.recordToggle, false)
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
                footer = { text = "moseeri hub // " .. os.date("%H:%M:%S") },
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
    setToggle(UIRef.playToggle, true)
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
                if skillPress and (UnitAI.autoBuff or UnitAI.autoAbilities or (AutoPlace.enabled and AutoPlace.smartFreeze)) then
                    -- skill presses recorded by hand would break the buff rotation's turn order, and
                    -- the unit skills / smart freeze loops cast them at the right time themselves
                    addReplayLog(string.format("#%d %s: skipped, the buff rotation / unit skills / freeze cast skills", i, a.name))
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
        setToggle(UIRef.playToggle, false)
        refreshStatus()
        addReplayLog(finished and string.format("finished, %d failed", failed) or "stopped")

        if finished then
            Tools.totalReplays = Tools.totalReplays + 1
            if failed > 0 then
                Tools.totalFails = Tools.totalFails + 1
                notify(string.format("Finished, %d action(s) failed.", failed))
            else
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
-- A full PlayerGui scan walks thousands of instances and several loops ask the same question
-- many times a second: each answer below is reused for half a second.
Scan.memo = {}
function Scan.Cached(key, fn)
    local m, now = Scan.memo[key], os.clock()
    if m and now - m.at >= 0 and now - m.at < 0.5 then return m[1], m[2] end
    local a, b = fn()
    Scan.memo[key] = { at = now, a, b }
    return a, b
end
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
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and (d.Text == "moseeri hub" or d.Text == "MACRO // LAB") then mine = true break end
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

function Scan.Results()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return false end
    local results = gui:FindFirstChild("ResultsUI")
    if results and results:IsA("LayerCollector") and results.Enabled then return true end
    -- never in the lobby (result words show up there on passes, quests, banners)
    local cfg = workspace:FindFirstChild("_MAP_CONFIG")
    local lobby = cfg and cfg:FindFirstChild("IsLobby")
    if not cfg or (lobby and lobby.Value == true) then return false end
    local data = workspace:FindFirstChild("_DATA")
    local fin = data and (data:FindFirstChild("GameFinished") or data:FindFirstChild("GameOver") or data:FindFirstChild("GameEnded"))
    if fin and fin:IsA("BoolValue") and fin.Value == true then return true end
    -- fallback, only once the match has started (wave counter moved): a label that IS a
    -- result word ("VICTORY", "Defeat!", "Total Time: 01:15"), not one that has it inside
    -- (the quest line "Defeat 50 enemies")
    if getCurrentWave() <= 0 then return false end
    for _, d in ipairs(gui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text > 0 then
            local t = string.lower(tostring(d.Text)):gsub("<[^>]->", ""):match("^%s*(.-)[%p%s]*$")
            for _, word in ipairs(Words.END) do
                local whole = t == word or ((word == "total time" or word == "waves completed") and t:sub(1, #word) == word)
                if whole and isOnScreen(d) and not isOwnGui(d) then return true end
            end
        end
    end
    return false
end

local function isResultsShowing() return Scan.Cached("results", Scan.Results) end

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
    if not UIRef.autoStatusParagraph then return end
    local parts = {}
    if AutoFarm.autoReplay then table.insert(parts, "Replay: ON") end
    if AutoFarm.autoNextStage then table.insert(parts, "Next stage: ON") end
    if AutoFarm.autoLeave then table.insert(parts, "Leave when you lose: ON") end
    if AutoFarm.autoStart then table.insert(parts, "Vote start: ON" .. (AutoFarm.lastStart and (" (" .. AutoFarm.lastStart .. ")") or "")) end
    if AutoFarm.autoSkip then table.insert(parts, "Skip waves: ON" .. (AutoFarm.lastSkip and (" (" .. AutoFarm.lastSkip .. ")") or "")) end
    if AutoFarm.leaveAtWave > 0 then table.insert(parts, "Leave at wave " .. AutoFarm.leaveAtWave) end
    if AutoFarm.autoSell and AutoFarm.sellAtWave > 0 then table.insert(parts, "Sell at wave " .. AutoFarm.sellAtWave) end
    if AutoFarm.speedMultiplier ~= 1 then table.insert(parts, string.format("Speed: %.1fx", AutoFarm.speedMultiplier)) end
    if #parts == 0 then table.insert(parts, "All off") end
    UIRef.autoStatusParagraph:UpdateBody(table.concat(parts, "\n"))
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

    -- (only when the 45 s ran out: not when Auto leave was turned off or the script closed)
    if not done and goal == "leave" and os.clock() >= giveUpAt and not State.unloaded then
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

-- Vote start / skip wave: the game's own remote when it has one (names used by AA), else
-- the button on screen. Each try is shown in the status so a wrong guess is visible.
Words.START_REMOTES = { "vote_start", "start_game", "vote_start_game", "ready_up" }
Words.SKIP_REMOTES = { "vote_wave_skip", "skip_wave", "vote_skip_wave", "vote_skip" }
do
local function inLobby()
    local cfg = workspace:FindFirstChild("_MAP_CONFIG")
    local lobby = cfg and cfg:FindFirstChild("IsLobby")
    return (lobby and lobby.Value == true) or not cfg
end

local function fireFirst(names, ...)
    local args = table.pack(...)
    for _, name in ipairs(names) do
        local r = getAARemote(name)
        if r then
            task.spawn(function()
                pcall(function()
                    if r:IsA("RemoteFunction") then r:InvokeServer(table.unpack(args, 1, args.n))
                    else r:FireServer(table.unpack(args, 1, args.n)) end
                end)
            end)
            return name
        end
    end
    return nil
end

-- A visible button whose own label contains one of the words (never ours, never "restart").
local function labelButton(words)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("GuiButton") and isOnScreen(d) and not isOwnGui(d) then
            local text = buttonText(d)
            if not text:find("restart", 1, true) then
                for _, w in ipairs(words) do
                    if text:find(w, 1, true) then return d end
                end
            end
        end
    end
    return nil
end

local function gameStarted()
    local data = workspace:FindFirstChild("_DATA")
    local started = data and data:FindFirstChild("GameStarted")
    return started and started.Value == true
end

task.spawn(function()
    local nextStart, nextSkip = 0, 0
    while not State.unloaded do
        task.wait(0.5)
        local now = os.clock()
        if (AutoFarm.autoStart or AutoFarm.autoSkip) and not inLobby() and not isResultsShowing() then
            if AutoFarm.autoStart and not gameStarted() and getCurrentWave() <= 0 and now >= nextStart then
                nextStart = now + 2
                local via = fireFirst(Words.START_REMOTES)
                local btn = labelButton({ "vote start", "start game", "vote to start", "start" })
                if btn then clickButton(btn) end
                AutoFarm.lastStart = via or (btn and "button") or "nothing found"
            end
            -- (Fool's Hunt: no skipping - the time between waves is what pays for the upgrades)
            if AutoFarm.autoSkip and gameStarted() and now >= nextSkip and not State.eventMode then
                nextSkip = now + 3
                local via = fireFirst(Words.SKIP_REMOTES, true)
                local btn = labelButton({ "skip wave", "skip" })
                if btn then clickButton(btn) end
                AutoFarm.lastSkip = via or (btn and "button") or "nothing found"
            end
        end
    end
end)
end

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
    local targetName = string.lower(AutoFarm.sellUnitName):match("^%s*(.-)%s*$")
    for _, unit in ipairs(folder:GetChildren()) do
        local stats = unit:FindFirstChild("_stats")
        local id = stats and stats:FindFirstChild("id")
        local same = string.lower(unit.Name) == targetName or (id and string.lower(tostring(id.Value)) == targetName)
        if same and isMyUnit(unit) then
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

-- Units another unit summons (Erwin's Scout Corps "aot_generic", cost 1) carry the
-- summoner's uuid but cannot be upgraded or cast; set once unit data can be read.
local isSummon = function() return false end

local function ownedUnits()
    local folder = unitsFolder()
    if not folder then return {} end
    local mine, all, anyOwnerField = {}, {}, false
    for _, unit in ipairs(folder:GetChildren()) do
        local stats = unit:FindFirstChild("_stats")
        local base = stats and stats:FindFirstChild("base")
        if not (base and tostring(base.Value) == "pve") and not isSummon(unit) then table.insert(all, unit) end
        if stats and stats:FindFirstChild("player") then anyOwnerField = true end
        if isMyUnit(unit) and not isSummon(unit) then table.insert(mine, unit) end
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
    local lines = { "[moseeri hub · Buff report] " .. os.date("%H:%M:%S") }
    pcall(function() table.insert(lines, "status: " .. UnitAIModule.StatusDetail():gsub("\n", " | ")) end)
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

-- Skills that stop enemies (Shadowgirl "homura:timestop", freeze, stun): Auto Place fires
-- them at the best moment instead of whenever they are ready.
function BuffRot.isControlSkill(unit)
    local stats = unit:FindFirstChild("_stats")
    local a = stats and stats:FindFirstChild("active_attack")
    local name = a and string.lower(tostring(a.Value)) or ""
    return name:find("stop", 1, true) ~= nil or name:find("freeze", 1, true) ~= nil or name:find("stun", 1, true) ~= nil
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
-- (the unit skills loop below waits for the cooldown too)
BuffRot.readyIn, BuffRot.observeCast = readyIn, observeCast
function BuffRot.markCast(unit) ourCast[unit] = os.clock() end

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

-- Full buff / ability status (in Copy buff report); the Advanced tab shows one line.
function UnitAIModule.StatusDetail()
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
    return table.concat(parts, "\n")
end

local function refreshUnitStatus()
    if not UIRef.unitStatusParagraph then return end
    local line
    if UnitAI.autoBuff then
        local mine = #ownedUnits()
        line = mine < UnitAI.minUnitsForBuff and string.format("Buffs waiting %d/%d units", mine, UnitAI.minUnitsForBuff)
            or string.format("Buffs %d/%d", BuffRot.buffUnits or 0, BuffRot.buffUnits or 0)
        if BuffRot.autoActive > 0 then line = line .. " (turn the in-game Auto skill Off)"
        elseif mine >= UnitAI.minUnitsForBuff and BuffRot.buffUnits == 0 then line = line .. " (no buff unit: Learn buff)" end
    else
        line = "Buffs off"
    end
    line = line .. " · abilities " .. (UnitAI.autoAbilities and "on" or "off")
    pcall(function() UIRef.unitStatusParagraph:UpdateBody(line) end)
end

local abilityGen, buffGen = 0, 0

function UnitAIModule.StartAbilities()
    abilityGen = abilityGen + 1
    local gen = abilityGen
    task.spawn(function()
        while UnitAI.autoAbilities and gen == abilityGen do
            if isGameRunning() then
                for _, unit in ipairs(myUnitsWithAbility()) do
                    local held = AutoPlace.enabled and AutoPlace.smartFreeze and BuffRot.isControlSkill(unit)
                    BuffRot.observeCast(unit)
                    if inAttackState(unit) and not held and BuffRot.readyIn(unit) <= 0 and not UnitAIModule.Costly(unit) then
                        fireActiveAttack(unit)
                        BuffRot.markCast(unit)
                    end
                end
            end
            task.wait(math.max(1, UnitAI.abilityCooldown))
        end
    end)
end

-- A skill that costs units or yen (sacrifice, sell, pay): left to the player. Read from the
-- skill's name and any cost number in _stats (field names are a guess).
Words.COSTLY_SKILL = { "sacrific", "consume", "devour" }
function UnitAIModule.Costly(unit)
    local stats = unit:FindFirstChild("_stats")
    local act = stats and stats:FindFirstChild("active_attack")
    local name = act and string.lower(tostring(act.Value)) or ""
    for _, w in ipairs(Words.COSTLY_SKILL) do if name:find(w, 1, true) then return true end end
    for _, n in ipairs({ "active_attack_cost", "active_cost", "skill_cost", "ability_cost" }) do
        local v = stats and stats:FindFirstChild(n)
        if v and (tonumber(v.Value) or 0) > 0 then return true end
    end
    return false
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
local AutoPlaceModule = { team = {}, status = "Off", problem = nil, placed = {}, full = {}, noSpot = {},
    gameCaps = {}, failsBy = {} } -- limits found this game only (refusals / messages), refusals in a row per unit
do
local PATH_CELL = 2.5      -- path points closer than this are merged
local SIDE_DIST = { 4, 5, 8, 12 } -- how far beside the path to try (4 for narrow rooftops, 12 reaches hills set back)
local MIN_FROM_PATH = 4    -- never closer than this to the path (that is the road)
local MIN_SPACING = 3      -- distance kept between own units
local BAD_REACH = 4        -- spots this close to a refused one are tried last (same building)
local DEFAULT_RANGE = 15
local apGen = 0
local badSpots = {}
local candidates, candidatesFor = nil, -1
local recentBad = {}
local unknownTries = 0

-- Map fingerprint: event and Infinity Mansion stages keep one name while the map rotates
-- (Fool's Hunt changes map every ~45 min), so the map itself is part of the key: where
-- _BASES.player.base and _BASES.pve.base stand (or the player LANES bends), rounded to
-- whole studs and hashed to 6 hex digits. Read again every 3 s and at each game start.
function AutoPlaceModule.MapFingerprint(fresh)
    local now = os.clock()
    if not fresh and AutoPlaceModule.fpAt and now - AutoPlaceModule.fpAt < 3 then return AutoPlaceModule.fp end
    local coords = {}
    pcall(function()
        local bases = workspace:FindFirstChild("_BASES")
        local function add(inst)
            local ok, p = pcall(function() return inst:IsA("BasePart") and inst.Position or inst:GetPivot().Position end)
            if ok and p then
                table.insert(coords, string.format("%d,%d,%d", math.floor(p.X + 0.5), math.floor(p.Y + 0.5), math.floor(p.Z + 0.5)))
            end
        end
        for _, side in ipairs({ "player", "pve" }) do
            local b = bases and bases:FindFirstChild(side)
            local base = b and b:FindFirstChild("base")
            if base then add(base) end
        end
        if #coords < 2 then
            coords = {}
            local pb = bases and bases:FindFirstChild("player")
            local lanes = pb and pb:FindFirstChild("LANES")
            for _, lane in ipairs(lanes and lanes:GetChildren() or {}) do
                for _, bend in ipairs(lane:GetChildren()) do add(bend) end
            end
            table.sort(coords)
        end
    end)
    local fp
    if #coords > 0 then
        local h = 5381
        for c in table.concat(coords, "|"):gmatch(".") do h = (h * 33 + c:byte()) % 16777216 end
        fp = string.format("%06x", h)
    end
    AutoPlaceModule.fp, AutoPlaceModule.fpAt, AutoPlaceModule.fpFrom = fp, now, table.concat(coords, " ")
    return fp
end

-- Plain stage name (stage losses stay on it: the waves are the stage's, whatever the map).
function AutoPlaceModule.StageName() return State.stage or "unknown" end

-- Key for everything learned about the map (enemy path, hill trust): stage # fingerprint.
local function stageKey()
    local fp = AutoPlaceModule.MapFingerprint()
    return fp and (AutoPlaceModule.StageName() .. "#" .. fp) or AutoPlaceModule.StageName()
end
AutoPlaceModule.StageKey = stageKey

-- Losses remembered for this stage (see AutoPlace.stageLosses).
function AutoPlaceModule.Losses()
    return (AutoPlace.stageLosses or {})[AutoPlaceModule.StageName()] or 0
end

-- Placement mode in use: the chosen one, but Balanced turns Safe on a stage lost before.
function AutoPlaceModule.Mode()
    if AutoPlace.placeMode == "Balanced" and AutoPlaceModule.Losses() > 0 then return "Safe" end
    return AutoPlace.placeMode
end

-- Called once per finished game.
function AutoPlaceModule.OnResult(win)
    AutoPlace.stageLosses = AutoPlace.stageLosses or {}
    local key, n = AutoPlaceModule.StageName(), AutoPlaceModule.Losses()
    if win then
        AutoPlace.stageLosses[key] = n > 1 and n - 1 or nil
    else
        AutoPlace.stageLosses[key] = n + 1
        AutoPlaceModule.Note(string.format("lost on %s: next runs here play safer", key))
    end
    saveConfig()
end

-- A path saved before fingerprints (under the plain stage name) is taken over by this map
-- only when it runs from this map's enemy base (a point within 15 studs of _BASES.pve.base);
-- otherwise it is left alone for the map it came from and this map learns its own.
function AutoPlaceModule.AdoptOldPath(key)
    local name = AutoPlaceModule.StageName()
    local old = AutoPlace.paths[name]
    if key == name or type(old) ~= "table" or #old == 0 then return nil end
    local spawn = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("pve")
    if not spawn then return nil end
    local fits = false
    for _, q in ipairs(old) do
        if type(q) == "table" and tonumber(q[1]) and tonumber(q[3]) then
            local dx, dz = q[1] - spawn.X, q[3] - spawn.Z
            if dx * dx + dz * dz < 225 then fits = true break end
        end
    end
    if not fits then return nil end
    AutoPlace.paths[name] = nil
    if AutoPlace.hillBy[name] then AutoPlace.hillBy[key], AutoPlace.hillBy[name] = AutoPlace.hillBy[name], nil end
    AutoPlace.paths[key] = old
    saveConfig()
    AutoPlaceModule.Note("old saved path matches this map: kept as " .. key)
    return old
end

local function pathPoints()
    local key = stageKey()
    if not AutoPlace.paths[key] then
        AutoPlace.paths[key] = AutoPlaceModule.AdoptOldPath(key) or {}
    end
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
AutoPlaceModule.RootPos = rootPos

local function isEnemy(unit)
    local stats = unit:FindFirstChild("_stats")
    if not stats then return false end
    local base = stats:FindFirstChild("base")
    if base then return tostring(base.Value) == "pve" end
    return stats:FindFirstChild("player") == nil and unit:FindFirstChild("HumanoidRootPart") ~= nil
end
AutoPlaceModule.IsEnemy = isEnemy

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

-- Ground under a point: height, "hill" / "ground" when the part hit (or a parent) is named
-- like one (hill, cliff, mountain, rock, elevated / ground), and the part itself.
local function groundHit(x, y, z)
    local ok, hit = pcall(function()
        -- skip units, the invisible _barrier walls, the ignore folder and any part that can be
        -- walked through (invisible / no collision), so the ray stops on real ground
        local exclude = { unitsFolder() }
        for _, n in ipairs({ "_barrier", "ignore", "_DEAD_UNITS", "_PETS" }) do
            local f = workspace:FindFirstChild(n)
            if f then table.insert(exclude, f) end
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        for _ = 1, 4 do
            params.FilterDescendantsInstances = exclude
            local h = workspace:Raycast(Vector3.new(x, y + 60, z), Vector3.new(0, -120, 0), params)
            if not h then return nil end
            local inst = h.Instance
            local okPass, passable = pcall(function() return inst.CanCollide == false or inst.Transparency >= 0.95 end)
            if not (okPass and passable) or not inst then return h end
            table.insert(exclude, inst)
        end
        return nil
    end)
    if not (ok and hit and hit.Position) then return nil end
    local tag
    pcall(function()
        local node = hit.Instance
        while node and node ~= workspace do
            local n = string.lower(node.Name)
            if n:find("hill", 1, true) or n:find("cliff", 1, true) or n:find("mountain", 1, true)
                or n:find("rock", 1, true) or n:find("elevated", 1, true) then tag = "hill" break end
            if n:find("ground", 1, true) then tag = "ground" break end
            node = node.Parent
        end
    end)
    return hit.Position.Y, tag, hit.Instance
end

local function groundAt(x, y, z)
    return (groundHit(x, y, z)) or (y - 2)
end

local function buildCandidates(pts)
    local list = {}
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.71, 0.71 }, { -0.71, 0.71 }, { 0.71, -0.71 }, { -0.71, -0.71 } }
    local step = math.max(1, math.floor(#pts / 120))
    for i = 1, #pts, step do
        local p = pts[i]
        local roadY = groundHit(p[1], p[2], p[3])
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
                    local gy, tag, part = groundHit(x, p[2], z)
                    -- nothing under it, or well below the road (past a rooftop / ledge edge, as on
                    -- Fiend City where the road runs over roofs): not a place to stand
                    if gy and not (roadY and gy < roadY - 3) then
                        -- (well above the road with no hill name: a hill, or a roof / tree / wall;
                        -- hillBy says which, so those spots can be distrusted per stage)
                        local kind = tag or ((roadY and gy > roadY + 2.5) and "hill" or "ground")
                        table.insert(list, { x = x, y = p[2], z = z, score = score, groundY = gy, kind = kind,
                            hillBy = kind == "hill" and (tag and "name" or "height") or nil, part = part, rise = roadY and gy - roadY })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

-- Where a unit may stand: "hill" (hill_unit), "any" (hybrid_placement) or "ground".
function AutoPlaceModule.PlacementKind(t)
    local def = AutoPlaceModule.UnitDef and AutoPlaceModule.UnitDef(t.name)
    if def and def.hill_unit == true then return "hill" end
    if def and def.hybrid_placement == true then return "any" end
    return "ground"
end

-- Bad spots are remembered per placement kind: a spot refused to a hill unit may suit a ground one.
local function spotKey(c, kind)
    return string.format("%d,%d|%s", math.floor(c.x + 0.5), math.floor(c.z + 0.5), kind or "ground")
end

-- Role from the game's own unit definition (src.Data.Units): farm_amount > 0 = farm,
-- _show_as_buff_unit / _NO_ATTACKS_UNIT = buff or support, else damage. nil = no definition.
function AutoPlaceModule.RoleFromDef(name)
    local def = AutoPlaceModule.UnitDef and AutoPlaceModule.UnitDef(name)
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
    if def._show_as_buff_unit == true or def._NO_ATTACKS_UNIT == true then
        -- a buffer with passives (hoshino: damage buff + cheaper upgrades) is "support"
        return type(def.passives) == "table" and next(def.passives) ~= nil and "support" or "buff"
    end
    for k, v in pairs(def) do
        if type(v) == "string" and string.lower(tostring(k)):find("active", 1, true) and string.lower(v):find("buff", 1, true) then
            return "buff"
        end
    end
    return "dps"
end

-- Damage per second per ¥ from the definition (higher = better value); 0 when unknown.
-- Trait effects (from the AA trait guides): damage, attack time (SPA) and range multipliers,
-- plus "cap" for traits that limit placement. Levels I/II/III or 1/2/3 pick the column.
local TRAITS = {
    unique = { dmg = 4, spa = 0.9, range = 1.1, cap = 1 },
    divine = { dmg = 1.2, spa = 0.9, range = 1.2 },
    celestial = { dmg = 1.3, range = 1.1 },
    golden = { dmg = 1.3 },
    reaper = { dmg = 1.15 },
    godspeed = { spa = 0.8 },
    sniper = { range = 1.25 },
    culling = { dmg = 1.05 }, -- +20% only on enemies under 30% hp
    adept = {}, -- levels up faster, no fight effect
    nimble = { spa = { 0.95, 0.925, 0.88 } },
    range = { range = { 1.1, 1.125, 1.15 } },
    superior = { dmg = { 1.1, 1.125, 1.15 } },
}
-- game ids whose shown name differs (game_data Traits: ethereal is "Celestial", neuroplasticity
-- is "Adept"); old saves may still hold the id
local TRAIT_IDS = { ethereal = "Celestial", neuroplasticity = "Adept" }
TRAITS.ethereal, TRAITS.neuroplasticity = TRAITS.celestial, TRAITS.adept
local ROMAN = { i = 1, ii = 2, iii = 3 }

function AutoPlaceModule.TraitMods(traits)
    local m = { dmg = 1, spa = 1, range = 1 }
    for _, raw in ipairs(traits or {}) do
        local text = string.lower(tostring(raw))
        local word = text:match("^%a+") or text
        local lvl = tonumber(text:match("(%d+)%s*$")) or ROMAN[text:match("%s([iv]+)%s*$") or ""] or 1
        local t = TRAITS[word]
        if t then
            for _, k in ipairs({ "dmg", "spa", "range" }) do
                local v = t[k]
                if type(v) == "table" then v = v[math.max(1, math.min(#v, lvl))] end
                if v then m[k] = m[k] * v end
            end
            if t.cap then m.cap = t.cap end
        end
    end
    return m
end

-- A team unit's real numbers: a placed copy's own _stats when there is one (already includes
-- its rolls and trait), else the definition scaled by the rolls and trait from the team data.
-- Seconds between hits from the unit data. A unit with none there attacks only with its skill:
-- Arlem (armin) hits once in 60 s (36k a hit, ~600 a second), but read as one hit a second it
-- looked 60x stronger, was placed and upgraded - owner 2026-10-24 "it attacks slowly, never take it".
function AutoPlaceModule.DefCd(def)
    local cd = tonumber(def and def.attack_cooldown)
    if cd then return cd end
    return (tonumber(def and def.damage) or 0) > 0 and 60 or 1
end

function AutoPlaceModule.Stats(t)
    local def = AutoPlaceModule.UnitDef and AutoPlaceModule.UnitDef(t.name) or {}
    local rolls = t.rolls or {}
    local tm = AutoPlaceModule.TraitMods(t.traits)
    local s = {
        damage = (tonumber(def.damage) or 0) * (rolls.potency_stat or 1) * tm.dmg,
        cooldown = math.max(0.5, AutoPlaceModule.DefCd(def)) / math.max(0.1, rolls.speed_stat or 1) * tm.spa,
        range = (tonumber(def.range) or DEFAULT_RANGE) * (rolls.range_stat or 1) * tm.range,
    }
    local placed = t.placedSample
    local st = placed and placed.Parent and placed:FindFirstChild("_stats")
    if st then
        local function num(n) local v = st:FindFirstChild(n) return v and tonumber(v.Value) end
        s.damage = num("damage") or s.damage
        s.cooldown = num("attack_cooldown") or s.cooldown
        s.range = num("range") or s.range
    end
    if s.range <= 0 then s.range = DEFAULT_RANGE end
    return s
end

-- Area attacks hit several enemies at once: their damage counts this much more than a
-- single-target unit's when ranking units (Value, the "Strongest" status line)
local AOE_VALUE = 1.5

-- Damage per second per ¥ (higher = better value); 0 for units that do not attack.
function AutoPlaceModule.Value(t, cost)
    if not cost or cost <= 0 then return 0 end
    local s = AutoPlaceModule.Stats(t)
    local aoe = AutoPlaceModule.IsAoe and AutoPlaceModule.IsAoe(t.name)
    return s.damage / s.cooldown / cost * (aoe and AOE_VALUE or 1)
end

function AutoPlaceModule.Range(t)
    return AutoPlaceModule.Stats(t).range
end

-- Role of a unit already on the map: the game's definition first, else its own stats;
-- remembered by unit name for games where the definition cannot be read.
local function unitRole(u)
    local stats = u:FindFirstChild("_stats")
    if not stats then return "dps" end
    local id = stats:FindFirstChild("id")
    local name = id and tostring(id.Value) or u.Name
    local farm = stats:FindFirstChild("farm_amount")
    local act = stats:FindFirstChild("active_attack")
    local role = AutoPlaceModule.RoleFromDef(name)
    if not role then
        role = "dps"
        if farm and (tonumber(farm.Value) or 0) > 0 then
            role = "farm"
        elseif (act and string.lower(tostring(act.Value)):find("buff", 1, true)) or UnitAI.learned[name] then
            role = "buff"
        end
    end
    if AutoPlace.roles[name] ~= role then
        AutoPlace.roles[name] = role
        saveConfig()
    end
    return role
end

local BUFF_REACH = 12

-- A placed damage unit that hit nothing for 60 s while enemies walked inside its range (on
-- the map plane) stands where it cannot reach them (Room 39: "DMG 0 | Takedowns 0" on a hill):
-- no more yen goes into it. Read from its _stats damage / takedown value when the game has
-- one (names are a guess: any that matches), else from whether its spot reaches a road point.
AutoPlaceModule.DMG_STATS = { "damage_dealt", "total_damage", "damage_done", "dmg_dealt", "takedowns", "kills" }
AutoPlaceModule.hits = setmetatable({}, { __mode = "k" })
function AutoPlaceModule.HitTotal(u)
    local st = u:FindFirstChild("_stats")
    local total
    for _, n in ipairs(AutoPlaceModule.DMG_STATS) do
        local o = st and st:FindFirstChild(n)
        local okA, attr = pcall(function() return u:GetAttribute(n) end)
        local x = (o and o:IsA("ValueBase") and tonumber(o.Value)) or (okA and tonumber(attr)) or nil
        if x then total = (total or 0) + x end
    end
    return total
end
local function unitReach(u)
    local st = u:FindFirstChild("_stats")
    local rv = st and st:FindFirstChild("range")
    local id = st and st:FindFirstChild("id")
    local def = AutoPlaceModule.UnitDef(id and tostring(id.Value) or u.Name) or {}
    return (rv and tonumber(rv.Value)) or tonumber(def.range) or DEFAULT_RANGE
end
-- called every Auto Place tick: counts, per damage unit, the seconds enemies spent inside its
-- range without its hit counter going up
function AutoPlaceModule.WatchHits()
    local now = os.clock()
    local enemies = {}
    local folder = unitsFolder()
    for _, e in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(e) then
            local p = rootPos(e)
            if p then table.insert(enemies, p) end
        end
    end
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            local total = AutoPlaceModule.HitTotal(u)
            local h = AutoPlaceModule.hits[u]
            if not h then h = { total = total, quiet = 0, at = now } AutoPlaceModule.hits[u] = h end
            if total and h.total and total > h.total then h.quiet = 0 end
            h.total = total
            local p, r = rootPos(u), unitReach(u)
            local near = false
            for _, e in ipairs(enemies) do
                if p and (e.X - p.X) ^ 2 + (e.Z - p.Z) ^ 2 <= r * r then near = true break end
            end
            if near then h.quiet = h.quiet + math.min(2, now - h.at) end
            h.at = now
        end
    end
end
function AutoPlaceModule.OutOfReach(u)
    if unitRole(u) ~= "dps" then return false end
    -- summoners and trap units deal their damage through other things, so their own
    -- counter can stay at 0 while they work (Elyssia's card shows DMG 0)
    local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
    if def.spawn_unit or def.spawn_script or def.max_path_units or AutoPlaceModule.IsTrap(unitType(u)) then return false end
    local h = AutoPlaceModule.hits[u] or {}
    AutoPlaceModule.hits[u] = h
    -- its spot reaches no road point at all (3D): out of range right away
    local p, pts = rootPos(u), pathPoints()
    if not p or #pts < 8 then return false end
    local r = unitReach(u)
    local out = true
    for _, q in ipairs(pts) do
        if (q[1] - p.X) ^ 2 + (q[2] - p.Y) ^ 2 + (q[3] - p.Z) ^ 2 <= r * r then out = false break end
    end
    if not out and h.total ~= nil then
        -- or enemies spent a full minute inside its range and it never hit (no hit yet is
        -- fine: front units may kill everything before it gets a turn)
        out = h.quiet >= 60 and h.total == 0
    end
    if out and not h.noted then
        h.noted = true
        AutoPlaceModule.Note(string.format("%s is out of range - not upgraded", unitType(u)))
    end
    return out
end

-- skip = how many good free spots to pass over (used to rotate while the price is unknown).
-- role: "farm" takes the spots that cover the least road (farms earn anywhere), "buff"
-- the spots next to the most damage units, anything else the spots covering the most road
-- within that unit's own range (a range-9 unit must stand closer than a range-16 one).
local function bestSpot(skip, role, range, kind, aoe, back)
    skip = skip or 0
    kind = kind or "ground"
    local pts = pathPoints()
    if not candidates or #pts >= candidatesFor + math.max(10, math.floor(candidatesFor * 0.1)) or #pts < candidatesFor
        or AutoPlaceModule.candidatesKey ~= stageKey() then
        candidates, candidatesFor = buildCandidates(pts), #pts
        AutoPlaceModule.candidatesKey = stageKey()
    end
    local mine, helpers, farms, buffers = {}, {}, {}, {}
    for _, u in ipairs(ownedUnits()) do
        local p = rootPos(u)
        if p then
            table.insert(mine, p)
            local r = unitRole(u)
            if r == "dps" then table.insert(helpers, p)
            elseif r == "farm" then table.insert(farms, p)
            elseif r == "buff" then table.insert(buffers, p) end
        end
    end
    local function countNear(list, c, reach)
        local n = 0
        for _, p in ipairs(list) do
            local dx, dz = p.X - c.x, p.Z - c.z
            if dx * dx + dz * dz <= reach * reach then n = n + 1 end
        end
        return n
    end
    -- refused spots of this kind: a spot right next to one is most likely in the same
    -- building, so it is only tried when nothing else is free (each refusal costs ~0.5 s)
    local refused = {}
    for key in pairs(badSpots) do
        local x, z, k = key:match("^(%-?%d+),(%-?%d+)|(.+)$")
        if x and k == kind then table.insert(refused, { tonumber(x), tonumber(z) }) end
    end
    -- road points inside this unit's reach from c: the reach is 3D (a spot 37 studs above the
    -- road on a tall rock reaches nothing with range 24), c.rise = height above the road
    local attacks = role ~= "farm" and role ~= "buff" and role ~= "support"
    local reach = (range and range > 0) and range or DEFAULT_RANGE
    local function cover(c)
        local flat = reach * reach - (c.rise or 0) ^ 2
        if flat <= 0 then return 0 end
        local n = 0
        for _, q in ipairs(pts) do
            local dx, dz = q[1] - c.x, q[3] - c.z
            if dx * dx + dz * dz <= flat then n = n + 1 end
        end
        return n
    end
    local free, nearRefused = {}, {}
    for _, c in ipairs(candidates) do
        if not badSpots[spotKey(c, kind)] and (kind == "any" or c.kind == kind) and not (attacks and cover(c) == 0) then
            local ok = true
            for _, p in ipairs(mine) do
                local dx, dz = p.X - c.x, p.Z - c.z
                if dx * dx + dz * dz < MIN_SPACING * MIN_SPACING then ok = false break end
            end
            if ok then
                local near = false
                for _, b in ipairs(refused) do
                    local dx, dz = b[1] - c.x, b[2] - c.z
                    if dx * dx + dz * dz < BAD_REACH * BAD_REACH then near = true break end
                end
                table.insert(near and nearRefused or free, c)
            end
        end
    end
    if kind == "hill" then
        -- hill units: spots on parts named like a hill first; height-only spots (roofs, trees
        -- and walls look the same) only when none is named, or once one took a hill unit here
        local trust = (AutoPlace.hillBy or {})[stageKey()]
        local function named(list)
            local out = {}
            for _, c in ipairs(list) do if c.hillBy == "name" then table.insert(out, c) end end
            return out
        end
        local nf, nr = named(free), named(nearRefused)
        -- (Room 39: a named hill that covered no road won over a good height-only one)
        local function best(list) local m = 0 for _, c in ipairs(list) do m = math.max(m, cover(c)) end return m end
        local comparable = not attacks or best(nf) >= 0.7 * best(free)
        if trust == "name" or (trust ~= "height" and #nf + #nr > 0 and comparable) then free, nearRefused = nf, nr end
    end
    if #free == 0 then free = nearRefused end
    if role == "farm" then
        if #farms == 0 then return free[#free - skip] end
        -- farms side by side (one support unit then reaches them all), on low-value spots
        local scored = {}
        for _, c in ipairs(free) do
            table.insert(scored, { c = c, k = countNear(farms, c, 6) * 100000 - c.score })
        end
        table.sort(scored, function(a, b) return a.k > b.k end)
        return scored[skip + 1] and scored[skip + 1].c
    end
    if (role == "buff" or role == "support") and (#helpers > 0 or #farms > 0) then
        -- buff: next to the most damage units. support (also cheapens upgrades, e.g.
        -- hoshino): next to the farms it will cheapen, then damage units, within its range
        local reach = (range and range > 0 and range ~= DEFAULT_RANGE) and range or BUFF_REACH
        local scored = {}
        for _, c in ipairs(free) do
            local near = countNear(helpers, c, reach)
            if role == "support" then near = near + 2 * countNear(farms, c, reach) end
            -- buff units inside each other's reach: each one is buffed when it casts, so its
            -- own buff comes out stronger (Erwin chain), then it reaches the damage units
            if role == "buff" then near = near + 1.5 * countNear(buffers, c, reach) end
            table.insert(scored, { c = c, k = near * 100000 + c.score })
        end
        table.sort(scored, function(a, b) return a.k > b.k end)
        return scored[skip + 1] and scored[skip + 1].c
    end
    if role ~= "buff" and role ~= "support" then
        local r = (range and range > 0) and range or DEFAULT_RANGE
        -- Fast clear: prefer spots near the enemy spawn (kills early, waves end sooner);
        -- Safe: near our base (last line, nothing slips past). Balanced: road covered only.
        local mode = AutoPlaceModule.Mode()
        local spawn, goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("pve"), AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
        local scored = {}
        for _, c in ipairs(free) do
            local n, passes, inside = 0, 0, false
            local r2 = r * r - (c.rise or 0) ^ 2
            for _, q in ipairs(pts) do
                local dx, dz = q[1] - c.x, q[3] - c.z
                local hit = dx * dx + dz * dz <= r2
                if hit then n = n + 1 end
                if hit and not inside then passes = passes + 1 end
                inside = hit
            end
            -- area attacks hit the whole crowd: a spot where the road passes by two or three
            -- times (a bend, a U-turn) is worth more than one long straight
            if aoe and passes > 1 then n = n * (1 + 0.5 * (passes - 1)) end
            -- back: a trap unit that also hits flyers (Usopp) guards the last stretch before
            -- our base in every mode (owner): whatever slips past the front line meets its traps
            if spawn and goal and (back or mode == "Fast clear" or mode == "Safe") then
                local ds = math.sqrt((c.x - spawn.X) ^ 2 + (c.z - spawn.Z) ^ 2)
                local dg = math.sqrt((c.x - goal.X) ^ 2 + (c.z - goal.Z) ^ 2)
                local nearSpawn = dg / math.max(1, ds + dg) -- 1 at the spawn, 0 at our base
                -- (back alone leans softer than Safe: a spot that still covers a lot of road
                -- near the base beats a tiny corner right at the gate)
                if mode == "Fast clear" and not back then n = n * nearSpawn ^ 2
                elseif mode == "Safe" then n = n * (1 - nearSpawn) ^ 2
                else n = n * (1 - nearSpawn) end
            end
            table.insert(scored, { c = c, n = n })
        end
        table.sort(scored, function(a, b) return a.n > b.n end)
        return scored[skip + 1] and scored[skip + 1].c
    end
    return free[skip + 1]
end

-- Trait names out of whatever shape the game stores them in: "golden", { "golden" },
-- { golden = true }, { golden = 1 }, { { name = "range", level = 2 } }, nested one more level.
-- Free text is kept only when it is a known trait word or a short plain name.
function AutoPlaceModule.CollectTraits(val, out, depth, key)
    out, depth = out or {}, depth or 0
    local function add(text)
        text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
        local word = string.lower(text):match("^%a+")
        if not word or #text > 24 or text:find("-", 1, true) then return end
        if TRAIT_IDS[word] then text = TRAIT_IDS[word] .. text:sub(#word + 1) end
        if not TRAITS[word] and (depth > 1 or text:find("%d%d%d")) then return end
        for _, have in ipairs(out) do if string.lower(have) == string.lower(text) then return end end
        table.insert(out, text)
    end
    if type(val) == "string" then
        if val ~= "" then add(val) end
    elseif (val == true or type(val) == "number") and type(key) == "string" then
        local word = string.lower(key):match("^%a+")
        if word and TRAITS[word] then
            add(type(val) == "number" and val > 1 and val <= 3 and (key .. " " .. math.floor(val)) or key)
        end
    elseif type(val) == "table" and depth < 3 then
        local name = rawget(val, "name") or rawget(val, "id") or rawget(val, "trait") or rawget(val, "trait_id") or rawget(val, "type")
        if type(name) == "string" then
            local lvl = tonumber(rawget(val, "level") or rawget(val, "tier") or rawget(val, "rank"))
            add(lvl and lvl > 1 and (name .. " " .. math.floor(lvl)) or name)
        else
            for k, v in pairs(val) do AutoPlaceModule.CollectTraits(v, out, depth + 1, type(k) == "string" and k or nil) end
        end
    end
    return out
end

-- Team = equipped units { slot -> {uuid, name} }: from the game's own data (getgc), plus
-- any unit of ours already on the map (its _stats.uuid), so it works without getgc too.
-- Traits and rolls found once are remembered per unit (AutoPlace.unitInfo, saved), so a
-- game where the game data cannot be read still knows them.
-- Random-equipped events (Fool's Hunt: LevelData._randomequippedmode): the hotbar holds random
-- level-100 copies of the player's units made when the game started, not the equipped team.
AutoPlaceModule.loadUnix = os.time()
-- live random copies as the game announces them (watched: unit_added_temporary({ uuid,
-- unit_id, _creation_time, ... }) every 10 s; unit_removed_temporary when one goes);
-- badTemp: copies the game refused to place
AutoPlaceModule.liveTemp, AutoPlaceModule.goneTemp, AutoPlaceModule.badTemp, AutoPlaceModule.tempVersion = {}, {}, {}, 0
AutoPlaceModule.usedSlot = {}
AutoPlaceModule.EVENT_CAP = 20
task.spawn(pcall, function()
    local stc = ReplicatedStorage:WaitForChild("endpoints", 5):WaitForChild("server_to_client", 5)
    local function uuidOf(v) return type(v) == "table" and v.uuid and tostring(v.uuid) or (type(v) == "string" and v or nil) end
    stc:WaitForChild("unit_added_temporary", 5).OnClientEvent:Connect(function(data)
        local uuid = uuidOf(data)
        if uuid and type(data) == "table" and data.unit_id then
            AutoPlaceModule.liveTemp[uuid] = { id = tostring(data.unit_id), made = tonumber(data._creation_time) or os.time(), seen = os.clock(),
                shiny = data.shiny == true, rolls = type(data.trait_stats) == "table" and data.trait_stats or nil }
            AutoPlaceModule.goneTemp[uuid] = nil
            AutoPlaceModule.tempVersion = AutoPlaceModule.tempVersion + 1
        end
    end)
    stc:WaitForChild("unit_removed_temporary", 5).OnClientEvent:Connect(function(data)
        local uuid = uuidOf(data)
        if uuid then
            AutoPlaceModule.liveTemp[uuid], AutoPlaceModule.goneTemp[uuid] = nil, true
            AutoPlaceModule.tempVersion = AutoPlaceModule.tempVersion + 1
        end
    end)
end)
function AutoPlaceModule.EventMode()
    local d = Stage.levelData()
    return type(d) == "table" and rawget(d, "_randomequippedmode") ~= nil
end

-- The event hotbar: slot -> unit id (the model shown in PlayerGui.spawn_units...Units.<slot>)
-- and price; the uuid is the game's table for a unit made this session (_creation_time) with
-- that unit_id and no equipped_slot (the real collection was made long ago).
-- The bar shows a unit's model by its base name ("fujitora" for fujitora_evolved, ":shiny"
-- for skins): unit ids are compared on that base.
function AutoPlaceModule.BaseId(id) return (tostring(id):gsub(":.*$", ""):gsub("_evolved$", "")) end
function AutoPlaceModule.HotbarTeam()
    local team, pool, used = {}, {}, {}
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local bar = gui and gui:FindFirstChild("spawn_units")
    bar = bar and bar:FindFirstChild("Lives")
    bar = bar and bar:FindFirstChild("Frame")
    bar = bar and bar:FindFirstChild("Units")
    local slots, sig = {}, {}
    for s = 1, 6 do
        local slot = bar and bar:FindFirstChild(tostring(s))
        local view = slot and slot:FindFirstChild("Main") and slot.Main:FindFirstChild("View")
        local world = view and view:FindFirstChildOfClass("WorldModel")
        local model = world and world:FindFirstChildOfClass("Model")
        if model then
            local priceLabel = slot:FindFirstChild("Cost") and slot.Cost:FindFirstChild("text")
            -- (a slot whose copy was placed may keep showing that unit: skipped until the game
            -- announces a newer copy of it)
            local used = AutoPlaceModule.usedSlot[s]
            local stale = used and AutoPlaceModule.BaseId(used.id) == AutoPlaceModule.BaseId(model.Name)
            if stale then
                for _, info in pairs(AutoPlaceModule.liveTemp) do
                    if AutoPlaceModule.BaseId(info.id) == AutoPlaceModule.BaseId(used.id) and (info.seen or 0) > used.at then stale = false end
                end
            end
            if not stale then
                slots[s] = { id = AutoPlaceModule.BaseId(model.Name), model = model,
                    price = priceLabel and tonumber((tostring(priceLabel.Text):gsub("[^%d]", ""))) }
                sig[#sig + 1] = s .. "=" .. slots[s].id
            end
        end
    end
    -- getgc walks all of memory: only when the units on the bar changed (or the game said a
    -- unit was added / removed: tempVersion)
    sig = table.concat(sig, ",") .. "#" .. AutoPlaceModule.tempVersion
    if sig == AutoPlaceModule.hotbarSig and AutoPlaceModule.hotbarTeam
        and (AutoPlaceModule.hotbarComplete or os.clock() < (AutoPlaceModule.hotbarRetry or 0)) then
        return AutoPlaceModule.hotbarTeam
    end
    -- candidates per unit id, newest first: copies the game announced (unit_added_temporary),
    -- then any made this session found in memory. A replay in the same server leaves the last
    -- game's copies in memory: placing those is refused (money piled up to 28k in a real game)
    local found = {}
    for uuid, info in pairs(AutoPlaceModule.liveTemp) do
        table.insert(found, { id = info.id, uuid = uuid, made = info.made + 1e9, shiny = info.shiny, rolls = info.rolls })
    end
    -- (once the game announced copies this run, only those count: memory also holds old ones)
    if #found == 0 and type(getgc) == "function" then
        -- (units already on the map have their own tables too: never one of those)
        local onMap = {}
        for _, u in ipairs(ownedUnits()) do
            local st = u:FindFirstChild("_stats")
            local id = st and st:FindFirstChild("uuid")
            if id then onMap[tostring(id.Value)] = true end
        end
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and rawget(v, "uuid") and rawget(v, "unit_id") and rawget(v, "equipped_slot") == nil then
                    local made = tonumber(rawget(v, "_creation_time"))
                    if made and made >= AutoPlaceModule.loadUnix - 1800 and not onMap[tostring(rawget(v, "uuid"))] then
                        table.insert(found, { id = tostring(rawget(v, "unit_id")), uuid = tostring(rawget(v, "uuid")), made = made })
                    end
                end
            end
        end)
    end
    table.sort(found, function(a, b) return a.made > b.made end)
    for _, f in ipairs(found) do
        if not AutoPlaceModule.goneTemp[f.uuid] and not AutoPlaceModule.badTemp[f.uuid] then
            local key = AutoPlaceModule.BaseId(f.id)
            pool[key] = pool[key] or {}
            local dup = false
            for _, u in ipairs(pool[key]) do if u.uuid == f.uuid then dup = true end end
            if not dup then table.insert(pool[key], { uuid = f.uuid, id = f.id, shiny = f.shiny, rolls = f.rolls }) end
        end
    end
    local complete = true
    for s = 1, 6 do
        local sl = slots[s]
        if sl then
            for _, entry in ipairs(pool[sl.id] or {}) do
                local uuid = entry.uuid
                if not used[uuid] then
                    used[uuid] = true
                    team[s] = { uuid = uuid, name = entry.id, cost = sl.price, temp = true, traits = {}, rolls = entry.rolls or {}, model = sl.model, slot = s, shiny = entry.shiny }
                    break
                end
            end
            if not team[s] then complete = false end
        end
    end
    -- (a slot without its uuid yet is looked up again in 30 s, or when the bar changes)
    AutoPlaceModule.hotbarSig, AutoPlaceModule.hotbarComplete = sig, complete
    AutoPlaceModule.hotbarRetry = os.clock() + 30
    AutoPlaceModule.hotbarTeam = team
    return team
end

function AutoPlaceModule.RefreshTeam()
    local team = {}
    -- (set from the stage every time: once on, it stayed on - a later normal stage would then run
    -- the event brain, which finds no random copies and places nothing)
    State.eventMode = AutoPlaceModule.EventMode()
    if State.eventMode then
        -- (never saved as lastTeam: these copies vanish when the game ends)
        local hot = AutoPlaceModule.HotbarTeam()
        for _, t in pairs(hot) do
            local def = AutoPlaceModule.UnitDef(t.name)
            t.cost = t.cost or (def and tonumber(def.cost))
            t.gameCap = def and tonumber(def.spawn_cap) or nil
            if t.gameCap then AutoPlace.caps[t.name] = t.gameCap end
        end
        AutoPlaceModule.team, AutoPlaceModule.teamReadAt = hot, os.clock()
        AutoPlaceModule.hotbarAt = os.clock()
        return hot
    end
    if type(getgc) == "function" then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and rawget(v, "uuid") and rawget(v, "equipped_slot") and rawget(v, "unit_id") then
                    local okOne, errOne = pcall(function()
                    local slot = tonumber(rawget(v, "equipped_slot"))
                    if slot and slot >= 1 and slot <= 6 then
                        -- this copy's random rolls (speed_stat, potency_stat, range_stat, ...)
                        local rolls, keys, traits = {}, {}, {}
                        for k, val in pairs(v) do
                            local key = tostring(k)
                            local lower = string.lower(key)
                            table.insert(keys, key)
                            if type(val) == "number" and lower:find("stat", 1, true) then rolls[key] = val end
                            if type(val) == "table" and lower:find("stat", 1, true) then
                                for rk, rv in pairs(val) do
                                    if type(rv) == "number" then rolls[tostring(rk)] = rv end
                                end
                            end
                            -- named traits (Divine, Godspeed, Sniper II, ...) in any "trait" field
                            -- ("trait_stats" holds numbers like range = 1.1, not names)
                            if lower:find("trait", 1, true) and not lower:find("stat", 1, true) then
                                AutoPlaceModule.CollectTraits(val, traits, 0)
                            end
                        end
                        table.sort(keys)
                        -- raw trait data for the game data report (its exact shape is not known yet)
                        local raw = {}
                        for _, key in ipairs({ "traits", "trait_stats" }) do
                            local val = rawget(v, key)
                            if type(val) == "table" then
                                local parts = {}
                                for tk, tv in pairs(val) do
                                    if type(tv) == "table" then
                                        local inner = {}
                                        for ik, iv in pairs(tv) do table.insert(inner, tostring(ik) .. "=" .. tostring(iv)) end
                                        tv = "{" .. table.concat(inner, ",") .. "}"
                                    end
                                    table.insert(parts, tostring(tk) .. "=" .. tostring(tv))
                                end
                                table.insert(raw, key .. "{" .. table.concat(parts, ",") .. "}")
                            elseif val ~= nil then
                                table.insert(raw, key .. "=" .. tostring(val))
                            end
                        end
                        team[slot] = { uuid = tostring(rawget(v, "uuid")), name = tostring(rawget(v, "unit_id")),
                            rolls = rolls, traits = traits, traitRaw = table.concat(raw, " "), fields = table.concat(keys, ",") }
                    end
                    end)
                    if not okOne then AutoPlaceModule.teamError = clip(tostring(errOne), 120) end
                end
            end
        end)
    end
    -- The game does not always keep the team in memory (seen 2026-10-23: cid and elyssia
    -- never placed because only units already on the map were known). Remember the last
    -- team read from game data and fill the missing slots from it.
    AutoPlace.lastTeam = AutoPlace.lastTeam or {}
    if next(team) then
        -- (after a swap the old slots must not come back from memory)
        local now, changed = {}, false
        for slot, t in pairs(team) do now[tostring(slot)] = { uuid = t.uuid, name = t.name } end
        for k, v in pairs(now) do
            local old = AutoPlace.lastTeam[k]
            if not old or old.uuid ~= v.uuid or old.name ~= v.name then changed = true end
        end
        for k in pairs(AutoPlace.lastTeam) do if not now[k] then changed = true end end
        AutoPlace.lastTeam = now
        if changed then saveConfig() end
    else
        for k, v in pairs(AutoPlace.lastTeam) do
            local slot = tonumber(k)
            if slot then team[slot] = { uuid = v.uuid, name = v.name, fromLastTeam = true } end
        end
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
    AutoPlace.unitInfo = AutoPlace.unitInfo or {}
    local learned = false
    for s, t in pairs(team) do
        local old = AutoPlaceModule.team[s]
        if old and old.uuid == t.uuid then t.cost = old.cost end
        local key = (tostring(t.uuid):gsub("[{}%s]", ""))
        local info = AutoPlace.unitInfo[key]
        if t.fields then
            -- read from the game data just now: remember it (changes when traits are rerolled)
            local traitText = table.concat(t.traits or {}, ",")
            if not info or info.traits ~= traitText or info.name ~= t.name then
                AutoPlace.unitInfo[key] = { name = t.name, traits = traitText, rolls = t.rolls }
                learned = true
            end
        elseif info then
            t.traits, t.rolls, t.fromMemory = {}, info.rolls or {}, true
            for word in string.gmatch(info.traits or "", "[^,]+") do table.insert(t.traits, word) end
        end
        -- price and placement limit straight from the game's unit data, when it has them
        local def = AutoPlaceModule.UnitDef(t.name)
        if def then
            t.cost = t.cost or tonumber(def.cost)
            local gameCap = tonumber(def.spawn_cap)
            if gameCap and gameCap >= 1 then
                -- (a cap learned from a misread message must not stick: Speedwagon stayed at 1)
                AutoPlace.caps[t.name], t.gameCap = gameCap, gameCap
            elseif not AutoPlace.caps[t.name] then
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
    AutoPlaceModule.teamReadAt = os.clock()
    pcall(AutoPlaceModule.MigrateSkip)
    if learned then saveConfig() end
    if AutoPlaceModule.refreshSkipUI then pcall(AutoPlaceModule.refreshSkipUI) end
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

isSummon = function(unit)
    local def = AutoPlaceModule.UnitDef(unitType(unit))
    return def ~= nil and (tonumber(def.cost) or 0) <= 1
end

-- Decision log shown under Auto Place: what it placed / upgraded and why.
AutoPlaceModule.log = {}
function AutoPlaceModule.Note(text)
    local last = AutoPlaceModule.log[#AutoPlaceModule.log]
    if last and last.text == text then return end
    table.insert(AutoPlaceModule.log, { at = os.clock(), text = text })
    while #AutoPlaceModule.log > 6 do table.remove(AutoPlaceModule.log, 1) end
end

-- How many buff units of this kind keep the buff on all the time: cooldown / buff length,
-- once the rotation has measured them; 4 until then (the usual Erwin/Wendy rotation).
function AutoPlaceModule.BuffNeed(t)
    local g = BuffRot.groups[t.name]
    local dur = (UnitAI.buffDuration and UnitAI.buffDuration > 0 and UnitAI.buffDuration) or (g and (g.duration or g.durationAtLeast))
    if g and g.cd and g.cd > 0 and dur and dur > 0 then return math.max(1, math.ceil(g.cd / dur - 1e-6)) end
    return 4
end

-- Attack shape of a unit from ReplicatedStorage.src.Data.Attacks: true when its main attack
-- hits an area (aoe / aoe_dot / cone / line / full), false for single target, nil unknown.
local attacksModule
-- Area units the owner saw in game whose attack is not in the data (newer units): judar hits a
-- group for 78k at level 2 (2026-10-24)
AutoPlaceModule.AOE_SEEN = { judar_evolved = true }
function AutoPlaceModule.IsAoe(name)
    if AutoPlaceModule.AOE_SEEN[name] then return true end
    local def = AutoPlaceModule.UnitDef(name)
    local id = def and (def.primary_attack_no_upgrades or def.primary_attack)
    if type(id) ~= "string" then return nil end
    if attacksModule == nil then
        attacksModule = false
        pcall(function()
            local m = ReplicatedStorage.src.Data:FindFirstChild("Attacks")
            local ok, mod = pcall(require, m)
            if ok and type(mod) == "table" then attacksModule = mod end
        end)
    end
    local e = attacksModule and attacksModule[id]
    if type(e) ~= "table" then return nil end
    for _, k in ipairs({ "aoe", "aoe_dot", "cone", "line", "full", "circle" }) do
        if e[k] ~= nil then return true end
    end
    return false
end

-- Flying enemies can only be hit by hill units and hybrid units (wiki, UPD 20.4).
-- [unit id] = upgrade level from which a ground unit becomes hybrid (several do at some
-- level); the game's field for it is not known yet, so this stays empty until it is.
AutoPlaceModule.AirFromLevel = {}
function AutoPlaceModule.AirCapable(name, level)
    local def = AutoPlaceModule.UnitDef(name)
    if def and (def.hill_unit == true or def.hybrid_placement == true) then return true end
    local from = AutoPlaceModule.AirFromLevel[name]
    return from ~= nil and (level or 0) >= from
end

-- Number of flying enemies on the map (_stats.Flying 1 / true). Also counts every enemy seen
-- this game once (seen / seenFly), so the share of flyers is steady while a wave thins out.
AutoPlaceModule.seen, AutoPlaceModule.seenN, AutoPlaceModule.seenFly = setmetatable({}, { __mode = "k" }), 0, 0
function AutoPlaceModule.Flying()
    local folder = unitsFolder()
    local n = 0
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(u) then
            local st = u:FindFirstChild("_stats")
            local fl = st and st:FindFirstChild("Flying")
            local flies = fl ~= nil and (fl.Value == true or (tonumber(fl.Value) or 0) > 0)
            if flies then n = n + 1 end
            if AutoPlaceModule.seen[u] == nil then
                AutoPlaceModule.seen[u] = flies
                AutoPlaceModule.seenN = AutoPlaceModule.seenN + 1
                if flies then AutoPlaceModule.seenFly = AutoPlaceModule.seenFly + 1 end
            end
        end
    end
    return n
end

-- Road trap units (Usopp: path_ability / max_path_units) hit flyers only as they pass a trap:
-- not a full answer to them when the team has another air unit.
function AutoPlaceModule.IsTrap(name)
    local def = AutoPlaceModule.UnitDef(name)
    if not def then return false end
    if def.max_path_units ~= nil then return true end
    local id = def.primary_attack_no_upgrades or def.primary_attack
    local ok, entry = pcall(function()
        local m = ReplicatedStorage.src.Data:FindFirstChild("Attacks")
        local mod = m and require(m)
        return type(mod) == "table" and mod[id] or nil
    end)
    return ok and type(entry) == "table" and entry.path_ability ~= nil
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

-- Air focus is a quota, not a lock: while flyers are about, the air-capable share of the
-- placed damage (damage / s) should reach max(40%, share of flyers among enemies seen).
-- Below it, the next damage unit placed / upgraded is an air-capable one; above it the
-- normal order goes on. Traps count half when the team has another air unit.
function AutoPlaceModule.AirNeed()
    -- (Fool's Hunt: flyers come from wave 10 and one unhit flyer ends the game; the strategy search
    -- kept 3 units that hit them by wave 8 - so from wave 6 they are made ready before any flies)
    local early = false
    if State.eventMode and not AutoPlaceModule.flying and AutoPlaceModule.WaveNumber() >= 6 then
        local n = 0
        for _, u in ipairs(ownedUnits()) do
            local lvl = AutoPlaceModule.StatNum(u, "upgrade") or 0
            if unitRole(u) == "dps" and AutoPlaceModule.AirCapable(unitType(u) or "", lvl) then n = n + 1 end
        end
        early = n < 3
    end
    if not AutoPlaceModule.flying and not early then AutoPlaceModule.airShare = nil return false end
    -- another air unit that is on the map or can go down now (a hill unit with no hill spot
    -- does not count: then the trap unit is the whole answer)
    local realAir = false
    for _, tm in pairs(AutoPlaceModule.team) do
        if (AutoPlaceModule.RoleOf(tm) or "dps") == "dps" and AutoPlaceModule.AirCapable(tm.name, math.huge)
            and not AutoPlaceModule.IsTrap(tm.name) then
            local placedNow = #placedOf(tm.uuid) > 0
            local blocked = AutoPlaceModule.full[tm.uuid] or (AutoPlaceModule.noSpot[tm.uuid] or 0) > os.clock()
            if placedNow or not blocked then realAir = true end
        end
    end
    AutoPlaceModule.airRealInTeam = realAir
    local air, total = 0, 0
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            local name = unitType(u)
            local lvl = u:FindFirstChild("_stats") and u._stats:FindFirstChild("upgrade")
            local s = AutoPlaceModule.Stats({ name = name, placedSample = u })
            -- (a placed copy's own _stats.damage already includes its upgrades)
            local grown = u._stats:FindFirstChild("damage") and 1 or (1 + 0.5 * (lvl and tonumber(lvl.Value) or 0))
            local d = s.damage / math.max(0.1, s.cooldown) * grown
            total = total + d
            if AutoPlaceModule.AirCapable(name, lvl and tonumber(lvl.Value) or 0) then
                air = air + d * ((realAir and AutoPlaceModule.IsTrap(name)) and 0.5 or 1)
            end
        end
    end
    local target = math.max(0.4, AutoPlaceModule.seenFly / math.max(1, AutoPlaceModule.seenN))
    AutoPlaceModule.airShare, AutoPlaceModule.airTarget = total > 0 and air / total or 0, target
    return air <= 0 or air / total < target
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
    -- an event copy's placed unit may carry a new uuid: count that unit type on the map too
    local function sameType()
        local n = 0
        for _, u in ipairs(ownedUnits()) do if unitType(u) == t.name then n = n + 1 end end
        return n
    end
    local typeCount = t.temp and sameType() or nil
    local y = spot.groundY or groundAt(spot.x, spot.y, spot.z)
    local repliedAt
    AutoPlaceModule.inFlight, AutoPlaceModule.inFlightAt = true, os.clock()
    task.spawn(function()
        pcall(function() remote:InvokeServer(t.uuid, CFrame.new(spot.x, y, spot.z)) end)
        repliedAt = os.clock()
        AutoPlaceModule.inFlight = nil
    end)
    -- Success = the unit shows up. A refusal is known once the server has answered and
    -- nothing appeared shortly after, so a refused spot costs well under a second.
    local deadline = os.clock() + 2
    while os.clock() < deadline and not (repliedAt and os.clock() - repliedAt > 0.3) do
        task.wait(0.1)
        local now = placedOf(t.uuid)
        if typeCount and #now <= count and sameType() > typeCount then
            AutoPlaceModule.lastTry = t.name .. ": placed (new uuid)"
            return true
        end
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
    AutoPlaceModule.lastTry = string.format("%s: %s", t.name, repliedAt and "refused" or "no reply yet")
    return false
end

-- Cost of a placed unit's next upgrade from its definition (upgrade[level+1].cost), and
-- whether it can still be upgraded.
local function nextUpgrade(u, level)
    local stats = u:FindFirstChild("_stats")
    local id = stats and stats:FindFirstChild("id")
    local def = AutoPlaceModule.UnitDef(id and tostring(id.Value) or u.Name)
    local up = def and (def.upgrade or def.upgrades)
    local maxLvl = stats and stats:FindFirstChild("max_upgrade")
    local maxN = (maxLvl and tonumber(maxLvl.Value)) or (type(up) == "table" and #up > 0 and #up) or nil
    if maxN and level >= maxN then return false, nil end
    local step = type(up) == "table" and up[level + 1]
    return true, type(step) == "table" and tonumber(step.cost) or nil
end

-- Control skills (Shadowgirl's time stop, freeze, stun): each upgrade of a copy brings its
-- skill back sooner / wider ("+ Temporal Grenade [-14s Timestop Cooldown]"), so one copy
-- of the type is pushed to max before the next copy gets any upgrade.
local ControlUp = {
    -- a control skill counts as worth this share of the unit's own damage per second at its
    -- base cooldown; a level that cuts the cooldown from 40 s to 30 s adds a third of that
    WORTH = 1,
    -- STAND-IN until the real skill-upgrade fields are known (the game data report lists
    -- every upgrade level): when no level carries a skill field, each upgrade of a control
    -- unit counts this share of its own damage per second on top of the damage it gains
    BONUS = 0.5,
    BASE_CD = 45, -- skill cooldown when neither the definition nor the unit says (Shadowgirl ~44 s)
}

-- Skill fields of one upgrade level: new skill cooldown, seconds cut off it, new skill
-- reach (range / aoe / radius of the active), and whether any skill field was there.
-- Field names are not known for sure: any key naming the active/skill/ability and a
-- cooldown or reach counts, plus a "-14s Timestop Cooldown" style note text.
function ControlUp.fields(step)
    local cd, cut, reach, any, noteCut
    for k, v in pairs(step) do
        local key, n = string.lower(tostring(k)), tonumber(v)
        local skill = key:find("active", 1, true) or key:find("skill", 1, true) or key:find("ability", 1, true)
        if n and (key:find("cooldown", 1, true) or key:find("_cd", 1, true)) and (skill or (key:find("reduc", 1, true) and not key:find("attack", 1, true))) then
            if key:find("reduc", 1, true) or key:find("cut", 1, true) then cut = (cut or 0) + math.abs(n) else cd = n end
            any = true
        elseif n and skill and (key:find("range", 1, true) or key:find("aoe", 1, true) or key:find("radius", 1, true) or key:find("size", 1, true)) then
            reach, any = n, true
        elseif type(v) == "string" and (key:find("note", 1, true) or key:find("desc", 1, true) or key == "text") then
            for num, words in string.lower(v):gmatch("%-%s*([%d%.]+)%s*s%s+([%a ]-)%s*cooldown") do
                if words ~= "attack" and words ~= "spa" and tonumber(num) then
                    noteCut, any = (noteCut or 0) + tonumber(num), true
                end
            end
        end
    end
    -- the note only counts when no number field says it already (no double cut)
    if not cd and not cut then cut = noteCut end
    return cd, cut, reach, any
end

-- Skill value of a control unit's next upgrade as a share of its own damage per second.
function ControlUp.share(def, up, level)
    local any = false
    for _, step in ipairs(up) do
        if type(step) == "table" and select(4, ControlUp.fields(step)) then any = true break end
    end
    if not any then return ControlUp.BONUS end
    local cd = tonumber(def.active_attack_cooldown) or tonumber(def.active_cooldown) or ControlUp.BASE_CD
    local reach = tonumber(def.active_attack_range) or tonumber(def.active_range)
    local oldCd, oldReach = cd, reach
    for i = 1, level + 1 do
        if i == level + 1 then oldCd, oldReach = cd, reach end
        local step = up[i]
        if type(step) == "table" then
            local c, cut, r = ControlUp.fields(step)
            cd = math.max(1, (c or cd) - (cut or 0))
            reach = r or reach
        end
    end
    local gain = math.max(0, oldCd / cd - 1)
    if oldReach and reach and oldReach > 0 then gain = gain + math.max(0, reach / oldReach - 1) end
    return gain * ControlUp.WORTH
end

-- Copies of a control unit that may be upgraded now: per unit type only the copy with the
-- highest level (tie: the first placed) until it is maxed. Other units are not in the set.
function ControlUp.focus(units, now)
    local best, out = {}, {}
    for _, u in ipairs(units) do
        if BuffRot.isControlSkill(u) and (ControlUp.fails[u] or 0) < now then
            local level = AutoPlaceModule.StatNum(u, "upgrade") or 0
            local key = unitType(u)
            if nextUpgrade(u, level) and (not best[key] or level > best[key].level) then best[key] = { u = u, level = level } end
        end
    end
    for _, b in pairs(best) do out[b.u] = true end
    return out
end
-- allowed(u) is false only for a control copy that is not its type's focus copy
function ControlUp.allowed(u, focus)
    return focus[u] == true or not BuffRot.isControlSkill(u)
end

-- Fusion (Carrot + Vego: goku_ssj3 and vegeta_majin each get a "vegito_fusion..." skill at
-- upgrade 7, together they become Vegito). Read from the definitions: a unit whose upgrade
-- level gives an active_attack with "fusion" in it; the part up to "fusion" pairs them.
-- Returns key, level or nil.
function ControlUp.fusionOf(name)
    local def = AutoPlaceModule.UnitDef(name)
    local up = def and (def.upgrade or def.upgrades)
    if type(up) ~= "table" then return nil end
    for i, step in ipairs(up) do
        local a = type(step) == "table" and step.active_attack
        local key = type(a) == "string" and string.lower(a):match("^(.-fusion)")
        if key then return key, i end
    end
    return nil
end

-- Fusion pairs on the map: key -> list of { u, level, need }, the highest-level copy of each
-- unit type, only when two or more types share the key (both halves are placed).
function ControlUp.fusionPairs(units)
    local byKey, out = {}, {}
    -- no fusion in the Infinity Tower (owner): the money there goes into raw strength, and the
    -- fusion would also take Carrot (a hill unit that hits flyers) off the map
    local where = string.lower(tostring(Stage.mode or "") .. " " .. tostring(State.stage or ""))
    if where:find("infinite_tower", 1, true) or where:find("infinity mansion", 1, true) then return out end
    for _, u in ipairs(units) do
        local name = unitType(u)
        local key, need = ControlUp.fusionOf(name)
        if key then
            local k = byKey[key] or {}
            byKey[key] = k
            local level = AutoPlaceModule.StatNum(u, "upgrade") or 0
            if not k[name] or level > k[name].level then k[name] = { u = u, level = level, need = need } end
        end
    end
    for key, k in pairs(byKey) do
        local list = {}
        for _, c in pairs(k) do table.insert(list, c) end
        if #list >= 2 then out[key] = list end
    end
    return out
end

-- Copies still on the way to their fusion level: u -> level (a level with no damage gain
-- still counts a little for them, so they keep moving once better upgrades are done).
function ControlUp.fusionFocus(units)
    local out = {}
    for _, list in pairs(ControlUp.fusionPairs(units)) do
        for _, c in ipairs(list) do
            if c.level < c.need then out[c.u] = c.level end
        end
    end
    return out
end

-- Both halves at their fusion level: press the fusion skill (one press; pressed again after
-- 15 s if both are still on the map).
ControlUp.fusedAt = {}
function ControlUp.FusionStep()
    for key, list in pairs(ControlUp.fusionPairs(ownedUnits())) do
        local ready = true
        for _, c in ipairs(list) do if c.level < c.need then ready = false end end
        if ready and os.clock() - (ControlUp.fusedAt[key] or -1e9) >= 15 then
            ControlUp.fusedAt[key] = os.clock()
            if fireActiveAttack(list[1].u) then
                AutoPlaceModule.Note(string.format("fusion: %s + %s", unitType(list[1].u), unitType(list[2].u)))
            end
        end
    end
end

-- Damage per second a placed unit gains from its next upgrade, scaled by the copy's own
-- trait and rolls (a Golden / high-roll carry gains more from the same upgrade); control
-- units add the skill's worth (ControlUp.share).
local upgradeFails = setmetatable({}, { __mode = "k" })
ControlUp.fails = upgradeFails
local function upgradeGain(u, level)
    local def = AutoPlaceModule.UnitDef(unitType(u))
    local up = def and (def.upgrade or def.upgrades)
    if def and (type(up) ~= "table" or #up == 0) then
        -- (no upgrade list: an even share of the usual growth per level)
        local maxN = AutoPlaceModule.StatNum(u, "max_upgrade") or 8
        local base = (tonumber(def.damage) or 0) / math.max(0.5, AutoPlaceModule.DefCd(def))
        return level < maxN and base * (AutoPlaceModule.GROWTH - 1) / maxN * (AutoPlaceModule.IsAoe(unitType(u)) and AOE_VALUE or 1) or 0
    end
    if type(up) ~= "table" then return 0 end
    local function statsAt(n)
        local dmg, cd = tonumber(def.damage) or 0, AutoPlaceModule.DefCd(def)
        for i = 1, n do
            local step = up[i]
            if type(step) == "table" then
                dmg = tonumber(step.damage) or dmg
                cd = tonumber(step.attack_cooldown) or cd
            end
        end
        return dmg / math.max(0.5, cd)
    end
    local mult = 1
    local uuid = u:FindFirstChild("_stats") and u._stats:FindFirstChild("uuid")
    for _, t in pairs(AutoPlaceModule.team) do
        if uuid and normUuid(t.uuid) == normUuid(uuid.Value) then
            local tm, rolls = AutoPlaceModule.TraitMods(t.traits), t.rolls or {}
            mult = tm.dmg / tm.spa * (rolls.potency_stat or 1) * (rolls.speed_stat or 1)
        end
    end
    -- same area-attack weight as Value, so "upgrade it or place another copy" compares like with like
    if AutoPlaceModule.IsAoe(unitType(u)) then mult = mult * AOE_VALUE end
    local skill = BuffRot.isControlSkill(u) and ControlUp.share(def, up, level) * statsAt(level + 1) or 0
    return (math.max(0, statsAt(level + 1) - statsAt(level)) + skill) * mult
end

-- Damage per second at the last upgrade over the base one, the middle of the units whose upgrade
-- lists are known (bee_girl 13x, medea 22x, esdeath 17x, tatsumaki 17x, metal_knight 25x ...).
-- About half the roster (fujitora, konan, sakamoto, gyutaro, frieren, saber ...) has no list in
-- the unit data: judged at base strength they were X'd as "far below the team" and never got
-- upgrades picked (real games 2026-10-24).
AutoPlaceModule.GROWTH = 17
-- farms the owner keeps (2026-10-24): 3 speedwagons + 1 bulma, all upgraded to the top
AutoPlaceModule.FARM_COUNT = { speedwagon = 3, bulma = 1 }
function AutoPlaceModule.IsShiny(u)
    local st = u:FindFirstChild("_stats")
    local v = st and st:FindFirstChild("shiny")
    return v ~= nil and v.Value == true
end

-- Fool's Hunt: damage per second a unit kind reaches fully upgraded (its definition), area
-- attacks counted higher. Used to tell a strong random copy from a weak one.
function AutoPlaceModule.MaxDps(name)
    local def = AutoPlaceModule.UnitDef(name)
    if not def then return nil end
    local dmg, cd = tonumber(def.damage) or 0, AutoPlaceModule.DefCd(def)
    local up = def.upgrade or def.upgrades
    -- (newer units keep their upgrades in a form not read here: their full strength is guessed)
    if type(up) ~= "table" or #up == 0 then
        return dmg / math.max(0.5, cd) * AutoPlaceModule.GROWTH * (AutoPlaceModule.IsAoe(name) and AOE_VALUE or 1)
    end
    for _, step in ipairs(type(up) == "table" and up or {}) do
        if type(step) == "table" then
            dmg = tonumber(step.damage) or dmg
            cd = tonumber(step.attack_cooldown) or cd
        end
    end
    return dmg / math.max(0.5, cd) * (AutoPlaceModule.IsAoe(name) and AOE_VALUE or 1)
end

-- Fool's Hunt: a damage copy weaker than the damage units already down (under 70% of their
-- middle one, fully upgraded) would only take one of the 20 places - a real game hit the limit
-- with 20 units, many weak or never upgraded. Owner, 2026-10-24: place only the strong ones,
-- X the rest so the slot rolls again. Judged once 4 damage units are down.
-- (40% while under 10 units: places are plenty early and the team must grow)
-- (strategy search, 400 settings x 300 games: the best ones X copies under the team's middle
-- unit once the map has a few units, and keep almost anything while it is small)
AutoPlaceModule.WEAK_SHARE, AutoPlaceModule.WEAK_SHARE_EARLY = 1.0, 0.2
function AutoPlaceModule.EventWeak(t, role)
    if not State.eventMode or not t or not t.temp or role ~= "dps" then return false end
    -- (a unit that hits flyers is never cleared: goku_ssj3 was, then a flyer walked in and took
    -- the full base in one go - real game 2026-10-24)
    if AutoPlaceModule.AirCapable(t.name, math.huge) then return false end
    local mine = AutoPlaceModule.MaxDps(t.name)
    if not mine then return false end
    local all = {}
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            local v = AutoPlaceModule.MaxDps(unitType(u))
            if v and v > 0 then table.insert(all, v) end
        end
    end
    if #all < 4 then return false end
    table.sort(all)
    local share = #ownedUnits() >= 8 and AutoPlaceModule.WEAK_SHARE or AutoPlaceModule.WEAK_SHARE_EARLY
    return mine < all[math.floor(#all / 2) + 1] * share
end

-- Fool's Hunt: a copy of a unit already at its own limit (bulma 1, speedwagon 3) cannot be
-- placed; trying it again and again held the money for 30 s at a time in a real game.
function AutoPlaceModule.EventCapped(t)
    if not State.eventMode or not t or not t.temp then return false end
    local def = AutoPlaceModule.UnitDef(t.name)
    local cap = def and tonumber(def.spawn_cap)
    if not cap then return false end
    local n, base = 0, AutoPlaceModule.BaseId(t.name)
    for _, u in ipairs(ownedUnits()) do
        if AutoPlaceModule.BaseId(unitType(u) or "") == base then n = n + 1 end
    end
    return n >= cap
end

-- Clears a Fool's Hunt copy with its X on the bar: the slot rolls a new one.
function AutoPlaceModule.DropCopy(t, why)
    local bar = Lobby.SpellSlotBar and Lobby.SpellSlotBar()
    local x = bar and bar:FindFirstChild(tostring(t.slot))
    x = x and x:FindFirstChild("Delete", true)
    AutoPlaceModule.badTemp[t.uuid] = true
    AutoPlaceModule.hotbarAt, AutoPlaceModule.hotbarSig = 0, nil
    if x then Lobby.TapGui(x) end
    AutoPlaceModule.Note(string.format("copy cleared: %s (%s)", t.name, why))
end

AutoPlaceModule.SUMMON_BUFF = { giselle_evolved = true, giselle = true }
-- owner 2026-10-24: saber carries the early game, 2 upgrades are enough; pucci is placed when money
-- is left over and then upgraded to the top (its skill speeds up the team's attacks)
-- (jiraiya and emilia slow the enemies: placed, never upgraded)
AutoPlaceModule.UP_CAP = { saber_evolved = 2, jiraiya_evolved = 0, emilia = 0 }
AutoPlaceModule.UP_FIRST = { pucci_heaven = true }
function AutoPlaceModule.SummonerDown(units)
    for _, o in ipairs(units) do
        local def = AutoPlaceModule.UnitDef(unitType(o) or "") or {}
        if def.spawn_unit or def.spawn_script or tostring(def.primary_attack_no_upgrades or ""):find("elyssia") then return true end
    end
    return false
end

-- Does this placed unit carry the trait (team data by uuid: traits = {{trait = "unique", tier = 1}})?
function AutoPlaceModule.HasTrait(u, name)
    local uuid = u:FindFirstChild("_stats") and u._stats:FindFirstChild("uuid")
    if not uuid then return false end
    for _, t in pairs(AutoPlaceModule.team) do
        if normUuid(t.uuid) == normUuid(uuid.Value) then
            for _, tr in pairs(type(t.traits) == "table" and t.traits or {}) do
                local id = type(tr) == "table" and (tr.trait or tr.id or tr.name) or tr
                if string.lower(tostring(id)) == name then return true end
            end
        end
    end
    return false
end

-- Best damage gained per ¥ from upgrading any placed damage unit (0 when none can be upgraded).
function AutoPlaceModule.BestUpgradeScore()
    local best, now = 0, os.clock()
    local units = ownedUnits()
    local focus = ControlUp.focus(units, now)
    for _, u in ipairs(units) do
        if unitRole(u) == "dps" and (upgradeFails[u] or 0) < now and ControlUp.allowed(u, focus) then
            local lvl = u:FindFirstChild("_stats") and u._stats:FindFirstChild("upgrade")
            local level = lvl and tonumber(lvl.Value) or 0
            local can, cost = nextUpgrade(u, level)
            if can and cost then best = math.max(best, upgradeGain(u, level) / math.max(1, cost)) end
        end
    end
    return best
end

-- One upgrade: farms first (they pay for the rest), then support, then damage. Buff units
-- (Erwin, Wendy ...) are never upgraded: their buff does not grow with it, money wasted.
-- Farms go lowest level first; damage units go by the most damage gained per ¥, so the
-- strongest unit (best trait / rolls / upgrade path) is pushed up first instead of spreading
-- thin. Control units (time stop) upgrade one copy to max before the next (ControlUp.focus).
-- onlyRole limits it to one role, airOnly to units that hit flyers. Returns seconds to wait,
-- or nil when nothing is left.
local function upgradeStep(money, onlyRole, airOnly, noWait)
    local remote = getAARemote("upgrade_unit_ingame")
    if not remote then return nil end
    -- (owner 2026-10-24: the always-on aura unit (hoshino: team damage +7% -> +15%, upgrades
    -- 10% -> 20% cheaper) is upgraded to the top early, with the farms; rotation buffers never)
    local RANK = { farm = 1, dps = 2, support = 1 }
    local pick, pickLevel, pickRank, pickCost, pickScore, pickRole, pickAir
    -- flying enemies on the map: damage units that can hit them (after this upgrade) go first
    local air = AutoPlaceModule.airNeed == true
    local now = os.clock()
    local units = ownedUnits()
    local focus = ControlUp.focus(units, now)
    local fuse = ControlUp.fusionFocus(units)
    for _, u in ipairs(units) do
        local role = unitRole(u)
        -- (owner: a Never unit is not upgraded either - akainu and Cream get slower with upgrades)
        local never = State.eventMode and AutoPlaceModule.InList(Lobby.cfg.eventNever, unitType(u))
        local capLvl = AutoPlaceModule.UP_CAP[unitType(u) or ""]
        if capLvl and (AutoPlaceModule.StatNum(u, "upgrade") or 0) >= capLvl then never = true end
        if role ~= "buff" and not never and (not onlyRole or role == onlyRole) and (upgradeFails[u] or 0) < now and ControlUp.allowed(u, focus)
            and not AutoPlaceModule.OutOfReach(u) then
            local stats = u:FindFirstChild("_stats")
            local lvl = stats and stats:FindFirstChild("upgrade")
            local level = lvl and tonumber(lvl.Value) or 0
            local can, cost = nextUpgrade(u, level)
            -- a farm upgrade must pay back in time (friend's Infinity Mansion loss: ~60k in farms
            -- by wave 9, Bulma at 6, the damage units barely upgraded)
            if can and role == "farm" and not AutoPlaceModule.FarmPays(u, level, cost) then can = false end
            -- (spare money only: an upgrade it cannot pay must not block one it can - a farm's
            -- 6500 upgrade held 30k unused in a real game)
            if can and noWait and cost and money and cost > money then can = false end
            if can then
                local rank = AutoPlaceModule.UP_FIRST[unitType(u) or ""] and 1 or RANK[role] or 2
                -- (an upgrade price not in the data: about the unit's price times the next level)
                local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
                local guess = (tonumber(def.cost) or 1000) * (level + 1)
                local score = (rank == 2) and (upgradeGain(u, level) / math.max(1, cost or guess)) or -level
                -- fusion halves go by value like everything else (Vegito is only ~16% more than
                -- the two at level 7, a forced push starved better upgrades: near loss in Hard
                -- Room 45); a level that adds no damage (Vego 6) still moves on toward the fusion
                if rank == 2 and fuse[u] then score = math.max(score, 1e-6) end
                -- (owner 2026-10-24: the Unique-trait unit is upgraded first, to the top)
                if rank == 2 and score > 0 and AutoPlaceModule.HasTrait(u, "unique") then score = score * 1e6 end
                -- (owner: giselle also raises summons' damage - worth twice its own gain while a
                -- summoner such as elyssia is down)
                if AutoPlaceModule.SUMMON_BUFF[unitType(u) or ""] and AutoPlaceModule.SummonerDown(units) then score = score * 2 end
                local isAir = air and role == "dps" and AutoPlaceModule.AirCapable(unitType(u), level + 1)
                    and not (AutoPlaceModule.airRealInTeam and AutoPlaceModule.IsTrap(unitType(u)))
                if airOnly and not isAir then
                    -- skip: only units that hit flyers this time
                elseif not pick or rank < pickRank or (rank == pickRank and isAir and not pickAir)
                    or (rank == pickRank and isAir == pickAir and score > pickScore) then
                    pick, pickLevel, pickRank, pickCost, pickScore, pickRole, pickAir = u, level, rank, cost, score, role, isAir
                end
            end
        end
    end
    if not pick then return nil end
    if noWait and pickCost and money and money < pickCost then return nil end
    if pickCost and money and money < pickCost then
        AutoPlaceModule.status = string.format("Upgrade %s to %d: waiting for money %d / %d", unitType(pick), pickLevel + 1, math.floor(money), math.floor(pickCost))
        return 0.2
    end
    AutoPlaceModule.status = string.format("Upgrading %s (level %d)", unitType(pick), pickLevel)
    AutoPlaceModule.tickStep = "upgrade"
    -- (an answer that never comes must not stop Auto Place: given up after 4 s)
    local answered = false
    task.spawn(function() pcall(function() remote:InvokeServer(pick) end) answered = true end)
    local giveUp = os.clock() + 4
    while not answered and os.clock() < giveUp do task.wait(0.1) end
    local lvl = pick:FindFirstChild("_stats") and pick._stats:FindFirstChild("upgrade")
    for _ = 1, 6 do -- the new level can replicate a moment after the reply
        if not lvl or (tonumber(lvl.Value) or 0) > pickLevel then break end
        task.wait(0.1)
    end
    if lvl and (tonumber(lvl.Value) or 0) > pickLevel then
        AutoPlaceModule.Note(string.format("upgraded %s to %d (%s%s)", unitType(pick), pickLevel + 1, pickRole,
            pickAir and ", hits flying enemies" or fuse[pick] and ", for the fusion" or BuffRot.isControlSkill(pick) and ", skill copy first" or (pickRank == 2 and ", most damage per ¥" or "")))
    elseif not (pickCost and money and money < pickCost) then
        -- refused with the money in hand: leave this unit for 30 s instead of retrying forever
        upgradeFails[pick] = now + 30
        AutoPlaceModule.Note(string.format("could not upgrade %s - skipped for 30 s", unitType(pick)))
    end
    return pickCost and 0.3 or 1.5
end

-- The game shows each team slot's price on the hotbar ("800 ¥") and the cash just above it
-- ("10175¥"). Reading them means the first placement of a game needs no guessing, and a
-- "Cannot place unit here!" spot is skipped at once instead of retried.
local function parseYen(text)
    -- "1350 ¥", "12352¥", the full-width "￥", and rich text tags stripped first
    local plain = tostring(text):gsub("<[^>]->", "")
    local num = plain:match("^%s*([%d,]+)%s*¥%s*$") or plain:match("^%s*([%d,]+)%s*￥%s*$")
    return num and tonumber((num:gsub(",", ""))) or nil
end

function AutoPlaceModule.ReadHud() return Scan.Cached("hud", AutoPlaceModule.ScanHud) end
function AutoPlaceModule.ScanHud()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil, {} end
    local labels = {}
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local v = parseYen(d.Text)
            if not v and d.Parent and tostring(d.Text):match("^%s*[%d,]+%s*$") then
                -- AA draws the price and the ¥ as two labels side by side ("2300" + symbol "¥")
                for _, sib in ipairs(d.Parent:GetChildren()) do
                    if sib ~= d and (sib:IsA("TextLabel") or sib:IsA("TextButton")) and parseYen("0" .. tostring(sib.Text)) == 0 then
                        v = tonumber((tostring(d.Text):gsub("[%s,]", "")))
                        break
                    end
                end
            end
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
            elseif (t:find("max", 1, true) or t:find("limit", 1, true))
                and (t:find("place", 1, true) or t:find("unit", 1, true) or t:find("reach", 1, true)) then kind = "cap" end
            if kind and isOnScreen(d) and not isOwnGui(d) then return kind end
        end
    end
    return nil
end

-- Role of a team unit before it is placed: remembered from earlier games, else guessed from
-- the game's unit data (a farm/income number = farm, a buff skill = buff). nil = not known.
function AutoPlaceModule.RoleOf(t)
    local fromDef = AutoPlaceModule.RoleFromDef(t.name)
    if fromDef then return fromDef end
    if AutoPlace.roles[t.name] then return AutoPlace.roles[t.name] end
    if UnitAI.learned[t.name] then return "buff" end
    return nil
end

-- Danger: the base HP bar at the top of the screen ("90.0/90.0") went down, i.e. enemies
-- got through. Stays on for 20 s after the last drop.
local dangerUntil, lastHp = 0, nil

local function basePos(side)
    return AutoPlaceModule.BasePos(side)
end
function AutoPlaceModule.BasePos(side)
    local bases = workspace:FindFirstChild("_BASES")
    local b = bases and bases:FindFirstChild(side)
    local base = b and b:FindFirstChild("base")
    if not base then return nil end
    local ok, p = pcall(function() return base:GetPivot().Position end)
    return ok and p or nil
end

function AutoPlaceModule.BaseHp() return Scan.Cached("basehp", AutoPlaceModule.ScanBaseHp) end
function AutoPlaceModule.ScanBaseHp()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    -- several "a / b" labels sit at the top (unit counts like 240/200, wave counters): the
    -- base HP is the one with the biggest maximum that is not over it
    local bestCur, bestMax
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) and d.AbsolutePosition.Y < 200 then
            local plain = tostring(d.Text):gsub("<[^>]->", ""):gsub(",", "")
            local cur, max = plain:match("^%s*(%d+%.?%d*)%s*/%s*(%d+%.?%d*)%s*$")
            cur, max = tonumber(cur), tonumber(max)
            if cur and max and max > 0 and cur <= max and (not bestMax or max > bestMax) then
                bestCur, bestMax = cur, max
            end
        end
    end
    return bestCur, bestMax
end

function AutoPlaceModule.EnemyProgress()
    local goal, start = basePos("player"), basePos("pve")
    if not goal or not start then return 0 end
    local total = math.sqrt((start.X - goal.X) ^ 2 + (start.Z - goal.Z) ^ 2)
    if total < 1 then return 0 end
    local best = 0
    local folder = unitsFolder()
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(u) then
            local p = rootPos(u)
            if p then
                local d = math.sqrt((p.X - goal.X) ^ 2 + (p.Z - goal.Z) ^ 2)
                best = math.max(best, 1 - d / total)
            end
        end
    end
    return best
end

-- A boss (5x the usual max HP; real bosses are ~10x) or several regenerating enemies on the map: damage first,
-- before the base gets hit. Returns the reason, or nil.
function AutoPlaceModule.Threat()
    local folder = unitsFolder()
    local hps, regen = {}, 0
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(u) then
            local st = u:FindFirstChild("_stats")
            local hpV = st and st:FindFirstChild("base_health")
            local rg = st and st:FindFirstChild("Regen")
            if hpV and tonumber(hpV.Value) then table.insert(hps, tonumber(hpV.Value)) end
            if rg and (rg.Value == true or (tonumber(rg.Value) or 0) > 0) then regen = regen + 1 end
        end
    end
    if #hps > 0 then
        table.sort(hps)
        -- what a normal enemy has: the median when there are a few on the map (remembered for
        -- the moments a boss walks almost alone), the weakest one when there are only two
        if #hps >= 3 then AutoPlaceModule.normalHp = hps[math.ceil(#hps / 2)] end
        local normal = (#hps >= 3 and hps[math.ceil(#hps / 2)]) or (#hps == 2 and hps[1]) or AutoPlaceModule.normalHp
        if normal and normal > 0 and hps[#hps] >= 5 * normal then return "boss on the map" end
    end
    if regen >= 3 then return string.format("%d regenerating enemies", regen) end
    return nil
end

function AutoPlaceModule.Danger()
    local now = os.clock()
    local hp = AutoPlaceModule.BaseHp()
    if hp then
        if lastHp and hp < lastHp - 1e-6 then dangerUntil = now + 20 end
        lastHp = hp
    end
    -- (enemy distance to our base is NOT used: winding roads pass near the base early and
    -- kept danger on all game; a base HP drop is the reliable sign)
    return now < dangerUntil
end

-- Last wave of the stage (workspace._is_last_wave); never true in infinite modes.
-- The wave now (workspace._wave_num in the real game, _DATA.Wave otherwise).
function AutoPlaceModule.WaveNumber()
    local alt = workspace:FindFirstChild("_wave_num")
    local w = alt and tonumber(alt.Value) or 0
    local data = workspace:FindFirstChild("_DATA")
    local v = data and (data:FindFirstChild("Wave") or data:FindFirstChild("CurrentWave"))
    if v and tonumber(v.Value) then w = math.max(w, tonumber(v.Value)) end
    return w
end

-- Does this farm upgrade pay back in half the waves left? (a stage counts as FARM_HORIZON
-- waves; endless events do not stop). Unknown numbers: yes, as before.
AutoPlaceModule.FARM_HORIZON = 15
function AutoPlaceModule.FarmPays(u, level, cost)
    if not cost then return true end
    local def = AutoPlaceModule.UnitDef(unitType(u))
    local up = def and (def.upgrade or def.upgrades)
    if type(up) ~= "table" or type(up[level + 1]) ~= "table" then return true end
    local now = level == 0 and tonumber(def.farm_amount) or (type(up[level]) == "table" and tonumber(up[level].farm_amount))
    local nextAmount = tonumber(up[level + 1].farm_amount)
    if not now or not nextAmount or nextAmount <= now then return true end
    -- (Fool's Hunt: the owner upgrades the farms to the top)
    if State.eventMode then return true end
    local left = AutoPlaceModule.FARM_HORIZON - AutoPlaceModule.WaveNumber()
    return cost / (nextAmount - now) <= left / 2
end

function AutoPlaceModule.LastWave()
    local v = workspace:FindFirstChild("_is_last_wave")
    return v ~= nil and v.Value == true
end

-- Sells one farm unit (not the unsellable ones); true when one was sold.
local soldFarms = setmetatable({}, { __mode = "k" })
function AutoPlaceModule.SellFarm()
    local remote = getAARemote("sell_unit_ingame")
    if not remote then return false end
    for _, u in ipairs(ownedUnits()) do
        local def = AutoPlaceModule.UnitDef(unitType(u))
        if unitRole(u) == "farm" and not soldFarms[u] and not (def and def.unsellable) then
            soldFarms[u] = true
            pcall(function() remote:InvokeServer(u) end)
            AutoPlaceModule.Note(string.format("sold %s: last wave, its yen goes to damage", unitType(u)))
            return true
        end
    end
    return false
end

-- Pick the next unit from the WHOLE team: first the damage unit with the best damage per ¥
-- (to hold wave 1), then every farm, then the rest spread evenly with damage before buffs.
-- In danger, the best-value damage unit first and nothing else (returns "upgrade" when none
-- is left). 5th result: the team's strongest damage unit (best damage per ¥) is on the map.
local function chooseNext(prices, danger)
    local list, dpsPlaced = {}, 0
    local strongest, strongestDown
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local copies = placedOf(t.uuid)
            local placed = #copies
            t.placedSample = copies[1]
            local role = AutoPlaceModule.RoleOf(t) or "dps"
            if role == "dps" then dpsPlaced = dpsPlaced + placed end
            local target = math.min(AutoPlaceModule.SlotTarget(s, t), tonumber(AutoPlace.caps[t.name]) or AutoPlaceModule.gameCaps[t.name] or 99,
                AutoPlaceModule.TraitMods(t.traits).cap or 99)
            -- an event copy is one unit: placed once, then its slot frees for the next random one
            if t.temp then target = math.min(target, 1) end
            -- slots set to 0 or found full with none down do not count as the strongest
            if role == "dps" and target > 0 and (placed > 0 or not AutoPlaceModule.full[t.uuid]) then
                local cost = t.cost or prices[s]
                local v = AutoPlaceModule.Value(t, cost)
                if not strongest or v > strongest then strongest, strongestDown = v, placed > 0 end
            end
            -- buff units: only as many as the rotation needs (6 Erwins = money not spent on damage)
            if role == "buff" then target = math.min(target, AutoPlaceModule.BuffNeed(t)) end
            local resting = (AutoPlaceModule.noSpot[t.uuid] or 0) > os.clock()
            if role == "farm" and AutoPlace.sellFarmsLast and AutoPlaceModule.LastWave() then resting = true end
            if not AutoPlaceModule.full[t.uuid] and not resting and placed < target then
                table.insert(list, { slot = s, t = t, role = role, placed = placed, target = target,
                    cost = t.cost or prices[s] or math.huge })
            end
        end
    end
    -- (no price known for any damage unit yet: values are all 0, nothing to wait for)
    strongestDown = strongestDown ~= false or (strongest or 0) <= 0
    if #list == 0 then return nil, nil, nil, dpsPlaced, strongestDown end
    -- damage unit with the most damage per ¥ (traits and rolls included); cheaper on a tie,
    -- so with no prices known yet this is the cheapest one
    -- (flying enemies on the map: the best one that can hit them, when one is left to place)
    local function bestDps()
        local best
        local air = AutoPlaceModule.airNeed == true
        for _, e in ipairs(list) do
            if e.role == "dps" then
                e.value = AutoPlaceModule.Value(e.t, e.cost ~= math.huge and e.cost or nil)
                -- 2 = air unit, 1 = road trap (when the team has another air unit), 0 = ground
                e.air = (air and AutoPlaceModule.AirCapable(e.t.name, 0)) and
                    ((AutoPlaceModule.airRealInTeam and AutoPlaceModule.IsTrap(e.t.name)) and 1 or 2) or 0
                if not best or e.air > best.air or (e.air == best.air
                    and (e.value > best.value or (e.value == best.value and e.cost < best.cost))) then best = e end
            end
        end
        return best
    end
    if danger then
        local best = bestDps()
        if best then return best.slot, best.t, best.role, dpsPlaced, strongestDown end
        return nil, nil, "upgrade", dpsPlaced, strongestDown
    end
    local function cheapest(role)
        local best
        for _, e in ipairs(list) do
            if e.role == role and (not best or e.cost < best.cost or (e.cost == best.cost and e.slot < best.slot)) then best = e end
        end
        return best
    end
    -- the best-value damage unit, then the farms, then support (cheaper upgrades before upgrading)
    local pick = (dpsPlaced == 0 and bestDps()) or cheapest("farm") or cheapest("support")
    -- air share below its quota: the next damage unit is an air-capable one (if one is left)
    if not pick and AutoPlaceModule.airNeed then
        local best = bestDps()
        if best and best.air > 0 then pick = best end
    end
    if not pick then
        for _, e in ipairs(list) do e.value = AutoPlaceModule.Value(e.t, e.cost ~= math.huge and e.cost or nil) end
        table.sort(list, function(a, b)
            local ra, rb = a.placed / math.max(1, a.target), b.placed / math.max(1, b.target)
            if math.abs(ra - rb) > 1e-6 then return ra < rb end
            if a.role ~= b.role then return a.role == "dps" end
            if math.abs(a.value - b.value) > 1e-9 then return a.value > b.value end
            return a.slot < b.slot
        end)
        pick = list[1]
    end
    return pick.slot, pick.t, pick.role, dpsPlaced, strongestDown
end

-- A spot refused with the money in hand. Hill units refused 3 times on height-only "hill"
-- spots on this stage: those are roofs / trees, use named hills only from now on. A unit
-- refused 6 times in a row rests 20 s so the rest of the team (buffs, farms, upgrades) goes on.
AutoPlaceModule.heightRefusals = {}
function AutoPlaceModule.SpotRefused(t, spot, kind)
    local key = stageKey()
    if kind == "hill" and spot.hillBy == "height" and AutoPlace.hillBy[key] ~= "height" then
        local n = (AutoPlaceModule.heightRefusals[key] or 0) + 1
        AutoPlaceModule.heightRefusals[key] = n
        if n >= 3 and AutoPlace.hillBy[key] ~= "name" then
            AutoPlace.hillBy[key] = "name"
            saveConfig()
            AutoPlaceModule.Note(string.format("%s refused on raised spots 3 times: they are roofs here, named hills only", t.name))
        end
    end
    t.spotRefused = (t.spotRefused or 0) + 1
    if t.spotRefused >= 6 then
        t.spotRefused = 0
        AutoPlaceModule.noSpot[t.uuid] = os.clock() + 20
        AutoPlaceModule.Note(string.format("%s refused on 6 spots in a row - the others go first for 20 s", t.name))
    end
end

-- Fool's Hunt brain: ONE decision a tick over every copy on the bar and every upgrade on the map,
-- in place of the stack of normal-stage rules that kept blocking each other there (saving for a
-- spell, waiting for a flyer upgrade, an empty bar, danger) - owner 2026-10-24: "it should have
-- been separate from the start". The policy is the strategy simulator's (sim/strategies.js act,
-- tested over 100k+ games): clear what is not wanted, then compare the best copy (its level-0
-- damage per yen x placeBonus) with the best upgrade (damage gained per yen) and do the better
-- one, saving for it when it cannot be paid yet. Farms, buff units and flyer hitters while short
-- go first. Returns seconds to wait, or nil and the copy to place.
-- owner's picks 2026-10-24, first placed first: judar (cid when no judar), sakamoto, nagumo (cuts
-- HP), saber (early carry), frieren and monet (flyers, slow), jiraiya and emilia (slow, no upgrades)
AutoPlaceModule.RANK = { "judar_evolved", "cid_evolved", "sakamoto_evolved", "nagumo_evolved", "saber_evolved", "frieren_evolved", "monet_evolved", "jiraiya_evolved", "emilia" }
AutoPlaceModule.ROSTER = { "akainu_evolved", "aokiji_evolved", "archer_evolved", "armin", "avdol_evolved", "bee_girl_evolved", "caesarclown_evolved", "cid_evolved", "daki_evolved", "demiurge_evolved", "emilia", "escanor_evolved", "esdeath_evolved", "frieren_evolved", "fujitora_evolved", "ghostkun_evolved", "gildarts_evolved", "gilgamesh_evolved", "goku_ssj3_evolved", "gremmy_evolved", "guts_berserker", "gyutaro_evolved", "hakari_evolved", "hidan_unit_evolved", "illya_evolved", "jiraiya_evolved", "josuke_2_evolved", "judar_evolved", "julius_evolved", "koichi_evolved", "konan_unit_evolved", "law_2_evolved", "medea_evolved", "meliodas_evolved", "metal_knight_evolved", "monet_evolved", "nagumo_evolved", "nagumo_evolved", "narberal_evolved", "naruto_6tails", "natsu_evolved", "pucci_heaven", "saber_evolved", "sabo_evolved", "sakamoto_evolved", "shalltear_evolved", "shigaraki_evolved", "stain_evolved", "sukuna", "tatsumaki_evolved", "tengen_2_evolved", "usopp_ts_evolved", "vanilla_ice_evolved" }
function AutoPlaceModule.InList(list, name)
    for _, n in ipairs(type(list) == "table" and list or {}) do if n == name then return true end end
    return false
end
AutoPlaceModule.EV = { placeBonus = 2, reserve = 0, airMin = 3, airBy = 8, buffUnits = 2, stuck = 25 }
function AutoPlaceModule.EventChoose(money)
    local EV, now = AutoPlaceModule.EV, os.clock()
    local wave = AutoPlaceModule.WaveNumber()
    local units = ownedUnits()
    local atCap = #units >= math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99)
    local air, buffs = 0, 0
    for _, u in ipairs(units) do
        local r = unitRole(u)
        if r == "dps" and AutoPlaceModule.AirCapable(unitType(u) or "", AutoPlaceModule.StatNum(u, "upgrade") or 0) then air = air + 1 end
        if r == "buff" or r == "support" then buffs = buffs + 1 end
    end
    local airShort = air < EV.airMin and wave <= EV.airBy + 5
    AutoPlaceModule.copySeen = AutoPlaceModule.copySeen or {}
    -- 1. every copy on the bar: cleared with its X, or a candidate
    local best, bestV = nil, -1
    for _, t in pairs(AutoPlaceModule.team) do
        if t.temp and not AutoPlaceModule.full[t.uuid] and not AutoPlaceModule.badTemp[t.uuid] then
            local role = AutoPlaceModule.RoleOf(t) or "dps"
            local why
            local always = AutoPlaceModule.InList(Lobby.cfg.eventAlways, t.name)
            if AutoPlaceModule.InList(Lobby.cfg.eventNever, t.name) then why = "on the never list"
            elseif role == "farm" then
                -- (owner: 3 speedwagons + 1 bulma, upgraded to the top, any more X'd; a golden
                -- (shiny) copy takes a normal one's place through a Refund)
                local same, plain = 0, nil
                for _, u in ipairs(units) do
                    if unitType(u) == t.name then
                        same = same + 1
                        if not AutoPlaceModule.IsShiny(u) then plain = u end
                    end
                end
                local cap = AutoPlaceModule.FARM_COUNT[t.name] or tonumber((AutoPlaceModule.UnitDef(t.name) or {}).spawn_cap) or 1
                if same >= cap then
                    if t.shiny and plain and Lobby.CastOn("sell_refund", plain) then return 1 end
                    why = t.shiny and "golden farm but no Refund in hand" or "farms full"
                end
            elseif AutoPlaceModule.EventCapped(t) then why = "its unit is at the limit"
            elseif role == "buff" or role == "support" then
                if buffs >= EV.buffUnits then why = "enough buff units" end
            elseif not always and AutoPlaceModule.EventWeak(t, role) then why = "far below the team"
            end
            local first = AutoPlaceModule.copySeen[t.uuid] or now
            AutoPlaceModule.copySeen[t.uuid] = first
            if not why and not atCap and now - first > EV.stuck and t.cost and money and money >= t.cost then why = "stuck on the bar" end
            if why then
                AutoPlaceModule.DropCopy(t, why)
                return 0.5
            end
            if not atCap and (AutoPlaceModule.noSpot[t.uuid] or 0) <= now then
                -- (an Always unit counts 3x, and more the stronger it ranks - AutoPlaceModule.RANK)
                local v = AutoPlaceModule.Value(t, t.cost or 1000) * EV.placeBonus
                if always then
                    local list, at = AutoPlaceModule.RANK, #AutoPlaceModule.RANK + 1
                    for i, n in ipairs(list) do if n == t.name then at = i end end
                    v = v * (3 + 2 * math.max(0, #list - at + 1) / #list)
                end
                if role == "farm" or role == "buff" or role == "support" or (airShort and AutoPlaceModule.AirCapable(t.name, 0)) then v = math.huge end
                if v > bestV then best, bestV = { t = t, role = role }, v end
            end
        end
    end
    -- 2. the best upgrade on the map, then the better of the two
    local upV = AutoPlace.upgrade and AutoPlaceModule.BestUpgradeScore() or 0
    local function canPay(b) return not b.t.cost or (money and money >= b.t.cost) end
    if best and bestV >= upV then
        if canPay(best) then return nil, best.t, best.role end
        AutoPlaceModule.status = string.format("Saving for %s: %d / %d", best.t.name, math.floor(money or 0), math.floor(best.t.cost))
        return 0.2
    end
    if AutoPlace.upgrade then
        local wait = upgradeStep((money or 0) - EV.reserve, nil, nil, true)
        if wait then return wait end
        if upV > 0 then
            AutoPlaceModule.status = "Saving for the best upgrade"
            return 0.3
        end
    end
    if best and canPay(best) then return nil, best.t, best.role end
    AutoPlaceModule.status = best and "Waiting for money" or (atCap and "Unit limit reached - upgrading" or "Waiting for the next copy")
    return 0.5
end

local function tick()
    AutoPlaceModule.idleMoney = nil
    -- (where the last tick got to, for the live status: a step that never returns shows here)
    AutoPlaceModule.tickAt, AutoPlaceModule.tickStep = os.clock(), "start"
    if State.replaying then AutoPlaceModule.status = "Paused while the macro plays" return 1 end
    if not isGameRunning() or isResultsShowing() then AutoPlaceModule.status = "Waiting for a game" return 1 end
    local grew = samplePath()
    if grew and #pathPoints() % 20 == 0 then saveConfig() end
    if not next(AutoPlaceModule.team) then AutoPlaceModule.RefreshTeam() end
    -- event hotbar: new random units arrive during the game (read again every 5 s)
    if AutoPlaceModule.hotbarAt and os.clock() - AutoPlaceModule.hotbarAt > 5 then AutoPlaceModule.RefreshTeam() end
    -- part of the team came only from units on the map (no traits/rolls): read again now and then
    -- (once per game: getgc walks every table in memory, and the team often never shows up)
    if os.clock() - (AutoPlaceModule.teamReadAt or 0) > 15 and not AutoPlaceModule.extraTeamRead then
        for _, t in pairs(AutoPlaceModule.team) do
            if not t.fields then AutoPlaceModule.extraTeamRead = true AutoPlaceModule.RefreshTeam() break end
        end
    end
    -- (Fool's Hunt: a bar with no unit copy on it is normal - nothing to place, the money goes
    -- into upgrades; stopping here held 40k unused with 13 units down until the loss)
    if not next(AutoPlaceModule.team) and not State.eventMode then
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
    pcall(AutoPlaceModule.WatchHits)
    pcall(ControlUp.FusionStep)
    local hudMoney, hudPrices = AutoPlaceModule.ReadHud()
    -- money: the learned value, else AA's in-game yen (_stats.resource), else the screen
    local money = (AutoPlace.moneyPath and readCostValue(AutoPlace.moneyPath))
        or readCostValue("LP._stats.resource") or hudMoney
    AutoPlaceModule.tickStep = "spells"
    pcall(Lobby.SpellStep, money)
    pcall(Lobby.RerollStep)
    -- a spell in hand beats any upgrade (Random Buff: +100% for 1000): the money waits for it
    -- (real game: the yen went into upgrades as it came, three buffs sat unused all game)
    local okSave, saving = pcall(Lobby.SpellSaving, money)
    if okSave and saving and not AutoPlaceModule.danger then
        AutoPlaceModule.status = saving
        return 0.5
    end
    AutoPlaceModule.tickStep = "choose"
    if AutoPlace.sellFarmsLast and AutoPlaceModule.LastWave() and AutoPlaceModule.SellFarm() then return 0.3 end
    local danger = AutoPlaceModule.Danger()
    if danger and not AutoPlaceModule.danger then AutoPlaceModule.Note("base took damage: damage units first for 20 s") end
    AutoPlaceModule.danger = danger
    -- flying enemies: only hill / hybrid units hit them, so those come first (bestDps, upgradeStep)
    local flyingNow = AutoPlaceModule.Flying()
    local flying = flyingNow > 0 and "flying enemies on the map" or nil
    if flying and not AutoPlaceModule.flying then
        local any = false
        for _, tm in pairs(AutoPlaceModule.team) do
            if AutoPlaceModule.AirCapable(tm.name, math.huge) then any = true end
        end
        if any then
            AutoPlaceModule.Note("flying enemies on the map: hill / hybrid units first")
        elseif not AutoPlaceModule.flyWarned then
            AutoPlaceModule.flyWarned = true
            AutoPlaceModule.Note("flying enemies: no hill or hybrid unit in the team")
        end
    end
    AutoPlaceModule.flying = flying
    AutoPlaceModule.airNeed = AutoPlaceModule.AirNeed()
    if flying and AutoPlaceModule.flyWarned then AutoPlaceModule.problem = "flying enemies: no hill or hybrid unit in the team" end
    if not danger then
        -- strong enemies on the map: put the money into damage now, before they reach the base
        -- (flyers alone are not a threat: they only steer which damage unit comes next, AirNeed)
        local threat = AutoPlaceModule.Threat()
        if threat and threat ~= AutoPlaceModule.threat then AutoPlaceModule.Note(threat .. ": damage units first") end
        AutoPlaceModule.threat = threat
        danger = threat ~= nil
    end
    local slot, t, role, dpsPlaced, strongestDown = chooseNext(hudPrices, danger)
    -- Place units myself (Home): the player places, the script only upgrades / sells
    if AutoPlace.manual then t = nil end
    -- Fool's Hunt: its own brain decides (EventChoose); the normal-stage rules below are skipped
    local ev = State.eventMode and not AutoPlace.manual and Lobby.cfg.eventBrain ~= false
    if ev then
        local wait, et, er = AutoPlaceModule.EventChoose(money)
        if wait then return wait end
        t, role, slot = et, er, et.slot
    end
    if not ev then
    -- Fool's Hunt: 20 units at most on the map (seen in the real game); then the money goes into
    -- upgrades instead of refused placements
    if t and AutoPlaceModule.hotbarAt and #ownedUnits() >= math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) then t = nil end
    -- air quota not met but no air unit can go down now (no hill spot, at its limit): say so
    -- once and go on in the normal order, never stall
    if AutoPlaceModule.airNeed and t and role == "dps" and not AutoPlaceModule.AirCapable(t.name, 0) and not AutoPlaceModule.airFallbackNoted then
        AutoPlaceModule.airFallbackNoted = true
        AutoPlaceModule.Note("flying enemies: no air unit can be placed now (no spot / limit) - normal order")
    end
    -- most enemies fly (or they get through) and every air copy is down: their upgrades come
    -- before more ground copies; when none can be upgraded the normal order goes on
    local flyShare = AutoPlaceModule.seenFly / math.max(1, AutoPlaceModule.seenN)
    if AutoPlaceModule.airNeed and (flyShare >= 0.5 or danger) and AutoPlace.upgrade and t and role == "dps"
        and not AutoPlaceModule.AirCapable(t.name, 0) then
        -- (only an upgrade it can pay now: waiting 3500 for a flyer upgrade left a 1500 copy unplaced
        -- with 3k in hand and 4 units down - real game 2026-10-24)
        local wait = upgradeStep(money, "dps", true, State.eventMode)
        if wait then return wait end
    end
    if danger and not t then
        -- enemies are getting through and no damage unit is left to place: upgrade damage
        local wait = upgradeStep(money, "dps")
        if wait then return wait end
        slot, t, role, dpsPlaced, strongestDown = chooseNext(hudPrices, false)
        if AutoPlace.manual then t = nil end
        -- (the same map limit as the first pick: this second one went past it, 22 refusals)
        if t and AutoPlaceModule.hotbarAt and #ownedUnits() >= math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) then t = nil end
    end
    -- (lost twice here: no farm upgrades until every damage unit is down)
    if not danger and AutoPlace.upgrade and (dpsPlaced or 0) > 0 and strongestDown
        and (AutoPlaceModule.Losses() < 2 or (t == nil or role ~= "dps"))
        and (not t or (role ~= "farm" and role ~= "support")) then
        -- once the strongest damage unit and every farm are down, farm upgrades pay for
        -- themselves quickly (speedwagon 200 -> 500 per wave), so they come before spreading
        -- more units; before that the money goes into the strongest unit first
        local wait = upgradeStep(money, "farm")
        if wait then return wait end
    end
    -- nothing left to place and upgrades off while the yen piles up: say so (short status)
    AutoPlaceModule.idleMoney = (not t and not AutoPlace.upgrade and money and money >= 2000) and money or nil
    if not t then
        -- units waiting for a free spot are not "placed": say so instead
        local resting = 0
        for _, untilT in pairs(AutoPlaceModule.noSpot) do
            if untilT > os.clock() then resting = resting + 1 end
        end
        if AutoPlace.upgrade then
            local wait = upgradeStep(money)
            if wait then return wait end
        end
        if resting > 0 then
            AutoPlaceModule.status = string.format("No free spot for %d unit(s) - trying again soon", resting)
        else
            AutoPlaceModule.status = AutoPlace.manual and "You place the units" or AutoPlace.upgrade and "All units placed and fully upgraded" or "Everything placed"
        end
        return 1
    end
    end
    local cost = t.cost or hudPrices[slot]
    if not ev then
    if AutoPlaceModule.EventWeak(t, role) then
        AutoPlaceModule.DropCopy(t, "far below the team")
        return 0.5
    end
    if AutoPlaceModule.EventCapped(t) then
        AutoPlaceModule.DropCopy(t, "its unit is at the limit")
        return 0.5
    end
    -- (owner: 3 speedwagons + 1 bulma, any more only take a place on the map)
    if State.eventMode and t.temp and role == "farm" then
        local same = 0
        for _, u in ipairs(ownedUnits()) do if unitType(u) == t.name then same = same + 1 end end
        if same >= (AutoPlaceModule.FARM_COUNT[t.name] or tonumber((AutoPlaceModule.UnitDef(t.name) or {}).spawn_cap) or 1) then
            AutoPlaceModule.DropCopy(t, "farm not needed now")
            return 0.5
        end
    end
    -- (a copy left on the bar 25 s with the money for it is stuck: owner's screenshot, three
    -- copies sat there; cleared so the slot rolls again)
    if State.eventMode and t.temp then
        AutoPlaceModule.copySeen = AutoPlaceModule.copySeen or {}
        local first = AutoPlaceModule.copySeen[t.uuid] or os.clock()
        AutoPlaceModule.copySeen[t.uuid] = first
        if os.clock() - first > 25 and cost and money and money >= cost then
            AutoPlaceModule.DropCopy(t, "stuck on the bar")
            return 0.5
        end
    end
    -- Fool's Hunt: copies come one at a time, so money past this copy's price would sit unused
    -- (16k idle with 13 units in a real game): it goes into upgrades, the copy's price kept
    -- (in danger too, damage units only: 35k sat unused while enemies were getting through)
    if State.eventMode and AutoPlace.upgrade and cost and money and money > cost then
        local wait = upgradeStep(money - cost, danger and "dps" or nil, nil, true)
        if wait then return wait end
    end
    if not danger and AutoPlace.upgrade and role == "dps" and (dpsPlaced or 0) > 0 then
        -- stay ahead instead of waiting for the base to get hit: when upgrading the strongest
        -- unit (trait / rolls included) adds more damage per ¥ than another copy, upgrade it
        if AutoPlaceModule.BestUpgradeScore() > AutoPlaceModule.Value(t, cost) then
            local wait = upgradeStep(money, "dps")
            if wait then return wait end
        end
    end
    if cost and money and money < cost then
        AutoPlaceModule.status = string.format("Slot %d %s: waiting for money %d / %d", slot, t.name, math.floor(money), math.floor(cost))
        return 0.1
    end
    end
    local unknown = not (cost and money)
    local range = AutoPlaceModule.Range(t)
    local kind = AutoPlaceModule.PlacementKind(t)
    local aoe = AutoPlaceModule.IsAoe(t.name)
    local back = AutoPlaceModule.IsTrap(t.name) and AutoPlaceModule.AirCapable(t.name, 0)
    local spot = bestSpot(unknown and (unknownTries % 3) or 0, role, range, kind, aoe, back) or bestSpot(0, role, range, kind, aoe, back)
    if not spot then
        -- no spot of this kind (e.g. a hill unit on a map without free hills): let the
        -- other units go first and try this one again later
        AutoPlaceModule.noSpot[t.uuid] = os.clock() + 20
        AutoPlaceModule.problem = string.format("no free %s spot for %s - trying the other units first", kind, t.name)
        AutoPlaceModule.noSpotNoted = AutoPlaceModule.noSpotNoted or {}
        if not AutoPlaceModule.noSpotNoted[stageKey() .. t.uuid] then
            AutoPlaceModule.noSpotNoted[stageKey() .. t.uuid] = true
            AutoPlaceModule.Note(string.format("no %s spot within %s's reach of the road - not placed", kind, t.name))
        end
        return 0.1
    end
    -- (a call the game never answers must not stop placing for good: given up after 6 s)
    if AutoPlaceModule.inFlight and os.clock() - (AutoPlaceModule.inFlightAt or 0) > 6 then AutoPlaceModule.inFlight = nil end
    if AutoPlaceModule.inFlight then
        -- (the game has not answered the last placement yet: a second one could double it)
        AutoPlaceModule.status = "Waiting for the game to answer the last placement"
        return 0.2
    end
    AutoPlaceModule.status = string.format("Slot %d %s (%s): placing", slot, t.name, role)
    AutoPlaceModule.tickStep = "place"
    if tryPlace(t, spot) then
        -- (event: the copy is used up - the placed unit may carry another uuid, so it is not
        -- counted from the map; the bar is read again on the next tick)
        if t.temp then
            AutoPlaceModule.full[t.uuid], AutoPlaceModule.badTemp[t.uuid] = true, true
            AutoPlaceModule.capFails = 0
            if t.slot then AutoPlaceModule.usedSlot[t.slot] = { id = t.name, at = os.clock() } end
            AutoPlaceModule.hotbarAt, AutoPlaceModule.hotbarSig = 0, nil
        end
        AutoPlaceModule.failsBy[t.uuid], recentBad = 0, {}
        t.spotRefused = 0
        AutoPlaceModule.problem = nil
        if kind == "hill" and spot.hillBy == "height" and AutoPlace.hillBy[stageKey()] ~= "height" then
            AutoPlace.hillBy[stageKey()] = "height"
            saveConfig()
        end
        local why = (danger and "danger, best damage per ¥") or (role == "farm" and "farm pays for the rest")
            or (role == "buff" and string.format("buff rotation needs %d", AutoPlaceModule.BuffNeed(t)))
            or (role == "support" and "support before upgrades") or "damage"
        AutoPlaceModule.Note(string.format("placed %s #%d on %s (%s)", t.name, #placedOf(t.uuid), spot.kind or "ground", why))
        return 0.2
    end
    local why = refusalReason()
    if why == "money" then return 0.5 end
    -- below the game's own limit a "limit" message cannot be about this unit
    if why == "cap" and t.gameCap and #placedOf(t.uuid) < t.gameCap then why = "spot" end
    if why == "spot" or (why == nil and cost and money and money >= cost) then AutoPlaceModule.SpotRefused(t, spot, kind) end
    if why == "spot" then
        badSpots[spotKey(spot, kind)] = true
        return 0.1
    end
    -- (Fool's Hunt: "max placement" for a copy under its own unit limit = the map's unit limit;
    -- not learning that sent every new copy in to be refused)
    if why == "cap" and t.temp and State.eventMode and not AutoPlaceModule.EventCapped(t) and #ownedUnits() > 0 then
        AutoPlaceModule.capSeen = #ownedUnits()
    end
    if why == "cap" then
        -- the game's "max placement" message: full for this game only (a misread message
        -- must not stick; the game data's spawn_cap is the saved limit)
        AutoPlaceModule.full[t.uuid] = true
        AutoPlaceModule.gameCaps[t.name] = math.max(1, #placedOf(t.uuid))
        return 0.1
    end
    if cost and money and money >= cost then
        -- enough money but refused: the spot is not allowed; several in a row = unit limit
        local key = spotKey(spot, kind)
        badSpots[key] = true
        recentBad[#recentBad + 1] = key
        -- (counted per unit: another unit's refusals say nothing about this one)
        AutoPlaceModule.failsBy[t.uuid] = (AutoPlaceModule.failsBy[t.uuid] or 0) + 1
        t.refused = (t.refused or 0) + 1
        -- an event copy not announced by the game this run (a replay leaves the last game's in
        -- memory) and refused twice: try the next copy of that unit
        -- (event: refused three times in a row with this many units down = the map is full)
        if t.temp then
            AutoPlaceModule.capFails = (AutoPlaceModule.capFails or 0) + 1
            -- (only from 10 units on: one copy refused three times with 1 unit down read as
            -- "map full" and nothing more was placed all game)
            if AutoPlaceModule.capFails >= 3 and #ownedUnits() >= 10 then AutoPlaceModule.capSeen = #ownedUnits() end
        end
        -- (below the map's unit limit only: at the limit every copy is refused)
        if t.temp and t.refused >= 3 and AutoPlaceModule.liveTemp[t.uuid] and State.eventMode
            and #ownedUnits() < math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) - 1 then
            for _, k in ipairs(recentBad) do badSpots[k] = nil end
            recentBad = {}
            AutoPlaceModule.DropCopy(t, "refused 3 times with the money in hand")
            return 0.2
        end
        if t.temp and t.refused >= 2 and not AutoPlaceModule.liveTemp[t.uuid] then
            AutoPlaceModule.badTemp[t.uuid], AutoPlaceModule.hotbarSig = true, nil
            AutoPlaceModule.RefreshTeam()
            return 0.2
        end
        if t.refused >= 8 and #placedOf(t.uuid) == 0 then
            -- refused on 8 spots and never placed: not in the equipped team any more
            AutoPlaceModule.full[t.uuid] = true
            AutoPlaceModule.Note(string.format("%s refused 8 times - left out (not equipped?)", t.name))
            for _, k in ipairs(recentBad) do badSpots[k] = nil end
            recentBad, AutoPlaceModule.failsBy[t.uuid] = {}, 0
            return 0.1
        end
        if AutoPlaceModule.failsBy[t.uuid] >= 4 and not t.gameCap and #placedOf(t.uuid) >= 1 then
            -- refused on 4 different spots with money in hand: this unit is at its limit for
            -- this game (never saved, never 0), and those spots were fine for other units
            AutoPlaceModule.full[t.uuid] = true
            AutoPlaceModule.gameCaps[t.name] = #placedOf(t.uuid)
            for _, k in ipairs(recentBad) do badSpots[k] = nil end
            recentBad, AutoPlaceModule.failsBy[t.uuid] = {}, 0
        end
        return 0.2
    end
    -- price or money not known yet: a refusal may just mean "not enough money", so keep
    -- every spot and rotate between the top three until one placement succeeds
    unknownTries = unknownTries + 1
    return 1
end

-- The best moment to stop time: enemies about to reach the base, a boss (3x the usual HP)
-- inside our damage units' range, or most enemies bunched inside that range.
-- A number from a unit's _stats folder (nil when missing).
function AutoPlaceModule.StatNum(u, name)
    local st = u:FindFirstChild("_stats")
    local v = st and st:FindFirstChild(name)
    return v and tonumber(v.Value) or nil
end

function AutoPlaceModule.FreezeMoment()
    local folder = unitsFolder()
    local enemies, hps = {}, {}
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(u) then
            local p = rootPos(u)
            if p then
                -- max HP (base_health): current health makes hurt enemies look small and a fresh one a "boss"
                local hp = AutoPlaceModule.StatNum(u, "base_health") or AutoPlaceModule.StatNum(u, "health") or 0
                table.insert(enemies, { p = p, hp = hp })
                table.insert(hps, hp)
            end
        end
    end
    if #enemies == 0 then return nil end
    if AutoPlaceModule.danger then return "base is taking damage" end
    if AutoPlaceModule.EnemyProgress() >= 0.75 then return "enemies close to the base" end
    local zone = {}
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            local p = rootPos(u)
            local def = AutoPlaceModule.UnitDef(unitType(u))
            local r = (AutoPlaceModule.StatNum(u, "range") or (def and tonumber(def.range)) or DEFAULT_RANGE) * (AutoPlaceModule.StatNum(u, "range_multiplier") or 1)
            if p then table.insert(zone, { p = p, r = r }) end
        end
    end
    table.sort(hps)
    local median = hps[math.ceil(#hps / 2)] or 0
    local inZone, boss = 0, false
    for _, e in ipairs(enemies) do
        for _, z in ipairs(zone) do
            local dx, dz = e.p.X - z.p.X, e.p.Z - z.p.Z
            if dx * dx + dz * dz <= z.r * z.r then
                inZone = inZone + 1
                if #enemies >= 3 and median > 0 and e.hp >= 3 * median then boss = true end
                break
            end
        end
    end
    if boss then return "boss inside the damage zone" end
    if inZone >= math.max(5, math.ceil(#enemies * 0.6)) then return string.format("%d enemies inside the damage zone", inZone) end
    return nil
end

local function freezeLoop(gen)
    local last, lastAny = {}, -1e9
    while AutoPlace.enabled and gen == apGen and not State.unloaded do
        if AutoPlace.smartFreeze and isGameRunning() and not isResultsShowing() then
            pcall(function()
                local why
                for _, u in ipairs(ownedUnits()) do
                    if BuffRot.isControlSkill(u) and os.clock() - lastAny >= 4 then
                        local cd = AutoPlaceModule.StatNum(u, "active_attack_cooldown") or 30
                        if os.clock() - (last[u] or -1e9) >= cd + 0.5 then
                            if why == nil then why = AutoPlaceModule.FreezeMoment() or false end
                            if why and fireActiveAttack(u) then
                                last[u], lastAny = os.clock(), os.clock()
                                AutoPlaceModule.Note(string.format("%s stopped time: %s", unitType(u), why))
                                break
                            end
                        end
                    end
                end
            end)
        end
        task.wait(0.3)
    end
end

-- Sets a unit's targeting (_stats.priority) through change_priority and checks it took.
-- The remote's arguments are not known: (unit, "strongest"), then (unit, "Strongest"), then
-- (unit) alone up to 7 times as a cycle through First / Closest / ... / Last. The way that
-- worked is remembered (AutoPlace.priorityMethod) and tried first next time.
function AutoPlaceModule.SetPriority(unit, want)
    local remote = getAARemote("change_priority")
    local st = unit:FindFirstChild("_stats")
    local v = st and st:FindFirstChild("priority")
    if not remote or not v then return false end
    local function is() return string.lower(tostring(v.Value)) == want end
    if is() then return true end
    local function call(mode)
        local before = tostring(v.Value)
        pcall(function()
            if mode then remote:InvokeServer(unit, mode) else remote:InvokeServer(unit) end
        end)
        for _ = 1, 5 do -- the new value can replicate a moment after the reply
            if tostring(v.Value) ~= before then break end
            task.wait(0.1)
        end
        return is()
    end
    local ways = {
        direct = function() return call(want) end,
        capital = function() return call(want:sub(1, 1):upper() .. want:sub(2)) end,
        cycle = function()
            for _ = 1, 7 do
                if call(nil) then return true end
            end
            return false
        end,
    }
    local order = { "direct", "capital", "cycle" }
    local known = AutoPlace.priorityMethod
    if ways[known] then
        for i, m in ipairs(order) do if m == known then table.remove(order, i) break end end
        table.insert(order, 1, known)
    end
    for _, m in ipairs(order) do
        if ways[m]() then
            if AutoPlace.priorityMethod ~= m then AutoPlace.priorityMethod = m; saveConfig() end
            return true
        end
    end
    return false
end

-- One targeting fix per call: damage units on "first"; while a boss is out, single-target
-- ones on "strongest" (area units keep "first", they hit the boss anyway). At most one try
-- per unit every 3 s; a unit where every way failed twice is left alone.
AutoPlaceModule.prioTries = setmetatable({}, { __mode = "k" })
function AutoPlaceModule.TargetStep()
    local boss = AutoPlaceModule.Threat() == "boss on the map"
    local now = os.clock()
    for _, u in ipairs(ownedUnits()) do
        local st = u:FindFirstChild("_stats")
        local v = st and st:FindFirstChild("priority")
        if v and not isSummon(u) and unitRole(u) == "dps" then
            local name = unitType(u)
            local want = (boss and AutoPlaceModule.IsAoe(name) == false) and "strongest" or "first"
            local tr = AutoPlaceModule.prioTries[u] or { at = -1e9, fails = 0 }
            AutoPlaceModule.prioTries[u] = tr
            if string.lower(tostring(v.Value)) ~= want and tr.fails < 2 and now - tr.at >= 3 then
                tr.at = now
                if AutoPlaceModule.SetPriority(u, want) then
                    AutoPlaceModule.Note(string.format("target: %s -> %s (%s)", name, want, boss and "boss on the map" or "normal"))
                else
                    tr.fails = tr.fails + 1
                    if tr.fails >= 2 then AutoPlaceModule.Note(string.format("could not change the target of %s - left as it is", name)) end
                end
                return
            end
        end
    end
end

function AutoPlaceModule.TargetLoop(gen)
    while AutoPlace.enabled and gen == apGen and not State.unloaded do
        if AutoPlace.autoTarget and isGameRunning() and not isResultsShowing() then
            pcall(AutoPlaceModule.TargetStep)
        end
        task.wait(0.5)
    end
end

function AutoPlaceModule.Start()
    apGen = apGen + 1
    local gen = apGen
    task.spawn(freezeLoop, gen)
    task.spawn(AutoPlaceModule.TargetLoop, gen)
    AutoPlaceModule.flyWarned, AutoPlaceModule.flying = nil, nil
    AutoPlaceModule.full, badSpots, unknownTries, recentBad = {}, {}, 0, {}
    AutoPlaceModule.gameCaps, AutoPlaceModule.failsBy = {}, {}
    AutoPlaceModule.noSpot = {}
    task.spawn(function()
        local lastGame
        while AutoPlace.enabled and gen == apGen and not State.unloaded do
            local data = workspace:FindFirstChild("_DATA")
            local started = data and data:FindFirstChild("GameStarted")
            local gameNow = started and started.Value
            if gameNow and not lastGame then
                AutoPlaceModule.MapFingerprint(true)
                AutoPlaceModule.full, badSpots, unknownTries, recentBad = {}, {}, 0, {}
    AutoPlaceModule.gameCaps, AutoPlaceModule.failsBy = {}, {}
                AutoPlaceModule.flyWarned, AutoPlaceModule.flying = nil, nil
                AutoPlaceModule.seenN, AutoPlaceModule.seenFly, AutoPlaceModule.airFallbackNoted = 0, 0, nil
                AutoPlaceModule.seen = setmetatable({}, { __mode = "k" })
                AutoPlaceModule.noSpot = {}
                AutoPlaceModule.extraTeamRead = nil
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

-- Short status: what it is doing, the two strongest units and the last two actions.
local function shortStatus()
    local lines = { AutoPlaceModule.StageLine and AutoPlaceModule.StageLine() or tostring(State.stage), "Status: " .. AutoPlaceModule.status }
    if AutoPlaceModule.idleMoney then
        table.insert(lines, string.format("Idle money: %d ¥ – turn on Auto upgrade", math.floor(AutoPlaceModule.idleMoney)))
    end
    if AutoPlaceModule.danger then table.insert(lines, "DANGER: damage units first") end
    if AutoPlaceModule.problem then table.insert(lines, "Problem: " .. AutoPlaceModule.problem) end
    local rank = {}
    for _, t in pairs(AutoPlaceModule.team) do
        if AutoPlaceModule.RoleOf(t) == "dps" then
            local st = AutoPlaceModule.Stats(t)
            local aoe = AutoPlaceModule.IsAoe(t.name)
            table.insert(rank, { name = t.name, dps = st.damage / math.max(0.1, st.cooldown) * (aoe and AOE_VALUE or 1) })
        end
    end
    table.sort(rank, function(a, b) return a.dps > b.dps end)
    if #rank > 0 then
        table.insert(lines, "Strongest: " .. rank[1].name .. (rank[2] and (", then " .. rank[2].name) or ""))
    end
    local log = AutoPlaceModule.log
    for i = #log, math.max(1, #log - 1), -1 do
        table.insert(lines, string.format("%ds ago - %s", math.floor(os.clock() - log[i].at), log[i].text))
    end
    return table.concat(lines, "\n")
end

function AutoPlaceModule.StatusText()
    if not AutoPlace.showDetails then return shortStatus() end
    local lines = { "Status: " .. AutoPlaceModule.status }
    if AutoPlaceModule.danger then table.insert(lines, "DANGER: enemies getting through - damage units first") end
    local team = {}
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local cap = tonumber(AutoPlace.caps[t.name]) or AutoPlaceModule.gameCaps[t.name]
            local role = AutoPlaceModule.RoleOf(t)
            local target = math.min(AutoPlaceModule.SlotTarget(s, t), cap or 99)
            if role == "buff" then target = math.min(target, AutoPlaceModule.BuffNeed(t)) end
            local full = (cap and target == cap) and " (limit)" or ""
            local traitText = #(t.traits or {}) > 0 and (" {" .. table.concat(t.traits, ",") .. "}") or ""
            table.insert(team, string.format("%d %s%s %d/%d%s%s", s, t.name, role and ("[" .. role .. "]") or "",
                #placedOf(t.uuid), target, full, traitText))
        end
    end
    table.insert(lines, "Team: " .. (#team > 0 and table.concat(team, ", ") or "not read yet"))
    local rank = {}
    for _, t in pairs(AutoPlaceModule.team) do
        if AutoPlaceModule.RoleOf(t) == "dps" then
            local st = AutoPlaceModule.Stats(t)
            local aoe = AutoPlaceModule.IsAoe(t.name)
            table.insert(rank, { name = t.name, dps = st.damage / math.max(0.1, st.cooldown) * (aoe and AOE_VALUE or 1) })
        end
    end
    table.sort(rank, function(a, b) return a.dps > b.dps end)
    if #rank > 0 then
        local parts = {}
        for i, r in ipairs(rank) do table.insert(parts, string.format("%d. %s %.0f/s", i, r.name, r.dps)) end
        table.insert(lines, "Strongest (traits + rolls): " .. table.concat(parts, ", "))
    end
    table.insert(lines, string.format("Path: %d points for %s", #pathPoints(), stageKey()))
    table.insert(lines, "Map fingerprint: " .. (AutoPlaceModule.MapFingerprint() or "none (no _BASES)") .. " from " .. (AutoPlaceModule.fpFrom ~= "" and AutoPlaceModule.fpFrom or "-"))
    if AutoPlaceModule.Losses() > 0 then
        table.insert(lines, string.format("Lost here %d time(s) lately: playing safer (%s placement)", AutoPlaceModule.Losses(), AutoPlaceModule.Mode()))
    end
    if AutoPlaceModule.problem then table.insert(lines, "Problem: " .. AutoPlaceModule.problem) end
    if #AutoPlaceModule.log > 0 then
        table.insert(lines, "Last actions:")
        for i = #AutoPlaceModule.log, 1, -1 do
            local e = AutoPlaceModule.log[i]
            table.insert(lines, string.format("  %ds ago - %s", math.floor(os.clock() - e.at), e.text))
        end
    end
    return table.concat(lines, "\n")
end

function AutoPlaceModule.MapReport()
    local lines = { "[moseeri hub · Map report] " .. os.date("%H:%M:%S") .. " stage " .. stageKey() }
    table.insert(lines, "map fingerprint: " .. (AutoPlaceModule.MapFingerprint(true) or "none (no _BASES)") .. " from " .. (AutoPlaceModule.fpFrom ~= "" and AutoPlaceModule.fpFrom or "-"))
    -- (a friend's report could not say why nothing was placed: the Auto Place status goes in now)
    table.insert(lines, string.format("auto place: %s | problem: %s | event mode: %s | last step: %s %ss ago", tostring(AutoPlaceModule.status),
        tostring(AutoPlaceModule.problem), tostring(State.eventMode), tostring(AutoPlaceModule.tickStep),
        tostring(AutoPlaceModule.tickAt and math.floor(os.clock() - AutoPlaceModule.tickAt))))
    for i = math.max(1, #AutoPlaceModule.log - 6), #AutoPlaceModule.log do
        local e = AutoPlaceModule.log[i]
        table.insert(lines, "  note: " .. tostring(type(e) == "table" and (e.text or e.msg) or e))
    end
    table.insert(lines, "getgc: " .. tostring(type(getgc) == "function") .. ", Raycast: " .. tostring(pcall(function() return RaycastParams.new() end)))
    AutoPlaceModule.RefreshTeam()
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local rolls = {}
            for k, v in pairs(t.rolls or {}) do table.insert(rolls, string.format("%s=%.3f", k, v)) end
            table.sort(rolls)
            local st = AutoPlaceModule.Stats(t)
            table.insert(lines, string.format("slot %d: %s uuid %s cost %s role %s | rolls %s | dmg %.0f every %.2fs range %.1f",
                s, t.name, clip(t.uuid, 14), tostring(t.cost), tostring(AutoPlaceModule.RoleOf(t)),
                #rolls > 0 and table.concat(rolls, " ") or "none", st.damage, st.cooldown, st.range))
            table.insert(lines, "  team data fields: " .. clip(t.fields or "-", 300))
            table.insert(lines, string.format("  traits: %s%s | stands on: %s | raw: %s",
                #(t.traits or {}) > 0 and table.concat(t.traits, ", ") or "none", t.fromMemory and " (remembered)" or "",
                AutoPlaceModule.PlacementKind(t), clip(t.traitRaw ~= "" and t.traitRaw or "-", 200)))
        end
    end
    -- team data not found in memory: list tables that hold one of our uuids, to learn the new shape
    local missing = {}
    for _, t in pairs(AutoPlaceModule.team) do
        if not t.fields then missing[(tostring(t.uuid):gsub("[{}%s]", ""))] = t.name end
    end
    if next(missing) and type(getgc) == "function" then
        local found = 0
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if found >= 6 then break end
                if type(v) == "table" then
                    for k, val in pairs(v) do
                        local name = type(val) == "string" and missing[(val:gsub("[{}%s]", ""))]
                        if name then
                            found = found + 1
                            local parts = {}
                            for k2, v2 in pairs(v) do
                                local shown = type(v2) == "table" and "{table}" or clip(tostring(v2), 24)
                                table.insert(parts, tostring(k2) .. "=" .. shown)
                            end
                            table.sort(parts)
                            table.insert(lines, string.format("  %s's data in memory (via %s): %s", name, tostring(k), clip(table.concat(parts, " "), 400)))
                            break
                        end
                    end
                end
            end
        end)
        if found == 0 then table.insert(lines, "  team data: no table in memory holds our unit uuids") end
    end
    if AutoPlaceModule.teamError then table.insert(lines, "  team read error: " .. AutoPlaceModule.teamError) end
    -- portals in the bag with everything they carry (tier, challenge, buffs ...), to learn
    -- which ones make units or upgrades cheaper
    pcall(function()
        local function show(v, depth)
            if type(v) ~= "table" then return clip(tostring(v), 30) end
            if depth > 1 then return "{table}" end
            local parts = {}
            for k, x in pairs(v) do table.insert(parts, tostring(k) .. "=" .. show(x, depth + 1)) end
            table.sort(parts)
            return "{" .. table.concat(parts, ",") .. "}"
        end
        local bag
        for _, v in ipairs(type(getgc) == "function" and getgc(true) or {}) do
            if type(v) == "table" and type(rawget(v, "unique_items")) == "table" then bag = v break end
        end
        local shown = 0
        for key, item in pairs(bag and bag.unique_items or {}) do
            local id = type(item) == "table" and (item.item_id or item.id or item.name) or key
            if string.lower(tostring(id)):find("portal", 1, true) and shown < 8 then
                shown = shown + 1
                table.insert(lines, string.format("portal %s: %s", tostring(id), clip(show(item, 0), 600)))
            end
        end
        table.insert(lines, bag and string.format("portals in bag: %d shown", shown) or "portals in bag: bag data not found")
    end)
    local hotbarTexts = {}
    pcall(function()
        local h = workspace.CurrentCamera.ViewportSize.Y
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        for _, d in ipairs(gui and gui:GetDescendants() or {}) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and isOnScreen(d) and not isOwnGui(d)
                and d.AbsolutePosition.Y > h * 0.75 and #d.Text > 0 and #hotbarTexts < 30 then
                table.insert(hotbarTexts, string.format("%s=%q", d.Name, clip(d.Text, 24)))
            end
        end
    end)
    table.insert(lines, "bottom of screen texts: " .. (#hotbarTexts > 0 and table.concat(hotbarTexts, " ") or "none"))
    table.insert(lines, "money value: " .. tostring(AutoPlace.moneyPath) .. " = " .. tostring(AutoPlace.moneyPath and readCostValue(AutoPlace.moneyPath)))
    local top = {}
    for _, c in ipairs(workspace:GetChildren()) do table.insert(top, c.Name) end
    table.insert(lines, "workspace: " .. clip(table.concat(top, ", "), 400))
    pcall(function()
        -- hill spots and what the ray hits there, so we learn what real hills are called
        local hills, sorted = {}, {}
        for _, c in ipairs(candidates or (#pathPoints() >= 8 and buildCandidates(pathPoints())) or {}) do
            if c.kind == "hill" then table.insert(sorted, c) end
        end
        -- up to 3 named hills (the ones hill units get first), then the best height-only ones
        local named = 0
        for _, c in ipairs(sorted) do if c.hillBy == "name" then named = named + 1 end end
        local keepNamed = math.max(3, 5 - (#sorted - named))
        table.sort(sorted, function(a, b)
            if (a.hillBy == "name") ~= (b.hillBy == "name") then return a.hillBy == "name" end
            return a.score > b.score
        end)
        for i, c in ipairs(sorted) do
            if #hills < 5 and (c.hillBy ~= "name" or i <= keepNamed) then
                table.insert(hills, string.format("(%d,%d) +%.1f %s %s", math.floor(c.x + 0.5), math.floor(c.z + 0.5), c.rise or 0,
                    c.hillBy or "?", c.part and clip(c.part:GetFullName(), 80) or "?"))
            end
        end
        table.insert(lines, string.format("hill spots (best 5, height above road, by name/height, part): %s | here: %s, height refusals %d",
            #hills > 0 and table.concat(hills, "; ") or "none", tostring(AutoPlace.hillBy[stageKey()] or "not learned"),
            AutoPlaceModule.heightRefusals[stageKey()] or 0))
        local under = {}
        for _, u in ipairs(ownedUnits()) do
            if AutoPlaceModule.PlacementKind({ name = unitType(u) }) == "hill" then
                local p, gy, tag, part = rootPos(u), nil, nil, nil
                if p then gy, tag, part = groundHit(p.X, p.Y, p.Z) end
                table.insert(under, string.format("%s on %s (y %.1f)", unitType(u), part and clip(part:GetFullName(), 80) or "nothing", gy or 0))
            end
        end
        if #under > 0 then table.insert(lines, "our hill units stand on: " .. table.concat(under, "; ")) end
    end)
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
    -- every enemy type on the map with its own values and attributes (flying, regen, shield
    -- ... whatever the game calls them), to teach Auto Place which units can hit what
    local seenKind = {}
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        local stats = u:FindFirstChild("_stats")
        local id = stats and stats:FindFirstChild("id")
        local kind = id and tostring(id.Value) or u.Name
        if isEnemy(u) and not seenKind[kind] then
            seenKind[kind] = true
            local parts = {}
            for _, c in ipairs(stats and stats:GetChildren() or {}) do
                if c:IsA("ValueBase") then table.insert(parts, c.Name .. "=" .. clip(tostring(c.Value), 20)) end
            end
            local ok, attrs = pcall(function() return u:GetAttributes() end)
            for k, v in pairs(ok and attrs or {}) do table.insert(parts, "@" .. tostring(k) .. "=" .. clip(tostring(v), 20)) end
            local p = rootPos(u)
            table.sort(parts)
            table.insert(lines, string.format("enemy %s y=%s: %s", kind, p and string.format("%.1f", p.Y) or "?", clip(table.concat(parts, " "), 700)))
        end
    end
    -- unit data keys that may decide air / hidden targets
    local airKeys = {}
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        local def = t and AutoPlaceModule.UnitDef(t.name)
        for k, v in pairs(def or {}) do
            local key = string.lower(tostring(k))
            if key:find("fly", 1, true) or key:find("air", 1, true) or key:find("hidden", 1, true) or key:find("target", 1, true) then
                table.insert(airKeys, t.name .. "." .. tostring(k) .. "=" .. clip(tostring(v), 20))
            end
        end
    end
    table.insert(lines, "unit air/target keys: " .. (#airKeys > 0 and table.concat(airKeys, " ") or "none"))
    -- attack shapes (circle / cone / line / full): the attack data modules, entries for our team
    pcall(function()
        local data = ReplicatedStorage.src.Data
        local names = {}
        for _, c in ipairs(data:GetChildren()) do table.insert(names, c.Name) end
        table.insert(lines, "src.Data has: " .. clip(table.concat(names, ", "), 400))
        local wantedAttacks = {}
        for s = 1, 6 do
            local t = AutoPlaceModule.team[s]
            local def = t and AutoPlaceModule.UnitDef(t.name)
            if def then
                for _, k in ipairs({ "primary_attack_no_upgrades", "primary_attack", "active_attack" }) do
                    if type(def[k]) == "string" then wantedAttacks[def[k]] = t.name end
                end
            end
        end
        local shown = 0
        for _, m in ipairs(data:GetDescendants()) do
            if m:IsA("ModuleScript") and string.lower(m.Name):find("attack", 1, true) and shown < 12 then
                local ok, mod = pcall(require, m)
                if ok and type(mod) == "table" then
                    for id, owner in pairs(wantedAttacks) do
                        local e = mod[id]
                        if type(e) == "table" and shown < 12 then
                            shown = shown + 1
                            local parts = {}
                            for k, v in pairs(e) do
                                local shownV = type(v) == "table" and "{table}" or clip(tostring(v), 24)
                                table.insert(parts, tostring(k) .. "=" .. shownV)
                            end
                            table.sort(parts)
                            table.insert(lines, string.format("attack %s (%s, %s): %s", id, owner, m.Name, clip(table.concat(parts, " "), 500)))
                        end
                    end
                end
            end
        end
        if shown == 0 then table.insert(lines, "attack data: not found in modules named *attack*") end
    end)
    -- data only, for later work on flying enemies and two-lane maps: unit tags per team
    -- unit, the lane folders and the lane / path / bend values of the first enemies
    pcall(function()
        local m = ReplicatedStorage.src.Data:FindFirstChild("UnitTags")
        local ok, mod = pcall(require, m)
        if not (m and ok and type(mod) == "table") then table.insert(lines, "unit tags: no src.Data.UnitTags") return end
        local hits = 0
        for s = 1, 6 do
            local t = AutoPlaceModule.team[s]
            local def = t and AutoPlaceModule.UnitDef(t.name)
            local e = t and (mod[def and def.id or t.name] or mod[t.name])
            if e ~= nil then
                hits = hits + 1
                local parts = {}
                for k, v in pairs(type(e) == "table" and e or { value = e }) do
                    table.insert(parts, tostring(k) .. "=" .. (type(v) == "table" and "{table}" or clip(tostring(v), 24)))
                end
                table.sort(parts)
                table.insert(lines, string.format("unit tags %s: %s", t.name, clip(table.concat(parts, " "), 400)))
            end
        end
        if hits == 0 then
            local keys = {}
            for k, v in pairs(mod) do
                if #keys >= 5 then break end
                table.insert(keys, tostring(k) .. "=" .. (type(v) == "table" and "{table}" or clip(tostring(v), 24)))
            end
            table.insert(lines, "unit tags: no entry by unit id, first keys: " .. table.concat(keys, " "))
        end
    end)
    pcall(function()
        local pb = bases and bases:FindFirstChild("player")
        local lanes = pb and pb:FindFirstChild("LANES")
        local names = {}
        for _, c in ipairs(lanes and lanes:GetChildren() or {}) do table.insert(names, c.Name) end
        local seen = {}
        for _, u in ipairs(folder and folder:GetChildren() or {}) do
            if #seen >= 3 then break end
            local stats = isEnemy(u) and u:FindFirstChild("_stats")
            if stats then
                local parts = {}
                for _, c in ipairs(stats:GetChildren()) do
                    local n = string.lower(c.Name)
                    if c:IsA("ValueBase") and (n:find("lane", 1, true) or n:find("path", 1, true) or n:find("bend", 1, true)) then
                        table.insert(parts, c.Name .. "=" .. clip(tostring(c.Value), 20))
                    end
                end
                table.insert(seen, u.Name .. "{" .. table.concat(parts, " ") .. "}")
            end
        end
        table.insert(lines, string.format("lanes: %s | enemy lane values: %s", lanes and (#names > 0 and table.concat(names, ", ") or "empty") or "no _BASES.player.LANES",
            #seen > 0 and table.concat(seen, " ") or "no enemies"))
    end)
    -- data only: the unit panel's targeting menu (First / Closest / Strongest ...)
    pcall(function()
        local ep = ReplicatedStorage:FindFirstChild("endpoints")
        local remotes, vals = {}, {}
        for _, d in ipairs(ep and ep:GetDescendants() or {}) do
            local n = string.lower(d.Name)
            if (d:IsA("RemoteEvent") or d:IsA("RemoteFunction")) and (n:find("target", 1, true) or n:find("priority", 1, true)
                or n:find("mode", 1, true) or n:find("focus", 1, true)) then
                table.insert(remotes, string.format("%s (%s)", d.Name, d.ClassName))
            end
        end
        for _, u in ipairs(ownedUnits()) do
            local stats = u:FindFirstChild("_stats")
            for _, c in ipairs(stats and stats:GetChildren() or {}) do
                local n = string.lower(c.Name)
                if c:IsA("ValueBase") and (n:find("target", 1, true) or n:find("priority", 1, true)) and #vals < 12 then
                    table.insert(vals, string.format("%s.%s=%s", u.Name, c.Name, clip(tostring(c.Value), 20)))
                end
            end
        end
        table.insert(lines, string.format("targeting remotes: %s | unit target values: %s",
            #remotes > 0 and table.concat(remotes, ", ") or "none", #vals > 0 and table.concat(vals, " ") or "none"))
    end)
    local hpNow, hpMax = AutoPlaceModule.BaseHp()
    table.insert(lines, string.format("base hp read from screen: %s / %s (danger mode needs this), leading enemy %.0f%% of the way",
        tostring(hpNow), tostring(hpMax), AutoPlaceModule.EnemyProgress() * 100))
    table.insert(lines, string.format("path points: %d", #pathPoints()))
    local spot = #pathPoints() >= 8 and bestSpot()
    if spot then table.insert(lines, string.format("best spot: (%.1f, %.1f, %.1f) %s, covers %d path points", spot.x, spot.groundY or spot.y, spot.z, tostring(spot.kind), spot.score)) end

    local hudMoney, hudPrices = AutoPlaceModule.ReadHud()
    local priceText = {}
    for s = 1, 6 do if hudPrices[s] then table.insert(priceText, s .. "=" .. hudPrices[s]) end end
    table.insert(lines, string.format("screen: money %s, hotbar prices %s", tostring(hudMoney), table.concat(priceText, " ")))

    -- Remotes and on-screen buttons for starting / skipping / voting (for Auto vote start / skip).
    local cts = ReplicatedStorage:FindFirstChild("endpoints")
    cts = cts and cts:FindFirstChild("client_to_server")
    local voteRemotes = {}
    for _, r in ipairs(cts and cts:GetChildren() or {}) do
        local n = string.lower(r.Name)
        for _, w in ipairs({ "vote", "start", "skip", "wave", "ready", "speed" }) do
            if n:find(w, 1, true) then table.insert(voteRemotes, r.Name .. "(" .. r.ClassName .. ")") break end
        end
    end
    table.insert(lines, "vote/start/skip remotes: " .. (#voteRemotes > 0 and table.concat(voteRemotes, ", ") or "none"))
    local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local shown = {}
    for _, d in ipairs(pg and pg:GetDescendants() or {}) do
        if #shown >= 40 then break end
        if d:IsA("GuiButton") and isOnScreen(d) and not isOwnGui(d) then
            local label = d:IsA("TextButton") and d.Text or ""
            if label == "" then
                for _, c in ipairs(d:GetDescendants()) do
                    if c:IsA("TextLabel") and #c.Text > 0 then label = c.Text break end
                end
            end
            table.insert(shown, d.Name .. (label ~= "" and ("=" .. clip(label, 18)) or ""))
        end
    end
    table.insert(lines, "buttons on screen: " .. table.concat(shown, ", "))

    -- data only, for a future Auto Join: every remote the game has (any sub-folder of
    -- endpoints), and in the lobby the teleporters / rooms and the stage-selection UI
    pcall(function()
        local ep = ReplicatedStorage:FindFirstChild("endpoints")
        local all = {}
        for _, d in ipairs(ep and ep:GetDescendants() or {}) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") then
                table.insert(all, string.format("%s.%s(%s)", d.Parent and d.Parent.Name or "?", d.Name, d.ClassName))
            end
        end
        -- remotes for later features first (join / portals / eggs / event spells and cards), then the rest
        local function wanted(r)
            local l = string.lower(r)
            for _, w in ipairs({ "place", "spawn", "spell", "card", "vote", "temporary", "fool", "april", "portal", "egg",
                "capsule", "open", "use_item", "lobby", "join", "lock", "teleport" }) do
                if l:find(w, 1, true) then return true end
            end
            return false
        end
        table.sort(all, function(a, b)
            local wa, wb = wanted(a), wanted(b)
            if wa ~= wb then return wa end
            return a < b
        end)
        table.insert(lines, clip(string.format("all remotes (%d, wanted ones first; full list: Save unit catalog -> remotes_and_hud.txt): %s", #all,
            #all > 0 and table.concat(all, ", ") or "none"), 6000))
    end)
    pcall(function()
        local cfg = workspace:FindFirstChild("_MAP_CONFIG")
        local lobby = cfg and cfg:FindFirstChild("IsLobby")
        if not (lobby and lobby.Value == true) then return end
        local words = { "teleport", "elevator", "room", "lobby", "portal", "story", "raid", "infinite", "challenge" }
        local rooms = 0
        for _, obj in ipairs(workspace:GetChildren()) do
            local n = string.lower(obj.Name)
            for _, w in ipairs(words) do
                if n:find(w, 1, true) and rooms < 12 then
                    rooms = rooms + 1
                    local kids, vals = {}, {}
                    for _, c in ipairs(obj:GetChildren()) do
                        if #kids < 15 then table.insert(kids, c.Name .. "(" .. c.ClassName .. ")") end
                    end
                    for _, d in ipairs(obj:GetDescendants()) do
                        if d:IsA("ValueBase") and #vals < 15 then
                            local ok, v = pcall(function() return d.Value end)
                            table.insert(vals, d.Name .. "=" .. (ok and clip(tostring(v), 24) or "?"))
                        end
                    end
                    table.insert(lines, clip(string.format("lobby %s (%s): children %s | values %s", obj.Name, obj.ClassName,
                        #kids > 0 and table.concat(kids, ", ") or "none", #vals > 0 and table.concat(vals, " ") or "none"), 600))
                    break
                end
            end
        end
        if rooms == 0 then table.insert(lines, "lobby: no teleporter / room / elevator objects found in workspace") end
        local gui, texts = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui"), {}
        for _, d in ipairs(gui and gui:GetDescendants() or {}) do
            if #texts >= 40 then break end
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text > 0 and isOnScreen(d) and not isOwnGui(d) then
                table.insert(texts, d.Name .. "=" .. clip(d.Text, 24))
            end
        end
        table.insert(lines, clip("lobby screen texts: " .. (#texts > 0 and table.concat(texts, ", ") or "none"), 2000))
    end)

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
                            -- every upgrade level, to learn the real skill-upgrade field names
                            -- (time stop cooldown / reach) that ControlUp now only guesses
                            if type(up) == "table" and #up > 0 then
                                local levels = {}
                                for n, step in ipairs(up) do
                                    local kv = {}
                                    if type(step) == "table" then
                                        for k, v in pairs(step) do table.insert(kv, tostring(k) .. "=" .. short(v)) end
                                        table.sort(kv)
                                    end
                                    table.insert(levels, n .. ": " .. table.concat(kv, " "))
                                end
                                table.insert(lines, string.format("upgrades slot %d %s (%d, active %s): %s", wanted[id], id, #up,
                                    tostring(def.active_attack), clip(table.concat(levels, " | "), 1500)))
                            end
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

-- "Save unit catalog": one line per unit the game defines (src.Data.Units, every module
-- and id) to AAMacro/unit_catalog.txt, plus a depth-limited dump of the other data modules
-- (traits, waves, levels ...) to AAMacro/game_data.txt, so the real field names are known.
local Catalog = {}
AutoPlaceModule.Catalog = Catalog -- the dumpers are used by the Dungeon Run report too
function Catalog.text(v, n)
    if type(v) == "table" then
        local c = 0
        for _ in pairs(v) do c = c + 1 end
        return "{" .. c .. "}"
    end
    local s = tostring(v)
    if #s > n then s = s:sub(1, n - 1) .. "~" end
    return s
end

-- Flags of an Attacks entry (freeze, aoe, buff, path_ability ...) as "[a,b]", "" when none.
function Catalog.flags(entry)
    local flags = {}
    if type(entry) == "table" then
        for _, k in ipairs({ "freeze", "stun", "slow", "aoe", "aoe_dot", "cone", "line", "full", "circle", "buff", "heal", "spawn_unit", "path_ability" }) do
            if entry[k] ~= nil then table.insert(flags, k) end
        end
    end
    return #flags > 0 and (" [" .. table.concat(flags, ",") .. "]") or ""
end

-- A table's values (array) or keys (set), joined: _secondary_damage_types may be either.
function Catalog.list(v)
    if type(v) ~= "table" then return v ~= nil and Catalog.text(v, 30) or "-" end
    local out = {}
    for k, x in pairs(v) do
        table.insert(out, type(k) == "number" and Catalog.text(x, 20) or tostring(k))
    end
    table.sort(out)
    return #out > 0 and table.concat(out, ",") or "-"
end

-- One catalog line for unit id. tags = { [unit id] = "Farm,Timestop" } from src.Data.UnitTags.
function Catalog.line(id, def, attacks, tags)
    local function num(v) return tonumber(v) and tostring(tonumber(v)) or "-" end
    local main = def.primary_attack_no_upgrades or def.primary_attack
    local entry = type(main) == "string" and type(attacks[main]) == "table" and attacks[main] or nil
    local shape = "?"
    if entry and entry.path_ability ~= nil then
        shape = "path"
    elseif def.spawn_unit == true or (entry and entry.spawn_unit ~= nil) then
        shape = "summoner"
    elseif entry then
        shape = "single"
        for _, k in ipairs({ "aoe_dot", "aoe", "cone", "line", "full", "circle" }) do
            if entry[k] ~= nil then shape = k break end
        end
    end
    if type(main) == "string" then shape = shape .. " " .. Catalog.text(main, 40) .. Catalog.flags(entry) end
    if def.max_path_units then shape = shape .. " max_path_units " .. num(def.max_path_units) end
    local act = def.active_attack
    local actText = "-"
    if act ~= nil and tostring(act) ~= "nil" and tostring(act) ~= "" then
        local a = attacks[tostring(act)]
        actText = Catalog.text(act, 40) .. Catalog.flags(a)
            .. (def.active_attack_cooldown and " cd " .. num(def.active_attack_cooldown) or "")
        if type(a) == "table" and a.path_ability ~= nil then actText = actText .. " (path)" end
    end
    local place = {}
    if def.hill_unit then table.insert(place, "hill") end
    if def.hybrid_placement then table.insert(place, "hybrid") end
    local up = def.upgrade or def.upgrades
    local upText = "0"
    if type(up) == "table" and #up > 0 then
        local last = up[#up]
        upText = tostring(#up)
        if type(last) == "table" then
            upText = upText .. string.format(" last dmg %s cd %s range %s cost %s", num(last.damage), num(last.attack_cooldown), num(last.range), num(last.cost))
            -- skill fields anywhere in the levels (the names ControlUp looks for)
            local skill = {}
            for n, step in ipairs(up) do
                if type(step) == "table" then
                    for k, v in pairs(step) do
                        local key = string.lower(tostring(k))
                        if key:find("active", 1, true) or key:find("skill", 1, true) or key:find("ability", 1, true) or key:find("note", 1, true) or key:find("reduc", 1, true) then
                            table.insert(skill, n .. ":" .. tostring(k) .. "=" .. Catalog.text(v, 30))
                        end
                    end
                end
            end
            if #skill > 0 then upText = upText .. " skill " .. table.concat(skill, " ") end
        end
    end
    local line = table.concat({ tostring(id), Catalog.text(def.name or def.display_name or "-", 30), Catalog.text(def.rarity or def.Rarity or "-", 14),
        num(def.cost), num(def.spawn_cap), AutoPlaceModule.RoleFromDef(tostring(id)) or "?",
        string.format("%s/%s/%s", num(def.damage), num(def.attack_cooldown), num(def.range)),
        Catalog.text(def._base_damage_type or "-", 20) .. " +" .. Catalog.list(def._secondary_damage_types), shape, actText,
        #place > 0 and table.concat(place, ",") or "-", num(def.farm_amount), tags[tostring(id)] or "-", upText }, " | ")
    if #line > 400 then line = line:sub(1, 399) .. "~" end
    return line
end

-- Depth-limited dump of one data module: numbers/strings/booleans printed, tables recursed,
-- functions and instances skipped, cut at maxLen characters. Top-level keys (a stage, a
-- level) are separated by a blank line.
function Catalog.dump(value, maxLen, depth)
    local out, size, cut, seen = {}, 0, false, {}
    local function add(s)
        if cut then return end
        if size + #s > maxLen then
            table.insert(out, "...cut")
            cut = true
            return
        end
        table.insert(out, s)
        size = size + #s + 1
    end
    local function walk(v, depth, indent)
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            if cut then return end
            local x = v[k]
            local t = typeof and typeof(x) or type(x)
            if indent == "" and #out > 0 then add("") end
            if type(x) == "table" then
                if depth <= 1 or seen[x] then
                    add(indent .. tostring(k) .. " = " .. Catalog.text(x, 10))
                else
                    seen[x] = true
                    add(indent .. tostring(k) .. ":")
                    walk(x, depth - 1, indent .. "  ")
                end
            elseif t ~= "function" and t ~= "Instance" then
                add(indent .. tostring(k) .. " = " .. Catalog.text(x, 120))
            end
        end
    end
    if type(value) == "table" then walk(value, depth or 3, "") else add(Catalog.text(value, 120)) end
    return table.concat(out, "\n")
end

-- Writes AAMacro/<file>; falls back to the clipboard. Returns where it went, or nil.
function Catalog.save(file, text)
    if hasFileApi() then
        local ok = pcall(function()
            ensureFolder(Config.Folder)
            writefile(Config.Folder .. "/" .. file, text)
        end)
        if ok then return Config.Folder .. "/" .. file end
    end
    if type(setclipboard) == "function" and pcall(setclipboard, text) then return "clipboard" end
    return nil
end

-- "Save unit catalog" also writes AAMacro/remotes_and_hud.txt (data only, nothing is called):
-- every remote under ReplicatedStorage.endpoints, the bottom hotbar slots (price "text" +
-- "¥" symbol, or "LevelText" Lvl) with texts, images, attributes and values, a visible
-- "Choose a card!" vote, and game tables (getgc) about temporary units / spells / cards.
Catalog.EVENT_WORDS = { "temporary", "spell", "fool", "card", "april", "vote", "modifier" }
function Catalog.guiNode(d, indent, out)
    local bits = { indent .. d.Name .. " (" .. d.ClassName .. ")" }
    pcall(function()
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            table.insert(bits, "text=" .. Catalog.text((tostring(d.Text):gsub("\n", " ")), 80))
        end
    end)
    pcall(function()
        if d:IsA("ImageLabel") or d:IsA("ImageButton") then
            local img = d.Image
            if img ~= nil and img ~= "" then table.insert(bits, "image=" .. tostring(img)) end
        end
    end)
    pcall(function()
        if d:IsA("ValueBase") then table.insert(bits, "value=" .. Catalog.text(d.Value, 80)) end
    end)
    pcall(function()
        local attrs, keys = d:GetAttributes(), {}
        for k in pairs(attrs) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        for _, k in ipairs(keys) do table.insert(bits, "@" .. k .. "=" .. Catalog.text(attrs[k], 60)) end
    end)
    table.insert(out, table.concat(bits, " "))
end
function Catalog.guiTree(root, depth, out, indent)
    indent = indent or "  "
    if #out > 4000 then return end
    for _, c in ipairs(root:GetChildren()) do
        Catalog.guiNode(c, indent, out)
        if depth > 1 then Catalog.guiTree(c, depth - 1, out, indent .. "  ") end
    end
end
function Catalog.remotesAndHud()
    local out = { "# remotes_and_hud " .. os.date("%Y-%m-%d %H:%M:%S") .. " | stage " .. tostring(State.stage) }
    -- (a) remotes, full path + class, no clipping
    local remotes = {}
    pcall(function()
        local ep = ReplicatedStorage:FindFirstChild("endpoints")
        for _, d in ipairs(ep and ep:GetDescendants() or {}) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction")
                or d.ClassName == "UnreliableRemoteEvent" then
                table.insert(remotes, d:GetFullName() .. " (" .. d.ClassName .. ")")
            end
        end
    end)
    table.sort(remotes)
    table.insert(out, string.format("== remotes (%d) ==", #remotes))
    for _, r in ipairs(remotes) do table.insert(out, r) end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    -- (b) hotbar slots: the frame that is one of several sibling slots holding a price / Lvl label
    local markers = {}
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        pcall(function()
            if not d:IsA("TextLabel") or isOwnGui(d) then return end
            local hit = false
            if d.Name == "text" then
                local sym = d.Parent and d.Parent:FindFirstChild("symbol")
                hit = sym ~= nil and sym:IsA("TextLabel") and tostring(sym.Text):find("¥", 1, true) ~= nil
            elseif d.Name == "LevelText" then
                hit = tostring(d.Text):find("Lvl", 1, true) ~= nil
            end
            if hit then table.insert(markers, d) end
        end)
    end
    local function holdsMarker(node)
        for _, m in ipairs(markers) do if m == node or m:IsDescendantOf(node) then return true end end
        return false
    end
    local slots, seenSlot = {}, {}
    for _, m in ipairs(markers) do
        local node, slot = m.Parent, m.Parent
        for _ = 1, 5 do
            local p = node and node.Parent
            if not p or p == gui then break end
            local n = 0
            for _, sib in ipairs(p:GetChildren()) do if holdsMarker(sib) then n = n + 1 end end
            if n >= 2 then slot = node break end
            node = p
        end
        if slot and not seenSlot[slot] then seenSlot[slot] = true table.insert(slots, slot) end
    end
    table.insert(out, "")
    table.insert(out, string.format("== hotbar slots (%d) ==", #slots))
    for i, slot in ipairs(slots) do
        local names = {}
        for _, c in ipairs(slot:GetChildren()) do table.insert(names, c.Name) end
        table.insert(out, string.format("slot %d: %s | children: %s", i, slot:GetFullName(), table.concat(names, ", ")))
        Catalog.guiNode(slot, "  self: ", out)
        Catalog.guiTree(slot, 3, out, "  ")
    end
    -- (c) a visible "Choose a card!" vote: the screen it sits on
    table.insert(out, "")
    table.insert(out, "== card vote ==")
    local cards = 0
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        local ok, hit = pcall(function()
            return (d:IsA("TextLabel") or d:IsA("TextButton")) and not isOwnGui(d) and isOnScreen(d)
                and string.lower(tostring(d.Text)):find("choose a card", 1, true) ~= nil
        end)
        if ok and hit and cards < 2 then
            cards = cards + 1
            local root = d:FindFirstAncestorWhichIsA("LayerCollector") or d.Parent
            table.insert(out, "vote screen: " .. root:GetFullName() .. " (title " .. d:GetFullName() .. ")")
            Catalog.guiTree(root, 6, out, "  ")
        end
    end
    if cards == 0 then table.insert(out, "no 'Choose a card!' on screen") end
    -- (d) game tables about temporary units / spells / cards / votes (shallow, max 20)
    table.insert(out, "")
    table.insert(out, "== getgc tables (event words: " .. table.concat(Catalog.EVENT_WORDS, ", ") .. ") ==")
    local found = 0
    pcall(function()
        if type(getgc) ~= "function" then table.insert(out, "getgc not available") return end
        for _, v in ipairs(getgc(true)) do
            if found >= 20 then break end
            if type(v) == "table" then
                local hitKey
                pcall(function()
                    for k in pairs(v) do
                        if type(k) == "string" then
                            local lk = string.lower(k)
                            for _, w in ipairs(Catalog.EVENT_WORDS) do
                                if lk:find(w, 1, true) then hitKey = k break end
                            end
                        end
                        if hitKey then break end
                    end
                end)
                if hitKey then
                    found = found + 1
                    local parts, n = {}, 0
                    pcall(function()
                        for k, x in pairs(v) do
                            n = n + 1
                            if n > 40 then table.insert(parts, "...") break end
                            table.insert(parts, tostring(k) .. "=" .. Catalog.text(x, 60))
                        end
                    end)
                    table.insert(out, string.format("table %d (key %s): %s", found, hitKey, table.concat(parts, " ")))
                end
            end
        end
    end)
    if found == 0 then table.insert(out, "none found") end
    return table.concat(out, "\n")
end

-- AAMacro/event_data.txt: every ModuleScript under ReplicatedStorage whose table mentions an
-- event word (Fool's Hunt cards / spells: Spellproof, Enemy Health, Refund, Astral ...) in a
-- key or a string value, with its full path and a depth-4 dump (60 KB per module at most).
-- Modules that error or are huge (over 200000 table entries) are skipped.
Catalog.MODULE_WORDS = { "spellproof", "enemy health", "enemy speed", "aprilcoins", "april", "fool", "curse",
    "blessing", "modifier", "refund", "astral", "ritual", "merge", "clone" }
function Catalog.findWord(value)
    local seen, count, hit = {}, 0, nil
    local function str(s)
        local l = string.lower(s)
        for _, w in ipairs(Catalog.MODULE_WORDS) do
            if l:find(w, 1, true) then return w end
        end
    end
    local function walk(v, depth)
        if hit or count > 200000 or depth > 8 or seen[v] then return end
        seen[v] = true
        for k, x in pairs(v) do
            count = count + 1
            if hit or count > 200000 then return end
            if type(k) == "string" then hit = hit or (str(k) and (str(k) .. " in key " .. Catalog.text(k, 40))) end
            if type(x) == "string" then hit = hit or (str(x) and (str(x) .. " in " .. Catalog.text(k, 30) .. "=" .. Catalog.text(x, 40)))
            elseif type(x) == "table" then walk(x, depth + 1) end
        end
    end
    if type(value) == "table" then walk(value, 1) end
    if count > 200000 then return nil, "huge" end
    return hit
end
function Catalog.eventData()
    local blocks, scanned, skipped = {}, 0, 0
    for _, m in ipairs(ReplicatedStorage:GetDescendants()) do
        if m:IsA("ModuleScript") then
            scanned = scanned + 1
            local ok, value = pcall(require, m)
            if ok and type(value) == "table" then
                local okFind, hit, why = pcall(Catalog.findWord, value)
                if okFind and hit then
                    local okDump, body = pcall(Catalog.dump, value, 60000, 4)
                    table.insert(blocks, "== " .. m:GetFullName() .. " (" .. hit .. ") ==\n" .. (okDump and body or "(dump failed)"))
                elseif not okFind or why == "huge" then
                    skipped = skipped + 1
                end
            elseif not ok then
                skipped = skipped + 1
            end
        end
    end
    table.insert(blocks, 1, string.format("# event_data %s | %d modules scanned, %d with event words, %d skipped (error / huge) | words: %s",
        os.date("%Y-%m-%d %H:%M:%S"), scanned, #blocks, skipped, table.concat(Catalog.MODULE_WORDS, ", ")))
    return table.concat(blocks, "\n\n"), #blocks - 1
end

function AutoPlaceModule.SaveCatalog()
    local src = ReplicatedStorage:FindFirstChild("src")
    local data = src and src:FindFirstChild("Data")
    local attacks, tags = {}, {}
    pcall(function()
        local ok, mod = pcall(require, data:FindFirstChild("Attacks"))
        if ok and type(mod) == "table" then attacks = mod end
    end)
    -- UnitTags: { Farm = { "speedcart", ... } or { speedcart = true }, Timestop = ... }
    pcall(function()
        local ok, mod = pcall(require, data:FindFirstChild("UnitTags"))
        if not (ok and type(mod) == "table") then return end
        local names = {}
        for tag in pairs(mod) do table.insert(names, tostring(tag)) end
        table.sort(names)
        for _, tag in ipairs(names) do
            local members = mod[tag]
            if type(members) == "table" then
                for k, v in pairs(members) do
                    local id = type(k) == "number" and tostring(v) or tostring(k)
                    tags[id] = tags[id] and (tags[id] .. "," .. tag) or tag
                end
            end
        end
    end)
    local lines, ids = {}, {}
    local units = data and data:FindFirstChild("Units")
    for _, m in ipairs(units and units:GetDescendants() or {}) do
        if m:IsA("ModuleScript") then
            pcall(function()
                local ok, defs = pcall(require, m)
                if not (ok and type(defs) == "table") then return end
                for id, def in pairs(defs) do
                    if type(def) == "table" and not ids[tostring(id)] then
                        local ok2, line = pcall(Catalog.line, id, def, attacks, tags)
                        ids[tostring(id)] = true
                        table.insert(lines, ok2 and line or (tostring(id) .. " | error reading this unit"))
                    end
                end
            end)
        end
    end
    table.sort(lines)
    table.insert(lines, 1, string.format("# %d units | id | name | rarity | cost | spawn_cap | role | damage/attack_cooldown/range"
        .. " | damage type +secondary | attack shape, primary attack [flags] | active_attack [flags] | placement | farm_amount"
        .. " | UnitTags | upgrade levels, last level, skill fields", #lines))
    local where = Catalog.save("unit_catalog.txt", table.concat(lines, "\n"))
    notify(where and string.format("Unit catalog saved: %s (%d units)", where, #lines - 1) or "Unit catalog: no writefile or setclipboard here.")

    -- the other data modules, one "== Name ==" block each (a Folder of modules is walked too)
    local blocks = {}
    for _, name in ipairs({ "Traits", "TraitStats", "Buffs", "Boosts", "Waves", "Levels", "Maps", "Worlds", "ChallengeAndRewards" }) do
        pcall(function()
            local obj = data and data:FindFirstChild(name)
            if not obj then return end
            local mods = obj:IsA("ModuleScript") and { obj } or {}
            if not obj:IsA("ModuleScript") then
                for _, d in ipairs(obj:GetDescendants()) do
                    if d:IsA("ModuleScript") then table.insert(mods, d) end
                end
            end
            for _, m in ipairs(mods) do
                local ok, value = pcall(require, m)
                local body = ok and Catalog.dump(value, 40000) or "(could not be read)"
                table.insert(blocks, "== " .. (m == obj and name or (name .. "/" .. m.Name)) .. " ==\n" .. body)
            end
        end)
    end
    if where ~= "clipboard" then
        local ok, text = pcall(Catalog.remotesAndHud)
        if not ok then text = "remotes_and_hud failed: " .. tostring(text) end
        local whereHud = Catalog.save("remotes_and_hud.txt", text)
        notify(whereHud and string.format("Remotes + hotbar saved: %s (%d KB)", whereHud, math.ceil(#text / 1024))
            or "Remotes + hotbar: not saved (no writefile here).")
        local okEv, evText, hits = pcall(Catalog.eventData)
        if not okEv then evText, hits = "event_data failed: " .. tostring(evText), 0 end
        local whereEv = Catalog.save("event_data.txt", evText)
        notify(whereEv and string.format("Event data saved: %s (%d KB, %d modules with event words)", whereEv, math.ceil(#evText / 1024), hits or 0)
            or "Event data: not saved (no writefile here).")
    end
    -- every child of src.Data by full name, so modules not dumped here are known by name
    pcall(function()
        local names = {}
        for _, c in ipairs(data and data:GetChildren() or {}) do table.insert(names, c:GetFullName() .. " (" .. c.ClassName .. ")") end
        table.sort(names)
        table.insert(blocks, 1, "== src.Data children (" .. #names .. ") ==\n" .. table.concat(names, "\n"))
    end)
    if #blocks > 0 then
        local text = table.concat(blocks, "\n\n")
        local whereData = where == "clipboard" and nil or Catalog.save("game_data.txt", text)
        notify(whereData and string.format("Game data saved: %s (%d KB, %d modules)", whereData, math.ceil(#text / 1024), #blocks)
            or "Game data: not saved (no writefile here).")
    end
end
end

--------------------------------------------------------------------------------
-- MODULE: Game report webhook (after every game: result, rewards, player, bag, team)
--------------------------------------------------------------------------------
do
local function httpPost(url, body)
    local req = (syn and syn.request) or (http and http.request) or request or http_request
    if type(req) ~= "function" then return false end
    return pcall(req, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
end

local function commas(n)
    local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""):gsub("^%-,", "-"))
end

local function prettyName(id)
    return (tostring(id):gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- AA keeps the bag in ItemInventoryServiceClient.session.inventory.inventory_profile_data;
-- if the loader cannot be required here, find that table in memory instead.
local function inventoryData()
    local data
    pcall(function()
        local loader = require(ReplicatedStorage.src.Loader)
        local svc = loader.load_client_service(script, "ItemInventoryServiceClient")
        data = svc.session.inventory.inventory_profile_data
    end)
    if type(data) ~= "table" and type(getgc) == "function" then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and type(rawget(v, "normal_items")) == "table" then data = v break end
            end
        end)
    end
    return type(data) == "table" and data or nil
end

-- { [item id] = count } from normal + unique items, whatever shape the game uses.
local function itemCounts(data)
    local counts, total = {}, 0
    local function add(id, n)
        id = tostring(id)
        counts[id] = (counts[id] or 0) + n
        total = total + n
    end
    for _, key in ipairs({ "normal_items", "unique_items" }) do
        local list = data and data[key]
        if type(list) == "table" then
            for k, v in pairs(list) do
                if type(v) == "number" then add(k, v)
                elseif type(v) == "table" then
                    add(v.item_id or v.id or v.name or k, tonumber(v.amount or v.count or v.quantity) or 1)
                end
            end
        end
    end
    return counts, total
end

-- (the Lobby tab reads the bag with the same helpers)
Lobby.inventoryData, Lobby.itemCounts, Lobby.prettyName = inventoryData, itemCounts, prettyName

-- Bag size: a number field named like max/capacity/limit/slots on the inventory data.
local function bagCapacity(data)
    if not data then return nil end
    for k, v in pairs(data) do
        local key = string.lower(tostring(k))
        if type(v) == "number" and v > 0 and (key:find("max", 1, true) or key:find("capacity", 1, true)
            or key:find("limit", 1, true) or key:find("slot", 1, true)) then
            return v, tostring(k)
        end
    end
    return nil
end

local function playerSnapshot()
    local snap = { at = os.clock() }
    local stats = Players.LocalPlayer:FindFirstChild("_stats")
    local function num(name)
        local v = stats and stats:FindFirstChild(name)
        return v and tonumber(v.Value) or nil
    end
    snap.gold, snap.gems = num("gold_amount"), num("gem_amount")
    -- "Level 206 [755/1535]": other players' cards and max-level previews also say
    -- "Level 999 [999999/999999]", so only visible labels count and the lowest one on
    -- screen (our own XP bar) wins
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local bestY = -math.huge
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) then
            local plain = tostring(d.Text):gsub("<[^>]->", ""):gsub(",", "")
            local lvl, cur, max = plain:match("^%s*[Ll]evel%s+(%d+)%s*%[(%d+)%s*/%s*(%d+)%]")
            lvl, cur, max = tonumber(lvl), tonumber(cur), tonumber(max)
            if lvl and cur and max and cur < max and d.AbsolutePosition.Y > bestY then
                bestY = d.AbsolutePosition.Y
                snap.level, snap.xp, snap.xpMax = lvl, cur, max
            end
        end
    end
    local inv = inventoryData()
    snap.items, snap.itemTotal = itemCounts(inv)
    snap.kinds = 0
    for _ in pairs(snap.items) do snap.kinds = snap.kinds + 1 end
    snap.bagMax = bagCapacity(inv)
    snap.hasInventory = inv ~= nil
    return snap
end
-- (the Bag cleaner's "When bag is over": same reading as the report's Bag line)
function Lobby.BagFraction() return select(2, Webhook.BagLine(playerSnapshot())) end

-- "+20", "+55 XP" ... shown on the result screen.
local function resultScreenGains()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local seen, out = {}, {}
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) then
            local t = tostring(d.Text)
            if t:match("^%s*%+%s*[%d,]+") and not seen[t] then
                seen[t] = true
                table.insert(out, t)
            end
        end
    end
    return out
end

local session = { started = os.clock(), wins = 0, losses = 0 }
local startSnap, firstSnap
local gameWave = 0 -- highest wave seen this game (the counter is reset when the result shows)

local function clock(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function waveNow()
    local w = getCurrentWave()
    local alt = workspace:FindFirstChild("_wave_num")
    if alt and tonumber(alt.Value) then w = math.max(w, tonumber(alt.Value)) end
    return w
end

-- Player headshot for the embed thumbnail (looked up once).
local avatarUrl
local function playerAvatar()
    if avatarUrl ~= nil then return avatarUrl or nil end
    avatarUrl = false
    pcall(function()
        local id = Players.LocalPlayer.UserId
        local raw = game:HttpGet("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. id .. "&size=150x150&format=Png")
        local data = HttpService:JSONDecode(raw)
        local url = data and data.data and data.data[1] and data.data[1].imageUrl
        if type(url) == "string" and url:find("^https://") then avatarUrl = url end
    end)
    return avatarUrl or nil
end

-- "Normal" / "Hard" / "Nightmare" shown under the stage name on the result screen.
local function difficultyText()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) then
            local t = tostring(d.Text):gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
            local low = string.lower(t)
            if low == "normal" or low == "hard" or low == "nightmare" or low == "insane" then return t end
        end
    end
    return nil
end

local function yamlValue(v)
    return (tostring(v):gsub("\n", " "):gsub("`", "'"))
end

-- Bag state for the report and the bag-full ping: "95 / 100", "✅ space left" ..., fraction.
function Webhook.BagLine(snap)
    if not snap.hasInventory then return "not readable", nil end
    local used = (snap.bagMax and snap.itemTotal <= snap.bagMax and snap.itemTotal)
        or (snap.bagMax and snap.kinds <= snap.bagMax and snap.kinds) or nil
    if not used then return string.format("%s items", commas(snap.itemTotal)), nil end
    local f = used / snap.bagMax
    local state = (f >= 1 and "⛔ full") or (f >= 0.9 and "⚠️ almost full") or "✅ space left"
    return string.format("`%s / %s` · %s", commas(used), commas(snap.bagMax), state), f
end

-- Won or lost. The result screen can open before its VICTORY text shows (Infinity Mansion
-- Room 51: a win was reported as a defeat 1 s after the last wave), so wait up to 4 s for
-- the word; a "Defeat" / "Game over" label alone means lost. With neither, the base still
-- standing (HP above 0 at the top of the screen) means won.
function Webhook.ResultWin()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _ = 1, 16 do
        if resultIsVictory() then return true end
        for _, d in ipairs(gui and gui:GetDescendants() or {}) do
            if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) then
                local t = string.lower(tostring(d.Text)):gsub("<[^>]->", ""):match("^%s*(.-)[%p%s]*$")
                if t == "defeat" or t == "game over" then return false end
            end
        end
        task.wait(0.25)
    end
    local cur = AutoPlaceModule.ScanBaseHp()
    return cur ~= nil and cur > 0
end

function Webhook.BuildReport(kind)
    local now = playerSnapshot()
    local before = startSnap or now
    local win = kind == "win"
    local head = (kind == "test" and "🧪 TEST REPORT") or (win and "🏆 VICTORY") or "💀 DEFEAT"
    local diff = difficultyText() or (Stage.difficulty ~= "Normal" and Stage.difficulty) or nil
    if diff then head = head .. " · " .. diff end
    local runTime = startSnap and (now.at - startSnap.at) or 0

    -- (Discord squeezes runs of spaces into one, so items on a line are split with " · ")
    local stage = Stage.Pretty() or State.stage or "Unknown stage"
    local place, rest = stage:match("^(.-) — (.+)$")
    local desc = {
        "📍 " .. (place and ("**" .. place .. "** — " .. rest) or ("**" .. stage .. "**")),
        string.format("⏱ `%s` · 🌊 Wave `%d`", clock(runTime), math.max(gameWave, waveNow())),
        "👤 ||" .. tostring(Players.LocalPlayer.Name) .. "||",
    }

    -- Rewards: one line each, what this game added first, the total in brackets
    local rewards = {}
    if now.gems and before.gems and now.gems ~= before.gems then
        table.insert(rewards, string.format("💎 **%s%s** Gems · %s", now.gems > before.gems and "+" or "", commas(now.gems - before.gems), commas(now.gems)))
    end
    if now.gold and before.gold and now.gold ~= before.gold then
        table.insert(rewards, string.format("🪙 **%s%s** Gold · %s", now.gold > before.gold and "+" or "", commas(now.gold - before.gold), commas(now.gold)))
    end
    if now.level and now.xp then
        local gain
        if before.level and before.xp and now.level == before.level then gain = now.xp - before.xp
        elseif before.level and before.xp and before.xpMax and now.level > before.level then gain = (before.xpMax - before.xp) + now.xp end
        local where = string.format("Lv %d%s (%s / %s)", now.level, (before.level and now.level > before.level) and " ↑" or "",
            commas(now.xp), commas(now.xpMax or 0))
        if gain and gain > 0 then table.insert(rewards, string.format("⭐ **+%s** XP · %s", commas(gain), where)) end
    end
    local gotItems = {}
    for id, n in pairs(now.items or {}) do
        local was = (before.items or {})[id] or 0
        if n > was then table.insert(gotItems, { id = id, n = n, got = n - was }) end
    end
    table.sort(gotItems, function(a, b) return a.got > b.got end)
    for i, it in ipairs(gotItems) do
        if i > 10 then table.insert(rewards, string.format("📦 ... and %d more", #gotItems - 10)) break end
        table.insert(rewards, string.format("📦 **+%d** %s", it.got, prettyName(it.id)))
    end
    if #rewards == 0 then
        for _, g in ipairs(resultScreenGains()) do table.insert(rewards, "🎁 " .. g) end
    end
    if #rewards == 0 then table.insert(rewards, "nothing new") end

    local bagText = Webhook.BagLine(now)
    local embed = {
        author = { name = "moseeri hub" },
        title = head,
        color = kind == "test" and 5793266 or (win and 5763719 or 15548997),
        description = table.concat(desc, "\n"),
        fields = {
            { name = "🎁 Rewards", value = table.concat(rewards, "\n"), inline = false },
            { name = "🎒 Bag", value = bagText, inline = false },
        },
        footer = { text = "moseeri hub · Notify" },
    }
    if kind == "loss" then
        -- what Auto Place was doing when the game was lost, so a defeat can be looked into
        -- from Discord alone: units on the map (count and highest upgrade) and its last actions
        local why = { "Lost at wave: " .. math.max(gameWave, waveNow()) }
        local units, order = {}, {}
        for _, u in ipairs(ownedUnits()) do
            local name = unitType(u)
            local lvl = u:FindFirstChild("_stats") and u._stats:FindFirstChild("upgrade")
            if not units[name] then units[name] = { n = 0, top = 0 } table.insert(order, name) end
            units[name].n = units[name].n + 1
            units[name].top = math.max(units[name].top, lvl and tonumber(lvl.Value) or 0)
        end
        if #order > 0 then table.insert(why, "# Units (copies, best upgrade) #") end
        for _, name in ipairs(order) do
            table.insert(why, string.format("%s: x%d, up %d", yamlValue(name), units[name].n, units[name].top))
        end
        local log = AutoPlaceModule.log or {}
        if #log > 0 then table.insert(why, "# Last actions #") end
        for i = #log, 1, -1 do
            table.insert(why, string.format("- %ds before: %s", math.floor(os.clock() - log[i].at), yamlValue(log[i].text)))
        end
        if AutoPlaceModule.problem then table.insert(why, "Problem: " .. yamlValue(AutoPlaceModule.problem)) end
        table.insert(embed.fields, { name = "Why it was lost", value = clip("```yaml\n" .. table.concat(why, "\n"), 1000) .. "\n```", inline = false })
    end
    local avatar = playerAvatar()
    if avatar then embed.thumbnail = { url = avatar } end
    pcall(function() embed.timestamp = DateTime.now():ToIsoDate() end)
    return { username = "moseeri hub", embeds = { embed } }
end

-- "Discord alerts" (Settings): one switch for every report / ping flag below.
Webhook.ALERT_FLAGS = { "notifyComplete", "notifyFail", "pingMythic", "pingBagFull", "pingDisconnect", "pingLosses" }
function Webhook.AlertsOn()
    if #tostring(Webhook.url or "") < 10 then return false end
    for _, k in ipairs(Webhook.ALERT_FLAGS) do if Webhook[k] then return true end end
    return false
end
function Webhook.SetAlerts(on)
    for _, k in ipairs(Webhook.ALERT_FLAGS) do Webhook[k] = on == true end
end
-- the URL box shows only the last 4 characters once a URL is set
function Webhook.Masked()
    local u = tostring(Webhook.url or "")
    return #u >= 10 and ("****" .. u:sub(-4)) or u
end
function Webhook.SetUrl(text)
    text = tostring(text or "")
    if #Webhook.url >= 10 and text == Webhook.Masked() then return end -- our own masked text
    local had = #Webhook.url >= 10
    Webhook.url = text
    -- a first URL turns the alerts on
    if not had and #text >= 10 then
        Webhook.SetAlerts(true)
        pcall(function() setToggle(Controls.discordAlerts, true) end)
    end
    pcall(function() Controls.webhookUrl:UpdateText(Webhook.Masked()) end)
    saveConfig()
end

-- Discord ping for important events only (Mythic/Secret drop, bag full, disconnect / kick,
-- two losses in a row): "@here" (allowed_mentions parse "everyone" is what lets @here
-- ping), or "<@ID>" for an old config that saved a user id. Normal reports mention nobody.
-- At most one ping per event type per 2 minutes.
Webhook.lastPing = {}
-- owner turned pings off for now (2026-10-24): alerts still post, they just mention nobody
Webhook.pingsOff = true
function Webhook.PingFor(kind)
    if Webhook.pingsOff then return nil end
    local id = tostring(Webhook.pingId or ""):match("^%s*(%d+)%s*$")
    if id and #id < 5 then id = nil end
    local on = ({ mythic = Webhook.pingMythic, bag = Webhook.pingBagFull, disconnect = Webhook.pingDisconnect, losses = Webhook.pingLosses })[kind]
    if on == false then return nil end
    local now = os.clock()
    if Webhook.lastPing[kind] and now - Webhook.lastPing[kind] < 120 then return nil end
    Webhook.lastPing[kind] = now
    return id or "here"
end
local function withPing(payload, kinds)
    for _, kind in ipairs(kinds or {}) do
        local id = Webhook.PingFor(kind)
        if id == "here" then
            payload.content = "@here"
            payload.allowed_mentions = { parse = { "everyone" } }
            return payload
        elseif id then
            payload.content = "<@" .. id .. ">"
            payload.allowed_mentions = { parse = {}, users = { id } }
            return payload
        end
    end
    payload.allowed_mentions = { parse = {} }
    return payload
end

function Webhook.SendReport(kind, pings)
    if #Webhook.url < 10 then return false end
    local ok, payload = pcall(Webhook.BuildReport, kind)
    if not ok then return false end
    return httpPost(Webhook.url, HttpService:JSONEncode(withPing(payload, pings)))
end

-- A short alert embed (Mythic drop, bag full, disconnect) with the ping.
function Webhook.Alert(kind, title, text, color)
    if #Webhook.url < 10 then return false end
    local payload = { username = "moseeri hub", embeds = { {
        author = { name = "moseeri hub" }, title = title, description = text, color = color or 16766720,
        footer = { text = "moseeri hub · Notify" } } } }
    pcall(function() payload.embeds[1].timestamp = DateTime.now():ToIsoDate() end)
    return httpPost(Webhook.url, HttpService:JSONEncode(withPing(payload, { kind })))
end

-- Owned units (uuid -> unit id) from the game's tables, like the team read.
function Webhook.OwnedUnits()
    local out = {}
    pcall(function()
        for _, v in ipairs(type(getgc) == "function" and getgc(true) or {}) do
            if type(v) == "table" then
                local uuid, id = rawget(v, "uuid"), rawget(v, "unit_id")
                if type(uuid) == "string" and type(id) == "string" then out[uuid] = id end
            end
        end
    end)
    return out
end

-- Units new since the game started whose rarity is Mythic or Secret; else result-screen
-- texts that say Mythic / Secret. Returns a list of "Mythic: Name" lines.
function Webhook.RareDrops(before)
    local found = {}
    for uuid, id in pairs(Webhook.OwnedUnits()) do
        if before and not before[uuid] then
            local def = AutoPlaceModule.UnitDef(id) or {}
            local rarity = tostring(def.rarity or "")
            if rarity:lower() == "mythic" or rarity:lower() == "secret" then
                table.insert(found, string.format("%s: %s", rarity:sub(1, 1):upper() .. rarity:sub(2):lower(), tostring(def.name or prettyName(id))))
            end
        end
    end
    if #found == 0 then
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        for _, d in ipairs(gui and gui:GetDescendants() or {}) do
            pcall(function()
                if d:IsA("TextLabel") and isOnScreen(d) and not isOwnGui(d) then
                    local t = tostring(d.Text):gsub("<[^>]->", "")
                    local l = t:lower()
                    if (l:find("mythic", 1, true) or l:find("secret", 1, true)) and #t <= 60 and #found < 3 then table.insert(found, t) end
                end
            end)
        end
    end
    table.sort(found)
    return found
end

-- Disconnect / kick: the error prompt or the local player leaving (once, best effort).
pcall(function()
    local gs = game:GetService("GuiService")
    local function onError(msg)
        if State.unloaded then return end
        local text = type(msg) == "string" and msg or ""
        if text == "" then pcall(function() text = gs:GetErrorMessage() end) end
        if text == "" or Webhook.disconnectSent then return end
        Webhook.disconnectSent = true
        if Webhook.pingDisconnect ~= false then pcall(Webhook.Alert, "disconnect", "⚠️ Disconnected", clip(text, 300), 15105570) end
    end
    pcall(function() table.insert(State.connections, gs.ErrorMessageChanged:Connect(onError)) end)
    pcall(function()
        table.insert(State.connections, Players.PlayerRemoving:Connect(function(p)
            if p == Players.LocalPlayer then onError("left the game (kicked or closed)") end
        end))
    end)
end)

-- Snapshot when a game starts, report when its result screen shows (once per game).
task.spawn(function()
    local wasStarted, wasResults = false, false
    local unitsBefore, reported
    while not State.unloaded do
        task.wait(1)
        local data = workspace:FindFirstChild("_DATA")
        local started = data and data:FindFirstChild("GameStarted")
        local isStarted = started and started.Value == true
        if isStarted and not wasStarted then
            reported = false
            startSnap, gameWave = playerSnapshot(), 0
            firstSnap = firstSnap or startSnap
            unitsBefore = #Webhook.url >= 10 and Webhook.OwnedUnits() or nil
        end
        if isStarted then gameWave = math.max(gameWave, waveNow()) end
        wasStarted = isStarted
        local results = isResultsShowing()
        if results and not wasResults and startSnap and not reported then
            reported = true -- (the result screen going away and back is the same game)
            local win = Webhook.ResultWin()
            if win then session.wins = session.wins + 1 else session.losses = session.losses + 1 end
            session.lossStreak = win and 0 or (session.lossStreak or 0) + 1
            pcall(AutoPlaceModule.OnResult, win)
            pcall(Lobby.TowerResult, win)
            -- (while Watch is on: one line per game in AAMacro/games.txt, to measure a strategy)
            if State.watching then
                pcall(function()
                    local old
                    pcall(function() old = readfile(Config.Folder .. "/games.txt") end)
                    local line = string.format("%s | %s | %s | wave %d | units %d | candy %s | gains %s", os.date("%Y-%m-%d %H:%M:%S"),
                        tostring(State.stage), win and "WIN" or "LOSS", math.max(gameWave, waveNow()), #ownedUnits(),
                        tostring(Lobby.candy), table.concat(resultScreenGains(), " "))
                    AutoPlaceModule.Catalog.save("games.txt", ((type(old) == "string" and old ~= "") and (old .. "\n") or "") .. line)
                end)
            end
            task.wait(1.5) -- let the game add the rewards first
            local pings = {}
            -- bag turned full (once until it has room again)
            local okBag, frac = pcall(function() return select(2, Webhook.BagLine(playerSnapshot())) end)
            local bagFull = okBag and frac ~= nil and frac >= 1
            local bagTurnedFull = bagFull and not Webhook.bagFullNoted
            Webhook.bagFullNoted = bagFull
            if bagTurnedFull and Webhook.pingBagFull ~= false then table.insert(pings, "bag") end
            local lossAlarm = not win and session.lossStreak >= 2 and Webhook.pingLosses ~= false
            if lossAlarm then table.insert(pings, "losses") end
            local report = (win and Webhook.notifyComplete) or (not win and Webhook.notifyFail) or lossAlarm
            if report then
                Webhook.SendReport(win and "win" or "loss", pings)
            elseif bagTurnedFull and Webhook.pingBagFull ~= false then
                Webhook.Alert("bag", "⛔ Bag full", "Your bag is full: new drops are lost until you make room.", 15548997)
            end
            if Webhook.pingMythic ~= false and unitsBefore then
                local okR, drops = pcall(Webhook.RareDrops, unitsBefore)
                if okR and #drops > 0 then
                    Webhook.Alert("mythic", "🌟 " .. drops[1], table.concat(drops, "\n"), 16766720)
                end
            end
        end
        wasResults = results
    end
end)
end

do
local Catalog = AutoPlaceModule.Catalog
--------------------------------------------------------------------------------
-- MODULE: Dungeon Run (data first; acts only on room / item ids read from the game)
--------------------------------------------------------------------------------
-- A run costs a Dungeon Key: 20 depths, a boss at the end, room choices at each step
-- (SHOP, HOARD, CHEST, SHRINE, BATTLE), 5 lost rooms end the run, QUIT loses everything.
-- The client_to_server remotes are known by name (dungeon_enter_room, dungeon_buy_shop ...)
-- but not their arguments, so the bot reads the run from the game's own tables (getgc) and
-- the screen, shows it, and only calls a remote with an argument it found there: a room /
-- item id when the entries have one, else its position in the game's own list. Each call
-- is checked (the run must change within 5 s); a call that changes nothing stops the bot
-- until the owner sends a dungeon report. It never clicks screen buttons, never starts or
-- quits a run, and buys only wish-list items.
DungeonRun.WORDS = { "depth", "floor", "room", "heart", "lives", "death", "shop", "curse", "blessing", "hoard",
    "chest", "coin", "dungeon", "shrine", "key" }
DungeonRun.TYPES = { "HOARD", "CHEST", "SHOP", "BATTLE", "SHRINE", "BOSS" }
DungeonRun.WAITING = "waiting for dungeon data - press Copy dungeon report in a run and send it"

function DungeonRun.priority()
    local list = {}
    for w in tostring(DungeonRun.roomPriority or ""):upper():gmatch("%a+") do
        for _, t in ipairs(DungeonRun.TYPES) do if w == t then table.insert(list, t) end end
    end
    if #list == 0 then list = { "HOARD", "CHEST", "SHOP", "BATTLE", "SHRINE" } end
    return list
end

function DungeonRun.wishes()
    local list = {}
    for w in tostring(DungeonRun.wishList or ""):gmatch("[^,;\n]+") do
        local s = w:match("^%s*(.-)%s*$")
        if s ~= "" then table.insert(list, string.lower(s)) end
    end
    return list
end

-- key of t whose lowercased name matches one of the patterns (in order), and its value
local function findKey(t, patterns, kind)
    for _, p in ipairs(patterns) do
        for k, v in pairs(t) do
            if type(k) == "string" and string.lower(k):find(p) and (not kind or type(v) == kind) then return k, v end
        end
    end
end
DungeonRun.findKey = findKey

-- How many dungeon words a table's keys contain (0 = not about the dungeon).
function DungeonRun.score(t)
    local n = 0
    local ok = pcall(function()
        for k in pairs(t) do
            if type(k) == "string" then
                local l = string.lower(k)
                for _, w in ipairs(DungeonRun.WORDS) do
                    if l:find(w, 1, true) then n = n + 1 break end
                end
            end
        end
    end)
    return ok and n or 0
end

-- A list entry (room / shop item): its type or name, its id and its position.
local function entryOf(e, index)
    if type(e) == "string" then return { label = e, index = index } end
    if type(e) ~= "table" then return nil end
    local _, label = findKey(e, { "^type$", "^room_type$", "^kind$", "^name$", "^item$", "^id$", "type", "name" }, "string")
    local idKey, id = findKey(e, { "^id$", "^uuid$", "^room_id$", "^item_id$", "_id$", "uuid" })
    if type(id) ~= "string" and type(id) ~= "number" then idKey, id = nil, nil end
    local _, price = findKey(e, { "^price$", "^cost$", "price", "cost" }, "number")
    return { label = label, id = id, idKey = idKey, index = index, price = price, raw = e }
end

local function listOf(v)
    local out = {}
    if type(v) ~= "table" then return out end
    local n = #v
    if n > 0 then
        for i = 1, n do
            local e = entryOf(v[i], i)
            if e then table.insert(out, e) end
        end
    else
        for k, x in pairs(v) do
            local e = entryOf(x, nil)
            if e then
                e.key = k
                if not e.id and (type(k) == "string" or type(k) == "number") then e.id, e.idKey = k, "key" end
                table.insert(out, e)
            end
        end
        table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    end
    return out
end

-- The run as the game holds it: the getgc table with a depth and room choices (or a shop).
function DungeonRun.Read()
    local best, bestScore
    -- the table found last time is read again while it still looks like the run
    local last = DungeonRun.runTable
    if last and DungeonRun.score(last) >= 2 then best = last end
    if not best and type(getgc) == "function" then
        pcall(function()
            for _, t in ipairs(getgc(true)) do
                if type(t) == "table" then
                    local s = DungeonRun.score(t)
                    if s >= 2 and (not bestScore or s > bestScore) then
                        local ok, has = pcall(function()
                            return findKey(t, { "depth", "floor" }, "number") ~= nil
                                or findKey(t, { "room", "choice", "option" }, "table") ~= nil
                        end)
                        if ok and has then best, bestScore = t, s end
                    end
                end
            end
        end)
    end
    DungeonRun.runTable = best
    if not best then return nil end
    local st = { table = best }
    pcall(function()
        st.depth = select(2, findKey(best, { "^depth$", "current_depth", "^floor$", "depth", "floor" }, "number"))
        st.maxDepth = select(2, findKey(best, { "max_depth", "total_depth", "max_floor" }, "number"))
        st.hearts = select(2, findKey(best, { "^hearts$", "^lives$", "heart", "lives" }, "number"))
        st.maxHearts = select(2, findKey(best, { "max_heart", "max_lives" }, "number"))
        st.deaths = select(2, findKey(best, { "death", "loss", "fail" }, "number"))
        st.coins = select(2, findKey(best, { "^coins$", "hoard", "coin", "gold" }, "number"))
        st.silverKeys = select(2, findKey(best, { "silver" }, "number"))
        st.goldKeys = select(2, findKey(best, { "gold_key", "golden" }, "number"))
        local _, rooms = findKey(best, { "^rooms$", "room_choices", "choices", "options", "next_rooms", "rooms", "room" }, "table")
        st.rooms = listOf(rooms)
        local _, shop = findKey(best, { "^shop$", "shop_items", "shop" }, "table")
        if type(shop) == "table" then
            local _, items = findKey(shop, { "items", "stock", "offers" }, "table")
            st.shop = listOf(items or shop)
        end
        local _, inv = findKey(best, { "inventory", "blessing", "items", "owned" }, "table")
        st.inventory = inv
        local _, dead = findKey(best, { "dead", "died", "defeated" }, "boolean")
        st.dead = dead
        local _, curse = findKey(best, { "curse" })
        st.curse = curse
    end)
    for _, r in ipairs(st.rooms or {}) do
        local l = string.upper(tostring(r.label or ""))
        for _, t in ipairs(DungeonRun.TYPES) do
            if l:find(t, 1, true) then r.type = t break end
        end
    end
    return st
end

-- Room cards / hearts text on screen, for the status only (never clicked).
function DungeonRun.ScreenText()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local seen, out = {}, {}
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        pcall(function()
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and not isOwnGui(d) and isOnScreen(d) then
                local text = tostring(d.Text):gsub("<[^>]->", "")
                local up = text:upper()
                for _, t in ipairs(DungeonRun.TYPES) do
                    if up:find(t, 1, true) and not seen[t] and #text <= 20 then seen[t] = true table.insert(out, t) end
                end
                if text:match("^%s*%d+%s*/%s*5%s*$") and not seen.hearts then seen.hearts = true table.insert(out, "hearts " .. text) end
            end
        end)
    end
    return out
end

function DungeonRun.StatusText(st)
    local lines = { "Auto: " .. (DungeonRun.enabled and "ON" or "off") .. " | " .. tostring(DungeonRun.status) }
    if st then
        table.insert(lines, string.format("Depth %s%s | hearts %s%s | coins %s | keys silver %s gold %s",
            tostring(st.depth or "?"), st.maxDepth and ("/" .. st.maxDepth) or "/20", tostring(st.hearts or "?"),
            st.maxHearts and ("/" .. st.maxHearts) or "", tostring(st.coins or "?"), tostring(st.silverKeys or "?"), tostring(st.goldKeys or "?")))
        local rooms = {}
        for _, r in ipairs(st.rooms or {}) do
            table.insert(rooms, string.format("%s%s", tostring(r.type or r.label or "?"), r.id ~= nil and ("[" .. tostring(r.id) .. "]") or ("#" .. tostring(r.index))))
        end
        table.insert(lines, "Rooms offered: " .. (#rooms > 0 and table.concat(rooms, ", ") or "none"))
        if st.shop and #st.shop > 0 then
            local items = {}
            for _, it in ipairs(st.shop) do table.insert(items, tostring(it.label or it.id or "?") .. (it.price and (" " .. it.price) or "")) end
            table.insert(lines, "Shop: " .. table.concat(items, ", "))
        end
    else
        table.insert(lines, st == false and "Run data: not read yet (press Refresh dungeon data)"
            or "Run data: not found (not in a dungeon, or its table is unknown)")
    end
    local screen = DungeonRun.ScreenText()
    if #screen > 0 then table.insert(lines, "On screen: " .. table.concat(screen, ", ")) end
    table.insert(lines, "Rooms: " .. table.concat(DungeonRun.priority(), " > ") .. " | shrines " .. (DungeonRun.acceptShrines and "on" or "off")
        .. " | wish-list: " .. (#DungeonRun.wishes() > 0 and table.concat(DungeonRun.wishes(), ", ") or "empty (buys nothing)"))
    return table.concat(lines, "\n")
end

function DungeonRun.Refresh(st)
    if not UIRef.dungeonStatus then return end
    if st == nil then st = DungeonRun.Read() end
    pcall(function() UIRef.dungeonStatus:UpdateBody(DungeonRun.StatusText(st)) end)
end

-- Everything that looks like dungeon data, for the owner to send (clipboard + file).
function DungeonRun.Report()
    local out = { "[moseeri hub · Dungeon report] " .. os.date("%H:%M:%S") .. " stage " .. tostring(State.stage) }
    local remotes = {}
    pcall(function()
        for _, d in ipairs(ReplicatedStorage.endpoints:GetDescendants()) do
            local l = string.lower(d.Name)
            if l:find("dungeon", 1, true) or l:find("room", 1, true) or l:find("shrine", 1, true) or l:find("chest", 1, true) then
                table.insert(remotes, d:GetFullName() .. " (" .. d.ClassName .. ")")
            end
        end
    end)
    table.sort(remotes)
    table.insert(out, "remotes: " .. (#remotes > 0 and table.concat(remotes, ", ") or "none"))
    local st = DungeonRun.Read()
    table.insert(out, "read: " .. DungeonRun.StatusText(st):gsub("\n", " | "))
    local n = 0
    pcall(function()
        for _, t in ipairs(type(getgc) == "function" and getgc(true) or {}) do
            if n >= 15 then break end
            if type(t) == "table" and DungeonRun.score(t) >= 1 then
                n = n + 1
                local ok, body = pcall(Catalog.dump, t, 4000, 3)
                table.insert(out, string.format("== table %d (dungeon words %d)%s ==\n%s", n, DungeonRun.score(t),
                    t == (st and st.table) and " [used as the run]" or "", ok and body or "?"))
            end
        end
    end)
    if n == 0 then table.insert(out, "no getgc table with dungeon keys") end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, g in ipairs(gui and gui:GetChildren() or {}) do
        pcall(function()
            local l = string.lower(g.Name)
            if not isOwnGui(g) and (l:find("dungeon", 1, true) or l:find("room", 1, true) or l:find("shop", 1, true)
                or l:find("shrine", 1, true) or l:find("chest", 1, true) or l:find("hoard", 1, true)) then
                local lines = {}
                Catalog.guiTree(g, 6, lines, "  ")
                table.insert(out, "== screen " .. g:GetFullName() .. " ==\n" .. table.concat(lines, "\n"))
            end
        end)
    end
    local text = table.concat(out, "\n")
    local where = Catalog.save("dungeon_report.txt", text)
    if type(setclipboard) == "function" then pcall(setclipboard, text) end
    notify(string.format("Dungeon report copied (%d KB)%s", math.ceil(#text / 1024), where and where ~= "clipboard" and (", saved to " .. where) or ""))
    return text
end

-- Calls a client_to_server dungeon remote with one argument; true when the run changed.
function DungeonRun.Call(name, arg, before)
    local remote = getAARemote(name)
    if not remote then DungeonRun.status = name .. " remote not found" return false end
    DungeonRun.calls = (DungeonRun.calls or 0) + 1
    local ok, res = pcall(function()
        if remote:IsA("RemoteFunction") then return remote:InvokeServer(arg) end
        remote:FireServer(arg)
        return true
    end)
    local deadline = os.clock() + 5
    while os.clock() < deadline do
        local now = DungeonRun.Read()
        if now and before and DungeonRun.Changed(before, now) then return true, res end
        task.wait(0.25)
    end
    return false, ok and res or "error"
end

function DungeonRun.Changed(a, b)
    if a.depth ~= b.depth or a.coins ~= b.coins or a.hearts ~= b.hearts then return true end
    local function sig(list)
        local parts = {}
        for _, e in ipairs(list or {}) do table.insert(parts, tostring(e.label) .. ":" .. tostring(e.id)) end
        return table.concat(parts, ",")
    end
    return sig(a.rooms) ~= sig(b.rooms) or sig(a.shop) ~= sig(b.shop)
end

-- The room to enter: the first type in the priority list that is offered (shrines only
-- when allowed; a boss room when it is the only way on). nil = nothing fits.
function DungeonRun.PickRoom(rooms)
    local order = DungeonRun.priority()
    table.insert(order, "BOSS")
    for _, want in ipairs(order) do
        if want ~= "SHRINE" or DungeonRun.acceptShrines then
            for _, r in ipairs(rooms or {}) do
                if r.type == want then return r end
            end
        end
    end
end

-- One step of the auto run. Returns seconds to wait.
function DungeonRun.Step()
    local st = DungeonRun.Read()
    if not st or ((not st.rooms or #st.rooms == 0) and not (st.shop and #st.shop > 0) and not st.dead) then
        DungeonRun.status = DungeonRun.WAITING
        DungeonRun.Refresh(st)
        return 2
    end
    if DungeonRun.blocked then
        DungeonRun.status = DungeonRun.blocked
        DungeonRun.Refresh(st)
        return 2
    end
    -- shop: wish-list items only (empty list = buy nothing), never more than the coins
    if st.shop and #st.shop > 0 then
        local wishes = DungeonRun.wishes()
        for _, it in ipairs(st.shop) do
            local name = string.lower(tostring(it.label or it.id or ""))
            local wanted = false
            for _, w in ipairs(wishes) do if name:find(w, 1, true) then wanted = true break end end
            DungeonRun.bought = DungeonRun.bought or {}
            local key = tostring(st.depth) .. ":" .. tostring(it.id or it.index)
            if wanted and not DungeonRun.bought[key] and (not it.price or not st.coins or st.coins >= it.price) then
                DungeonRun.bought[key] = true
                local arg = it.id ~= nil and it.id or it.index
                if arg == nil then break end
                DungeonRun.status = "buying " .. tostring(it.label or arg)
                local changed = DungeonRun.Call("dungeon_buy_shop", arg, st)
                if not changed then
                    DungeonRun.blocked = "dungeon_buy_shop(" .. tostring(arg) .. ") changed nothing - " .. DungeonRun.WAITING
                end
                return 1
            end
        end
    end
    if st.dead then
        if DungeonRun.autoContinueDeath and not DungeonRun.deathTried then
            DungeonRun.deathTried = true
            DungeonRun.status = "lost a room: continuing"
            DungeonRun.Call("dungeon_continue_death", nil, st)
        else
            DungeonRun.status = "lost a room: auto continue after death is off"
        end
        DungeonRun.Refresh(st)
        return 2
    end
    DungeonRun.deathTried = nil
    local room = DungeonRun.PickRoom(st.rooms)
    if not room then
        DungeonRun.status = "no room fits the settings (shrines off?) - pick one yourself"
        DungeonRun.Refresh(st)
        return 2
    end
    local arg = room.id ~= nil and room.id or room.index
    if arg == nil then
        DungeonRun.status = DungeonRun.WAITING
        DungeonRun.Refresh(st)
        return 2
    end
    DungeonRun.status = string.format("entering %s (%s %s)", tostring(room.type), room.id ~= nil and "id" or "position", tostring(arg))
    DungeonRun.Refresh(st)
    local changed = DungeonRun.Call("dungeon_enter_room", arg, st)
    if changed then
        DungeonRun.picks = DungeonRun.picks or {}
        table.insert(DungeonRun.picks, room.type)
        DungeonRun.status = "entered " .. tostring(room.type)
    else
        DungeonRun.blocked = string.format("dungeon_enter_room(%s) changed nothing - %s", tostring(arg), DungeonRun.WAITING)
    end
    DungeonRun.Refresh()
    return 1
end

function DungeonRun.Start()
    DungeonRun.gen = (DungeonRun.gen or 0) + 1
    local gen = DungeonRun.gen
    DungeonRun.enabled, DungeonRun.blocked = true, nil
    task.spawn(function()
        while DungeonRun.enabled and gen == DungeonRun.gen and not State.unloaded do
            local ok, wait = pcall(DungeonRun.Step)
            if not ok then DungeonRun.status = "error: " .. clip(tostring(wait), 80) wait = 3 end
            task.wait(wait or 2)
        end
    end)
end

function DungeonRun.Stop()
    DungeonRun.enabled = false
    DungeonRun.gen = (DungeonRun.gen or 0) + 1
    DungeonRun.status = "Off"
    DungeonRun.Refresh(false)
end
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
    if not UIRef.statsText then return end
    local elapsed = os.clock() - Tools.sessionStartedAt
    UIRef.statsText:UpdateBody(string.format(
        "Session time: %s\nTotal replays: %d\nFailed replays: %d\nTotal actions fired: %d",
        formatDuration(elapsed), Tools.totalReplays, Tools.totalFails, Tools.totalActions
    ))
end

-- Performance options (Settings). They only change what is drawn: no part the placement
-- raycasts hit is moved, destroyed or made non-queryable, and _road / _terrain / _BASES /
-- _UNITS are never touched. Everything is pcall'd; turning an option off restores it.
Tools.perf = { lowGraphics = false, hideEffects = false, noDecor = false, white = false, fpsCap = "Off" }
Tools.perfSaved = { lit = {}, fx = setmetatable({}, { __mode = "k" }), decor = setmetatable({}, { __mode = "k" }) }
Tools.fxClasses = { "ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles" }
function ToolsModule.HideEffect(d)
    local saved = Tools.perfSaved.fx
    pcall(function()
        for _, cls in ipairs(Tools.fxClasses) do
            if d:IsA(cls) then
                if d.Enabled then saved[d] = true; d.Enabled = false end
                return
            end
        end
        if d:IsA("BillboardGui") then
            -- damage numbers: a billboard whose text is just a number ("1,250", "3.4K")
            task.delay(0, function()
                pcall(function()
                    local name = string.lower(d.Name)
                    local numeric = name:find("damage", 1, true) or name:find("dmg", 1, true) or name:find("indicator", 1, true)
                    for _, l in ipairs(d:GetDescendants()) do
                        if l:IsA("TextLabel") and tostring(l.Text):match("^%s*%-?[%d,%.]+[kKmMbB]?%s*$") then numeric = true end
                    end
                    if numeric and d.Enabled and Tools.perf.hideEffects then saved[d] = true; d.Enabled = false end
                end)
            end)
        end
    end)
end
function ToolsModule.SetPerf(key, value)
    local P, S = Tools.perf, Tools.perfSaved
    P[key] = value
    local on = value == true
    if key == "lowGraphics" then
        local lit = S.lit
        pcall(function()
            local rendering = settings().Rendering
            if on then
                if lit.quality == nil then lit.quality = rendering.QualityLevel end
                rendering.QualityLevel = Enum.QualityLevel.Level01
            elseif lit.quality ~= nil then
                rendering.QualityLevel = lit.quality; lit.quality = nil
            end
        end)
        pcall(function()
            local L = game:GetService("Lighting")
            if on then
                if lit.shadows == nil then lit.shadows, lit.fogEnd = L.GlobalShadows, L.FogEnd end
                L.GlobalShadows, L.FogEnd = false, 1e6
                lit.effects = lit.effects or {}
                for _, c in ipairs(L:GetChildren()) do
                    if c:IsA("PostEffect") and c.Enabled then c.Enabled = false; lit.effects[c] = "enabled"
                    elseif c:IsA("Atmosphere") or c:IsA("Sky") or c:IsA("Clouds") then c.Parent = nil; lit.effects[c] = "parent" end
                end
            else
                if lit.shadows ~= nil then L.GlobalShadows, L.FogEnd = lit.shadows, lit.fogEnd; lit.shadows = nil end
                for c, how in pairs(lit.effects or {}) do
                    pcall(function() if how == "enabled" then c.Enabled = true else c.Parent = L end end)
                end
                lit.effects = nil
            end
        end)
    elseif key == "hideEffects" then
        if S.fxConn then pcall(function() S.fxConn:Disconnect() end); S.fxConn = nil end
        if on then
            for _, d in ipairs(workspace:GetDescendants()) do ToolsModule.HideEffect(d) end
            local ok, conn = pcall(function() return workspace.DescendantAdded:Connect(ToolsModule.HideEffect) end)
            if ok then S.fxConn = conn end
        else
            for d in pairs(S.fx) do pcall(function() d.Enabled = true end) end
            S.fx = setmetatable({}, { __mode = "k" })
        end
    elseif key == "noDecor" then
        local map = workspace:FindFirstChild("_map")
        if on and map then
            local KEEP = { _road = true, _terrain = true, _BASES = true, _UNITS = true }
            for _, d in ipairs(map:GetDescendants()) do
                pcall(function()
                    if not d:IsA("BasePart") then return end
                    local node = d
                    while node and node ~= map do
                        local n = string.lower(node.Name)
                        if KEEP[node.Name] or n:find("road", 1, true) or n:find("path", 1, true) or n:find("ground", 1, true)
                            or n:find("floor", 1, true) or n:find("terrain", 1, true) or n:find("base", 1, true) then return end
                        node = node.Parent
                    end
                    if S.decor[d] == nil then S.decor[d] = d.LocalTransparencyModifier end
                    d.LocalTransparencyModifier = 1
                end)
            end
        elseif not on then
            for d, old in pairs(S.decor) do pcall(function() d.LocalTransparencyModifier = old end) end
            S.decor = setmetatable({}, { __mode = "k" })
        end
    elseif key == "white" then
        pcall(function() RunService:Set3dRenderingEnabled(not on) end)
        if S.whiteGui then pcall(function() S.whiteGui:Destroy() end); S.whiteGui = nil end
        if on then
            pcall(function()
                local holder = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
                local g = Instance.new("ScreenGui")
                g.Name = "MoseeriPowerSave"
                g.IgnoreGuiInset, g.DisplayOrder = true, -1
                local l = Instance.new("TextLabel")
                l.Size, l.BackgroundColor3, l.TextColor3 = UDim2.new(1, 0, 1, 0), Color3.fromRGB(245, 245, 245), Color3.fromRGB(60, 60, 60)
                l.TextSize, l.Text = 22, "moseeri hub: 3D off to save power — LeftControl to open menu"
                l.Parent = g
                g.Parent = holder
                S.whiteGui = g
            end)
        end
    elseif key == "fpsCap" then
        local n = tonumber(value)
        if type(setfpscap) == "function" and (n or S.capSet) then
            pcall(setfpscap, n or 0)
            S.capSet = n ~= nil
        end
    end
end
function ToolsModule.PerfOff()
    for _, k in ipairs({ "lowGraphics", "hideEffects", "noDecor", "white" }) do
        if Tools.perf[k] then local keep = Tools.perf[k]; ToolsModule.SetPerf(k, false); Tools.perf[k] = keep end
    end
    if Tools.perf.fpsCap ~= "Off" then local keep = Tools.perf.fpsCap; ToolsModule.SetPerf("fpsCap", "Off"); Tools.perf.fpsCap = keep end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
Window = MacLib:Window({
    Title = "moseeri hub",
    Subtitle = "Anime Adventures auto farm",
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
-- Menu order: Home, Lobby, Dungeon, Event, Macro, Settings (made here, filled below)
UIRef.tabs = {}
for _, t in ipairs({ { "home", "Home" }, { "lobby", "Lobby" }, { "dungeon", "Dungeon" }, { "event", "Event" },
    { "macro", "Macro" }, { "settings", "Settings" } }) do
    UIRef.tabs[t[1]] = tabGroup:Tab({ Name = t[2], Image = "rbxassetid://10734950309" })
end
-- Home: "Play" (left), "More" (right)
UIRef.play = UIRef.tabs.home:Section({ Side = "Left" })
UIRef.more = UIRef.tabs.home:Section({ Side = "Right" })
UIRef.play:Header({ Text = "Play" })
UIRef.more:Header({ Text = "More" })
-- Each tab is built inside its own do-block: Lua 5.1 allows only 200 active locals per
-- function, and the section variables are not needed once a tab is built.
local macroTab, refreshProfileUI

-- TAB 1: Macro (record / play / files)
do
macroTab = UIRef.tabs.macro

local controlSection = macroTab:Section({ Side = "Left" })
local fileSection = macroTab:Section({ Side = "Left" })

controlSection:Header({ Text = "Record & Play" })
UIRef.statusParagraph = controlSection:Paragraph({ Header = "Status", Body = "" })
UIRef.recordToggle = controlSection:Toggle({
    Name = "Record",
    Default = false,
    Callback = function(on)
        if syncing then return end
        if on then
            if not RecordingModule.Start() then setToggle(UIRef.recordToggle, false) end
        else
            RecordingModule.Stop()
        end
    end,
}, "RecordToggle")
UIRef.playToggle = controlSection:Toggle({
    Name = "Play",
    Default = false,
    Callback = function(on)
        if syncing then return end
        if on then
            if not PlaybackModule.Play(false) then setToggle(UIRef.playToggle, false) end
        else
            PlaybackModule.Stop()
        end
    end,
}, "PlayToggle")
Controls.autoPlay = controlSection:Toggle({
    Name = "Wait for wave start",
    Default = State.autoPlay,
    Callback = function(on) State.autoPlay = on; saveConfig() end,
}, "AutoPlay")

UIRef.savedDropdown = controlSection:Dropdown({
    Name = "Saved macros",
    Multi = false,
    Required = false,
    Options = {},
    Callback = function(selected)
        if syncing or type(selected) ~= "string" then return end
        ProfilesModule.Load(selected)
    end,
}, "SavedMacros")
UIRef.nameInput = controlSection:Input({
    Name = "Macro name",
    Placeholder = "auto from stage",
    AcceptedCharacters = "All",
    Callback = function(text)
        if type(text) == "string" then
            State.macroName = text
            refreshStatus()
        end
    end,
}, "MacroName")
controlSection:Button({ Name = "Save", Callback = ProfilesModule.Save })
controlSection:Button({ Name = "Delete", Callback = ProfilesModule.DeleteCurrent })

fileSection:Header({ Text = "Import / export" })
fileSection:Button({ Name = "Export", Callback = ProfilesModule.Export })
fileSection:Button({ Name = "Import folder", Callback = ProfilesModule.ImportFolder })
UIRef.pasteInput = fileSection:Input({
    Name = "Paste JSON",
    Placeholder = "paste here",
    AcceptedCharacters = "All",
    Callback = ProfilesModule.ImportText,
}, "PasteJSON")

end

-- TAB: Home - one AUTO switch for the whole farming set, the mode, and one status line
do
local home = UIRef.play
-- AUTO on: Auto Place + Auto upgrade + buff rotation + unit skills + smart time stop + auto
-- target + sell farms at the end + vote start + skip waves (per mode). The switches as they
-- were before AUTO went on are kept (AutoPlace.homeKeep, saved in config) and come back when
-- AUTO goes off.
local KEEP = { { AutoPlace, "enabled" }, { AutoPlace, "upgrade" }, { AutoPlace, "smartFreeze" }, { AutoPlace, "autoTarget" },
    { AutoPlace, "sellFarmsLast" }, { AutoFarm, "autoStart" }, { AutoFarm, "autoSkip" }, { AutoFarm, "autoReplay" },
    { AutoFarm, "autoNextStage" }, { AutoFarm, "autoLeave" }, { UnitAI, "autoBuff" }, { UnitAI, "autoAbilities" } }
function AutoPlaceModule.HomeAuto(on)
    local mode = AutoPlace.preset == "Safe" and "Safe" or "Fast farm"
    local p = AutoPlaceModule.PRESETS[mode] or {}
    if on then
        if not AutoPlace.homeKeep then
            AutoPlace.homeKeep = {}
            for _, k in ipairs(KEEP) do AutoPlace.homeKeep[k[2]] = k[1][k[2]] == true end
        end
        AutoPlace.upgrade, AutoPlace.smartFreeze, AutoPlace.autoTarget, AutoPlace.sellFarmsLast = true, true, true, true
        AutoFarm.autoStart, AutoFarm.autoSkip = true, p.autoSkip == true
        UnitAI.autoBuff, UnitAI.autoAbilities = true, true
        UnitAIModule.StartBuff()
        UnitAIModule.StartAbilities()
        AutoPlaceModule.SetPlacing(true)
    else
        local keep = AutoPlace.homeKeep
        AutoPlace.homeKeep = nil
        for _, k in ipairs(KEEP) do k[1][k[2]] = keep and keep[k[2]] == true or false end
        if UnitAI.autoBuff then UnitAIModule.StartBuff() else UnitAIModule.StopBuff() end
        if UnitAI.autoAbilities then UnitAIModule.StartAbilities() else UnitAIModule.StopAbilities() end
        AutoPlaceModule.SetPlacing(AutoPlace.enabled)
    end
    -- the switches still on screen show the same state (their callbacks only repeat it)
    local wasReady = configReady
    configReady = false
    for _, cv in ipairs({ { Controls.autoStart, AutoFarm.autoStart }, { Controls.autoSkip, AutoFarm.autoSkip },
        { UIRef.autoReplayToggle, AutoFarm.autoReplay }, { UIRef.autoNextToggle, AutoFarm.autoNextStage },
        { UIRef.autoLeaveToggle, AutoFarm.autoLeave } }) do
        if cv[1] then pcall(function() setToggle(cv[1], cv[2]) end) end
    end
    configReady = wasReady
    pcall(refreshAutoStatus)
    pcall(refreshUnitStatus)
    saveConfig()
    notify(on and ("AUTO on (" .. mode .. ")") or "AUTO off: your own switches are back")
end
Controls.homeAuto = home:Toggle({
    Name = "AUTO",
    Default = false,
    Callback = function(on)
        if syncing or not configReady then return end
        AutoPlaceModule.HomeAuto(on)
    end,
}, "HomeAuto")
-- the player places the units; AUTO still upgrades them, buffs, uses skills, freezes, targets
Controls.placeMyself = home:Toggle({
    Name = "Place units myself",
    Default = AutoPlace.manual == true,
    Callback = function(on)
        AutoPlace.manual = on
        saveConfig(); pcall(AutoPlaceModule.refreshUI)
    end,
}, "PlaceMyself")

-- "Skip these units": team units by name that are never placed (AutoPlace.skip, saved by
-- name so it follows the unit when the team order changes). Old configs kept a 0 per slot:
-- AutoPlaceModule.MigrateSkip turns those into names once the slot's unit is known.
function AutoPlaceModule.TeamNames()
    local names, bySlot = {}, {}
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s] or (AutoPlace.lastTeam or {})[tostring(s)]
        local name = t and t.name and tostring(t.name)
        if name and name ~= "" then
            bySlot[s] = name
            if not table.find(names, name) then table.insert(names, name) end
        end
    end
    return names, bySlot
end
function AutoPlaceModule.MigrateSkip()
    local _, bySlot = AutoPlaceModule.TeamNames()
    local changed = false
    for s = 1, 6 do
        if (tonumber(AutoPlace.slots[s]) or 8) <= 0 and bySlot[s] then
            AutoPlace.skip[bySlot[s]] = true
            AutoPlace.slots[s] = 8
            changed = true
        end
    end
    if changed then saveConfig() end
end
-- how many of slot s (unit t) to place: 0 when skipped, else the slot's number (8 = up to the limit)
function AutoPlaceModule.SlotTarget(s, t)
    if t and AutoPlace.skip[tostring(t.name)] then return 0 end
    return tonumber(AutoPlace.slots[s]) or 8
end
function AutoPlaceModule.refreshSkipUI()
    if not Controls.dontPlace then return end
    local names = AutoPlaceModule.TeamNames()
    local picked = {}
    for _, name in ipairs(names) do
        if AutoPlace.skip[name] then picked[name] = true end
    end
    local _, bySlot = AutoPlaceModule.TeamNames()
    for s, name in pairs(bySlot) do
        if (tonumber(AutoPlace.slots[s]) or 8) <= 0 then picked[name] = true end
    end
    local was = syncing
    syncing = true
    pcall(function()
        local key = table.concat(names, ",")
        if key ~= AutoPlaceModule.skipNames then
            AutoPlaceModule.skipNames = key
            Controls.dontPlace:ClearOptions()
            Controls.dontPlace:InsertOptions(names)
        end
        Controls.dontPlace:UpdateSelection(picked)
    end)
    syncing = was
end
Controls.dontPlace = home:Dropdown({
    Name = "Skip these units",
    Multi = true,
    Required = false,
    Options = (AutoPlaceModule.TeamNames()),
    Default = {},
    Callback = function(value)
        if syncing then return end
        -- MacLib gives { [name] = true }; a plain list of names works too
        local picked = {}
        for k, v in pairs(type(value) == "table" and value or {}) do
            if v == true then picked[tostring(k)] = true elseif type(v) == "string" then picked[v] = true end
        end
        AutoPlace.skip = picked
        -- (a slot left at 0 by an old config is now a name above)
        for s = 1, 6 do if (tonumber(AutoPlace.slots[s]) or 8) <= 0 then AutoPlace.slots[s] = 8 end end
        saveConfig()
    end,
}, "AutoPlaceDontPlace")
Controls.homeMode = home:Dropdown({
    Name = "Mode",
    Multi = false,
    Required = true,
    Options = { "Fast farm", "Safe" },
    Default = AutoPlace.preset == "Safe" and "Safe" or "Fast farm",
    Callback = function(v)
        if syncing or not configReady or type(v) ~= "string" or v == AutoPlace.preset then return end
        AutoPlaceModule.ApplyPreset(v)
    end,
}, "HomeMode")
UIRef.homeStatus = home:Paragraph({ Header = "Now", Body = "Waiting for a game" })
UIRef.autoReplayToggle = home:Toggle({
    Name = "Auto replay",
    Default = AutoFarm.autoReplay,
    Callback = function(on) AutoFarm.autoReplay = on; refreshAutoStatus(); saveConfig() end,
}, "AutoReplay")
UIRef.autoNextToggle = home:Toggle({
    Name = "Auto next stage",
    Default = AutoFarm.autoNextStage,
    Callback = function(on) AutoFarm.autoNextStage = on; refreshAutoStatus(); saveConfig() end,
}, "AutoNext")
UIRef.autoLeaveToggle = home:Toggle({
    Name = "Auto leave on loss",
    Default = AutoFarm.autoLeave,
    Callback = function(on) AutoFarm.autoLeave = on; refreshAutoStatus(); saveConfig() end,
}, "AutoLeave")
Controls.autoStart = home:Toggle({
    Name = "Vote start",
    Default = AutoFarm.autoStart,
    Callback = function(on) AutoFarm.autoStart = on; refreshAutoStatus(); saveConfig() end,
}, "AutoStart")
Controls.autoSkip = home:Toggle({
    Name = "Skip waves",
    Default = AutoFarm.autoSkip,
    Callback = function(on) AutoFarm.autoSkip = on; refreshAutoStatus(); saveConfig() end,
}, "AutoSkip")
function AutoPlaceModule.StageLine()
    local stage = Stage.Pretty()
    if not stage then return "Lobby" end
    local wave = getCurrentWave and getCurrentWave() or 0
    return stage .. (wave and wave > 0 and (" · Wave " .. wave) or "")
end
function AutoPlaceModule.HomeLine()
    local first = (AutoPlaceModule.StatusText and select(2, pcall(AutoPlaceModule.StatusText)) or ""):match("Status: ([^\n]*)")
    local where = AutoPlaceModule.StageLine and AutoPlaceModule.StageLine() or tostring(State.stage or "lobby")
    return where .. " | " .. (first or AutoPlaceModule.status or "Off")
end
AutoPlaceModule.refreshHome = function()
    pcall(function() UIRef.homeStatus:UpdateBody(AutoPlaceModule.HomeLine()) end)
end
end

-- Auto Place: presets (Mode on Home) and Home > More (full status). Auto upgrade, damage
-- unit spots, smart freeze, sell farms at the end and auto target have no switch of their
-- own: AUTO turns them on and Mode picks the spots (Fast farm = Fast clear, Safe = Safe).
do
-- the Auto Place loop on / off (AUTO on Home drives it; "Place units myself" only stops
-- new units from being placed - upgrades, freeze and targeting go on)
function AutoPlaceModule.SetPlacing(on)
    AutoPlace.enabled = on
    if on then AutoPlaceModule.Start() else AutoPlaceModule.Stop() end
    pcall(AutoPlaceModule.refreshUI); saveConfig()
end
-- One click sets every Auto Place / wave option for a way of playing.
local PRESETS = {
    ["Fast farm"] = { placeMode = "Fast clear", upgrade = true, sellFarmsLast = true, smartFreeze = true, autoStart = true, autoSkip = true },
    ["Safe"] = { placeMode = "Safe", upgrade = true, sellFarmsLast = true, smartFreeze = true, autoStart = true, autoSkip = false },
}
AutoPlaceModule.PRESETS = PRESETS
function AutoPlaceModule.ApplyPreset(name)
    local p = PRESETS[name]
    AutoPlace.preset = name
    if p then
        AutoPlace.placeMode, AutoPlace.upgrade = p.placeMode, p.upgrade
        AutoPlace.sellFarmsLast, AutoPlace.smartFreeze = p.sellFarmsLast, p.smartFreeze
        AutoFarm.autoStart, AutoFarm.autoSkip = p.autoStart, p.autoSkip
        for _, cv in ipairs({ { Controls.autoStart, p.autoStart }, { Controls.autoSkip, p.autoSkip } }) do
            if cv[1] then pcall(function() setToggle(cv[1], cv[2]) end) end
        end
        pcall(function() if Controls.homeMode then Controls.homeMode:UpdateSelection(name) end end)
        pcall(refreshAutoStatus)
        notify("Mode " .. name .. ": " .. p.placeMode .. " placement, skip waves " .. (p.autoSkip and "on" or "off"))
    end
    saveConfig()
end
Controls.showDetails = UIRef.more:Toggle({
    Name = "Show full status",
    Default = AutoPlace.showDetails,
    Callback = function(on) AutoPlace.showDetails = on; saveConfig(); pcall(AutoPlaceModule.refreshUI) end,
}, "AutoPlaceDetails")
local placeStatus = UIRef.more:Paragraph({ Header = "Placing", Body = "Off" })
AutoPlaceModule.refreshUI = function()
    pcall(function() placeStatus:UpdateBody(AutoPlaceModule.StatusText()) end)
end
end

-- Home > More: buff troubleshooting (buff rotation and unit skills have no switch of their
-- own: AUTO turns them on; check interval, buff gap, buff length and min units keep their
-- saved / default values)
do
local section = UIRef.more
section:Button({ Name = "Learn buff", Callback = UnitAIModule.StartLearn })
local learnedParagraph = section:Paragraph({ Header = "Learned", Body = "" })
UnitAIModule.refreshLearnedUI = function()
    local kinds = {}
    for kind, e in pairs(UnitAI.learned) do table.insert(kinds, kind .. " (" .. e.name .. ")") end
    table.sort(kinds)
    pcall(function() learnedParagraph:UpdateBody(#kinds > 0 and table.concat(kinds, ", ") or "nothing learned (uses use_active_attack)") end)
end
UnitAIModule.refreshLearnedUI()
section:Button({ Name = "Forget learned buffs", Callback = UnitAIModule.ForgetLearned })
section:Button({ Name = "Copy buff report", Callback = UnitAIModule.BuffReport })
end


-- Stage lists for Auto join from the game's own Worlds data: Story / Infinite (worlds with
-- levels), Legend (legend_stage), Raid (raid_world); the Infinity Mansion has no world.
function Lobby.Worlds(mode)
    local out, seen, rank = {}, {}, {}
    if mode == "Infinity Mansion" then return { "Infinity Mansion" } end
    if mode == "Event" then return { "Current event" } end
    pcall(function()
        -- game order, first choice: the game's own WorldLevelOrder list (world ids, or
        -- tables naming one), position = rank
        local order = require(ReplicatedStorage.src.Data.WorldLevelOrder)
        for i, v in ipairs(type(order) == "table" and order or {}) do
            local id = type(v) == "string" and v or (type(v) == "table" and (v.world or v.id or v[1])) or nil
            if type(id) == "string" and not rank[id] then rank[id] = i end
        end
    end)
    pcall(function()
        -- else each level's story_world_rank (first world = 1)
        if next(rank) then return end
        local levels = require(ReplicatedStorage.src.Data.Levels)
        for _, l in pairs(type(levels) == "table" and levels or {}) do
            local r = type(l) == "table" and tonumber(l.story_world_rank)
            if r and type(l.world) == "string" then rank[l.world] = math.min(rank[l.world] or r, r) end
        end
    end)
    pcall(function()
        local worlds = require(ReplicatedStorage.src.Data.Worlds)
        for id, w in pairs(type(worlds) == "table" and worlds or {}) do
            if type(w) == "table" and type(w.name) == "string" and type(w.levels) == "table" then
                local kind = (w.legend_stage and "Legend") or (w.raid_world and "Raid") or "Story"
                local fits = kind == mode or (mode == "Infinite" and kind == "Story" and w.infinite ~= nil)
                if fits and not seen[w.name] then
                    seen[w.name] = rank[id] or math.huge
                    table.insert(out, w.name)
                elseif fits and rank[id] then
                    seen[w.name] = math.min(seen[w.name], rank[id])
                end
            end
        end
    end)
    table.sort(out, function(a, b)
        if seen[a] ~= seen[b] then return seen[a] < seen[b] end
        return a < b
    end)
    return out
end

-- The level id to lock for a world picked by name: Infinite = the world's infinite id, else
-- the world's own levels in order (act 1 = first). From the game's Worlds and Levels data.
function Lobby.LevelId(mode, worldName, act)
    local found
    pcall(function()
        local worlds = require(ReplicatedStorage.src.Data.Worlds)
        local levels = require(ReplicatedStorage.src.Data.Levels)
        for id, w in pairs(worlds) do
            if type(w) == "table" and w.name == worldName then
                local kind = (w.legend_stage and "Legend") or (w.raid_world and "Raid") or "Story"
                if mode == "Infinite" and kind == "Story" and type(w.infinite) == "table" and w.infinite.id then
                    found = w.infinite.id
                elseif kind == mode then
                    local list = {}
                    for lid, l in pairs(levels) do
                        if type(l) == "table" and l.world == id and not l.infinite then table.insert(list, lid) end
                    end
                    table.sort(list, function(a, b)
                        local ra = tonumber(levels[a].story_level_rank) or tonumber(tostring(a):match("(%d+)$")) or 0
                        local rb = tonumber(levels[b].story_level_rank) or tonumber(tostring(b):match("(%d+)$")) or 0
                        if ra ~= rb then return ra < rb end
                        return tostring(a) < tostring(b)
                    end)
                    found = list[math.min(#list, math.max(1, act))] or found
                end
            end
        end
    end)
    return found
end

-- Lobby rooms ("_lobbytemplategreen1" ...): models named _lobbytemplate* in the lobby.
-- Watched: Story used "_lobbytemplategreen1", Raid "_lobbytemplate213", a portal
-- "_lobbytemplateportal23". kind "raid" = number-only rooms, "portal" = portal rooms,
-- else the green (story) rooms; any other non-portal room only when none of those exist.
function Lobby.Rooms(kind)
    local want, other = {}, {}
    for _, d in ipairs(workspace:GetDescendants()) do
        local n = d:IsA("Model") and d.Name
        if n and n:find("^_lobbytemplate") then
            local rest = n:sub(15)
            local isPortal, isRaid, isGreen = rest:find("^portal") ~= nil, rest:find("^%d+$") ~= nil, rest:find("^green") ~= nil
            local isEvent = rest:find("^_?event") ~= nil -- watched: "_lobbytemplate_event3"
            if (kind == "portal" and isPortal) or (kind == "raid" and isRaid) or (kind == "event" and isEvent)
                or (kind ~= "portal" and kind ~= "raid" and kind ~= "event" and isGreen) then
                table.insert(want, n)
            elseif not isPortal and not isEvent then
                table.insert(other, n)
            end
        end
    end
    table.sort(want)
    table.sort(other)
    if #want == 0 and kind ~= "portal" and kind ~= "event" then return other end
    return want
end

function Lobby.Status(text)
    Lobby.statusText = text
    pcall(function() UIRef.lobbyStatus:UpdateBody(text) end)
end

-- Auto join, as watched in the game: walk into a room, lock the level (room, level id,
-- friends only, difficulty), start. A room that refuses is skipped for the next one.
function Lobby.Join()
    local c = Lobby.cfg
    if c.mode == "Event" then
        -- watched: walking into an event room is all it takes, the room starts by itself. The
        -- join call alone (made from across the lobby) did not start it in the real game, so
        -- the character is moved onto the room's floor, like walking in; the call follows.
        local join = getAARemote("request_join_lobby")
        for _, room in ipairs(Lobby.Rooms("event")) do
            local model
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("Model") and d.Name == room then model = d break end
            end
            local root
            pcall(function() root = Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart") end)
            if model and root then
                pcall(function()
                    local cf, size = model:GetBoundingBox()
                    root.CFrame = CFrame.new(cf.Position - Vector3.new(0, size.Y / 2 - 3, 0))
                end)
                task.wait(1)
            end
            local ok, reply = true, nil
            if join then ok, reply = pcall(function() return join:InvokeServer(room) end) end
            if ok and reply ~= false then Lobby.Status("Auto join: event room " .. room) return true end
        end
        Lobby.Status("Auto join: no event room found")
        return false
    end
    local level = Lobby.LevelId(c.mode, c.world, tonumber(c.act) or 1)
    if not level then Lobby.Status("Auto join: pick a Stage for " .. c.mode) return false end
    local join, lock, start = getAARemote("request_join_lobby"), getAARemote("request_lock_level"), getAARemote("request_start_game")
    if not (join and lock and start) then Lobby.Status("Auto join: the game's join calls were not found") return false end
    for _, room in ipairs(Lobby.Rooms(c.mode == "Raid" and "raid" or "story")) do
        local ok, reply = pcall(function() return join:InvokeServer(room) end)
        if ok and reply ~= false then
            task.wait(0.5)
            pcall(function() lock:InvokeServer(room, level, c.joinFriends == true, c.difficulty) end)
            task.wait(0.5)
            pcall(function() start:InvokeServer(room) end)
            Lobby.Status(string.format("Auto join: starting %s (%s) in %s", level, c.difficulty, room))
            return true
        end
    end
    Lobby.Status("Auto join: no free room")
    return false
end

-- Infinity Mansion: the game starts the player's current room (watched:
-- request_start_infinite_tower(141, "Hard")). The room comes from the stage name of the
-- last tower game ("Infinity Mansion Room 141"): won = the next room, lost = the same.
function Lobby.TowerResult(win)
    local n = tonumber(tostring(State.stage or ""):match("[Ii]nfinity [Mm]ansion[^%d]*(%d+)"))
    if not n then return end
    Lobby.cfg.towerRoom = win and n + 1 or n
    saveConfig()
end
function Lobby.JoinTower()
    local c = Lobby.cfg
    if (c.towerRoom or 0) < 1 then
        Lobby.Status("Infinity Mansion: play one tower room with the script on, so it knows your room")
        return false
    end
    local start = getAARemote("request_start_infinite_tower")
    if not start then return false end
    pcall(function() start:InvokeServer(c.towerRoom, c.difficulty) end)
    Lobby.Status(string.format("Infinity Mansion: starting room %d (%s)", c.towerRoom, c.difficulty))
    return true
end

-- Fool's Hunt with Watch on: every new enemy once (wave, max HP, speed, flying, armor, regen)
-- and, once a wave, our side (units, levels, damage per second from the unit data, base HP) into
-- event_waves.txt - the numbers a fast strategy simulator is tuned on.
function Lobby.RecordWaves()
    Lobby.waveSeen = Lobby.waveSeen or setmetatable({}, { __mode = "k" })
    Lobby.waveLog = Lobby.waveLog or { "# " .. os.date("%Y-%m-%d %H:%M:%S") }
    local wave = AutoPlaceModule.WaveNumber()
    local folder = unitsFolder()
    local function num(st, n) local v = st:FindFirstChild(n) return v and tonumber(v.Value) or (v and tostring(v.Value)) or "-" end
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if not Lobby.waveSeen[u] and AutoPlaceModule.IsEnemy(u) then
            Lobby.waveSeen[u] = true
            local st = u:FindFirstChild("_stats")
            if st then
                table.insert(Lobby.waveLog, string.format("E w%d %s hp %s base_hp %s speed %s base_speed %s fly %s armor %s regen %s barrier %s",
                    wave, (num(st, "id") == "-" and u.Name or tostring(num(st, "id"))), tostring(num(st, "health")), tostring(num(st, "base_health")), tostring(num(st, "speed")),
                    tostring(num(st, "base_speed")), tostring(num(st, "Flying")), tostring(num(st, "Armor")), tostring(num(st, "Regen")), tostring(num(st, "barrier"))))
            end
        end
    end
    if wave ~= Lobby.waveLast then
        Lobby.waveLast = wave
        local parts, dps = {}, 0
        for _, u in ipairs(ownedUnits()) do
            local lvl = AutoPlaceModule.StatNum(u, "upgrade") or 0
            local d = (AutoPlaceModule.StatNum(u, "damage") or 0) / math.max(0.5, AutoPlaceModule.StatNum(u, "attack_cooldown") or AutoPlaceModule.DefCd(AutoPlaceModule.UnitDef(unitType(u) or "")))
            dps = dps + d
            table.insert(parts, string.format("%s:%d", tostring(unitType(u)), lvl))
        end
        local hp, hpMax = AutoPlaceModule.ScanBaseHp()
        table.insert(Lobby.waveLog, string.format("W w%d units %d dps %d base %s/%s candy %s | %s", wave, #parts, math.floor(dps), tostring(hp), tostring(hpMax),
            tostring(Lobby.candy), table.concat(parts, " ")))
    end
    while #Lobby.waveLog > 3000 do table.remove(Lobby.waveLog, 2) end
    AutoPlaceModule.Catalog.save("event_waves_" .. tostring(math.floor(AutoPlaceModule.loadUnix or 0)) .. ".txt", table.concat(Lobby.waveLog, "\n"))
end

-- Every 5 s in the lobby (not while Watch is teaching): join again 20 s after a try.
function Lobby.Loop()
    while not State.unloaded do
        local c = Lobby.cfg
        local cfg = workspace:FindFirstChild("_MAP_CONFIG")
        local flag = cfg and cfg:FindFirstChild("IsLobby")
        local inLobbyNow = flag and flag.Value == true
        local busy = false
        -- order in the lobby: clean the bag, open eggs, then a portal, else Auto join
        -- (nothing while Watch is teaching); in a stage only the cleaner, when allowed
        -- while Watch is on, a live status file for checking a run from outside the game
        if State.watching and not inLobbyNow and os.clock() - (Lobby.lastLive or -1e9) > 15 then
            Lobby.lastLive = os.clock()
            pcall(function()
                local hp, hpMax = AutoPlaceModule.ScanBaseHp()
                local money = readCostValue("LP._stats.resource")
                Lobby.live = Lobby.live or {}
                local slots, live = {}, 0
                for s = 1, 6 do
                    local t = AutoPlaceModule.team[s]
                    if t then table.insert(slots, s .. "=" .. t.name .. ":" .. tostring(t.uuid):sub(2, 5)) end
                end
                for _ in pairs(AutoPlaceModule.liveTemp) do live = live + 1 end
                table.insert(Lobby.live, string.format("%s tick %ss@%s money %s base %s/%s units %d try %s candy %s card %s spells %s live %d team %s | %s", os.date("%H:%M:%S"),
                    tostring(AutoPlaceModule.tickAt and math.floor(os.clock() - AutoPlaceModule.tickAt)), tostring(AutoPlaceModule.tickStep), tostring(money and math.floor(money)), tostring(hp), tostring(hpMax), #ownedUnits(), tostring(AutoPlaceModule.lastTry),
                    tostring(Lobby.candy), tostring(Lobby.cardInfo), table.concat(Lobby.spells or {}, "+"), live, table.concat(slots, ","), (AutoPlaceModule.StatusText():gsub("\n", " | "):gsub("Map fingerprint:[^|]*|", ""))))
                if #Lobby.live > 60 then table.remove(Lobby.live, 1) end
                AutoPlaceModule.Catalog.save("live_status.txt", table.concat(Lobby.live, "\n"))
            end)
        end
        if State.watching and State.eventMode and not inLobbyNow then
            local ok, err = pcall(Lobby.RecordWaves)
            Lobby.recordError = not ok and tostring(err) or nil
        end
        if inLobbyNow and not Lobby.listsFilled and Lobby.RefreshLists and os.clock() - (Lobby.lastRefresh or -1e9) > 30 then
            Lobby.lastRefresh = os.clock()
            pcall(Lobby.RefreshLists, false)
        end
        if not State.watching or c.watchNoPause then
            if c.clean and (inLobbyNow or c.cleanInStage) and os.clock() - (Lobby.lastClean or -1e9) > 30 then
                Lobby.lastClean = os.clock()
                pcall(Lobby.Clean)
            end
            if inLobbyNow and c.openEggs then
                local ok, opened = pcall(Lobby.OpenEggs)
                busy = ok and opened == true
            end
            if inLobbyNow and not busy and os.clock() - (Lobby.lastJoin or -1e9) > 20 then
                local used = false
                if c.usePortals then
                    Lobby.lastJoin = os.clock()
                    local ok, r = pcall(Lobby.UsePortal)
                    used = ok and r == true
                end
                if not used and c.autoJoin then
                    Lobby.lastJoin = os.clock()
                    local ok, joined = pcall(c.mode == "Infinity Mansion" and Lobby.JoinTower or Lobby.Join)
                    -- an event room starts on its own after a countdown: joining again restarts
                    -- it, so the next try waits a minute (+20 s)
                    if ok and joined and c.mode == "Event" then Lobby.lastJoin = os.clock() + 60 end
                end
            end
        end
        task.wait(busy and 2 or 5)
    end
end

-- Fool's Hunt cards (watched in the real game): show_roguelike_options(seconds, { { title,
-- option_type = "Bad" | "Good", effects = { { type, amount, ... }, ... } }, ... }), then
-- show_roguelike_vote_result(picked, { candy_multiplier, persistent_effects }). A "Bad" card
-- makes the enemies stronger and adds 0.3 to the coin multiplier (added up: 0.6 after two);
-- a "Good" card helps us and adds nothing. The vote call (select_roguelike_option) was never
-- seen with its arguments: the ways below are tried in turn; a way whose result matched the
-- pick twice is kept (cfg.voteWay).
-- (a finger tap on the card is what the real game took - taps only)
-- (the game's own call, seen by Watch when the owner voted by hand: select_roguelike_option("3"),
-- the card's number as text; taps on Confirm did not count - real game 2026-10-24)
Lobby.VOTE_WAYS = { "remote" }

-- The button for a text on screen (a card's title, a spell's name): the label's nearest
-- button ancestor, else a button inside the label's card (3 levels up). Clicking it lets the
-- game send its own call, with the right arguments.
function Lobby.ButtonFor(text, root)
    local want = string.lower(tostring(text)):gsub("^%s+", ""):gsub("%s+$", "")
    root = root or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(root and root:GetDescendants() or {}) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isOnScreen(d) and not isOwnGui(d) then
            local plain = string.lower(tostring(d.Text)):gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if plain == want then
                -- the label itself or its closest container that holds a button (the card's
                -- own frame comes before the frame holding all the cards)
                local node = d
                for _ = 1, 6 do
                    if node:IsA("GuiButton") then return node end
                    for _, b in ipairs(node:GetDescendants()) do
                        if b:IsA("GuiButton") and b.Name ~= "Delete" and isOnScreen(b) then return b end
                    end
                    node = node.Parent
                    if not node or node:IsA("LayerCollector") then break end
                end
            end
        end
    end
    return nil
end

-- Share of our damage by type (physical / magic / true ...), from the placed units' data.
function Lobby.DamageShare()
    local share, total = {}, 0
    for _, u in ipairs(ownedUnits()) do
        local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
        local kind = tostring(def._base_damage_type or "physical")
        local dps = (tonumber(def.damage) or 0) / math.max(0.5, AutoPlaceModule.DefCd(def))
        share[kind] = (share[kind] or 0) + dps
        total = total + dps
    end
    if total <= 0 then return { physical = 0.5, magic = 0.5 } end
    for k, v in pairs(share) do share[k] = v / total end
    return share
end

-- How much a card hurts us (0 = nothing): enemy health and speed directly, resistance only
-- for the damage types we deal (true damage ignores it), shields and death bombs a little.
Lobby.AVOID = 10
function Lobby.CardCost(opt, share)
    local cost = 0
    for _, e in ipairs(Lobby.AsList(type(opt.effects) == "table" and opt.effects or {})) do
        local t, a = tostring(e.type), tonumber(e.amount) or 0
        if t == "candy_multiplier" then
            -- (the reward, not a cost)
        -- (owner 2026-10-24: never Enemy Health, Enemy Speed or armor against the damage we deal
        -- while another card is there: AVOID puts them behind every other one)
        elseif t == "enemy_stat_mul" then cost = cost + Lobby.AVOID + a
        elseif t == "enemy_speedup" then cost = cost + Lobby.AVOID + 1.2 * a
        elseif t == "enemy_resistance_specific" then
            local mine = share[tostring(e.damage_type)] or 0
            cost = cost + 1.5 * (a / 100) * mine + (mine >= 0.3 and Lobby.AVOID or 0)
        -- (regen once is fine, more of it stacks up: each one taken costs more)
        elseif t == "enemy_regen" then cost = cost + 100 * a * (1 + (Lobby.regenTaken or 0))
        elseif t == "enemy_shield" then cost = cost + 0.1 * a
        elseif t == "enemy_bomb" then cost = cost + 0.2
        elseif opt.option_type == "Bad" then cost = cost + 0.6
        end
    end
    return cost
end

-- How much a Good card helps: damage first, then range, then attack speed (owner 2026-10-24);
-- Yen (resource_gain) never: the owner cut it - damage and range help more. nil = not taken.
function Lobby.CardGain(opt)
    local gain = 0
    for _, e in ipairs(Lobby.AsList(type(opt.effects) == "table" and opt.effects or {})) do
        local t, stat, a = tostring(e.type), tostring(e.stat), math.abs(tonumber(e.amount) or 0)
        if t == "resource_gain" then return nil
        elseif t == "stat_mul" and stat == "damage" then gain = gain + 1.0 * a
        elseif t == "stat_mul" and stat == "range" then gain = gain + 0.9 * a
        elseif t == "stat_mul" and stat == "attack_cooldown" then gain = gain + 0.8 * a
        else gain = gain + 0.3 * a
        end
    end
    return gain
end

-- The card to pick: "Most coins" takes the Bad card that hurts least (each adds 0.3 to the
-- coin multiplier) unless the base is losing HP or every Bad card is heavy; "Safest" takes a
-- Good card whenever there is one.
Lobby.BAD_CARDS_UNTIL = 6
function Lobby.PickCard(options)
    local share = Lobby.DamageShare()
    local hp, hpMax = AutoPlaceModule.ScanBaseHp()
    local hurt = hp and hpMax and hpMax > 0 and hp / hpMax < 0.8
    local bestBad, bestBadCost, good, goodGain
    for i, o in ipairs(options) do
        if type(o) == "table" then
            if o.option_type == "Good" then
                local g = Lobby.CardGain(o)
                if g and (not good or g > goodGain) then good, goodGain = i, g end
            else
                local c = Lobby.CardCost(o, share)
                if not bestBad or c < bestBadCost then bestBad, bestBadCost = i, c end
            end
        end
    end
    -- (strategy simulator, 2000 games each: Bad cards past wave 6 make the enemies outgrow the team
    -- - Good cards only reached wave 23 on average vs 18, with 22% MORE coins, since coins come
    -- mostly from the waves lived; Bad cards on every offer was the worst play tested, -35% coins)
    local late = State.eventMode and AutoPlaceModule.WaveNumber() >= Lobby.BAD_CARDS_UNTIL
    if good and (Lobby.cfg.cardMode == "Safest" or late or hurt or not bestBad or bestBadCost > 0.8) then return good, "help" end
    return bestBad or 1, "coins"
end

-- (the real game sends the cards keyed "1", "2", "3" - strings, so # sees none)
function Lobby.AsList(t)
    if type(t) ~= "table" or #t > 0 then return t end
    local keys, out = {}, {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(x, y) return (tonumber(x) or math.huge) < (tonumber(y) or math.huge) end)
    for _, k in ipairs(keys) do table.insert(out, t[k]) end
    return out
end

function Lobby.OnCardOptions(seconds, options)
    options = Lobby.AsList(options)
    if not Lobby.cfg.eventCards or type(options) ~= "table" or #options == 0 then
        Lobby.cardInfo = "skipped: " .. (Lobby.cfg.eventCards and "no options" or "cards off")
        return
    end
    local remote = getAARemote("select_roguelike_option")
    local i, why = Lobby.PickCard(options)
    -- (taps only when the game has no vote call)
    local way = remote and "remote" or "gui"
    local arg = tostring(i)
    Lobby.pendingVote = { title = options[i].title, way = way }
    Lobby.cardInfo = string.format("want %s (%s)", tostring(options[i].title), way)
    AutoPlaceModule.Note(string.format("card: %s (%s, way %s)", tostring(options[i].title), why, way))
    task.spawn(pcall, function()
        if way == "gui" then
            -- the card on screen, then its Confirm button (a tapped card only shows Confirm; the
            -- vote counts once Confirm is tapped - real game 2026-10-24)
            local card
            for _ = 1, 15 do
                card = Lobby.ButtonFor(options[i].title)
                if card then break end
                task.wait(0.3)
            end
            if not card then return end
            -- (the card is tapped once only: a second tap may take the choice back; Confirm pops
            -- in with an animation, so it is tapped after it settles and again while it stays -
            -- one quick tap on it did not count in the real game)
            Lobby.TapGui(card)
            local ok
            for _ = 1, 10 do
                task.wait(0.3)
                ok = Lobby.ButtonFor("Confirm")
                if ok then break end
            end
            if not ok then return end
            for n = 1, 4 do
                task.wait(0.6)
                if not (ok.Parent and isOnScreen(ok)) then return end
                Lobby.TapGui(ok)
                Lobby.cardInfo = Lobby.cardInfo:gsub(" confirm %d$", "") .. " confirm " .. n
            end
        else
            -- (sent without waiting: a call the game does not answer must not hold anything up)
            remote:InvokeServer(arg)
        end
    end)
end

function Lobby.OnCardResult(picked, state)
    if type(state) == "table" then Lobby.candy = tonumber(state.candy_multiplier) or Lobby.candy end
    if type(picked) == "table" then
        for _, e in ipairs(Lobby.AsList(type(picked.effects) == "table" and picked.effects or {})) do
            if e.type == "enemy_regen" then Lobby.regenTaken = (Lobby.regenTaken or 0) + 1 end
        end
    end
    local p = Lobby.pendingVote
    Lobby.pendingVote = nil
    Lobby.cardInfo = string.format("%s -> got %s", tostring(Lobby.cardInfo), type(picked) == "table" and tostring(picked.title) or "?")
    if not p or type(picked) ~= "table" or Lobby.cfg.voteWay ~= "" then return end
    if picked.title == p.title then
        Lobby.voteHits = (Lobby.voteHits or 0) + 1
        if Lobby.voteHits >= 2 then
            Lobby.cfg.voteWay = p.way
            saveConfig()
            AutoPlaceModule.Note("card vote way learned: " .. p.way)
        end
    else
        -- (the game picked another card: this way did not count)
        Lobby.voteHits = 0
        Lobby.voteTry = (Lobby.voteTry or 1) % #Lobby.VOTE_WAYS + 1
    end
end

-- Spells in hand (watched: ingame_spells({ "clone" }) every 10 s). Used: Random Buff on the
-- strongest damage unit, Clone on the most upgraded one, Astral Summon when rich; never
-- Refund / Ritual / Merge / Astral Gate. use_ingame_spell's arguments were never seen either:
-- a way counts as working when the spell leaves the hand (cfg.spellWay).
-- (owner: a spell is used by tapping its card, then the unit on the map - taps only)
-- (the game's own call, seen by Watch: use_ingame_spell(<bar slot number>, <unit model>). The
-- owner's hand calls on konan went through; the script's on armin were refused every time, so a
-- unit whose spell stays in hand is skipped from then on)
Lobby.SPELL_WAYS = { "model" }
-- names on the bar (IngameSpells data) and the ones that only take a slot from new units
Lobby.SPELL_NAMES = { clone = "Clone", random_buff = "Random Buff", sacrifice = "Merge", sell_refund = "Refund",
    gate = "Astral Gate", summon = "Astral Summon", ritual = "Ritual" }
Lobby.DROP_SPELLS = {}

-- The bar slot showing a spell (by its name on the card).
function Lobby.SpellSlotBar()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local bar = gui and gui:FindFirstChild("spawn_units")
    bar = bar and bar:FindFirstChild("Lives")
    bar = bar and bar:FindFirstChild("Frame")
    return bar and bar:FindFirstChild("Units")
end

-- The number the game wants for a spell on the bar: its place there, 1-6 (the owner's buffs in
-- places 1, 3, 4 went out as "1", "3", "4"). Spell frames are all named GameSpellFrame, so the
-- name is no use (sent as the key, every call was ignored - real game 2026-10-24): the layout
-- order when it is a place, else the place counted left to right.
function Lobby.SpellKey(frame)
    local order = tonumber(frame.LayoutOrder)
    if order and order >= 1 and order <= 6 then return tostring(order) end
    if tonumber(frame.Name) then return frame.Name end
    local rank, x = 1, frame.AbsolutePosition.X
    for _, o in ipairs(frame.Parent and frame.Parent:GetChildren() or {}) do
        if o ~= frame and o:IsA("GuiObject") and o.Visible and o.AbsolutePosition.X < x - 1 then rank = rank + 1 end
    end
    return tostring(rank)
end

function Lobby.SpellWayOk(way)
    for _, w in ipairs(Lobby.SPELL_WAYS) do if w == way then return true end end
    return false
end

function Lobby.SpellSlot(id)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local bar = gui and gui:FindFirstChild("spawn_units")
    bar = bar and bar:FindFirstChild("Lives")
    bar = bar and bar:FindFirstChild("Frame")
    bar = bar and bar:FindFirstChild("Units")
    local want = string.lower(Lobby.SPELL_NAMES[id] or id):gsub("%s+", "")
    for _, slot in ipairs(bar and bar:GetChildren() or {}) do
        for _, d in ipairs(slot:GetDescendants()) do
            -- (the card writes it over two lines, "Random" / "Buff": compared without spaces)
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.lower(tostring(d.Text)):gsub("<[^>]->", " "):gsub("%s+", "") == want then
                return slot
            end
        end
    end
    return nil
end

-- A real tap on a screen object (its middle). In the real game the card vote did not go
-- through the button's click handlers, but a finger tap on the card did.
function Lobby.TapGui(obj)
    if not obj then return false end
    local ok = pcall(function()
        local inset = game:GetService("GuiService"):GetGuiInset()
        local pos = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
    return ok
end

-- What each spell does (IngameSpells data) and how it is used:
-- random_buff +100% attack or range on a unit (the strongest), clone a copy with the same upgrade
-- level (owner: only once a unit is fully upgraded - then the copy is just as strong), summon / gate instant (Astral Summon: a random equipped unit into
-- the slot; Astral Gate: Astral Summon three times as likely), sacrifice = Merge (all the SAME
-- units in its range go into it, 1.5x their damage, and their places on the map come free),
-- sell_refund = Refund (a full refund: a weak unit is sold from the start, and near the
-- 20-unit limit the weakest makes room), ritual (the unit becomes a Holy Warlord walking the path,
-- as strong as that unit: the strongest goes - owner 2026-10-24 "very good").
Lobby.SPELLS = { random_buff = { cost = 1000, target = "strongest" }, clone = { cost = 5000, target = "maxed" },
    summon = { cost = 10000 }, gate = { cost = 2500 },
    sacrifice = { cost = 1000, target = "merge", dropIfNone = true }, sell_refund = { cost = 0, target = "weakest" },
    ritual = { cost = 10000, target = "strongest" } }
function Lobby.OnSpells(list)
    list = Lobby.AsList(list)
    if type(list) ~= "table" then return end
    local before = Lobby.spellTry
    Lobby.spells = list
    if before and not Lobby.SpellWayOk(Lobby.cfg.spellWay) then
        local n = 0
        for _, s in ipairs(list) do if s == before.id then n = n + 1 end end
        if n >= (before.had or 1) then
            if before.target then
                Lobby.spellBad = Lobby.spellBad or {}
                Lobby.spellBad[before.target] = true
                AutoPlaceModule.Note("spell refused on " .. tostring(before.targetName) .. " - next unit")
            end
            Lobby.spellWayTry = (Lobby.spellWayTry or 1) % #Lobby.SPELL_WAYS + 1
        else
            Lobby.cfg.spellWay = before.way
            if Lobby.spellTries then Lobby.spellTries[before.id] = 0 end
            saveConfig()
            AutoPlaceModule.Note("spell way learned: " .. before.way)
        end
    end
    Lobby.spellTry = nil
end

-- At the unit cap a new random unit cannot be placed: its slot is cleared with its X so the
-- bar rolls again (owner: spells like Random Buff come that way).
function Lobby.RerollStep()
    if not State.eventMode or not Lobby.cfg.eventSpells or os.clock() - (Lobby.rerollAt or -1e9) < 3 then return end
    if #ownedUnits() < math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) then return end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local bar = gui and gui:FindFirstChild("spawn_units")
    bar = bar and bar:FindFirstChild("Lives")
    bar = bar and bar:FindFirstChild("Frame")
    bar = bar and bar:FindFirstChild("Units")
    for _, slot in ipairs(bar and bar:GetChildren() or {}) do
        local view = slot:FindFirstChild("Main") and slot.Main:FindFirstChild("View")
        local world = view and view:FindFirstChildOfClass("WorldModel")
        local x = slot:FindFirstChild("Delete", true)
        if world and world:FindFirstChildOfClass("Model") and x then
            Lobby.rerollAt = os.clock()
            Lobby.TapGui(x)
            AutoPlaceModule.Note("bar full of units at the cap: cleared one for a new roll")
            return
        end
    end
end

-- At its last upgrade level (the unit data's upgrade list).
function Lobby.FullyUpgraded(u)
    local def = AutoPlaceModule.UnitDef(unitType(u) or "")
    local up = def and (def.upgrade or def.upgrades)
    return type(up) == "table" and #up > 0 and (AutoPlaceModule.StatNum(u, "upgrade") or 0) >= #up
end

-- The unit a spell goes on (nil = none fits now). Units refused before are skipped.
function Lobby.SpellTarget(spec)
    local bad = Lobby.spellBad or {}
    local units = ownedUnits()
    local function dpsNow(u)
        local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
        local dmg = AutoPlaceModule.StatNum(u, "damage") or tonumber(def.damage) or 0
        local cd = AutoPlaceModule.StatNum(u, "attack_cooldown") or AutoPlaceModule.DefCd(def)
        return dmg / math.max(0.5, cd) * (AutoPlaceModule.IsAoe(unitType(u)) and AOE_VALUE or 1), (tonumber(def.damage) or 0) > 0
    end
    local target, best
    if spec.target == "merge" then
        -- the damage unit with the most units of its own kind in its range
        for _, u in ipairs(units) do
            local dps, hits = dpsNow(u)
            local p, kind = AutoPlaceModule.RootPos(u), unitType(u)
            local range = AutoPlaceModule.StatNum(u, "range") or tonumber((AutoPlaceModule.UnitDef(kind) or {}).range) or 0
            if hits and p and not bad[u] then
                local n = 0
                for _, o in ipairs(units) do
                    local q = o ~= u and unitType(o) == kind and AutoPlaceModule.RootPos(o)
                    if q and (q - p).Magnitude <= range then n = n + 1 end
                end
                -- (strong kinds first - owner: merging the strong ones saves places and makes them
                -- stronger; then the most of its kind in range)
                local score = (AutoPlaceModule.MaxDps(kind) or 0) * 100 + n * 10 + dps / 1e9
                if n > 0 and (not best or score > best) then target, best = u, score end
            end
        end
    elseif spec.target == "weakest" then
        -- a damage unit under half of the team's middle one (fully upgraded) from the start (owner:
        -- sell the weak ones early), any weakest one near the limit; never a unit that hits flyers,
        -- never a farm, never with under 4 damage units down
        local all = {}
        for _, u in ipairs(units) do
            local v = select(2, dpsNow(u)) and AutoPlaceModule.MaxDps(unitType(u) or "")
            if v then table.insert(all, v) end
        end
        if #all < 4 then return nil end
        table.sort(all)
        local nearLimit = #units >= math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) - 2
        local bar = nearLimit and math.huge or all[math.floor(#all / 2) + 1] * 0.5
        for _, u in ipairs(units) do
            local _, hits = dpsNow(u)
            local full = AutoPlaceModule.MaxDps(unitType(u) or "")
            if hits and full and full < bar and not bad[u] and not AutoPlaceModule.AirCapable(unitType(u) or "", math.huge) and (not best or full < best) then
                target, best = u, full
            end
        end
    else
        for _, u in ipairs(units) do
            if unitType(u) then
                -- damage per second as the unit stands now (its own _stats: level, upgrades, trait,
                -- earlier buffs), area attacks counted higher; Clone takes the most upgraded one
                local dps, hits = dpsNow(u)
                local ok = hits and not bad[u] and (spec.target ~= "maxed" or Lobby.FullyUpgraded(u))
                if ok and (not best or dps > best) then target, best = u, dps end
            end
        end
    end
    return target
end

function Lobby.SpellSaving(money)
    if not Lobby.cfg.eventSpells or not State.eventMode or not money then return nil end
    -- (only once a spell has gone through: saving for one the game ignores held 8k+ unused)
    if not Lobby.SpellWayOk(Lobby.cfg.spellWay) then return nil end
    local dps, maxed = 0, false
    for _, u in ipairs(ownedUnits()) do
        local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
        if (tonumber(def.damage) or 0) > 0 then
            dps = dps + 1
            maxed = maxed or Lobby.FullyUpgraded(u)
        end
    end
    if dps == 0 then return nil end
    for _, id in ipairs(Lobby.spells or {}) do
        -- (not for a spell tried 5 times that stays in hand: the taps are not landing)
        local tried = (Lobby.spellTries or {})[id] or 0
        if id == "random_buff" and money < 1000 and tried < 5 then return "Saving for Random Buff" end
        -- (big spells only once the team is grown: saving for Clone from wave 5 held a team of 5
        -- units for a minute - real game 2026-10-24)
        local grown = #ownedUnits() >= 15
        if id == "clone" and grown and maxed and money < 5000 and tried < 5 then return "Saving for Clone" end
        if id == "ritual" and grown and money < 10000 and tried < 5 then return "Saving for Ritual" end
        -- (owner: Astral Summon is among the best - saved for as soon as it is in hand)
        if id == "summon" and money < 10000 and tried < 5 then return "Saving for Astral Summon" end
    end
    return nil
end

-- Uses a spell in hand on a unit now (Refund for a golden farm). True when it was sent.
function Lobby.CastOn(id, target)
    local remote = getAARemote("use_ingame_spell")
    local slot = Lobby.SpellSlot(id)
    if not (remote and slot) or os.clock() - (Lobby.spellAt or -1e9) < 4 then return false end
    Lobby.spellAt = os.clock()
    local key = Lobby.SpellKey(slot)
    task.spawn(pcall, function() remote:InvokeServer(key, target) end)
    AutoPlaceModule.Note(string.format("spell: %s on %s (making room for a golden copy)", id, unitType(target) or "?"))
    return true
end

function Lobby.SpellStep(money)
    if not Lobby.cfg.eventSpells or not money then return end
    local remote = getAARemote("use_ingame_spell")
    if os.clock() - (Lobby.spellAt or -1e9) < 4 then return end
    if Lobby.SpellCap() then return end
    for _, id in ipairs(Lobby.spells or {}) do
        local spec = Lobby.SPELLS[id]
        -- spells that only take a slot from the next random unit: dropped with their X
        if Lobby.DROP_SPELLS[id] then
            local slot = Lobby.SpellSlot(id)
            local x = slot and slot:FindFirstChild("Delete", true)
            if x then
                Lobby.spellAt = os.clock()
                Lobby.TapGui(x)
                AutoPlaceModule.Note("spell dropped: " .. id)
                return
            end
        end
        local target = spec and spec.target and Lobby.SpellTarget(spec)
        local slot = spec and Lobby.SpellSlot(id)
        if spec and spec.dropIfNone and not target and slot and slot:FindFirstChild("Delete", true) then
            -- (Merge with no two of a kind in range: its bar slot is worth more to a new roll)
            Lobby.spellAt = os.clock()
            Lobby.TapGui(slot:FindFirstChild("Delete", true))
            AutoPlaceModule.Note("spell dropped: " .. id .. " (nothing to use it on)")
            return
        end
        if spec and slot and (target or not spec.target) and money >= spec.cost + (spec.reserve or 0) then
            local way = Lobby.SpellWayOk(Lobby.cfg.spellWay) and Lobby.cfg.spellWay or Lobby.SPELL_WAYS[Lobby.spellWayTry or 1]
            local had = 0
            for _, s in ipairs(Lobby.spells) do if s == id then had = had + 1 end end
            Lobby.spellAt = os.clock()
            Lobby.spellTry = { id = id, way = way, had = had, target = target, targetName = target and unitType(target) }
            Lobby.spellTries = Lobby.spellTries or {}
            Lobby.spellTries[id] = (Lobby.spellTries[id] or 0) + 1
            -- sent without waiting: a call in a shape the game does not take got no answer, and
            -- waiting for it stopped Auto Place for the rest of the game (real game, 2026-10-24)
            -- (taps on the unit missed: the game sent the spell with no target - real game 2026-10-24)
            -- (the game's answer is noted: the same-looking call from the owner's hand went through,
            -- the script's got ignored - real game 2026-10-24)
            if remote then
                task.spawn(pcall, function()
                    local key = Lobby.SpellKey(slot)
                    local a, b = remote:InvokeServer(key, target)
                    AutoPlaceModule.Note(string.format("spell answer %s: %s %s (key %s, order %s, %s)", id, tostring(a), tostring(b),
                        key, tostring(slot.LayoutOrder), target and target:GetFullName() or "no target"))
                end)
            end
            AutoPlaceModule.Note(string.format("spell: %s%s (way %s)", id, target and (" on " .. unitType(target)) or "", way))
            return
        end
    end
end

-- (owner: spells waiting for money or a target must not fill the bar - a bar full of them gets
-- no new units; above the limit the least useful one is cleared. Checked FIRST each time: at the
-- end of the spell step it was never reached while a Refund kept finding someone to try - five
-- Refunds filled the bar in a real game)
function Lobby.SpellCap()
    local held = Lobby.spells or {}
    if #held <= (tonumber(Lobby.cfg.maxSpellsHeld) or 2) then return false end
    local worst, worstP
    for _, id in ipairs(held) do
        local p = Lobby.SPELL_KEEP[id] or 0
        if not worst or p < worstP then worst, worstP = id, p end
    end
    local slot = worst and Lobby.SpellSlot(worst)
    local x = slot and slot:FindFirstChild("Delete", true)
    if not x then return false end
    Lobby.spellAt = os.clock()
    Lobby.TapGui(x)
    AutoPlaceModule.Note("spell dropped: " .. worst .. " (more than " .. tostring(Lobby.cfg.maxSpellsHeld or 2) .. " waiting)")
    return true
end
-- which spell to keep when too many wait (higher = kept)
Lobby.SPELL_KEEP = { summon = 8, ritual = 7, clone = 6, random_buff = 5, sacrifice = 3, sell_refund = 2, gate = 1 }

-- (each connected on its own: one missing event must not leave the others unheard)
for name, fn in pairs({ show_roguelike_options = function(sec, o)
        Lobby.cardInfo = "options seen"
        local ok, err = pcall(Lobby.OnCardOptions, sec, o)
        if not ok then Lobby.cardInfo = "error: " .. clip(tostring(err), 80) end
    end,
    show_roguelike_vote_result = function(p, st) pcall(Lobby.OnCardResult, p, st) end,
    ingame_spells = function(l) pcall(Lobby.OnSpells, l) end }) do
    task.spawn(pcall, function()
        ReplicatedStorage:WaitForChild("endpoints", 5):WaitForChild("server_to_client", 5):WaitForChild(name, 5).OnClientEvent:Connect(fn)
    end)
end

-- Portal and item ids in the bag (pretty names), for the Portals and Bag cleaner lists.
-- The bag as the game keeps it: unique items (portals and others, each with a uuid, the
-- only kind delete_unique_items takes) and normal items by count (eggs are capsule_*).
function Lobby.Bag()
    local bag = { uniques = {}, counts = {} }
    local data = Lobby.inventoryData()
    -- the service's copy may hold no unique items: then the table the game report reads
    -- (found in memory by its unique_items list, portals listed there with uuids)
    local function hasUniques(d) return type(d) == "table" and type(d.unique_items) == "table" and next(d.unique_items) ~= nil end
    if not hasUniques(data) and type(getgc) == "function" then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and hasUniques(v) then data = v break end
            end
        end)
    end
    for k, v in pairs(data and type(data.unique_items) == "table" and data.unique_items or {}) do
        if type(v) == "table" then
            local id, uuid = v.item_id or v.id, v.uuid or (type(k) == "string" and k or nil)
            if type(id) == "string" and type(uuid) == "string" then table.insert(bag.uniques, { id = id, uuid = uuid, data = v }) end
        end
    end
    for k, v in pairs(data and type(data.normal_items) == "table" and data.normal_items or {}) do
        local n = type(v) == "number" and v or (type(v) == "table" and tonumber(v.amount or v.count or v.quantity)) or 0
        local id = type(v) == "table" and (v.item_id or v.id) or k
        if n > 0 then bag.counts[tostring(id)] = (bag.counts[tostring(id)] or 0) + n end
    end
    return bag
end

-- A portal's tier: the first number field named tier anywhere inside its item data.
function Lobby.Tier(item, depth)
    depth = depth or 0
    if type(item) ~= "table" or depth > 4 then return nil end
    if tonumber(item.tier) then return tonumber(item.tier) end
    for _, v in pairs(item) do
        local t = type(v) == "table" and Lobby.Tier(v, depth + 1)
        if t then return t end
    end
    return nil
end

-- Lists for the dropdowns (pretty names): portal kinds, other unique items, eggs.
function Lobby.BagNames()
    local portals, items, eggs, seen = {}, {}, {}, {}
    local bag = Lobby.Bag()
    for _, u in ipairs(bag.uniques) do
        local name = Lobby.prettyName(u.id)
        if not seen[name] then
            seen[name] = true
            table.insert(u.id:find("^portal") and portals or items, name)
        end
    end
    for id in pairs(bag.counts) do
        if id:find("^capsule") then table.insert(eggs, Lobby.prettyName(id)) end
    end
    table.sort(portals) table.sort(items) table.sort(eggs)
    return portals, items, eggs
end

function Lobby.Picked(list, name)
    for _, n in ipairs(list or {}) do if n == name then return true end end
    return false
end

-- Portal challenges from the game's ChallengeAndRewards data: id -> shown name ("double_cost"
-- -> "High Cost", "regen_enemies" -> "Regen Enemies" ...), and the names sorted for the list.
function Lobby.ChallengeNames()
    local byId, names = {}, {}
    pcall(function()
        local data = require(ReplicatedStorage.src.Data.ChallengeAndRewards)
        for id, ch in pairs(type(data) == "table" and type(data.challenges) == "table" and data.challenges or {}) do
            local name = type(ch) == "table" and type(ch.name) == "string" and ch.name or tostring(id)
            byId[tostring(id)] = name
            table.insert(names, name)
        end
    end)
    table.sort(names)
    return byId, names
end

-- The challenges on one portal: any string inside its item data that is a challenge id.
function Lobby.PortalChallenges(item, byId, out, depth)
    out, depth = out or {}, depth or 0
    if type(item) ~= "table" or depth > 5 then return out end
    for k, v in pairs(item) do
        if type(v) == "string" and byId[v] then out[byId[v]] = true end
        if type(k) == "string" and byId[k] and v ~= false then out[byId[k]] = true end
        if type(v) == "table" then Lobby.PortalChallenges(v, byId, out, depth + 1) end
    end
    return out
end

-- Portals: the picked portal kind with the lowest tier at or above "Lowest tier" is used
-- (use_portal(uuid), as watched), then its new portal room is started. Returns true when
-- one was used, false when none is left (Auto join takes over).
function Lobby.UsePortal()
    local c = Lobby.cfg
    if c.portal == "" then return false end
    local best, bestTier
    -- "Challenges to play": only portals carrying one of the picked challenges (none = any)
    local byId = #c.challenges > 0 and Lobby.ChallengeNames() or nil
    for _, u in ipairs(Lobby.Bag().uniques) do
        if u.id:find("^portal") and Lobby.prettyName(u.id) == c.portal then
            local tier = Lobby.Tier(u.data) or 0
            local fits = not byId
            if byId then
                for name in pairs(Lobby.PortalChallenges(u.data, byId)) do
                    if Lobby.Picked(c.challenges, name) then fits = true end
                end
            end
            if fits and tier >= (tonumber(c.portalTier) or 1) and (not best or tier < bestTier) then best, bestTier = u, tier end
        end
    end
    if not best then
        Lobby.Status("Portals: no " .. c.portal .. " at tier " .. c.portalTier .. "+" .. (byId and " with a picked challenge" or "") .. " left - Auto join")
        return false
    end
    local use, start = getAARemote("use_portal"), getAARemote("request_start_game")
    if not (use and start) then return false end
    local before = {}
    for _, r in ipairs(Lobby.Rooms("portal")) do before[r] = true end
    pcall(function() use:InvokeServer(best.uuid) end)
    for _ = 1, 20 do
        for _, r in ipairs(Lobby.Rooms("portal")) do
            if not before[r] then
                task.wait(0.5)
                pcall(function() start:InvokeServer(r) end)
                Lobby.Status(string.format("Portals: started %s (tier %s) in %s", c.portal, tostring(bestTier), r))
                return true
            end
        end
        task.wait(0.25)
    end
    Lobby.Status("Portals: used " .. c.portal .. " but no portal room showed up")
    return true
end

-- Eggs: each picked egg kind is opened while there are any (use_item(id, { use10 }), as
-- watched): 10 at a time when 10 or more are left. Lobby only, one open every 2 s.
function Lobby.OpenEggs()
    local use = getAARemote("use_item")
    if not use then return end
    for id, n in pairs(Lobby.Bag().counts) do
        if id:find("^capsule") and n > 0 and Lobby.Picked(Lobby.cfg.eggs, Lobby.prettyName(id)) then
            pcall(function() use:InvokeServer(id, { use10 = n >= 10 }) end)
            Lobby.Status(string.format("Eggs: opened %s (%d left before)", Lobby.prettyName(id), n))
            return true
        end
    end
    return false
end

-- Bag cleaner: once the bag is over the set share, every unique item whose kind was picked
-- in "Delete portals" / "Delete items" goes in one delete_unique_items({ uuids }) call (as
-- watched). Nothing is picked by default, nothing else is ever deleted.
function Lobby.Clean()
    local c = Lobby.cfg
    if #c.deletePortals == 0 and #c.deleteItems == 0 then return false end
    local frac = Lobby.BagFraction and Lobby.BagFraction()
    if not frac or frac * 100 < c.cleanAt then return false end
    local uuids = {}
    for _, u in ipairs(Lobby.Bag().uniques) do
        local name = Lobby.prettyName(u.id)
        local list = u.id:find("^portal") and c.deletePortals or c.deleteItems
        if Lobby.Picked(list, name) and #uuids < 50 then table.insert(uuids, u.uuid) end
    end
    local del = getAARemote("delete_unique_items")
    if #uuids == 0 or not del then return false end
    pcall(function() del:InvokeServer(uuids) end)
    Lobby.Status(string.format("Bag cleaner: deleted %d picked item(s) (bag was %d%%)", #uuids, math.floor(frac * 100)))
    return true
end

-- Watch: every remote the player fires (lobby buttons, portals, deleting, eggs, rewards) with
-- its full arguments, newest last, saved to AAMacro/lobby_watch.txt for the next build.
Lobby.NOISE = { "mouse", "camera", "heartbeat", "ping", "client_loaded" }
function State.onWatch(remote, method, args)
    local name = string.lower(remote.Name)
    for _, w in ipairs(Lobby.NOISE) do if name:find(w, 1, true) then return end end
    local parts = {}
    for i = 1, args.n or #args do parts[i] = describeValue(args[i], 0, FULL) end
    local line = string.format("%s %s %s(%s)", os.date("%H:%M:%S"), remote:GetFullName(), method, table.concat(parts, ", "))
    table.insert(Lobby.watchLog, line)
    if #Lobby.watchLog > 300 then table.remove(Lobby.watchLog, 1) end
    Lobby.watchDirty = true
end
function Lobby.SetWatch(on)
    if on and not installHook() then return false end
    State.watching = on
    if on then
        -- added to what earlier Watch runs wrote (the script restarts after every teleport)
        local old
        pcall(function() old = readfile(Config.Folder .. "/lobby_watch.txt") end)
        Lobby.watchLog = {}
        if type(old) == "string" and old ~= "" then table.insert(Lobby.watchLog, (old:sub(-20000))) end
        table.insert(Lobby.watchLog, "# lobby_watch " .. os.date("%Y-%m-%d %H:%M:%S") .. " | stage " .. tostring(State.stage or "lobby"))
        -- what the game sends us too (event cards on offer, temporary units, spells): logged
        -- as "<-" lines from plain OnClientEvent connections (nothing hooked, nothing sent)
        Lobby.watchConns = Lobby.watchConns or {}
        pcall(function()
            for _, r in ipairs(ReplicatedStorage.endpoints.server_to_client:GetChildren()) do
                local n = string.lower(r.Name)
                if r:IsA("RemoteEvent") and (n:find("temporary", 1, true) or n:find("roguelike", 1, true)
                    or n:find("spell", 1, true) or n:find("vote", 1, true) or n:find("unit_spawned", 1, true)) then
                    table.insert(Lobby.watchConns, r.OnClientEvent:Connect(function(...)
                        local args = table.pack(...)
                        local parts = {}
                        for i = 1, args.n do parts[i] = describeValue(args[i], 0, FULL) end
                        table.insert(Lobby.watchLog, string.format("%s <- %s(%s)", os.date("%H:%M:%S"), r.Name, table.concat(parts, ", ")))
                        Lobby.watchDirty = true
                    end))
                end
            end
        end)
        task.spawn(function()
            -- written every 2 s (not inside the hook) while Watch is on
            while State.watching and not State.unloaded do
                if Lobby.watchDirty then
                    Lobby.watchDirty = false
                    AutoPlaceModule.Catalog.save("lobby_watch.txt", table.concat(Lobby.watchLog, "\n"))
                end
                task.wait(2)
            end
        end)
    else
        for _, c in ipairs(Lobby.watchConns or {}) do pcall(function() c:Disconnect() end) end
        Lobby.watchConns = {}
    end
    return true
end

-- TAB: Lobby (phase 1: settings + Watch) and Event - planned, waiting for game data
do
local function namesOf(sel)
    -- MacLib multi dropdown gives { [name] = true }; a plain list works too
    local out = {}
    for k, v in pairs(type(sel) == "table" and sel or {}) do
        if v == true then table.insert(out, k) elseif type(v) == "string" then table.insert(out, v) end
    end
    table.sort(out)
    return out
end
local function set(key) return function(v) if syncing then return end Lobby.cfg[key] = v saveConfig() end end
local function setList(key) return function(v) if syncing then return end Lobby.cfg[key] = namesOf(v) saveConfig() end end
local function picked(list) local m = {} for _, n in ipairs(list) do m[n] = true end return m end

local join = UIRef.tabs.lobby:Section({ Side = "Left" })
join:Header({ Text = "Auto join" })
UIRef.lobbyStatus = join:Paragraph({ Header = "Status", Body = "In the lobby: clean bag, open eggs, use a portal, else Auto join. Infinity Mansion learns your room from one tower game. Rewards wait for Watch." })
join:Toggle({ Name = "Auto join", Default = Lobby.cfg.autoJoin, Callback = set("autoJoin") }, "LobbyAutoJoin")
local worldDropdown
join:Dropdown({ Name = "Join mode", Multi = false, Required = true,
    Options = { "Story", "Infinite", "Legend", "Raid", "Infinity Mansion", "Event" }, Default = Lobby.cfg.mode,
    Callback = function(v)
        if syncing or type(v) ~= "string" then return end
        Lobby.cfg.mode = v
        saveConfig()
        pcall(function()
            worldDropdown:ClearOptions()
            worldDropdown:InsertOptions(Lobby.Worlds(v))
        end)
    end }, "LobbyMode")
worldDropdown = join:Dropdown({ Name = "Stage", Multi = false, Required = false,
    Options = Lobby.Worlds(Lobby.cfg.mode), Default = Lobby.cfg.world ~= "" and Lobby.cfg.world or nil,
    Callback = function(v) if syncing or type(v) ~= "string" then return end Lobby.cfg.world = v saveConfig() end }, "LobbyWorld")
join:Dropdown({ Name = "Act", Multi = false, Required = true, Options = { "1", "2", "3", "4", "5", "6" },
    Default = Lobby.cfg.act, Callback = set("act") }, "LobbyAct")
join:Dropdown({ Name = "Difficulty", Multi = false, Required = true, Options = { "Normal", "Hard" },
    Default = Lobby.cfg.difficulty, Callback = set("difficulty") }, "LobbyDifficulty")
join:Toggle({ Name = "Friends only (join)", Default = Lobby.cfg.joinFriends, Callback = set("joinFriends") }, "LobbyJoinFriends")
-- (stays on across teleports until turned off: the script restarts in every stage)
join:Toggle({ Name = "Watch (teach me once)", Default = Lobby.cfg.watch, Callback = function(on)
    local was = State.watching
    if Lobby.cfg.watch ~= on then Lobby.cfg.watch = on saveConfig() end
    if not Lobby.SetWatch(on) then notify("Watch needs hookmetamethod (this executor has none).") return end
    if was and not on then
        AutoPlaceModule.Catalog.save("lobby_watch.txt", table.concat(Lobby.watchLog, "\n"))
        notify(string.format("Watch saved %d calls to AAMacro/lobby_watch.txt", math.max(0, #Lobby.watchLog - 1)))
    end
end }, "LobbyWatch")

local portals, items, eggs = Lobby.BagNames()
local portal = UIRef.tabs.lobby:Section({ Side = "Right" })
portal:Header({ Text = "Portals" })
portal:Toggle({ Name = "Use portals", Default = Lobby.cfg.usePortals, Callback = set("usePortals") }, "LobbyUsePortals")
local portalDropdown = portal:Dropdown({ Name = "Portal", Multi = false, Required = false, Options = portals,
    Default = Lobby.cfg.portal ~= "" and Lobby.cfg.portal or nil,
    Callback = function(v) if syncing or type(v) ~= "string" then return end Lobby.cfg.portal = v saveConfig() end }, "LobbyPortal")
portal:Dropdown({ Name = "Challenges to play", Multi = true, Required = false, Options = select(2, Lobby.ChallengeNames()),
    Default = picked(Lobby.cfg.challenges), Callback = setList("challenges") }, "LobbyChallenges")
portal:Dropdown({ Name = "Lowest tier", Multi = false, Required = true, Options = { "1", "2", "3", "4", "5", "6" },
    Default = Lobby.cfg.portalTier, Callback = set("portalTier") }, "LobbyPortalTier")
portal:Toggle({ Name = "Friends only (portal)", Default = Lobby.cfg.portalFriends, Callback = set("portalFriends") }, "LobbyPortalFriends")

local bag = UIRef.tabs.lobby:Section({ Side = "Right" })
bag:Header({ Text = "Bag cleaner" })
bag:Toggle({ Name = "Clean bag", Default = Lobby.cfg.clean, Callback = set("clean") }, "LobbyClean")
local delPortals = bag:Dropdown({ Name = "Delete portals", Multi = true, Required = false, Options = portals,
    Default = picked(Lobby.cfg.deletePortals), Callback = setList("deletePortals") }, "LobbyDeletePortals")
local delItems = bag:Dropdown({ Name = "Delete items", Multi = true, Required = false, Options = items,
    Default = picked(Lobby.cfg.deleteItems), Callback = setList("deleteItems") }, "LobbyDeleteItems")
bag:Slider({ Name = "When bag is over (%)", Minimum = 50, Maximum = 100, Default = Lobby.cfg.cleanAt,
    Callback = set("cleanAt") }, "LobbyCleanAt")
bag:Toggle({ Name = "Also during stages", Default = Lobby.cfg.cleanInStage, Callback = set("cleanInStage") }, "LobbyCleanInStage")
-- Fills the bag lists again, keeping what was picked (the bag is often not loaded yet when
-- the script starts: the lobby loop calls this every 30 s while the lists are empty).
-- With save, every portal's full data goes to AAMacro/portals.txt (its buffs and tier).
function Lobby.RefreshLists(save)
    local p, i, e = Lobby.BagNames()
    Lobby.listsFilled = #p + #i + #e > 0
    local was = syncing
    syncing = true
    pcall(function()
        for _, d in ipairs({ portalDropdown, delPortals }) do d:ClearOptions() d:InsertOptions(p) end
        delItems:ClearOptions() delItems:InsertOptions(i)
        if UIRef.lobbyEggs then UIRef.lobbyEggs:ClearOptions() UIRef.lobbyEggs:InsertOptions(e) end
        if Lobby.cfg.portal ~= "" then portalDropdown:UpdateSelection(Lobby.cfg.portal) end
        delPortals:UpdateSelection(picked(Lobby.cfg.deletePortals))
        delItems:UpdateSelection(picked(Lobby.cfg.deleteItems))
        if UIRef.lobbyEggs then UIRef.lobbyEggs:UpdateSelection(picked(Lobby.cfg.eggs)) end
    end)
    syncing = was
    if save then
        local lines = { "# portals " .. os.date("%Y-%m-%d %H:%M:%S") }
        for _, u in ipairs(Lobby.Bag().uniques) do
            if u.id:find("^portal") then table.insert(lines, u.id .. " " .. describeValue(u.data, 0, FULL)) end
        end
        AutoPlaceModule.Catalog.save("portals.txt", table.concat(lines, "\n"))
    end
    return p, i, e
end
bag:Button({ Name = "Refresh bag lists", Callback = function()
    local p, i, e = Lobby.RefreshLists(true)
    notify(string.format("Bag: %d portal kinds, %d other items, %d eggs (portals.txt saved)", #p, #i, #e))
end })

local gifts = UIRef.tabs.lobby:Section({ Side = "Left" })
gifts:Header({ Text = "Eggs and rewards" })
gifts:Toggle({ Name = "Open eggs I have", Default = Lobby.cfg.openEggs, Callback = set("openEggs") }, "LobbyOpenEggs")
-- (which bag items are eggs is not in the game data we have: the player picks them)
UIRef.lobbyEggs = gifts:Dropdown({ Name = "Eggs to open", Multi = true, Required = false, Options = eggs,
    Default = picked(Lobby.cfg.eggs), Callback = setList("eggs") }, "LobbyEggs")
gifts:Toggle({ Name = "Claim rewards", Default = Lobby.cfg.claim, Callback = set("claim") }, "LobbyClaim")
gifts:Paragraph({ Header = "Never buys", Body = "Daily, quests, level and battle pass rewards; eggs you already own." })
local event = UIRef.tabs.event:Section({ Side = "Left" })
event:Header({ Text = "Fool's Hunt" })
event:Paragraph({ Header = "How", Body = "Lobby > Join mode: Event joins it. Home AUTO places the random units. The map changes every game." })
event:Toggle({ Name = "Vote cards", Default = Lobby.cfg.eventCards, Callback = set("eventCards") }, "EventCards")
event:Dropdown({ Name = "Card choice", Multi = false, Required = true, Options = { "Most coins", "Safest" },
    Default = Lobby.cfg.cardMode, Callback = set("cardMode") }, "EventCardMode")
event:Toggle({ Name = "Use spells", Default = Lobby.cfg.eventSpells, Callback = set("eventSpells") }, "EventSpells")
event:Toggle({ Name = "Event Auto Place", Default = Lobby.cfg.eventBrain ~= false, Callback = set("eventBrain") }, "EventBrain")
event:Dropdown({ Name = "Always place", Multi = true, Required = false, Options = AutoPlaceModule.ROSTER,
    Default = picked(Lobby.cfg.eventAlways or {}), Callback = setList("eventAlways") }, "EventAlways")
event:Dropdown({ Name = "Never place (X)", Multi = true, Required = false, Options = AutoPlaceModule.ROSTER,
    Default = picked(Lobby.cfg.eventNever or {}), Callback = setList("eventNever") }, "EventNever")
event:Dropdown({ Name = "Spells kept waiting", Multi = false, Required = true, Options = { "1", "2", "3" },
    Default = tostring(Lobby.cfg.maxSpellsHeld or 2), Callback = function(v) if syncing then return end Lobby.cfg.maxSpellsHeld = tonumber(v) or 2 saveConfig() end }, "EventSpellsHeld")
event:Paragraph({ Header = "Event Auto Place", Body = "Its own brain for Fool's Hunt (normal stages keep the usual Auto Place). Always place: placed first, never X'd as weak. Never place: X'd at once so the slot rolls again. The rest: placed when not far below the team. Every X and placement says why in the Home log." })
event:Paragraph({ Header = "Cards", Body = "Most coins: the Bad card that hurts the team least (+0.3 coins each), a Good card when the base is hurt. Safest: Good cards first." })
end

-- TAB: Dungeon (data first; see MODULE: Dungeon Run)
do
local dungeonTab = UIRef.tabs.dungeon
local dataSection = dungeonTab:Section({ Side = "Left" })
local setSection = dungeonTab:Section({ Side = "Right" })

dataSection:Header({ Text = "Dungeon data" })
UIRef.dungeonStatus = dataSection:Paragraph({ Header = "Run", Body = DungeonRun.WAITING })
dataSection:Button({ Name = "Copy dungeon report", Callback = function() pcall(DungeonRun.Report) end })
dataSection:Paragraph({ Header = "", Body = "In a run, on the room choice (and in a shop):\npress Copy dungeon report and send it.\nThe bot acts only on room / item ids it finds\nin the game's data; it never quits a run." })
Controls.dungeonAuto = dataSection:Toggle({
    Name = "Auto dungeon",
    Default = false,
    Callback = function(on)
        if on then DungeonRun.Start() else DungeonRun.Stop() end
    end,
}, "DungeonBot")

setSection:Header({ Text = "Choices" })
Controls.dungeonPriority = setSection:Input({
    Name = "Room priority",
    Placeholder = "HOARD > CHEST > SHOP > BATTLE > SHRINE",
    Default = DungeonRun.roomPriority,
    AcceptedCharacters = "All",
    Callback = function(text) DungeonRun.roomPriority = text or ""; DungeonRun.Refresh(false); saveConfig() end,
}, "DungeonPriority")
Controls.dungeonWish = setSection:Input({
    Name = "Shop wish-list (names, comma separated)",
    Placeholder = "empty = buy nothing",
    Default = DungeonRun.wishList,
    AcceptedCharacters = "All",
    Callback = function(text) DungeonRun.wishList = text or ""; DungeonRun.Refresh(false); saveConfig() end,
}, "DungeonWishList")
Controls.shrineEnabled = setSection:Toggle({
    Name = "Accept shrines (curse for more reward)",
    Default = DungeonRun.acceptShrines,
    Callback = function(on) DungeonRun.acceptShrines = on; DungeonRun.Refresh(false); saveConfig() end,
}, "Shrine")
Controls.dungeonRareEnd = setSection:Toggle({
    Name = "Open rare chests at the end",
    Default = DungeonRun.openRareAtEnd,
    Callback = function(on) DungeonRun.openRareAtEnd = on; saveConfig() end,
}, "DungeonRareAtEnd")
Controls.dungeonContinueDeath = setSection:Toggle({
    Name = "Auto continue after a lost room",
    Default = DungeonRun.autoContinueDeath,
    Callback = function(on) DungeonRun.autoContinueDeath = on; saveConfig() end,
}, "DungeonContinueDeath")
setSection:Paragraph({ Header = "", Body = "Battles are normal games: Auto Place plays\nthem with your team. Chests are not opened\nautomatically yet (their data is unknown)." })
end

-- TAB 5: Settings
do
local settingsTab = UIRef.tabs.settings

local generalSection = settingsTab:Section({ Side = "Left" })
local webhookSection = settingsTab:Section({ Side = "Left" })
local profileSection = settingsTab:Section({ Side = "Left" })
Controls.perfSection = settingsTab:Section({ Side = "Right" })
local toolsSection = settingsTab:Section({ Side = "Right" })

profileSection:Header({ Text = "Profiles" })
local profileNameText = Profile.name
local profileDropdown

-- the active profile is the dropdown's value
refreshProfileUI = function()
    if profileDropdown then
        pcall(function()
            profileDropdown:ClearOptions()
            profileDropdown:InsertOptions(ConfigProfiles.List())
            if Profile.name ~= "" then profileDropdown:UpdateSelection(Profile.name) end
        end)
    end
end

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
Controls.profileName = profileSection:Input({
    Name = "Profile name",
    Placeholder = "e.g. Namak farm",
    Default = Profile.name,
    AcceptedCharacters = "All",
    Callback = function(text) profileNameText = text or "" end,
}, "ProfileName")
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

generalSection:Header({ Text = "General" })
UIRef.antiAfkToggle = generalSection:Toggle({
    Name = "Anti-AFK",
    Default = false,
    Callback = function(on)
        Tools.antiAfk = on
        if on then ToolsModule.StartAntiAfk() else ToolsModule.StopAntiAfk() end
        saveConfig()
    end,
}, "AntiAfk")

webhookSection:Header({ Text = "Discord" })
Controls.webhookUrl = webhookSection:Input({
    Name = "Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default = Webhook.Masked(),
    AcceptedCharacters = "All",
    Callback = function(text) Webhook.SetUrl(text) end,
}, "WebhookUrl")
-- one switch for win / loss reports and the four important pings (flags kept in config)
Controls.discordAlerts = webhookSection:Toggle({
    Name = "Discord alerts",
    Default = Webhook.AlertsOn(),
    Callback = function(on)
        if syncing then return end
        Webhook.SetAlerts(on); saveConfig()
    end,
}, "DiscordAlerts")
webhookSection:Button({
    Name = "Send test",
    Callback = function()
        if Webhook.SendReport("test") then notify("Test report sent to Discord.")
        else notify("Could not send: check the webhook URL (and that this executor has request).") end
    end,
})

-- Performance: all off by default, saved in config (Tools.perf)
Controls.perfSection:Header({ Text = "Performance" })
for _, p in ipairs({ { "lowGraphics", "Low graphics", "PerfLowGraphics" }, { "hideEffects", "Hide effects", "PerfHideEffects" },
    { "noDecor", "Hide map decor", "PerfNoDecor" }, { "white", "White screen", "PerfWhiteScreen" } }) do
    Controls["perf_" .. p[1]] = Controls.perfSection:Toggle({
        Name = p[2],
        Default = false,
        Callback = function(on)
            if on == (Tools.perf[p[1]] == true) then return end
            ToolsModule.SetPerf(p[1], on); saveConfig()
        end,
    }, p[3])
end
Controls.perf_fpsCap = Controls.perfSection:Dropdown({
    Name = "FPS cap",
    Multi = false,
    Required = true,
    Options = { "Off", "60", "30", "15" },
    Default = "Off",
    Callback = function(v)
        if type(v) ~= "string" or v == Tools.perf.fpsCap then return end
        ToolsModule.SetPerf("fpsCap", v); saveConfig()
    end,
}, "PerfFpsCap")
toolsSection:Header({ Text = "Tools" })
toolsSection:Button({ Name = "Copy game report", Callback = AutoPlaceModule.MapReport })
toolsSection:Button({ Name = "Save unit catalog", Callback = function() pcall(AutoPlaceModule.SaveCatalog) end })
toolsSection:Button({ Name = "Copy full log", Callback = RecordingModule.CopyLog })
toolsSection:Button({ Name = "Reset learned data", Callback = function() AutoPlaceModule.ForgetPath(); AutoPlaceModule.refreshUI() end })
end

--------------------------------------------------------------------------------
-- Runtime: game start, stage detect, heartbeat, auto farm wave checks
--------------------------------------------------------------------------------
local function onGameStarted()
    -- the stage can change between games (Next stage, a new room): read it again
    Stage.data = nil
    State.stage = Stage.detect() or State.stage
    pcall(refreshStatus)
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
        if AutoPlaceModule.refreshHome then AutoPlaceModule.refreshHome() end
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
    pcall(ToolsModule.PerfOff)
    configReady = false
    State.unloaded = true
    State.recording = false
    State.finalizing = false
    State.replaying = false
    UnitAI.autoAbilities = false
    UnitAI.autoBuff = false
    Tools.antiAfk = false
    AutoPlace.enabled = false
    DungeonRun.enabled = false
    for _, connection in ipairs(State.connections) do connection:Disconnect() end
    if viewportConnection then viewportConnection:Disconnect() end
    if recordUnitConnection then recordUnitConnection:Disconnect() end
    if replayUnitConnection then replayUnitConnection:Disconnect() end
    AutoFarm.autoReplay, AutoFarm.autoNextStage, AutoFarm.autoLeave = false, false, false
    AutoFarm.autoStart, AutoFarm.autoSkip = false, false
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
    setControl(UIRef.autoReplayToggle, AutoFarm.autoReplay)
    setControl(UIRef.autoNextToggle, AutoFarm.autoNextStage)
    setControl(UIRef.autoLeaveToggle, AutoFarm.autoLeave)
    setControl(Controls.autoStart, AutoFarm.autoStart)
    setControl(Controls.autoSkip, AutoFarm.autoSkip)
    setControl(Controls.abilityCooldown, UnitAI.abilityCooldown)
    setControl(Controls.buffGap, UnitAI.buffGap)
    setControl(Controls.buffDuration, UnitAI.buffDuration)
    setControl(Controls.minUnitsForBuff, UnitAI.minUnitsForBuff)
    setControl(Controls.autoPlay, State.autoPlay)
    setControl(Controls.webhookUrl, Webhook.Masked())
    setControl(Controls.discordAlerts, Webhook.AlertsOn())
    setControl(Controls.shrineEnabled, DungeonRun.acceptShrines)
    setControl(Controls.dungeonRareEnd, DungeonRun.openRareAtEnd)
    setControl(Controls.dungeonContinueDeath, DungeonRun.autoContinueDeath)
    setControl(Controls.dungeonPriority, DungeonRun.roomPriority)
    setControl(Controls.dungeonWish, DungeonRun.wishList)
    setControl(Controls.profileName, Profile.name)

    UnitAI.autoAbilities = pendingToggles.autoAbilities == true
    setControl(UIRef.autoAbilitiesToggle, UnitAI.autoAbilities)
    if UnitAI.autoAbilities then UnitAIModule.StartAbilities() else UnitAIModule.StopAbilities() end
    UnitAI.autoBuff = pendingToggles.autoBuff == true
    setControl(UIRef.autoBuffToggle, UnitAI.autoBuff)
    if UnitAI.autoBuff then UnitAIModule.StartBuff() else UnitAIModule.StopBuff() end
    Tools.antiAfk = pendingToggles.antiAfk == true
    setControl(UIRef.antiAfkToggle, Tools.antiAfk)
    if Tools.antiAfk then ToolsModule.StartAntiAfk() else ToolsModule.StopAntiAfk() end
    local perf = pendingToggles.perf or {}
    for _, k in ipairs({ "lowGraphics", "hideEffects", "noDecor", "white" }) do setControl(Controls["perf_" .. k], perf[k] == true) end
    if perf.fpsCap == "60" or perf.fpsCap == "30" or perf.fpsCap == "15" then
        pcall(function() Controls.perf_fpsCap:UpdateSelection(perf.fpsCap) end)
    end
    setControl(Controls.autoPlaceUpgrade, AutoPlace.upgrade)
    pcall(function() Controls.placeMode:UpdateSelection(AutoPlace.placeMode) end)
    setControl(Controls.smartFreeze, AutoPlace.smartFreeze)
    setControl(Controls.sellFarmsLast, AutoPlace.sellFarmsLast)
    setControl(Controls.autoTarget, AutoPlace.autoTarget)
    setControl(Controls.showDetails, AutoPlace.showDetails)
    pcall(AutoPlaceModule.MigrateSkip)
    pcall(AutoPlaceModule.refreshSkipUI)
    AutoPlace.enabled = pendingToggles.autoPlace == true
    setControl(Controls.placeMyself, AutoPlace.manual == true)
    if AutoPlace.enabled then AutoPlaceModule.Start() else AutoPlaceModule.Stop() end
    setControl(Controls.homeAuto, AutoPlace.enabled)
    pcall(function() Controls.homeMode:UpdateSelection(AutoPlace.preset == "Safe" and "Safe" or "Fast farm") end)

    refreshUnitStatus()
    refreshAutoStatus()
    DungeonRun.Refresh(false)
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
    -- (Watch first: the loop must not act once before it is back on)
    if Lobby.cfg.watch and not State.watching then Lobby.SetWatch(true) end
    task.spawn(Lobby.Loop)
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
DungeonRun.Refresh(false)
ToolsModule.RefreshStats()
UIRef.tabs.home:Select()
notify("moseeri hub loaded — 6 tabs.")
return {
    Recording = RecordingModule,
    Playback = PlaybackModule,
    Profiles = ProfilesModule,
    Scan = Scan,
    Stage = Stage,
    AutoFarm = AutoFarmModule,
    UnitAI = UnitAIModule,
    DungeonRun = DungeonRun,
    Tools = ToolsModule,
}
