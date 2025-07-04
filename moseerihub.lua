
getgenv().AutoFarm = false
getgenv().KillAura = false
if _G.MoseeriWindow then _G.MoseeriWindow:Destroy() _G.MoseeriWindow = nil end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name = "👑 Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "Made by Moseeri",
    ConfigurationSaving = { Enabled = true, FileName = "MoseeriHub" },
    Discord = { Enabled = false },
    KeySystem = false,
})
_G.MoseeriWindow = Window

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
local PE = RepStorage:WaitForChild("PlayerEvents")
local ManageWeapon = PE:WaitForChild("ManageWeapon")
local EntityHit = PE:WaitForChild("EntityHit")

local WalkSpeedValue, JumpPowerValue, AuraRadius = 16, 50, 30
local selectedMob = ""

local function getMonsterNames()
    local seen, out = {}, {}
    local root = workspace:FindFirstChild("SpawnedEntities")
    if root then
        for _, m in ipairs(root:GetChildren()) do
            if m:IsA("Model") and not seen[m.Name] then
                seen[m.Name] = true
                table.insert(out, m.Name)
            end
        end
    end
    return out
end

local function setCharacterStats()
    local c = Players.LocalPlayer.Character
    if c then
        local h = c:FindFirstChildOfClass("Humanoid")
        if h then
            h.WalkSpeed = WalkSpeedValue
            h.JumpPower = JumpPowerValue
        end
    end
end

local function findNearestMob()
    local best, bestDist = nil, math.huge
    local root = workspace:FindFirstChild("SpawnedEntities")
    if not root then return end
    local me = Players.LocalPlayer.Character
    if not me or not me:FindFirstChild("HumanoidRootPart") then return end
    local myPos = me.HumanoidRootPart.Position
    for _, m in ipairs(root:GetChildren()) do
        if m:IsA("Model") then
            if selectedMob == "" or m.Name:lower():find(selectedMob:lower(),1,true) then
                local hrp = m:FindFirstChild("HumanoidRootPart")
                local hum = m:FindFirstChildOfClass("Humanoid")
                if hrp and hum and hum.Health>0 then
                    local d = (hrp.Position - myPos).Magnitude
                    if d < bestDist then
                        bestDist, best = d, m
                    end
                end
            end
        end
    end
    return best
end

local startCFrame
local function teleportAndAttack(mob)
    local c = Players.LocalPlayer.Character
    if not c then return end
    local part = c:FindFirstChild("HumanoidRootPart")
    if not part then return end
    startCFrame = part.CFrame
    local mHRP = mob:FindFirstChild("HumanoidRootPart")
    if mHRP then
        c:SetPrimaryPartCFrame(mHRP.CFrame * CFrame.new(0,0,2))
        RunService.Heartbeat:Wait()
        pcall(function() ManageWeapon:InvokeServer(true) end)
        RunService.Heartbeat:Wait()
        pcall(function() EntityHit:FireServer(mob) end)
    end
end

local function autoFarmLoop()
    while getgenv().AutoFarm do
        local mob = findNearestMob()
        if mob then
            teleportAndAttack(mob)
            repeat RunService.Heartbeat:Wait()
            until not mob:FindFirstChildOfClass("Humanoid") or mob.Humanoid.Health<=0
            if startCFrame then
                Players.LocalPlayer.Character:SetPrimaryPartCFrame(startCFrame)
                RunService.Heartbeat:Wait()
            end
        else
            task.wait(1)
        end
    end
end
function startAutoFarm() if not getgenv().AutoFarm then getgenv().AutoFarm=true; task.spawn(autoFarmLoop) end end
function stopAutoFarm() getgenv().AutoFarm = false end

local function killAuraLoop()
    while getgenv().KillAura do
        local c = Players.LocalPlayer.Character
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if hrp then
            local origin = hrp.Position
            local root = workspace:FindFirstChild("SpawnedEntities")
            if root then
                for _, m in ipairs(root:GetChildren()) do
                    local p = m:FindFirstChild("HumanoidRootPart")
                    local h = m:FindFirstChildOfClass("Humanoid")
                    if p and h and h.Health>0 and (origin-p.Position).Magnitude<=AuraRadius then
                        pcall(function()
                            ManageWeapon:InvokeServer(true)
                            EntityHit:FireServer(m)
                        end)
                    end
                end
            end
        end
        RunService.RenderStepped:Wait()
    end
end
function startKillAura() if not getgenv().KillAura then getgenv().KillAura=true; task.spawn(killAuraLoop) end end
function stopKillAura() getgenv().KillAura=false end

-- 🏠 Home Tab ทุกอย่างอยู่ในนี้หมด!
local home = Window:CreateTab("🏠 Home")
home:CreateSection("Character & AutoFarm")

home:CreateSlider({
    Name         = "WalkSpeed",
    Range        = {1,500},
    Increment    = 1,
    Suffix       = " Speed",
    CurrentValue = WalkSpeedValue,
    Callback     = function(v) WalkSpeedValue=v; setCharacterStats() end,
})
home:CreateSlider({
    Name         = "JumpPower",
    Range        = {1,500},
    Increment    = 1,
    Suffix       = " Jump",
    CurrentValue = JumpPowerValue,
    Callback     = function(v) JumpPowerValue=v; setCharacterStats() end,
})
home:CreateDropdown({
    Name           = "Select Mob",
    Options        = getMonsterNames(),
    CurrentOption  = { selectedMob },
    MultipleOptions= false,
    Callback       = function(opt)
        selectedMob = (type(opt)=="table" and opt[1]) or opt
        print("[AutoFarm] Selected Mob:", selectedMob)
    end,
})
home:CreateToggle({
    Name         = "Enable Auto Farm",
    CurrentValue = false,
    Callback     = function(on) if on then startAutoFarm() else stopAutoFarm() end end,
})

-- 🟦 ย้าย Kill Aura มาตรงนี้
home:CreateSection("Kill Aura Settings")
home:CreateSlider({
    Name         = "Aura Radius",
    Range        = {1,100},
    Increment    = 1,
    Suffix       = " studs",
    CurrentValue = AuraRadius,
    Callback     = function(v) AuraRadius=v end,
})
home:CreateToggle({
    Name         = "Enable Kill Aura",
    CurrentValue = false,
    Callback     = function(on) if on then startKillAura() else stopKillAura() end end,
})

-- 🏝 Teleports Tab
local tp = Window:CreateTab("🏝 Teleports")
tp:CreateSection("Locations")
tp:CreateButton({ Name="Starter Island",      Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(0,10,0)) end })
tp:CreateButton({ Name="Pirate Island",       Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(100,10,0)) end })
tp:CreateButton({ Name="Pineapple Paradise",  Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(200,10,0)) end })

print("👑 Moseeri Hub (test5) loaded!")
