local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "กำลังโหลด...",
    LoadingSubtitle = "ระบบ Auto Farm",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = false
})

-- ✅ TAB และ SECTION
local AutoFarmTab = Window:CreateTab("📦 Auto Farm", 4483362458) -- icon optional
local FarmSection = AutoFarmTab:CreateSection("ตั้งค่าฟาร์ม")

-- ✅ ตัวแปรใช้งาน
getgenv().autofarm = false
getgenv().selectedMob = nil
getgenv().farmDelay = 0.1

-- ✅ สร้าง Dropdown มอนสเตอร์
local mobs = {}
for _, v in pairs(game:GetService("Workspace"):WaitForChild("Monster"):WaitForChild("Mon"):GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

FarmSection:CreateDropdown({
    Name = "เลือกมอนสเตอร์",
    Options = mobs,
    CurrentOption = mobs[1],
    Callback = function(option)
        getgenv().selectedMob = option
    end
})

-- ✅ สร้าง Slider ตั้งค่าหน่วง
FarmSection:CreateSlider({
    Name = "ดีเลย์การตี (วินาที)",
    Range = {0.05, 1},
    Increment = 0.05,
    CurrentValue = 0.1,
    Callback = function(val)
        getgenv().farmDelay = val
    end
})

-- ✅ Toggle เปิด/ปิด AutoFarm
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

-- ✅ ฟังก์ชัน AutoFarm
function AutoFarm()
    spawn(function()
        while getgenv().autofarm do
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob)
            if mob and mob:FindFirstChild("HumanoidRootPart") then
                local player = game.Players.LocalPlayer
                player.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
                -- ถ้ามีระบบโจมตีอัตโนมัติแบบกด
                game:GetService("VirtualUser"):Button1Down(Vector2.new(0, 0))
            end
            task.wait(getgenv().farmDelay)
        end
    end)
end
