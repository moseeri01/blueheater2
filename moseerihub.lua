local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Auto Farm Hub",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "MoseeriHub",
        FileName = "config"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "มาจาก Discord",
        Note = "https://discord.gg/yourinvite",
        FileName = "moseerikey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"https://raw.githubusercontent.com/YourUser/YourRepo/main/key.txt"}
    }
})

-- หน้า Main
local Main = Window:CreateTab("🎯 Main", nil)
local FarmSec = Main:CreateSection("🛡️ Auto Farm Settings")

-- ตัวแปร Global
getgenv().autofarm = false
getgenv().selectedMob = nil
getgenv().delayTime = 0.1

-- ดึงชื่อ Mob จาก Workspace
local mobList = {}
for _, mob in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
    if not table.find(mobList, mob.Name) then
        table.insert(mobList, mob.Name)
    end
end

-- เมนูเลือก Mob
FarmSec:CreateDropdown({
    Name = "Select Mob",
    Options = mobList,
    CurrentOption = mobList[1] or "None",
    Callback = function(value)
        getgenv().selectedMob = value
    end
})

-- Slider ตั้งดีเลย์
FarmSec:CreateSlider({
    Name = "Delay (seconds)",
    Range = {0.05, 2},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = 0.1,
    Callback = function(v)
        getgenv().delayTime = v
    end
})

-- ปุ่ม Auto Farm พร้อมไอคอน
FarmSec:CreateToggle({
    Name = "⚔️ Auto Farm",
    CurrentValue = false,
    Callback = function(enabled)
        getgenv().autofarm = enabled
        if enabled then
            startAutoFarm()
        end
    end
})

-- ฟังก์ชัน Auto Farm
function startAutoFarm()
    task.spawn(function()
        while getgenv().autofarm do
            local root = game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob or "")
            if root and mob and mob:FindFirstChild("HumanoidRootPart") then
                root.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
            end
            task.wait(getgenv().delayTime)
        end
    end)
end
