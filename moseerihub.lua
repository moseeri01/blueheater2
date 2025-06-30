-- โหลด Rayfield GUI
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

-- สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Auto Farm System",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "MoseeriHub",
        FileName = "Settings"
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

-- แจ้งเตือนตอนเริ่ม
Rayfield:Notify({
   Title = "Welcome!",
   Content = "Moseeri Hub Loaded",
   Duration = 4,
   Image = 13047715178,
   Actions = {
      Okay = {
         Name = "Close",
         Callback = function() print("User accepted") end
      }
   }
})

-- สร้าง Tab “Auto Farm”
local Tab = Window:CreateTab("🏹 Auto Farm")
local Section = Tab:CreateSection("Farming Control")

-- ตัวแปร global สำหรับควบคุม AutoFarm
getgenv().autoFarm = false
getgenv().selectedMob = ""
getgenv().delay = 0.1

-- รวบรวมชื่อมอนจาก Workspace
local mobs = {}
for _, v in ipairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

-- Dropdown เลือกมอน
Section:CreateDropdown({
    Name = "Select Mob",
    Options = mobs,
    CurrentOption = mobs[1] or "",
    Flag = "SelectMob",
    Callback = function(Option)
        getgenv().selectedMob = Option
    end
})

-- Slider ตั้งค่า Delay
Section:CreateSlider({
    Name = "Delay Between Warps",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = " sec",
    CurrentValue = getgenv().delay,
    Flag = "WarpDelay",
    Callback = function(Value)
        getgenv().delay = Value
    end
})

-- Toggle ปุ่มเปิด/ปิด Auto Farm
Section:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Flag = "ToggleAutoFarm",
    Callback = function(Value)
        getgenv().autoFarm = Value
        if Value then AutoFarm() end
    end
})

-- ฟังก์ชัน AutoFarm
function AutoFarm()
    spawn(function()
        while getgenv().autoFarm do
            local mob = game:GetService("Workspace").Monster.Mon:FindFirstChild(getgenv().selectedMob)
            if mob and mob:FindFirstChild("HumanoidRootPart") then
                local plr = game.Players.LocalPlayer
                plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
            end
            task.wait(getgenv().delay)
        end
    end)
end
