local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Auto Farm Example",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = false
})

local MainTab = Window:CreateTab("Auto Farm")
local FarmSection = MainTab:CreateSection("Main Farming")

-- ตัวแปรและชื่อมอน
local mobs = {}
getgenv().selectedMob = nil
getgenv().autofarm = false

-- อัปเดตชื่อมอนใน Workspace
for _, v in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

-- Dropdown ให้เลือกมอน
FarmSection:CreateDropdown({
    Name = "Select Mob",
    Options = mobs,
    CurrentOption = mobs[1],
    Callback = function(Option)
        getgenv().selectedMob = Option
    end
})

-- ปุ่ม Toggle ฟาร์ม
FarmSection:CreateToggle({
    Name = "Start Auto Farm",
    CurrentValue = false,
    Callback = function(value)
        getgenv().autofarm = value
        if value then
            AutoFarm()
        end
    end,
})

-- ฟังก์ชัน Auto Farm
function AutoFarm()
    spawn(function()
        while getgenv().autofarm do
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob)
            if mob and mob:FindFirstChild("HumanoidRootPart") then
                local plr = game.Players.LocalPlayer
                plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
            end
            task.wait(0.1)
        end
    end)
end
