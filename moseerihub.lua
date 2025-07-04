-- test4.lua

-- 🚫 ปิด loop เก่า (ถ้ามี)
getgenv().AutoFarm = false
getgenv().KillAura = false

-- 🪟 ถ้ามีหน้าต่าง Rayfield เก่า ก็ทำลายก่อน
if _G.RayfieldWindow then
    _G.RayfieldWindow:Destroy()
    _G.RayfieldWindow = nil
end

-- 🌐 โหลด Rayfield UI
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
_G.RayfieldWindow = Rayfield

-- 🪟 สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
    Name                = "👑 Moseeri Hub",
    LoadingTitle        = "Loading Moseeri Hub...",
    LoadingSubtitle     = "Made by Moseeri",
    ConfigurationSaving = { Enabled = true, FileName = "MoseeriHub" },
    Discord             = { Enabled = false },
    KeySystem           = false,
})

-- 📦 Services & Remotes
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local RepStorage   = game:GetService("ReplicatedStorage")
local PlayerEvents = RepStorage:WaitForChild("PlayerEvents")
local ManageWeapon = PlayerEvents:WaitForChild("ManageWeapon")
local EntityHit    = PlayerEvents:WaitForChild("EntityHit")

-- 🔧 State
getgenv().AutoFarm = false
getgenv().KillAura = false
local WalkSpeedValue = 16
local JumpPowerValue = 50
local AuraRadius     = 30
local selectedMob    = ""

-- 📋 ดึงรายชื่อมอน (ไม่ซ้ำ)
local function getMonsterNames()
    local t, seen = {}, {}
    local root = workspace:FindFirstChild("SpawnedEntities")
    if root then
        for _, m in ipairs(root:GetChildren()) do
            if m:IsA("Model") and not seen[m.Name] then
                seen[m.Name] = true
                table.insert(t, m.Name)
            end
        end
    end
    return t
end

-- 💥 ตั้งค่า Speed/Jump
local function setCharacterStats()
    local c = Players.LocalPlayer.Character
    if c then
        local h = c:FindFirstChildOfClass("Humanoid")
        if h then
            h.WalkSpeed  = WalkSpeedValue
            h.JumpPower  = JumpPowerValue
        end
    end
end

-- 🔍 หา nearest mob ตามชื่อ (substring) หรือ ทุกตัวถ้าว่าง
local function findNearestMob()
    local best, bestDist = nil, math.huge
    local root = workspace:FindFirstChild("SpawnedEntities")
    if not root then return end

    for _, m in ipairs(root:GetChildren()) do
        if m:IsA("Model") then
            local nm = m.Name
            if selectedMob == "" or nm:lower():find(selectedMob:lower(),1,true) then
                local hrp = m:FindFirstChild("HumanoidRootPart")
                local hum = m:FindFirstChildOfClass("Humanoid")
                if hrp and hum and hum.Health > 0 then
                    local d = (Players.LocalPlayer.Character.HumanoidRootPart.Position - hrp.Position).Magnitude
                    if d < bestDist then
                        bestDist, best = d, m
                    end
                end
            end
        end
    end
    if best then
        print(("[AutoFarm] Nearest matching mob: %s (%.1f)"):format(best.Name,bestDist))
    else
        print(("[AutoFarm] No matching mob for “%s”"):format(selectedMob))
    end
    return best
end

-- 🚶 วาร์ป+ตี (จดตำแหน่งก่อน)
local startCFrame
local function teleportAndAttack(mob)
    local c = Players.LocalPlayer.Character
    if not c then return end
    if not c.PrimaryPart then
        local hrp = c:FindFirstChild("HumanoidRootPart")
        if hrp then c.PrimaryPart = hrp end
    end
    if not c.PrimaryPart then return end

    startCFrame = c.PrimaryPart.CFrame
    local mHRP = mob:FindFirstChild("HumanoidRootPart")
    if mHRP then
        c:SetPrimaryPartCFrame(mHRP.CFrame * CFrame.new(0,0,2))
        RunService.Heartbeat:Wait()
        RunService.Heartbeat:Wait()
        pcall(function() ManageWeapon:InvokeServer(true) end)
        RunService.Heartbeat:Wait()
        pcall(function() EntityHit:FireServer(mob) end)
    end
