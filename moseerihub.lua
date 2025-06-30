-- โหลด Rayfield
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

-- ขั้นตอนที่ 1: สร้างหน้าต่าง UI
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

-- ขั้นตอนที่ 2: สร้าง Tab สำหรับ Auto Farm
local AutoFarmTab = Window:CreateTab("📦 Auto Farm")
local FarmSection = AutoFarmTab:CreateSection("ตั้งค่าฟาร์ม")

-- ขั้นตอนที่ 3: Dropdown สำหรับเลือกมอนสเตอร์
local mobs = {}
getgenv().selectedMob = nil
getgenv().autofarm = false
getgenv().farmDelay = 0.1

for _, v in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
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

-- ตัวเลื่อนปรับความหน่วงของการตี
FarmSection:CreateSlider({
    Name = "ดีเลย์การตี (วินาที)",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = 0.1,
    Callback = function(Value)
        getgenv().farmDelay = Value
    end
})

-- ขั้นตอนที่ 4: Toggle เปิด/ปิด Auto Farm
FarmSection:CreateToggle({
    Name = "เปิด Auto Farm",
    CurrentValue = false,
    Callback = function(value)
        getgenv().autofarm = value
        if value then
            AutoFarm()
        end
    end
})

-- ขั้นตอนที่ 5: ฟังก์ชัน AutoFarm
function AutoFarm()
    spawn(function()
        while getgenv().autofarm do
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob)
            if mob and mob:FindFirstChild("HumanoidRootPart") then
                local plr = game.Players.LocalPlayer
                plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
                -- ใส่การโจมตีแบบคลิกจำลอง
                game:GetService("VirtualUser"):Button1Down(Vector2.new(0, 0))
            end
            task.wait(getgenv().farmDelay)
        end
    end)
end
