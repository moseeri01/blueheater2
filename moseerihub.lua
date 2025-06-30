local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "กำลังโหลด...",
    LoadingSubtitle = "Auto Farm",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = false
})

local AutoFarmTab = Window:CreateTab("📦 Auto Farm")
local FarmSection = AutoFarmTab:CreateSection("ตั้งค่าฟาร์ม")

-- ✅ ตัวแปร
getgenv().autofarm = false
getgenv().selectedMob = nil
getgenv().farmDelay = 0.1

task.wait(1) -- สำคัญ!! เพื่อให้ UI โหลดเสร็จก่อน

-- ✅ ดึงชื่อมอน
local mobs = {}
local mobFolder = game:GetService("Workspace"):FindFirstChild("Monster") and game:GetService("Workspace").Monster:FindFirstChild("Mon")

if mobFolder then
    for _, v in pairs(mobFolder:GetChildren()) do
        if not table.find(mobs, v.Name) then
            table.insert(mobs, v.Name)
        end
    end
else
    warn("❌ ไม่พบ Workspace.Monster.Mon")
end

-- ✅ Dropdown
FarmSection:CreateDropdown({
    Name = "เลือกมอนสเตอร์",
    Options = mobs,
    CurrentOption = mobs[1] or "None",
    Callback = function(option)
        getgenv().selectedMob = option
    end
})

-- ✅ Slider
FarmSection:CreateSlider({
    Name = "ดีเลย์การตี (วินาที)",
    Range = {0.05, 1},
    Increment = 0.05,
    CurrentValue = 0.1,
    Callback = function(val)
        getgenv().farmDelay = val
    end
})

-- ✅ Toggle
FarmSection:CreateToggle({
    Name = "เริ่ม Auto Farm",
    CurrentValue = false,
    Callback = function(value)
        getgenv().autofarm = value
        if value then
            AutoFarm()
        end
    end
})

-- ✅ ฟังก์ชัน Auto Farm
function AutoFarm()
    spawn(function()
        while getgenv().autofarm do
            local mob = mobFolder and mobFolder:FindFirstChild(getgenv().selectedMob)
            if mob and mob:FindFirstChild("HumanoidRootPart") then
                local hrp = game.Players.LocalPlayer.Character.HumanoidRootPart
                hrp.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
            end
            task.wait(getgenv().farmDelay)
        end
    end)
end
