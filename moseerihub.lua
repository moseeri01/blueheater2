-- เรียก Rayfield (Sirius)
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Moseeri Hub",
    LoadingSubtitle = "by Moseeri",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Get your key from Discord",
        Note = "https://discord.gg/uGX2X3xWvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = { "https://raw.githubusercontent.com/moseeri01/key/main/key.txt" }
    }
})

-- แจ้งเตือนเมื่อโหลดเสร็จ
Rayfield:Notify({
    Title = "Welcome!",
    Content = "Moseeri Hub Loaded",
    Duration = 4,
    Image = 13047715178,
    Actions = {
        Close = { Name = "Close", Callback = function() print("Hub Closed") end }
    }
})

----------------------------------------
-- Tab: 🏠 Home
----------------------------------------
local HomeTab     = Window:CreateTab("🏠 Home", nil)
local HomeSection = HomeTab:CreateSection("Main")

HomeSection:CreateLabel("👋 Welcome to Moseeri Hub!")

HomeSection:CreateButton({
    Name = "Rejoin Server",
    Callback = function()
        game:GetService("Players").LocalPlayer:Kick("Rejoining…")
    end
})

HomeSection:CreateButton({
    Name = "Destroy GUI",
    Callback = function()
        Rayfield:Destroy()
    end
})

----------------------------------------
-- Tab: Main Features
----------------------------------------
local MFTab     = Window:CreateTab("Main Features", nil)
local MFSec     = MFTab:CreateSection("Features")

-- Auto Farm
getgenv().autoFarm        = false
MFSec:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Flag = "Main_AutoFarm",
    Tooltip = "เปิด/ปิดการฟาร์มอัตโนมัติ",
    Callback = function(v)
        getgenv().autoFarm = v
        print("Auto Farm:", v)
    end,
})

-- Chest Farm
getgenv().chestFarm      = false
MFSec:CreateToggle({
    Name = "Chest Farm",
    CurrentValue = false,
    Flag = "Main_ChestFarm",
    Tooltip = "เปิด/ปิดการเก็บ Chest อัตโนมัติ",
    Callback = function(v)
        getgenv().chestFarm = v
        print("Chest Farm:", v)
    end,
})

-- Dodge Mechanism
getgenv().autoDodge      = false
MFSec:CreateToggle({
    Name = "Dodge Mechanism",
    CurrentValue = false,
    Flag = "Main_Dodge",
    Tooltip = "เปิด/ปิดระบบหลบสกิล",
    Callback = function(v)
        getgenv().autoDodge = v
        print("Dodge Mechanism:", v)
    end,
})

-- Boss Prioritization
getgenv().bossPriority   = false
MFSec:CreateToggle({
    Name = "Boss Prioritization",
    CurrentValue = false,
    Flag = "Main_BossPriority",
    Tooltip = "โฟกัสบอสก่อน",
    Callback = function(v)
        getgenv().bossPriority = v
        print("Boss Prioritization:", v)
    end,
})

-- Kill Aura
getgenv().killAura       = false
MFSec:CreateToggle({
    Name = "Kill Aura",
    CurrentValue = false,
    Flag = "Main_KillAura",
    Tooltip = "เปิด/ปิดระบบ Kill Aura",
    Callback = function(v)
        getgenv().killAura = v
        print("Kill Aura:", v)
    end,
})

-- Kill Aura Speed
getgenv().killAuraSpeed  = 50
MFSec:CreateSlider({
    Name = "Kill Aura Speed",
    Range = {1, 100},
    Increment = 1,
    Suffix = "%",
    CurrentValue = 50,
    Flag = "Main_KillAuraSpeed",
    Tooltip = "ปรับความถี่การโจมตีของ Kill Aura",
    Callback = function(val)
        getgenv().killAuraSpeed = val
        print("Kill Aura Speed:", val)
    end,
})

----------------------------------------
-- Tab: Dungeon & Tower
----------------------------------------
local DTTab     = Window:CreateTab("Dungeon & Tower", nil)
local DTSec     = DTTab:CreateSection("Automation")

-- ตัวอย่าง Auto Dungeon
getgenv().autoDungeon    = false
DTSec:CreateToggle({
    Name = "Auto Dungeon",
    CurrentValue = false,
    Flag = "DT_AutoDungeon",
    Tooltip = "เข้า-ออกดันเจี้ยนอัตโนมัติ",
    Callback = function(v)
        getgenv().autoDungeon = v
        print("Auto Dungeon:", v)
    end,
})

