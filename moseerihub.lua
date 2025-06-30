-- โหลดไลบรารี Rayfield (Sirius.menu)
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- สร้างหน้าต่างหลัก พร้อมระบบ KeySystem
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "Auto Farm System",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Get your key from Discord",
        Note = "https://discord.gg/uGX2X3WvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
    }
})

-- Notification แสดงแค่โหลดเสร็จ
Rayfield:Notify({
    Title = "✅ Moseeri Hub Loaded",
    Content = "Welcome to the hub!",
    Duration = 4,
    Image = 13047715178,  -- เปลี่ยนเป็น AssetID ที่ต้องการ
    Actions = {
        Okay = {
            Name = "Close",
            Callback = function() end
        }
    }
})

-- ────────────────
-- 1) MAIN FEATURES TAB
-- ────────────────
local TabMain = Window:CreateTab("Main Features", 4483345998)
local SectionFarm = TabMain:CreateSection("Auto Farming")

-- เก็บชื่อมอนสเตอร์จาก Workspace
local mobs = {}
for _, v in pairs(game.Workspace.Monster.Mon:GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

-- กำหนดค่าเริ่มต้น
getgenv().autoFarm      = false
getgenv().selectedMob   = mobs[1] or ""
getgenv().farmDelay     = 0.1

-- Dropdown เลือกมอน
SectionFarm:CreateDropdown({
    Name = "Select Mob",
    Options = mobs,
    CurrentOption = getgenv().selectedMob,
    Flag = "FarmMob",
    Callback = function(opt)
        getgenv().selectedMob = opt
    end
})

-- Slider ตั้ง Delay
SectionFarm:CreateSlider({
    Name = "Delay Between Warps",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = getgenv().farmDelay,
    Flag = "FarmDelay",
    Callback = function(val)
        getgenv().farmDelay = val
    end
})

-- Toggle เริ่ม/หยุด Auto Farm
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
    end
})

-- ────────────────
-- 2) DUNGEON & TOWER TAB
-- ────────────────
local TabDungeon = Window:CreateTab("Dungeon & Tower", 6023426942)
local SectionDungeon = TabDungeon:CreateSection("Dungeon Scripts")
SectionDungeon:CreateButton({
    Name = "Auto Dungeon",
    Callback = function()
        -- ใส่โค้ด Auto Dungeon เพิ่มตรงนี้
        print("Running Auto Dungeon...")
    end
})

-- ────────────────
-- 3) PLAYER TAB
-- ────────────────
local TabPlayer = Window:CreateTab("Player", 147826918)
local SectionPlayer = TabPlayer:CreateSection("Player Options")

getgenv().infJump = false
-- Infinite Jump Toggle
SectionPlayer:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = getgenv().infJump,
    Flag = "InfJumpToggle",
    Callback = function(val)
        getgenv().infJump = val
        if val then
            game:GetService("UserInputService").JumpRequest:Connect(function()
                if getgenv().infJump then
                    local plr = game.Players.LocalPlayer
                    plr.Character.Humanoid:ChangeState("Jumping")
                end
            end)
        end
    end
})

-- WalkSpeed Slider
SectionPlayer:CreateSlider({
    Name = "Walkspeed",
    Range = {16, 200},
    Increment = 1,
    Suffix = "Speed",
    CurrentValue = 16,
    Flag = "WalkSpeedSlider",
    Callback = function(val)
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = val
    end
})

-- ────────────────
-- 4) MISC TAB
-- ────────────────
local TabMisc = Window:CreateTab("Misc", 5012544693)
local SectionMisc = TabMisc:CreateSection("Utilities")

SectionMisc:CreateButton({
    Name = "Teleport to Spawn",
    Callback = function()
        local spawnCFrame = workspace.SpawnLocation.CFrame
        game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawnCFrame
    end
})
