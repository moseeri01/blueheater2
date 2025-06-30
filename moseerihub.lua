-- moseerihub.lua

-- 1️⃣ เรียกไลบรารี Rayfield จาก Sirius
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- 2️⃣ สร้างหน้าต่างหลัก พร้อมระบบ KeySystem ดึงจาก key.txt ใน repo
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Auto Farm System",
    ConfigurationSaving = { Enabled = true, FolderName = nil, FileName = "MoseeriHub" },
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
-- 2) แจ้งเตือนเมื่อโหลดเสร็จ
Rayfield:Notify({
    Title = "Welcome!",
    Content = "Moseeri Hub Loaded",
    Duration = 4,
    Image = 13047715178,
    Actions = {
        Okay = { Name = "Close", Callback = function() print("User accepted") end }
    }
})

-- 3) แท็บ Home
local HomeTab     = Window:CreateTab("🏠 Home", nil)
local HomeSection = HomeTab:CreateSection("Main")

HomeSection:CreateLabel("Welcome to Moseeri Hub!")
HomeSection:CreateButton({
    Name = "Rejoin Server",
    Callback = function()
        game:GetService("TeleportService"):Teleport(game.PlaceId)
    end
})

-- 4) แท็บ Teleports
local TP    = Window:CreateTab("🏝 Teleports", nil)
local TPsec = TP:CreateSection("Maps")

TPsec:CreateButton({ Name = "Starter Island",    Callback = function() /* โค้ดวาร์ป */ end })
TPsec:CreateButton({ Name = "Pirate Island",     Callback = function() /* โค้ดวาร์ป */ end })
TPsec:CreateButton({ Name = "Pineapple Paradise", Callback = function() /* โค้ดวาร์ป */ end })

-- 5) แท็บ Auto Farm
local AF    = Window:CreateTab("🏹 Auto Farm", nil)
local AFsec = AF:CreateSection("Farming Control")

-- 🔸 ตัวแปรควบคุม
getgenv().autoFarm    = false
getgenv().selectedMob = nil
getgenv().delayWarp   = 0.1

-- 🔸 โฟลเดอร์ม็อบ
local monFolder = workspace:WaitForChild("Monster",5):WaitForChild("Mon",5)
if not monFolder then
    warn("❌ ไม่พบ Monster.Mon ใน workspace")
    return
end

-- 🔸 เตรียมรายชื่อม็อบเบื้องต้น
local mobList = {}
for _, m in ipairs(monFolder:GetChildren()) do
    table.insert(mobList, m.Name)
end

-- 🔸 สร้าง Dropdown ให้เลือกม็อบ
local dropdown = AFsec:CreateDropdown({
    Name          = "Select Mob",
    Options       = mobList,
    CurrentOption = mobList[1],
    Callback      = function(option)
        getgenv().selectedMob = option
    end
})

-- 🔸 ฟังก์ชันอัปเดตรายชื่อม็อบอัตโนมัติ
local function updateMobs()
    local newList = {}
    for _, m in ipairs(monFolder:GetChildren()) do
        table.insert(newList, m.Name)
    end
    dropdown:Refresh(newList)
end

-- เรียกครั้งแรก + ผูกอีเวนต์
updateMobs()
monFolder.ChildAdded:Connect(updateMobs)
monFolder.ChildRemoved:Connect(updateMobs)

-- 🔸 Slider ปรับ Delay ระหว่างวาร์ป
AFsec:CreateSlider({
    Name         = "Warp Delay",
    Range        = {0.05, 1},
    Increment    = 0.05,
    Suffix       = "s",
    CurrentValue = getgenv().delayWarp,
    Callback     = function(v)
        getgenv().delayWarp = v
    end,
})

-- 🔸 Toggle เปิด/ปิด Auto Farm
AFsec:CreateToggle({
    Name         = "Enable Auto Farm",
    CurrentValue = false,
    Callback     = function(val)
        getgenv().autoFarm = val
        if val then
            spawn(function()
                while getgenv().autoFarm do
                    local mob = monFolder:FindFirstChild(getgenv().selectedMob)
                    if mob and mob:FindFirstChild("HumanoidRootPart") then
                        local plr = game.Players.LocalPlayer
                        if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                            plr.Character.HumanoidRootPart.CFrame =
                                mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                        end
                    end
                    task.wait(getgenv().delayWarp)
                end
            end)
        end
    end,
})