-- ตัวอย่าง Auto Tower
getgenv().autoTower      = false
DTSec:CreateToggle({
    Name = "Auto Tower",
    CurrentValue = false,
    Flag = "DT_AutoTower",
    Tooltip = "ปีนหอคอยอัตโนมัติ",
    Callback = function(v)
        getgenv().autoTower = v
        print("Auto Tower:", v)
    end,
})

-- Interval ระหว่าง Auto Tower
getgenv().towerInterval  = 5
DTSec:CreateSlider({
    Name = "Tower Interval",
    Range = {1, 60},
    Increment = 1,
    Suffix = "s",
    CurrentValue = 5,
    Flag = "DT_TowerInterval",
    Tooltip = "ดีเลย์ระหว่างแต่ละขั้นหอคอย",
    Callback = function(v)
        getgenv().towerInterval = v
        print("Tower Interval:", v)
    end,
})

-- ปุ่ม Teleport ตัวอย่าง
DTSec:CreateButton({
    Name = "Teleport to Dungeon",
    Callback = function()
        local spawn = workspace:FindFirstChild("DungeonSpawn")
        if spawn then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        end
    end,
})

DTSec:CreateButton({
    Name = "Teleport to Tower",
    Callback = function()
        local spawn = workspace:FindFirstChild("TowerSpawn")
        if spawn then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        end
    end,
})

----------------------------------------
-- Tab: Player
----------------------------------------
local PTab      = Window:CreateTab("Player", nil)
local PMov      = PTab:CreateSection("Movement")
local PMisc     = PTab:CreateSection("Miscellaneous")

-- Infinite Jump
getgenv().infJump       = false
PMov:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Flag = "P_InfJump",
    Tooltip = "กระโดดไม่จำกัด",
    Callback = function(v)
        getgenv().infJump = v
        print("Infinite Jump:", v)
    end,
})
-- เชื่อม KeyDown ใน background
if not getgenv().infJumpInit then
    getgenv().infJumpInit = true
    local plr = game:GetService("Players").LocalPlayer
    plr:GetMouse().KeyDown:Connect(function(key)
        if getgenv().infJump and key:byte() == 32 then
            local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            if h then
                h:ChangeState("Jumping")
            end
        end
    end)
end

-- WalkSpeed Slider
getgenv().walkSpeed     = 16
PMov:CreateSlider({
    Name = "WalkSpeed",
    Range = {1, 350},
    Increment = 1,
    Suffix = "",
    CurrentValue = 16,
    Flag = "P_WalkSpeed",
    Tooltip = "ปรับความเร็วเดิน",
    Callback = function(v)
        getgenv().walkSpeed = v
        local hrp = game.Players.LocalPlayer.Character
        if hrp then hrp.Humanoid.WalkSpeed = v end
    end,
})

-- JumpPower Slider
getgenv().jumpPower     = 50
PMov:CreateSlider({
    Name = "JumpPower",
    Range = {1, 350},
    Increment = 1,
    Suffix = "",
    CurrentValue = 50,
    Flag = "P_JumpPower",
    Tooltip = "ปรับพลังกระโดด",
    Callback = function(v)
        getgenv().jumpPower = v
        local hrp = game.Players.LocalPlayer.Character
        if hrp then hrp.Humanoid.JumpPower = v end
    end,
})

-- Spam Chat
getgenv().chatSpam      = false
getgenv().spamText      = "Hello"
PMisc:CreateToggle({
    Name = "Spam Chat",
    CurrentValue = false,
    Flag = "P_ChatSpam",
    Tooltip = "ส่งข้อความซ้ำๆ",
    Callback = function(v)
        getgenv().chatSpam = v
        spawn(function()
            while getgenv().chatSpam do
                game:GetService("ReplicatedStorage").DefaultChatSystemChatEvents.SayMessageRequest:FireServer(getgenv().spamText, "All")
                task.wait(1)
            end
        end)
    end,
})
PMisc:CreateInput({
    Name = "Spam Text",
    PlaceholderText = "พิมพ์ข้อความ...",
    RemoveTextAfterFocusLost = true,
