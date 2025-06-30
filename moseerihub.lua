local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "By Amira",
    ConfigurationSaving = { Enabled = true, FolderName = nil, FileName = "MoseeriHub" },
    KeySystem = false,      -- <-- ปิดก่อน ให้ UI ขึ้นเลย
})

-- เก็บชื่อมอนสเตอร์
local mobs = {}
for _, m in pairs(workspace.Monster.Mon:GetChildren()) do
    if not table.find(mobs, m.Name) then
        table.insert(mobs, m.Name)
    end
end

-- ค่าเริ่มต้น
getgenv().autoFarm    = false
getgenv().selectedMob = mobs[1] or ""
getgenv().farmDelay   = 0.1

-- สร้าง Tab + Section
local TabMain     = Window:CreateTab("Main Features", 4483345998)
local SectionFarm = TabMain:CreateSection("Farming Control")

-- 1) Dropdown เลือกมอน
SectionFarm:CreateDropdown({
    Name = "Select Mob",
    Options = mobs,
    CurrentOption = getgenv().selectedMob,
    Flag = "FarmMob",
    Callback = function(opt)
        getgenv().selectedMob = opt
    end,
})

-- 2) Slider ตั้ง Delay
SectionFarm:CreateSlider({
    Name = "Warp Delay",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = getgenv().farmDelay,
    Flag = "FarmDelay",
    Callback = function(val)
        getgenv().farmDelay = val
    end,
})

-- 3) **Toggle “Enable Auto Farm”**
SectionFarm:CreateToggle({
    Name = "Enable Auto Farm",
    CurrentValue = getgenv().autoFarm,
    Flag = "ToggleAutoFarm",
    Callback = function(val)
        getgenv().autoFarm = val
        if val then
            spawn(function()
                while getgenv().autoFarm do
                    local mob = workspace.Monster.Mon:FindFirstChild(getgenv().selectedMob)
                    if mob and mob:FindFirstChild("HumanoidRootPart") then
                        local plr = game.Players.LocalPlayer
                        plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                    end
                    task.wait(getgenv().farmDelay)
                end
            end)
        end
    end,
})
