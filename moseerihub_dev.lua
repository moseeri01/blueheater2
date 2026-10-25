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
    Keybind = Enum.KeyCode.LeftControl
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
    stopTimes = {},               -- [control skill id] = { dur = s a stop lasts, gap = s enemies stay immune } (measured)
    preset = "Custom",            -- last preset picked ("Safe" / "Balanced" / "Fast"; old saves "Fast farm"); Custom = set by hand
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
    roomPriority = "HOARD>CHEST>SHOP>SHRINE",
    wishList = "",            -- shop items to buy, by name; empty = buy nothing
    acceptShrines = false,
    openRareAtEnd = true,
    autoContinueDeath = false,
    mode = "Fixed",           -- room choice: "Fixed" (Room priority) | "Auto" (scored from dungeon_changed)
    status = "Off",
}

-- Tools state
local Tools = {
    antiAfk = false,
    antiAfkConnection = nil,
    -- spots ON the enemy path are tried too (some units may stand on the road; the game refuses
    -- where it does not allow it and that spot is skipped) - owner 2026-10-24
    onPath = false,
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
        openEggs = false, eggs = {}, claim = false, survey = false, surveyDone = {}, towerRoom = 0, challenges = {}, watch = false,
        watchNoPause = false, eventCards = false, cardMode = "Most coins", voteWay = "", eventSpells = false, spellWay = "",
        -- Fool's Hunt: its own Auto Place brain, the units always placed / never placed (the rest
        -- go by the quality bar), and how many spells may wait in hand. Default lists: the strategy
        -- simulator's damage per map place at full upgrade over the owner's roster (2026-10-24).
        eventBrain = true, maxSpellsHeld = 2, eventListsVer = 3, shareData = true, shareNoticed = false, autoUpdate = true, dailyDoneOn = "",
        eventAlways = { "judar_evolved", "cid_evolved", "bee_girl_evolved", "homura_evolved", "sakamoto_evolved", "nagumo_evolved", "saber_evolved", "frieren_evolved", "monet_evolved", "jiraiya_evolved", "emilia" },
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
            openRareAtEnd = DungeonRun.openRareAtEnd, autoContinueDeath = DungeonRun.autoContinueDeath,
            mode = DungeonRun.mode, enabled = DungeonRun.enabled == true, pendingStart = DungeonRun.pendingStart == true,
            prefs = DungeonRun.prefs, shrineRule = DungeonRun.shrineRule, autoShop = DungeonRun.autoShop ~= false,
            goldChests = DungeonRun.goldChests or "end", itemPrefs = DungeonRun.itemPrefs, picksV2 = DungeonRun.picksV2, lostRooms = DungeonRun.lostRooms, flyMaps = DungeonRun.flyMaps,
            stuckTotal = DungeonRun.stuckTotal, lastStuck = DungeonRun.lastStuck,
            lives = DungeonRun.lives },
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
        tools = { antiAfk = Tools.antiAfk, perf = Tools.perf, onPath = Tools.onPath or nil },
        autoPlace = {
            enabled = AutoPlace.enabled, manual = AutoPlace.manual, skip = next(AutoPlace.skip) and AutoPlace.skip or nil,
            homeKeep = AutoPlace.homeKeep, upgrade = AutoPlace.upgrade, slots = AutoPlace.slots,
            moneyPath = AutoPlace.moneyPath, paths = next(AutoPlace.paths) and AutoPlace.paths or nil,
            caps = next(AutoPlace.caps) and AutoPlace.caps or nil,
            roles = next(AutoPlace.roles) and AutoPlace.roles or nil,
            unitInfo = next(AutoPlace.unitInfo or {}) and AutoPlace.unitInfo or nil,
            stageLosses = next(AutoPlace.stageLosses or {}) and AutoPlace.stageLosses or nil,
            stopTimes = next(AutoPlace.stopTimes or {}) and AutoPlace.stopTimes or nil,
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
    -- (the unit lists kept a saved copy of the FIRST defaults for good - Cream stayed on Always on the
    -- owner's game after it was moved to Never: a saved copy older than the lists in the code is dropped)
    local oldLists = type(data.lobby) == "table" and (tonumber(data.lobby.eventListsVer) or 0) < Lobby.cfg.eventListsVer
    for k, v in pairs(type(data.lobby) == "table" and data.lobby or {}) do
        if oldLists and (k == "eventAlways" or k == "eventNever" or k == "eventListsVer") then v = Lobby.cfg[k] end
        if Lobby.cfg[k] ~= nil and type(v) == type(Lobby.cfg[k]) then Lobby.cfg[k] = v end
        -- (learned dungeon items and pictures have no default: they were saved but never read back, so
        -- every reload - each room is a teleport - showed the generic picture again; 2026-10-26)
        if (k == "dungeonItems" or k == "dungeonItemIcons" or k == "dungeonIcons4" or k == "dungeonNameIcons") and type(v) == "table" then Lobby.cfg[k] = v end
        if k == "dungeonModuleScan" and type(v) == "number" then Lobby.cfg[k] = v end
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
    if DungeonRun.roomPriority == "HOARD > CHEST > SHOP > BATTLE > SHRINE" then DungeonRun.roomPriority = "HOARD>CHEST>SHOP>SHRINE" end
    DungeonRun.wishList = pick(d.wishList, "string", DungeonRun.wishList)
    DungeonRun.acceptShrines = pick(d.shrineEnabled, "boolean", DungeonRun.acceptShrines)
    DungeonRun.openRareAtEnd = pick(d.openRareAtEnd, "boolean", DungeonRun.openRareAtEnd)
    DungeonRun.autoContinueDeath = pick(d.autoContinueDeath, "boolean", DungeonRun.autoContinueDeath)
    DungeonRun.mode = d.mode == "Auto" and "Auto" or "Fixed"
    DungeonRun.pendingStart = d.pendingStart == true
    DungeonRun.lives = tonumber(d.lives)
    -- (Setup window: room prefs and the shrine rule; an old config keeps its typed priority)
    DungeonRun.prefs = type(d.prefs) == "table" and d.prefs or nil
    if DungeonRun.prefs and DungeonRun.ApplyPrefs then DungeonRun.ApplyPrefs() end
    DungeonRun.shrineRule = (d.shrineRule == "never" or d.shrineRule == "lives3" or d.shrineRule == "always") and d.shrineRule or nil
    DungeonRun.autoShop = d.autoShop ~= false
    DungeonRun.goldChests = d.goldChests == "now" and "now" or "end"
    DungeonRun.itemPrefs = type(d.itemPrefs) == "table" and d.itemPrefs or {}
    DungeonRun.picksV2 = d.picksV2 == true or nil
    DungeonRun.legacyPicks = not DungeonRun.picksV2 and next(DungeonRun.itemPrefs) ~= nil or nil
    DungeonRun.lostRooms = type(d.lostRooms) == "table" and d.lostRooms or {}
    DungeonRun.flyMaps = type(d.flyMaps) == "table" and d.flyMaps or {}
    DungeonRun.stuckTotal, DungeonRun.lastStuck = tonumber(d.stuckTotal), type(d.lastStuck) == "string" and d.lastStuck or nil
    -- (every room is a teleport and the script reloads there: Auto dungeon has to come back on)
    pendingToggles.dungeon = d.enabled == true
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
    Tools.onPath = t.onPath == true
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
    if type(ap.stopTimes) == "table" then
        AutoPlace.stopTimes = {}
        for k, v in pairs(ap.stopTimes) do
            if type(k) == "string" and type(v) == "table" then
                AutoPlace.stopTimes[k] = { dur = tonumber(v.dur), gap = tonumber(v.gap) }
            end
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
            if gen ~= playGen then return end
            local stats = unit:FindFirstChild("_stats")
            local base = stats and stats:FindFirstChild("base")
            if base and tostring(base.Value) == "pve" then return end -- an enemy
            table.insert(replayNewUnits, { unit = unit, at = os.clock() })
            if #replayNewUnits > 50 then table.remove(replayNewUnits, 1) end
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
AutoFarmModule.ResultsShowing, AutoFarmModule.ResultIsVictory = isResultsShowing, resultIsVictory

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
    -- (a Dungeon Room result only has Next, tapped by Lobby.Loop: Replay / Leave would leave the run)
    if DungeonRun.InRoom() then return nil end
    local victory = resultIsVictory()
    if AutoFarm.autoNextStage and victory then return "next_story", Words.NEXT_STAGE end
    if AutoFarm.autoReplay then return "replay", Words.REPLAY end
    if AutoFarm.autoLeave and not victory then return "leave", Words.LEAVE end
    return nil
end

-- "There is a pending teleport, please wait." on screen: the game is already moving us on
function AutoFarmModule.TeleportPending()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.lower(tostring(d.Text)):find("pending teleport", 1, true) and isOnScreen(d) then return true end
    end
    return false
end

function AutoFarmModule.OnGameEnd()
    if endHandling or State.recording or State.finalizing then return end
    -- (a friend's Infinity Mansion: Next Room pressed again every 20 s while the teleport was
    -- pending, and each press only brought the message back - wait for the game instead; still
    -- there after 2 minutes with Auto join on: back to the lobby, Auto join starts the next room)
    if AutoFarmModule.TeleportPending() then
        AutoFarmModule.pendingSince = AutoFarmModule.pendingSince or os.clock()
        if os.clock() - AutoFarmModule.pendingSince > 120 and Lobby.cfg.autoJoin then
            AutoFarmModule.pendingSince = nil
            local back = findScreenButton(Words.LEAVE)
            if back then clickButton(back) notify("Teleport stuck for 2 minutes: back to the lobby, Auto join goes on") end
        end
        return
    end
    AutoFarmModule.pendingSince = nil
    local goal, words = endGoal()
    if not goal then return end
    endHandling = true
    notify("Match ended: auto " .. goal .. "...")
    task.wait(1.5)
    -- (the Discord report goes out first: a quick Replay teleported away before it was sent)
    local reportBy = os.clock() + 8
    while Webhook.reportPending and os.clock() < reportBy do task.wait(0.2) end

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
        notify("Auto " .. tostring(goal) .. ": could not find the button. Settings > Tools > Copy full log on the result screen and send it.")
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
DungeonRun.InLobby = inLobby

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
            -- (Fool's Hunt too since 2026-10-24: owner - skipping brings the money sooner and saves time)
            if AutoFarm.autoSkip and gameStarted() and now >= nextSkip then
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
    -- (perf: read 10+ times a tick - kept 0.1 s while the folder holds as many children; a copy goes out)
    local kids = folder:GetChildren()
    local memo, list = State.ownedMemo, nil
    if memo and memo.folder == folder and memo.n == #kids and os.clock() - memo.at < 0.1 then
        list = memo.list
    else
        local mine, all, anyOwnerField = {}, {}, false
        for _, unit in ipairs(kids) do
            local stats = unit:FindFirstChild("_stats")
            local base = stats and stats:FindFirstChild("base")
            if not (base and tostring(base.Value) == "pve") and not isSummon(unit) then table.insert(all, unit) end
            if stats and stats:FindFirstChild("player") then anyOwnerField = true end
            if isMyUnit(unit) and not isSummon(unit) then table.insert(mine, unit) end
        end
        list = (#mine == 0 and not anyOwnerField) and all or mine
        State.ownedMemo = { folder = folder, n = #kids, at = os.clock(), list = list }
    end
    local copy = {}
    for i, u in ipairs(list) do copy[i] = u end
    return copy
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
            -- (0.25 s only while a buff rotation is known: each pass reads every unit's stats)
            task.wait(next(BuffRot.groups) and 0.25 or 1)
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
AutoPlaceModule.badParts = setmetatable({}, { __mode = "k" }) -- parts a raised spot was refused on (bestSpot: tried last)
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

-- A hard stage (normal modes only): Hard / Nightmare difficulty, a challenge (Daily Challenge was
-- lost at wave 3 with 4 farms and one damage unit down), or a stage lost here lately.
-- Auto Place v2 knobs (work/placement_method.md; the functions follow placedOf below)
local PV = {}
AutoPlaceModule.V2 = PV
PV.SHORT_ROAD, PV.LONG_ROAD = 250, 350 -- road kinds by the road length (studs): short < 250 <= middle <= 350 < long
PV.ROAD_STEP = 2.5                     -- lane road point spacing (studs)
PV.CARRY_LEVEL = 4                     -- short / middle maps: the carry's upgrades to this level come in the order
PV.NEAR_BEST = 0.9                     -- other damage units stand by the carry when that spot is within 10% of the best
PV.MARGIN_HIGH, PV.MARGIN_LOW = 1.5, 1.2 -- spending: margin >= high = farms, < low = damage upgrades first
PV.ENEMY_SPEED = 6                     -- enemy walk speed (studs / s) until measured
PV.CONE_HALF = math.rad(45)            -- cone attacks: this far either side of the heading
PV.LINE_HALF = 2.5                     -- line attacks: this wide either side
PV.REC_TYPE = 1.25                     -- the level's _recommended_damage_types deal this much more
PV.SLOW_GAIN = 1.3                     -- enemies stay this much longer where a slow unit reaches the same road
PV.MIN_NORMAL = 0.85                   -- a spot's ground must be flatter than this (surface normal Y): no cliff sides
PV.REFUSED_GONE = 3                    -- a refused spot and this far around it: never tried again this game
PV.PLACE_REACH = 30                    -- hill-placement spots at most this far from the road
PV.SUMMON_COVER = 0.5                  -- a summoner's summons work along this share of the road (margin)
-- Fool's Hunt on the v2 spot rules (AutoPlace.v2Event = true; off by default - owner 2026-10-26, on hold): the road, cov / best, the carry /
-- damage / slow / summoner / buff spots; Merge keeps its rule (a copy next to its own kind first). What to buy
-- stays the event brain's (EventChoose).
function PV.EventOn() return AutoPlace.v2Event == true end
-- The map's hill-placement parts (Hill4_Placement ...): parts under _terrain / _map with "placement" in
-- their own or a parent's name (4 levels); read again every 10 s.
function PV.PlacementParts()
    local key = AutoPlaceModule.StageKey and AutoPlaceModule.StageKey() or ""
    if PV.placeFor == key and os.clock() - (PV.placeAt or -1e9) < 10 then return PV.placeParts end
    local out = {}
    pcall(function()
        for _, root in ipairs({ workspace:FindFirstChild("_terrain"), workspace:FindFirstChild("_map") }) do
            for _, d in ipairs(root and root:GetDescendants() or {}) do
                if #out >= 200 then break end
                if d:IsA("BasePart") then
                    local node, n = d, 0
                    while node and node ~= root and n < 4 do
                        if string.lower(node.Name):find("placement", 1, true) then out[#out + 1] = d break end
                        node, n = node.Parent, n + 1
                    end
                end
            end
        end
    end)
    PV.placeFor, PV.placeAt, PV.placeParts = key, os.clock(), out
    return out
end
function AutoPlaceModule.Hard()
    if State.eventMode then return false end
    local d = string.lower(tostring(Stage.difficulty or ""))
    local where = string.lower(tostring(Stage.mode or "") .. " " .. tostring(State.stage or ""))
    return (d ~= "" and d ~= "normal") or where:find("challenge", 1, true) ~= nil
        or where:find("daily", 1, true) ~= nil or AutoPlaceModule.Losses() > 0
end

-- The learned path does not reach our base yet (a stage played for the first time, or enemies held /
-- killed near the spawn): no road point within a quarter of the spawn-to-base distance (12 studs at
-- least) of our base.
AutoPlaceModule.HOLD_PATH = 12 -- seconds the 2nd damage unit waits for that at most (tick; 45 left 12.5k unspent at wave 5 - candy map 2026-10-25)
AutoPlaceModule.holdAt = {}    -- [stageKey] = when that wait began

-- Enemy spawn and our base, checked against the road (normal stages): _BASES.pve / _BASES.player
-- as a rule, but swapped when the first recorded road points (where the enemies first showed up)
-- lie clearly nearer _BASES.player - every "toward our base" score would point at the entrance
-- (owner 2026-10-25: units went to the front). Returns spawn, base, swapped.
-- The two ends of the game's lane road (normal stages): its first bend (enemy end) and last (our base),
-- cached per stage, read again every 2 s while missing. On Mountain Temple / Puppet Island / Sacred
-- Planet _BASES.player stands 130-260 studs from the road's end, so "toward our base" means toward
-- the lane end where there is one (24 real scans, 2026-10-25).
AutoPlaceModule.laneEnds = {}
function AutoPlaceModule.LaneEnds()
    local key = stageKey()
    local c = AutoPlaceModule.laneEnds[key]
    if c and (c.s or os.clock() - c.at < 2) then return c.s, c.g end
    local goal = AutoPlaceModule.BasePos("player")
    local g = goal and { x = goal.X, z = goal.Z } or { x = 0, z = 0 }
    local lanes = AutoPlaceModule.Lanes()
    local useSide = "player"
    for _, lane in ipairs(lanes) do if lane.side == "pve" and #lane.bends >= 2 then useSide = "pve" end end
    local s, e
    for _, lane in ipairs(lanes) do
        -- (only the game's numbered lanes - every real scan has them; anything else is no proof of the ends)
        local numbered = 0
        for _, b in ipairs(lane.bends) do if tonumber(b.name) then numbered = numbered + 1 end end
        if not s and lane.side == useSide and numbered >= 2 then
            local chain = AutoPlaceModule.LaneOrder(lane.bends, g, lane.side)
            s = { X = chain[1].x, Y = chain[1].y, Z = chain[1].z }
            e = { X = chain[#chain].x, Y = chain[#chain].y, Z = chain[#chain].z }
        end
    end
    AutoPlaceModule.laneEnds[key] = { s = s, g = e, at = os.clock() }
    return s, e
end

function AutoPlaceModule.Ends()
    local spawn, goal = AutoPlaceModule.BasePos("pve"), AutoPlaceModule.BasePos("player")
    if State.eventMode then return spawn, goal, false end
    local ls, lg = AutoPlaceModule.LaneEnds()
    if ls and lg then return ls, lg, false end
    local pts = AutoPlaceModule.PathPoints()
    -- (no _BASES.pve on a map - Ant Kingdom Dungeon Room: the first recorded road point is where the
    -- enemies came in)
    if not spawn and goal and #pts >= 8 then return { X = pts[1][1], Y = pts[1][2], Z = pts[1][3] }, goal, false end
    if not (spawn and goal) or #pts < 8 then return spawn, goal, false end
    local ds, dg = 0, 0
    for i = 1, 5 do
        ds = ds + math.sqrt((pts[i][1] - spawn.X) ^ 2 + (pts[i][3] - spawn.Z) ^ 2)
        dg = dg + math.sqrt((pts[i][1] - goal.X) ^ 2 + (pts[i][3] - goal.Z) ^ 2)
    end
    if dg < 0.5 * ds then
        if AutoPlaceModule.endsNoted ~= stageKey() then
            AutoPlaceModule.endsNoted = stageKey()
            AutoPlaceModule.Note("enemies enter at _BASES.player on this map: base sides swapped")
        end
        return goal, spawn, true
    end
    return spawn, goal, false
end

function AutoPlaceModule.PathShort()
    local spawn, goal = AutoPlaceModule.Ends()
    if not (spawn and goal) then return false end
    local reach = math.max(12, 0.25 * math.sqrt((spawn.X - goal.X) ^ 2 + (spawn.Z - goal.Z) ^ 2))
    for _, q in ipairs(AutoPlaceModule.PathPoints()) do
        if (q[1] - goal.X) ^ 2 + (q[3] - goal.Z) ^ 2 <= reach * reach then return false end
    end
    return true
end

-- Placement mode in use: the chosen one, but Balanced turns Safe on a hard stage.
function AutoPlaceModule.Mode()
    if AutoPlace.placeMode == "Balanced" and AutoPlaceModule.Hard() then return "Safe" end
    return AutoPlace.placeMode
end

-- Called once per finished game.
function AutoPlaceModule.OnResult(win)
    -- (a played stage is not new any more: no new-stage hold in the next game on it)
    AutoPlaceModule.freshStage = {}
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

-- Another stage on the same map (same fingerprint) learned its path already: Strange Town Raid,
-- Infinity Mansion and the Daily Challenge share one road, but each stage name started from 4
-- points and the first units went down on that (owner 2026-10-25). The longest such path that runs
-- from this map's enemy base is copied; learning goes on from it.
function AutoPlaceModule.SameMapPath(key)
    local fp = tostring(key):match("#(%w+)$")
    if not fp then return nil end
    local spawn = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("pve")
    -- a complete one (reaching our base) first, then the longest; with no _BASES.pve (Dungeon rooms)
    -- only a complete one - nothing else shows it is this map's road
    local best, bestDone
    for k, p in pairs(AutoPlace.paths) do
        if k ~= key and type(p) == "table" and #p >= 30 and string.sub(k, -(#fp + 1)) == "#" .. fp then
            local fits = spawn == nil
            if spawn then
                for _, q in ipairs(p) do
                    if type(q) == "table" and tonumber(q[1]) and tonumber(q[3])
                        and (q[1] - spawn.X) ^ 2 + (q[3] - spawn.Z) ^ 2 < 225 then fits = true break end
                end
            end
            local done = AutoPlaceModule.Reaches(p)
            if fits and (done or spawn) and (not best or (done and not bestDone) or (done == bestDone and #p > #best)) then
                best, bestDone = p, done
            end
        end
    end
    if not best then return nil end
    local copy = {}
    for i, q in ipairs(best) do copy[i] = { q[1], q[2], q[3] } end
    AutoPlaceModule.Note(string.format("same map played before: its enemy path (%d points%s) is used here", #copy, bestDone and ", complete" or ""))
    return copy, bestDone
end
AutoPlaceModule.sameMapAt = {}
AutoPlaceModule.sameMapDone = {}
AutoPlaceModule.freshStage = {}
AutoPlaceModule.laneClean = {}

-- The game's own road data: _BASES.pve.LANES / _BASES.player.LANES .<lane>.<bend> (MapFingerprint reads
-- player LANES on maps with no _BASES.pve). Real dump (Planet Greenie, 2026-10-25): bends "1".."10" plus
-- "final" by the enemy entrance and "spawn" by our base - "10" next to the entrance, "1" next to our base
-- (player LANES run base -> entrance: summons walk the road backwards). Raw bends go into the dump.
function AutoPlaceModule.Lanes()
    local bases = workspace:FindFirstChild("_BASES")
    local out = {}
    for _, side in ipairs({ "pve", "player" }) do
        local sb = bases and bases:FindFirstChild(side)
        local lanes = sb and sb:FindFirstChild("LANES")
        for _, lane in ipairs(lanes and lanes:GetChildren() or {}) do
            local bends = {}
            for _, b in ipairs(lane:GetChildren()) do
                local ok, p = pcall(function() return b:IsA("BasePart") and b.Position or b:GetPivot().Position end)
                if ok and p then bends[#bends + 1] = { name = b.Name, x = p.X, y = p.Y, z = p.Z } end
            end
            if #bends > 0 then out[#out + 1] = { name = lane.Name, side = side, bends = bends } end
        end
    end
    return out
end
-- One lane's bends in walking order, entrance first (24 real scans, 2026-10-25): player LANES run "final"
-- (enemy end) -> numbered bends high to low -> "spawn" (our base), pve LANES the other way round (PV.LaneOrder).
-- No bend name a number: chained from the bend farthest from our base, nearest bend next.
function AutoPlaceModule.LaneOrder(bends, g, side)
    local fixed = PV.LaneOrder(bends, side)
    if fixed then return fixed end
    local function d2(a, b) return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 end
    local chain = {}
    local start, sd = 1, -1
    for i, p in ipairs(bends) do if d2(p, g) > sd then start, sd = i, d2(p, g) end end
    local used = { [start] = true }
    chain[1] = bends[start]
    while #chain < #bends do
        local last, bi, bd = chain[#chain], nil, nil
        for i, p in ipairs(bends) do
            if not used[i] and (not bd or d2(last, p) < bd) then bi, bd = i, d2(last, p) end
        end
        used[bi] = true
        chain[#chain + 1] = bends[bi]
    end
    return chain
end
function AutoPlaceModule.LanePath()
    local goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
    if not goal then return nil end
    local g = { x = goal.X, z = goal.Z }
    local lanes = AutoPlaceModule.Lanes()
    -- (the enemies' own lanes first when the map has them)
    local useSide = "player"
    for _, lane in ipairs(lanes) do if lane.side == "pve" and #lane.bends >= 2 then useSide = "pve" end end
    local out = {}
    for _, lane in ipairs(lanes) do
        if lane.side == useSide and #lane.bends >= 2 then
            local chain = AutoPlaceModule.LaneOrder(lane.bends, g, lane.side)
            for i = 1, #chain - 1 do
                local a, b = chain[i], chain[i + 1]
                local len = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
                for s = 0, len - 0.01, 2.5 do
                    local t = s / math.max(0.01, len)
                    out[#out + 1] = { a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t }
                end
            end
            local e = chain[#chain]
            out[#out + 1] = { e.x, e.y, e.z }
        end
    end
    return #out >= 8 and out or nil
end

-- Does this road reach our base: a point within a quarter of the spawn-to-base distance (12 studs at
-- least) of _BASES.player; the spawn is _BASES.pve or the first point.
function AutoPlaceModule.Reaches(pts)
    local goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
    local spawn = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("pve")
    -- (normal stages: the lane road's ends where the map has lanes - see LaneEnds)
    if not State.eventMode and AutoPlaceModule.LaneEnds then
        local ls, lg = AutoPlaceModule.LaneEnds()
        if ls and lg then spawn, goal = ls, lg end
    end
    if not goal or type(pts) ~= "table" or #pts == 0 then return false end
    local sx, sz = spawn and spawn.X or pts[1][1], spawn and spawn.Z or pts[1][3]
    local reach = math.max(12, 0.25 * math.sqrt((sx - goal.X) ^ 2 + (sz - goal.Z) ^ 2))
    for _, q in ipairs(pts) do
        if (q[1] - goal.X) ^ 2 + (q[3] - goal.Z) ^ 2 <= reach * reach then return true end
    end
    return false
end

local function pathPoints()
    local key = stageKey()
    if not AutoPlace.paths[key] then
        AutoPlace.paths[key] = AutoPlaceModule.AdoptOldPath(key) or {}
        -- (nothing saved for this stage: a new one - the only kind the new-stage hold waits on)
        if #AutoPlace.paths[key] == 0 then AutoPlaceModule.freshStage[key] = true end
    end
    -- (empty, or a stub that does not reach our base: the same map's road from another stage - each
    -- Dungeon Room depth is its own stage - tried once a second, the bases may load late; a stub
    -- keeps its points and gets the other road's points that are not already there)
    local cur = AutoPlace.paths[key]
    -- (normal stages, once per stage: lane points merged by the old bend chaining - out of order on
    -- Planet Greenie, its road cut across off-road ground - are dropped; learned samples are always on
    -- the half-stud grid, lane points are not; the lanes are merged again in the right order below)
    if not State.eventMode and not AutoPlaceModule.laneClean[key] then
        AutoPlaceModule.laneClean[key] = true
        local kept = {}
        for _, q in ipairs(cur) do
            if q[1] * 2 == math.floor(q[1] * 2) and q[3] * 2 == math.floor(q[3] * 2) then kept[#kept + 1] = q end
        end
        if #kept < #cur then
            AutoPlace.paths[key], cur = kept, kept
            AutoPlaceModule.sameMapDone[key] = nil
            AutoPlaceModule.Note(string.format("old lane points dropped from the saved road (%d left)", #kept))
        end
    end
    if not State.eventMode and not AutoPlaceModule.sameMapDone[key] and os.clock() - (AutoPlaceModule.sameMapAt[key] or -1e9) >= 1 then
        AutoPlaceModule.sameMapAt[key] = os.clock()
        -- (v2: the map's lanes are the road at load on every normal stage; learned points only add to it)
        local lanesNow = AutoPlaceModule.LanePath()
        if lanesNow or #cur == 0 or not AutoPlaceModule.Reaches(cur) then
            local same, done
            if lanesNow then same, done = lanesNow, true else same, done = AutoPlaceModule.SameMapPath(key) end
            -- (no complete road seen on this map: the game's lane bends)
            if not done then
                local lanes = AutoPlaceModule.LanePath()
                if lanes and AutoPlaceModule.Reaches(lanes) then
                    same, done = lanes, true
                    AutoPlaceModule.Note(string.format("enemy road taken from the map's lanes (%d points)", #lanes))
                end
            end
            if same and #cur == 0 then
                AutoPlace.paths[key] = same
                AutoPlaceModule.sameMapDone[key] = true
            elseif same and done then
                for _, q in ipairs(same) do
                    if #cur >= 400 then break end
                    local near = false
                    for _, c in ipairs(cur) do
                        if (c[1] - q[1]) ^ 2 + (c[3] - q[3]) ^ 2 < PATH_CELL * PATH_CELL then near = true break end
                    end
                    if not near then cur[#cur + 1] = q end
                end
                AutoPlaceModule.sameMapDone[key] = true
            end
        else
            AutoPlaceModule.sameMapDone[key] = true
        end
    end
    return AutoPlace.paths[key]
end

AutoPlaceModule.PathPoints = function() return pathPoints() end

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
    return hit.Position.Y, tag, hit.Instance, hit.Normal and hit.Normal.Y
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
        if Tools.onPath and roadY then
            local score = 0
            for _, q in ipairs(pts) do
                local dx, dz = q[1] - p[1], q[3] - p[3]
                if dx * dx + dz * dz <= DEFAULT_RANGE * DEFAULT_RANGE then score = score + 1 end
            end
            table.insert(list, { x = p[1], y = p[2], z = p[3], score = score, groundY = roadY, kind = "ground", onPath = true })
        end
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
                if nearest >= MIN_FROM_PATH * MIN_FROM_PATH or (Tools.onPath and dist == SIDE_DIST[1]) then
                    local gy, tag, part, ny = groundHit(x, p[2], z)
                    -- nothing under it, or well below the road (past a rooftop / ledge edge, as on
                    -- Fiend City where the road runs over roofs): not a place to stand; nor a steep
                    -- slope (cliff sides, boulders, snow banks - Snowy Kingdom 2026-10-26)
                    if gy and not (roadY and gy < roadY - 3) and not (ny and ny < PV.MIN_NORMAL) then
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
    -- (hill units: the map's hill-placement parts - Hill4_Placement on Snowy Kingdom stands 30-120 studs
    -- off the road, past the side spots above, so hill units fell back to cliffs and boulders and were
    -- refused): a grid over each part's top within PLACE_REACH of the road
    local sub = {}
    for i = 1, #pts, math.max(1, math.floor(#pts / 100)) do sub[#sub + 1] = pts[i] end
    local function near(x, z)
        local best, at = math.huge, nil
        for _, q in ipairs(sub) do
            local d2 = (q[1] - x) ^ 2 + (q[3] - z) ^ 2
            if d2 < best then best, at = d2, q end
        end
        return math.sqrt(best), at
    end
    local made = 0
    for _, part in ipairs(PV.PlacementParts()) do
        local okP, pos, size = pcall(function() return part.Position, part.Size end)
        if okP and pos and made < 1500 then
            local r = size and math.max(size.X, size.Z) / 2 or 16
            if near(pos.X, pos.Z) <= PV.PLACE_REACH + r then
                local step = math.max(3, r / 5)
                for gx = -r, r, step do
                    for gz = -r, r, step do
                        local x, z = pos.X + gx, pos.Z + gz
                        local d, q = near(x, z)
                        if q and d <= PV.PLACE_REACH and made < 1500 then
                            local gy, _, hp, ny = groundHit(x, pos.Y + (size and size.Y or 40), z)
                            if gy and hp == part and not (ny and ny < PV.MIN_NORMAL) then
                                local roadY = groundHit(q[1], q[2], q[3]) or (q[2] - 2)
                                local score = 0
                                for _, w in ipairs(pts) do
                                    if (w[1] - x) ^ 2 + (w[3] - z) ^ 2 <= DEFAULT_RANGE * DEFAULT_RANGE then score = score + 1 end
                                end
                                made = made + 1
                                table.insert(list, { x = x, y = gy, z = z, score = score, groundY = gy, kind = "hill", hillBy = "name",
                                    part = hp, rise = gy - roadY, placement = true })
                            end
                        end
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
    golden = { money = 1.5 }, -- ("gives much more money" - game Traits text; owner 2026-10-25: no damage. x1.5 is a
                              -- guess, the data has no number - AutoPlaceModule.GOLDEN_MONEY)
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
    local m = { dmg = 1, spa = 1, range = 1, money = 1 }
    for _, raw in ipairs(traits or {}) do
        local text = string.lower(tostring(raw))
        local word = text:match("^%a+") or text
        local lvl = tonumber(text:match("(%d+)%s*$")) or ROMAN[text:match("%s([iv]+)%s*$") or ""] or 1
        local t = TRAITS[word]
        if t then
            for _, k in ipairs({ "dmg", "spa", "range", "money" }) do
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
AutoPlaceModule.AOE_VALUE = AOE_VALUE

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
    -- (perf: kept on the candidate per reach; only road points added since the last count are looked at)
    local function cover(c)
        local flat = reach * reach - (c.rise or 0) ^ 2
        if flat <= 0 then return 0 end
        c.covBy = c.covBy or {}
        local e = c.covBy[reach]
        if not e or e.pts ~= pts or e.upto > #pts then e = { pts = pts, upto = 0, n = 0 } c.covBy[reach] = e end
        if e.upto < #pts then
            PV.work = PV.work + (#pts - e.upto)
            local n = e.n
            for i = e.upto + 1, #pts do
                local q = pts[i]
                local dx, dz = q[1] - c.x, q[3] - c.z
                if dx * dx + dz * dz <= flat then n = n + 1 end
            end
            e.n, e.upto = n, #pts
        end
        return e.n
    end
    local free, nearRefused = {}, {}
    for _, c in ipairs(candidates) do
        -- (normal stages: candidates are built once and kept until the road grows 10%; a spot made
        -- beside the end of a short road is ON the road once it grows past it - refused, auto_place)
        local onRoad = false
        if not State.eventMode and not c.onPath and not AutoPlaceModule.rescue then
            -- (perf: kept on the candidate; only road points added since the last look are checked)
            if c.roadPts ~= pts or (c.roadUpto or 0) > #pts then c.roadPts, c.roadUpto, c.onRoad = pts, 0, false end
            if not c.onRoad and c.roadUpto < #pts then
                PV.work = PV.work + (#pts - c.roadUpto)
                for i = c.roadUpto + 1, #pts do
                    local q = pts[i]
                    if (q[1] - c.x) ^ 2 + (q[3] - c.z) ^ 2 < 12.25 then c.onRoad = true break end
                end
            end
            c.roadUpto = #pts
            onRoad = c.onRoad
        end
        if not onRoad and not badSpots[spotKey(c, kind)] and (kind == "any" or c.kind == kind)
            and not (attacks and cover(c) == 0 and not AutoPlaceModule.rescue) then
            local ok = true
            for _, p in ipairs(mine) do
                local dx, dz = p.X - c.x, p.Z - c.z
                if dx * dx + dz * dz < MIN_SPACING * MIN_SPACING then ok = false break end
            end
            if ok then
                local near = c.part ~= nil and AutoPlaceModule.badParts[c.part] == true
                -- (within REFUSED_GONE studs of a refused spot: out for the rest of the game; up to BAD_REACH: last)
                local gone = false
                for _, b in ipairs(refused) do
                    local d2 = (b[1] - c.x) ^ 2 + (b[2] - c.z) ^ 2
                    if d2 < PV.REFUSED_GONE * PV.REFUSED_GONE then gone = true break end
                    if d2 < BAD_REACH * BAD_REACH then near = true end
                end
                if not gone then table.insert(near and nearRefused or free, c) end
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
        -- (a map with hill-placement parts: only those - the height-only spots there are cliffs and boulders)
        if trust == "name" or #PV.PlacementParts() > 0 or (trust ~= "height" and #nf + #nr > 0 and comparable) then free, nearRefused = nf, nr end
    end
    if #free == 0 then free = nearRefused end
    -- v2 (normal stages, and Fool's Hunt with AutoPlace.v2Event): damage / slow by PV.Rank, buff / support by
    -- PV.BuffRank; farms below
    if (not State.eventMode or PV.EventOn()) and role ~= "farm" then
        local list
        if (role == "buff" or role == "support") and (#helpers > 0 or #farms > 0) then
            list = PV.BuffRank(free, (range and range > 0 and range ~= DEFAULT_RANGE) and range or BUFF_REACH)
        elseif attacks then
            local top, sub
            -- (a summoner: beside the road where its summons enter it - PV.SummonRank)
            if PV.IsSummoner(AutoPlaceModule.placingName or "") then list, top, sub = PV.SummonRank(free), 0, "summon"
            else list, top, sub = PV.Rank(PV.Pool(free, cover), AutoPlaceModule.placingT, role, reach, back) end
            -- (placement_dump.json: the top spots of the last few damage placements)
            local log = {}
            for i = 1, math.min(30, #list) do
                local e = list[i]
                log[i] = { x = math.floor(e.c.x * 10) / 10, z = math.floor(e.c.z * 10) / 10, n = math.floor(e.cov * 10) / 10,
                    p = math.floor(e.p * 100) / 100, d = e.d and math.floor(e.d * 10) / 10 or nil, kind = e.c.kind }
            end
            table.insert(AutoPlaceModule.scoredLog, { unit = AutoPlaceModule.placingName, range = reach, as = sub, buff = AutoPlaceModule.RangeBuff(),
                defRange = AutoPlaceModule.DefRangeAt(AutoPlaceModule.placingName or "", 0),
                best = math.floor(PV.Best(reach, PV.Shape(AutoPlaceModule.placingName or ""), candidates) * 10) / 10,
                wave = AutoPlaceModule.WaveNumber(), top = log })
            while #AutoPlaceModule.scoredLog > 4 do table.remove(AutoPlaceModule.scoredLog, 1) end
            -- (Fool's Hunt Merge: a copy next to its own kind first - inside 0.6 of its reach - so Merge can fold them)
            if State.eventMode and AutoPlaceModule.placingName then
                local kin = {}
                for _, u in ipairs(ownedUnits()) do
                    if unitType(u) == AutoPlaceModule.placingName then
                        local p = rootPos(u)
                        if p then kin[#kin + 1] = p end
                    end
                end
                if #kin > 0 then
                    local near, rest = {}, {}
                    for _, e in ipairs(list) do
                        local ok = false
                        for _, p in ipairs(kin) do
                            if (p.X - e.c.x) ^ 2 + (p.Z - e.c.z) ^ 2 <= (reach * 0.6) ^ 2 then ok = true break end
                        end
                        table.insert(ok and near or rest, e)
                    end
                    for _, e in ipairs(rest) do near[#near + 1] = e end
                    list = near
                end
            end
        end
        if list then return list[skip + 1] and list[skip + 1].c end
    end
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
        -- buff and support (hoshino's aura): next to the most damage units - owner 2026-10-24
        local reach = (range and range > 0 and range ~= DEFAULT_RANGE) and range or BUFF_REACH
        local scored = {}
        for _, c in ipairs(free) do
            local near = countNear(helpers, c, reach)
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
        -- (owner: Fool's Hunt maps are short - the first units stand back near the base so the early
        -- waves walk longer through them while the money goes into upgrades; later ones go forward)
        -- (owner: it depends on the map - a short road keeps them back until wave 20, a long one
        -- plays the middle from the start; the road length is noted so the line can be tuned)
        if State.eventMode then
            local len = 0
            for i = 2, #pts do len = len + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][3] - pts[i - 1][3]) ^ 2) end
            local short = len < AutoPlaceModule.SHORT_ROAD
            AutoPlaceModule.shortRoad = short
            if AutoPlaceModule.roadNoted ~= stageKey() then
                AutoPlaceModule.roadNoted = stageKey()
                AutoPlaceModule.Note(string.format("road %d studs: %s map", math.floor(len), short and "short" or "long"))
            end
            mode = (AutoPlaceModule.WaveNumber() < (short and 20 or 0)) and "Safe" or "Balanced"
        end
        local spawn, goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("pve"), AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
        -- (Fool's Hunt: a copy goes next to one of its own kind, inside its reach, so Merge can fold
        -- them - spread over the map, three fujitoras never could)
        local kin = {}
        if State.eventMode and AutoPlaceModule.placingName then
            for _, u in ipairs(ownedUnits()) do
                if unitType(u) == AutoPlaceModule.placingName then
                    local p = AutoPlaceModule.RootPos(u)
                    if p then kin[#kin + 1] = p end
                end
            end
        end
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
            for _, p in ipairs(kin) do
                if (p.X - c.x) ^ 2 + (p.Z - c.z) ^ 2 <= (r * 0.6) ^ 2 then n = n * 1.5 break end
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
    local stc = ReplicatedStorage:WaitForChild("endpoints"):WaitForChild("server_to_client")
    local function uuidOf(v) return type(v) == "table" and v.uuid and tostring(v.uuid) or (type(v) == "string" and v or nil) end
    table.insert(State.connections, stc:WaitForChild("unit_added_temporary").OnClientEvent:Connect(function(data)
        local uuid = uuidOf(data)
        if uuid and type(data) == "table" and data.unit_id then
            AutoPlaceModule.liveTemp[uuid] = { id = tostring(data.unit_id), made = tonumber(data._creation_time) or os.time(), seen = os.clock(),
                shiny = data.shiny == true, rolls = type(data.trait_stats) == "table" and data.trait_stats or nil }
            AutoPlaceModule.goneTemp[uuid] = nil
            AutoPlaceModule.tempVersion = AutoPlaceModule.tempVersion + 1
        end
    end))
    table.insert(State.connections, stc:WaitForChild("unit_removed_temporary").OnClientEvent:Connect(function(data)
        local uuid = uuidOf(data)
        if uuid then
            AutoPlaceModule.liveTemp[uuid], AutoPlaceModule.goneTemp[uuid] = nil, true
            AutoPlaceModule.tempVersion = AutoPlaceModule.tempVersion + 1
        end
    end))
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
            -- (at most 20 s: a slot showing the same unit kind again after that is a new copy - real game
            -- 2026-10-25, wave 30 with 48k yen and two copies on the bar that were never seen)
            local stale = used and AutoPlaceModule.BaseId(used.id) == AutoPlaceModule.BaseId(model.Name) and os.clock() - used.at < 20
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
    AutoPlaceModule.hotbarAt = nil
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
    -- (a summoner whose summons hit flyers - PV.SummonAir)
    if PV.SummonAir and PV.SummonAir(name) then return true end
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

-- ===== Auto Place v2 (work/placement_method.md, normal stages only; Fool's Hunt keeps its own brain) =====
-- One method: the road from the game's lanes, a spot score per unit against the best spot for its range
-- on this map, an order by road kind and the spending by margin. Each rule has a named v2_* test.
-- A bend chain in the game's own order: player LANES "final" (enemy end) -> numbered bends high to low
-- -> "spawn" (our base); pve LANES the other way round. Numbers always win; nil with fewer than 2.
function PV.LaneOrder(bends, side)
    local nums, fin, sp = {}, nil, nil
    for _, b in ipairs(bends) do
        local name = string.lower(tostring(b.name))
        if tonumber(b.name) then nums[#nums + 1] = b
        elseif name == "final" then fin = b
        elseif name == "spawn" then sp = b end
    end
    if #nums < 2 then return nil end
    table.sort(nums, function(a, b) return tonumber(a.name) > tonumber(b.name) end)
    local chain = {}
    if fin then chain[1] = fin end
    for _, b in ipairs(nums) do chain[#chain + 1] = b end
    if sp then chain[#chain + 1] = sp end
    if side == "pve" then
        local rev = {}
        for i = #chain, 1, -1 do rev[#rev + 1] = chain[i] end
        chain = rev
    end
    return chain
end

-- The road: every lane (both on two-lane maps) as points every ROAD_STEP studs, enemy end first; each
-- point has p = how far along its lane (0 enemy end, 1 our base) and w = road length it stands for.
-- Points the enemies walked more than 4 studs off the lanes are added with the p of the nearest lane
-- point. No lanes: the learned road in walking order. len = the longest lane (shared as `rl`).
function PV.Road()
    local key = stageKey()
    local learned = pathPoints()
    local c = PV.road
    if c and c.key == key and #learned < c.n + math.max(10, math.floor(c.n * 0.1)) and os.clock() - c.at < 5 then return c end
    local goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
    local g = goal and { x = goal.X, z = goal.Z } or { x = 0, z = 0 }
    local lanes = AutoPlaceModule.Lanes()
    local useSide = "player"
    for _, lane in ipairs(lanes) do if lane.side == "pve" and #lane.bends >= 2 then useSide = "pve" end end
    local pts, longest, nLanes = {}, 0, 0
    for _, lane in ipairs(lanes) do
        local chain = lane.side == useSide and #lane.bends >= 2 and AutoPlaceModule.LaneOrder(lane.bends, g, lane.side)
        if chain and #chain >= 2 then
            local total = 0
            for i = 2, #chain do total = total + math.sqrt((chain[i].x - chain[i - 1].x) ^ 2 + (chain[i].z - chain[i - 1].z) ^ 2) end
            if total > 0 then
                nLanes = nLanes + 1
                longest = math.max(longest, total)
                local along = 0
                for i = 2, #chain do
                    local a, b = chain[i - 1], chain[i]
                    local seg = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                    local n = math.max(1, math.ceil(seg / PV.ROAD_STEP))
                    for k = 0, n - 1 do
                        local t = k / n
                        pts[#pts + 1] = { a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t,
                            p = (along + seg * t) / total, w = seg / n, lane = nLanes }
                    end
                    along = along + seg
                end
                local e = chain[#chain]
                pts[#pts + 1] = { e.x, e.y, e.z, p = 1, w = 0, lane = nLanes }
            end
        end
    end
    local from = nLanes > 0 and "lanes" or "learned"
    if nLanes > 0 then
        local extra = {}
        for _, q in ipairs(learned) do
            local bd, bp = math.huge, 0
            for _, r in ipairs(pts) do
                local d = (r[1] - q[1]) ^ 2 + (r[3] - q[3]) ^ 2
                if d < bd then bd, bp = d, r.p end
            end
            if bd > 16 then extra[#extra + 1] = { q[1], q[2], q[3], p = bp, w = PV.ROAD_STEP, extra = true, lane = nLanes + 1 } end
        end
        for _, q in ipairs(extra) do pts[#pts + 1] = q end
    elseif #learned >= 2 then
        -- (the learned road in sample order; a sample joins the lane of the latest of the 10 before it
        -- within 8 studs, else it starts a new lane - two roads sampled in turn stay two lanes)
        local laneOf, prevOf, n = {}, {}, 0
        for i, q in ipairs(learned) do
            for j = i - 1, math.max(1, i - 10), -1 do
                if (learned[j][1] - q[1]) ^ 2 + (learned[j][3] - q[3]) ^ 2 <= 64 then laneOf[i], prevOf[i] = laneOf[j], j break end
            end
            if not laneOf[i] then n = n + 1 laneOf[i] = n end
        end
        local along, total = {}, {}
        for i, q in ipairs(learned) do
            local j = prevOf[i]
            along[i] = j and along[j] + math.sqrt((learned[j][1] - q[1]) ^ 2 + (learned[j][3] - q[3]) ^ 2) or 0
            total[laneOf[i]] = math.max(total[laneOf[i]] or 0, along[i])
        end
        for i, q in ipairs(learned) do
            local l = laneOf[i]
            pts[#pts + 1] = { q[1], q[2], q[3], p = (total[l] or 0) > 0 and along[i] / total[l] or 0, w = PV.ROAD_STEP, lane = l }
            longest = math.max(longest, total[l] or 0)
        end
    end
    PV.road = { key = key, n = #learned, at = os.clock(), pts = pts, len = longest, lanes = nLanes, from = from }
    PV.lastLen = math.floor(longest + 0.5)
    return PV.road
end

-- Saved roads: at most PV.MAX_PATHS stages (every Dungeon depth is its own stage and all of it is written on
-- every save); the smallest go first, never this stage's.
PV.MAX_PATHS = 60
function PV.PrunePaths()
    local keys, cur = {}, stageKey()
    for k, p in pairs(AutoPlace.paths) do if k ~= cur then keys[#keys + 1] = { k = k, n = type(p) == "table" and #p or 0 } end end
    if #keys < PV.MAX_PATHS then return end
    table.sort(keys, function(a, b) return a.n < b.n end)
    for i = 1, #keys - PV.MAX_PATHS + 1 do AutoPlace.paths[keys[i].k] = nil end
end

-- short < SHORT_ROAD <= middle <= LONG_ROAD < long
function PV.Kind(len)
    if len < PV.SHORT_ROAD then return "short" end
    if len > PV.LONG_ROAD then return "long" end
    return "middle"
end

-- Road length (studs) a unit at c reaches with range r and its attack shape, and the mean p of that
-- road. circle = everything in range; cone = the best of 16 headings, CONE_HALF either side; line = the
-- best of 16 headings, LINE_HALF wide. c.rise (height above the road) shortens the reach on the map.
-- (perf: every answer is kept until the road changes - units and spots do not move; PV.work counts the
-- road points visited, for the perf test)
PV.work, PV.coverCache, PV.coverN = 0, {}, 0
function PV.Cover(c, r, shape, road)
    road = road or PV.Road()
    local sig = road.key .. "|" .. #road.pts .. "|" .. math.floor(road.len)
    if PV.coverSig ~= sig or PV.coverN > 20000 then PV.coverSig, PV.coverCache, PV.coverN = sig, {}, 0 end
    local key = string.format("%.1f|%.1f|%.2f|%s|%.1f", c.x, c.z, r, shape or "circle", c.rise or 0)
    local hit = PV.coverCache[key]
    if hit then return hit[1], hit[2] end
    local cov, p = PV.CoverRaw(c, r, shape, road)
    PV.coverCache[key], PV.coverN = { cov, p }, PV.coverN + 1
    return cov, p
end
function PV.CoverRaw(c, r, shape, road)
    PV.work = PV.work + #road.pts * ((shape == "cone" or shape == "line") and 16 or 1)
    local flat = r * r - (c.rise or 0) ^ 2
    if flat <= 0 then return 0, 0 end
    if shape == "cone" or shape == "line" then
        local best, bestP, cosHalf = 0, 0, math.cos(PV.CONE_HALF)
        for k = 0, 15 do
            local a = k * math.pi / 8
            local ux, uz = math.cos(a), math.sin(a)
            local s, sp = 0, 0
            for _, q in ipairs(road.pts) do
                local dx, dz = q[1] - c.x, q[3] - c.z
                local d2 = dx * dx + dz * dz
                if d2 <= flat then
                    local along = dx * ux + dz * uz
                    local ok
                    if shape == "line" then ok = along >= 0 and math.abs(dx * uz - dz * ux) <= PV.LINE_HALF
                    else ok = along >= math.sqrt(d2) * cosHalf end
                    if ok then s, sp = s + q.w, sp + q.w * q.p end
                end
            end
            if s > best then best, bestP = s, sp / s end
        end
        return best, bestP
    end
    local s, sp = 0, 0
    for _, q in ipairs(road.pts) do
        if (q[1] - c.x) ^ 2 + (q[3] - c.z) ^ 2 <= flat then s, sp = s + q.w, sp + q.w * q.p end
    end
    return s, s > 0 and sp / s or 0
end

-- The best road cover any spot on this map gives for this range and shape (cov / best = spot score).
-- cands = the spot candidates (bestSpot's list); cached per stage, range, shape and road size.
function PV.Best(r, shape, cands)
    local road = PV.Road()
    cands = cands or candidates or {}
    local key = string.format("%s|%.1f|%s|%d|%d", road.key, r, shape, #cands, #road.pts)
    PV.bestCache = PV.bestCache or {}
    if PV.bestCache[key] then return PV.bestCache[key] end
    PV.bestN = (PV.bestN or 0) + 1
    if PV.bestN > 200 then PV.bestCache, PV.bestN = {}, 1 end
    local list = {}
    for _, c in ipairs(cands) do list[#list + 1] = { c = c, cov = (PV.Cover(c, r, "circle", road)) } end
    table.sort(list, function(a, b) return a.cov > b.cov end)
    local best = list[1] and list[1].cov or 0
    if shape ~= "circle" then
        best = 0
        for i = 1, math.min(60, #list) do best = math.max(best, (PV.Cover(list[i].c, r, shape, road))) end
    end
    PV.bestCache[key] = best
    return best
end

-- The game's Attacks entry of a unit's main attack (and of its active skill).
function PV.Attack(name, field)
    local def = AutoPlaceModule.UnitDef(name)
    local id = def and (field and def[field] or def.primary_attack_no_upgrades or def.primary_attack)
    if type(id) ~= "string" then return nil end
    if attacksModule == nil then
        attacksModule = false
        pcall(function()
            local ok, mod = pcall(require, ReplicatedStorage.src.Data:FindFirstChild("Attacks"))
            if ok and type(mod) == "table" then attacksModule = mod end
        end)
    end
    local e = attacksModule and attacksModule[id]
    return type(e) == "table" and e or nil
end
function PV.Shape(name)
    local e = PV.Attack(name)
    if e and e.cone ~= nil then return "cone" end
    if e and e.line ~= nil then return "line" end
    return "circle"
end
-- slow / freeze / stun in its main attack or its active skill
PV.SLOW_UNITS = {}
function PV.IsSlow(name)
    if PV.SLOW_UNITS[name] then return true end
    for _, f in ipairs({ false, "active_attack" }) do
        local e = PV.Attack(name, f or nil)
        if e and (e.slow ~= nil or e.freeze ~= nil or e.stun ~= nil) then return true end
    end
    return false
end

-- Our damage against these enemies: x the room's / level's weakness (_weak_against amplification), /
-- its strength (_strong_against), x REC_TYPE for the level's _recommended_damage_types, and the
-- resistance cards taken against that type (x100 / (100 + resist)).
local function normType(k) return (string.lower(tostring(k or "")):gsub("_damage$", "")) end
function PV.TypeFactor(name)
    local def = AutoPlaceModule.UnitDef(name) or {}
    local kind = normType(def._base_damage_type or "physical")
    local f = 1
    local ok, d = pcall(Stage.levelData)
    if ok and type(d) == "table" then
        for _, w in pairs(type(d._weak_against) == "table" and d._weak_against or {}) do
            if type(w) == "table" and normType(w.damage_type) == kind then f = f * math.max(1, tonumber(w.amplification) or 1) end
        end
        for _, w in pairs(type(d._strong_against) == "table" and d._strong_against or {}) do
            local k = type(w) == "table" and w.damage_type or w
            local a = type(w) == "table" and tonumber(w.amplification)
            if normType(k) == kind then f = f * ((a and a < 1 and a) or (a and a > 1 and 1 / a) or 0.5) end
        end
        for _, k in pairs(type(d._recommended_damage_types) == "table" and d._recommended_damage_types or {}) do
            if normType(k) == kind then f = f * PV.REC_TYPE end
        end
    end
    for k, res in pairs(Lobby.resTaken or {}) do
        if normType(k) == kind and tonumber(res) then f = f * 100 / (100 + tonumber(res)) end
    end
    return f
end

-- A team copy's damage per second against this map: its rolls and trait (Stats), area x AOE_VALUE, x
-- TypeFactor. The carry = the strongest placeable damage copy (the better-trait copy of a unit wins; a
-- Unique-trait copy always).
function PV.Power(t)
    local s = AutoPlaceModule.Stats(t)
    return s.damage / math.max(0.1, s.cooldown) * (AutoPlaceModule.IsAoe(t.name) and AutoPlaceModule.AOE_VALUE or 1) * PV.TypeFactor(t.name)
end
function PV.Carry()
    local best, bv, bs
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t and (AutoPlaceModule.RoleOf(t) or "dps") == "dps" and AutoPlaceModule.SlotTarget(s, t) > 0
            and (not AutoPlaceModule.full[t.uuid] or #placedOf(t.uuid) > 0) then
            -- (owner 2026-10-24: the Unique-trait copy is upgraded first, to the top - it is the carry)
            local v = PV.Power(t) * (AutoPlaceModule.TraitMods(t.traits).cap == 1 and 1e6 or 1)
            -- (a summoner only when no other damage unit is in the team: its summons do the damage, not it)
            if PV.IsSummoner and PV.IsSummoner(t.name) then v = v * 1e-6 end
            if not bv or v > bv then best, bv, bs = t, v, s end
        end
    end
    return best, bs
end
-- the carry's copy on the map (highest level)
function PV.CarryUnit()
    local t = PV.Carry()
    if not t then return nil end
    local pick, lv
    for _, u in ipairs(placedOf(t.uuid)) do
        local l = AutoPlaceModule.StatNum(u, "upgrade") or 0
        if not lv or l > lv then pick, lv = u, l end
    end
    return pick, lv
end

-- What a placement is for: carry (also a trap that hits flyers - it guards the base end), slow, damage,
-- or the role itself (farm, buff, support).
function PV.SpotRole(t, role, back)
    if role ~= "dps" then return role end
    local carry = PV.Carry()
    if back or (t and carry and t.uuid == carry.uuid) or not carry then return "carry" end
    if t and PV.IsSlow(t.name) and PV.CarryUnit() then return "slow" end
    return "damage"
end

-- The longest lane (LANE_MIN+ studs) none of our damage units reaches; nil with one lane or all reached.
PV.LANE_MIN = 30
function PV.UncoveredLane(road)
    local len, hit = {}, {}
    local reach = {}
    for _, u in ipairs(ownedUnits()) do
        local p = unitRole(u) == "dps" and rootPos(u)
        if p then reach[#reach + 1] = { p, AutoPlaceModule.StatNum(u, "range") or unitReach(u) } end
    end
    if #reach == 0 then return nil end
    local n = 0
    for _, q in ipairs(road.pts) do
        if not len[q.lane] then n = n + 1 end
        len[q.lane] = (len[q.lane] or 0) + q.w
        if not hit[q.lane] then
            for _, e in ipairs(reach) do
                if (e[1].X - q[1]) ^ 2 + (e[1].Z - q[3]) ^ 2 <= e[2] * e[2] then hit[q.lane] = true break end
            end
        end
    end
    if n < 2 then return nil end
    local best, bl
    for l, total in pairs(len) do
        if not hit[l] and total >= PV.LANE_MIN and (not bl or total > bl) then best, bl = l, total end
    end
    return best
end

-- (perf) the RANK_MAX spots that reach the most road points, by the caller's own count
PV.RANK_MAX = 400
function PV.Pool(free, count)
    if #free <= PV.RANK_MAX then return free end
    local list = {}
    for i, c in ipairs(free) do list[i] = { c = c, n = count(c) } end
    table.sort(list, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, PV.RANK_MAX do out[i] = list[i].c end
    return out
end

-- The spot for a damage / slow unit (bestSpot, normal stages). free = its free spots of its kind.
--   carry : best cover in the base half of the road (mean p of its road >= 0.5)
--   damage: best spot within BUFF_REACH of the carry when its cover is within NEAR_BEST of the best one
--   slow  : best spot reaching the carry's road (same bend) on the enemy side of it (lower mean p)
-- falling back to the best cover. Returns the ordered list (choice first) and the best cover.
function PV.Rank(free, t, role, r, back)
    local road = PV.Road()
    local shape = PV.Shape(t and t.name or "")
    local list = {}
    for _, c in ipairs(free) do
        local cov, p = PV.Cover(c, r, "circle", road)
        if cov > 0 or AutoPlaceModule.rescue then list[#list + 1] = { c = c, cov = cov, p = p } end
    end
    table.sort(list, function(a, b) return a.cov > b.cov end)
    if shape ~= "circle" then
        local top = {}
        for i = 1, math.min(60, #list) do
            local e = list[i]
            e.cov, e.p = PV.Cover(e.c, r, shape, road)
            if e.cov > 0 or AutoPlaceModule.rescue then top[#top + 1] = e end
        end
        list = top
        table.sort(list, function(a, b) return a.cov > b.cov end)
    end
    local sub = PV.SpotRole(t, role, back)
    local top = list[1] and list[1].cov or 0
    local want
    -- (a lane of LANE_MIN+ studs that no damage unit reaches - a second road, "A new path has opened!" -
    -- gets the next damage unit: the spots reaching it, best cover first)
    local gap = (sub == "damage" or sub == "slow") and PV.UncoveredLane(road)
    if gap then
        local lanePts = {}
        for _, q in ipairs(road.pts) do if q.lane == gap then lanePts[#lanePts + 1] = q end end
        want = function(e)
            for _, q in ipairs(lanePts) do
                if (q[1] - e.c.x) ^ 2 + (q[3] - e.c.z) ^ 2 <= r * r then return true end
            end
            return false
        end
        sub = sub .. "+lane"
    end
    if want then
        -- (decided above)
    elseif sub == "carry" then
        want = function(e) return e.p >= 0.5 end
    elseif sub == "damage" and PV.FinishFast() then
        -- (finish fast: the best spot in the front half of the road - PV.FinishFast)
        want = function(e) return e.p < 0.5 end
        sub = "damage+fast"
    elseif sub == "damage" or sub == "slow" then
        local cu = PV.CarryUnit()
        local cp = cu and rootPos(cu)
        if cp and sub == "damage" then
            want = function(e) return (e.c.x - cp.X) ^ 2 + (e.c.z - cp.Z) ^ 2 <= BUFF_REACH * BUFF_REACH and e.cov >= PV.NEAR_BEST * top end
        elseif cp then
            local cr = AutoPlaceModule.StatNum(cu, "range") or unitReach(cu)
            local seg, csum, cw = {}, 0, 0
            for _, q in ipairs(road.pts) do
                if (q[1] - cp.X) ^ 2 + (q[3] - cp.Z) ^ 2 <= cr * cr then seg[#seg + 1] = q csum, cw = csum + q.w * q.p, cw + q.w end
            end
            local cpMean = cw > 0 and csum / cw or 0
            want = function(e)
                if e.p >= cpMean then return false end
                for _, q in ipairs(seg) do
                    if (q[1] - e.c.x) ^ 2 + (q[3] - e.c.z) ^ 2 <= r * r then return true end
                end
                return false
            end
        end
    end
    local out = {}
    if want then for _, e in ipairs(list) do e.wanted = want(e) == true end end
    for _, e in ipairs(list) do if want and e.wanted then out[#out + 1] = e end end
    for _, e in ipairs(list) do if not (want and e.wanted) then out[#out + 1] = e end end
    return out, top, sub
end

-- Buff / support: the spot whose reach holds the most team damage (each damage unit by its damage per
-- second, the carry twice).
function PV.BuffRank(free, reach)
    local units = {}
    local cu = PV.CarryUnit()
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            local p = rootPos(u)
            local dmg = AutoPlaceModule.StatNum(u, "damage") or 1
            local cd = AutoPlaceModule.StatNum(u, "attack_cooldown") or 1
            if p then units[#units + 1] = { p = p, v = math.max(0.01, dmg / math.max(0.1, cd)) * (u == cu and 2 or 1) } end
        end
    end
    local list = {}
    for _, c in ipairs(free) do
        local v = 0
        for _, e in ipairs(units) do
            if (e.p.X - c.x) ^ 2 + (e.p.Z - c.z) ^ 2 <= reach * reach then v = v + e.v end
        end
        list[#list + 1] = { c = c, v = v + (c.score or 0) * 1e-6 }
    end
    table.sort(list, function(a, b) return a.v > b.v end)
    return list
end

-- cov / best of a unit on the map, 0-100 (-1: unknown)
function PV.CovBest(u)
    local p = rootPos(u)
    local range = AutoPlaceModule.StatNum(u, "range") or unitReach(u)
    if not p or not range or range <= 0 then return -1 end
    local road = PV.Road()
    if #road.pts < 2 then return -1 end
    local shape = PV.Shape(unitType(u) or "")
    local cov = PV.Cover({ x = p.X, z = p.Z }, range, shape, road)
    local best = PV.Best(range, shape)
    if best <= 0 then return -1 end
    return math.floor(100 * math.min(1, cov / best) + 0.5)
end

-- Share of the team's damage (damage per second) standing inside a buff / support unit's reach, 0-100;
-- -1 with no buff or support unit down.
function PV.BuffShare()
    local dps, buffs = {}, {}
    for _, u in ipairs(ownedUnits()) do
        local role, p = unitRole(u), rootPos(u)
        if p and role == "dps" then
            local v = (AutoPlaceModule.StatNum(u, "damage") or 1) / math.max(0.1, AutoPlaceModule.StatNum(u, "attack_cooldown") or 1)
            dps[#dps + 1] = { p = p, v = v }
        elseif p and (role == "buff" or role == "support") then
            local r = AutoPlaceModule.StatNum(u, "range") or BUFF_REACH
            buffs[#buffs + 1] = { p = p, r = math.max(BUFF_REACH, r) }
        end
    end
    if #buffs == 0 or #dps == 0 then return -1 end
    local all, inside = 0, 0
    for _, d in ipairs(dps) do
        all = all + d.v
        for _, b in ipairs(buffs) do
            if (b.p.X - d.p.X) ^ 2 + (b.p.Z - d.p.Z) ^ 2 <= b.r * b.r then inside = inside + d.v break end
        end
    end
    return all > 0 and math.floor(100 * inside / all + 0.5) or -1
end

-- Enemy walk speed (studs / s), measured from the enemies' moves between ticks; ENEMY_SPEED until then.
-- The game's unit data has only a speed multiplier (1 for most enemies) and the challenge
-- enemy_speed_scale, no studs per second.
PV.seen = setmetatable({}, { __mode = "k" })
-- Kill depth: an enemy gone from the map before the last 5% of the road died there (one that reaches
-- our base end is a leak - the base-hit rule). PV.kills = road positions of the last 10, per stage.
PV.track, PV.kills = {}, {}
function PV.RoadPos(p, road)
    local bd, bp = math.huge, 0
    for _, q in ipairs((road or PV.Road()).pts) do
        local d = (q[1] - p.X) ^ 2 + (q[3] - p.Z) ^ 2
        if d < bd then bd, bp = d, q.p end
    end
    return bp
end
function PV.SpeedStep()
    local folder = unitsFolder()
    local now = os.clock()
    local road = PV.Road()
    -- (a new stage, or a new game - the wave number went down: the enemies cleared at the end were no kills)
    local w = AutoPlaceModule.WaveNumber()
    if PV.killsKey ~= road.key or w < (PV.killWave or 0) then PV.kills, PV.track, PV.killsKey = {}, {}, road.key end
    PV.killWave = w
    local track = {}
    for _, e in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(e) then
            local p = rootPos(e)
            if p and #road.pts > 0 then track[e] = PV.RoadPos(p, road) end
            local last = PV.seen[e]
            if p and last and now - last.t >= 0.2 and now - last.t <= 3 then
                local v = math.sqrt((p.X - last.x) ^ 2 + (p.Z - last.z) ^ 2) / (now - last.t)
                if v > 0.2 and v < 60 then PV.speed = PV.speed and (0.9 * PV.speed + 0.1 * v) or v end
            end
            if p and (not last or now - last.t >= 0.2) then PV.seen[e] = { x = p.X, z = p.Z, t = now } end
        end
    end
    for e, p in pairs(PV.track) do
        if track[e] == nil and p < 0.95 then
            table.insert(PV.kills, p)
            while #PV.kills > 10 do table.remove(PV.kills, 1) end
        end
    end
    PV.track = track
end
-- mean road position where the last enemies died; nil with fewer than 5 kills seen
function PV.KillDepth()
    if #PV.kills < 5 then return nil end
    local s = 0
    for _, p in ipairs(PV.kills) do s = s + p end
    return s / #PV.kills
end

-- Margin = our power / threat, and how deep the enemies get (PV.KillDepth: where they die, 0-1 along the road).
--   threat = HP on the map (+ shield, x1.2 regenerating), at least the last wave's peak x wave / (wave - 1)
--   power  = sum over our damage units of damage / s x TypeFactor x its live damage_multiplier x seconds an enemy stays in reach
--            (road in reach / enemy speed, x SLOW_GAIN where a slow unit reaches the same road)
-- nil margin while there is no threat, no damage unit down or fewer than 5 kills seen (KillDepth).
PV.peak = {}
function PV.Threat()
    local folder = unitsFolder()
    local hp, list = 0, {}
    for _, e in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(e) then
            local st = e:FindFirstChild("_stats")
            local hum = e:FindFirstChildOfClass("Humanoid")
            local h = (hum and tonumber(hum.Health)) or nil
            local function num(n) local v = st and st:FindFirstChild(n) return v and tonumber(v.Value) end
            h = h or num("health") or num("base_health") or 0
            h = h + (num("shield") or 0)
            local rg = st and st:FindFirstChild("Regen")
            if rg and (rg.Value == true or (tonumber(rg.Value) or 0) > 0) then h = h * 1.2 end
            hp = hp + h
            local p = rootPos(e)
            if p then list[#list + 1] = p end
        end
    end
    local w = AutoPlaceModule.WaveNumber()
    PV.peak[w] = math.max(PV.peak[w] or 0, hp)
    local prev = w > 1 and PV.peak[w - 1]
    if prev and prev > 0 then hp = math.max(hp, prev * w / (w - 1)) end
    return hp, list
end
function PV.Margin()
    -- (perf: at most once a second - it runs from every tick)
    local m = PV.marginMemo
    if m and os.clock() - m.at < 1 then return m[1], m[2], m[3], m[4] end
    local a, b, c, d = PV.MarginNow()
    PV.marginMemo = { a, b, c, d, at = os.clock() }
    return a, b, c, d
end
function PV.MarginNow()
    local threat = PV.Threat()
    local road = PV.Road()
    local depth = PV.KillDepth()
    local speed = PV.speed or PV.ENEMY_SPEED
    local slows = {}
    local units = ownedUnits()
    for _, u in ipairs(units) do
        if unitRole(u) == "dps" and PV.IsSlow(unitType(u) or "") then
            local p = rootPos(u)
            if p then slows[#slows + 1] = { p, (AutoPlaceModule.StatNum(u, "range") or unitReach(u)) } end
        end
    end
    local power, any = 0, false
    for _, u in ipairs(units) do
        local p = rootPos(u)
        if p and unitRole(u) == "dps" then
            any = true
            local name = unitType(u) or ""
            local r = AutoPlaceModule.StatNum(u, "range") or unitReach(u)
            local cov = PV.Cover({ x = p.X, z = p.Z }, r, PV.Shape(name), road)
            -- (a summoner: its summons walk the road - judged by its own range the margin read low and the
            -- farms waited, friend's Snowy Kingdom room 2026-10-26)
            if PV.IsSummoner and PV.IsSummoner(name) then cov = math.max(cov, road.len * PV.SUMMON_COVER) end
            local slowed = false
            for _, s in ipairs(slows) do
                if (s[1].X - p.X) ^ 2 + (s[1].Z - p.Z) ^ 2 <= (r + s[2]) ^ 2 then slowed = true break end
            end
            -- (the unit's own numbers when its _stats has none)
            local def = AutoPlaceModule.UnitDef(name) or {}
            local dps = (AutoPlaceModule.StatNum(u, "damage") or tonumber(def.damage) or 0)
                / math.max(0.1, AutoPlaceModule.StatNum(u, "attack_cooldown") or AutoPlaceModule.DefCd(def))
            dps = dps * (AutoPlaceModule.IsAoe(name) and AutoPlaceModule.AOE_VALUE or 1) * PV.TypeFactor(name)
                * (AutoPlaceModule.StatNum(u, "damage_multiplier") or 1) -- (live buffs: cards, shrine, shop items, buff units)
            power = power + dps * cov / math.max(0.1, speed) * (slowed and PV.SLOW_GAIN or 1)
        end
    end
    -- (unknown until 5 enemies died here: before that the power estimate has nothing to be checked against)
    local margin = (any and threat > 0 and depth ~= nil) and power / threat or nil
    return margin, depth, threat, power
end
-- "high" (money to farms), "low" (damage upgrades, carry first) or "normal" (the order of the road kind)
function PV.Spend(danger)
    local margin, depth = PV.Margin()
    PV.lastMargin, PV.lastDepth = margin, depth
    PV.FastNote(margin, danger)
    if danger or (depth and depth > 0.5) or (margin and margin < PV.MARGIN_LOW) then return "low" end
    if margin and margin >= PV.MARGIN_HIGH and depth and depth < 0.5 then return "high" end
    return "normal"
end
PV.ORDER = {
    short = { "carry", "aura", "carryUp", "slow", "rotating", "farms", "rest" },
    middle = { "carry", "aura", "farms", "rotating", "carryUp", "slow", "rest" },
    long = { "carry", "aura", "farms", "rotating", "farmUps", "carryUp", "rest" },
    high = { "carry", "aura", "farms", "rotating", "farmUps", "rest" },
    low = { "carry", "aura", "carryMax", "rotating", "damageUps", "rest" },
}
PV.FARM_PHASE_WAVE = 6 -- from this wave the farm steps wait while the carry has an upgrade left below CARRY_LEVEL
PV.DPS_BY_WAVE = 5     -- a damage unit that is not a summoner is on the map by this wave
PV.HARD_ROOM = 2       -- level _lobby_difficulty_scale at least this: a hard room
PV.HARD_DPS = 3        -- hard room: the carry stays at HARD_LEVEL until this many damage units are down
PV.HARD_LEVEL = 2
function PV.HardRoom()
    local ok, d = pcall(Stage.levelData)
    return ok and type(d) == "table" and (tonumber(d._lobby_difficulty_scale) or 0) >= PV.HARD_ROOM
end
-- (b) a hard room: no carry upgrade past HARD_LEVEL while fewer than HARD_DPS damage units are down and one
-- can still be placed
function PV.CarryHold(u, level)
    if State.eventMode or level < PV.HARD_LEVEL or not PV.HardRoom() or unitType(u) ~= (PV.Carry() or {}).name then return false end
    if PV.DpsDown() >= PV.HARD_DPS then return false end
    for _, x in ipairs(AutoPlaceModule.placeable or {}) do if x.role == "dps" then return true end end
    return false
end
-- our damage units on the map (all, and the ones that are not summoners)
function PV.DpsDown()
    local n, real = 0, 0
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" then
            n = n + 1
            if not (PV.IsSummoner and PV.IsSummoner(unitType(u) or "")) then real = real + 1 end
        end
    end
    return n, real
end
function PV.Steps(danger)
    local spend = PV.Spend(danger)
    if spend ~= "normal" then return PV.ORDER[spend], spend end
    local kind = PV.Kind(PV.Road().len)
    return PV.ORDER[kind], kind
end

-- The hill spots beside the road (for the wave-1 dump): candidates on a part named like a hill or
-- raised 2.5+ studs over the road (roofs look the same), with how high and by which sign.
function PV.HillSpots()
    local pts = pathPoints()
    if not candidates and #pts >= 2 then candidates, candidatesFor = buildCandidates(pts), #pts end
    local out = {}
    for _, c in ipairs(candidates or {}) do
        if c.kind == "hill" and #out < 80 then
            out[#out + 1] = { x = math.floor(c.x * 10) / 10, z = math.floor(c.z * 10) / 10, rise = c.rise and math.floor(c.rise * 10) / 10 or nil,
                by = c.hillBy, part = c.part and c.part.Name or nil }
        end
    end
    return out
end

-- Buff units (owner 2026-10-25, work/placement_method.md "Buff units - how many and how far").
-- Kind from the game data: summon (buffs summons only: SUMMON_BUFF), farm (a farm / money / income key
-- in its attacks), rotating (a cast buff - its active attack - that passes between copies), damage
-- (an always-on aura: support, or a buff with no cast).
PV.FARM_BUFF = {}
PV.SHORT_WAVES = 15      -- a stage with at most this many waves (and not infinite) is short: 1 copy each
PV.BUFF_STEP = 0.1       -- buff added per upgrade level (x the team damage / s it reaches): a guess, no number in the data
PV.SHORT_BUFF_LEVEL = 2  -- short stages: buff upgrades stop here (where the buff % stops growing much: a guess)
local function hasKey(v, words, depth)
    if type(v) ~= "table" or depth > 3 then return false end
    for k, x in pairs(v) do
        local key = string.lower(tostring(k))
        for _, w in ipairs(words) do if key:find(w, 1, true) then return true end end
        if hasKey(x, words, depth + 1) then return true end
    end
    return false
end
-- Kind of a buff / support unit from the game data, and why (for buff_units.txt):
--   rotating - role buff (no passives: it casts, the cast passes between copies - wendy / erwin
--              "<unit>:buff_units"): the full set (BuffNeed, usually 4), never upgraded
--   aura     - role support (passives: always on - hoshino Idol): exactly 1, upgraded to the top
--   summon   - buffs summons only (SUMMON_BUFF, or "summon" in its passives): 1 copy, only with a summoner down
--   farm     - a money buff (a farm / money / income key in its attacks): 1 copy, not upgraded
--   unknown  - no data: 1 copy (logged)
function PV.BuffKind(name)
    local base = AutoPlaceModule.BaseId(name)
    local def = AutoPlaceModule.UnitDef(name)
    if not def then return "unknown", "no unit data" end
    if AutoPlaceModule.SUMMON_BUFF[name] or AutoPlaceModule.SUMMON_BUFF[base] then return "summon", "SUMMON_BUFF list" end
    for _, ps in pairs(type(def.passives) == "table" and def.passives or {}) do
        local text = type(ps) == "table" and (tostring(ps.name or "") .. " " .. tostring(ps.description or "")) or tostring(ps)
        if string.lower(text):find("summon", 1, true) then return "summon", "passive: " .. text:sub(1, 40) end
    end
    local act, main = PV.Attack(name, "active_attack"), PV.Attack(name)
    local money = { "farm", "money", "income" }
    if PV.FARM_BUFF[name] or PV.FARM_BUFF[base] or hasKey(act, money, 1) or hasKey(main, money, 1) then return "farm", "money key in its attacks" end
    -- (the game's own split: a buff unit with passives is "support" - an always-on aura, hoshino; one without
    -- is "buff" - it casts its buff and the cast passes between copies, wendy / erwin: active_attack
    -- "<unit>:buff_units" in the real data)
    if AutoPlaceModule.RoleFromDef(name) == "support" then return "aura", "support: passives, always on" end
    return "rotating", "buff unit that casts" .. (type(def.active_attack) == "string" and (" (" .. def.active_attack .. ")") or "")
end
-- buff_units.txt: every buff / support unit in the game data with its kind and why, once per session
function PV.DumpBuffUnits()
    if PV.buffDumped or type(writefile) ~= "function" then return end
    PV.buffDumped = true
    AutoPlaceModule.UnitDef("")
    local lines = {}
    for id, def in pairs(unitDefsCache or {}) do
        local role = AutoPlaceModule.RoleFromDef(id)
        if (role == "buff" or role == "support") and (tonumber(def.cost) or 0) > 1 then
            local kind, why = PV.BuffKind(id)
            lines[#lines + 1] = string.format("%s | %s | %s | %s", id, tostring(def.name or "-"), kind, why)
        end
    end
    table.sort(lines)
    table.insert(lines, 1, string.format("# %d buff / support units | id | name | kind | why (Auto Place v2, %s)", #lines, os.date("%Y-%m-%d %H:%M")))
    pcall(function()
        if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(Config.Folder) then makefolder(Config.Folder) end
        writefile(Config.Folder .. "/buff_units.txt", table.concat(lines, "\n"))
    end)
end
-- Waves in this stage from the level data (math.huge = infinite; nil = unknown): its own count field,
-- else the waves table of src.Data.Waves[level.waves].
function PV.WaveCount()
    local key = stageKey()
    if PV.wavesFor == key then return PV.waves end
    PV.wavesFor, PV.waves = key, nil
    local ok, d = pcall(Stage.levelData)
    if not (ok and type(d) == "table") then return nil end
    -- (Dungeon Room and Infinity Mansion: 15 waves, though their level data carries _override_waves
    -- { infinite = true } - friend's room 2026-10-26 placed 4 Wendy and upgraded them all)
    local where = string.lower(tostring(State.stage or "") .. " " .. tostring(d.name or ""))
    if d._dungeon ~= nil or where:find("dungeon room", 1, true) or where:find("infinity mansion", 1, true) then PV.waves = 15 return PV.waves end
    if d.infinite == true or string.lower(tostring(d._gamemode or "")) == "infinite" then PV.waves = math.huge return PV.waves end
    for _, k in ipairs({ "wave_count", "max_wave", "max_waves", "waves_count", "_waves" }) do
        if tonumber(d[k]) then PV.waves = tonumber(d[k]) return PV.waves end
    end
    if type(d.waves) == "string" then
        pcall(function()
            local mod = ReplicatedStorage.src.Data:FindFirstChild("Waves")
            local mods = { mod }
            for _, m in ipairs(mod and mod:GetDescendants() or {}) do if m:IsA("ModuleScript") then mods[#mods + 1] = m end end
            for _, m in ipairs(mods) do
                local okR, t = pcall(require, m)
                local e = okR and type(t) == "table" and t[d.waves]
                if type(e) == "table" then
                    if e.infinite then PV.waves = math.huge return end
                    local n = 0
                    for _ in pairs(type(e.waves) == "table" and e.waves or {}) do n = n + 1 end
                    if n > 0 then PV.waves = n return end
                end
            end
        end)
    end
    return PV.waves
end
-- long = more than SHORT_WAVES waves, infinite, Fool's Hunt, or the wave count unknown
function PV.LongStage()
    if State.eventMode then return true end
    local n = PV.WaveCount()
    return n == nil or n > PV.SHORT_WAVES
end
-- damage units on the map outside every copy of this buff unit
function PV.OutOfBuffReach(name)
    local copies, out = {}, false
    for _, u in ipairs(ownedUnits()) do
        if unitType(u) == name then
            local p = rootPos(u)
            if p then copies[#copies + 1] = { p, math.max(BUFF_REACH, AutoPlaceModule.StatNum(u, "range") or unitReach(u) or 0) } end
        end
    end
    for _, u in ipairs(ownedUnits()) do
        local p = unitRole(u) == "dps" and rootPos(u)
        if p then
            local inside = false
            for _, c in ipairs(copies) do
                if (c[1].X - p.X) ^ 2 + (c[1].Z - p.Z) ^ 2 <= c[2] * c[2] then inside = true break end
            end
            if not inside then out = true end
        end
    end
    return out
end
-- Copies of a buff / support unit to place (owner 2026-10-26), the same on every stage length:
-- rotating the full set once 2+ damage units are down; aura 1 once a damage unit is down; summon 1 with a
-- summoner down, else 0; farm / unknown 1.
function PV.BuffCopies(t, placed)
    local kind = PV.BuffKind(t.name)
    local dps = PV.DpsDown()
    if kind == "summon" then return AutoPlaceModule.SummonerDown(ownedUnits()) and 1 or 0, kind end
    if kind == "rotating" then return dps >= 2 and AutoPlaceModule.BuffNeed(t) or 0, kind end
    if kind == "aura" then return dps >= 1 and 1 or 0, kind end
    return 1, kind
end
-- An upgrade of a buff / support unit, per yen (compared with the damage upgrades' damage / s per yen):
-- rotating never (level 0 already rotates); aura first, to the top; farm never; summon only with a summoner
-- down; summon / unknown by BUFF_STEP x the team damage / s in reach, and past SHORT_BUFF_LEVEL not on a
-- short stage.
function PV.BuffUpScore(u, level, cost)
    local name = unitType(u) or ""
    local kind = PV.BuffKind(name)
    if kind == "rotating" or kind == "farm" then return 0 end
    if kind == "aura" then return 1e6 end
    if kind == "summon" and not AutoPlaceModule.SummonerDown(ownedUnits()) then return 0 end
    if not PV.LongStage() and level >= PV.SHORT_BUFF_LEVEL then return 0 end
    local p = rootPos(u)
    if not p then return 0 end
    local reach = math.max(BUFF_REACH, AutoPlaceModule.StatNum(u, "range") or 0)
    local dps = 0
    for _, o in ipairs(ownedUnits()) do
        local q = unitRole(o) == "dps" and rootPos(o)
        if q and (q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2 <= reach * reach then
            local def = AutoPlaceModule.UnitDef(unitType(o) or "") or {}
            dps = dps + (AutoPlaceModule.StatNum(o, "damage") or tonumber(def.damage) or 0)
                / math.max(0.1, AutoPlaceModule.StatNum(o, "attack_cooldown") or AutoPlaceModule.DefCd(def))
        end
    end
    return PV.BUFF_STEP * dps / math.max(1, cost or 1)
end

-- an air-capable damage unit of ours on the map (flyers: upgrades go to those - upgradeStep)
function PV.AirDown()
    for _, u in ipairs(ownedUnits()) do
        if unitRole(u) == "dps" and AutoPlaceModule.AirCapable(unitType(u) or "", AutoPlaceModule.StatNum(u, "upgrade") or 0) then return true end
    end
    return false
end
-- flyers matter now: air need, flyers on the map, or most enemies seen this stage fly
function PV.AirStage()
    return AutoPlaceModule.airNeed == true or AutoPlaceModule.flying ~= nil
        or (AutoPlaceModule.seenFly or 0) / math.max(1, AutoPlaceModule.seenN or 0) >= 0.5
end

-- Timing (owner 2026-10-25, work/placement_method.md "Timing"): act on the money change, farm upgrades
-- before the wave's payout, air upgrades at once while flyers are on the map, and a per-wave log.
PV.END_SECONDS = 2.5   -- a wave timer counting down to this or less: the wave is ending
PV.END_ENEMIES = 1     -- or this many enemies left, once the wave has had 3+ on the map and is 5+ s old
-- the wave timer: workspace._wave_time or LP._stats.wave_timer; counting down when it went down lately
function PV.WaveTimer()
    local v = workspace:FindFirstChild("_wave_time")
    local t = v and tonumber(v.Value)
    if not t then
        local st = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("_stats")
        local w = st and st:FindFirstChild("wave_timer")
        t = w and tonumber(w.Value)
    end
    if not t then return nil end
    local now = os.clock()
    if PV.wtLast and t < PV.wtLast.v then PV.wtDown = now end
    if not PV.wtLast or t ~= PV.wtLast.v then PV.wtLast = { v = t, at = now } end
    return t, PV.wtDown ~= nil and now - PV.wtDown < 3
end
function PV.WaveEnding()
    local t, down = PV.WaveTimer()
    if t and down and t > 0 and t <= PV.END_SECONDS then return true end
    local w = AutoPlaceModule.WaveNumber()
    if PV.endWave ~= w then PV.endWave, PV.endSeen, PV.endAt = w, 0, os.clock() end
    local n = 0
    local folder = unitsFolder()
    for _, e in ipairs(folder and folder:GetChildren() or {}) do if isEnemy(e) then n = n + 1 end end
    PV.endSeen = math.max(PV.endSeen, n)
    return PV.endSeen >= 3 and os.clock() - PV.endAt >= 5 and n <= PV.END_ENEMIES
end

-- The money value as an instance (for its Changed signal): the learned path, else LP._stats.resource.
function PV.MoneyValue()
    local path = AutoPlace.moneyPath or "LP._stats.resource"
    local instPath, attr = path:match("^(.-)@(.+)$")
    instPath = instPath or path
    local current, rest = game, instPath
    if instPath:sub(1, 2) == "LP" then current, rest = Players.LocalPlayer, instPath:sub(3) end
    for segment in rest:gmatch("[^%.]+") do
        if not (current == game and segment == "game") then
            current = current and current:FindFirstChild(segment)
        end
    end
    return current, attr
end
-- money crossing what the last tick waits for (AutoPlaceModule.nextCost) wakes the Auto Place loop at once;
-- the moment it became affordable is kept for the lag log
function PV.WatchMoney()
    local ok, inst, attr = pcall(PV.MoneyValue)
    if not ok then inst = nil end
    if inst == PV.moneyInst then return end
    if PV.moneyConn then pcall(function() PV.moneyConn:Disconnect() end) end
    PV.moneyInst, PV.moneyConn = inst, nil
    if not inst then return end
    pcall(function()
        local sig = attr and inst:GetAttributeChangedSignal(attr) or inst.Changed
        PV.moneyConn = sig:Connect(function()
            local v = tonumber(attr and inst:GetAttribute(attr) or inst.Value)
            local need = AutoPlaceModule.nextCost
            -- (flyers on the map: any money gain may pay an air upgrade - the loop looks at once)
            local gain = v and PV.seenMoney and v > PV.seenMoney
            PV.seenMoney = v
            if gain and AutoPlaceModule.flying then AutoPlaceModule.wake = true end
            if v and need and v >= need then
                AutoPlaceModule.wake = true
                PV.affordAt = PV.affordAt or os.clock()
            end
        end)
    end)
end
-- what a tick waits for (a price): wakes the loop when the money reaches it; also starts the lag clock
-- when it is affordable already
function PV.WaitFor(cost, money)
    cost = tonumber(cost)
    if not cost then return end
    AutoPlaceModule.nextCost = math.min(AutoPlaceModule.nextCost or math.huge, cost)
    if money and money >= cost then PV.affordAt = PV.affordAt or os.clock() end
end
-- a placement / upgrade done: the lag since it became affordable goes into this wave's log
PV.waveLog = {}
function PV.Acted()
    if PV.affordAt then
        local lag = os.clock() - PV.affordAt
        PV.waveLag = math.max(PV.waveLag or 0, lag)
    end
    PV.affordAt = nil
end
-- once a tick: a new wave closes the last one's row (money left unspent at its end, the worst lag)
function PV.WaveStep(money)
    local w = AutoPlaceModule.WaveNumber()
    if w < (PV.logWave or 0) then PV.waveLog = {} PV.FastWave(true) PV.u4, PV.carryRow, PV.peak = nil, 0, {} end
    if PV.logWave and w > PV.logWave then
        PV.FastWave(false)
        table.insert(PV.waveLog, { wave = PV.logWave, unspent = PV.lastMoney and math.floor(PV.lastMoney) or -1,
            lag = math.floor((PV.waveLag or 0) * 100 + 0.5) / 100 })
        while #PV.waveLog > 40 do table.remove(PV.waveLog, 1) end
        PV.waveLag = 0
    end
    PV.logWave, PV.lastMoney = w, money
    if w >= 4 and not PV.u4 then PV.u4 = #ownedUnits() end
end

-- Summoners (owner 2026-10-26, work/placement_method.md "Summoners"): their summons run along the road and
-- do the damage (Elyssia's jellyfish), so a summoner is not judged by its own range: it stands right beside
-- the road where its summons enter it and meet the enemies early.
PV.SUMMON_SIDE = 4.5   -- at most this far from the road
PV.SUMMON_AT = 0.4     -- road position aimed for (0 enemy end, 1 our base): early enough to meet them, a guess
PV.SUMMON_AIR = { elyssia = true, elyssia_evolved = true } -- owner 2026-10-26: the jellyfish hit flyers too (not in the data)
-- its summons' definitions: units named "<its id>_..." with no price (elyssia_jellyfish, elyssia_eel)
function PV.Summons(name)
    local base = AutoPlaceModule.BaseId(name)
    AutoPlaceModule.UnitDef("")
    PV.summonsOf = PV.summonsOf or {}
    if PV.summonsOf[base] then return PV.summonsOf[base] end
    local out = {}
    for id, def in pairs(unitDefsCache or {}) do
        local mine = (id ~= base and id:sub(1, #base + 1) == base .. "_" and not id:find("evolved", 1, true))
            or (id ~= name and id:sub(1, #name + 1) == name .. "_")
        if mine and (tonumber(def.cost) or 0) <= 1 then out[#out + 1] = def end
    end
    PV.summonsOf[base] = out
    return out
end
function PV.IsSummoner(name)
    local def = AutoPlaceModule.UnitDef(name) or {}
    return def.spawn_unit == true or def.spawn_script ~= nil or #PV.Summons(name) > 0
end
-- its summons hit flyers: one of them is a hill / hybrid unit, or the owner's list
function PV.SummonAir(name)
    if PV.SUMMON_AIR[name] or PV.SUMMON_AIR[AutoPlaceModule.BaseId(name)] then return true end
    if not PV.IsSummoner(name) then return false end
    for _, def in ipairs(PV.Summons(name)) do
        if def.hybrid_placement == true or def.hill_unit == true then return true end
    end
    return false
end
-- distance to the nearest road point and that point's road position
function PV.RoadSpot(x, z, road)
    local bd, bp = math.huge, 0
    for _, q in ipairs((road or PV.Road()).pts) do
        local d = (q[1] - x) ^ 2 + (q[3] - z) ^ 2
        if d < bd then bd, bp = d, q.p end
    end
    return math.sqrt(bd), bp
end
-- a summoner's spots: within SUMMON_SIDE of the road, nearest SUMMON_AT along it first; the rest after
function PV.SummonRank(free)
    local road = PV.Road()
    local near, far = {}, {}
    for _, c in ipairs(free) do
        local d, p = PV.RoadSpot(c.x, c.z, road)
        local e = { c = c, cov = 0, p = p, d = d }
        if d <= PV.SUMMON_SIDE then near[#near + 1] = e else far[#far + 1] = e end
    end
    table.sort(near, function(a, b)
        local ka, kb = math.abs(a.p - PV.SUMMON_AT), math.abs(b.p - PV.SUMMON_AT)
        if math.abs(ka - kb) > 1e-6 then return ka < kb end
        return a.d < b.d
    end)
    table.sort(far, function(a, b) return a.d < b.d end)
    for _, e in ipairs(far) do near[#near + 1] = e end
    return near
end
-- a summoner on the map, for the logs: its road distance (studs) and road position (0-100); nil otherwise
function PV.RoadRow(u)
    if State.eventMode or not PV.IsSummoner(unitType(u) or "") then return nil, nil end
    local p = rootPos(u)
    if not p then return nil, nil end
    local d, rp = PV.RoadSpot(p.X, p.Z)
    return math.floor(d * 10 + 0.5) / 10, math.floor(rp * 100 + 0.5)
end

-- Finish fast (owner 2026-10-26, work/placement_method.md "Finish fast"): a team that is clearly strong
-- (margin >= MARGIN_HIGH 2 waves in a row, base never hit this game) puts its later damage units (not
-- the carry) in the front half of the road, so waves die sooner and auto-skip ends them early. A base
-- hit or a margin under MARGIN_LOW goes back to the base half. Mode: Safe = never, Balanced = this rule,
-- Fast clear = from the first wave the margin is high.
PV.highStreak, PV.waveHigh, PV.baseHit = 0, false, false
-- from PV.Spend: what the margin said this tick
function PV.FastNote(margin, danger)
    if danger then PV.baseHit = true end
    if margin and margin >= PV.MARGIN_HIGH then PV.waveHigh = true end
    if margin and margin < PV.MARGIN_LOW then PV.highStreak, PV.waveHigh = 0, false end
end
-- from PV.WaveStep: a wave ended (new = a new game)
function PV.FastWave(new)
    if new then PV.highStreak, PV.waveHigh, PV.baseHit = 0, false, false return end
    PV.highStreak = PV.waveHigh and PV.highStreak + 1 or 0
    PV.waveHigh = false
end
function PV.FinishFast()
    -- (the setting itself, not Mode(): that turns Balanced into Safe on every Hard stage)
    local mode = AutoPlace.placeMode
    if State.eventMode or mode == "Safe" or PV.baseHit then return false end
    local need = mode == "Fast clear" and 1 or 2
    return PV.highStreak >= need or (mode == "Fast clear" and PV.waveHigh)
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

-- Control skills (time stop / freeze / stun) one at a time (owner 2026-10-26): two homura time
-- stops fired together waste one - the enemies are already stopped, and after a stop they stay
-- immune a moment. The next copy casts only once the running stop has ENDED plus the immunity gap.
-- The end is seen, not guessed: enemy spots are taken 0.4 s and 0.8 s after the cast; the stop has
-- ended when most of them move again. Enemies that never stopped = a wasted cast. Stop length and
-- gap: skill data when it has them, else measured and remembered (AutoPlace.stopTimes), else 3 s gap.
ControlUp.STOP_GAP = 3
ControlUp.stats = setmetatable({}, { __mode = "k" }) -- [control unit] = { casts, wasted }
function ControlUp.skillId(u)
    local st = u:FindFirstChild("_stats")
    local a = st and st:FindFirstChild("active_attack")
    return a and tostring(a.Value) or "?"
end
-- A number in the skill's Attacks entry (one level deep) whose key holds one of the words.
function ControlUp.dataNum(u, words)
    local id = ControlUp.skillId(u)
    local ok, entry = pcall(function()
        local m = ReplicatedStorage.src.Data:FindFirstChild("Attacks")
        local mod = m and require(m)
        return type(mod) == "table" and mod[id] or nil
    end)
    if not (ok and type(entry) == "table") then return nil end
    local function look(t)
        for k, v in pairs(t) do
            local key = string.lower(tostring(k))
            for _, w in ipairs(words) do
                if key:find(w, 1, true) and tonumber(v) then return tonumber(v) end
            end
        end
    end
    local n = look(entry)
    if n then return n end
    for _, v in pairs(entry) do if type(v) == "table" then n = look(v) if n then return n end end end
    return nil
end
function ControlUp.gap(u)
    local t = (AutoPlace.stopTimes or {})[ControlUp.skillId(u)] or {}
    return ControlUp.dataNum(u, { "immun" }) or t.gap or ControlUp.STOP_GAP
end
function ControlUp.reach(u)
    local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
    return (AutoPlaceModule.StatNum(u, "range") or tonumber(def.range) or DEFAULT_RANGE) * (AutoPlaceModule.StatNum(u, "range_multiplier") or 1)
end
function ControlUp.enemySpots()
    local out = {}
    local folder = unitsFolder()
    for _, e in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(e) then
            local p = rootPos(e)
            if p then out[e] = p end
        end
    end
    return out
end
-- Enemies inside this copy's reach right now.
function ControlUp.inReach(u, spots)
    local p = rootPos(u)
    if not p then return 0 end
    local r = ControlUp.reach(u)
    local n = 0
    for _, q in pairs(spots or ControlUp.enemySpots()) do
        if (q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2 <= r * r then n = n + 1 end
    end
    return n
end
-- Share of the enemies seen in both snapshots that moved more than 0.3 studs.
local function movedShare(a, b)
    local both, moved = 0, 0
    for e, p in pairs(a) do
        local q = b[e]
        if q then
            both = both + 1
            if (q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2 > 0.09 then moved = moved + 1 end
        end
    end
    return both, moved
end
function ControlUp.Cast(u, now)
    ControlUp.stop = { unit = u, id = ControlUp.skillId(u), at = now }
    local s = ControlUp.stats[u] or { casts = 0, wasted = 0 }
    ControlUp.stats[u] = s
    s.casts = s.casts + 1
end
-- Follows the running stop: wasted / still holding / ended (and remembers how long it lasted).
function ControlUp.Watch(now)
    local st = ControlUp.stop
    if not st or st.endedAt then return end
    AutoPlace.stopTimes = AutoPlace.stopTimes or {}
    local times = AutoPlace.stopTimes[st.id] or {}
    -- (two snapshots after the stop has landed - it lands a moment after the cast, and the step taken
    -- in between made every cast look wasted)
    if not st.start then
        if now - st.at >= 0.4 then st.start = ControlUp.enemySpots() end
        return
    end
    if not st.snap then
        if now - st.at < 0.8 then return end
        st.snap = ControlUp.enemySpots()
        local both, moved = movedShare(st.start, st.snap)
        if both > 0 and moved * 2 > both then
            -- they kept walking: nothing stopped (still immune, or the skill missed them)
            st.endedAt, st.wasted = st.at, true
            local s = ControlUp.stats[st.unit]
            if s then s.wasted = s.wasted + 1 end
            local prev = ControlUp.prevEnd
            if prev and st.at - prev < 15 then
                times.gap = math.max(times.gap or ControlUp.STOP_GAP, st.at - prev + 1)
                AutoPlace.stopTimes[st.id] = times
            end
            AutoPlaceModule.Note(string.format("%s's stop did nothing (enemies kept moving)", unitType(st.unit) or "?"))
        end
        return
    end
    local both, moved = movedShare(st.snap, ControlUp.enemySpots())
    local guess = ControlUp.dataNum(st.unit, { "duration", "stop_time", "freeze_time", "stun_time" }) or times.dur or 6
    if (both > 0 and moved * 2 > both) or (both == 0 and now - st.at > guess + 1) or now - st.at > 30 then
        st.endedAt = now
        ControlUp.prevEnd = now
        if both > 0 then
            times.dur = math.floor((now - st.at) * 10 + 0.5) / 10
            AutoPlace.stopTimes[st.id] = times
        end
    end
end
-- No stop running, and the last one ended at least its gap ago.
function ControlUp.Clear(now)
    local st = ControlUp.stop
    if not st then return true end
    if not st.endedAt then return false end
    return st.wasted or now - st.endedAt >= ControlUp.gap(st.unit)
end
-- For the dump: each control unit's level, cooldown, reach, casts and wasted casts.
AutoPlaceModule.ControlReport = function() return ControlUp.Report() end
function ControlUp.Report()
    local out = {}
    for _, u in ipairs(ownedUnits()) do
        if BuffRot.isControlSkill(u) then
            local s = ControlUp.stats[u] or { casts = 0, wasted = 0 }
            out[#out + 1] = { id = unitType(u), level = AutoPlaceModule.StatNum(u, "upgrade") or 0,
                cd = AutoPlaceModule.StatNum(u, "active_attack_cooldown"), reach = ControlUp.reach(u),
                casts = s.casts, wasted = s.wasted, skill = ControlUp.skillId(u) }
        end
    end
    return out
end

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
-- road length (studs) under which a map counts as short (a first guess: tuned from the noted lengths)
AutoPlaceModule.SHORT_ROAD = 350
AutoPlaceModule.FARM_COUNT = { speedwagon = 3, bulma = 1 }
AutoPlaceModule.GOLDEN_MONEY = 1.5 -- Golden trait: money x this (a guess - the game data has no number)
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
-- (1.0 left Magic Town games with 9-12 units: middle units are X'd only when far weaker)
AutoPlaceModule.WEAK_SHARE, AutoPlaceModule.WEAK_SHARE_EARLY = 0.5, 0.2
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
AutoPlaceModule.dropAt = {}
function AutoPlaceModule.DropCopy(t, why)
    local bar = Lobby.SpellSlotBar and Lobby.SpellSlotBar()
    local x = bar and bar:FindFirstChild(tostring(t.slot))
    x = x and x:FindFirstChild("Delete", true)
    -- (a tap that missed - a panel over the bar - left the copy there for good when it was marked
    -- gone at once: now it is tapped again 5 s later while it is still on the bar - owner 2026-10-24)
    AutoPlaceModule.dropAt[t.uuid] = os.clock()
    if not (State.eventMode and Lobby.cfg.eventBrain ~= false) or not x then AutoPlaceModule.badTemp[t.uuid] = true end
    AutoPlaceModule.hotbarAt, AutoPlaceModule.hotbarSig = 0, nil
    if x then Lobby.TapGui(x) end
    AutoPlaceModule.Note(string.format("copy cleared: %s (%s)", t.name, why))
end

AutoPlaceModule.SUMMON_BUFF = { giselle_evolved = true, giselle = true }
-- owner 2026-10-24: saber carries the early game, 2 upgrades are enough; pucci is placed when money
-- is left over and then upgraded to the top (its skill speeds up the team's attacks)
-- (jiraiya and emilia slow the enemies: placed, never upgraded)
-- (owner: before judar comes, bee_girl and sakamoto are both upgraded; then judar only)
-- (Siren / monet carries instead when no bee_girl came - owner)
AutoPlaceModule.EARLY_CARRY = { bee_girl_evolved = true, sakamoto_evolved = true, monet_evolved = true }
-- (nagumo cuts HP: placed whenever it comes, no upgrades - owner 2026-10-24)
AutoPlaceModule.UP_CAP = { saber_evolved = 2, jiraiya_evolved = 0, emilia = 0, nagumo_evolved = 0 }
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
            if can and cost then
                local v = upgradeGain(u, level) / math.max(1, cost)
                -- (the same main-unit weight as upgradeStep in Fool's Hunt)
                local kind = unitType(u) or ""
                if State.eventMode and (AutoPlaceModule.InList(AutoPlaceModule.RANK, kind) or (AutoPlaceModule.WaveNumber() >= 8 and AutoPlaceModule.AirCapable(kind, math.huge))) and not AutoPlaceModule.UP_CAP[kind] then v = v * 10 end
                if State.eventMode and AutoPlaceModule.UP_CAP[kind] and level >= AutoPlaceModule.UP_CAP[kind] then v = 0 end
                best = math.max(best, v)
            end
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
AutoPlaceModule.upNeed = setmetatable({}, { __mode = "k" })
-- Hard stage with no damage unit at HARD_CARRY_LEVEL yet: damage upgrades before farm ones.
-- Range a unit really gets (normal stages, owner 2026-10-25): data range at an upgrade level (the last
-- upgrade entry with a range at or below it), the run's range buffs seen on our placed units (median of
-- their _stats.range / data range at their level, 1 - 1.6), and for the carry the range at PLAN_LEVEL
-- (cid went down with 19 and had 28-30 at level 3-5). Rolls and traits are in Range(t) already.
AutoPlaceModule.PLAN_LEVEL = 3
function AutoPlaceModule.DefRangeAt(name, level)
    local def = AutoPlaceModule.UnitDef(name) or {}
    local r = tonumber(def.range) or DEFAULT_RANGE
    if type(def.upgrade) == "table" then
        for i = 1, math.min(level or 0, #def.upgrade) do
            local up = def.upgrade[i]
            if type(up) == "table" and tonumber(up.range) then r = tonumber(up.range) end
        end
    end
    return r
end
function AutoPlaceModule.RangeBuff()
    local ratios = {}
    for _, u in ipairs(ownedUnits()) do
        local real = AutoPlaceModule.StatNum(u, "range")
        local base = AutoPlaceModule.DefRangeAt(unitType(u) or "", AutoPlaceModule.StatNum(u, "upgrade") or 0)
        if real and base and base > 0 then ratios[#ratios + 1] = real / base end
    end
    if #ratios < 2 then return 1 end
    table.sort(ratios)
    return math.max(1, math.min(1.6, ratios[math.ceil(#ratios / 2)]))
end
function AutoPlaceModule.CarryName()
    local t = PV.Carry()
    return t and t.name
end
function AutoPlaceModule.PlanRange(t)
    local r = AutoPlaceModule.Range(t)
    if State.eventMode then return r end
    -- (a placed copy's _stats.range already has the buffs and its level)
    if not (t.placedSample and t.placedSample.Parent) then
        r = r * AutoPlaceModule.RangeBuff()
        if t.name == AutoPlaceModule.CarryName() then
            local now = AutoPlaceModule.DefRangeAt(t.name, 0)
            if now > 0 then r = r * AutoPlaceModule.DefRangeAt(t.name, AutoPlaceModule.PLAN_LEVEL) / now end
        end
    end
    return r
end

-- After a damage unit goes down (normal stages): cov / best = the road in its reach against the best spot
-- for its range and shape on this map. BAD_SPOT under BAD_COVER: noted, counted for the shared game row
-- (bad) and kept for the dump - measurement only, it steers nothing.
AutoPlaceModule.badLog, AutoPlaceModule.badCount = {}, 0
AutoPlaceModule.BAD_COVER = 0.7
function AutoPlaceModule.CheckSpot(name, spot, range)
    if State.eventMode or not range or range <= 0 or PV.IsSummoner(name) then return end
    local road = PV.Road()
    if #road.pts < 8 then return end
    local w = AutoPlaceModule.WaveNumber()
    if w < (AutoPlaceModule.badWave or 0) then AutoPlaceModule.badLog, AutoPlaceModule.badCount = {}, 0 end
    AutoPlaceModule.badWave = w
    if not candidates then candidates, candidatesFor = buildCandidates(pathPoints()), #pathPoints() end
    local shape = PV.Shape(name)
    local cov, prog = PV.Cover(spot, range, shape, road)
    local best = PV.Best(range, shape, candidates)
    if best <= 0 or cov >= AutoPlaceModule.BAD_COVER * best then return end
    AutoPlaceModule.badCount = AutoPlaceModule.badCount + 1
    table.insert(AutoPlaceModule.badLog, { unit = name, cov = math.floor(cov), best = math.floor(best), score = math.floor(100 * cov / best + 0.5),
        prog = math.floor(prog * 100 + 0.5), wave = w, x = math.floor(spot.x), z = math.floor(spot.z), range = range })
    AutoPlaceModule.Note(string.format("BAD_SPOT %s cov %d of best %d studs (%d%%) at %d%% along the road", name, math.floor(cov),
        math.floor(best), math.floor(100 * cov / best + 0.5), math.floor(prog * 100 + 0.5)))
end
local function upgradeStep(money, onlyRole, airOnly, noWait, waitCap, onlyUnit)
    local remote = getAARemote("upgrade_unit_ingame")
    -- (normal stages: flyers on the map - upgrades only on units that hit them, when one is down; farms by their own call)
    if not State.eventMode and PV.AirStage() and (onlyRole == "dps" or onlyRole == nil) and PV.AirDown() then airOnly = true end
    if not remote then return nil end
    -- (owner 2026-10-24: the always-on aura unit (hoshino) is placed early and upgraded to the top
    -- once the damage units are; rotation buffers never)
    local RANK = { farm = 1, dps = 2, support = 3 }
    local pick, pickLevel, pickRank, pickCost, pickScore, pickRole, pickAir
    -- flying enemies on the map: damage units that can hit them (after this upgrade) go first
    local air = AutoPlaceModule.airNeed == true
    local now = os.clock()
    local units = ownedUnits()
    local focus = ControlUp.focus(units, now)
    local fuse = ControlUp.fusionFocus(units)
    local summonerDown = AutoPlaceModule.SummonerDown(units)
    -- (Fool's Hunt: ONE carry gets the upgrades first - a main unit when one is down, else the one
    -- strongest at full upgrade; spread over many, the early damage was never enough - owner)
    local carry, carryV, carry2, carry2V
    if State.eventMode then
        for _, o in ipairs(units) do
            local k = unitType(o) or ""
            local lv = AutoPlaceModule.StatNum(o, "upgrade") or 0
            local more = nextUpgrade(o, lv)
            if unitRole(o) == "dps" and not AutoPlaceModule.UP_CAP[k] and more and (upgradeFails[o] or 0) < now
                and not AutoPlaceModule.InList(Lobby.cfg.eventNever, k) then
                -- (the owner's list order first - cid before Siren - then strength)
                local at = 0
                for i, n in ipairs(AutoPlaceModule.RANK) do if n == k then at = #AutoPlaceModule.RANK - i + 1 end end
                local v = at * 1e12 + (AutoPlaceModule.MaxDps(k) or 0)
                -- (owner: the first carry is best one that hits flyers too - maxed before flyers come at wave 10)
                -- (owner: bee_girl carries the early game only; from wave 8 judar gets everything to the top)
                local w = AutoPlaceModule.WaveNumber()
                if not carry or v > carryV then carry, carryV, carry2, carry2V = o, v, carry, carryV
                elseif not carry2 or v > carry2V then carry2, carry2V = o, v end
            end
        end
    end
    -- (owner: before wave 10, no damage upgrade unless the carry is a main or an early carry -
    -- medea, archer, gyutaro were upgraded for nothing while the enemies were still easy)
    local carryKind = carry and unitType(carry) or ""
    -- (owner 2026-10-24: with no judar / cid down, one carry alone was too little - sakamoto at 2-7,
    -- everything else at 0, lost at waves 11-15; the next best one is upgraded along with it)
    -- (2026-10-25 03:30: the second carry and the farm wait were taken back - shared data: after them,
    -- Snowy Town fell from wave 24 on average (3 games) to wave 14 (7 games))
    carry2 = nil
    -- (late spare money goes to the other damage units too: from wave 25, with over twice the
    -- carry's next upgrade in hand. Shared data 2026-10-25: wave-30 wins had 411k-717k team DPS at
    -- wave 29, losses 218k-416k, and one loss sat on 48k unspent)
    local spare = false
    if State.eventMode and carry and AutoPlaceModule.WaveNumber() >= 25 then
        local _, c2 = nextUpgrade(carry, AutoPlaceModule.StatNum(carry, "upgrade") or 0)
        spare = c2 ~= nil and (money or 0) >= 2 * c2
    end
    -- (farm upgrades wait from wave 5 while the carry is below level 3: bulma reached 6 with
    -- sakamoto at 2, lost at wave 11)
    local carryLow = false
    -- (not once the base is hit, and only to wave 5 on a short road: on Snowy Town every damage unit
    -- sat at level 0 while bulma reached 5, lost at wave 7)
    local earlyNoCarry = State.eventMode and not AutoPlaceModule.danger
        -- (to wave 6 only, 4 on a short road: solo games with no main on the bar left every damage
        -- unit at level 0 while the farms reached 4, and died at waves 8-11 - shared data 2026-10-25)
        and AutoPlaceModule.WaveNumber() < (AutoPlaceModule.shortRoad and 4 or 6)
        and AutoPlaceModule.UnitDef("judar_evolved") ~= nil -- (only with the owner's roster in the game data)
        and not (AutoPlaceModule.EARLY_CARRY[carryKind] or (AutoPlaceModule.InList(AutoPlaceModule.RANK, carryKind) and not AutoPlaceModule.UP_CAP[carryKind]))
    local topOf = {}
    for _, o in ipairs(units) do
        local k = unitType(o) or ""
        topOf[k] = math.max(topOf[k] or 0, AutoPlaceModule.StatNum(o, "upgrade") or 0)
    end
    for _, u in ipairs(units) do
        local role = unitRole(u)
        -- (owner: a Never unit is not upgraded either - akainu and Cream get slower with upgrades)
        local never = State.eventMode and AutoPlaceModule.InList(Lobby.cfg.eventNever, unitType(u))
        local capLvl = AutoPlaceModule.UP_CAP[unitType(u) or ""]
        if State.eventMode and Lobby.shieldTaken and AutoPlaceModule.ShieldBreaker(unitType(u) or "") and not AutoPlaceModule.InList(AutoPlaceModule.RANK, unitType(u)) then capLvl = 0 end
        if capLvl and (AutoPlaceModule.StatNum(u, "upgrade") or 0) >= capLvl then never = true end
        if (role ~= "buff" or not State.eventMode) and not never and (not onlyRole or role == onlyRole) and (not onlyUnit or u == onlyUnit) and (upgradeFails[u] or 0) < now and ControlUp.allowed(u, focus)
            and not AutoPlaceModule.OutOfReach(u) then
            local stats = u:FindFirstChild("_stats")
            local lvl = stats and stats:FindFirstChild("upgrade")
            local level = lvl and tonumber(lvl.Value) or 0
            local can, cost = nextUpgrade(u, level)
            -- (no price in the data: the least it can be, learned from the game refusing it)
            local need = AutoPlaceModule.upNeed[u]
            if not cost and need and need.level == level then cost = need.money end
            -- a farm upgrade must pay back in time (friend's Infinity Mansion loss: ~60k in farms
            -- by wave 9, Bulma at 6, the damage units barely upgraded)
            if can and role == "farm" and not AutoPlaceModule.FarmPays(u, level, cost) then can = false end
            -- (hard room: the carry waits at HARD_LEVEL for the first damage units - PV.CarryHold)
            if can and PV.CarryHold(u, level) then can = false end
            -- (spare money only: an upgrade it cannot pay must not block one it can - a farm's
            -- 6500 upgrade held 30k unused in a real game)
            if can and noWait and cost and money and cost > money then can = false end
            -- (waitCap: the most it may save up for; above it the money goes elsewhere)
            if can and waitCap and cost and cost > waitCap and not (money and cost <= money) then can = false end
            if can then
                local rank = AutoPlaceModule.UP_FIRST[unitType(u) or ""] and 1 or RANK[role] or 2
                -- (an upgrade price not in the data: about the unit's price times the next level)
                local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
                local guess = (tonumber(def.cost) or 1000) * (level + 1)
                local score = (rank == 2) and (upgradeGain(u, level) / math.max(1, cost or guess)) or -level
                -- (normal stages: a buff / support upgrade competes with the damage upgrades by the damage it adds)
                local buffUp = not State.eventMode and (role == "buff" or role == "support")
                if buffUp then rank, score = 2, PV.BuffUpScore(u, level, cost or guess) end
                -- fusion halves go by value like everything else (Vegito is only ~16% more than
                -- the two at level 7, a forced push starved better upgrades: near loss in Hard
                -- Room 45); a level that adds no damage (Vego 6) still moves on toward the fusion
                if rank == 2 and fuse[u] then score = math.max(score, 1e-6) end
                -- (owner 2026-10-24: the Unique-trait unit is upgraded first, to the top)
                if rank == 2 and score > 0 and AutoPlaceModule.HasTrait(u, "unique") then score = score * 1e6 end
                -- (owner: giselle also raises summons' damage - worth twice its own gain while a
                -- summoner such as elyssia is down)
                if AutoPlaceModule.SUMMON_BUFF[unitType(u) or ""] and summonerDown then score = score * 2 end
                -- (owner: in Fool's Hunt the main units are pushed to the top first; the early ones
                -- took the money and the mains stayed low - a lost game 2026-10-24)
                if State.eventMode and rank == 2 and score > 0 then
                    local kind = unitType(u) or ""
                    -- (the leading copy of a kind first: fujitora x3 all at level 2 helps less than one at 6)
                    if level < (topOf[kind] or 0) then score = score * 0.3 end
                    -- (from wave 8 the units that hit flyers count as mains too: two metal_knights sat at
                    -- level 0 and a flyer took the game at wave 12)
                    local airMain = AutoPlaceModule.WaveNumber() >= 8 and AutoPlaceModule.AirCapable(kind, math.huge)
                    if (AutoPlaceModule.InList(AutoPlaceModule.RANK, kind) or airMain) and not AutoPlaceModule.UP_CAP[kind] then score = score * 10
                    else score = score * 0.3 end
                    -- (owner: one unit to the top at a time - every other damage upgrade waits)
                    if carry and u ~= carry and u ~= carry2 and not spare then score = 0 end
                end
                local isAir = air and role == "dps" and AutoPlaceModule.AirCapable(unitType(u), level + 1)
                    and not (AutoPlaceModule.airRealInTeam and AutoPlaceModule.IsTrap(unitType(u)))
                if airOnly and not isAir then
                    -- skip: only units that hit flyers this time
                elseif State.eventMode and rank == 2 and earlyNoCarry then
                    -- skip: early game with no main / early carry down - money goes to farms and the mains to come
                elseif State.eventMode and rank == 1 and carryLow then
                    -- skip: the carry gets to level 3 before more farm upgrades
                elseif State.eventMode and carry and rank == 2 and u ~= carry and u ~= carry2 and not spare
                    and not (unitType(carry) ~= "judar_evolved" and unitType(carry) ~= "cid_evolved" and AutoPlaceModule.EARLY_CARRY[unitType(u) or ""]) then
                    -- skip: the carry goes to the top first
                elseif buffUp and score <= 0 then
                    -- skip: this buff adds nothing worth its price now
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
        PV.WaitFor(pickCost, money)
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
        PV.Acted()
        -- (any copy of the carry's unit counts: cid had three copies upgraded in turn)
        if not State.eventMode then PV.carryRow = unitType(pick) == (PV.Carry() or {}).name and (PV.carryRow or 0) + 1 or 0 end
        AutoPlaceModule.Note(string.format("upgraded %s to %d (%s%s)", unitType(pick), pickLevel + 1, pickRole,
            pickAir and ", hits flying enemies" or fuse[pick] and ", for the fusion" or BuffRot.isControlSkill(pick) and ", skill copy first" or (pickRank == 2 and ", most damage per ¥" or "")))
    elseif not pickCost and State.eventMode and money then
        -- (no price in the data and refused: it costs more than the money we had - saved for
        -- instead of skipped; judar's 18000 upgrade never came, cheaper ones took the money)
        AutoPlaceModule.upNeed[pick] = { level = pickLevel, money = math.floor(money) + 1 }
        AutoPlaceModule.Note(string.format("%s upgrade costs over %d - saving for it", unitType(pick), math.floor(money)))
    elseif not (pickCost and money and money < pickCost) then
        -- refused with the money in hand: leave this unit for 30 s instead of retrying forever
        upgradeFails[pick] = now + 30
        AutoPlaceModule.Note(string.format("could not upgrade %s - skipped for 30 s", unitType(pick)))
    end
    return pickCost and 0.1 or 1.5
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
    if AutoPlaceModule.FARM_COUNT[AutoPlaceModule.BaseId(t.name)] then return "farm" end
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
    -- (Fool's Hunt: farms to the top early, none after wave 10 - a bulma maxed at ~39k by wave 13
    -- left the damage units at levels 0-2 and the game was lost)
    -- (a hard stop at wave 10 left a bulma placed late at level 0 with 26k in hand at wave 21:
    -- an upgrade is bought whenever it pays back 1.5x before wave 30)
    if State.eventMode then
        local def = AutoPlaceModule.UnitDef(unitType(u))
        local up = def and (def.upgrade or def.upgrades)
        local nowAmt = level == 0 and tonumber(def and def.farm_amount) or (type(up) == "table" and type(up[level]) == "table" and tonumber(up[level].farm_amount))
        local nextAmt = type(up) == "table" and type(up[level + 1]) == "table" and tonumber(up[level + 1].farm_amount)
        if not (nowAmt and nextAmt and nextAmt > nowAmt) then return AutoPlaceModule.WaveNumber() < 10 end
        return (nextAmt - nowAmt) * (30 - AutoPlaceModule.WaveNumber()) >= 1.5 * cost
    end
    -- (portals run past wave 15: a fixed 15-wave horizon stopped every farm upgrade there, so
    -- at least 8 waves are always counted; farms are sold on the last wave anyway)
    local left = math.max(AutoPlaceModule.FARM_HORIZON - AutoPlaceModule.WaveNumber(), 8)
    -- (a Golden farm earns more from the same upgrade)
    local gain = (nextAmount - now) * (AutoPlaceModule.HasTrait(u, "golden") and AutoPlaceModule.GOLDEN_MONEY or 1)
    return cost / gain <= left / 2
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
-- Last-wave boss chase (owner 2026-10-25, work/placement_method.md "Last-wave boss chase"): on the last
-- wave (Fool's Hunt from wave 30 only) with a boss past the middle of the road and time left before it
-- reaches our base, damage units that can no longer reach the road ahead of it are sold, and the
-- strongest team damage unit the money (with the sale) buys goes on the spot covering the most road
-- ahead of the boss, nearest our base. Once a game. The time stop then fires when the boss enters that
-- unit's zone (FreezeMoment: "boss inside the damage zone"). chase / bossBase go into the AASTAT row.
AutoPlaceModule.chase = {}
function AutoPlaceModule.Boss()
    local folder = unitsFolder()
    local hps, top, topHp = {}, nil, 0
    for _, e in ipairs(folder and folder:GetChildren() or {}) do
        if isEnemy(e) then
            local hp = AutoPlaceModule.StatNum(e, "base_health") or 0
            hps[#hps + 1] = hp
            if hp > topHp then top, topHp = e, hp end
        end
    end
    table.sort(hps)
    -- (what a normal enemy has, remembered for when the boss walks almost alone)
    if #hps >= 3 then AutoPlaceModule.normalHp = hps[math.ceil(#hps / 2)] end
    local normal = (#hps >= 3 and hps[math.ceil(#hps / 2)]) or (#hps == 2 and hps[1]) or AutoPlaceModule.normalHp
    if top and normal and normal > 0 and topHp >= 5 * normal then return top end
    return nil
end
-- Progress along the learned road (0 = enemy end, 1 = our base) of every road point, by distance to
-- our base end (Ends), and of the road point nearest (x, z).
local function roadProgs(pts, goal, x, z)
    local far, near = 0, math.huge
    local d = {}
    for i, q in ipairs(pts) do
        d[i] = math.sqrt((q[1] - goal.X) ^ 2 + (q[3] - goal.Z) ^ 2)
        far, near = math.max(far, d[i]), math.min(near, d[i])
    end
    local progs, at, ad = {}, 0, nil
    for i, q in ipairs(pts) do
        progs[i] = far > near and (far - d[i]) / (far - near) or 0
        local dq = (q[1] - x) ^ 2 + (q[3] - z) ^ 2
        if not ad or dq < ad then at, ad = progs[i], dq end
    end
    return progs, at
end
function AutoPlaceModule.BossChase(money, prices)
    local c = AutoPlaceModule.chase
    local w = AutoPlaceModule.WaveNumber()
    if w < (c.wave or 0) then c = {} AutoPlaceModule.chase = c end -- a new game
    c.wave = w
    -- (did the boss reach our base: it left the map while past 90% of the road)
    if c.boss and not c.boss.Parent and (c.lastProg or 0) >= 0.9 then c.reached, c.boss = true, nil end
    if c.done or AutoPlace.manual or not AutoPlaceModule.LastWave() then return nil end
    if State.eventMode and w < 30 then return nil end
    -- (a boss once found is followed while it is on the map)
    local boss = (c.boss and c.boss.Parent and c.boss) or AutoPlaceModule.Boss()
    local bp = boss and rootPos(boss)
    local pts = pathPoints()
    local _, goal = AutoPlaceModule.Ends()
    if not (bp and goal) or #pts < 8 then return nil end
    local progs, bossProg = roadProgs(pts, goal, bp.X, bp.Z)
    c.boss, c.lastProg = boss, bossProg
    local now = os.clock()
    if c.lastPos and now - c.lastAt > 0.2 then
        local v = math.sqrt((bp.X - c.lastPos.X) ^ 2 + (bp.Z - c.lastPos.Z) ^ 2) / (now - c.lastAt)
        -- (stopped or slowed to a crawl: keep the walking speed - slows are counted as time won)
        if v > 0.3 then c.speed = v end
    end
    if not c.lastPos or now - c.lastAt > 0.2 then c.lastPos, c.lastAt = bp, now end
    if bossProg < 0.5 or not c.speed then return nil end
    local len = 0
    for i = 2, #pts do len = len + math.min(10, math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][3] - pts[i - 1][3]) ^ 2)) end
    local left = (1 - bossProg) * len / c.speed
    if left < AutoPlaceModule.CHASE_NEED then
        c.done = true
        AutoPlaceModule.Note(string.format("boss chase: too late (%.0f s to our base)", left))
        return nil
    end
    -- units that cannot reach any road ahead of the boss: sold, their money joins in
    local function reaches(u)
        local p = rootPos(u)
        if not p then return true end
        local r = AutoPlaceModule.StatNum(u, "range") or AutoPlaceModule.Range({ name = unitType(u) or "" })
        for i, q in ipairs(pts) do
            if progs[i] > bossProg and (q[1] - p.X) ^ 2 + (q[3] - p.Z) ^ 2 <= r * r then return true end
        end
        return false
    end
    local sell, saleGuess = {}, 0
    for _, u in ipairs(ownedUnits()) do
        local def = AutoPlaceModule.UnitDef(unitType(u)) or {}
        if unitRole(u) == "dps" and not def.unsellable and not reaches(u) then
            sell[#sell + 1] = u
            saleGuess = saleGuess + 0.5 * (AutoPlaceModule.StatNum(u, "total_spent") or tonumber(def.cost) or 0)
        end
    end
    -- the strongest team damage unit the money buys (a copy under its limit, or one freed by a sale)
    local pick, pickCost, pickV
    for s, t in pairs(AutoPlaceModule.team) do
        local cost = t.cost or (prices or {})[s]
        if (AutoPlaceModule.RoleOf(t) or "dps") == "dps" and cost and cost <= (money or 0) + saleGuess
            and not AutoPlaceModule.full[t.uuid] then
            local v = AutoPlaceModule.MaxDps(t.name) or 0
            if not pickV or v > pickV then pick, pickCost, pickV = t, cost, v end
        end
    end
    if not pick then return nil end
    -- its spot: the free one covering the most road ahead of the boss, nearest our base first
    local r = AutoPlaceModule.PlanRange(pick)
    local kind = AutoPlaceModule.PlacementKind(pick)
    local mine = {}
    for _, u in ipairs(ownedUnits()) do
        local p = rootPos(u)
        if p then mine[#mine + 1] = p end
    end
    local spot, best
    for _, cnd in ipairs(candidates or {}) do
        if (kind == "any" or cnd.kind == kind) and not badSpots[spotKey(cnd, kind)] then
            local free = true
            for _, p in ipairs(mine) do
                if (p.X - cnd.x) ^ 2 + (p.Z - cnd.z) ^ 2 < MIN_SPACING * MIN_SPACING then free = false break end
            end
            if free then
                local r2 = r * r - (cnd.rise or 0) ^ 2
                local n = 0
                for i, q in ipairs(pts) do
                    if progs[i] > bossProg + 0.02 and (q[1] - cnd.x) ^ 2 + (q[3] - cnd.z) ^ 2 <= r2 then n = n + progs[i] end
                end
                if n > 0 and (not best or n > best) then spot, best = cnd, n end
            end
        end
    end
    if not spot then
        c.done = true
        AutoPlaceModule.Note("boss chase: no free spot ahead of the boss")
        return nil
    end
    local remote = getAARemote("sell_unit_ingame")
    for _, u in ipairs(sell) do
        if remote then pcall(function() remote:InvokeServer(u) end) end
        AutoPlaceModule.Note(string.format("boss chase: sold %s (cannot reach the boss any more)", unitType(u) or "?"))
    end
    if #sell > 0 then return 0.3 end -- (the sale money arrives, the next tick places)
    if (money or 0) < pickCost then return 0.2 end
    AutoPlaceModule.status = string.format("Boss chase: %s ahead of the boss (%.0f s to our base)", pick.name, left)
    if tryPlace(pick, spot) then
        c.done, c.used = true, true
        AutoPlaceModule.Note(string.format("boss chase: placed %s ahead of the boss at %d%% of the road (%.0f s to our base)",
            pick.name, math.floor(bossProg * 100 + 0.5), left))
        return 0.2
    end
    return 0.3
end
AutoPlaceModule.CHASE_NEED = 2 -- s the boss must still need to reach our base for the chase to start

local function chooseNext(prices, danger)
    local list, dpsPlaced, farmsPlaced = {}, 0, 0
    local strongest, strongestDown
    for s = 1, 6 do
        local t = AutoPlaceModule.team[s]
        if t then
            local copies = placedOf(t.uuid)
            local placed = #copies
            t.placedSample = copies[1]
            local role = AutoPlaceModule.RoleOf(t) or "dps"
            if role == "dps" then dpsPlaced = dpsPlaced + placed end
            if role == "farm" then farmsPlaced = farmsPlaced + placed end
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
            -- (v2 money units: speedwagon x3 + bulma x1, any more only take a place on the map)
            if role == "farm" and not State.eventMode and AutoPlaceModule.FARM_COUNT[AutoPlaceModule.BaseId(t.name)] then
                target = math.min(target, AutoPlaceModule.FARM_COUNT[AutoPlaceModule.BaseId(t.name)])
            end
            -- buff units: only as many as the rotation needs (6 Erwins = money not spent on damage)
            -- (normal stages: PV.BuffCopies - by kind and stage length, buff and support alike)
            if (role == "buff" or role == "support") and not State.eventMode then target = math.min(target, (PV.BuffCopies(t, placed)))
            elseif role == "buff" then target = math.min(target, AutoPlaceModule.BuffNeed(t)) end
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
    AutoPlaceModule.placeable = list
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
    -- the best-value damage unit, then the farms, then support (normal stages: v2Plan sets the order first)
    -- (a Golden farm copy first among the farms: it earns more)
    local goldFarm
    for _, e in ipairs(list) do
        if e.role == "farm" and AutoPlaceModule.TraitMods(e.t.traits).money > 1 and (not goldFarm or e.cost < goldFarm.cost) then goldFarm = e end
    end
    local pick = (dpsPlaced == 0 and bestDps()) or goldFarm or cheapest("farm") or cheapest("support")
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
AutoPlaceModule.RANK = { "judar_evolved", "cid_evolved", "bee_girl_evolved", "homura_evolved", "sakamoto_evolved", "nagumo_evolved", "saber_evolved", "frieren_evolved", "monet_evolved", "jiraiya_evolved", "emilia" }
AutoPlaceModule.ROSTER = { "akainu_evolved", "aokiji_evolved", "archer_evolved", "armin", "avdol_evolved", "bee_girl_evolved", "caesarclown_evolved", "cid_evolved", "daki_evolved", "demiurge_evolved", "emilia", "escanor_evolved", "esdeath_evolved", "frieren_evolved", "fujitora_evolved", "ghostkun_evolved", "gildarts_evolved", "gilgamesh_evolved", "goku_ssj3_evolved", "gremmy_evolved", "guts_berserker", "gyutaro_evolved", "hakari_evolved", "hidan_unit_evolved", "homura_evolved", "illya_evolved", "jiraiya_evolved", "josuke_2_evolved", "judar_evolved", "julius_evolved", "koichi_evolved", "konan_unit_evolved", "law_2_evolved", "medea_evolved", "meliodas_evolved", "metal_knight_evolved", "monet_evolved", "nagumo_evolved", "nagumo_evolved", "narberal_evolved", "naruto_6tails", "natsu_evolved", "pucci_heaven", "saber_evolved", "sabo_evolved", "sakamoto_evolved", "shalltear_evolved", "shigaraki_evolved", "stain_evolved", "sukuna", "tatsumaki_evolved", "tengen_2_evolved", "usopp_ts_evolved", "vanilla_ice_evolved" }
function AutoPlaceModule.InList(list, name)
    for _, n in ipairs(type(list) == "table" and list or {}) do if n == name then return true end end
    return false
end
-- A fast hitter that breaks enemy shields (one hit takes a shield point): attacks every 2 s or
-- faster, or bee_girl (1 s, armour shred) - owner 2026-10-24
function AutoPlaceModule.ShieldBreaker(name)
    if name == "bee_girl_evolved" then return true end
    local def = AutoPlaceModule.UnitDef(name)
    local cd = def and tonumber(def.attack_cooldown)
    return cd ~= nil and cd > 0 and cd <= 2 and (tonumber(def.damage) or 0) > 0
end

function AutoPlaceModule.CountKind(units, name)
    local n = 0
    for _, u in ipairs(units) do if unitType(u) == name then n = n + 1 end end
    return n
end

function AutoPlaceModule.DamageCount(units)
    local n = 0
    for _, u in ipairs(units) do if unitRole(u) == "dps" then n = n + 1 end end
    return n
end
AutoPlaceModule.EV = { placeBonus = 2, reserve = 0, airMin = 3, airBy = 8, buffUnits = 2, stuck = 12 }
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
        if t.temp and not AutoPlaceModule.full[t.uuid] and not AutoPlaceModule.badTemp[t.uuid]
            and now - (AutoPlaceModule.dropAt[t.uuid] or -1e9) > 5 then
            local role = AutoPlaceModule.RoleOf(t) or "dps"
            local why
            local always = AutoPlaceModule.InList(Lobby.cfg.eventAlways, t.name)
            -- (an Enemy Shield card was taken: up to 2 fast hitters are placed to break the shields)
            local breaker = false
            if Lobby.shieldTaken and not always and AutoPlaceModule.ShieldBreaker(t.name) then
                local have = 0
                for _, u in ipairs(units) do if AutoPlaceModule.ShieldBreaker(unitType(u) or "") then have = have + 1 end end
                breaker = have < 2
            end
            always = always or breaker
            -- (a main unit came this game: from now on the rest are not needed; with none, they hold the line)
            if always and not AutoPlaceModule.UP_CAP[t.name] then AutoPlaceModule.mainSeen = true end
            -- (under 6 damage units any damage copy goes down - Snowy Town was lost at wave 7 with 4 units;
            -- Arlem only never: 5000 for a hit every 60 s)
            local thin = role == "dps" and AutoPlaceModule.DamageCount(units) < 6 and t.name ~= "armin"
            -- (from wave 20 a free map place is worth more than the yen: losses at waves 28-30 had only
            -- 10-16 of 20 units while copies were cleared - owner 2026-10-25)
            local lateRoom = AutoPlaceModule.WaveNumber() >= 20 and #units < math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) - 2
            -- (the owner's Never list always wins - shared data 2026-10-25: natsu, sabo, narberal, vanilla_ice,
            -- akainu were placed in 52 games while the team was thin, all left at level 0)
            if AutoPlaceModule.InList(Lobby.cfg.eventNever, t.name) or (AutoPlace.skip[t.name] and not thin) then why = "on the never / skip list"
            -- (place-only units - nagumo, jiraiya, emilia: one of each; three nagumos took three places)
            elseif AutoPlaceModule.UP_CAP[t.name] == 0 and AutoPlaceModule.CountKind(units, t.name) >= 1 then why = "one is enough"
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
            -- (owner: only the units on the Always list - the rest just while fewer than 4 damage units
            -- are down, so the early waves are held)
            elseif not always and role == "dps" and AutoPlaceModule.mainSeen and AutoPlaceModule.DamageCount(units) >= 8
                and not lateRoom then why = "not on the Always list"
            -- (also weak copies late: lost at wave 30 with 48k unspent while gilgamesh was cleared as weak)
            elseif not always and not thin and not (lateRoom and role == "dps") and AutoPlaceModule.EventWeak(t, role) then why = "far below the team"
            end
            local first = AutoPlaceModule.copySeen[t.uuid] or now
            AutoPlaceModule.copySeen[t.uuid] = first
            -- (owner: cleared sooner, money or not - only a main unit may wait for its price)
            -- (a thin team gives a damage copy 30 s to be afforded, then it goes like any other)
            local mayWait = always
            if not why and not atCap and now - first > EV.stuck and (not mayWait or (t.cost and money and money >= t.cost)) then why = "stuck on the bar" end
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
                -- (an Always unit goes down as soon as it can be paid: nagumo was X'd as stuck while the
                -- money waited for an upgrade - Snowy Town loss 2026-10-24)
                -- (owner 2026-10-25: below 8 damage units a damage copy that can be paid NOW is placed
                -- before upgrades - usopp and illya were cleared while the yen went into monet / frieren.
                -- Never saved for: saving for unaffordable copies stopped every upgrade and filled the bar)
                -- (only a copy that can be paid now goes before upgrades; an Always copy may also be
                -- saved for while the base is safe - review 2026-10-25: saving for unpayable copies
                -- stalled every upgrade)
                local payNow = t.cost and money and money >= t.cost
                if (always and (payNow or not AutoPlaceModule.danger))
                    or (payNow and (role == "farm" or role == "buff" or role == "support" or (airShort and AutoPlaceModule.AirCapable(t.name, 0))
                    )) then v = math.huge end
                -- (2026-10-25 night: "below 8 damage units a payable damage copy goes before upgrades" was
                -- taken back - shared data showed 6-8 units placed at level 0 and losses at waves 7-15)
                if v > bestV then best, bestV = { t = t, role = role }, v end
            end
        end
    end
    -- 1b. the map is full and a main unit waits on the bar: the weakest other unit makes room
    -- (Refund in hand = full price back, else sold) - owner 2026-10-24: two judar copies sat on
    -- the bar while 20 weaker units held every place
    if atCap and os.clock() - (AutoPlaceModule.swapAt or -1e9) > 6 then
        local mainWaiting = false
        for _, t in pairs(AutoPlaceModule.team) do
            if t.temp and not AutoPlaceModule.badTemp[t.uuid] and AutoPlaceModule.InList(AutoPlaceModule.RANK, t.name)
                and not AutoPlaceModule.UP_CAP[t.name] then mainWaiting = true end
        end
        if mainWaiting then
            local worst, worstV
            for _, u in ipairs(units) do
                local kind = unitType(u) or ""
                local main = AutoPlaceModule.InList(AutoPlaceModule.RANK, kind) and not AutoPlaceModule.UP_CAP[kind]
                local airUnit = AutoPlaceModule.AirCapable(kind, AutoPlaceModule.StatNum(u, "upgrade") or 0)
                if unitRole(u) == "dps" and not main and not (airUnit and air <= EV.airMin) then
                    local v = AutoPlaceModule.MaxDps(kind) or 0
                    if not worst or v < worstV then worst, worstV = u, v end
                end
            end
            if worst then
                AutoPlaceModule.swapAt = os.clock()
                if not Lobby.CastOn("sell_refund", worst) then
                    local sell = getAARemote("sell_unit_ingame")
                    if sell then task.spawn(pcall, function() sell:InvokeServer(worst) end) end
                    AutoPlaceModule.Note(string.format("sold %s to make room for a main unit", unitType(worst) or "?"))
                end
                return 1
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
        -- (waits for the best one - main units weigh x10 - instead of buying whatever is cheap:
        -- the mains never reached their big upgrades)
        local m = (money or 0) - EV.reserve
        -- (farms and the aura unit only when they can be paid now; a farm's 30000 must not hold the team)
        -- (base being hit: damage first, no farm or aura upgrades)
        local wait = (not AutoPlaceModule.danger and (upgradeStep(m, "farm", nil, true) or upgradeStep(m, "support", nil, true))) or upgradeStep(m, "dps")
        if wait then return wait end
        -- (no "saving" without an upgrade that can actually be picked: with the carry maxed and no
        -- other main, 20k sat unused until the loss - real game 2026-10-24)
    end
    if best and canPay(best) then return nil, best.t, best.role end
    AutoPlaceModule.status = best and "Waiting for money" or (atCap and "Unit limit reached - upgrading" or "Waiting for the next copy")
    return 0.5
end

-- v2 order (normal stages): the steps of PV.Steps in turn - the first one not done yet acts.
--   carry: place the carry | carryUp: its upgrades to CARRY_LEVEL | carryMax: its upgrades to the top
--   slow: place a slow unit | farms: place the money units | farmUps: farm upgrades that pay back
--   damageUps: damage upgrades | rest: the normal choice below (chooseNext, value per ¥)
-- Returns a wait, or a team entry to place (t, role, slot), or nothing (go on with the rest).
local function v2Plan(money, danger)
    -- (a) starvation guard: never two carry upgrades in a row while a team unit - damage / slow, or a farm on a
    -- long road - is unplaced and affordable now (owner's rooms 2026-10-26: one carry upgraded 1->4, lost)
    if (PV.carryRow or 0) >= 1 then
        local long = PV.Kind(PV.Road().len) == "long"
        local best, bv
        for _, x in ipairs(AutoPlaceModule.placeable or {}) do
            if x.cost <= (money or 0) and (x.role == "dps" or (x.role == "farm" and long)) then
                local v = (x.role == "dps" and 1e6 or 0) + AutoPlaceModule.Value(x.t, x.cost ~= math.huge and x.cost or nil)
                if not bv or v > bv then best, bv = x, v end
            end
        end
        if best then AutoPlaceModule.v2Why = "guard: a unit before another carry upgrade" return nil, best.t, best.role, best.slot end
    end
    -- (timing, owner 2026-10-25) flyers on the map: an air-capable unit's upgrade (not a trap's) the moment it is affordable
    -- (airNeed held on for the call: upgradeStep counts a unit as air only while the air quota is short)
    if AutoPlace.upgrade and AutoPlaceModule.flying then
        local need = AutoPlaceModule.airNeed
        AutoPlaceModule.airNeed = true
        -- (not the traps: they hit flyers weakly - the build must not lock onto them, flying_mixed_team)
        local ok, wait = pcall(function()
            for _, u in ipairs(ownedUnits()) do
                if unitRole(u) == "dps" and not AutoPlaceModule.IsTrap(unitType(u) or "") then
                    local w = upgradeStep(money, "dps", true, true, nil, u)
                    if w then return w end
                end
            end
        end)
        AutoPlaceModule.airNeed = need
        if ok and wait then return wait end
    end
    -- the wave is ending: an affordable farm upgrade now, before the payout (bought after it, it misses
    -- that wave's money) - whatever bigger thing the money was saved for
    if AutoPlace.upgrade and not danger and PV.WaveEnding() then
        local wait = upgradeStep(money, "farm", nil, true)
        if wait then return wait end
    end
    -- (flying enemies on the map, or most enemies seen here fly: the air rules below choose - owner rule, not in the spec)
    if PV.AirStage() then AutoPlaceModule.v2Why = "air" return nil end
    local steps, why = PV.Steps(danger)
    AutoPlaceModule.v2Why = why
    local list = AutoPlaceModule.placeable or {}
    local function entry(test)
        local best
        for _, e in ipairs(list) do
            if test(e) and (not best or e.cost < best.cost or (e.cost == best.cost and e.slot < best.slot)) then best = e end
        end
        return best
    end
    local carry = PV.Carry()
    local wave = AutoPlaceModule.WaveNumber()
    -- (a damage unit that is not a summoner goes down by DPS_BY_WAVE whatever the order says)
    local _, realDown = PV.DpsDown()
    if realDown == 0 and wave >= PV.DPS_BY_WAVE - 1 then
        local e, ev
        for _, x in ipairs(list) do
            if x.role == "dps" and not PV.IsSummoner(x.t.name) then
                local v = PV.Power(x.t)
                if not e or v > ev then e, ev = x, v end
            end
        end
        if e then AutoPlaceModule.v2Why = "damage by wave " .. PV.DPS_BY_WAVE return nil, e.t, e.role, e.slot end
    end
    for _, step in ipairs(steps) do
        if step == "rest" then return nil end
        -- (from FARM_PHASE_WAVE the carry's upgrades come before more farms: never a farm phase without end)
        if (step == "farms" or step == "farmUps") and wave >= PV.FARM_PHASE_WAVE then
            local cu, lv = PV.CarryUnit()
            if cu and lv < PV.CARRY_LEVEL and nextUpgrade(cu, lv) then step = "skip" end
        end
        if step == "rotating" then
            -- (the rotating buff's full set once 2+ damage units are down: its target is 0 before - BuffCopies)
            local e = entry(function(x) return x.role == "buff" and PV.BuffKind(x.t.name) == "rotating" end)
            if e then return nil, e.t, e.role, e.slot end
        end
        if step == "aura" then
            -- (the aura buff: one copy right after the first damage unit, upgraded to the top early - each
            -- level cuts every price and raises team damage, owner 2026-10-26)
            local e = PV.DpsDown() >= 1 and entry(function(x) return (x.role == "buff" or x.role == "support") and x.placed == 0 and PV.BuffKind(x.t.name) == "aura" end)
            if e then return nil, e.t, e.role, e.slot end
            if AutoPlace.upgrade then
                for _, u in ipairs(ownedUnits()) do
                    local r = unitRole(u)
                    if (r == "buff" or r == "support") and PV.BuffKind(unitType(u) or "") == "aura" then
                        local wait = upgradeStep(money, nil, nil, why == "low", nil, u)
                        if wait then return wait end
                    end
                end
            end
        end
        if step == "carry" and carry and #placedOf(carry.uuid) == 0 then
            local e = entry(function(x) return x.t.uuid == carry.uuid end)
            if e then return nil, e.t, e.role, e.slot end
        elseif (step == "carryUp" or step == "carryMax") and AutoPlace.upgrade then
            local cu, lv = PV.CarryUnit()
            if cu and (step == "carryMax" or lv < PV.CARRY_LEVEL) then
                local wait = upgradeStep(money, "dps", nil, nil, nil, cu)
                if wait then return wait end
            end
        elseif step == "slow" then
            local e = entry(function(x) return x.role == "dps" and x.placed == 0 and PV.IsSlow(x.t.name) end)
            if e then return nil, e.t, e.role, e.slot end
        elseif step == "farms" then
            -- (a Golden copy first: it earns more)
            local e = entry(function(x) return x.role == "farm" and AutoPlaceModule.TraitMods(x.t.traits).money > 1 end)
                or entry(function(x) return x.role == "farm" end)
            if e then return nil, e.t, e.role, e.slot end
        elseif step == "farmUps" and AutoPlace.upgrade then
            local wait = upgradeStep(money, "farm")
            if wait then return wait end
        elseif step == "damageUps" then
            -- (a new damage copy when it adds more damage per ¥ than the best upgrade, else the upgrade)
            local e, ev
            for _, x in ipairs(list) do
                if x.role == "dps" then
                    local v = AutoPlaceModule.Value(x.t, x.cost ~= math.huge and x.cost or nil)
                    if not e or v > ev then e, ev = x, v end
                end
            end
            if e and (not AutoPlace.upgrade or ev >= AutoPlaceModule.BestUpgradeScore()) then return nil, e.t, e.role, e.slot end
            if AutoPlace.upgrade then
                local wait = upgradeStep(money, "dps")
                if wait then return wait end
            end
            if e then return nil, e.t, e.role, e.slot end
        end
    end
    return nil
end

local function tick()
    AutoPlaceModule.idleMoney, AutoPlaceModule.nextCost, AutoPlaceModule.v2Picked = nil, nil, nil
    -- (where the last tick got to, for the live status: a step that never returns shows here)
    AutoPlaceModule.tickAt, AutoPlaceModule.tickStep = os.clock(), "start"
    if State.replaying then AutoPlaceModule.status = "Paused while the macro plays" return 1 end
    if not isGameRunning() or isResultsShowing() then AutoPlaceModule.status = "Waiting for a game" return 1 end
    local grew = samplePath()
    if grew then AutoPlaceModule.pathGrewAt = os.clock() end
    if not State.eventMode then pcall(PV.SpeedStep) end
    if grew and #pathPoints() % 20 == 0 then saveConfig() end
    pcall(AutoPlaceModule.DumpStep)
    -- (an empty team is read again at most every 15 s on a normal stage: each read walks all memory - getgc)
    local reads = AutoPlaceModule.emptyReads or 0
    local every = (reads < 4 and 15) or (reads < 10 and 60) or 300
    if not next(AutoPlaceModule.team) and (State.eventMode or os.clock() - (AutoPlaceModule.teamReadAt or -1e9) >= every) then
        AutoPlaceModule.RefreshTeam()
        AutoPlaceModule.emptyReads = next(AutoPlaceModule.team) and 0 or reads + 1
    end
    -- event hotbar: new random units arrive during the game (read again every 5 s)
    if State.eventMode and AutoPlaceModule.hotbarAt and os.clock() - AutoPlaceModule.hotbarAt > 5 then AutoPlaceModule.RefreshTeam() end
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
    if not State.eventMode then pcall(PV.WaveStep, money) end
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
    -- (normal stages: no unit of ours down by wave 2 - friends on builds 202654-204218 lost Snowy Kingdom
    -- Dungeon Room at wave 7 with none, not reproduced on the 24 scanned maps: noted once with the status
    -- for the report, and the newer spot filters (road distance, BAD_SPOT areas, road cover) and the
    -- "no spot" rests are dropped until a unit is down)
    if not State.eventMode and not AutoPlace.manual and AutoPlaceModule.WaveNumber() >= 2 and #ownedUnits() == 0 then
        if not AutoPlaceModule.rescue then
            AutoPlaceModule.Note(string.format("NO_UNITS at wave %d: %s | %s - placing without the spot filters",
                AutoPlaceModule.WaveNumber(), tostring(AutoPlaceModule.status), tostring(AutoPlaceModule.problem)))
            AutoPlaceModule.noSpot = {}
        end
        AutoPlaceModule.rescue = true
    else
        AutoPlaceModule.rescue = nil
    end
    if AutoPlace.sellFarmsLast and AutoPlaceModule.LastWave() and AutoPlaceModule.SellFarm() then return 0.3 end
    do
        -- (last-wave boss chase: its own function, see AutoPlaceModule.BossChase)
        local okC, waitC = pcall(AutoPlaceModule.BossChase, money, hudPrices)
        if okC and waitC then return waitC end
    end
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
        -- (event has no fixed team: the units already down count)
        for _, u in ipairs(ownedUnits()) do
            if AutoPlaceModule.AirCapable(unitType(u) or "", math.huge) then any = true end
        end
        -- (a dungeon room's map with flyers is remembered for the room choice: DungeonRun.RoomFlies)
        if DungeonRun.InRoom() then pcall(DungeonRun.NoteFlyMap) end
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
    -- (owner 2026-10-25: on a stage played for the first time only the road near the enemy spawn
    -- is known when the first unit goes down, so every unit stood forward) the 2nd+ damage unit
    -- waits until the learned path reaches our base - HOLD_PATH s at most, never in danger, not in
    -- Fast clear (units forward on purpose there)
    -- (a new stage only: where the enemies never reach our base the road stays "short" for good, and
    -- the script reloads every game - the hold came back each game there, auto_place next game)
    if t and role == "dps" and (dpsPlaced or 0) > 0 and not danger and not State.eventMode and not AutoPlaceModule.flying
        and AutoPlaceModule.freshStage[stageKey()] and AutoPlaceModule.Mode() ~= "Fast clear" and AutoPlaceModule.PathShort() then
        -- (no early end when the path stops growing: Future City 2026-10-25, homura froze the enemies
        -- by the spawn and the units went down on a 25-point stub 150 studs from our base)
        local key = stageKey()
        AutoPlaceModule.holdAt[key] = AutoPlaceModule.holdAt[key] or os.clock()
        if os.clock() - AutoPlaceModule.holdAt[key] < AutoPlaceModule.HOLD_PATH then
            if AutoPlaceModule.holdNoted ~= key then
                AutoPlaceModule.holdNoted = key
                AutoPlaceModule.Note("new stage: more damage units once the enemy path reaches our base")
            end
            -- (the money waits for the next unit: upgrading during the hold put upgrades before placing -
            -- auto_place_upgrade; flyers on the map end the hold, see above)
            AutoPlaceModule.status = string.format("Learning the road to our base (%d points) before more damage units", #pathPoints())
            -- (0.1: the path is sampled once a tick - at 0.5 the enemies moved past PATH_CELL between
            -- samples and the saved road had gaps; spots in them were on the road, refused next game)
            return 0.1
        end
    end
    -- Fool's Hunt: its own brain decides (EventChoose); the normal-stage rules below are skipped
    local ev = State.eventMode and not AutoPlace.manual and Lobby.cfg.eventBrain ~= false
    if ev then
        local wait, et, er = AutoPlaceModule.EventChoose(money)
        if wait then return wait end
        t, role, slot = et, er, et.slot
    end
    if not ev and not State.eventMode and not AutoPlace.manual then
        local wait, vt, vrole, vslot = v2Plan(money, danger)
        if wait then return wait end
        if vt then t, role, slot = vt, vrole, vslot end
        AutoPlaceModule.v2Picked = vt ~= nil
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
    if State.eventMode and not danger and AutoPlace.upgrade and (dpsPlaced or 0) > 0 and strongestDown
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
            -- (normal stages, flyers on the map: air upgrades first - upgradeStep - then farms)
            local wait
            if PV.AirStage() and not State.eventMode then wait = upgradeStep(money) or upgradeStep(money, "farm")
            else wait = upgradeStep(money) end
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
    if not danger and AutoPlace.upgrade and role == "dps" and (dpsPlaced or 0) > 0 and not (AutoPlaceModule.v2Picked and not State.eventMode) then
        -- stay ahead instead of waiting for the base to get hit: when upgrading the strongest
        -- unit (trait / rolls included) adds more damage per ¥ than another copy, upgrade it
        if AutoPlaceModule.BestUpgradeScore() > AutoPlaceModule.Value(t, cost) then
            -- (normal stages: saving only for an upgrade up to 4x the waiting unit's price - saving for
            -- cid's 14k left homura (1.6k) and hoshino unplaced with 9.9k in hand at wave 10, Shibuya
            -- Dungeon Room 2026-10-25; a small upgrade still comes before a weak copy)
            local cap = (not State.eventMode and cost) and math.max(money or 0, 4 * cost) or nil
            local wait = upgradeStep(money, "dps", nil, nil, cap)
            if wait then return wait end
        end
    end
    if cost and money and money < cost then
        AutoPlaceModule.status = string.format("Slot %d %s: waiting for money %d / %d", slot, t.name, math.floor(money), math.floor(cost))
        PV.WaitFor(cost, money)
        return 0.1
    end
    end
    local unknown = not (cost and money)
    local range = AutoPlaceModule.PlanRange(t)
    local kind = AutoPlaceModule.PlacementKind(t)
    local aoe = AutoPlaceModule.IsAoe(t.name)
    local back = AutoPlaceModule.IsTrap(t.name) and AutoPlaceModule.AirCapable(t.name, 0)
    AutoPlaceModule.placingName, AutoPlaceModule.placingT = t.name, t
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
    -- (the time the placing STARTED: the game may announce the next copy of this kind before
    -- tryPlace returns, and that copy must not count as the used one)
    local placeStart = os.clock()
    if tryPlace(t, spot) then
        PV.Acted()
        PV.carryRow = 0
        -- (event: the copy is used up - the placed unit may carry another uuid, so it is not
        -- counted from the map; the bar is read again on the next tick)
        if t.temp then
            AutoPlaceModule.full[t.uuid], AutoPlaceModule.badTemp[t.uuid] = true, true
            AutoPlaceModule.capFails = 0
            if t.slot then AutoPlaceModule.usedSlot[t.slot] = { id = t.name, at = placeStart } end
            AutoPlaceModule.hotbarAt = 0
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
        if role == "dps" and not State.eventMode then pcall(AutoPlaceModule.CheckSpot, t.name, spot, range) end
        return 0.2
    end
    local why = refusalReason()
    if why == "money" then return 0.5 end
    -- below the game's own limit a "limit" message cannot be about this unit
    if why == "cap" and t.gameCap and #placedOf(t.uuid) < t.gameCap then why = "spot" end
    if why == "spot" or (why == nil and cost and money and money >= cost) then AutoPlaceModule.SpotRefused(t, spot, kind) end
    if why == "spot" then
        badSpots[spotKey(spot, kind)] = true
        -- (a raised spot with no hill name is a roof / wall: the rest of that part is refused too -
        -- a buff unit tried 7 spots on one roof, each refusal ~0.5 s)
        if spot.part and spot.hillBy == "height" then AutoPlaceModule.badParts[spot.part] = true end
        return 0.1
    end
    -- (Fool's Hunt: "max placement" for a copy under its own unit limit = the map's unit limit;
    -- not learning that sent every new copy in to be refused)
    -- (10 units at least: one misread refusal with 3 units down stopped every placement - review 2026-10-25)
    if why == "cap" and t.temp and State.eventMode and not AutoPlaceModule.EventCapped(t) and #ownedUnits() >= 10 then
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
-- inside our damage units' range, or a big pack (8+) bunched inside that range.
-- A number from a unit's _stats folder (nil when missing).
function AutoPlaceModule.StatNum(u, name)
    local st = u:FindFirstChild("_stats")
    local v = st and st:FindFirstChild(name)
    return v and tonumber(v.Value) or nil
end

-- waited = seconds the skill has been ready (unlocks the small-group fallback).
function AutoPlaceModule.FreezeMoment(waited)
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
    -- owner 2026-10-24 (Fool's Hunt): 5 in the zone was a wasted 44 s cooldown - wait for a real
    -- pack (8+), or 6+ that are most of a small wave
    if inZone >= 8 or (inZone >= 6 and inZone >= math.ceil(#enemies * 0.6)) then
        return string.format("%d enemies inside the damage zone", inZone)
    end
    -- never sit on it all game: after 60 s ready a small group in the zone is still better than nothing
    if (waited or 0) > 60 and inZone >= 3 then
        return string.format("%d enemies inside the damage zone, ready for %d s", inZone, math.floor(waited))
    end
    return nil
end

local function freezeLoop(gen)
    local last, lastAny, readyAt = {}, -1e9, {}
    while AutoPlace.enabled and gen == apGen and not State.unloaded do
        if AutoPlace.smartFreeze and isGameRunning() and not isResultsShowing() then
            pcall(function()
                local now = os.clock()
                ControlUp.Watch(now)
                -- (one stop at a time: the next only after the running one ended + the gap - ControlUp)
                if not ControlUp.Clear(now) then return end
                local spots = ControlUp.enemySpots()
                local best, bestN, bestWait
                for _, u in ipairs(ownedUnits()) do
                    if BuffRot.isControlSkill(u) then
                        local cd = AutoPlaceModule.StatNum(u, "active_attack_cooldown") or 30
                        if now - (last[u] or -1e9) >= cd + 0.5 then
                            -- first time seen ready (not the cooldown end: a fresh unit has no last cast)
                            readyAt[u] = readyAt[u] or now
                            -- (the ready copy with the most enemies in ITS reach goes; none in reach = wait)
                            local n = ControlUp.inReach(u, spots)
                            if n > 0 and (not bestN or n > bestN) then best, bestN, bestWait = u, n, now - readyAt[u] end
                        end
                    end
                end
                if not best then return end
                local why = AutoPlaceModule.FreezeMoment(bestWait)
                if why and fireActiveAttack(best) then
                    last[best], lastAny, readyAt[best] = os.clock(), os.clock(), nil
                    ControlUp.Cast(best, os.clock())
                    AutoPlaceModule.Note(string.format("%s stopped time: %s (%d in its reach)", unitType(best), why, bestN))
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
    -- (event: every unit on "first" - a boss comes most waves there, and chasing it let the
    -- front enemies through; owner 2026-10-24)
    -- (but the LAST wave of the event: the final boss decides the game - 2026-10-25, most late losses
    -- were exactly at wave 30 with a strong team; single-target units go for it there)
    local boss = (not State.eventMode or AutoPlaceModule.LastWave()) and AutoPlaceModule.Threat() == "boss on the map"
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
    pcall(PV.DumpBuffUnits)
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
                -- (perf: per-game tables keyed by uuid start empty; saved roads capped)
                AutoPlaceModule.goneTemp, AutoPlaceModule.badTemp, AutoPlaceModule.copySeen, AutoPlaceModule.noSpotNoted = {}, {}, {}, {}
                AutoPlaceModule.emptyReads = 0
                pcall(PV.PrunePaths)
                AutoPlaceModule.RefreshTeam()
            end
            lastGame = gameNow
            -- (timing: the money's Changed signal wakes the wait below once the money reaches what the tick
            -- waits for - PV.WatchMoney; the tick's own wait stays the fallback)
            pcall(PV.WatchMoney)
            AutoPlaceModule.wake = false
            local ok, waitFor = pcall(tick)
            if not ok then
                AutoPlaceModule.problem = "error: " .. clip(tostring(waitFor), 60)
                waitFor = 2
            end
            local untilT = os.clock() + (waitFor or 1)
            while os.clock() < untilT and not (AutoPlaceModule.wake and os.clock() - (PV.wokeAt or -1e9) >= 0.1) and AutoPlace.enabled and gen == apGen do task.wait(0.05) end
            if AutoPlaceModule.wake and os.clock() < untilT then PV.wokeAt = os.clock() end
        end
    end)
end

function AutoPlaceModule.Stop()
    AutoPlace.enabled = false
    apGen = apGen + 1
    AutoPlaceModule.status = "Off"
end

-- (for code outside this block: the UI toggle "Place on enemy path")
function AutoPlaceModule.ResetSpots() candidates, candidatesFor = nil, -1 end

-- AAMacro/placement_dump.json once at waves 5, 10 and 20 of a normal stage: the recorded road, our
-- units (role, range, spot, road cover %), the bases and the scored spots of the last damage
-- placements - read on the PC (work/dump_map.js draws it) to judge the placer against the real map.
AutoPlaceModule.scoredLog = {}
AutoPlaceModule.DUMP_WAVES = { 1, 5, 10, 20 } -- wave 1: the map scan (lanes) without playing on
-- For the dump: workspace's top folders, and anything named like a path / waypoint / node / lane /
-- route (the game has "Show Paths Info" for multi-path modes, so its own path data may be readable).
-- workspace._road (a Model seen on Planet Greenie): its children, for the dump.
function AutoPlaceModule.RoadModel()
    local out = {}
    local road = workspace:FindFirstChild("_road")
    for _, c in ipairs(road and road:GetChildren() or {}) do
        local okp, p = pcall(function() return c:IsA("BasePart") and c.Position or c:GetPivot().Position end)
        local ok, n = pcall(function() return #c:GetChildren() end)
        out[#out + 1] = { name = c.Name, class = c.ClassName, children = ok and n or -1,
            x = okp and p and math.floor(p.X * 10) / 10 or nil, z = okp and p and math.floor(p.Z * 10) / 10 or nil }
    end
    return out
end
function AutoPlaceModule.MapScan()
    local out = { top = {}, named = {} }
    for _, c in ipairs(workspace:GetChildren()) do
        local ok, n = pcall(function() return #c:GetChildren() end)
        table.insert(out.top, c.Name .. ":" .. c.ClassName .. ":" .. tostring(ok and n or "?"))
    end
    local skip = { _UNITS = true, _DEAD_UNITS = true, _PETS = true }
    local seen = 0
    local function walk(node, depth)
        for _, c in ipairs(node:GetChildren()) do
            seen = seen + 1
            if seen > 20000 or #out.named >= 40 then return end
            local n = string.lower(c.Name)
            if n:find("path", 1, true) or n:find("waypoint", 1, true) or n:find("node", 1, true)
                or n:find("lane", 1, true) or n:find("route", 1, true) or n:find("road", 1, true) then
                local ok, kids = pcall(function() return #c:GetChildren() end)
                local okp, p = pcall(function() return c:IsA("BasePart") and c.Position or (c:IsA("Model") and c:GetPivot().Position) or nil end)
                table.insert(out.named, { path = c:GetFullName(), class = c.ClassName, children = ok and kids or -1,
                    x = okp and p and math.floor(p.X) or nil, z = okp and p and math.floor(p.Z) or nil })
            end
            if depth < 6 and not skip[c.Name] then walk(c, depth + 1) end
        end
    end
    pcall(walk, workspace, 1)
    return out
end
function AutoPlaceModule.DumpStep()
    if State.eventMode then return end
    local w = AutoPlaceModule.WaveNumber()
    if w < (AutoPlaceModule.dumpWave or 0) then AutoPlaceModule.dumpDone = {} end -- a new game
    AutoPlaceModule.dumpWave = w
    AutoPlaceModule.dumpDone = AutoPlaceModule.dumpDone or {}
    local mark
    for _, m in ipairs(AutoPlaceModule.DUMP_WAVES) do
        if w >= m and not AutoPlaceModule.dumpDone[m] then mark = m end
    end
    if not mark then return end
    for _, m in ipairs(AutoPlaceModule.DUMP_WAVES) do if m <= mark then AutoPlaceModule.dumpDone[m] = true end end
    local pts = pathPoints()
    local units = {}
    for _, u in ipairs(ownedUnits()) do
        local p = rootPos(u)
        if p then
            local range = AutoPlaceModule.StatNum(u, "range") or AutoPlaceModule.Range({ name = unitType(u) or "" }) or 0
            local inside = 0
            for _, q in ipairs(pts) do
                if (q[1] - p.X) ^ 2 + (q[3] - p.Z) ^ 2 <= range * range then inside = inside + 1 end
            end
            table.insert(units, { id = unitType(u) or "?", role = unitRole(u), range = range, x = math.floor(p.X * 10) / 10,
                y = math.floor(p.Y * 10) / 10, z = math.floor(p.Z * 10) / 10, level = AutoPlaceModule.StatNum(u, "upgrade") or 0,
                cov = #pts > 0 and math.floor(100 * inside / #pts + 0.5) or -1, covBest = PV.CovBest(u),
                road = (function() local d, p = PV.RoadRow(u) return d and { d = d, p = p } or nil end)() })
        end
    end
    local function base(side)
        local b = AutoPlaceModule.BasePos(side)
        return b and { x = math.floor(b.X * 10) / 10, z = math.floor(b.Z * 10) / 10 } or nil
    end
    -- (spawn / base = the ends the placer uses; pve / player = the game's _BASES as they are)
    local s, g, swapped = AutoPlaceModule.Ends()
    local function xz(v) return v and { x = math.floor(v.X * 10) / 10, z = math.floor(v.Z * 10) / 10 } or nil end
    local data = { stage = State.stage, key = stageKey(), wave = w, mode = AutoPlaceModule.Mode(), hard = AutoPlaceModule.Hard(),
        version = Lobby and Lobby.VERSION, time = os.date("%Y-%m-%d %H:%M:%S"), spawn = xz(s), base = xz(g), swapped = swapped,
        pve = base("pve"), player = base("player"), path = pts, units = units, placements = AutoPlaceModule.scoredLog,
        short = AutoPlaceModule.PathShort(), map = AutoPlaceModule.MapScan(), lanes = AutoPlaceModule.Lanes(), bad = AutoPlaceModule.badLog,
        road = AutoPlaceModule.RoadModel(), lanePath = AutoPlaceModule.LanePath(), hills = PV.HillSpots(),
        control = AutoPlaceModule.ControlReport(),
        v2 = { rl = PV.Road().len, kind = PV.Kind(PV.Road().len), from = PV.Road().from, lanes = PV.Road().lanes, order = AutoPlaceModule.v2Why,
            margin = PV.lastMargin, depth = PV.lastDepth, speed = PV.speed, buff = PV.BuffShare(), carry = AutoPlaceModule.CarryName(), waves = PV.waveLog, fast = PV.FinishFast(), highStreak = PV.highStreak } }
    local ok, text = pcall(function() return HttpService:JSONEncode(data) end)
    if ok and type(writefile) == "function" then
        pcall(function() writefile(Config.Folder .. "/placement_dump.json", text) end)
        -- (a copy per map and wave in AAMacro/dumps/, so the next game does not overwrite a bad case)
        pcall(function()
            local dir = Config.Folder .. "/dumps"
            if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(dir) then makefolder(dir) end
            local name = string.sub(string.gsub(tostring(stageKey()), "[^%w]+", "_"), 1, 80)
            writefile(dir .. "/" .. name .. "_w" .. tostring(mark) .. ".json", text)
        end)
        AutoPlaceModule.Note(string.format("placement dump written (wave %d)", w))
    end
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
        table.insert(lines, string.format("Idle money: %d ¥ – turn on AUTO", math.floor(AutoPlaceModule.idleMoney)))
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
    local ok, res = pcall(req, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
    -- (a refused message still came back without an error: the reply code says whether it arrived)
    local code = ok and type(res) == "table" and tonumber(res.StatusCode) or nil
    return ok and (not code or code < 300), code or (not ok and tostring(res)) or nil
end
-- (Lobby.ShareGame sits outside this block: it posts through Webhook.post)
Webhook.post = httpPost

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
-- (getgc walks the whole Lua heap and the lobby asks every few seconds: the table found is
-- kept by a weak ref and reused while it still has its items; a new walk at most once a minute)
local gcFound = setmetatable({}, { __mode = "v" })
local gcScanAt = {}
local function gcFind(key, ok)
    local c = gcFound[key]
    if c ~= nil and ok(c) then return c end
    if type(getgc) ~= "function" or os.clock() - (gcScanAt[key] or -math.huge) < 60 then return nil end
    gcScanAt[key] = os.clock()
    local found
    pcall(function()
        for _, v in ipairs(getgc(true)) do
            if type(v) == "table" and ok(v) then found = v break end
        end
    end)
    gcFound[key] = found
    return found
end
local function inventoryData()
    local data
    pcall(function()
        local loader = require(ReplicatedStorage.src.Loader)
        local svc = loader.load_client_service(script, "ItemInventoryServiceClient")
        data = svc.session.inventory.inventory_profile_data
    end)
    if type(data) ~= "table" then
        data = gcFind("normal", function(v) return type(rawget(v, "normal_items")) == "table" end)
    end
    return type(data) == "table" and data or nil
end

-- { [item id] = count } from normal + unique items, whatever shape the game uses.
Lobby.GcFind = gcFind
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
        -- (also kept on the device, AAMacro/losses.txt, newest last, so each loss can be read
        -- and fixed without copying it from Discord; owner 2026-10-24)
        pcall(function()
            local path = "AAMacro/losses.txt"
            local old = isfile(path) and readfile(path) or ""
            if #old > 60000 then old = old:sub(-40000) end
            writefile(path, old .. string.format("=== %s | candy %s | card %s\n%s\n\n", os.date("%Y-%m-%d %H:%M:%S"),
                tostring(Lobby.candy), tostring(Lobby.cardInfo), table.concat(why, "\n")))
        end)
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

-- Discord refuses the whole message when one part is over its limit (field 1024, description
-- 4096, title 256): a long Fool's Hunt report never arrived - every part is cut to fit.
function Webhook.Fit(payload)
    local function cut(v, n) v = tostring(v or "") return #v > n and (v:sub(1, n - 3) .. "...") or v end
    for _, e in ipairs(type(payload) == "table" and payload.embeds or {}) do
        if e.title then e.title = cut(e.title, 256) end
        if e.description then e.description = cut(e.description, 4000) end
        local fields = {}
        for i, f in ipairs(e.fields or {}) do
            if i <= 25 then fields[#fields + 1] = { name = cut(f.name, 256), value = cut(f.value ~= "" and f.value or "-", 1024), inline = f.inline } end
        end
        if e.fields then e.fields = fields end
    end
    return payload
end

function Webhook.SendReport(kind, pings)
    if #Webhook.url < 10 then return false end
    local ok, payload = pcall(Webhook.BuildReport, kind)
    if not ok then
        AutoPlaceModule.Note("webhook: report could not be built - " .. clip(tostring(payload), 80))
        return false
    end
    local sent, why = httpPost(Webhook.url, HttpService:JSONEncode(withPing(Webhook.Fit(payload), pings)))
    AutoPlaceModule.Note("webhook: " .. kind .. " report " .. (sent and "sent" or ("NOT sent - " .. clip(tostring(why), 60))))
    return sent
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
        -- (Fool's Hunt: leaving right after a game ended is the replay teleport, not a kick)
        if State.eventMode and os.clock() - (Webhook.endedAt or -1e9) < 120 then return end
        Webhook.disconnectSent = true
        -- (owner 2026-10-24: removed - every replay / lobby teleport was reported as a disconnect)
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
    -- (a result screen already up when this copy starts - an auto-update at the result screen - is
    -- the game the copy before already reported: counted twice in games.txt otherwise, 2026-10-25)
    local wasStarted, wasResults = false, (pcall(isResultsShowing) and isResultsShowing()) or false
    local unitsBefore, reported
    while not State.unloaded do
        task.wait(1)
        local data = workspace:FindFirstChild("_DATA")
        local started = data and data:FindFirstChild("GameStarted")
        local isStarted = started and started.Value == true
        if isStarted and not wasStarted then
            reported = false
            -- (per-game card memory starts empty: a Replay keeps the script running)
            Lobby.cardsTaken, Lobby.badTaken, Lobby.resTaken, Lobby.regenTaken, Lobby.shieldTaken = nil, nil, nil, nil, nil
            Lobby.candy, Lobby.pendingVote, Lobby.spells, Lobby.buffMain = nil, nil, nil, nil
            Lobby.depthByWave, Lobby.lastDepth, Lobby.lastUnitRows, Lobby.roadReversed = {}, nil, nil, nil
            -- (mainSeen is kept across games, as before: resetting it let weak copies fill the early map)
            AutoPlaceModule.capSeen, AutoPlaceModule.capFails = nil, 0
            startSnap, gameWave = playerSnapshot(), 0
            firstSnap = firstSnap or startSnap
            unitsBefore = #Webhook.url >= 10 and Webhook.OwnedUnits() or nil
        end
        if isStarted then gameWave = math.max(gameWave, waveNow()) end
        wasStarted = isStarted
        local results = isResultsShowing()
        if results and not wasResults and startSnap and not reported then
            reported = true -- (the result screen going away and back is the same game)
            Webhook.endedAt = os.clock()
            Webhook.reportPending = true
            local win = Webhook.ResultWin()
            if win then session.wins = session.wins + 1 else session.losses = session.losses + 1 end
            session.lossStreak = win and 0 or (session.lossStreak or 0) + 1
            pcall(AutoPlaceModule.OnResult, win)
            pcall(Lobby.TowerResult, win)
            if tostring(State.stage or ""):lower():find("daily", 1, true) then
                Lobby.cfg.dailyDoneOn = os.date("%Y-%m-%d")
                pcall(saveConfig)
            end
            -- (Infinity Mansion: a won room offers a first-clear reward that must be claimed before the
            -- next room - left unclaimed, the game sat 20 min and was kicked, 2026-10-25. The call's
            -- arguments were never recorded: tried with none, the answer noted in share_log.txt)
            if win and tostring(State.stage or ""):lower():find("infinity mansion", 1, true) then
                task.spawn(function()
                    task.wait(2)
                    local r = getAARemote("claim_first_clear_rewards")
                    if not r then return end
                    local ok, res = pcall(function()
                        if r:IsA("RemoteEvent") then r:FireServer() return "fired" end
                        return r:InvokeServer()
                    end)
                    pcall(Lobby.ShareLog, "tower first-clear claim: " .. tostring(ok) .. " " .. tostring(res))
                end)
            end
            task.spawn(function(w)
                local ok, err = pcall(Lobby.ShareGame, win, w)
                if not ok then
                    AutoPlaceModule.Note("game data NOT shared - " .. clip(tostring(err), 80))
                    pcall(Lobby.ShareLog, "error: " .. tostring(err))
                end
            end, math.max(gameWave, waveNow()))
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
                pcall(Webhook.SendReport, win and "win" or "loss", pings)
            elseif bagTurnedFull and Webhook.pingBagFull ~= false then
                Webhook.Alert("bag", "⛔ Bag full", "Your bag is full: new drops are lost until you make room.", 15548997)
            end
            Webhook.reportPending = false
            task.spawn(pcall, Lobby.AutoUpdate)
            -- (not in Fool's Hunt: its random copies are not drops - every one was announced)
            -- (owner 2026-10-24: removed - it listed Fool's Hunt copies and lobby units as drops)
            if false and Webhook.pingMythic ~= false and unitsBefore and not State.eventMode then
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
DungeonRun.TYPES = { "HOARD", "CHEST", "SHOP", "BATTLE", "SHRINE", "BOSS", "OPEN" }
DungeonRun.WAITING = "waiting for the room choice"

function DungeonRun.priority()
    local list = {}
    for w in tostring(DungeonRun.roomPriority or ""):upper():gmatch("%a+") do
        for _, t in ipairs(DungeonRun.TYPES) do if w == t then table.insert(list, t) end end
    end
    if #list == 0 then list = { "HOARD", "CHEST", "SHOP", "BATTLE", "SHRINE" } end
    return list
end

-- Room types the Setup window shows (the boss room is always last in the order).
-- (no BATTLE tile - it gives nothing and is always the last choice: owner 2026-10-25)
DungeonRun.ROOM_TYPES = { "HOARD", "CHEST", "SHOP", "SHRINE" }
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
-- (perf review 2026-10-25: Read scanned getgc every 2 s on normal stages and Refresh(nil) read again -
-- two full scans per step. Now: the last read is reused for 2 s, no scan outside a dungeon room / the
-- lobby, and a scan that found nothing holds 25 s)
DungeonRun.MISS_HOLD = 25
function DungeonRun.Read()
    local st = DungeonRun.ReadNow()
    DungeonRun.lastRead = { os.clock(), st }
    return st
end
function DungeonRun.ReadNow()
    local live = DungeonRun.live
    if not live and not (DungeonRun.InRoom() or DungeonRun.InLobby()) then return nil end
    if not live and (DungeonRun.InLobby() or DungeonRun.ChoiceOpen()) then live = DungeonRun.FindLive() end
    if live then return DungeonRun.FromLive(live) end
    local best, bestScore
    -- the table found last time is read again while it still looks like the run
    local last = DungeonRun.runTable
    if last and DungeonRun.score(last) >= 2 then best = last end
    if not best and type(getgc) == "function" and os.clock() - (DungeonRun.missAt or -1e9) >= DungeonRun.MISS_HOLD then
        DungeonRun.missAt = os.clock()
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
    DungeonRun.missAt = nil
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

-- One status line (owner 2026-10-25): "Depth 6/20 • Lives 3 • Next: Future City (weak to fire x2.8)",
-- then what the bot is doing.
function DungeonRun.StatusText(st)
    local parts = {}
    if not DungeonRun.enabled then table.insert(parts, "Off") end
    if st then
        table.insert(parts, string.format("Depth %s/20", tostring(st.depth or "?")))
        table.insert(parts, "Lives " .. tostring(st.hearts or "?"))
        if st.live and #st.rooms > 0 and not st.ended and DungeonRun.enteredTable ~= st.table then
            local r = DungeonRun.mode == "Auto" and DungeonRun.AutoPick(st.rooms, st.hearts) or DungeonRun.PickRoom(st.rooms) or st.rooms[1]
            if r then table.insert(parts, "Next: " .. tostring(r.label or r.type or r.id) .. " (" .. DungeonRun.Reason(r) .. ")") end
        end
    end
    if DungeonRun.enabled and DungeonRun.status then table.insert(parts, tostring(DungeonRun.status)) end
    return #parts > 0 and table.concat(parts, " • ") or "Off"
end

function DungeonRun.Refresh(st)
    if not UIRef.dungeonStatus then return end
    if st == nil then
        local last = DungeonRun.lastRead
        if last and os.clock() - last[1] < 2 then st = last[2] or false else st = DungeonRun.Read() end
    end
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
    local sel, seq = DungeonRun.selSeq or 0, DungeonRun.liveSeq or 0
    local ok, res = pcall(function()
        if remote:IsA("RemoteFunction") then return remote:InvokeServer(arg) end
        remote:FireServer(arg)
        return true
    end)
    local deadline = os.clock() + 5
    local legacy = before ~= nil and not before.live
    while os.clock() < deadline do
        if legacy then
            local now = DungeonRun.Read()
            if now and DungeonRun.Changed(before, now) then return true, res end
        end
        -- (live run: the game answers a room with dungeon_selected_changed, then teleports)
        if (DungeonRun.selSeq or 0) ~= sel or (DungeonRun.liveSeq or 0) ~= seq then return true, res end
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
    -- (BATTLE gives nothing: after every chosen type, then the boss room)
    local order = {}
    for _, t in ipairs(DungeonRun.priority()) do
        if t ~= "BATTLE" and t ~= "BOSS" then table.insert(order, t) end
    end
    table.insert(order, "BATTLE")
    table.insert(order, "BOSS")
    for _, want in ipairs(order) do
        if want ~= "SHRINE" or DungeonRun.ShrineOK(DungeonRun.lives) then
            for _, r in ipairs(rooms or {}) do
                if DungeonRun.HasType(r, want) then return r end
            end
        end
    end
end

-- One step of the auto run. Returns seconds to wait.
-- In the lobby the room choice only opens in the Dungeon Run window (friends' scripts sat in the lobby
-- for the whole run - 2026-10-25). With a run going (or keys and no run) and the choice still closed
-- after 8 s: tap the left menu's "Dungeon" button (PlayerGui.LeftUI_test.Buttons.Dungeon), 2 s later the
-- window's green Start (DungeonUI ... StartHolder.Main.Start) when it shows; again 20 s later at most.
DungeonRun.OPEN_AFTER, DungeonRun.OPEN_EVERY = 8, 20
function DungeonRun.StartButton()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local holder = ui and ui:FindFirstChild("StartHolder", true)
    local b = holder and holder:FindFirstChild("Start", true)
    if b and b:IsA("GuiButton") and isOnScreen(b) then return b end
end
function DungeonRun.OpenWindowStep(st)
    if DungeonRun.ChoiceOpen() then DungeonRun.closedSince = nil return nil end
    -- (You Died! first: the green Start under it only answers "error")
    if Lobby.ButtonFor("You Died!") then return nil end
    local running = st ~= nil and st.live and #st.rooms > 0 and not st.ended
    local keys = DungeonRun.KeyCount()
    if not running and not (keys and keys > 0) then return nil end
    DungeonRun.closedSince = DungeonRun.closedSince or os.clock()
    if os.clock() - DungeonRun.closedSince < DungeonRun.OPEN_AFTER then return nil end
    if os.clock() - (DungeonRun.openTryAt or -1e9) < DungeonRun.OPEN_EVERY then return nil end
    DungeonRun.openTryAt = os.clock()
    local menu = Lobby.ButtonFor("Dungeon")
    if not menu then
        pcall(Lobby.ShareLog, "dungeon: lobby - no Dungeon button on screen")
        return nil
    end
    Lobby.TapGui(menu)
    pcall(Lobby.ShareLog, "dungeon: lobby - tapped Dungeon (" .. (running and "run going" or ("keys " .. tostring(keys))) .. ")")
    task.wait(2)
    local start = DungeonRun.StartButton()
    if start then
        Lobby.TapGui(start)
        pcall(Lobby.ShareLog, "dungeon: lobby - tapped the window's green Start")
    end
    DungeonRun.status = "opened the Dungeon window"
    DungeonRun.Refresh(st)
    return 2
end

-- DUNGEON SCREENS (2026-10-25: every stuck run so far was a screen nobody handled). DungeonRun.Screen()
-- names the one on screen; the watchdog (DungeonRun.Watchdog, lobby loop) taps its primary button when
-- it stays 20 s with no progress (no dungeon_changed / room entered / lives change).
--   screen          detected by                                    action (who)                     next screen
--   click_continue  TextLabel "(Click anywhere to continue)"       tap the popup (Lobby.ClickAnywhere) next reward / room result
--   you_died        label "You Died!"                              Continue, then chests, continue_death, lobby (Lobby.DiedStep) run over -> lobby
--   shrine_page     DungeonUI ShrineRoom on screen / page _t "7"   offer scored: ACCEPT or DENY (ShrineStep) room choice
--   shop_page       DungeonUI ShopSelection / page _t "1"          buy_shop + continue_shop (PageStep) next page / room choice
--   chest_page      DungeonUI OpenTreasure / page _t "6"           open_chest(true) + continue_shop  room choice
--   room_popup      DungeonUI button "Enter" (LevelInfo)           Enter after 8 s (EnterPopupStep)  loading into the room
--   room_choice     DungeonUI LevelAttributes tiles on screen      dungeon_enter_room (LiveStep)     room popup / loading
--   start_page      DungeonUI StartHolder.Main.Start               dungeon_start / tap Start         room choice
--   room_result     Dungeon Room + result screen                   Next, then Open Dungeon (Lobby.Loop) room choice / You Died
--   in_room         Dungeon Room level data, no result yet         Auto Place plays it               room result
--   lobby           _MAP_CONFIG.IsLobby                            open the window (OpenWindowStep)  room choice / start page
--   run over        dungeon_changed({})                            next run when keys (TryStart)     start page / lobby
DungeonRun.PRIMARY = {
    room_popup = { "enter" }, room_result = { "next", "open dungeon" }, chest_page = { "open", "continue", "close" },
    shop_page = { "continue", "leave", "close" }, shrine_page = {}, start_page = { "start" },   -- (shrine: ShrineStep decides)
    room_choice = {},
}
function DungeonRun.Screen()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return "none" end
    if Lobby.ClickLabel() then return "click_continue", gui end
    local died = Lobby.ButtonFor("You Died!")
    if died then return "you_died", died:FindFirstAncestorWhichIsA("LayerCollector") or gui end
    local ui = gui:FindFirstChild("DungeonUI")
    if ui and (not ui:IsA("LayerCollector") or ui.Enabled) then
        for _, p in ipairs({ { "ShrineRoom", "shrine_page" }, { "ShopSelection", "shop_page" }, { "OpenTreasure", "chest_page" } }) do
            local page = ui:FindFirstChild(p[1], true)
            if page and isOnScreen(page) then return p[2], page end
        end
        if Lobby.ButtonFor("Enter", ui) then return "room_popup", ui end
        if DungeonRun.ChoiceOpen() then return "room_choice", ui end
        local start = DungeonRun.StartButton()
        if start then return "start_page", start.Parent end
    end
    if DungeonRun.InRoom() then
        if AutoFarmModule.ResultsShowing() then return "room_result", gui end
        return "in_room", gui
    end
    if DungeonRun.InLobby() then return "lobby", gui end
    return "none", gui
end
-- A visible button under root whose text / label / name is the word (exact text first, then contains).
function DungeonRun.FindButton(root, word)
    local best
    for _, b in ipairs(root and root:GetDescendants() or {}) do
        if b:IsA("GuiButton") and isOnScreen(b) and not isOwnGui(b) then
            local texts = { string.lower(b.Name) }
            if b:IsA("TextButton") then table.insert(texts, string.lower(tostring(b.Text))) end
            for _, d in ipairs(b:GetDescendants()) do
                if d:IsA("TextLabel") then table.insert(texts, string.lower(tostring(d.Text))) end
            end
            for _, t in ipairs(texts) do
                if t == word then return b end
                if not best and t:find(word, 1, true) then best = b end
            end
        end
    end
    return best
end
-- The same dungeon screen for 20 s with nothing moving: tap its primary button (one tap per 10 s), log
-- "STUCK <screen> -> ...", count it (shared in the AASTAT row) and dump the screen to dungeon_ui_dump.
-- In the room, in the lobby and on You Died! (its own careful sequence) nothing is tapped here.
DungeonRun.STUCK_AFTER, DungeonRun.STUCK_EVERY = 20, 10
function DungeonRun.Watchdog()
    if not DungeonRun.enabled then return end
    local name, root = DungeonRun.Screen()
    local progress = table.concat({ tostring(DungeonRun.liveSeq or 0), tostring(DungeonRun.enteredAt or 0), tostring(DungeonRun.selSeq or 0) }, ":")
    local w = DungeonRun.watch
    if not w or w.name ~= name or w.progress ~= progress then
        DungeonRun.watch = { name = name, progress = progress, since = os.clock() }
        return
    end
    if name == "in_room" or name == "lobby" or name == "none" or name == "click_continue" or name == "you_died" then return end
    if os.clock() - w.since < DungeonRun.STUCK_AFTER or os.clock() - (w.tapAt or -1e9) < DungeonRun.STUCK_EVERY then return end
    w.tapAt = os.clock()
    local button
    for _, word in ipairs(DungeonRun.PRIMARY[name] or {}) do
        button = DungeonRun.FindButton(root, word)
        if button then break end
    end
    if button then Lobby.TapGui(button) end
    DungeonRun.stuck = (DungeonRun.stuck or 0) + 1
    DungeonRun.lastStuck = name
    DungeonRun.stuckTotal = (DungeonRun.stuckTotal or 0) + 1
    local line = "STUCK " .. name .. " -> " .. (button and ("tapped " .. button.Name) or "no button to tap")
    pcall(Lobby.ShareLog, "dungeon: " .. line)
    pcall(DungeonRun.Log, line)
    -- the screen's buttons and texts, so an unknown screen can be handled later
    pcall(function()
        if not hasFileApi() then return end
        local lines = { "# " .. line .. " " .. os.date("%Y-%m-%d %H:%M:%S") }
        for _, d in ipairs(root:GetDescendants()) do
            if #lines >= 200 then break end
            if (d:IsA("GuiButton") or d:IsA("TextLabel")) and isOnScreen(d) then
                table.insert(lines, d:GetFullName() .. " | " .. d.ClassName .. ((d:IsA("TextLabel") or d:IsA("TextButton")) and (" | text=" .. clip(tostring(d.Text), 50)) or ""))
            end
        end
        DungeonRun.Append("AAMacro/dungeon_ui_dump.txt", "\n" .. table.concat(lines, "\n"), 300000)
    end)
    saveConfig()
end

-- The room popup ("Dungeon Room / <map> / Depth n / Difficulty xN" with a green Enter) left open: a
-- friend's run stood there (2026-10-25). With it on screen 8 s and no room entered meanwhile, Enter is
-- tapped by GUI (10 s apart at most) - also the fallback when dungeon_enter_room changed nothing.
function DungeonRun.EnterPopupStep()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local enter = ui and Lobby.ButtonFor("Enter", ui)
    if not enter then DungeonRun.popupSince = nil return end
    DungeonRun.popupSince = DungeonRun.popupSince or os.clock()
    if os.clock() - DungeonRun.popupSince < 8 then return end
    if os.clock() - (DungeonRun.enteredAt or -1e9) < 8 then return end
    if os.clock() - (DungeonRun.enterTapAt or -1e9) < 10 then return end
    DungeonRun.enterTapAt = os.clock()
    Lobby.TapGui(enter)
    pcall(Lobby.ShareLog, "dungeon: room popup open 8 s - tapped Enter")
    pcall(DungeonRun.Log, "room popup open 8 s - tapped Enter (" .. enter:GetFullName() .. ")")
end
-- After a SHRINE room the game shows its offer (page _t "7", DungeonUI ShrineRoom): "Do you accept the
-- shrine's offer?", rows under "YOU WILL RECEIVE:" (name + effect; curses marked [*]) and ACCEPT / DENY
-- (owner screenshot 2026-10-25). Every row is read (the list scrolls: hidden rows too) and scored -
-- buffs and chests plus, curses minus by how bad they are for this team - ACCEPT when the total is
-- above 0; with 1 life left any curse is DENIED unless a gold chest comes with it. The accept / deny
-- call is not recorded yet: the button is tapped by GUI (Watch logs the call the game sends).
DungeonRun.SHRINE_SKIP = { "shrine", "accept", "deny", "do you accept", "you will receive" }
-- An item's "<name> <effect>": our catalog by the game's id, else the wiki's list by name (the id read as
-- words: philosophers_stone -> Philosopher's Stone); the game's id stays the key.
function DungeonRun.ItemText(id)
    id = tostring(id or "")
    for _, kind in ipairs({ "shop", "shrine" }) do
        for _, it in ipairs(DungeonRun.ItemList(kind)) do
            if it.id == id and it.effect ~= "(seen in game)" then return it.name .. " " .. it.effect end
        end
    end
    -- (the longest matching name: "elf_bow" is Elf Bow, not Bow)
    local norm = string.lower(id):gsub("[^a-z]", "")
    local best, bestLen
    for name, effect in pairs(DungeonRun.WIKI_EFFECTS) do
        local n = name:gsub("[^a-z]", "")
        if norm ~= "" and #n >= 3 and (norm:find(n, 1, true) or (#norm >= 6 and n:find(norm, 1, true))) and (not bestLen or #n > bestLen) then
            best, bestLen = name .. " " .. effect, #n
        end
    end
    return best or id
end
-- What an item / curse is worth to THIS team (AA wiki effects, owner 2026-10-25): damage only by our
-- share of that damage type (Archmage's Hat +250% magic x our magic share), cost cuts by size (more
-- before depth 10), Philosopher's Stone highest, chest luck / range / cooldown in between; curses by
-- danger - Frenzy / Health / Flight with no air unit worst, Wind / Armor / Shielding / Regen middle,
-- Money / Shopping small, Chaos bad - x1.5 at 2 lives or less. Returns value, isCurse.
DungeonRun.CURSE_DANGER = { { "frenzy", 6 }, { "health", 6 }, { "hp", 6 }, { "flight", 8 }, { "fly", 8 }, { "chaos", 4 },
    { "wind", 3 }, { "armor", 3 }, { "shield", 3 }, { "regen", 3 }, { "vampir", 3 }, { "burst", 3 }, { "erupt", 2.5 },
    { "explo", 2.5 }, { "speed", 4 }, { "faster", 4 }, { "money", 1 }, { "hoard", 1 }, { "shop", 1 } }
function DungeonRun.ItemValue(text, lives)
    local low = string.lower(tostring(text))
    local pct = tonumber(low:match("(%d+)%%")) or 0
    if low:find("curse", 1, true) or low:find("[*]", 1, true) then
        local v = 2
        for _, b in ipairs(DungeonRun.CURSE_DANGER) do
            if low:find(b[1], 1, true) then
                v = b[2]
                if (b[1] == "flight" or b[1] == "fly") and DungeonRun.TeamHitsAir() then v = 2 end
                break
            end
        end
        if lives ~= nil and lives <= 2 then v = v * 1.5 end
        return -v, true
    end
    local share = DungeonRun.TeamShare()
    -- (Philosopher's Stone turns the chests held NOW into rare ones - worth the normal chests in hand, nothing
    -- with none: owner 2026-10-26, it was bought first and early before)
    if low:find("philosoph", 1, true) then
        local res = type(DungeonRun.live) == "table" and type(DungeonRun.live._resources) == "table" and DungeonRun.live._resources or {}
        return (tonumber(res.treasure) or 0) * 1.5, false
    end
    if low:find("rare chest", 1, true) or (low:find("gold", 1, true) and low:find("chest", 1, true)) then return 4, false end
    if low:find("cost", 1, true) then return pct / 10 * ((DungeonRun.lastDepth or 0) < 10 and 1.3 or 1), false end
    -- (the shop writes "Phys Crit Chance": "phys" counts as physical)
    for _, t in ipairs({ { "magic", "magic" }, { "physical", "physical" }, { "physical", "phys" }, { "true", "true" } }) do
        local word = t[2]
        if low:find(word .. " dmg", 1, true) or low:find(word .. " damage", 1, true) then return pct / 100 * 4 * (share[t[1]] or 0), false end
        if low:find(word .. " crit", 1, true) then return pct / 100 * 1.5 * (share[t[1]] or 0), false end
    end
    -- (chest luck pays on the chests still to come: more early in the run)
    if low:find("chest luck", 1, true) then
        local depth = DungeonRun.lastDepth or 0
        return pct / 40 * (depth < 10 and 1.5 or (depth < 15 and 1 or 0.5)), false
    end
    if low:find("cooldown", 1, true) or low:find("attack speed", 1, true) then return pct / 8, false end
    if low:find("range", 1, true) then return pct / 100 * 2, false end
    if low:find("boss", 1, true) then return pct / 50, false end
    if low:find("slower", 1, true) then return pct / 15, false end
    if low:find("star remnant", 1, true) then return 1.5, false end
    if low:find("chest", 1, true) then return 2.5, false end
    if low:find("boots", 1, true) then return 2.5, false end
    if low:find("attack", 1, true) or low:find("dmg", 1, true) or low:find("damage", 1, true) then return pct / 30, false end
    -- (an effect we do not know: worth too little to spend coins on, a small plus in a shrine offer)
    return 0.2, false
end
-- The offer's rows, each "name / effect" with its value. The page data names the offer by item id
-- ({ _t = "7", data = { {id = "boots"}, {id = "chest_mock_item"}, {id = "_curse_super_armored"} } }, device
-- 21:31 2026-10-25); without it the page's rows are read: every label under one row of the list joined
-- (the effect wraps: "... Armored Enemies" + "Chance"), resource numbers at the bottom skipped.
function DungeonRun.ShrineRows(page, data)
    local rows = {}
    for _, it in ipairs(type(data) == "table" and data or {}) do
        local id = type(it) == "table" and tostring(it.id or "") or tostring(it)
        if id ~= "" then
            local text = id
            for _, kind in ipairs({ "shrine", "shop" }) do
                for _, item in ipairs(DungeonRun.ItemList(kind)) do
                    if item.id == id then text = id .. " / " .. item.name .. " / " .. item.effect end
                end
            end
            if text == id then text = DungeonRun.ItemText(id) end
            if id:find("^_curse") and not text:lower():find("curse", 1, true) then text = text .. " / curse" end
            table.insert(rows, text)
        end
    end
    if #rows > 0 or not page then return rows end
    local list = page:FindFirstChildWhichIsA("ScrollingFrame", true) or page
    local groups, order = {}, {}
    for _, d in ipairs(list:GetDescendants()) do
        if d:IsA("TextLabel") and not d:FindFirstAncestorWhichIsA("GuiButton") then
            local t = tostring(d.Text):gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
            local low, skip = string.lower(t), t == "" or t:match("^[%d%s,%.xX/]+$") ~= nil
            for _, w in ipairs(DungeonRun.SHRINE_SKIP) do
                if low == w or low:find(w, 1, true) == 1 then skip = true end
            end
            if not skip then
                -- the row: the label's ancestor right under the list
                local key = d
                while key.Parent and key.Parent ~= list do key = key.Parent end
                if not groups[key] then groups[key] = {} table.insert(order, key) end
                table.insert(groups[key], t)
            end
        end
    end
    for _, key in ipairs(order) do table.insert(rows, table.concat(groups[key], " ")) end
    return rows
end
function DungeonRun.ShrineOffer(page, lives, data)
    local rows, total, curses, gold = {}, 0, 0, false
    for _, text in ipairs(DungeonRun.ShrineRows(page, data)) do
        local value, curse = DungeonRun.ItemValue(text, lives)
        if curse then curses = curses + 1 end
        local low = string.lower(text)
        if not curse and (low:find("gold", 1, true) or low:find("rare chest", 1, true) or low:find("philosoph", 1, true)) then gold = true end
        total = total + value
        table.insert(rows, string.format("%s (%+.1f)", text, value))
    end
    return rows, total, curses, gold
end
function DungeonRun.ShrineStep(st, seq)
    if DungeonRun.shrineTried == seq then
        DungeonRun.status = "shrine: waiting for the game"
        return true
    end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local page = ui and ui:FindFirstChild("ShrineRoom", true)
    if not page or not isOnScreen(page) then return false end
    local lives = st and st.hearts or DungeonRun.lives
    local live = type(DungeonRun.live) == "table" and DungeonRun.live.current_shops
    local data = type(live) == "table" and type(live[1]) == "table" and tostring(live[1]._t) == "7" and live[1].data or nil
    pcall(DungeonRun.LearnRowIcons, "ShrineRoom", data)
    pcall(DungeonRun.LearnRowTexts, "ShrineRoom", data, "shrine")
    local rows, total, curses, gold = DungeonRun.ShrineOffer(page, lives, data)
    local accept = total > 0
    if lives ~= nil and lives <= 1 and curses > 0 and not gold then accept = false end
    -- (My picks: an offered item that is not selected = DENY)
    local unpicked
    if DungeonRun.mode ~= "Auto" and type(data) == "table" then
        for _, it in ipairs(data) do
            local id = type(it) == "table" and it.id and string.lower(tostring(it.id))
            if id and not DungeonRun.ItemSelected(id) then unpicked, accept = id, false break end
        end
    end
    local button = DungeonRun.FindButton(page, accept and "accept" or "deny")
    if not button then return false end
    DungeonRun.shrineTried = seq
    Lobby.TapGui(button)
    local line = string.format("SHRINE %s: %s | score %.1f%s", accept and "accept" or "deny", table.concat(rows, "; "), total,
        unpicked and (" (not picked: " .. unpicked .. ")") or ((lives ~= nil and lives <= 1 and curses > 0 and not gold) and " (1 life: no curses)" or ""))
    DungeonRun.status = "shrine: " .. (accept and "accepted" or "denied")
    pcall(Lobby.ShareLog, "dungeon: " .. line)
    pcall(DungeonRun.Log, line .. " - tapped " .. button:GetFullName())
    DungeonRun.Refresh(st)
    return true
end

function DungeonRun.Step()
    pcall(DungeonRun.EnterPopupStep)
    -- (the shrine page also opens inside the room, over the map, right after the win - 2026-10-25)
    pcall(DungeonRun.ShrineStep, nil, DungeonRun.liveSeq or 0)
    pcall(DungeonRun.ScanData)
    pcall(DungeonRun.LearnIcons)
    pcall(DungeonRun.LearnItemIcons)
    local st = DungeonRun.Read()
    -- (only a fresh dungeon_changed shows a run still going: an old copy in memory still has rooms)
    if DungeonRun.pendingStart and DungeonRun.InLobby() and not (st and st.live and st.table == DungeonRun.live and #st.rooms > 0 and not st.ended) then
        return DungeonRun.TryStart()
    end
    if DungeonRun.InLobby() then
        local wait = DungeonRun.OpenWindowStep(st)
        if wait then return wait end
    end
    if st and st.live then return DungeonRun.LiveStep(st) end
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
    -- ("You Died!" is handled only by Lobby.DiedStep: a second sender here doubled the calls)
    if st.dead then
        DungeonRun.status = "lost a room"
        DungeonRun.Refresh(st)
        return 2
    end
    DungeonRun.deathTried = nil
    local room = DungeonRun.PickRoom(st.rooms)
    if not room then
        DungeonRun.status = "no room fits - pick one yourself"
        DungeonRun.Refresh(st)
        return 2
    end
    -- (the game sends the room as a string: dungeon_enter_room("2") - Watch, real game 2026-10-25)
    local arg = room.id ~= nil and room.id or room.index
    if arg ~= nil then arg = tostring(arg) end
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

-- The run as the game sends it: endpoints.server_to_client.dungeon_changed (Watch, real game
-- 2026-10-25, work/dungeon_samples.txt): { _started, _items = { { id = "_curse_money" } },
-- _resources = { money, treasure, treasure_gold }, current_shops, next = { ["1"] = room, ["2"] = room,
-- next1 = { rooms after room 1 }, next2 = ... } }, room = { _d = depth, _t = tags (meaning unknown),
-- _l = { _dungeon = { choice_str, depth }, _lobby_difficulty_scale, map, boss, _location_name,
-- _weak_against = { { damage_type = "air_damage", amplification = 3.1 } }, _strong_against } }.
-- dungeon_changed({}) = the run is over (after "You Died!" Continue).
-- In a Dungeon Room game (its level is "Dungeon Room (Depth N)", the level data has _dungeon).
function DungeonRun.InRoom()
    if DungeonRun.InLobby() then return false end
    if string.lower(tostring(State.stage or "")):find("dungeon room", 1, true) then return true end
    local ok, d = pcall(Stage.levelData)
    return ok and type(d) == "table" and (d._dungeon ~= nil or string.lower(tostring(d.name or "")):find("dungeon room", 1, true) ~= nil)
end
function DungeonRun.Norm(kind)
    return (string.lower(tostring(kind or "")):gsub("_damage$", ""))
end
function DungeonRun.AsList(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _, x in pairs(v) do table.insert(out, x) end
    return out
end
-- tags as text ("2,7,_curse_fly"), for the log
function DungeonRun.TagText(tags)
    local parts = {}
    for k, v in pairs(type(tags) == "table" and tags or {}) do
        table.insert(parts, type(v) == "table" and tostring(v.id or k) or (v == true and tostring(k) or tostring(k) .. "=" .. tostring(v)))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end
-- _t codes seen in the real game (2026-10-25): a room's tags are the pages that follow it, the same
-- codes as current_shops: "1" = shop ({_t = "1", data = {items}}), "6" = chest page ({_t = "6",
-- data = true}: dungeon_open_chest(true) used a gold chest) - the depth-10 room tagged 1,6 was
-- followed by a shop and a chest page. "3" = chest (rooms tagged "3,_curse_..." showed
-- "CURSE + CHEST"), "7" = shop (one sample), key "0" = { id = "_curse_..." } = a curse.
-- (corrected 2026-10-25): a code is the POSITION of the attribute picture in each tile's LevelAttributes
-- (Curse, shop, money, treasure_gold, treasure, bossfinal, chestopen, shrine = 0..7, dungeon_ui_dump):
-- "0" curse, "1" shop, "2" hoard, "3" gold chest, "4" chest, "5" boss, "6" chest-opening page, "7" shrine.
-- Checked: screen "1=HOARD _t 2 | 3=HOARD+CHEST _t 2,4" (device 2026-10-25), pages {_t = "1"} shop and
-- {_t = "6"} chest opening. The old map called 7 a shop: two rooms with {7} and {1,2} both read SHOP.
DungeonRun.TAG_TYPES = { ["1"] = "SHOP", ["2"] = "HOARD", ["3"] = "GOLD", ["4"] = "CHEST", ["5"] = "BOSS", ["6"] = "OPEN", ["7"] = "SHRINE" }
-- A room's types as a set ({ CHEST = true, CURSE = true }), from its _t tags.
function DungeonRun.TagTypes(tags)
    local set = {}
    for k, v in pairs(type(tags) == "table" and tags or {}) do
        if v == true and DungeonRun.TAG_TYPES[tostring(k)] then set[DungeonRun.TAG_TYPES[tostring(k)]] = true end
        if type(v) == "table" and tostring(v.id or ""):find("^_curse") then set.CURSE = true end
        local w = string.upper(tostring(type(v) == "table" and (v.type or v.id) or v))
        for _, t in ipairs(DungeonRun.TYPES) do
            if w == t then set[t] = true end
        end
    end
    if set.GOLD then set.CHEST = true end   -- a gold chest is a chest too (room lists, My picks)
    return set
end
-- the main type of a set (first in TYPES order; a curse is only an extra)
function DungeonRun.MainType(set)
    for _, t in ipairs(DungeonRun.TYPES) do if set[t] then return t end end
end
function DungeonRun.TagType(tags) return DungeonRun.MainType(DungeonRun.TagTypes(tags)) end
function DungeonRun.HasType(r, t) return r.type == t or (r.types ~= nil and r.types[t] == true) end
function DungeonRun.TypeText(r)
    local parts = {}
    for _, t in ipairs({ "CURSE", "HOARD", "GOLD", "CHEST", "OPEN", "SHOP", "BATTLE", "SHRINE", "BOSS" }) do
        if DungeonRun.HasType(r, t) then table.insert(parts, t) end
    end
    return table.concat(parts, "+")
end

-- The Dungeon Run window (PlayerGui.DungeonUI) shows what the data lacks. Real layout (dungeon_ui_dump,
-- 18:23 2026-10-25): LevelSelection.Inset.MainRow.Frame = a room tile (97x97, this depth's choices, left
-- to right = 1, 2, 3), its FrameTop.Frame tiles (53x53) = the rooms after it; each tile has
-- Main.LevelAttributes with one ImageLabel per attribute, NAMED by type (money, treasure, treasure_gold,
-- shop, shrine, bossfinal, chestopen, Curse) and visible when the room has it; a tile with none is a
-- plain battle. Configuration.Frame is the game's template (0x0): skipped. Lives: a visible "n/m" label.
DungeonRun.ATTR_TYPES = { money = "HOARD", treasure = "CHEST", treasure_gold = "GOLD", chestopen = "OPEN", shop = "SHOP",
    shrine = "SHRINE", bossfinal = "BOSS", curse = "CURSE" }
function DungeonRun.ReadScreen()
    local out = {}
    pcall(function()
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = gui and gui:FindFirstChild("DungeonUI")
        if not ui or (ui:IsA("LayerCollector") and not ui.Enabled) then return end
        local tiles = {}
        for _, d in ipairs(ui:GetDescendants()) do
            if d:IsA("TextLabel") and not out.lives and isOnScreen(d) then
                local a, b = tostring(d.Text):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
                if a and tonumber(b) <= 10 then out.lives, out.maxLives = tonumber(a), tonumber(b) end
            end
            if d.Name == "LevelAttributes" and isOnScreen(d) and not d:FindFirstAncestor("Configuration") then
                local tile = d.Parent and d.Parent.Parent
                local size = tile and tile:IsA("GuiObject") and tile.AbsoluteSize
                if size and size.X > 0 then
                    local types = {}
                    for _, x in ipairs(d:GetChildren()) do
                        local t = (x:IsA("ImageLabel") or x:IsA("ImageButton")) and x.Visible and DungeonRun.ATTR_TYPES[string.lower(x.Name)]
                        if t then types[t] = true end
                        if t == "GOLD" then types.CHEST = true end
                    end
                    if not DungeonRun.MainType(types) then types.BATTLE = true end
                    table.insert(tiles, { types = types, x = tile.AbsolutePosition.X, y = tile.AbsolutePosition.Y, size = size.X * size.Y })
                end
            end
        end
        local biggest = 0
        for _, t in ipairs(tiles) do biggest = math.max(biggest, t.size) end
        local big = {}
        for _, t in ipairs(tiles) do if t.size >= biggest * 0.7 then table.insert(big, t) end end
        table.sort(big, function(p, q) if p.x ~= q.x then return p.x < q.x end return p.y < q.y end)
        out.tiles = big
    end)
    return out
end

-- The room choice is open on screen: the Dungeon Run window shows room tiles (read every 2 s at most).
function DungeonRun.ChoiceOpen()
    if os.clock() - (DungeonRun.choiceAt or -1e9) < 2 then return DungeonRun.choiceOpen end
    DungeonRun.choiceAt = os.clock()
    local scr = DungeonRun.ReadScreen()
    DungeonRun.choiceOpen = scr.tiles ~= nil and #scr.tiles > 0
    return DungeonRun.choiceOpen
end

-- Every dungeon_changed / dungeon_selected_changed payload and screen read, for checking the
-- _t map after a run (lobby_watch keeps only 20 KB): AAMacro/dungeon_log.txt, last ~200 KB.
-- Adds text to a file: appendfile when the executor has it (the whole file is not rewritten per line),
-- trimmed to the last 3/4 of cap every 100 appends; else read + write.
function DungeonRun.Append(path, text, cap)
    if not hasFileApi() then return end
    if type(appendfile) == "function" and isfile(path) then
        appendfile(path, text)
        DungeonRun.appends = (DungeonRun.appends or 0) + 1
        if DungeonRun.appends % 100 == 0 then
            local old = readfile(path)
            if #old > cap then writefile(path, old:sub(-math.floor(cap * 0.75))) end
        end
        return
    end
    local old = isfile(path) and readfile(path) or ""
    if #old > cap then old = old:sub(-math.floor(cap * 0.75)) end
    writefile(path, old .. text)
end
function DungeonRun.Log(text)
    DungeonRun.Append("AAMacro/dungeon_log.txt", os.date("%H:%M:%S ") .. text .. "\n", 200000)
end
function DungeonRun.LiveRooms(nextT)
    local rooms = {}
    if type(nextT) ~= "table" then return rooms end
    for k, r in pairs(nextT) do
        if type(r) == "table" and type(r._l) == "table" then
            local dn = type(r._l._dungeon) == "table" and r._l._dungeon or {}
            local id = tostring(dn.choice_str or k)
            local types = DungeonRun.TagTypes(r._t)
            table.insert(rooms, { id = id, index = tonumber(id), l = r._l, depth = tonumber(r._d or dn.depth), tags = r._t,
                label = r._l._location_name or r._l.map, kids = nextT["next" .. id], types = types, type = DungeonRun.MainType(types) })
        end
    end
    table.sort(rooms, function(a, b) return (tonumber(a.id) or 99) < (tonumber(b.id) or 99) end)
    return rooms
end
-- the game's own copy of the run (lobby after a reload, before any dungeon_changed came)
function DungeonRun.FindLive()
    -- (a found copy is kept 60 s while its rooms' depth is unchanged - the 10 s rescan of getgc in the
    -- dungeon lobby was a hitch, lag review 2026-10-26)
    local held = DungeonRun.liveGc
    local same = held and DungeonRun.liveGcDepth == (DungeonRun.LiveRooms(rawget(held, "next") or {})[1] or {}).depth
    local hold = held and (same and 60 or 0) or DungeonRun.MISS_HOLD
    if os.clock() - (DungeonRun.findAt or -1e9) < hold then return DungeonRun.liveGc end
    DungeonRun.findAt = os.clock()
    DungeonRun.liveGc = nil
    if type(getgc) ~= "function" then return nil end
    -- (old copies stay in memory after the run moves on: depth 18 was "entered" four times while the
    -- run went 18 -> 21, 17:12-17:42 2026-10-25. The copy with the deepest rooms is the current one)
    pcall(function()
        local bestDepth = -1
        for _, t in ipairs(getgc(true)) do
            if type(t) == "table" and type(rawget(t, "next")) == "table" and (rawget(t, "_started") ~= nil or rawget(t, "_resources") ~= nil) then
                local rooms = DungeonRun.LiveRooms(rawget(t, "next"))
                local d = rooms[1] and rooms[1].depth or -1
                if #rooms > 0 and d > bestDepth then DungeonRun.liveGc, bestDepth = t, d end
            end
        end
        DungeonRun.liveGcDepth = bestDepth
    end)
    return DungeonRun.liveGc
end
function DungeonRun.FromLive(live)
    local st = { live = true, table = live }
    st.rooms = DungeonRun.LiveRooms(live.next)
    st.depth = st.rooms[1] and st.rooms[1].depth or DungeonRun.lastDepth
    st.maxDepth = 20
    st.hearts = DungeonRun.lives
    -- the Dungeon Run window, when open: lives and the room types under each tile
    local scr = DungeonRun.ReadScreen()
    if scr.lives then st.hearts, st.maxHearts = scr.lives, scr.maxLives end
    if scr.tiles and #scr.tiles > 0 and #scr.tiles == #st.rooms then
        local seen = {}
        for i, r in ipairs(st.rooms) do
            -- (the tile's own pictures are what the game shows: they replace the guess from _t)
            r.types = {}
            for t in pairs(scr.tiles[i].types) do r.types[t] = true end
            r.type = DungeonRun.MainType(r.types)
            table.insert(seen, r.id .. "=" .. DungeonRun.TypeText(r) .. " _t " .. DungeonRun.TagText(r.tags))
        end
        -- (screen vs data, once per room set: checks the _t code map after a run)
        local line = table.concat(seen, " | ")
        if line ~= DungeonRun.screenLine then
            DungeonRun.screenLine = line
            pcall(DungeonRun.Log, "screen rooms " .. line .. " lives " .. tostring(scr.lives) .. "/" .. tostring(scr.maxLives))
        end
    end
    local res = type(live._resources) == "table" and live._resources or {}
    st.coins, st.silverKeys, st.goldKeys = tonumber(res.money), tonumber(res.treasure), tonumber(res.treasure_gold)
    st.ended = next(live) == nil or (#st.rooms == 0 and (DungeonRun.lastDepth or 0) >= 20)
    return st
end

-- Share of our damage by type (normalised: "air", "dark" ...), each unit by its base dps; a
-- secondary type counts half. Placed units, else the team, else the event Always list.
function DungeonRun.TeamShare()
    local share, total = {}, 0
    local function add(name)
        local def = AutoPlaceModule.UnitDef(name)
        if type(def) ~= "table" or def._NO_ATTACKS_UNIT then return end
        local dps = (tonumber(def.damage) or 0) / math.max(0.5, AutoPlaceModule.DefCd(def))
        if dps <= 0 then return end
        local base = DungeonRun.Norm(def._base_damage_type or "physical")
        share[base] = (share[base] or 0) + dps
        for k, v in pairs(type(def._secondary_damage_types) == "table" and def._secondary_damage_types or {}) do
            local kind = DungeonRun.Norm(type(k) == "number" and v or k)
            if kind ~= base then share[kind] = (share[kind] or 0) + dps * 0.5 end
        end
        total = total + dps
    end
    local names = {}
    pcall(function() for _, u in ipairs(ownedUnits()) do table.insert(names, unitType(u)) end end)
    if #names == 0 then
        -- (the team table is read once a minute at most: the room choice comes every few minutes)
        if not AutoPlaceModule.team or (os.clock() - (DungeonRun.teamAt or -1e9) > 60 and next(AutoPlaceModule.team) == nil) then
            DungeonRun.teamAt = os.clock()
            pcall(AutoPlaceModule.RefreshTeam)
        end
        pcall(function() names = (AutoPlaceModule.TeamNames()) end)
    end
    if #names == 0 then names = Lobby.cfg.eventAlways or {} end
    for _, n in ipairs(names) do pcall(add, n) end
    if total <= 0 then return {} end
    for k, v in pairs(share) do share[k] = v / total end
    return share
end

DungeonRun.LOW_LIVES = 1     -- lives at or below this: weaknesses are not trusted, the easiest room wins
DungeonRun.LOOKAHEAD = 0.3   -- part of the best room after it that counts
-- Rooms lost in this run: lostRooms["<depth>:<map>"] = losses (saved: every room reloads the script).
DungeonRun.LOST_X = 1.5
function DungeonRun.RoomKey(depth, l)
    return tostring(depth) .. ":" .. tostring(type(l) == "table" and (l.map or l._location_name) or "?")
end
function DungeonRun.LostCount(r)
    return tonumber((DungeonRun.lostRooms or {})[DungeonRun.RoomKey(r.depth, r.l)]) or 0
end
-- In a Dungeon Room: the room just lost, from its level data (_dungeon.depth + map).
function DungeonRun.NoteLoss()
    local ok, d = pcall(Stage.levelData)
    if not ok or type(d) ~= "table" then return end
    local depth = type(d._dungeon) == "table" and d._dungeon.depth
    if not depth then return end
    local key = DungeonRun.RoomKey(depth, d)
    DungeonRun.lostRooms = DungeonRun.lostRooms or {}
    DungeonRun.lostRooms[key] = (tonumber(DungeonRun.lostRooms[key]) or 0) + 1
    pcall(DungeonRun.Log, "lost room " .. key .. " x" .. DungeonRun.lostRooms[key])
    saveConfig()
end
-- Flying enemies: only hill / hybrid units hit them. A room flies when its map had flyers in an
-- earlier dungeon room (flyMaps, saved) or it carries the flying curse; with no air-capable unit in
-- the team such a room counts FLY_X times harder.
DungeonRun.FLY_X = 3
function DungeonRun.RoomFlies(r)
    local map = type(r.l) == "table" and (r.l.map or r.l._location_name)
    if map and (DungeonRun.flyMaps or {})[tostring(map)] then return true end
    for _, v in pairs(type(r.tags) == "table" and r.tags or {}) do
        if type(v) == "table" and tostring(v.id or "") == "_curse_fly" then return true end
    end
    return false
end
function DungeonRun.TeamHitsAir()
    if os.clock() - (DungeonRun.airAt or -1e9) < 30 then return DungeonRun.air end
    DungeonRun.airAt = os.clock()
    local names = {}
    pcall(function() names = (AutoPlaceModule.TeamNames()) end)
    pcall(function() for _, u in ipairs(ownedUnits()) do table.insert(names, unitType(u)) end end)
    local air = false
    for _, n in ipairs(names) do
        if AutoPlaceModule.AirCapable(n, math.huge) then air = true end
    end
    DungeonRun.air = air
    return air
end
-- In a Dungeon Room with flyers on the map: remember the map.
function DungeonRun.NoteFlyMap()
    local ok, d = pcall(Stage.levelData)
    local map = ok and type(d) == "table" and (d.map or d._location_name)
    if not map then return end
    DungeonRun.flyMaps = DungeonRun.flyMaps or {}
    if DungeonRun.flyMaps[tostring(map)] then return end
    DungeonRun.flyMaps[tostring(map)] = true
    pcall(DungeonRun.Log, "flyers on map " .. tostring(map))
    saveConfig()
end
-- What a room gives, as a cut of its effective difficulty: gold (rare) chest > chest > shrine / shop
-- > hoard > battle (nothing). A room up to ~1.5x harder with a gold chest still wins over a battle.
DungeonRun.REWARDS = { { "GOLD", 0.35 }, { "CHEST", 0.25 }, { "SHRINE", 0.18 }, { "SHOP", 0.18 }, { "HOARD", 0.12 }, { "OPEN", 0.08 } }
-- One room's score = - effective difficulty: the room's difficulty scale divided by how much its
-- weaknesses raise our team's damage (our share of that type x (amplification - 1)), times what it
-- resists. (The old score took difficulty x2 minus the weakness bonus: difficulty grows with depth,
-- so every option sat near -10 and a x3.7 weakness on our type hardly counted - 2026-10-25)
function DungeonRun.ScoreRoom(r, share, lives)
    local l = r.l or {}
    local mult = 1
    for _, w in ipairs(DungeonRun.AsList(l._weak_against)) do
        if type(w) == "table" then
            mult = mult + (share[DungeonRun.Norm(w.damage_type)] or 0) * math.max(0, (tonumber(w.amplification) or 1) - 1)
        end
    end
    -- (no _strong_against seen yet: a factor below 1 = damage taken, above 1 = divided, none = half)
    for _, w in ipairs(DungeonRun.AsList(l._strong_against)) do
        local kind = type(w) == "table" and w.damage_type or w
        local a = type(w) == "table" and tonumber(w.amplification)
        local m = (a and a < 1 and a) or (a and a > 1 and 1 / a) or 0.5
        mult = mult * math.max(0.1, 1 - (share[DungeonRun.Norm(kind)] or 0) * (1 - m))
    end
    if lives ~= nil and lives <= DungeonRun.LOW_LIVES then mult = 1 end
    local scale = tonumber(l._lobby_difficulty_scale) or 1
    r.mult, r.eff = mult, scale / mult
    -- (a room lost before is x1.5 harder per loss: "Ant Kingdom" depth 18 was lost five times in a row
    -- while a SHOP room scored almost the same, 16:56-18:04 2026-10-25)
    r.lost = DungeonRun.LostCount(r)
    if r.lost > 0 then r.eff = r.eff * DungeonRun.LOST_X ^ r.lost end
    -- (flyers and no hill / hybrid unit in the team: lost Assassin Park depth 5 at wave 15, 19:16 2026-10-25)
    r.fly = DungeonRun.RoomFlies(r)
    if r.fly and not DungeonRun.TeamHitsAir() then r.eff = r.eff * DungeonRun.FLY_X end
    -- (owner 2026-10-25: BATTLE gives nothing - a room with a reward wins unless it is clearly harder;
    -- with 1 life left only the easiest room counts)
    r.reward, r.rewardType = 0, nil
    if not (lives ~= nil and lives <= DungeonRun.LOW_LIVES) then
        for _, rw in ipairs(DungeonRun.REWARDS) do
            if DungeonRun.HasType(r, rw[1]) and rw[2] > r.reward then r.reward, r.rewardType = rw[2], rw[1] end
        end
        r.eff = r.eff * (1 - r.reward)
    end
    return -r.eff
end
-- One option for the log: "2 Ant Kingdom [CHEST] diff 4.31 weak dark x3.0 (ours 18%) lightning x3.7 -> eff 3.31 score -4.20"
function DungeonRun.OptionLine(r, share)
    local weak = {}
    for _, w in ipairs(DungeonRun.AsList(r.l and r.l._weak_against)) do
        if type(w) == "table" then
            local ours = share[DungeonRun.Norm(w.damage_type)] or 0
            table.insert(weak, string.format("%s x%.1f%s", DungeonRun.Norm(w.damage_type), tonumber(w.amplification) or 1,
                ours > 0 and string.format(" (ours %d%%)", math.floor(ours * 100 + 0.5)) or ""))
        end
    end
    for _, w in ipairs(DungeonRun.AsList(r.l and r.l._strong_against)) do
        table.insert(weak, "strong " .. DungeonRun.Norm(type(w) == "table" and w.damage_type or w))
    end
    return string.format("%s %s [%s] diff %.2f %s%s-> eff %.2f score %.2f", tostring(r.id), tostring(r.label or "?"), DungeonRun.TypeText(r),
        tonumber(r.l and r.l._lobby_difficulty_scale) or 1, #weak > 0 and ("weak " .. table.concat(weak, " ") .. " ") or "no weakness ",
        ((r.lost or 0) > 0 and ("lost x" .. r.lost .. " ") or "") .. (r.fly and (DungeonRun.TeamHitsAir() and "flyers " or "flyers-no-air ") or "")
            .. ((r.reward or 0) > 0 and string.format("reward %s -%d%% ", r.rewardType, math.floor(r.reward * 100 + 0.5)) or ""),
        r.eff or 0, r.score or 0)
end
-- Auto mode: the best scored room (plus a part of the best one after it); room types, when the
-- data names them, break ties by Room priority; shrines only when allowed.
function DungeonRun.AutoPick(rooms, lives)
    local share = DungeonRun.TeamShare()
    local order = DungeonRun.priority()
    local best
    for _, r in ipairs(rooms or {}) do
        local sc = DungeonRun.ScoreRoom(r, share, lives)
        local after
        for _, k in ipairs(DungeonRun.LiveRooms(r.kids)) do
            local x = DungeonRun.ScoreRoom(k, share, lives)
            if not after or x > after then after = x end
        end
        if after then sc = sc + DungeonRun.LOOKAHEAD * after end
        local rank = r.type and table.find(order, r.type)
        if rank then sc = sc + 0.01 * (#order - rank + 1) end
        -- WANT / AVOID types: 10% / 15% of this room's effective difficulty (My picks only: Auto
        -- decides everything itself - owner 2026-10-25)
        for t, p in pairs(DungeonRun.mode == "Auto" and {} or DungeonRun.prefs or {}) do
            if DungeonRun.HasType(r, t) then
                if p == "prefer" then sc = sc + 0.1 * (r.eff or 1) elseif p == "avoid" then sc = sc - 0.15 * (r.eff or 1) end
            end
        end
        if DungeonRun.HasType(r, "SHRINE") and not DungeonRun.ShrineOK(lives) then sc = sc - 100 end
        r.score = sc
        if not best or sc > best.score then best = r end
    end
    return best
end

-- One step on the live run (from dungeon_changed or the game's copy of it).
-- Shop: dungeon_buy_shop(<slot number in the list now>) - the list shifts after each buy - then
-- dungeon_continue_shop(). Chest page: dungeon_open_chest(true) opens a gold chest (treasure_gold
-- - 1); false is not known yet, so silver chests are left alone. (Watch, real game 15:59 2026-10-25)
DungeonRun.PRICES = { gold_branch = 300, bow2 = 300, gold_shroom = 500 }
-- Shop items and shrine buffs seen in the real game (names / effects from the owner's screenshots,
-- 2026-10-25). New shop ids are learned from each shop page (Lobby.cfg.dungeonItems) and item
-- pictures from the open shop window (Lobby.cfg.dungeonItemIcons, same shape as room icons).
DungeonRun.ITEMS = {
    { id = "gold_branch", kind = "shop", name = "Golden Branch", effect = "-15% Placement/Upgrade Cost" },
    { id = "gold_shroom", kind = "shop", name = "Golden Mushroom", effect = "-30% Placement/Upgrade Cost" },
    { id = "bow2", kind = "shop", name = "Longbow", effect = "+30% Range" },
    { id = "philosophers_stone", kind = "shop", name = "Philosopher's Stone", effect = "Converts the chests held now to rare chests" },
    -- (curse ids from the run's _items; names / effects from the AA wiki's Dungeon page, 2026-10-25)
    { id = "_curse_money", kind = "shrine", name = "Curse of Money", effect = "-10% Hoard drops" },
    { id = "_curse_fly", kind = "shrine", name = "Curse of Flight", effect = "+20% chance of flying enemies" },
    { id = "_curse_speed", kind = "shrine", name = "Curse of Wind / Frenzy", effect = "Enemies +25% / +50% faster" },
    { id = "_curse_regen", kind = "shrine", name = "Curse of Regen", effect = "Enemies +1% regen" },
    { id = "_curse_health", kind = "shrine", name = "Curse of Health", effect = "Enemies +80% HP" },
    { id = "_curse_shop", kind = "shrine", name = "Curse of Shopping", effect = "+10% shop prices" },
    -- (the game ids of the shrine offer seen on the device, 21:31 2026-10-25)
    { id = "boots", kind = "shrine", name = "Speedy Boots", effect = "-20% Attack cooldown" },
    { id = "chest_mock_item", kind = "shrine", name = "Treasure Chest", effect = "+1 Treasure chest (instant)" },
    { id = "_curse_super_armored", kind = "shrine", name = "Curse of Armor", effect = "+100% Armored enemies chance" },
}
-- Blessing (shop item) and curse effects from the AA wiki's Dungeon page (2026-10-25), by name: used
-- for items learned in game whose id reads as one of these names. Text only - pictures come from the game.
DungeonRun.WIKI_EFFECTS = {
    ["mask of riches"] = "-50% Placement/Upgrade Cost", ["golden mushroom"] = "-30% Placement/Upgrade Cost",
    ["golden branch"] = "-15% Placement/Upgrade Cost", ["genie lamp"] = "+100% chest luck", ["golden fishhook"] = "+40% chest luck",
    ["fish hook"] = "+20% chest luck", ["archmages hat"] = "+250% Magic damage", ["magic tome"] = "+100% Magic damage",
    ["mage coat"] = "+50% Magic damage", ["aures maul"] = "+200% Physical damage", ["headsplitter"] = "+75% Physical damage",
    ["axe"] = "+50% Physical crit chance", ["solar cleaver"] = "+100% Physical crit chance", ["sylvanthorn"] = "+150% Range",
    ["elf bow"] = "+50% Range", ["reaper scythe"] = "+75% boss damage", ["celestial blade"] = "+777% True damage",
    ["scimitar"] = "+75% attack", ["sword"] = "+30% damage", ["ninja belt"] = "-12% attack speed",
    ["glacial axe"] = "Enemies 30% slower", ["philosophers stone"] = "Converts the chests held now to rare chests",
    ["shimmering moon fragment"] = "+1 star Star Remnant per chest",
    -- (not on the wiki: seen in a shop marked [*], 1100 coins - owner screenshot 2026-10-26)
    ["stormbringer"] = "-50% Attack cooldown",
    -- (shop items from the owner's screenshots 2026-10-26, not on the wiki)
    ["dagger"] = "+15% Attack", ["bow"] = "+20% Range",
    ["curse of wind"] = "Enemies +25% faster", ["curse of frenzy"] = "Enemies +50% faster", ["curse of burst"] = "+100% Burst trait",
    ["curse of shielding"] = "Enemies +3 shield", ["curse of armor"] = "+100% Armor trait", ["curse of chaos"] = "All curses random",
    ["curse of eruption"] = "+24 explosive death range", ["curse of explosion"] = "+12 explosive death range",
    ["curse of vampirism"] = "Enemies +3% regen",
}
-- The rows of a picker page: the catalog of that kind, then ids learned in game.
function DungeonRun.ItemList(kind)
    local out, seen = {}, {}
    for _, it in ipairs(DungeonRun.ITEMS) do
        if it.kind == kind then table.insert(out, it) seen[it.id] = true end
    end
    local learned = {}
    for id, v in pairs(Lobby.cfg.dungeonItems or {}) do
        if type(v) == "table" and v.kind == kind and not seen[id] then table.insert(learned, id) end
    end
    table.sort(learned)
    for _, id in ipairs(learned) do
        local v = Lobby.cfg.dungeonItems[id]
        local pretty = (id:gsub("^_", ""):gsub("_", " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
        -- (the name / effect the game's own page showed, when read: Bow / +20% Range)
        table.insert(out, { id = id, kind = kind, name = v.name or pretty,
            effect = v.effect or DungeonRun.WIKI_EFFECTS[string.lower(pretty)] or "(seen in game)" })
    end
    return out
end
-- Ids seen in shop pages and in the run's items, remembered for the picker pages.
function DungeonRun.LearnItems(p)
    Lobby.cfg.dungeonItems = Lobby.cfg.dungeonItems or {}
    local known, added = {}, {}
    for _, it in ipairs(DungeonRun.ITEMS) do known[it.id] = true end
    local function add(id, kind)
        id = string.lower(tostring(id or ""))
        if id ~= "" and not known[id] and not Lobby.cfg.dungeonItems[id] then
            Lobby.cfg.dungeonItems[id] = { kind = kind }
            table.insert(added, kind .. " " .. id)
        end
    end
    for _, page in ipairs(type(p.current_shops) == "table" and p.current_shops or {}) do
        if type(page) == "table" and tostring(page._t) == "1" and type(page.data) == "table" then
            for _, it in ipairs(page.data) do add(type(it) == "table" and it.id or it, "shop") end
        end
    end
    for _, it in ipairs(type(p._items) == "table" and p._items or {}) do
        local id = type(it) == "table" and tostring(it.id or "") or ""
        if id:find("^_curse") then add(id, "shrine") else add(id, "relic") end
    end
    -- (shrine offers name their items too: boots, chest_mock_item, _curse_super_armored ...)
    for _, page in ipairs(type(p.current_shops) == "table" and p.current_shops or {}) do
        if type(page) == "table" and tostring(page._t) == "7" and type(page.data) == "table" then
            for _, it in ipairs(page.data) do add(type(it) == "table" and it.id or it, "shrine") end
        end
    end
    if #added > 0 then
        pcall(DungeonRun.Log, "new items " .. table.concat(added, ", "))
        -- (their pictures may be in the game's data: scan it once more)
        DungeonRun.dataScanned = nil
        saveConfig()
    end
end
-- Item pictures from the open shop window: a label with an item's name and the picture next to it.
function DungeonRun.LearnItemIcons()
    if os.clock() - (DungeonRun.itemIconsAt or -1e9) < 15 then return end
    DungeonRun.itemIconsAt = os.clock()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    if not ui or (ui:IsA("LayerCollector") and not ui.Enabled) then return end
    Lobby.cfg.dungeonItemIcons = Lobby.cfg.dungeonItemIcons or {}
    local icons, byName, found = Lobby.cfg.dungeonItemIcons, {}, {}
    for _, it in ipairs(DungeonRun.AllItems()) do byName[DungeonRun.NameKey(it.name)] = it.id end
    Lobby.cfg.dungeonNameIcons = Lobby.cfg.dungeonNameIcons or {}
    local nameIcons = Lobby.cfg.dungeonNameIcons
    for _, pic in ipairs(ui:GetDescendants()) do
        local img = pic.Name == "ItemImage" and (pic:IsA("ImageLabel") or pic:IsA("ImageButton")) and tostring(pic.Image) or ""
        -- (the game keeps its card templates under a Configuration: not a real card)
        if img ~= "" and not DungeonRun.FRAME_IMAGES[img] and img ~= DungeonRun.SHOP_ICON and isOnScreen(pic) and not pic:FindFirstAncestorWhichIsA("Configuration") then
            local node, nameLabel = pic.Parent, nil
            for _ = 1, 4 do
                if not node or node:IsA("Configuration") or node:IsA("LayerCollector") then break end
                nameLabel = node:FindFirstChild("ItemName", true)
                if nameLabel then break end
                node = node.Parent
            end
            local key = nameLabel and nameLabel:IsA("TextLabel") and DungeonRun.NameKey(nameLabel.Text) or ""
            if key ~= "" and not (nameIcons[key] and nameIcons[key].image == img) then
                nameIcons[key] = { image = img }
                table.insert(found, key .. "=" .. img)
            end
        end
    end
    -- (a picture of the card frame - inset / border / glow - is no item picture: learned again)
    local function learned(id) return icons[id] and not DungeonRun.FRAME_IMAGES[icons[id].image or ""] end
    for _, d in ipairs(ui:GetDescendants()) do
        local id = (d:IsA("TextLabel") or d:IsA("TextButton")) and isOnScreen(d) and byName[DungeonRun.NameKey(tostring(d.Text):gsub("<[^>]->", ""))]
        if id and not learned(id) then
            local node = d.Parent
            for level = 1, 3 do
                if not node or learned(id) then break end
                local direct = node:FindFirstChild("ItemImage", level > 1)
                for _, x in ipairs(direct and { direct } or (level == 1 and node:GetChildren() or node:GetDescendants())) do
                    local img = (x:IsA("ImageLabel") or x:IsA("ImageButton")) and tostring(x.Image) or ""
                    if img ~= "" and not DungeonRun.FRAME_IMAGES[img] and img ~= DungeonRun.SHOP_ICON then
                        local icon = { image = tostring(x.Image) }
                        pcall(function()
                            local o, z = x.ImageRectOffset, x.ImageRectSize
                            if z and z.X > 0 and z.Y > 0 then icon.offset, icon.size = { o.X, o.Y }, { z.X, z.Y } end
                        end)
                        icons[id] = icon
                        Lobby.cfg.dungeonNameIcons = Lobby.cfg.dungeonNameIcons or {}
                        Lobby.cfg.dungeonNameIcons[DungeonRun.NameKey(d.Text)] = icon
                        table.insert(found, id .. "=" .. icon.image .. (icon.size and string.format(" rect %d,%d %dx%d", icon.offset[1], icon.offset[2], icon.size[1], icon.size[2]) or ""))
                        break
                    end
                end
                node = node.Parent
            end
        end
    end
    if #found > 0 then
        pcall(DungeonRun.Log, "item icons " .. table.concat(found, ", "))
        saveConfig()
        pcall(DungeonRun.WriteIconFile)
    end
end
-- Item picks (owner 2026-10-26: tap a row to select it, glowing = yes). itemPrefs[id] = "prefer"
-- (selected) | "avoid" (not selected) | nil = the script's recommendation (an older save with item
-- choices: nil was ANY = selected). Recommended = worth buying for this team (value > 0.3); a curse is
-- recommended when it is not a dangerous one (> -4).
-- (kept 5 s: every glowing card asks on each repaint - a tap re-scored the whole page)
DungeonRun.scoreMemo = {}
function DungeonRun.ItemScore(id)
    local m = DungeonRun.scoreMemo[id]
    if m and os.clock() - m.at < 5 and os.clock() >= m.at then return m.v, m.curse end
    local v, curse = DungeonRun.ItemValue(DungeonRun.ItemText(id))
    DungeonRun.scoreMemo[id] = { at = os.clock(), v = v, curse = curse }
    return v, curse
end
function DungeonRun.ItemRecommended(id)
    local v, curse = DungeonRun.ItemScore(id)
    if curse then return v > -4 end
    -- (a shrine blessing costs nothing: yes unless it hurts - an unknown new one denied the offer)
    local known = (Lobby.cfg.dungeonItems or {})[id]
    local kind = known and known.kind
    for _, it in ipairs(DungeonRun.ITEMS) do if it.id == id then kind = it.kind break end end
    if kind == "shrine" then return v >= 0 end
    return v > 0.3
end
function DungeonRun.ItemSelected(id, prefs)
    local p = (prefs or DungeonRun.itemPrefs or {})[id]
    if p == "avoid" then return false end
    if p == "prefer" or DungeonRun.legacyPicks then return true end
    return DungeonRun.ItemRecommended(id)
end
-- Value stars for a page's items: blessings ranked by the team score (top third 3, middle 2, low 1);
-- curses by danger (skulls, 3 = most dangerous). Returns stars[id] = { n = 1..3, curse = bool }.
function DungeonRun.ItemStars(items)
    local stars, groups = {}, { [false] = {}, [true] = {} }
    for _, it in ipairs(items) do
        local v, curse = DungeonRun.ItemScore(it.id)
        table.insert(groups[curse and true or false], { id = it.id, v = v })
    end
    for curse, g in pairs(groups) do
        table.sort(g, function(a, b) if curse then return a.v < b.v end return a.v > b.v end)
        local k = #g
        for i, e in ipairs(g) do
            stars[e.id] = { n = i <= math.ceil(k / 3) and 3 or (i <= math.ceil(2 * k / 3) and 2 or 1), curse = curse }
        end
    end
    return stars
end
-- "Recommended for your team": the 3-5 best blessings by the team score (5 at most, 3 when fewer are
-- worth buying, never one worth nothing).
function DungeonRun.TopItems(items)
    local g, good = {}, 0
    for _, it in ipairs(items) do
        local v, curse = DungeonRun.ItemScore(it.id)
        if not curse and v > 0 then
            table.insert(g, { id = it.id, v = v })
            if v > 0.3 then good = good + 1 end
        end
    end
    table.sort(g, function(a, b) return a.v > b.v end)
    local top = {}
    for i = 1, math.min(#g, math.min(5, math.max(3, good))) do top[g[i].id] = i end
    return top
end
-- Which item to buy: the wish-list first, then the item worth most to this team. My picks: only
-- selected items (glowing rows), the best first; Auto: the script's own choice (worth > 0.3).
-- Never one whose known price is over the coins.
function DungeonRun.ShopPick(items, money)
    local auto = DungeonRun.mode == "Auto"
    local list = type(items) == "table" and items or {}
    local function idOf(it) return string.lower(tostring(type(it) == "table" and it.id or it)) end
    local function allowed(id) return auto or DungeonRun.ItemSelected(id) end
    -- (the price on the page's row first: Bow 221 with 194 coins was tried and refused, 23:44 2026-10-25)
    local function affordable(id)
        -- (a refused item: only again with more coins than at the refusal)
        local refusedAt = (DungeonRun.refused or {})[id]
        if refusedAt and (not money or money <= refusedAt) then return false end
        local price = (DungeonRun.pagePrices or {})[id] or DungeonRun.PRICES[id]
        return not price or not money or money >= price
    end
    local wishes = auto and {} or DungeonRun.wishes()
    for _, w in ipairs(wishes) do
        for i, it in ipairs(list) do
            local id = idOf(it)
            if id:find(w, 1, true) and allowed(id) and affordable(id) then return i, id end
        end
    end
    -- (no wish-list: the item worth most to THIS team - DungeonRun.ItemValue; Auto keeps the coins for
    -- one worth almost nothing, My picks buys what was selected)
    local best, bestI, bestId
    for i, it in ipairs(list) do
        local id = idOf(it)
        if allowed(id) and affordable(id) then
            local v = DungeonRun.ItemValue(DungeonRun.ItemText(id))
            if (v > 0.3 or not auto) and (not best or v > best) then best, bestI, bestId = v, i, id end
        end
    end
    return bestI, bestId
end
function DungeonRun.PageStep(st, page)
    local kind = type(page) == "table" and tostring(page._t) or "?"
    local seq = DungeonRun.liveSeq or 0
    local money = st.coins
    if kind == "1" then
        pcall(DungeonRun.LearnRowIcons, "ShopSelection", page.data)
        pcall(DungeonRun.ReadRowPrices, "ShopSelection", page.data)
        pcall(DungeonRun.LearnRowTexts, "ShopSelection", page.data, "shop")
    end
    if kind == "1" and (DungeonRun.mode == "Auto" or DungeonRun.autoShop ~= false) and DungeonRun.buyStop ~= seq then
        local slot, id = DungeonRun.ShopPick(page.data, money)
        if slot then
            DungeonRun.status = "shop: buying " .. id
            DungeonRun.Refresh(st)
            local ok, answer = DungeonRun.Call("dungeon_buy_shop", slot, st)
            pcall(DungeonRun.Log, string.format("dungeon_buy_shop(%d) %s -> %s, answered %s", slot, id, ok and "bought" or "nothing", clip(tostring(answer), 40)))
            pcall(Lobby.ShareLog, "dungeon: shop bought " .. id .. (ok and "" or " - refused"))
            if ok then DungeonRun.lastBought = id end
            -- (refused: not tried again unless there is more money; the next pick runs at once and the shop
            -- is left as soon as nothing affordable and wanted is left - a cheaper Dagger after a refused Lamp)
            if not ok then
                DungeonRun.refused = DungeonRun.refused or {}
                DungeonRun.refused[id] = tonumber(money) or math.huge
            end
            return 1
        end
    elseif kind == "6" then
        local gold, normal = tonumber(st.goldKeys) or 0, tonumber(st.silverKeys) or 0
        -- (AA wiki: rare chests opened before the end lose the Secret Unit chance - Auto keeps them for depth 19+;
        -- normal chests wait with them: a Philosopher's Stone bought later turns them rare)
        local keep = DungeonRun.mode == "Auto" or DungeonRun.goldChests == "end"
        local now = not keep or (DungeonRun.lastDepth or 0) >= 19
        if now and DungeonRun.chestTried ~= seq and (gold > 0 or normal > 0) then
            DungeonRun.chestTried = seq
            DungeonRun.OpenChest(st, gold > 0)
            return 1
        end
    elseif kind == "7" and DungeonRun.ShrineStep(st, seq) then
        return 3
    elseif kind ~= "1" then
        -- (a page not known yet - a shrine?: left to the player, logged for the next build)
        local ok, j = pcall(function() return HttpService:JSONEncode(page) end)
        DungeonRun.status = "page _t " .. kind .. " not known yet - choose by hand"
        if DungeonRun.pageNoted ~= seq then
            DungeonRun.pageNoted = seq
            pcall(DungeonRun.Log, "unknown page " .. clip(ok and j or "?", 300))
        end
        DungeonRun.Refresh(st)
        return 3
    end
    DungeonRun.status = kind == "1" and "leaving the shop" or "leaving the chest page"
    DungeonRun.Refresh(st)
    local ok = DungeonRun.Call("dungeon_continue_shop", nil, st)
    if not ok then
        -- (no answer: the page's own Continue button by GUI, else left to the player)
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = gui and gui:FindFirstChild("DungeonUI")
        local pageGui = ui and ui:FindFirstChild(kind == "1" and "ShopSelection" or "OpenTreasure", true)
        local b = pageGui and DungeonRun.FindButton(pageGui, "continue")
        if b then
            Lobby.TapGui(b)
            pcall(Lobby.ShareLog, "dungeon: continue_shop gave no answer - tapped " .. b.Name)
        else
            DungeonRun.blocked = "dungeon_continue_shop changed nothing - continue by hand"
        end
    end
    return 1
end
-- Prices from the game's shop page: each row (in the order of the page data's ids) shows its price as a
-- plain number (Bow 221, Dagger 221 - 23:44 2026-10-25). Kept for this page: prices change with depth.
function DungeonRun.ReadRowPrices(pageName, data)
    -- (a read that does not line up keeps the prices read before: the list shrinks after a buy)
    DungeonRun.pagePrices = DungeonRun.pagePrices or {}
    if type(data) ~= "table" or #data == 0 then return end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local page = ui and ui:FindFirstChild(pageName, true)
    if not page or not isOnScreen(page) then return end
    local list = page:FindFirstChildWhichIsA("ScrollingFrame", true) or page
    local rows = {}
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") then table.insert(rows, c) end
    end
    if #rows ~= #data then return end
    local function order(x) local ok, v = pcall(function() return x.LayoutOrder end) return ok and tonumber(v) or 0 end
    table.sort(rows, function(a, b)
        if order(a) ~= order(b) then return order(a) < order(b) end
        return a.AbsolutePosition.Y < b.AbsolutePosition.Y
    end)
    for i, row in ipairs(rows) do
        local id = type(data[i]) == "table" and tostring(data[i].id or "") or tostring(data[i])
        for _, d in ipairs(row:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local n = tostring(d.Text):gsub("<[^>]->", ""):gsub("[,%s]", "")
                if n:match("^%d+$") then DungeonRun.pagePrices[id] = tonumber(n) break end
            end
        end
    end
end

-- One chest from the chest page: dungeon_open_chest(true) = gold (seen in Watch), (false) = a normal chest
-- (owner: it opens the same way). A call that errors or changes nothing: the page's Open button by GUI;
-- the reward popups after it are tapped away by Lobby.ClickAnywhere. Which way worked is logged.
function DungeonRun.OpenChest(st, gold)
    local what = gold and "gold chest" or "chest"
    DungeonRun.status = "opening a " .. what
    DungeonRun.Refresh(st)
    local ok, answer = DungeonRun.Call("dungeon_open_chest", gold, st)
    local how = string.format("open_chest(%s)", tostring(gold))
    if not ok then
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = gui and gui:FindFirstChild("DungeonUI")
        local page = ui and ui:FindFirstChild("OpenTreasure", true)
        local b = page and isOnScreen(page) and DungeonRun.FindButton(page, "open")
        if b then
            Lobby.TapGui(b)
            how = how .. " answered " .. clip(tostring(answer), 30) .. " - tapped " .. b.Name
        else
            how = how .. " answered " .. clip(tostring(answer), 30) .. " - no Open button"
        end
    end
    pcall(DungeonRun.Log, what .. ": " .. how)
    pcall(Lobby.ShareLog, "dungeon: " .. what .. " - " .. (ok and "opened via " or "") .. how)
end

function DungeonRun.LiveStep(st)
    if st.ended then
        DungeonRun.status = DungeonRun.startNote or "run over" .. (DungeonRun.InLobby() and " - no next run to start" or " - back to the lobby next")
        DungeonRun.Refresh(st)
        return 3
    end
    if DungeonRun.blocked then
        DungeonRun.status = DungeonRun.blocked
        DungeonRun.Refresh(st)
        return 2
    end
    -- (no lives left: the run is over, a room call only answers "error" - 18:05 2026-10-25)
    if st.hearts ~= nil and st.hearts <= 0 then
        DungeonRun.status = "no lives left - the run is over"
        DungeonRun.Refresh(st)
        return 3
    end
    -- shop / chest pages come first (current_shops; continue_shop closes the first one)
    if st.table == DungeonRun.live and type(st.table.current_shops) == "table" and st.table.current_shops[1] ~= nil then
        return DungeonRun.PageStep(st, st.table.current_shops[1])
    end
    if #st.rooms == 0 then
        DungeonRun.status = "no rooms offered right now"
        DungeonRun.Refresh(st)
        return 2
    end
    -- (the copy found in memory is the last room choice: rooms sent from it with the Dungeon Run window
    -- closed were never taken (12:49), but after a lost room no dungeon_changed comes - the owner's
    -- "Open Dungeon" only opens the window and the same choice is taken from there (15:22, 2026-10-25).
    -- So: a fresh dungeon_changed, or the window open with its room tiles on screen)
    if st.table ~= DungeonRun.live and not DungeonRun.ChoiceOpen() then
        DungeonRun.status = "waiting for the game to open the room choice"
        DungeonRun.Refresh(st)
        return 3
    end
    if DungeonRun.enteredTable == st.table then
        DungeonRun.status = "in room " .. tostring(DungeonRun.enteredId) .. " - waiting for its result"
        DungeonRun.Refresh(st)
        return 2
    end
    local room, why
    if DungeonRun.mode == "Auto" then
        room = DungeonRun.AutoPick(st.rooms, st.hearts)
        why = room and string.format("score %.2f", room.score or 0)
    else
        room = DungeonRun.PickRoom(st.rooms)
        why = room and tostring(room.type)
        local typed = false
        for _, r in ipairs(st.rooms) do if r.type then typed = true end end
        -- (the run's data names no room types yet: Fixed takes the first room like a macro)
        if not room and not typed then room, why = st.rooms[1], "first room (types not in the data)" end
    end
    if not room then
        DungeonRun.status = "no room fits - pick one yourself"
        DungeonRun.Refresh(st)
        return 2
    end
    local arg = tostring(room.id)
    DungeonRun.status = string.format("entering %s %s (%s)", arg, tostring(room.label or "?"), tostring(why))
    DungeonRun.Refresh(st)
    local team = {}
    local share = DungeonRun.TeamShare()
    for k, v in pairs(share) do table.insert(team, string.format("%s %d%%", k, math.floor(v * 100 + 0.5))) end
    table.sort(team)
    -- every option with its numbers, so a pick can be checked afterwards
    pcall(function()
        if DungeonRun.mode == "Auto" then DungeonRun.AutoPick(st.rooms, st.hearts) end
        local opts = {}
        for _, r in ipairs(st.rooms) do table.insert(opts, DungeonRun.OptionLine(r, share)) end
        local line = string.format("depth %s lives %s options: %s -> pick %s", tostring(st.depth), tostring(st.hearts), table.concat(opts, " | "), arg)
        DungeonRun.Log(line)
        Lobby.ShareLog("dungeon: " .. line)
    end)
    pcall(Lobby.ShareLog, string.format("dungeon: depth %s %s -> room %s %s (%s) lives %s team %s", tostring(st.depth), DungeonRun.mode, arg,
        tostring(room.label), tostring(why), tostring(st.hearts), table.concat(team, ", ")))
    local changed, answer = DungeonRun.Call("dungeon_enter_room", arg, st)
    pcall(Lobby.ShareLog, string.format("dungeon: dungeon_enter_room(%q) -> %s, answered %s", arg, changed and "taken" or "nothing", clip(tostring(answer), 60)))
    if changed then
        DungeonRun.enteredTable, DungeonRun.enteredId = st.table, arg
        DungeonRun.enteredAt = os.clock()
        DungeonRun.picks = DungeonRun.picks or {}
        table.insert(DungeonRun.picks, arg)
        DungeonRun.status = "entered room " .. arg .. " " .. tostring(room.label or "")
    else
        DungeonRun.blocked = string.format("room %s: the game did not take it (answered %s) - pick by hand", arg, clip(tostring(answer), 30))
    end
    DungeonRun.Refresh()
    return 1
end

function DungeonRun.OnChanged(p)
    if type(p) ~= "table" then return end
    DungeonRun.live = p
    DungeonRun.liveSeq = (DungeonRun.liveSeq or 0) + 1
    pcall(function() DungeonRun.Log("<- dungeon_changed(" .. HttpService:JSONEncode(p) .. ")") end)
    pcall(DungeonRun.LearnItems, p)
    DungeonRun.blocked = nil
    local rooms = DungeonRun.LiveRooms(p.next)
    if rooms[1] and rooms[1].depth then DungeonRun.lastDepth = rooms[1].depth end
    -- anything new in the data goes to the share log once (room tags, shops, keys)
    DungeonRun.seen = DungeonRun.seen or {}
    local function note(text)
        if DungeonRun.seen[text] then return end
        DungeonRun.seen[text] = true
        pcall(Lobby.ShareLog, "dungeon: " .. text)
    end
    local keys = {}
    for k in pairs(p) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    note("state keys " .. table.concat(keys, ","))
    for _, r in ipairs(rooms) do
        local t = DungeonRun.TagText(r.tags)
        if t ~= "" then note("room tags " .. t) end
    end
    if type(p.current_shops) == "table" and next(p.current_shops) ~= nil then
        local ok, j = pcall(function() return HttpService:JSONEncode(p.current_shops) end)
        note("shop " .. clip(ok and j or "?", 300))
    end
    -- (a run going on: _started with rooms ahead. After the owner pressed Continue on You Died! the game
    -- sent dungeon_changed({}) and at once a new run with only next1.. in next, no dungeon_start - 18:23 2026-10-25)
    local running = p._started == true and type(p.next) == "table" and next(p.next) ~= nil
    local over = next(p) == nil or (not running and #rooms == 0 and (DungeonRun.lastDepth or 0) >= 20)
    if over then
        note("run over at depth " .. tostring(DungeonRun.lastDepth))
        DungeonRun.lostRooms, DungeonRun.refused, DungeonRun.pagePrices = {}, nil, nil
        if DungeonRun.enabled then DungeonRun.pendingStart = true saveConfig() end
    elseif #rooms > 0 then DungeonRun.startNote = nil end
    if not over and (running or #rooms > 0) and DungeonRun.pendingStart then
        DungeonRun.pendingStart = false
        saveConfig()
    end
end
function DungeonRun.OnSelected(p)
    if type(p) ~= "table" then return end
    -- (kept in the config: every room reloads the script and the status read "Lives ?" - 2026-10-25)
    local lives = tonumber(p.lives)
    if lives and lives ~= DungeonRun.lives then
        DungeonRun.lives = lives
        saveConfig()
    end
    DungeonRun.selSeq = (DungeonRun.selSeq or 0) + 1
    pcall(function() DungeonRun.Log("<- dungeon_selected_changed(" .. HttpService:JSONEncode(p) .. ")") end)
end

-- Dungeon Run Keys in the bag; nil = not known (no key item seen: the call's answer decides).
function DungeonRun.KeyCount()
    local ok, bag = pcall(Lobby.Bag)
    if not ok or type(bag) ~= "table" then return nil end
    for id, n in pairs(bag.counts or {}) do
        local s = string.lower(tostring(id))
        if s:find("dungeon", 1, true) and s:find("key", 1, true) then return n end
    end
    return nil
end

-- The next run after one ended: one dungeon_start() per ended run, never retried.
function DungeonRun.TryStart()
    -- (You Died! still up: it closes the old run first - dungeon_start answered "error" under it, 22:56)
    if Lobby.ButtonFor("You Died!") then
        DungeonRun.status = "waiting for You Died! to close"
        DungeonRun.Refresh(false)
        return 3
    end
    DungeonRun.pendingStart = false
    saveConfig()
    -- (the game may already have started the next run itself, after You Died! Continue)
    local live = DungeonRun.live
    if type(live) == "table" and live._started == true and type(live.next) == "table" and next(live.next) ~= nil then
        DungeonRun.status = "next run already started by the game"
        DungeonRun.Refresh(false)
        return 2
    end
    local keys = DungeonRun.KeyCount()
    if keys ~= nil and keys <= 0 then
        DungeonRun.status = "run over - no Dungeon Run Key, not starting another"
        DungeonRun.startNote = DungeonRun.status
        DungeonRun.Refresh(false)
        return 5
    end
    local remote = getAARemote("dungeon_start")
    if not remote then
        DungeonRun.status = "run over - dungeon_start remote not found"
        DungeonRun.Refresh(false)
        return 5
    end
    DungeonRun.status = "starting the next run (keys " .. tostring(keys or "?") .. ")"
    DungeonRun.Refresh(false)
    local seq = DungeonRun.liveSeq or 0
    local ok, res = pcall(function()
        if remote:IsA("RemoteFunction") then return remote:InvokeServer() end
        remote:FireServer()
        return true
    end)
    local deadline = os.clock() + 10
    while os.clock() < deadline do
        local live = DungeonRun.live
        if (DungeonRun.liveSeq or 0) ~= seq and type(live) == "table" and live._started then
            DungeonRun.status = "next run started"
            pcall(Lobby.ShareLog, "dungeon: dungeon_start() -> new run (keys " .. tostring(keys or "?") .. ")")
            DungeonRun.Refresh()
            return 1
        end
        task.wait(0.25)
    end
    DungeonRun.status = "dungeon_start answered " .. clip(tostring(ok and res or "error"), 60) .. " - no new run (no key?), not trying again"
    DungeonRun.startNote = DungeonRun.status
    pcall(Lobby.ShareLog, "dungeon: " .. DungeonRun.status)
    DungeonRun.Refresh(false)
    return 5
end

for name, fn in pairs({ dungeon_changed = function(p) pcall(DungeonRun.OnChanged, p) end,
    dungeon_selected_changed = function(p) pcall(DungeonRun.OnSelected, p) end }) do
    task.spawn(pcall, function()
        local conn = ReplicatedStorage:WaitForChild("endpoints"):WaitForChild("server_to_client"):WaitForChild(name).OnClientEvent:Connect(fn)
        table.insert(State.connections, conn)
    end)
end

-- Room preferences from the Setup window: prefs[type] = "prefer" | "avoid" | nil. They become
-- the priority order (prefer, then neutral, then avoid) and, in Auto, a bonus / penalty of 10% / 15%
-- of the room's effective difficulty (DungeonRun.AutoPick).
function DungeonRun.ApplyPrefs()
    local prefs = DungeonRun.prefs or {}
    local order = {}
    for _, want in ipairs({ "prefer", false, "avoid" }) do
        for _, t in ipairs(DungeonRun.ROOM_TYPES) do
            if (prefs[t] or false) == want then table.insert(order, t) end
        end
    end
    DungeonRun.roomPriority = table.concat(order, ">")
end
-- Shrines: "never" | "lives3" (only with 3+ lives) | "always"
function DungeonRun.ShrineOK(lives)
    local rule = DungeonRun.shrineRule or (DungeonRun.acceptShrines and "always" or "never")
    return rule == "always" or (rule == "lives3" and (tonumber(lives) or 0) >= 3)
end
-- Why a room is picked, short: "weak to fire x2.8" / "easiest x0.65" / its type.
function DungeonRun.Reason(r)
    local types = DungeonRun.TypeText(r)
    if DungeonRun.mode ~= "Auto" or not r.l then return types ~= "" and types or "first room" end
    local why = DungeonRun.AutoReason(r)
    return types ~= "" and (types .. ", " .. why) or why
end
function DungeonRun.AutoReason(r)
    local share = DungeonRun.TeamShare()
    local best, bestGain
    for _, w in ipairs(DungeonRun.AsList(r.l._weak_against)) do
        local gain = type(w) == "table" and (share[DungeonRun.Norm(w.damage_type)] or 0) * ((tonumber(w.amplification) or 1) - 1) or 0
        if gain > 0 and (not bestGain or gain > bestGain) then best, bestGain = w, gain end
    end
    DungeonRun.ScoreRoom(r, share, DungeonRun.lives)
    if best then
        return string.format("weak to %s x%.1f, +%d%% dmg", DungeonRun.Norm(best.damage_type), tonumber(best.amplification) or 1,
            math.floor(((r.mult or 1) - 1) * 100 + 0.5))
    end
    return string.format("easiest x%.2f", tonumber(r.l._lobby_difficulty_scale) or 1)
end

-- The game's own room pictures, learned in game (owner 2026-10-25: recognisable icons): a label
-- naming a room type in DungeonUI with the picture next to it, or a dungeon data module entry with
-- an image / icon field. The room icons are one sprite sheet (rbxassetid://120321831419148 for every
-- type), so an icon is the image AND its ImageRectOffset / ImageRectSize. Saved in
-- Lobby.cfg.dungeonIcons4[type] = { image, offset = {x, y}, size = {x, y} }; emoji until found.
-- (the same image + rect for 2+ types is a card frame, not a room icon: dropped)
DungeonRun.EMOJI = { HOARD = "💰", CHEST = "📦", SHOP = "🛒", BATTLE = "⚔️", SHRINE = "⛩️", BOSS = "👹" }
-- The game's own attribute pictures, read from its room tiles (dungeon_ui_dump 18:23 2026-10-25). SHOP is
-- 120321831419148 (a purple-and-gold stall - a visible shop tile on the device, owner's crop); BATTLE has
-- no picture (swords).
DungeonRun.ICON_DEFAULTS = {
    HOARD = { image = "rbxassetid://95202532327953", offset = { 18, 0 }, size = { 18, 18 } },
    SHOP = { image = "rbxassetid://120321831419148" },
    CHEST = { image = "rbxassetid://116030223007249" },
    SHRINE = { image = "rbxassetid://119641795033383" },
    BOSS = { image = "rbxassetid://130798371196238" },
}
-- (the hidden attribute slots of every tile carry it too: only the "shop" slot's copy counts)
DungeonRun.SHOP_ICON = "rbxassetid://120321831419148"
function DungeonRun.FindIcons()
    Lobby.cfg.dungeonIcons4 = Lobby.cfg.dungeonIcons4 or {}
    local icons, found, cands = Lobby.cfg.dungeonIcons4, {}, {}
    local function typeOf(text)
        local w = string.upper(tostring(text or "")):gsub("<[^>]->", "")
        for _, t in ipairs(DungeonRun.TYPES) do
            if w == t or w == t .. " ROOM" or w == t .. "ROOM" then return t end
        end
    end
    local function keyOf(icon)
        local o, z = icon.offset or {}, icon.size or {}
        return string.format("%s|%s,%s|%s,%s", tostring(icon.image), tostring(o[1] or 0), tostring(o[2] or 0), tostring(z[1] or 0), tostring(z[2] or 0))
    end
    local function learn(t, image, from, x)
        image = tostring(image or "")
        if not t or image == "" then return end
        local icon = { image = image }
        if x then
            pcall(function()
                local o, z = x.ImageRectOffset, x.ImageRectSize
                if z and (z.X or 0) > 0 and (z.Y or 0) > 0 then
                    icon.offset, icon.size = { o and o.X or 0, o and o.Y or 0 }, { z.X, z.Y }
                end
            end)
        end
        table.insert(cands, { t = t, icon = icon, key = keyOf(icon), from = from })
    end
    -- the room tiles' attribute pictures, by their names (visible ones, not the template; the shop picture
    -- only from the shop slot)
    pcall(function()
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = gui and gui:FindFirstChild("DungeonUI")
        for _, d in ipairs(ui and ui:GetDescendants() or {}) do
            local t = (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Parent and d.Parent.Name == "LevelAttributes"
                and DungeonRun.ATTR_TYPES[string.lower(d.Name)]
            if t and t ~= "CURSE" and isOnScreen(d) and not d:FindFirstAncestor("Configuration")
                and tostring(d.Image) ~= "" and (t == "SHOP" or tostring(d.Image) ~= DungeonRun.SHOP_ICON) then
                learn(t, d.Image, "DungeonUI." .. d.Name, d)
            end
        end
    end)
    pcall(function()
        local data = ReplicatedStorage.src.Data
        for _, m in ipairs(data:GetDescendants()) do
            if m:IsA("ModuleScript") and string.lower(m.Name):find("dungeon", 1, true) then
                local ok, mod = pcall(require, m)
                local function walk(v, key, depth)
                    if type(v) ~= "table" or depth > 3 then return end
                    local t = typeOf(key) or typeOf(v.type) or typeOf(v.name) or typeOf(v.id)
                    if t then
                        for k, x in pairs(v) do
                            local lk = string.lower(tostring(k))
                            if (lk:find("image", 1, true) or lk:find("icon", 1, true)) and (type(x) == "string" or type(x) == "number") then
                                learn(t, type(x) == "number" and ("rbxassetid://" .. x) or x, m.Name)
                            end
                        end
                    end
                    for k, x in pairs(v) do walk(x, k, depth + 1) end
                end
                if ok then walk(mod, m.Name, 0) end
            end
        end
    end)
    -- one icon per type: drop an image + rect seen (now or saved) for another type
    local typesOf = {}
    local function mark(key, t) typesOf[key] = typesOf[key] or {} typesOf[key][t] = true end
    for _, c in ipairs(cands) do mark(c.key, c.t) end
    for t, icon in pairs(icons) do if type(icon) == "table" then mark(keyOf(icon), t) else icons[t] = nil end end
    local function shared(key) local n = 0 for _ in pairs(typesOf[key] or {}) do n = n + 1 end return n > 1 end
    for t, icon in pairs(icons) do if shared(keyOf(icon)) then icons[t] = nil end end
    for _, c in ipairs(cands) do
        if not icons[c.t] and not shared(c.key) then
            icons[c.t] = c.icon
            local o, z = c.icon.offset, c.icon.size
            found[#found + 1] = c.t .. "=" .. c.icon.image .. (z and string.format(" rect %s,%s %sx%s", o[1], o[2], z[1], z[2]) or "") .. " (" .. c.from .. ")"
        end
    end
    if #found > 0 then
        pcall(Lobby.ShareLog, "dungeon: room icons " .. table.concat(found, ", "))
        pcall(DungeonRun.Log, "room icons " .. table.concat(found, ", "))
        saveConfig()
    end
    return icons
end
-- One dump per script load of the Dungeon Run window while its room choice is open (AAMacro/
-- dungeon_ui_dump.txt): every descendant of the room area with path, class, text, image + sprite
-- rect, visibility, position and size - icon learning matched the depth slider, not the tiles,
-- in the real game (17:32-17:50 2026-10-25), so the tile layout has to be seen first.
-- The other Dungeon Run pages, once each per script load while on screen (AAMacro/
-- dungeon_pages_dump.txt): shop rows, shrine offer, chest page, You Died - to find the pictures of
-- shop items and shrine buffs (owner 2026-10-25: "find every dungeon picture").
DungeonRun.PAGES = { "ShopSelection", "ShrineRoom", "OpenTreasure", "YouDied" }
function DungeonRun.DumpPages()
    if not hasFileApi() then return end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    if not ui or (ui:IsA("LayerCollector") and not ui.Enabled) then return end
    DungeonRun.pagesDumped = DungeonRun.pagesDumped or {}
    for _, name in ipairs(DungeonRun.PAGES) do
        local page = not DungeonRun.pagesDumped[name] and ui:FindFirstChild(name, true)
        if page and isOnScreen(page) then
            DungeonRun.pagesDumped[name] = true
            local lines = { "# " .. name .. " " .. os.date("%Y-%m-%d %H:%M:%S") }
            for _, d in ipairs(page:GetDescendants()) do
                if #lines >= 400 then table.insert(lines, "... (capped)") break end
                pcall(function()
                    local parts = { (d:GetFullName():gsub("^.-" .. name .. "%.", "")), d.ClassName }
                    if d:IsA("TextLabel") or d:IsA("TextButton") then table.insert(parts, "text=" .. clip(tostring(d.Text), 60)) end
                    if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                        table.insert(parts, "image=" .. tostring(d.Image))
                        pcall(function()
                            local o, z = d.ImageRectOffset, d.ImageRectSize
                            if z and (z.X > 0 or z.Y > 0) then table.insert(parts, string.format("rect=%d,%d %dx%d", o.X, o.Y, z.X, z.Y)) end
                        end)
                    end
                    if d:IsA("GuiObject") then table.insert(parts, "visible=" .. tostring(isOnScreen(d))) end
                    table.insert(lines, table.concat(parts, " | "))
                end)
            end
            DungeonRun.Append("AAMacro/dungeon_pages_dump.txt", table.concat(lines, "\n") .. "\n", 300000)
            pcall(Lobby.ShareLog, "dungeon: dumped page " .. name)
        end
    end
end

-- Item pictures from the game itself (owner 2026-10-26: most rows still showed the generic icon). Once per
-- script load (again 60 s after a new id): every ModuleScript in ReplicatedStorage whose path names data /
-- dungeon / item / relic / blessing / curse / shop / shrine is required and walked for the item ids we know
-- (plus the ones seen so far); an image / icon field becomes that item's picture. The game's DungeonUI is
-- searched too, for objects NAMED by an item id (its templates). Everything found goes to
-- AAMacro/dungeon_items_dump.txt (pull it with adb when nothing is found).
DungeonRun.SEED_IDS = { "sword1", "sword2", "bow1", "bow2", "icebane", "hook", "boots", "chest_mock_item", "gold_branch",
    "gold_shroom", "dagger", "dagger1", "ninja_belt", "stormbringer", "axe", "genie_lamp", "philosophers_stone", "_curse_money",
    "_curse_super_armored", "_curse_fly", "_curse_regen", "_curse_speed", "_curse_health", "_curse_shop" }
DungeonRun.SCAN_WORDS = { "data", "dungeon", "item", "relic", "blessing", "curse", "shop", "shrine" }
DungeonRun.IMAGE_KEYS = { "image", "icon", "img", "thumb", "texture", "decal" }
function DungeonRun.ScanData()
    if DungeonRun.dataScanned or os.clock() - (DungeonRun.scanAt or -1e9) < 60 then return end
    DungeonRun.dataScanned, DungeonRun.scanAt = true, os.clock()
    local ids = {}
    for _, id in ipairs(DungeonRun.SEED_IDS) do ids[id] = true end
    for _, kind in ipairs({ "shop", "shrine" }) do
        for _, it in ipairs(DungeonRun.ItemList(kind)) do ids[it.id] = true end
    end
    for id in pairs(Lobby.cfg.dungeonItems or {}) do ids[id] = true end
    local lines, maybe, found, modules = {}, {}, {}, 0
    Lobby.cfg.dungeonItemIcons = Lobby.cfg.dungeonItemIcons or {}
    local icons = Lobby.cfg.dungeonItemIcons
    local function imageOf(k, x)
        local lk = string.lower(tostring(k))
        for _, w in ipairs(DungeonRun.IMAGE_KEYS) do
            if lk:find(w, 1, true) and (type(x) == "string" or type(x) == "number") then
                local img = type(x) == "number" and ("rbxassetid://" .. x) or tostring(x)
                if img:find("%d") then return img end
            end
        end
    end
    local modulesDue = os.time() - (Lobby.cfg.dungeonModuleScan or 0) > 86400
    if modulesDue then Lobby.cfg.dungeonModuleScan = os.time() end
    pcall(function()
        for _, m in ipairs(modulesDue and ReplicatedStorage:GetDescendants() or {}) do
            if m:IsA("ModuleScript") and #lines < 1500 then
                local path = string.lower(m:GetFullName())
                local hit = false
                for _, w in ipairs(DungeonRun.SCAN_WORDS) do if path:find(w, 1, true) then hit = true break end end
                if hit then
                    local ok, mod = pcall(require, m)
                    if ok and type(mod) == "table" then
                        modules = modules + 1
                        local dungeonish = path:find("dungeon", 1, true) or path:find("relic", 1, true) or path:find("blessing", 1, true) or path:find("curse", 1, true)
                        local function walk(v, key, depth)
                            if type(v) ~= "table" or depth > 5 or #lines > 1500 then return end
                            local id = ids[tostring(key)] and tostring(key) or (type(v.id) == "string" and ids[v.id] and v.id)
                            local fields, img = {}, nil
                            for k, x in pairs(v) do
                                if type(x) == "string" or type(x) == "number" or type(x) == "boolean" then
                                    table.insert(fields, tostring(k) .. "=" .. clip(tostring(x), 60))
                                    img = img or imageOf(k, x)
                                end
                            end
                            if id then
                                table.sort(fields)
                                table.insert(lines, m:GetFullName() .. " [" .. id .. "] " .. table.concat(fields, " "))
                                if img and not icons[id] then icons[id] = { image = img } table.insert(found, id .. "=" .. img) end
                            elseif img and dungeonish and #maybe < 300 then
                                table.sort(fields)
                                table.insert(maybe, m:GetFullName() .. " [" .. tostring(key) .. "] " .. table.concat(fields, " "))
                            end
                            for k, x in pairs(v) do walk(x, k, depth + 1) end
                        end
                        walk(mod, m.Name, 0)
                    end
                end
            end
        end
    end)
    -- ReplicatedStorage Instances named by an item id or name: an Image / Texture, a picture child,
    -- a StringValue or an attribute holding an asset id
    local names = {}
    for _, it in ipairs(DungeonRun.AllItems()) do names[DungeonRun.NameKey(it.name)] = it.id end
    local inst = {}
    pcall(function()
        for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
            local low = string.lower(d.Name)
            local id = ids[low] and low or names[DungeonRun.NameKey(d.Name)]
            if id and #inst < 300 then
                local img
                pcall(function()
                    if d:IsA("ImageLabel") or d:IsA("ImageButton") then img = tostring(d.Image)
                    elseif d:IsA("Decal") then img = tostring(d.Texture)
                    elseif d:IsA("StringValue") and tostring(d.Value):find("%d%d%d%d") then img = tostring(d.Value) end
                end)
                if not img or img == "" then
                    local c = d:FindFirstChildWhichIsA("ImageLabel", true) or d:FindFirstChildWhichIsA("Decal", true)
                    pcall(function() img = c and tostring(c:IsA("Decal") and c.Texture or c.Image) or nil end)
                end
                pcall(function()
                    for k, v in pairs(d:GetAttributes()) do
                        if not img and imageOf(k, v) then img = imageOf(k, v) end
                    end
                end)
                if img and img ~= "" and not DungeonRun.FRAME_IMAGES[img] then
                    table.insert(inst, d:GetFullName() .. " [" .. id .. "] " .. d.ClassName .. " image=" .. img)
                    if not icons[id] then icons[id] = { image = img } table.insert(found, id .. "=" .. img .. " (instance)") end
                end
            end
        end
    end)
    -- the game's own windows: objects named by an item id (its templates)
    local ui = {}
    pcall(function()
        local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        for _, d in ipairs(gui and gui:GetDescendants() or {}) do
            local id = string.lower(d.Name)
            if ids[id] then
                local imgObj = (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d or d:FindFirstChildWhichIsA("ImageLabel", true)
                local img = imgObj and tostring(imgObj.Image) or ""
                if img ~= "" and img ~= DungeonRun.SHOP_ICON then
                    table.insert(ui, d:GetFullName() .. " image=" .. img)
                    if not icons[id] then icons[id] = { image = img } table.insert(found, id .. "=" .. img .. " (ui)") end
                end
            end
        end
    end)
    -- (between the daily module reads the last full dump is kept)
    if hasFileApi() and (modulesDue or #inst > 0 or #ui > 0) then
        writefile("AAMacro/dungeon_items_dump.txt", table.concat({ "# dungeon items " .. os.date("%Y-%m-%d %H:%M:%S") ..
            " - " .. modules .. " modules read" .. (modulesDue and "" or " (modules: once a day, read before)"), "## entries for known ids", table.concat(lines, "\n"),
            "## other entries with an image in dungeon / relic / blessing / curse modules", table.concat(maybe, "\n"),
            "## ReplicatedStorage objects named by an item", table.concat(inst, "\n"),
            "## GUI objects named by an item id", table.concat(ui, "\n") }, "\n"))
    end
    if #found > 0 or modulesDue then
        if #found > 0 then pcall(DungeonRun.Log, "item icons from the game " .. table.concat(found, ", ")) end
        saveConfig()
    end
    pcall(DungeonRun.WriteIconFile)
end

function DungeonRun.DumpUI()
    if DungeonRun.uiDumped or not hasFileApi() then return end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    if not ui or (ui:IsA("LayerCollector") and not ui.Enabled) then return end
    local area = ui:FindFirstChild("LevelSelection", true)
    local areaShown = area ~= nil and isOnScreen(area)
    if not areaShown and not DungeonRun.ChoiceOpen() then return end
    DungeonRun.uiDumped = true
    local root = areaShown and area or ui
    local lines = { "# DungeonUI dump " .. os.date("%Y-%m-%d %H:%M:%S") .. " root " .. root:GetFullName() }
    for _, d in ipairs(root:GetDescendants()) do
        if #lines >= 600 then table.insert(lines, "... (capped at 600 lines)") break end
        pcall(function()
            local parts = { (d:GetFullName():gsub("^.-DungeonUI%.", "")), d.ClassName }
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then table.insert(parts, "text=" .. clip(tostring(d.Text), 50)) end
            if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                table.insert(parts, "image=" .. tostring(d.Image))
                pcall(function()
                    local o, z = d.ImageRectOffset, d.ImageRectSize
                    if z and (z.X > 0 or z.Y > 0) then table.insert(parts, string.format("rect=%d,%d %dx%d", o.X, o.Y, z.X, z.Y)) end
                end)
            end
            if d:IsA("GuiObject") then
                table.insert(parts, "visible=" .. tostring(isOnScreen(d)))
                local p, z = d.AbsolutePosition, d.AbsoluteSize
                if p and z then table.insert(parts, string.format("at=%d,%d size=%dx%d", p.X, p.Y, z.X, z.Y)) end
            end
            table.insert(lines, table.concat(parts, " | "))
        end)
    end
    writefile("AAMacro/dungeon_ui_dump.txt", table.concat(lines, "\n"))
    pcall(Lobby.ShareLog, "dungeon: wrote dungeon_ui_dump.txt (" .. #lines .. " lines)")
end

-- Learn while the room choice is on screen (every 15 s at most, until every room type has one).
function DungeonRun.LearnIcons()
    if os.clock() - (DungeonRun.iconsAt or -1e9) < 15 then return end
    local icons = Lobby.cfg.dungeonIcons4 or {}
    local missing = false
    for _, t in ipairs(DungeonRun.ROOM_TYPES) do if not icons[t] then missing = true end end
    if not missing or not DungeonRun.ChoiceOpen() then return end
    DungeonRun.iconsAt = os.clock()
    pcall(DungeonRun.FindIcons)
end
-- An item's picture on a picker row: learned from the shop window, else an emoji.
-- The game's shop / shrine page lists its rows in the order of the page data's ids: the picture in
-- row i is item i's (sprite rect kept). Saved like the room icons, logged once per item.
-- (the game's cards: SellFrame / OfferFrameItem, each with ItemImage + ItemName. The page's own
-- frame pictures - inset, border, EvolvedGlow, the coin - are not items; the Configuration template
-- is no row: it made 4 rows for 3 items, so nothing was ever learned - device dump 2026-10-26)
DungeonRun.FRAME_IMAGES = { ["rbxassetid://126788194153452"] = true, ["rbxassetid://93100413948929"] = true,
    ["rbxassetid://104758976705209"] = true, ["rbxassetid://95202532327953"] = true }
-- Pictures read from the game's shop / shrine pages (device dump 2026-10-25/26), by item name.
DungeonRun.NAME_ICONS = { ["speedy boots"] = "rbxassetid://110168360769036", ["treasure chest"] = "rbxassetid://103690538373746",
    ["curse of armor"] = "rbxassetid://131564693808604", bow = "rbxassetid://83257385637914", dagger = "rbxassetid://99767692490865",
    ["ninja belt"] = "rbxassetid://129383649740464", stormbringer = "rbxassetid://82443821880546", axe = "rbxassetid://126820581831157",
    ["nimble cloak"] = "rbxassetid://112490194054135" }
function DungeonRun.NameKey(name)
    return (string.lower(tostring(name or "")):gsub("^%[[^%]]*%]%s*", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
-- An item's picture: learned by id, else by its name, else the built-in one by name.
function DungeonRun.ItemIcon(it)
    local key = DungeonRun.NameKey(it.name)
    local icon = (Lobby.cfg.dungeonNameIcons or {})[key]
    if type(icon) == "table" and icon.image then return icon end
    icon = (Lobby.cfg.dungeonItemIcons or {})[it.id]
    if type(icon) == "table" and icon.image and not DungeonRun.FRAME_IMAGES[icon.image] and icon.image ~= DungeonRun.SHOP_ICON then return icon end
    return DungeonRun.NAME_ICONS[key] and { image = DungeonRun.NAME_ICONS[key] } or nil
end
-- Every item seen: shop, shrine (blessings / curses) and the run's other items (chest relics).
function DungeonRun.AllItems()
    local out = {}
    for _, kind in ipairs({ "shop", "shrine", "relic" }) do
        for _, it in ipairs(DungeonRun.ItemList(kind)) do table.insert(out, it) end
    end
    return out
end
-- AAMacro/dungeon_icons.txt: every picture learned (name -> asset, id -> asset) and, at the end,
-- the items still without one - pulled with adb to bake the full table into NAME_ICONS.
function DungeonRun.WriteIconFile()
    if not hasFileApi() then return end
    local lines, names, missing = { "# dungeon icons " .. os.date("%Y-%m-%d %H:%M:%S"), "## by name" }, {}, {}
    for k, v in pairs(Lobby.cfg.dungeonNameIcons or {}) do
        if type(v) == "table" and v.image then table.insert(names, string.format("%q = %q,", k, v.image)) end
    end
    for k, v in pairs(DungeonRun.NAME_ICONS) do
        if not (Lobby.cfg.dungeonNameIcons or {})[k] then table.insert(names, string.format("%q = %q, -- built in", k, v)) end
    end
    table.sort(names)
    for _, l in ipairs(names) do table.insert(lines, l) end
    table.insert(lines, "## by id")
    local ids = {}
    for _, it in ipairs(DungeonRun.AllItems()) do
        local icon = DungeonRun.ItemIcon(it)
        if icon then table.insert(ids, string.format("%s (%s) = %s", it.id, it.name, icon.image))
        else table.insert(missing, string.format("%s (%s, %s)", it.id, it.name, it.kind)) end
    end
    table.sort(ids)
    table.sort(missing)
    for _, l in ipairs(ids) do table.insert(lines, l) end
    table.insert(lines, "## still missing a picture: " .. #missing)
    for _, l in ipairs(missing) do table.insert(lines, l) end
    local text = table.concat(lines, "\n")
    if text:gsub("^[^\n]*", "") == (DungeonRun.iconFileText or ""):gsub("^[^\n]*", "") then return end
    DungeonRun.iconFileText = text
    pcall(writefile, "AAMacro/dungeon_icons.txt", text)
end
function DungeonRun.LearnRowIcons(pageName, data)
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local page = ui and ui:FindFirstChild(pageName, true)
    if not page or not isOnScreen(page) then return end
    local list = page:FindFirstChildWhichIsA("ScrollingFrame", true) or page
    local rows = {}
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") and c.Visible ~= false and c:FindFirstChildWhichIsA("ImageLabel", true) then table.insert(rows, c) end
    end
    local function order(x) local ok, v = pcall(function() return x.LayoutOrder end) return ok and tonumber(v) or 0 end
    table.sort(rows, function(a, b)
        if order(a) ~= order(b) then return order(a) < order(b) end
        return a.AbsolutePosition.Y < b.AbsolutePosition.Y
    end)
    Lobby.cfg.dungeonItemIcons = Lobby.cfg.dungeonItemIcons or {}
    Lobby.cfg.dungeonNameIcons = Lobby.cfg.dungeonNameIcons or {}
    local icons, byName, found = Lobby.cfg.dungeonItemIcons, Lobby.cfg.dungeonNameIcons, {}
    local byOrder = type(data) == "table" and #data == #rows
    for i, row in ipairs(rows) do
        -- the card's ItemImage first, else its first picture that is not part of the frame
        local pic = row:FindFirstChild("ItemImage", true)
        if not (pic and (pic:IsA("ImageLabel") or pic:IsA("ImageButton"))) then
            pic = nil
            for _, x in ipairs(row:GetDescendants()) do
                local img = (x:IsA("ImageLabel") or x:IsA("ImageButton")) and tostring(x.Image) or ""
                if img ~= "" and img ~= DungeonRun.SHOP_ICON and not DungeonRun.FRAME_IMAGES[img] then pic = x break end
            end
        end
        local img = pic and tostring(pic.Image) or ""
        if img ~= "" and img ~= DungeonRun.SHOP_ICON and not DungeonRun.FRAME_IMAGES[img] then
            local icon = { image = img }
            pcall(function()
                local o, z = pic.ImageRectOffset, pic.ImageRectSize
                if z and z.X > 0 and z.Y > 0 then icon.offset, icon.size = { o.X, o.Y }, { z.X, z.Y } end
            end)
            local nameLabel = row:FindFirstChild("ItemName", true)
            local key = nameLabel and nameLabel:IsA("TextLabel") and DungeonRun.NameKey(nameLabel.Text) or ""
            if key ~= "" and not (byName[key] and byName[key].image == img) then byName[key] = icon table.insert(found, key .. "=" .. img) end
            local id = byOrder and (type(data[i]) == "table" and tostring(data[i].id or "") or tostring(data[i])) or ""
            local old = icons[id]
            if id ~= "" and (type(old) ~= "table" or DungeonRun.FRAME_IMAGES[old.image or ""]) then
                icons[id] = icon
                table.insert(found, id .. "=" .. img)
            end
        end
    end
    if #found > 0 then
        pcall(DungeonRun.Log, "item icons from " .. pageName .. " " .. table.concat(found, ", "))
        pcall(DungeonRun.WriteIconFile)
        saveConfig()
    end
end
-- Each row's name and effect as the game's page shows them (rows in the order of the page data's ids):
-- the first text that is not a number is the name, the next the effect. Kept by id in Lobby.cfg.dungeonItems.
function DungeonRun.LearnRowTexts(pageName, data, kind)
    if type(data) ~= "table" or #data == 0 then return end
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("DungeonUI")
    local page = ui and ui:FindFirstChild(pageName, true)
    if not page or not isOnScreen(page) then return end
    local list = page:FindFirstChildWhichIsA("ScrollingFrame", true) or page
    local rows = {}
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") then table.insert(rows, c) end
    end
    if #rows ~= #data then return end
    local function order(x) local ok, v = pcall(function() return x.LayoutOrder end) return ok and tonumber(v) or 0 end
    table.sort(rows, function(a, b)
        if order(a) ~= order(b) then return order(a) < order(b) end
        return a.AbsolutePosition.Y < b.AbsolutePosition.Y
    end)
    Lobby.cfg.dungeonItems = Lobby.cfg.dungeonItems or {}
    local found = {}
    for i, row in ipairs(rows) do
        local id = type(data[i]) == "table" and tostring(data[i].id or "") or tostring(data[i])
        local texts = {}
        for _, d in ipairs(row:GetDescendants()) do
            if d:IsA("TextLabel") and not d:FindFirstAncestorWhichIsA("GuiButton") then
                local t = tostring(d.Text):gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
                if t ~= "" and not t:match("^[%d%s,%.xX/]+$") then table.insert(texts, t) end
            end
        end
        local name, effect = texts[1], texts[2]
        if id ~= "" and name then
            local v = Lobby.cfg.dungeonItems[id] or { kind = kind }
            if v.name ~= name or v.effect ~= effect then
                -- ([*] marks a special item - Stormbringer: scored by its effect like the rest; a downside in
                -- its effect text (a curse word) counts against it)
                v.special = name:find("^%[%*%]") ~= nil or nil
                v.name, v.effect = name:gsub("^%[%*%]%s*", ""), effect
                Lobby.cfg.dungeonItems[id] = v
                table.insert(found, id .. "=" .. v.name .. " / " .. tostring(effect))
            end
        end
    end
    if #found > 0 then
        pcall(DungeonRun.Log, "item names from " .. pageName .. ": " .. table.concat(found, ", "))
        saveConfig()
    end
end
-- One item for a row: name and effect from our list / the wiki, by the game's id.
function DungeonRun.ItemInfo(id)
    id = tostring(id or "")
    local kind = id:find("^_curse") and "shrine" or "shop"
    for _, k in ipairs({ "shop", "shrine" }) do
        for _, it in ipairs(DungeonRun.ItemList(k)) do
            if it.id == id and it.effect ~= "(seen in game)" then return it end
        end
    end
    local text = DungeonRun.ItemText(id)
    if text ~= id then
        for name, effect in pairs(DungeonRun.WIKI_EFFECTS) do
            if text == name .. " " .. effect then
                local pretty = name:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
                return { id = id, kind = kind, name = pretty, effect = effect }
            end
        end
    end
    local pretty = id:gsub("^_", ""):gsub("_", " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
    return { id = id, kind = kind, name = pretty, effect = "(effect not known yet)" }
end
function DungeonRun.ItemIconOn(parent, it, x, y, size)
    local icon = DungeonRun.ItemIcon(it)
    if type(icon) == "table" and icon.image then
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency, img.Image = 1, icon.image
        if icon.size then
            pcall(function()
                img.ImageRectOffset = Vector2.new(icon.offset[1] or 0, icon.offset[2] or 0)
                img.ImageRectSize = Vector2.new(icon.size[1], icon.size[2])
            end)
        end
        img.Position, img.Size = UDim2.new(0, x, 0, y), UDim2.new(0, size, 0, size)
        img.Parent = parent
        return img
    end
    local e = Instance.new("TextLabel")
    e.BackgroundTransparency, e.TextSize, e.TextColor3 = 1, 26, DungeonRun.COLORS.text
    e.Text = it.kind == "shrine" and "🔮" or "🛍️"
    e.Position, e.Size = UDim2.new(0, x, 0, y), UDim2.new(0, size, 0, size)
    e.Parent = parent
    return e
end
-- An icon on a tile: the learned picture (sprite rect when it has one), else the emoji.
function DungeonRun.IconOn(parent, t, x, y, size)
    local icon = (Lobby.cfg.dungeonIcons4 or {})[t] or DungeonRun.ICON_DEFAULTS[t]
    if type(icon) == "table" and icon.image then
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency, img.Image = 1, icon.image
        if icon.size then
            pcall(function()
                img.ImageRectOffset = Vector2.new(icon.offset[1] or 0, icon.offset[2] or 0)
                img.ImageRectSize = Vector2.new(icon.size[1], icon.size[2])
            end)
        end
        img.Position, img.Size = UDim2.new(0.5, -size / 2, 0, y), UDim2.new(0, size, 0, size)
        img.Parent = parent
        return img
    end
    local e = Instance.new("TextLabel")
    e.BackgroundTransparency, e.Text, e.TextSize, e.TextColor3 = 1, DungeonRun.EMOJI[t] or "?", 28, DungeonRun.COLORS.text
    e.Position, e.Size = UDim2.new(0, 0, 0, y), UDim2.new(1, 0, 0, size)
    e.Parent = parent
    return e
end

-- Setup window (our own ScreenGui): mode, room preferences, shrines, rare chests. Edits go to a
-- draft; Save & Close applies and saves, X closes without saving.
DungeonRun.COLORS = { bg = Color3.fromRGB(24, 24, 30), panel = Color3.fromRGB(44, 44, 54), on = Color3.fromRGB(60, 130, 240),
    prefer = Color3.fromRGB(40, 150, 80), avoid = Color3.fromRGB(180, 55, 55), text = Color3.fromRGB(235, 235, 240),
    frame = Color3.fromRGB(14, 14, 20), gold = Color3.fromRGB(255, 205, 60), dim = Color3.fromRGB(190, 190, 200),
    preferEdge = Color3.fromRGB(110, 230, 140), avoidEdge = Color3.fromRGB(255, 120, 120),
    picked = Color3.fromRGB(62, 70, 92), glow = Color3.fromRGB(255, 215, 90) }
function DungeonRun.OpenSetup()
    pcall(function() if DungeonRun.setupGui then DungeonRun.setupGui:Destroy() end end)
    pcall(DungeonRun.FindIcons)
    pcall(DungeonRun.ScanData)
    local C = DungeonRun.COLORS
    local prefs = {}
    for k, v in pairs(DungeonRun.prefs or {}) do prefs[k] = v end
    local draft = { mode = DungeonRun.mode, prefs = prefs, shrineRule = DungeonRun.shrineRule or (DungeonRun.acceptShrines and "always" or "never"),
        openRare = DungeonRun.openRareAtEnd ~= false, autoShop = DungeonRun.autoShop ~= false, goldChests = DungeonRun.goldChests or "end",
        itemPrefs = {} }
    for k, v in pairs(DungeonRun.itemPrefs or {}) do draft.itemPrefs[k] = v end
    local g = Instance.new("ScreenGui")
    -- (owner 2026-10-25: the popup opened BEHIND the hub window - it now sits on top of everything and
    -- the hub is hidden until Save & Close / X)
    g.Name, g.ResetOnSpawn, g.DisplayOrder = "MoseeriDungeonSetup", false, 1000000
    pcall(function() g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling end)
    local holder = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    local hidden = {}
    pcall(function()
        for _, c in ipairs(holder:GetChildren()) do
            if c:IsA("ScreenGui") and c.Name ~= "MoseeriDungeonSetup" and c.Enabled then
                for _, d in ipairs(c:GetDescendants()) do
                    if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == "moseeri hub" then
                        c.Enabled = false
                        table.insert(hidden, c)
                        break
                    end
                end
            end
        end
    end)
    local function close()
        for _, c in ipairs(hidden) do pcall(function() c.Enabled = true end) end
        pcall(function() g:Destroy() end)
        DungeonRun.setupGui = nil
    end
    local win = Instance.new("Frame")
    win.Name, win.Size, win.Position = "Window", UDim2.new(0, 380, 0, 410), UDim2.new(0.5, -190, 0.5, -205)
    win.BackgroundColor3, win.BorderSizePixel, win.Active = C.bg, 0, true
    win.Parent = g
    pcall(function() Instance.new("UICorner").Parent = win end)
    local function label(text, x, y, w, h, size, parent)
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency, l.TextColor3, l.Font, l.TextSize = 1, C.text, Enum.Font.GothamBold, size or 14
        l.TextXAlignment, l.TextWrapped = Enum.TextXAlignment.Left, true
        l.Position, l.Size, l.Text = UDim2.new(0, x, 0, y), UDim2.new(0, w, 0, h), text
        l.Parent = parent or win
        return l
    end
    local function button(text, x, y, w, h, onClick, parent)
        local b = Instance.new("TextButton")
        b.Position, b.Size, b.Text = UDim2.new(0, x, 0, y), UDim2.new(0, w, 0, h), text
        b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize, b.AutoButtonColor, b.BorderSizePixel = C.panel, C.text, Enum.Font.GothamBold, 14, true, 0
        b.Parent = parent or win
        pcall(function() Instance.new("UICorner").Parent = b end)
        b.Activated:Connect(function() pcall(onClick, b) end)
        return b
    end
    -- (the "moseeri hub" label marks the window as ours: our own result-screen clicker skips it)
    label("moseeri hub", 12, 6, 120, 16, 11)
    local title = label("Dungeon setup", 12, 20, 300, 24, 18)
    button("X", 340, 8, 30, 30, close)
    -- drag by the title
    pcall(function()
        local UIS = game:GetService("UserInputService")
        local dragging, start, startPos
        title.Active = true
        title.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, start, startPos = true, i.Position, win.Position
            end
        end)
        UIS.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - start
                win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
        UIS.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
        end)
    end)
    local paint = {}
    local function repaint() for _, f in ipairs(paint) do pcall(f) end end
    -- mode (owner 2026-10-25: plain names and one line saying the difference)
    label("Room choice", 12, 50, 200, 18)
    -- (owner 2026-10-25: each mode button says what it does - bold title, small line under it)
    for i, m in ipairs({ { "Auto", "Auto", "script picks rooms, shops and chests for you" },
        { "My picks", "Fixed", "you choose rooms, shop items and chests" } }) do
        local b = button("", 12 + (i - 1) * 182, 70, 174, 60, function() draft.mode = m[2] repaint() end)
        local t = label(m[1], 8, 4, 158, 22, 16, b)
        t.TextXAlignment = Enum.TextXAlignment.Center
        local sub = label(m[3], 8, 26, 158, 30, 11, b)
        sub.TextXAlignment, sub.TextColor3 = Enum.TextXAlignment.Center, C.dim
        table.insert(paint, function()
            b.BackgroundColor3 = draft.mode == m[2] and C.on or C.panel
            sub.TextColor3 = draft.mode == m[2] and C.text or C.dim
        end)
    end
    -- Select by tap (owner 2026-10-26): a selected card / room glows (border + brighter), tap again =
    -- not selected. My picks: tap to change; Auto: read-only, the glow shows what the script picks.
    local function glow(b, isOn)
        local stroke
        pcall(function()
            stroke = Instance.new("UIStroke")
            stroke.Thickness, stroke.Color, stroke.Parent = 2, C.glow, b
        end)
        table.insert(paint, function()
            if not b.Parent then return end
            local on = isOn()
            b.BackgroundColor3 = on and C.picked or C.panel
            if stroke then pcall(function() stroke.Transparency = on and 0 or 1 end) end
        end)
    end
    local function roomOn(t) return draft.mode == "Auto" or draft.prefs[t] ~= "avoid" end
    local pageFrame
    local function closePage() pcall(function() pageFrame:Destroy() end) pageFrame = nil repaint() end
    -- groups: shop by what the item does, shrine blessings first then curses by danger
    local function itemGroup(it)
        local text = string.lower(it.name .. " " .. it.effect)
        if it.kind == "shrine" then
            local v, curse = DungeonRun.ItemValue(it.name .. " " .. it.effect)
            if not curse then return 1, "Blessings" end
            return (v <= -4) and 2 or 3, (v <= -4) and "Dangerous curses" or "Other curses"
        end
        if text:find("cost", 1, true) then return 1, "Cost cuts" end
        if text:find("dmg", 1, true) or text:find("damage", 1, true) or text:find("crit", 1, true) or text:find("attack", 1, true) and not text:find("speed", 1, true) then return 2, "Damage" end
        if text:find("range", 1, true) or text:find("speed", 1, true) or text:find("cooldown", 1, true) or text:find("slower", 1, true) then return 3, "Range & speed" end
        if text:find("luck", 1, true) or text:find("chest", 1, true) then return 4, "Chest luck" end
        return 5, "Special"
    end
    -- (owner 2026-10-26: like the game's shop page - a grid of item cards, the game's picture on top,
    -- name, value stars, effect; "Recommended for your team" open on top, the other groups folded -
    -- tap the header (+ / -); open groups are remembered for this session only)
    DungeonRun.openGroups = DungeonRun.openGroups or {}
    local function itemList(kind, top, parent)
        local list = Instance.new("ScrollingFrame")
        list.Name, list.Position, list.Size = "List", UDim2.new(0, 8, 0, top), UDim2.new(1, -16, 0, 306 - top)
        list.BackgroundColor3, list.BorderSizePixel = C.frame, 0
        list.Parent = parent
        pcall(function() Instance.new("UICorner").Parent = list end)
        local items = DungeonRun.ItemList(kind)
        local stars, best = DungeonRun.ItemStars(items), DungeonRun.TopItems(items)
        local sorted = {}
        for i, it in ipairs(items) do
            local g, title = itemGroup(it)
            if best[it.id] then g, title, i = 0, "Recommended for your team", best[it.id] end
            table.insert(sorted, { it = it, g = g, title = title, i = i })
        end
        table.sort(sorted, function(a, b) if a.g ~= b.g then return a.g < b.g end return a.i < b.i end)
        local counts = {}
        for _, e in ipairs(sorted) do counts[e.g] = (counts[e.g] or 0) + 1 end
        local CW, CH, GAP = 112, 132, 6
        local function card(it, x, y)
            local b = button("", x, y, CW, CH, function()
                if draft.mode == "Auto" then return end
                draft.itemPrefs[it.id] = DungeonRun.ItemSelected(it.id, draft.itemPrefs) and "avoid" or "prefer"
                repaint()
            end, list)
            b.Name, b.AutoButtonColor = "Pick_" .. it.id, false
            DungeonRun.ItemIconOn(b, it, math.floor((CW - 56) / 2), 6, 56)
            local name = label(it.name, 4, 64, CW - 8, 28, 12, b)
            name.TextColor3, name.TextXAlignment = C.gold, Enum.TextXAlignment.Center
            local st = stars[it.id] or { n = 1 }
            local mark = label(string.rep(st.curse and "☠" or "★", st.n), 4, 92, CW - 8, 12, 11, b)
            mark.Name, mark.TextXAlignment, mark.TextColor3 = "Stars_" .. it.id, Enum.TextXAlignment.Center, st.curse and C.avoidEdge or C.gold
            local eff = label(it.effect, 4, 104, CW - 8, 26, 10, b)
            eff.TextColor3, eff.TextXAlignment = C.dim, Enum.TextXAlignment.Center
            glow(b, function()
                if draft.mode == "Auto" then return DungeonRun.ItemRecommended(it.id) end
                return DungeonRun.ItemSelected(it.id, draft.itemPrefs)
            end)
        end
        local layout
        layout = function()
            list:ClearAllChildren()
            local y, col, lastGroup, open = 4, 0, nil, true
            for _, e in ipairs(sorted) do
                if e.g ~= lastGroup then
                    if col > 0 then y, col = y + CH + GAP, 0 end
                    lastGroup = e.g
                    local key = kind .. "/" .. e.title
                    open = e.g == 0 or DungeonRun.openGroups[key] == true
                    local head = button("", 4, y, 346, 24, function()
                        DungeonRun.openGroups[key] = not DungeonRun.openGroups[key] or nil
                        layout()
                    end, list)
                    head.Name, head.BackgroundTransparency = "Head_" .. e.title, 1
                    -- (+ / - as text: the arrow glyphs showed as empty boxes - owner 2026-10-26)
                    label(e.g == 0 and "" or (open and "-" or "+"), 4, 2, 14, 20, 14, head).TextColor3 = C.dim
                    local t = label(e.title, 20, 2, 240, 20, 12, head)
                    t.Name, t.TextColor3 = "Group_" .. e.title, e.g == 0 and C.gold or C.dim
                    local n = label("(" .. counts[e.g] .. ")", 262, 2, 80, 20, 12, head)
                    n.TextXAlignment, n.TextColor3 = Enum.TextXAlignment.Right, C.dim
                    y = y + 26
                end
                if open then
                    card(e.it, 4 + col * (CW + GAP), y)
                    col = col + 1
                    if col == 3 then y, col = y + CH + GAP, 0 end
                end
            end
            if col > 0 then y = y + CH + GAP end
            pcall(function() list.ScrollBarThickness, list.CanvasSize = 6, UDim2.new(0, 0, 0, y + 4) end)
            repaint()
        end
        layout()
    end
    local function openPage(t)
        pcall(function() if pageFrame then pageFrame:Destroy() end end)
        pageFrame = Instance.new("Frame")
        pageFrame.Name, pageFrame.Position, pageFrame.Size = "Page_" .. t, UDim2.new(0, 0, 0, 48), UDim2.new(1, 0, 1, -48)
        pageFrame.BackgroundColor3, pageFrame.BorderSizePixel, pageFrame.Active = C.bg, 0, true
        pageFrame.Parent = win
        local page = pageFrame
        DungeonRun.IconOn(page, t, 0, 0, 30).Position = UDim2.new(0, 12, 0, 0)
        label(t .. " room", 50, 2, 160, 26, 16, page)
        -- the room itself: one glowing toggle in the header (glowing = go to this room)
        local roomBtn = button("Go to this room", 232, 0, 136, 30, function()
            if draft.mode == "Auto" then return end
            draft.prefs[t] = draft.prefs[t] ~= "avoid" and "avoid" or nil
            repaint()
        end, page)
        roomBtn.Name, roomBtn.TextSize, roomBtn.AutoButtonColor = "Room_" .. t, 12, false
        glow(roomBtn, function() return roomOn(t) end)
        label(draft.mode == "Auto" and "Auto picks these - glowing = yes (switch to My picks to change)" or "Tap to select - glowing = yes",
            12, 34, 356, 20, 11, page).TextColor3 = C.dim
        if t == "SHOP" then
            label("Buy in shops", 12, 58, 280, 26, 13, page)
            local shopBtn = button("", 300, 56, 68, 28, function() draft.autoShop = not draft.autoShop repaint() end, page)
            table.insert(paint, function()
                if not shopBtn.Parent then return end
                shopBtn.Text = draft.autoShop and "ON" or "OFF"
                shopBtn.BackgroundColor3 = draft.autoShop and C.prefer or C.panel
            end)
            itemList("shop", 90, page)
        elseif t == "SHRINE" then
            label("Offers are scored; an offer with an item that is not selected is denied", 12, 54, 356, 30, 11, page)
            itemList("shrine", 90, page)
        elseif t == "CHEST" then
            label("Gold chests", 12, 62, 100, 28, 14, page)
            for i, c in ipairs({ { "Open now", "now" }, { "Keep for the end", "end" } }) do
                local b = button(c[1], 112 + (i - 1) * 130, 60, 124, 30, function() draft.goldChests = c[2] repaint() end, page)
                table.insert(paint, function() if b.Parent then b.BackgroundColor3 = draft.goldChests == c[2] and C.on or C.panel end end)
            end
        else
            label("Coins room - nothing else to set up", 12, 62, 356, 24, 13, page).TextColor3 = C.dim
        end
        button("Back", 130, 312, 120, 34, closePage, page)
        repaint()
    end
    -- the run's items now (blessings and curses), read-only, with their pictures
    local function openRunItems()
        pcall(function() if pageFrame then pageFrame:Destroy() end end)
        pageFrame = Instance.new("Frame")
        pageFrame.Name, pageFrame.Position, pageFrame.Size = "Page_RunItems", UDim2.new(0, 0, 0, 48), UDim2.new(1, 0, 1, -48)
        pageFrame.BackgroundColor3, pageFrame.BorderSizePixel, pageFrame.Active = C.bg, 0, true
        pageFrame.Parent = win
        label("Items in this run", 12, 2, 356, 26, 16, pageFrame)
        local live = type(DungeonRun.live) == "table" and DungeonRun.live or {}
        local items = {}
        for _, it in ipairs(type(live._items) == "table" and live._items or {}) do
            local id = type(it) == "table" and it.id or it
            if id then table.insert(items, DungeonRun.ItemInfo(id)) end
        end
        local list = Instance.new("ScrollingFrame")
        list.Name, list.Position, list.Size = "List", UDim2.new(0, 8, 0, 34), UDim2.new(1, -16, 0, 266)
        list.BackgroundColor3, list.BorderSizePixel = C.frame, 0
        list.Parent = pageFrame
        pcall(function() list.ScrollBarThickness, list.CanvasSize = 6, UDim2.new(0, 0, 0, #items * 62 + 8) end)
        if #items == 0 then label("No blessings or curses yet in this run.", 12, 10, 330, 24, 13, list) end
        for i, it in ipairs(items) do
            local row = Instance.new("Frame")
            row.Name, row.Position, row.Size = "Row_" .. it.id, UDim2.new(0, 4, 0, 4 + (i - 1) * 62), UDim2.new(1, -14, 0, 58)
            row.BackgroundColor3, row.BorderSizePixel = it.kind == "shrine" and Color3.fromRGB(70, 36, 40) or C.panel, 0
            row.Parent = list
            DungeonRun.ItemIconOn(row, it, 6, 7, 44)
            local name = label(it.name, 58, 6, 260, 20, 14, row)
            name.TextColor3 = it.kind == "shrine" and C.avoidEdge or C.gold
            local eff = label(it.effect, 58, 28, 260, 24, 11, row)
            eff.TextColor3 = C.dim
        end
        button("Back", 130, 312, 120, 34, closePage, pageFrame)
    end
    -- (My picks only: the run's blessings and curses)
    local itemsBtn = button("Items", 138, 366, 74, 32, openRunItems)
    table.insert(paint, function() itemsBtn.Visible = draft.mode ~= "Auto" end)
    -- My picks: the room tiles (icon and name, glowing = go to this room; a tap opens the room's page).
    -- Auto: a summary only - nothing to choose (owner 2026-10-26)
    local tapHelp = label("Tap a room to set it up - glowing = go there", 12, 140, 356, 22, 12)
    local summary = label("", 12, 140, 356, 118, 12)
    table.insert(paint, function()
        tapHelp.Visible = draft.mode ~= "Auto"
        summary.Visible = draft.mode == "Auto"
        if draft.mode ~= "Auto" then return end
        local top, names = DungeonRun.TopItems(DungeonRun.ItemList("shop")), {}
        for _, it in ipairs(DungeonRun.ItemList("shop")) do if top[it.id] then names[top[it.id]] = it.name end end
        local bought = DungeonRun.lastBought and DungeonRun.ItemInfo(DungeonRun.lastBought)
        summary.Text = "What Auto does:\n- Rooms: the one your team's damage hits hardest; a room lost before counts harder\n"
            .. "- Shops: buys what is worth most to your team" .. (#names > 0 and (" (now: " .. table.concat(names, ", ") .. ")") or "") .. "\n"
            .. "- Gold (rare) chests: kept for the end - Secret Unit chance\n- Shrines: scored, accepted when worth it"
            .. (bought and ("\nLast bought: " .. bought.name) or "")
    end)
    for i, t in ipairs(DungeonRun.ROOM_TYPES) do
        -- (the tiles share the row's width: 4 since BATTLE has none - owner 2026-10-25)
        local n = #DungeonRun.ROOM_TYPES
        local w = math.floor((356 - (n - 1) * 8) / n)
        local tile = button("", 12 + (i - 1) * (w + 8), 166, w, 86, function() openPage(t) end)
        tile.Name, tile.AutoButtonColor = "Tile_" .. t, false
        DungeonRun.IconOn(tile, t, 0, 10, 40)
        local name = Instance.new("TextLabel")
        name.BackgroundTransparency, name.TextColor3, name.Font, name.TextSize = 1, C.text, Enum.Font.GothamBold, 12
        name.Position, name.Size = UDim2.new(0, 0, 0, 58), UDim2.new(1, 0, 0, 18)
        name.Text, name.Parent = t, tile
        glow(tile, function() return roomOn(t) end)
        table.insert(paint, function() tile.Visible = draft.mode ~= "Auto" end)
    end
    -- the next rooms with the score reason (Auto)
    local nextLabel = label("", 12, 262, 356, 96, 12)
    table.insert(paint, function()
        local st = DungeonRun.Read()
        local lines = {}
        if st and st.live and #st.rooms > 0 then
            local keep = DungeonRun.mode
            DungeonRun.mode = draft.mode
            pcall(function()
                local best = DungeonRun.mode == "Auto" and DungeonRun.AutoPick(st.rooms, st.hearts) or DungeonRun.PickRoom(st.rooms) or st.rooms[1]
                for _, r in ipairs(st.rooms) do
                    table.insert(lines, string.format("%s %s - %s%s", tostring(r.id), tostring(r.label or "?"), DungeonRun.Reason(r), r == best and "  ✓" or ""))
                end
            end)
            DungeonRun.mode = keep
        end
        nextLabel.Text = #lines > 0 and ("Next rooms:\n" .. table.concat(lines, "\n")) or "Next rooms: shown when the game opens the room choice"
    end)
    button("Copy report", 12, 366, 120, 32, function() pcall(DungeonRun.Report) end)
    button("Save & Close", 218, 366, 150, 32, function()
        DungeonRun.mode, DungeonRun.prefs, DungeonRun.shrineRule, DungeonRun.openRareAtEnd = draft.mode, draft.prefs, draft.shrineRule, draft.openRare
        if DungeonRun.legacyPicks then
            for _, kind in ipairs({ "shop", "shrine" }) do
                for _, it in ipairs(DungeonRun.ItemList(kind)) do draft.itemPrefs[it.id] = draft.itemPrefs[it.id] or "prefer" end
            end
        end
        DungeonRun.autoShop, DungeonRun.goldChests, DungeonRun.itemPrefs = draft.autoShop, draft.goldChests, draft.itemPrefs
        DungeonRun.picksV2, DungeonRun.legacyPicks = true, nil
        DungeonRun.acceptShrines = draft.shrineRule ~= "never"
        DungeonRun.ApplyPrefs()
        DungeonRun.blocked = nil
        saveConfig()
        DungeonRun.Refresh(false)
        close()
    end)
    repaint()
    g.Parent = holder
    DungeonRun.setupGui = g
    return g
end

function DungeonRun.Start()
    DungeonRun.gen = (DungeonRun.gen or 0) + 1
    local gen = DungeonRun.gen
    DungeonRun.enabled, DungeonRun.blocked = true, nil
    task.spawn(function()
        while DungeonRun.enabled and gen == DungeonRun.gen and not State.unloaded do
            local ok, wait = pcall(DungeonRun.Step)
            if not ok then DungeonRun.status = "error: " .. clip(tostring(wait), 80) wait = 3 pcall(DungeonRun.Refresh) end
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
    -- (the Space press alone did not reset the idle timer on MuMu / Delta: kicked "idle 20 minutes"
    -- twice on 2026-10-25. Roblox fires Idled before that kick; a VirtualUser click answers it)
    if not ToolsModule.idledConn then
        pcall(function()
            local vu = game:GetService("VirtualUser")
            ToolsModule.idledConn = Players.LocalPlayer.Idled:Connect(function()
                if not Tools.antiAfk then return end
                pcall(function()
                    vu:CaptureController()
                    vu:ClickButton2(Vector2.new())
                end)
            end)
            table.insert(State.connections, ToolsModule.idledConn)
        end)
    end
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
Tools.fxCheck = { BillboardGui = true }
for _, cls in ipairs(Tools.fxClasses) do Tools.fxCheck[cls] = true end
function ToolsModule.HideEffect(d)
    -- (runs for every new instance in workspace: parts, enemies... - leave at once unless the
    -- class is one we hide)
    if not Tools.fxCheck[d.ClassName] then return end
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
-- Home: "Play" (left) - the switches used every game; Auto join is on Lobby, Fool's Hunt on Event.
UIRef.play = UIRef.tabs.home:Section({ Side = "Left" })
UIRef.play:Header({ Text = "Play" })
-- Settings sections are made here (in screen order) so the blocks below can fill them:
-- set-once options and troubleshooting live there, not on Home.
UIRef.set = {}
for _, s in ipairs({ { "general", "Left", "General" }, { "webhook", "Left", "Discord" }, { "profile", "Left", "Profiles" },
    { "perf", "Right", "Performance" }, { "tools", "Right", "Tools" }, { "advanced", "Right", "Advanced" } }) do
    UIRef.set[s[1]] = UIRef.tabs.settings:Section({ Side = s[2] })
    UIRef.set[s[1]]:Header({ Text = s[3] })
end
UIRef.more = UIRef.set.advanced
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
    Placeholder = "auto",
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
    Placeholder = "paste",
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
-- the Home Mode shown for the saved preset ("Fast farm" from old saves = Fast; Custom: by placeMode)
AutoPlaceModule.MODE_HINT = { Safe = "Safe - stays near the base",
    Balanced = "Balanced - moves forward when the team is clearly stronger (recommended)",
    Fast = "Fast - forward from the start, skips waves" }
function AutoPlaceModule.ModeName()
    local p = AutoPlace.preset
    if p == "Safe" or p == "Balanced" or p == "Fast" then return p end
    if p == "Fast farm" then return "Fast" end
    return AutoPlace.placeMode == "Safe" and "Safe" or AutoPlace.placeMode == "Fast clear" and "Fast" or "Balanced"
end
function AutoPlaceModule.HomeAuto(on)
    local mode = AutoPlaceModule.ModeName()
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
Controls.homeMode = home:Dropdown({
    Name = "Mode",
    Multi = false,
    Required = true,
    Options = { "Safe", "Balanced", "Fast" },
    Default = AutoPlaceModule.ModeName(),
    Callback = function(v)
        if syncing or not configReady or type(v) ~= "string" or v == AutoPlace.preset then return end
        AutoPlaceModule.ApplyPreset(v)
    end,
}, "HomeMode")
UIRef.modeHint = home:Paragraph({ Header = "Hint", Body = AutoPlaceModule.MODE_HINT[AutoPlaceModule.ModeName()] })
-- the Mode dropdown and its hint show the saved preset (no preset is applied)
function AutoPlaceModule.ShowMode()
    local name = AutoPlaceModule.ModeName()
    local was = syncing
    syncing = true
    pcall(function() Controls.homeMode:UpdateSelection(name) end)
    syncing = was
    pcall(function() UIRef.modeHint:UpdateBody(AutoPlaceModule.MODE_HINT[name]) end)
end
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
    -- (not in Fool's Hunt: the bar changes every 10 s and rebuilding the list each time made it
    -- flicker and drop what was being picked - a friend's test 2026-10-24)
    if not Controls.dontPlace or State.eventMode then return end
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
function AutoPlaceModule.HomeLine(text)
    local parts = { AutoPlace.enabled and AutoPlaceModule.ModeName() or "AUTO off" }
    local where = AutoPlaceModule.StageLine and AutoPlaceModule.StageLine() or tostring(State.stage or "Lobby")
    table.insert(parts, where)
    if where == "Lobby" then
        if Lobby.statusText then table.insert(parts, Lobby.statusText) end
    else
        local units = #ownedUnits()
        if units > 0 then table.insert(parts, units .. " units") end
        local first = (text or (AutoPlaceModule.StatusText and select(2, pcall(AutoPlaceModule.StatusText))) or ""):match("Status: ([^\n]*)")
        table.insert(parts, first or AutoPlaceModule.status or "Off")
        local card = State.eventMode and Lobby.cardsTaken and Lobby.cardsTaken[#Lobby.cardsTaken]
        if card then table.insert(parts, "Card: " .. tostring(card[2])) end
    end
    if DungeonRun.enabled and DungeonRun.status then table.insert(parts, "Dungeon: " .. tostring(DungeonRun.status)) end
    return table.concat(parts, " · ")
end
-- (text: the StatusText already built this tick, so it is not built twice)
local lastHome
AutoPlaceModule.refreshHome = function(text)
    local line = AutoPlaceModule.HomeLine(text)
    if line == lastHome then return end
    lastHome = line
    pcall(function() UIRef.homeStatus:UpdateBody(line) end)
end
end

-- Auto Place: presets (Mode on Home) and Settings > Advanced (full status). Auto upgrade, damage
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
    ["Fast"] = { placeMode = "Fast clear", upgrade = true, sellFarmsLast = true, smartFreeze = true, autoStart = true, autoSkip = true },
    ["Balanced"] = { placeMode = "Balanced", upgrade = true, sellFarmsLast = true, smartFreeze = true, autoStart = true, autoSkip = true },
    ["Safe"] = { placeMode = "Safe", upgrade = true, sellFarmsLast = true, smartFreeze = true, autoStart = true, autoSkip = false },
}
PRESETS["Fast farm"] = PRESETS.Fast -- (old saves and old calls)
AutoPlaceModule.PRESETS = PRESETS
function AutoPlaceModule.ApplyPreset(name)
    if name == "Fast farm" then name = "Fast" end
    local p = PRESETS[name]
    AutoPlace.preset = name
    if p then
        AutoPlace.placeMode, AutoPlace.upgrade = p.placeMode, p.upgrade
        AutoPlace.sellFarmsLast, AutoPlace.smartFreeze = p.sellFarmsLast, p.smartFreeze
        AutoFarm.autoStart, AutoFarm.autoSkip = p.autoStart, p.autoSkip
        for _, cv in ipairs({ { Controls.autoStart, p.autoStart }, { Controls.autoSkip, p.autoSkip } }) do
            if cv[1] then pcall(function() setToggle(cv[1], cv[2]) end) end
        end
        pcall(AutoPlaceModule.ShowMode)
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
local lastPlacing
AutoPlaceModule.refreshUI = function(text)
    text = text or AutoPlaceModule.StatusText()
    if text == lastPlacing then return end
    lastPlacing = text
    pcall(function() placeStatus:UpdateBody(text) end)
end
end

-- Settings > Advanced: buff troubleshooting (buff rotation and unit skills have no switch of their
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
    pcall(function() learnedParagraph:UpdateBody(#kinds > 0 and table.concat(kinds, ", ") or "none (default skill call)") end)
end
UnitAIModule.refreshLearnedUI()
section:Button({ Name = "Forget learned buffs", Callback = UnitAIModule.ForgetLearned })
section:Button({ Name = "Copy buff report", Callback = UnitAIModule.BuffReport })
end


-- The event rooms the game runs now (GameplaySettings.ACTIVE_DUNGEONS: lobby room -> level id),
-- named for the Stage list so the owner sees where Auto join goes (2026-10-25: two event rooms,
-- Cursed Womb needs a key, Fool's Hunt does not - joining "any" could pick the wrong one).
Lobby.EVENT_NAMES = { april2_event = "Fool's Hunt", jjk_finger = "Cursed Womb" }
function Lobby.EventList()
    local out = {}
    pcall(function()
        local gs = require(ReplicatedStorage.src.Data.GameplaySettings)
        for room, id in pairs(type(gs) == "table" and gs.ACTIVE_DUNGEONS or {}) do
            local name = Lobby.EVENT_NAMES[tostring(id)] or tostring(id)
            table.insert(out, { room = tostring(room), id = tostring(id), name = name })
        end
    end)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Stage lists for Auto join from the game's own Worlds data: Story / Infinite (worlds with
-- levels), Legend (legend_stage), Raid (raid_world); the Infinity Mansion has no world.
function Lobby.Worlds(mode)
    local out, seen, rank = {}, {}, {}
    if mode == "Infinity Mansion" then return { "Infinity Mansion" } end
    if mode == "Challenges" then return { "Daily, then normal", "Daily", "Normal" } end
    if mode == "Event" then
        local out = { "Any event" }
        for _, e in ipairs(Lobby.EventList()) do table.insert(out, e.name) end
        return out
    end
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

-- Every lobby room with the texts shown on it (billboards / surface labels), once per lobby visit,
-- to AAMacro/lobby_rooms.txt - to tell Challenge, Daily Challenge and Raid rooms apart (all are
-- number-only names: _lobbytemplate316 = Challenge, 320 = Daily, watched 2026-10-25).
function Lobby.SaveRoomTexts()
    if not hasFileApi() then return end
    local lines = { "# lobby rooms " .. os.date("%Y-%m-%d %H:%M:%S") }
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Model") and d.Name:find("^_lobbytemplate") then
            local texts, seen = {}, {}
            for _, t in ipairs(d:GetDescendants()) do
                if (t:IsA("TextLabel") or t:IsA("TextButton")) and t.Text ~= "" then
                    local x = tostring(t.Text):gsub("<[^>]->", ""):gsub("%s+", " ")
                    if not seen[x] and #texts < 12 then seen[x] = true table.insert(texts, x) end
                end
            end
            local ok, cf = pcall(function() return d:GetPivot().Position end)
            table.insert(lines, string.format("%s | %s | %s", d.Name, ok and string.format("%.0f,%.0f", cf.X, cf.Z) or "?", table.concat(texts, " / ")))
        end
    end
    pcall(writefile, "AAMacro/lobby_rooms.txt", table.concat(lines, "\n"))
end

-- Challenges (watched 2026-10-25): walk-in rooms with the level already set - request_join_lobby(room)
-- then request_start_game(room). Normal = _lobbytemplate316, Daily = _lobbytemplate320 (from Watch;
-- AAMacro/lobby_rooms.txt lists each room's texts to confirm). Daily is played once a day: after a
-- daily game the date is kept and "Daily, then normal" goes on with the normal room.
Lobby.CHALLENGE_ROOMS = { Normal = "_lobbytemplate316", Daily = "_lobbytemplate320" }
function Lobby.JoinChallenge()
    local c = Lobby.cfg
    local want = c.world == "Daily" and "Daily" or c.world == "Normal" and "Normal"
        or (c.dailyDoneOn == os.date("%Y-%m-%d") and "Normal" or "Daily")
    local room = Lobby.CHALLENGE_ROOMS[want]
    local join, start = getAARemote("request_join_lobby"), getAARemote("request_start_game")
    if not (join and start) then Lobby.Status("Auto join: the game's join calls were not found") return false end
    local ok, reply = pcall(function() return join:InvokeServer(room) end)
    if not ok or reply == false then Lobby.Status("Auto join: " .. want .. " challenge room refused") return false end
    task.wait(1)
    pcall(function() start:InvokeServer(room) end)
    Lobby.Status("Auto join: " .. want .. " challenge (" .. room .. ")")
    return true
end

function Lobby.Status(text)
    Lobby.statusText = text
    if AutoPlaceModule.refreshHome then pcall(AutoPlaceModule.refreshHome) end
end

-- Auto join, as watched in the game: walk into a room, lock the level (room, level id,
-- friends only, difficulty), start. A room that refuses is skipped for the next one.
function Lobby.Join()
    local c = Lobby.cfg
    if c.mode == "Challenges" then return Lobby.JoinChallenge() end
    if c.mode == "Event" then
        -- watched: walking into an event room is all it takes, the room starts by itself. The
        -- join call alone (made from across the lobby) did not start it in the real game, so
        -- the character is moved onto the room's floor, like walking in; the call follows.
        local join = getAARemote("request_join_lobby")
        -- (only the chosen event's room when one is picked in Stage)
        local only
        for _, e in ipairs(Lobby.EventList()) do if e.name == c.world then only = e.room end end
        local rooms = only and { only } or Lobby.Rooms("event")
        for _, room in ipairs(rooms) do
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
-- Map survey (owner 2026-10-25): every Story and Raid world once, act 1 - join, leave 6 s after
-- wave 1 (the placement dump with the map lanes is written at wave 1), then the next world.
-- Worlds done are kept in surveyDone; it turns itself off when none is left.
function Lobby.SurveyStep(inLobbyNow)
    local c = Lobby.cfg
    if not c.survey then return end
    if inLobbyNow then
        Lobby.surveyAt = nil
        if os.clock() - (Lobby.surveyTry or -1e9) < 30 then return end
        for _, mode in ipairs({ "Story", "Raid" }) do
            for _, w in ipairs(Lobby.Worlds(mode)) do
                local key = mode .. ":" .. w
                if not c.surveyDone[key] then
                    c.surveyDone[key] = true
                    c.mode, c.world, c.act = mode, w, "1"
                    saveConfig()
                    Lobby.surveyTry = os.clock()
                    Lobby.Status("Map survey: " .. key)
                    pcall(Lobby.Join)
                    return
                end
            end
        end
        -- (the last join teleports late: switching off at once left the last map unleft - 20:42)
        if os.clock() - (Lobby.surveyTry or -1e9) < 120 then return end
        c.survey = false
        saveConfig()
        Lobby.Status("Map survey: every world done")
        return
    end
    if AutoPlaceModule.WaveNumber() < 1 then return end
    Lobby.surveyAt = Lobby.surveyAt or os.clock()
    if os.clock() - Lobby.surveyAt < 6 then return end
    Lobby.surveyAt = os.clock() + 30 -- then one try every 36 s
    local remote = getAARemote("teleport_back_to_lobby")
    if remote then
        pcall(function() if remote:IsA("RemoteFunction") then remote:InvokeServer() else remote:FireServer() end end)
    else
        pcall(function() game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer) end)
    end
end

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
-- Game data sharing (owner 2026-10-24, the hub is used by friends): one message per Fool's Hunt
-- game to the owner's data channel - map, wave, win, cards, and each unit's id / upgrade / trait /
-- golden / wave placed. No name, UserId or account data: a random id per device tells players
-- apart. On by default, told once on the first run, off with the Event tab toggle. The webhook
-- address is read from share_url.txt in the script's GitHub repo (the owner keeps it there).
Lobby.SHARE_URL_FILE = "https://raw.githubusercontent.com/moseeri01/blueheater2/main/share_url.txt"
-- Auto-update (owner 2026-10-25): Replay keeps the same server, so a fix only reached players who
-- went back to the lobby. At each result screen the hosted script is fetched; when its VERSION
-- differs it is run, and running it closes this copy (__MacroLabShutdown). VERSION is stamped at push.
Lobby.VERSION = "20261026-022708"
-- (two channels since 2026-10-25: "test" = moseerihub_dev.lua, the owner's device tries changes first;
-- "stable" = moseerihub.lua for friends, promoted once the test games look fine. Stamped at push.)
Lobby.CHANNEL = "test"
Lobby.SCRIPT_URL = Lobby.CHANNEL == "test" and "https://raw.githubusercontent.com/moseeri01/blueheater2/main/moseerihub_dev.lua"
    or "https://raw.githubusercontent.com/moseeri01/blueheater2/main/moseerihub.lua"
function Lobby.AutoUpdate()
    if not Lobby.cfg.autoUpdate or Lobby.VERSION == "dev" or Lobby.updating then return end
    local ok, src = pcall(function() return game:HttpGet(Lobby.SCRIPT_URL .. "?t=" .. tostring(os.time())) end)
    if not (ok and type(src) == "string" and #src > 100000) then return end
    local remote = src:match("Lobby%.VERSION = \"([^\"]+)\"")
    if not remote or remote == Lobby.VERSION or remote == "dev" then return end
    local fn = loadstring(src)
    if type(fn) ~= "function" then return end
    Lobby.updating = true
    pcall(Lobby.ShareLog, "auto-update " .. Lobby.VERSION .. " -> " .. remote)
    notify("moseeri hub: updating to " .. remote)
    task.spawn(fn)
end
function Lobby.ShareId()
    if Lobby.shareId then return Lobby.shareId end
    local path = "AAMacro/share_id.txt"
    local id = hasFileApi() and isfile(path) and readfile(path) or ""
    if #id < 8 then
        local t = {}
        for i = 1, 12 do
            local k = math.random(36)
            t[i] = string.sub("abcdefghijklmnopqrstuvwxyz0123456789", k, k)
        end
        id = table.concat(t)
        if hasFileApi() then pcall(writefile, path, id) end
    end
    Lobby.shareId = id
    return id
end
function Lobby.ShareNotice()
    if not Lobby.cfg.shareData or Lobby.cfg.shareNoticed then return end
    Lobby.cfg.shareNoticed = true
    pcall(saveConfig)
    notify("moseeri hub sends Fool's Hunt results (map, wave, units, cards - no account info) to help Auto Place. Turn off: Event tab > Share game data.")
end
-- (each try is noted in AAMacro/share_log.txt, so a send that never arrived can be traced)
function Lobby.ShareLog(text)
    if not hasFileApi() then return end
    local path = "AAMacro/share_log.txt"
    local old = isfile(path) and readfile(path) or ""
    writefile(path, old:sub(-4000) .. os.date("%H:%M:%S ") .. text .. "\n")
end
-- One row per unit on the map: id, upgrade, trait, golden, wave placed, and cov = how much of the
-- recorded enemy road lies inside its range (0-100) - to judge placement from the shared data.
function Lobby.UnitRows()
    local pts = AutoPlaceModule.PathPoints and AutoPlaceModule.PathPoints() or {}
    local rows = {}
    for _, u in ipairs(ownedUnits()) do
        local st = u:FindFirstChild("_stats")
        local trait = ""
        for _, c in ipairs(st and st:GetChildren() or {}) do
            local n = c.Name:lower()
            if c:IsA("StringValue") and n:find("trait", 1, true) and not n:find("stat", 1, true) and c.Value ~= "" then trait = c.Value break end
        end
        local cov = -1
        local range = AutoPlaceModule.StatNum(u, "range")
        local p = AutoPlaceModule.RootPos(u)
        if range and p and #pts >= 8 then
            local inside = 0
            for _, q in ipairs(pts) do
                if (q[1] - p.X) ^ 2 + (q[3] - p.Z) ^ 2 <= range * range then inside = inside + 1 end
            end
            cov = math.floor(100 * inside / #pts + 0.5)
        end
        -- (7th: cov / best for its range on this map, 0-100 - Auto Place v2)
        local okB, covBest = pcall(AutoPlaceModule.V2.CovBest, u)
        -- (summoners: 8th / 9th = road distance and road position 0-100 instead of cov / best)
        local okS, sd, sp = pcall(AutoPlaceModule.V2.RoadRow, u)
        if okS and sd then covBest = -1 else sd, sp = nil, nil end
        table.insert(rows, { unitType(u) or "?", AutoPlaceModule.StatNum(u, "upgrade") or 0, trait,
            AutoPlaceModule.IsShiny(u) and 1 or 0, (Lobby.placedAt or {})[u] or -1, cov, (not State.eventMode and okB) and covBest or -1, sd, sp })
    end
    return rows
end

function Lobby.ShareGame(win, wave)
    Lobby.ShareLog(string.format("game end: share %s, event %s, wave %s", tostring(Lobby.cfg.shareData), tostring(State.eventMode), tostring(wave)))
    -- (every mode since 2026-10-25, owner: story, raids, dungeon too - "mode" tells them apart)
    if not Lobby.cfg.shareData then return end
    if not Lobby.shareUrl then
        local ok, url = pcall(function() return game:HttpGet(Lobby.SHARE_URL_FILE) end)
        -- (kept only when found: a failed fetch is tried again next game)
        Lobby.shareUrl = ok and type(url) == "string" and url:match("https://[%w%./_%-]+") or nil
    end
    if not Lobby.shareUrl then Lobby.ShareLog("no share_url.txt address") return end
    -- (the map may already be cleared at the result screen in normal stages: the rows kept during
    -- the game stand in - Dungeon / story shares came with no units, 2026-10-25)
    local units = Lobby.UnitRows()
    if #units == 0 then units = Lobby.lastUnitRows or {} end
    -- (pl = players in the room: a duo game is much easier than solo, so stats compare like with like)
    local data = { v = 1, mode = State.eventMode and "event" or "other", ver = Lobby.VERSION, ch = Lobby.CHANNEL, pl = #game:GetService("Players"):GetPlayers(), id = Lobby.ShareId(), t = os.time(), map = tostring(State.stage), w = wave, win = win and 1 or 0,
        candy = Lobby.candy or 0, cards = Lobby.cardsTaken or {}, u = units,
        -- (normal stages: BAD_SPOT count and whether the learned road reached our base)
        bad = not State.eventMode and (AutoPlaceModule.badCount or 0) or nil,
        -- (Fool's Hunt rows: 1 = placed by the v2 spot rules, to compare win / wave old vs new)
        v2e = State.eventMode and (AutoPlaceModule.V2.EventOn() and 1 or 0) or nil,
        -- (last-wave boss chase used / the boss reached our base on the last wave)
        chase = (AutoPlaceModule.chase or {}).used and 1 or 0,
        bossBase = (AutoPlaceModule.chase or {}).lastProg ~= nil and ((AutoPlaceModule.chase or {}).reached and 1 or 0) or nil,
        -- (v2: road length, buff coverage % of the team's damage)
        rl = not State.eventMode and AutoPlaceModule.V2.lastLen or nil,
        u4 = not State.eventMode and AutoPlaceModule.V2.u4 or nil,
        bs = (function()
            if State.eventMode then return nil end
            local ok, v = pcall(AutoPlaceModule.V2.BuffShare)
            return ok and v or nil
        end)(),
        -- (dungeon games: stuck screens since the last shared dungeon game, the last one by name)
        stuck = DungeonRun.InRoom() and (DungeonRun.stuckTotal or 0) or nil,
        stuckAt = DungeonRun.InRoom() and DungeonRun.lastStuck or nil,
        pathOk = (function()
            if State.eventMode or not AutoPlaceModule.Reaches then return nil end
            return AutoPlaceModule.Reaches(AutoPlaceModule.PathPoints()) == true
        end)() }
    local body = HttpService:JSONEncode(data)
    -- (a Discord message holds 2000 characters: the last-placed units go first when it is long)
    while #body > 1900 and #units > 0 do
        table.remove(units)
        body = HttpService:JSONEncode(data)
    end
    local sent, why = Webhook.post(Lobby.shareUrl, HttpService:JSONEncode({ username = "moseeri data", content = "AASTAT " .. body }))
    if sent and data.stuck then DungeonRun.stuckTotal, DungeonRun.lastStuck = 0, nil saveConfig() end
    AutoPlaceModule.Note("game data " .. (sent and "shared" or ("NOT shared - " .. tostring(why))))
    Lobby.ShareLog("sent " .. tostring(sent) .. " " .. tostring(why) .. " (" .. #body .. " chars)")
end

-- Full skill / passive texts of the roster from the game's own data (owner 2026-10-25), written once a
-- version to AAMacro/unit_skills_full.txt: every text field of the unit and of the attacks it names
-- (primary / active), rich-text tags removed, nothing cut.
function Lobby.SaveSkills()
    if not hasFileApi() then return end
    local path = "AAMacro/unit_skills_full.txt"
    local stamp = "# version " .. tostring(Lobby.VERSION)
    if isfile(path) and readfile(path):sub(1, #stamp) == stamp then return end
    local attacks = {}
    pcall(function()
        local data = ReplicatedStorage.src.Data
        local ok, mod = pcall(require, data:FindFirstChild("Attacks"))
        if ok and type(mod) == "table" then attacks = mod end
    end)
    local names, seen = {}, {}
    for _, list in ipairs({ AutoPlaceModule.ROSTER or {}, Lobby.cfg.eventAlways or {}, Lobby.cfg.eventNever or {} }) do
        for _, n in ipairs(list) do if not seen[n] then seen[n] = true table.insert(names, n) end end
    end
    table.sort(names)
    local out = { stamp }
    local WANT = { "desc", "name", "passive", "abilit", "active", "text", "effect", "skill", "stun", "slow", "burn", "bleed", "summon", "buff", "aoe", "shield", "crit", "execute", "percent" }
    local function clean(v) return (tostring(v):gsub("<[^>]->", ""):gsub("%s+", " ")) end
    local function walk(t, prefix, depth, seenT)
        if depth > 5 or seenT[t] then return end
        seenT[t] = true
        local keys = {}
        for k in pairs(t) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local v, p = t[k], prefix .. "." .. tostring(k)
            local lk = p:lower()
            if type(v) == "table" then walk(v, p, depth + 1, seenT)
            elseif type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
                for _, w in ipairs(WANT) do
                    if lk:find(w, 1, true) and not lk:find("anim", 1, true) and not lk:find("sfx", 1, true) then
                        table.insert(out, "  " .. p:sub(2) .. " = " .. clean(v))
                        break
                    end
                end
            end
        end
    end
    for _, n in ipairs(names) do
        local def = AutoPlaceModule.UnitDef(n)
        table.insert(out, "")
        table.insert(out, "== " .. n .. (def and (" | " .. clean(def.name or "")) or " | (no data)"))
        if def then
            pcall(walk, def, "", 1, {})
            for _, key in ipairs({ "primary_attack", "primary_attack_no_upgrades", "active_attack" }) do
                local a = def[key]
                if type(a) == "string" and type(attacks[a]) == "table" then
                    table.insert(out, "  [" .. key .. " " .. a .. "]")
                    pcall(walk, attacks[a], "", 1, {})
                end
            end
        end
    end
    writefile(path, table.concat(out, "\n"))
end

function Lobby.RecordWaves()
    Lobby.placedAt = Lobby.placedAt or setmetatable({}, { __mode = "k" })
    for _, u in ipairs(ownedUnits()) do Lobby.placedAt[u] = Lobby.placedAt[u] or AutoPlaceModule.WaveNumber() end
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
    -- (written only when something new came, at most every 20 s: the whole file every 5 s was a
    -- steady stutter on a phone once it grew)
    if #Lobby.waveLog ~= Lobby.waveSaved and os.clock() - (Lobby.waveSavedAt or -1e9) > 20 then
        Lobby.waveSaved, Lobby.waveSavedAt = #Lobby.waveLog, os.clock()
        AutoPlaceModule.Catalog.save("event_waves_" .. tostring(math.floor(AutoPlaceModule.loadUnix or 0)) .. ".txt", table.concat(Lobby.waveLog, "\n"))
    end
end

-- "You Died!" (all lives lost): one step at a time, each waiting 8 s for the game's answer
-- (a dungeon_changed, 10 s each): 1 tap Continue (what the owner does by hand - answered at once at 11:43),
-- 2 open a gold chest left, 3 open a chest left (the server may want them first), 4 one direct
-- dungeon_continue_death(), 5 in a room: back to the lobby. Never two sends at once, nothing
-- repeated (18:05-18:16 2026-10-25: taps every 5 s and three calls in one second, none answered).
-- "(Click anywhere to continue)" reward popups - every mode (dungeon money, stage / raid / event / lobby
-- rewards, owner 2026-10-25): no button, a tap on the popup dismisses one item. Up to 6 items per call,
-- 2 s apart; each item's text logged once. Never while a room choice is open (it needs a real choice).
Lobby.CLICK_WORDS = { "click anywhere", "tap anywhere" }
function Lobby.ClickLabel()
    return (Scan.Cached("clickAnywhere", Lobby.FindClickLabel))
end
function Lobby.FindClickLabel()
    local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d:IsA("TextLabel") then
            local t = string.lower(tostring(d.Text))
            for _, w in ipairs(Lobby.CLICK_WORDS) do
                if t:find(w, 1, true) and isOnScreen(d) and not isOwnGui(d) then return d end
            end
        end
    end
end
function Lobby.ClickAnywhere()
    for _ = 1, 6 do
        local label = Lobby.ClickLabel()
        if not label or DungeonRun.ChoiceOpen() then return end
        -- the popup: a button around the label, else its top frame under the ScreenGui
        local node, target = label, nil
        while node.Parent and not node.Parent:IsA("LayerCollector") do
            if node:IsA("GuiButton") then target = node break end
            node = node.Parent
        end
        target = target or node
        local parts = {}
        for _, d in ipairs(target:GetDescendants()) do
            if d:IsA("TextLabel") and d ~= label and isOnScreen(d) and tostring(d.Text) ~= "" then table.insert(parts, clip(tostring(d.Text), 40)) end
        end
        local item = table.concat(parts, " / ")
        if item ~= Lobby.lastClickItem then
            Lobby.lastClickItem = item
            pcall(Lobby.ShareLog, "reward popup: " .. clip(item, 120) .. " - tapped to continue")
        end
        Lobby.TapGui(target)
        task.wait(2)
    end
end

function Lobby.DiedStep(inLobbyNow)
    if not Lobby.ButtonFor("You Died!") then Lobby.died = nil return end
    if DungeonRun.enabled and not DungeonRun.pendingStart then
        DungeonRun.pendingStart = true
        saveConfig()
    end
    local d = Lobby.died
    if not d then d = { step = 0, at = -1e9 } Lobby.died = d end
    local function log(text)
        pcall(Lobby.ShareLog, "dungeon: You Died! " .. text)
        pcall(DungeonRun.Log, "You Died! " .. text)
    end
    if d.step > 0 and (DungeonRun.liveSeq or 0) ~= d.seq then
        if not d.answered then d.answered = true log("answered after step " .. d.step) end
        return
    end
    if d.step >= 5 or os.clock() - d.at < 10 then return end
    if d.step > 0 then log("no answer to step " .. d.step .. " in 10 s") end
    d.step, d.at, d.seq = d.step + 1, os.clock(), DungeonRun.liveSeq or 0
    local res = type(DungeonRun.live) == "table" and type(DungeonRun.live._resources) == "table" and DungeonRun.live._resources or {}
    local function call(name, arg, have)
        if have ~= nil and have <= 0 then d.at = -1e9 log("step " .. d.step .. ": " .. name .. " skipped (none left)") return end
        local r = getAARemote(name)
        if not r then d.at = -1e9 log("step " .. d.step .. ": " .. name .. " not found") return end
        local ok, answer = pcall(function()
            if arg == nil then return r:InvokeServer() end
            return r:InvokeServer(arg)
        end)
        log(string.format("step %d: %s(%s) answered %s", d.step, name, arg == nil and "" or tostring(arg), clip(tostring(ok and answer or "error"), 40)))
        -- (a call that errors gets no answer later either: the next step at once - 22:55 2026-10-25)
        if not ok then d.at = -1e9 end
    end
    if d.step == 1 then
        local b = Lobby.ButtonFor("Continue")
        if b then Lobby.TapGui(b) log("step 1: tapped Continue") else log("step 1: no Continue button") end
    elseif d.step == 2 and not inLobbyNow then
        -- (in the room the calls below only answered "error" (22:55): back to the lobby at once, the
        -- You Died! page shows again there and its Continue works)
        d.step = 5
        local back, remote = Lobby.ButtonFor("Return to lobby"), getAARemote("teleport_back_to_lobby")
        local how
        if back then
            Lobby.TapGui(back) how = "tapped Return to lobby"
        elseif remote then
            pcall(function() if remote:IsA("RemoteFunction") then remote:InvokeServer() else remote:FireServer() end end)
            how = "teleport_back_to_lobby()"
        else
            pcall(function() game:GetService("TeleportService"):Teleport(8304191830, Players.LocalPlayer) end)
            how = "teleport to the lobby"
        end
        log("in the room, no answer - " .. how)
    elseif d.step == 2 then
        call("dungeon_open_chest", true, tonumber(res.treasure_gold))
    elseif d.step == 3 then
        call("dungeon_open_chest", false, tonumber(res.treasure))
    elseif d.step == 4 then
        call("dungeon_continue_death", nil)
    else
        log("still up in the lobby - press Continue by hand")
    end
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
        if State.eventMode and not inLobbyNow then pcall(Lobby.SampleDepth) end
        pcall(DungeonRun.DumpUI)
        pcall(DungeonRun.DumpPages)
        pcall(Lobby.ClickAnywhere)
        pcall(DungeonRun.Watchdog)
        -- (Dungeon Run "You Died!" - all lives lost, the run is over: its Continue collects the rewards
        -- and leaves. Left alone it sat there until the idle kick - 2026-10-25. It shows in the lobby too)
        pcall(Lobby.DiedStep, inLobbyNow)
        pcall(Lobby.SurveyStep, inLobbyNow)
        if not inLobbyNow then
            -- (Dungeon Room result, win or defeat: "Next" goes back to the room choice / You Died!
            -- page. Left alone it sat on DEFEAT Depth 6 for 5+ minutes - 2026-10-25)
            pcall(function()
                if os.clock() - (Lobby.roomNextAt or -1e9) < 4 then return end
                if not DungeonRun.InRoom() then return end
                -- (the page after it shows "Return to lobby" / "Open Dungeon": Open Dungeon reopens the
                -- Dungeon Run window for the next room or the retry; never Return to lobby mid-run - 2026-10-25.
                -- Its text alone is enough: that page may not count as the result screen)
                local word, b = "Next", nil
                if AutoFarmModule.ResultsShowing() then b = Lobby.ButtonFor(word) end
                if not b then word = "Open Dungeon" b = Lobby.ButtonFor(word) end
                if b then
                    -- (after a lost room the game itself selects the same room again:
                    -- dungeon_selected_changed with lives - 1 at the defeat, 2026-10-25)
                    local won = AutoFarmModule.ResultIsVictory()
                    if not won and not Lobby.lossNoted then Lobby.lossNoted = true pcall(DungeonRun.NoteLoss) end
                    Lobby.roomNextAt = os.clock()
                    Lobby.TapGui(b)
                    pcall(Lobby.ShareLog, "dungeon: room result (" .. (won and "won" or "lost") .. ") - tapped " .. word)
                end
            end)
        end
        if State.eventMode and not inLobbyNow and not Lobby.skillsSaved then Lobby.skillsSaved = true task.spawn(pcall, Lobby.SaveSkills) end
        -- (wave each unit was placed, and the unit rows kept for the shared game data - every mode)
        if not inLobbyNow then
            pcall(function()
                Lobby.placedAt = Lobby.placedAt or setmetatable({}, { __mode = "k" })
                for _, u in ipairs(ownedUnits()) do Lobby.placedAt[u] = Lobby.placedAt[u] or AutoPlaceModule.WaveNumber() end
                local rows = Lobby.UnitRows()
                if #rows > 0 then Lobby.lastUnitRows = rows end
            end)
        end
        if State.watching and State.eventMode and not inLobbyNow then
            local ok, err = pcall(Lobby.RecordWaves)
            Lobby.recordError = not ok and tostring(err) or nil
        end
        if inLobbyNow and not Lobby.roomsSaved then Lobby.roomsSaved = true task.delay(10, pcall, Lobby.SaveRoomTexts) end
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
-- Every label / button text in PlayerGui, lower case without rich-text tags -> its objects. One walk
-- answers all the ButtonFor questions of a loop ("You Died!", "Next", "Open Dungeon", "Dungeon"...
-- each walked the whole PlayerGui: a 50-200 ms hitch every 5 s, lag review 2026-10-26).
local function plainText(d) return (string.lower(tostring(d.Text)):gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")) end
function Lobby.TextIndex(root)
    local index = {}
    root = root or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(root and root:GetDescendants() or {}) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local plain = plainText(d)
            if plain ~= "" then
                index[plain] = index[plain] or {}
                table.insert(index[plain], d)
            end
        end
    end
    return index
end
function Lobby.ButtonFor(text, root)
    local want = (string.lower(tostring(text)):gsub("^%s+", ""):gsub("%s+$", ""))
    local index = root and Lobby.TextIndex(root) or Scan.Cached("textIndex", Lobby.TextIndex)
    for _, d in ipairs(index[want] or {}) do
        do
            if d.Parent and plainText(d) == want and isOnScreen(d) and not isOwnGui(d) then
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

-- Share of our damage by type (physical / magic / true ...), from the placed units' data -
-- in event also the Always list: the first card comes before the mains are down (owner
-- 2026-10-24: Magic Resistance +75 taken at the start, then judar came).
function Lobby.DamageShare()
    local share, total = {}, 0
    local function add(name, dmg, cd)
        local def = AutoPlaceModule.UnitDef(name) or {}
        local kind = tostring(def._base_damage_type or "physical")
        local dps = (dmg or tonumber(def.damage) or 0) / math.max(0.5, cd or AutoPlaceModule.DefCd(def))
        share[kind] = (share[kind] or 0) + dps
        total = total + dps
    end
    -- (placed units by their damage as upgraded now: three judar at level 8 counted as three level-0
    -- ones, and Spellproof II was taken - 2026-10-25)
    for _, u in ipairs(ownedUnits()) do
        add(unitType(u), AutoPlaceModule.StatNum(u, "damage"), AutoPlaceModule.StatNum(u, "attack_cooldown"))
    end
    if State.eventMode then
        for _, n in ipairs(Lobby.cfg.eventAlways or {}) do add(n) end
    end
    if total <= 0 then return { physical = 0.5, magic = 0.5 } end
    for k, v in pairs(share) do share[k] = v / total end
    -- (event: the main carry's damage type counts as ours whatever its share - judar is magic, but
    -- magic was ~22%% of the Always list, so Spellproof +75 was taken as cheap - 2026-10-25)
    if State.eventMode then
        local main
        for _, n in ipairs(AutoPlaceModule.RANK) do
            for _, u in ipairs(ownedUnits()) do if unitType(u) == n then main = n break end end
            if main then break end
        end
        local def = AutoPlaceModule.UnitDef(main or AutoPlaceModule.RANK[1] or "")
        local kind = def and tostring(def._base_damage_type or "physical")
        if kind then share[kind] = math.max(share[kind] or 0, 0.3) end
    end
    return share
end

-- How much a card hurts us (0 = nothing): enemy health and speed directly, resistance only
-- for the damage types we deal (true damage ignores it), shields and death bombs a little.
Lobby.AVOID = 10
Lobby.RES_CAP = 75
function Lobby.CardCost(opt, share)
    local cost = 0
    for _, e in ipairs(Lobby.AsList(type(opt.effects) == "table" and opt.effects or {})) do
        local t, a = tostring(e.type), tonumber(e.amount) or 0
        -- (owner 2026-10-24: each kind of Bad card once a game - a second one goes behind the rest)
        if t ~= "candy_multiplier" and (Lobby.badTaken or {})[t .. tostring(e.damage_type or "")] then cost = cost + Lobby.AVOID end
        if t == "candy_multiplier" then
            -- (the reward, not a cost)
        -- (owner 2026-10-24: never Enemy Health, Enemy Speed or armor against the damage we deal
        -- while another card is there: AVOID puts them behind every other one)
        elseif t == "enemy_stat_mul" then cost = cost + Lobby.AVOID + a
        elseif t == "enemy_speedup" then cost = cost + Lobby.AVOID + 1.2 * a
        elseif t == "enemy_resistance_specific" then
            -- (owner 2026-10-24: a team grows into its damage type later, so each type takes at
            -- most RES_CAP in all - past it the card goes behind every other one)
            local kind = tostring(e.damage_type)
            local mine = share[kind] or 0
            local prev = (Lobby.resTaken or {})[kind] or 0
            local over = prev + a > Lobby.RES_CAP
            -- (the share of our damage it takes away: damage x100/(100+resist), on top of what was
            -- taken before - +150 on +100 cuts that type by 43%%, more than Enemy Health +50%% (33%%)
            -- cuts everyone; counted against Enemy Health = AVOID)
            local loss = mine * (1 - (100 + prev) / (100 + prev + a))
            cost = cost + Lobby.AVOID * loss / 0.33 + ((mine >= 0.3 or over) and Lobby.AVOID or 0)
        -- (regen once is fine, more of it stacks up: each one taken costs more)
        elseif t == "enemy_regen" then cost = cost + 100 * a * (1 + (Lobby.regenTaken or 0))
        elseif t == "enemy_shield" then cost = cost + 0.1 * a
        elseif t == "enemy_bomb" then cost = cost + 0.2
        -- (Random Curses: "amount" random Bad effects, often Enemy Health / Speed / our resistance -
        -- each counted at 60% of a heavy card; taken as cheap, it gave Spellproof + Enemy Health
        -- in one game - real game 2026-10-25)
        elseif t == "random_effects" then cost = cost + math.max(1, a) * 0.6 * Lobby.AVOID
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
        -- (1.3: Attack I +12%% must beat Range I +15%% - owner order damage first; shared games took
        -- Range I over and over in mid-game losses, 2026-10-25)
        elseif t == "stat_mul" and stat == "damage" then gain = gain + 1.3 * a
        elseif t == "stat_mul" and stat == "range" then gain = gain + 0.9 * a
        elseif t == "stat_mul" and stat == "attack_cooldown" then gain = gain + 0.8 * a
        else gain = gain + 0.3 * a
        end
    end
    return gain
end

-- How far the front enemy got along this map's recorded road (0 = their spawn, 1 = our base), the
-- deepest point per wave. Read by the card choice as the team's margin (owner 2026-10-25: choose
-- by how strong the team is now, not by the wave number alone).
Lobby.depthByWave = {}
function Lobby.SampleDepth()
    local pts = AutoPlaceModule.PathPoints and AutoPlaceModule.PathPoints() or {}
    if #pts < 8 then return end
    if Lobby.roadReversed == nil then
        local goal = AutoPlaceModule.BasePos and AutoPlaceModule.BasePos("player")
        if goal then
            local function d(q) return (q[1] - goal.X) ^ 2 + (q[3] - goal.Z) ^ 2 end
            Lobby.roadReversed = d(pts[1]) < d(pts[#pts])
        end
    end
    local folder = unitsFolder()
    local deepest = 0
    for _, u in ipairs(folder and folder:GetChildren() or {}) do
        if AutoPlaceModule.IsEnemy(u) then
            local p = AutoPlaceModule.RootPos(u)
            if p then
                local bi, bd = 1, math.huge
                for i = 1, #pts, 2 do
                    local q = pts[i]
                    local d = (q[1] - p.X) ^ 2 + (q[3] - p.Z) ^ 2
                    if d < bd then bi, bd = i, d end
                end
                -- (oriented by our base: the recorded road may start at either end)
                local frac = bi / #pts
                if Lobby.roadReversed then frac = 1 - frac end
                deepest = math.max(deepest, frac)
            end
        end
    end
    local w = AutoPlaceModule.WaveNumber()
    Lobby.depthByWave[w] = math.max(Lobby.depthByWave[w] or 0, deepest)
end
-- The deepest point of the last 3 waves (nil until a road is known)
function Lobby.Margin()
    local w, m = AutoPlaceModule.WaveNumber(), nil
    for i = w - 2, w do
        local d = Lobby.depthByWave[i]
        if d then m = math.max(m or 0, d) end
    end
    return m
end
-- (depth limits, from the strategy simulator 2026-10-25, 1500 games each: Bad cards taken "because the
-- team looks strong" cost waves AND coins at every threshold (strong 0.45: w17.2 / 232 coins vs w20.9 /
-- 289 with none); Good-only once enemies pass 30%% of the road: w22.6 / 303 coins vs w20.7 / 287 with the
-- wave-6 rule. So: no strong override, weak at 0.3)
Lobby.DEPTH_STRONG, Lobby.DEPTH_WEAK = 0, 0.3

-- The card to pick: "Most coins" takes the Bad card that hurts least (each adds 0.3 to the
-- coin multiplier) unless the base is losing HP or every Bad card is heavy; "Safest" takes a
-- Good card whenever there is one.
-- (3 since 2026-10-25: the simulator found Bad cards past the first offer cost waves and coins
-- (cardSafeFrom 3: w23.0 / 305 coins vs 6: w20.7 / 287), and in shared games a wave-5 Plated / Spellproof
-- came before most early losses)
Lobby.BAD_CARDS_UNTIL = 3
function Lobby.PickCard(options)
    local share = Lobby.DamageShare()
    local hp, hpMax = AutoPlaceModule.ScanBaseHp()
    local hurt = hp and hpMax and hpMax > 0 and hp / hpMax < 0.8
    local bestBad, bestBadCost, good, goodGain, yen
    for i, o in ipairs(options) do
        if type(o) == "table" then
            if o.option_type == "Good" then
                local g = Lobby.CardGain(o)
                if g and (not good or g > goodGain) then good, goodGain = i, g end
                -- (Yen only beats a heavy Bad card - Enemy Health / Speed / our resistance;
                -- real game 2026-10-24: Yen, Resistant, Speed offered and Speed was taken)
                if not g then yen = i end
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
    -- (by the margin when the road is known: strong = a light Bad card even late; weak = Good only)
    local depth = State.eventMode and Lobby.Margin()
    Lobby.lastDepth = depth
    if depth then
        if depth >= Lobby.DEPTH_WEAK then late = true
        elseif depth < Lobby.DEPTH_STRONG and not hurt then late = false end
    end
    if good and (Lobby.cfg.cardMode == "Safest" or late or hurt or not bestBad or bestBadCost > 0.8) then return good, "help" end
    if good and depth and AutoPlaceModule.WaveNumber() >= Lobby.BAD_CARDS_UNTIL and bestBadCost >= Lobby.AVOID then return good, "help" end
    if yen and bestBad and bestBadCost >= Lobby.AVOID then return yen, "yen over a heavy Bad card" end
    if yen and not good and (Lobby.cfg.cardMode == "Safest" or late or hurt) then return yen, "help" end
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

-- Every card the game offers, once per title, to AAMacro/cards_seen.txt (the list lives only on
-- the server, so this is how the owner sees all of them).
function Lobby.LogCards(options)
    if not hasFileApi() then return end
    local path = "AAMacro/cards_seen.txt"
    local text = isfile(path) and readfile(path) or ""
    local add = {}
    for _, o in ipairs(options) do
        local title = type(o) == "table" and tostring(o.title) or ""
        if title ~= "" and not text:find(title .. " |", 1, true) then
            local parts = {}
            for _, e in ipairs(Lobby.AsList(type(o.effects) == "table" and o.effects or {})) do
                local f = {}
                for k, v in pairs(e) do table.insert(f, tostring(k) .. "=" .. tostring(v)) end
                table.sort(f)
                table.insert(parts, table.concat(f, " "))
            end
            table.insert(add, string.format("%s | %s | %s", title, tostring(o.option_type), table.concat(parts, " ; ")))
            text = text .. title .. " |"
        end
    end
    if #add > 0 then writefile(path, (isfile(path) and readfile(path) or "") .. table.concat(add, "\n") .. "\n") end
end

function Lobby.OnCardOptions(seconds, options)
    options = Lobby.AsList(options)
    pcall(Lobby.LogCards, options)
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
        -- (owner 2026-10-24: the remote vote stopped counting in one game - the card is also
        -- tapped on screen after it, so either way the vote lands)
        if remote then
            -- (not waited on: a call the game does not answer must not hold up the tap)
            task.spawn(pcall, function() remote:InvokeServer(arg) end)
            way = "gui"
        end
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
        end
    end)
end

function Lobby.OnCardResult(picked, state)
    if type(state) == "table" then Lobby.candy = tonumber(state.candy_multiplier) or Lobby.candy end
    if type(picked) == "table" then
        Lobby.cardsTaken = Lobby.cardsTaken or {}
        table.insert(Lobby.cardsTaken, { AutoPlaceModule.WaveNumber(), tostring(picked.title), Lobby.lastDepth and math.floor(Lobby.lastDepth * 100) or -1 })
    end
    if type(picked) == "table" then
        for _, e in ipairs(Lobby.AsList(type(picked.effects) == "table" and picked.effects or {})) do
            if e.type == "enemy_regen" then Lobby.regenTaken = (Lobby.regenTaken or 0) + 1 end
            if e.type == "enemy_shield" then Lobby.shieldTaken = true end
            if picked.option_type == "Bad" and e.type ~= "candy_multiplier" then
                Lobby.badTaken = Lobby.badTaken or {}
                Lobby.badTaken[tostring(e.type) .. tostring(e.damage_type or "")] = true
            end
            if e.type == "enemy_resistance_specific" then
                Lobby.resTaken = Lobby.resTaken or {}
                local kind = tostring(e.damage_type)
                Lobby.resTaken[kind] = (Lobby.resTaken[kind] or 0) + (tonumber(e.amount) or 0)
            end
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
-- (owner 2026-10-24: Ritual is not used - its 10000 goes into upgrades)
Lobby.DROP_SPELLS = { ritual = true }

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
    -- (owner: Astral Summon only with money to spare - 5000 kept for the main units' upgrades)
    summon = { cost = 10000, reserve = 5000 }, gate = { cost = 2500 },
    sacrifice = { cost = 1000, target = "merge", dropIfNone = true }, sell_refund = { cost = 0, target = "weakest" },
}
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
        local model = world and world:FindFirstChildOfClass("Model")
        -- (never a main unit's copy: it waits for a place to be made for it)
        local main = false
        for _, n in ipairs(AutoPlaceModule.RANK) do
            if model and AutoPlaceModule.BaseId(n) == AutoPlaceModule.BaseId(model.Name) and not AutoPlaceModule.UP_CAP[n] then main = true end
        end
        if model and x and not main then
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
        return dmg / math.max(0.5, cd) * (AutoPlaceModule.IsAoe(unitType(u)) and AutoPlaceModule.AOE_VALUE or 1), (tonumber(def.damage) or 0) > 0
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
        -- (owner: from the middle of the game the early units are sold too, their money goes into
        -- the main units)
        local nearLimit = #units >= math.min(AutoPlaceModule.EVENT_CAP, AutoPlaceModule.capSeen or 99) - 2
            or (AutoPlaceModule.WaveNumber() >= 12 and #units >= 15)
        local bar = nearLimit and math.huge or all[math.floor(#all / 2) + 1] * 0.5
        for _, u in ipairs(units) do
            local _, hits = dpsNow(u)
            local full = AutoPlaceModule.MaxDps(unitType(u) or "")
            local main = AutoPlaceModule.InList(AutoPlaceModule.RANK, unitType(u)) and not AutoPlaceModule.UP_CAP[unitType(u) or ""]
            if hits and full and full < bar and not main and not bad[u] and not AutoPlaceModule.AirCapable(unitType(u) or "", math.huge) and (not best or full < best) then
                target, best = u, full
            end
        end
    else
        for _, u in ipairs(units) do
            if unitType(u) then
                -- damage per second as the unit stands now (its own _stats: level, upgrades, trait,
                -- earlier buffs), area attacks counted higher; Clone takes the most upgraded one
                local dps, hits = dpsNow(u)
                -- (Ritual never takes a main unit: it sacrificed judar - owner 2026-10-24)
                local mainU = AutoPlaceModule.InList(AutoPlaceModule.RANK, unitType(u)) and not AutoPlaceModule.UP_CAP[unitType(u) or ""]
                -- (no buff or clone on a place-only unit - jiraiya got a Random Buff)
                local placeOnly = AutoPlaceModule.UP_CAP[unitType(u) or ""] ~= nil
                local ok = hits and not bad[u] and not placeOnly and (spec.target ~= "maxed" or Lobby.FullyUpgraded(u)) and not (spec.notMain and mainU)
                -- (owner: Random Buff goes on the main units first, in the list's order)
                local rank = 0
                for i, n in ipairs(AutoPlaceModule.RANK) do if n == unitType(u) then rank = #AutoPlaceModule.RANK - i + 1 end end
                local score = rank * 1e9 + dps
                if ok and (not best or score > best) then target, best = u, score end
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
        if id == "ritual" and grown and AutoPlaceModule.WaveNumber() >= 18 and money < 10000 and tried < 5 then return "Saving for Ritual" end
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
        -- (owner: every Random Buff on the same one main unit, stacked - the first one's pick)
        if id == "random_buff" then
            local keep = Lobby.buffMain
            -- (a sold or dead unit moves to _DEAD_UNITS: only one still in _UNITS counts)
            -- (owner: the buffs move to a higher main when one comes - judar, then cid ...)
            local function rankOf(x)
                for i, n in ipairs(AutoPlaceModule.RANK) do if n == unitType(x) then return i end end
                return 99
            end
            if target and keep and rankOf(target) < rankOf(keep) then keep = nil end
            if keep and keep.Parent and keep.Parent.Name == "_UNITS" and not (Lobby.spellBad or {})[keep] then target = keep else Lobby.buffMain = target end
        end
        local slot = spec and Lobby.SpellSlot(id)
        if spec and spec.dropIfNone and not target and slot and slot:FindFirstChild("Delete", true) then
            -- (Merge with no two of a kind in range: its bar slot is worth more to a new roll)
            Lobby.spellAt = os.clock()
            Lobby.TapGui(slot:FindFirstChild("Delete", true))
            AutoPlaceModule.Note("spell dropped: " .. id .. " (nothing to use it on)")
            return
        end
        -- (a thin team spends it all: real game 2026-10-24, waves 1-4 with no unit and 11k unused
        -- while Astral Summon waited for its reserve)
        local reserve = AutoPlaceModule.DamageCount(ownedUnits()) < 6 and 0 or (spec and spec.reserve or 0)
        if spec and slot and (target or not spec.target) and money >= spec.cost + reserve
            and AutoPlaceModule.WaveNumber() >= (spec.fromWave or 0) then
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
    -- (owner: one Clone in hand is enough - a second one is cleared at once)
    local seen = {}
    for _, id in ipairs(held) do
        seen[id] = (seen[id] or 0) + 1
        if Lobby.SPELL_MAX[id] and seen[id] > Lobby.SPELL_MAX[id] then
            local slot = Lobby.SpellSlot(id)
            local x = slot and slot:FindFirstChild("Delete", true)
            if x then
                Lobby.spellAt = os.clock()
                Lobby.TapGui(x)
                AutoPlaceModule.Note("spell dropped: " .. id .. " (one is enough)")
                return true
            end
        end
    end
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
Lobby.SPELL_MAX = { clone = 1 }
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
        -- (no time limit: a slow map load passed the old 5 s wait and left cards and spells unheard
        -- all game - real game 2026-10-24, Cursed Festival)
        local conn = ReplicatedStorage:WaitForChild("endpoints"):WaitForChild("server_to_client"):WaitForChild(name).OnClientEvent:Connect(fn)
        table.insert(State.connections, conn)
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
    if not hasUniques(data) then data = Lobby.GcFind("uniques", hasUniques) or data end
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
                    or n:find("spell", 1, true) or n:find("vote", 1, true) or n:find("unit_spawned", 1, true)
                    or n:find("dungeon", 1, true)) then
                    table.insert(Lobby.watchConns, r.OnClientEvent:Connect(function(...)
                        local args = table.pack(...)
                        local parts = {}
                        for i = 1, args.n do parts[i] = describeValue(args[i], 0, FULL) end
                        -- (dungeon state is nested deep - rooms of the next depths: kept whole as JSON)
                        if n:find("dungeon", 1, true) then
                            for i = 1, args.n do
                                local ok, j = pcall(function() return HttpService:JSONEncode(args[i]) end)
                                if ok and type(j) == "string" then parts[i] = j end
                            end
                        end
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

-- (the lobby's status goes to the Home status line: Lobby.Status)
local join = UIRef.tabs.lobby:Section({ Side = "Left" })
join:Header({ Text = "Auto join" })
join:Toggle({ Name = "Auto join", Default = Lobby.cfg.autoJoin, Callback = set("autoJoin") }, "LobbyAutoJoin")
join:Toggle({ Name = "Map survey (every map to wave 1)", Default = Lobby.cfg.survey, Callback = function(v)
    if syncing then return end
    Lobby.cfg.survey = v
    if v then Lobby.cfg.surveyDone = {} end
    saveConfig()
end }, "LobbySurvey")
-- (owner 2026-10-25: hard to see what is picked) one line says what Auto join starts; Event
-- uses only the event picker, Infinity Mansion only Difficulty - the unused fields are hidden
-- when this MacLib has SetVisibility, and the line leaves them out either way
local worldDropdown, actDropdown, diffDropdown
local joinLine = join:Paragraph({ Header = "Joins", Body = "" })
local function joinRefresh()
    local c = Lobby.cfg
    local m = tostring(c.mode)
    local usesStage = m ~= "Infinity Mansion"
    local usesAct = m ~= "Event" and m ~= "Infinity Mansion" and m ~= "Challenges"
    local usesDiff = m ~= "Event" and m ~= "Challenges"
    local parts = { m }
    if usesStage then table.insert(parts, c.world ~= "" and tostring(c.world) or "no stage picked") end
    if usesAct then table.insert(parts, "Act " .. tostring(c.act)) end
    if usesDiff then table.insert(parts, tostring(c.difficulty)) end
    pcall(function() joinLine:UpdateBody(table.concat(parts, " · ")) end)
    for _, d in ipairs({ { worldDropdown, usesStage }, { actDropdown, usesAct }, { diffDropdown, usesDiff } }) do
        pcall(function() d[1]:SetVisibility(d[2]) end)
    end
end
join:Dropdown({ Name = "Join mode", Multi = false, Required = true,
    Options = { "Event", "Challenges", "Story", "Infinite", "Legend", "Raid", "Infinity Mansion" }, Default = Lobby.cfg.mode,
    Callback = function(v)
        if syncing or type(v) ~= "string" then return end
        local changed = v ~= Lobby.cfg.mode
        Lobby.cfg.mode = v
        local list = Lobby.Worlds(v)
        -- a stage from the old mode's list would not match this one (only on a real change, and
        -- only when the list is known: the game data can be missing at start)
        if changed and #list > 0 and not table.find(list, Lobby.cfg.world) then
            Lobby.cfg.world = (v == "Event" or v == "Infinity Mansion" or v == "Challenges") and list[1] or ""
        end
        saveConfig()
        local was = syncing
        syncing = true
        pcall(function()
            worldDropdown:ClearOptions()
            worldDropdown:InsertOptions(list)
            if Lobby.cfg.world ~= "" then worldDropdown:UpdateSelection(Lobby.cfg.world) end
        end)
        syncing = was
        joinRefresh()
    end }, "LobbyMode")
worldDropdown = join:Dropdown({ Name = "Stage", Multi = false, Required = false,
    Options = Lobby.Worlds(Lobby.cfg.mode), Default = Lobby.cfg.world ~= "" and Lobby.cfg.world or nil,
    Callback = function(v) if syncing or type(v) ~= "string" then return end Lobby.cfg.world = v saveConfig() joinRefresh() end }, "LobbyWorld")
actDropdown = join:Dropdown({ Name = "Act", Multi = false, Required = true, Options = { "1", "2", "3", "4", "5", "6" },
    Default = Lobby.cfg.act, Callback = function(v) set("act")(v) joinRefresh() end }, "LobbyAct")
diffDropdown = join:Dropdown({ Name = "Difficulty", Multi = false, Required = true, Options = { "Normal", "Hard" },
    Default = Lobby.cfg.difficulty, Callback = function(v) set("difficulty")(v) joinRefresh() end }, "LobbyDifficulty")
joinRefresh()
join:Toggle({ Name = "Friends only", Default = Lobby.cfg.joinFriends, Callback = set("joinFriends") }, "LobbyJoinFriends")
-- (stays on across teleports until turned off: the script restarts in every stage)
UIRef.set.tools:Toggle({ Name = "Watch game calls", Default = Lobby.cfg.watch, Callback = function(on)
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
UIRef.set.general:Toggle({ Name = "Auto update", Default = Lobby.cfg.autoUpdate ~= false, Callback = set("autoUpdate") }, "EventAutoUpdate")
UIRef.set.general:Toggle({ Name = "Share game data", Default = Lobby.cfg.shareData ~= false, Callback = set("shareData") }, "EventShare")
task.delay(5, pcall, Lobby.ShareNotice)
local event = UIRef.tabs.event:Section({ Side = "Left" })
event:Header({ Text = "Fool's Hunt" })
event:Paragraph({ Header = "How", Body = "Lobby: Join mode Event, then AUTO on Home." })
event:Toggle({ Name = "Event Auto Place", Default = Lobby.cfg.eventBrain ~= false, Callback = set("eventBrain") }, "EventBrain")
event:Toggle({ Name = "Vote cards", Default = Lobby.cfg.eventCards, Callback = set("eventCards") }, "EventCards")
event:Toggle({ Name = "Use spells", Default = Lobby.cfg.eventSpells, Callback = set("eventSpells") }, "EventSpells")
event:Dropdown({ Name = "Card choice", Multi = false, Required = true, Options = { "Most coins", "Safest" },
    Default = Lobby.cfg.cardMode, Callback = set("cardMode") }, "EventCardMode")
event:Dropdown({ Name = "Always place", Multi = true, Required = false, Options = AutoPlaceModule.ROSTER,
    Default = picked(Lobby.cfg.eventAlways or {}), Callback = setList("eventAlways") }, "EventAlways")
event:Dropdown({ Name = "Never place", Multi = true, Required = false, Options = AutoPlaceModule.ROSTER,
    Default = picked(Lobby.cfg.eventNever or {}), Callback = setList("eventNever") }, "EventNever")
event:Dropdown({ Name = "Spells kept waiting", Multi = false, Required = true, Options = { "1", "2", "3" },
    Default = tostring(Lobby.cfg.maxSpellsHeld or 2), Callback = function(v) if syncing then return end Lobby.cfg.maxSpellsHeld = tonumber(v) or 2 saveConfig() end }, "EventSpellsHeld")
event:Paragraph({ Header = "Units", Body = "Always place: placed first, never removed. Never place: removed at once so the slot rolls again." })
event:Paragraph({ Header = "Cards", Body = "Most coins: the least harmful Bad card. Safest: Good cards first." })
end

-- TAB: Dungeon (data first; see MODULE: Dungeon Run)
do
local dungeonTab = UIRef.tabs.dungeon
local dataSection = dungeonTab:Section({ Side = "Left" })

-- (owner 2026-10-25: the tab keeps one status line, the switch and Setup; the choices live in
-- the Setup window - DungeonRun.OpenSetup)
dataSection:Header({ Text = "Dungeon" })
UIRef.dungeonStatus = dataSection:Paragraph({ Header = "Run", Body = "Off" })
Controls.dungeonAuto = dataSection:Toggle({
    Name = "Auto dungeon",
    Default = false,
    Callback = function(on)
        if on then DungeonRun.Start() else DungeonRun.Stop() end
        saveConfig()
    end,
}, "DungeonBot")
dataSection:Button({ Name = "Setup…", Callback = function()
    local ok, err = pcall(DungeonRun.OpenSetup)
    if not ok then notify("Dungeon setup: " .. clip(tostring(err), 80)) end
end })
end

-- TAB 5: Settings
do
local settingsTab = UIRef.tabs.settings

local generalSection, webhookSection, profileSection = UIRef.set.general, UIRef.set.webhook, UIRef.set.profile
Controls.perfSection = UIRef.set.perf
local toolsSection = UIRef.set.tools

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
    Placeholder = "name",
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

UIRef.antiAfkToggle = generalSection:Toggle({
    Name = "Anti-AFK",
    Default = false,
    Callback = function(on)
        Tools.antiAfk = on
        if on then ToolsModule.StartAntiAfk() else ToolsModule.StopAntiAfk() end
        saveConfig()
    end,
}, "AntiAfk")
generalSection:Toggle({
    Name = "Place on enemy path",
    Default = Tools.onPath == true,
    Callback = function(on)
        Tools.onPath = on
        AutoPlaceModule.ResetSpots() -- (spots are worked out again with / without the road)
        saveConfig()
    end,
}, "PlaceOnPath")

Controls.webhookUrl = webhookSection:Input({
    Name = "Webhook URL",
    Placeholder = "paste URL",
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
-- Auto Place / Home status: once a second off the frame thread (owner 2026-10-25: lag). The
-- status text is built once per tick for both paragraphs; nothing is built while the window
-- is hidden (MacLib Window:GetState, when it has one).
task.spawn(function()
    while not State.unloaded do
        local okShown, shown = pcall(function() return Window:GetState() end)
        if not (okShown and shown == false) then
            local ok, text = pcall(AutoPlaceModule.StatusText)
            text = ok and text or nil
            if AutoPlace.enabled and AutoPlaceModule.refreshUI then pcall(AutoPlaceModule.refreshUI, text) end
            if AutoPlaceModule.refreshHome then pcall(AutoPlaceModule.refreshHome, text) end
        end
        task.wait(1)
    end
end)
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
    pcall(function() if AutoPlaceModule.V2.moneyConn then AutoPlaceModule.V2.moneyConn:Disconnect() end end)
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
    -- (the config is read before the Dungeon module exists: its room prefs become the order here)
    if DungeonRun.prefs then pcall(DungeonRun.ApplyPrefs) end
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
    if pendingToggles.dungeon and not DungeonRun.enabled then
        setControl(Controls.dungeonAuto, true)
        DungeonRun.Start()
    end
    pcall(AutoPlaceModule.ShowMode)

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
