local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
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
        Note = "https://discord.gg/uGX2X3xWvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
    }
})

-- สร้างแท็บเดียว ชื่อ "Auto Farm"
local FarmTab = Window:CreateTab("⚔️ Auto Farm")

-- ตัวแปรหลัก
getgenv().autofarm = false
getgenv().selectedMob = nil
getgenv().delayTime = 0.1

-- หามอนสเตอร์ใน Workspace
local mobs = {}
for _, v in pairs(game:GetService("Workspace"):WaitForChild("Monster"):WaitForChild("Mon"):GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

-- Dropdown เลือกมอนสเตอร์
FarmTab:CreateDropdown({
    Name = "เลือกมอนสเตอร์",
    Options = mobs,
    CurrentOption = mobs[1] or "None",
    Callback = function(value)
        getgenv().selectedMob = value
    end
})

-- Slider ปรับดีเลย์
FarmTab:CreateSlider({
    Name = "ดีเลย์โจมตี (วินาที)",
    Range = {0.05, 2},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = 0.1,
    Callback = function(value)
        getgenv().delayTime = value
    end
})

-- ปุ่ม Toggle เริ่ม Auto Farm
FarmTab:CreateToggle({
    Name = "เริ่ม Auto Farm",
    CurrentValue = false,
    Callback = function(value)
        getgenv().autofarm = value
        if value then
            AutoFarm()
        end
    end
})

-- ฟังก์ชัน Auto Farm
function AutoFarm()
    task.spawn(function()
        while getgenv().autofarm do
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob)
            local plr = game.Players.LocalPlayer
            if mob and mob:FindFirstChild("HumanoidRootPart") and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
            end
            task.wait(getgenv().delayTime)
        end
    end)
end