end

-- 🔄 AutoFarm Loop
local function autoFarmLoop()
    while getgenv().AutoFarm do
        local mob = findNearestMob()
        if mob then
            teleportAndAttack(mob)
            repeat RunService.Heartbeat:Wait()
            until not mob:FindFirstChildOfClass("Humanoid") 
               or mob:FindFirstChildOfClass("Humanoid").Health<=0
            if startCFrame then
                Players.LocalPlayer.Character:SetPrimaryPartCFrame(startCFrame)
                RunService.Heartbeat:Wait()
            end
        else
            task.wait(1)
        end
    end
end

function startAutoFarm()
    if getgenv().AutoFarm then return end
    getgenv().AutoFarm = true
    task.spawn(autoFarmLoop)
end
function stopAutoFarm() getgenv().AutoFarm = false end

-- 🛡️ KillAura
local function killAuraLoop()
    while getgenv().KillAura do
        local c, hrp = Players.LocalPlayer.Character, nil
        if c then hrp = c:FindFirstChild("HumanoidRootPart") end
        if hrp then
            local origin = hrp.Position
            local root   = workspace:FindFirstChild("SpawnedEntities")
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
function startKillAura() if getgenv().KillAura then return end; getgenv().KillAura=true; task.spawn(killAuraLoop) end
function stopKillAura() getgenv().KillAura=false end

----------------------------------
-- ✅ Tab “Home”
local home = Window:CreateTab("🏠 Home")
home:CreateSection("Character & AutoFarm")

home:CreateSlider({
    Name          = "WalkSpeed",
    Range         = {1,500},
    Increment     = 1,
    Suffix        = " Speed",
    CurrentValue  = WalkSpeedValue,
    Callback      = function(v) WalkSpeedValue=v; setCharacterStats() end,
})

home:CreateSlider({
    Name          = "JumpPower",
    Range         = {1,500},
    Increment     = 1,
    Suffix        = " Jump",
    CurrentValue  = JumpPowerValue,
    Callback      = function(v) JumpPowerValue=v; setCharacterStats() end,
})

home:CreateDropdown({
    Name           = "Select Mob",
    Options        = getMonsterNames(),
    CurrentOption  = {selectedMob},
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

home:CreateToggle({
    Name         = "Enable Kill Aura",
    CurrentValue = false,
    Callback     = function(on) if on then startKillAura() else stopKillAura() end end,
})

----------------------------------
-- 🏝 Tab “Teleports”
local tp = Window:CreateTab("🏝 Teleports")
tp:CreateSection("Locations")
tp:CreateButton({ Name="Starter Island",  Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(0,10,0)) end })
tp:CreateButton({ Name="Pirate Island",   Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(100,10,0)) end })
tp:CreateButton({ Name="Pineapple Paradise", Callback=function() Players.LocalPlayer.Character:SetPrimaryPartCFrame(CFrame.new(200,10,0)) end })

----------------------------------
-- ⚔️ Tab “Kill Aura”
local ka = Window:CreateTab("⚔️ Kill Aura")
ka:CreateSection("Settings")
ka:CreateSlider({
    Name         = "Aura Radius",
    Range        = {1,100},
    Increment    = 1,
    Suffix       = " studs",
    CurrentValue = AuraRadius,
    Callback     = function(v) AuraRadius=v end,
})
ka:CreateToggle({
    Name         = "Enable Kill Aura",
    CurrentValue = false,
    Callback     = function(on) if on then startKillAura() else stopKillAura() end end,
})

print("👑 Moseeri Hub (test4) loaded!")
