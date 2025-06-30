-- moseerihub.lua

-- เรียก Rayfield (Sirius)
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- สร้างหน้าต่างหลัก
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

-- ข้อความแจ้งตอนโหลดเสร็จ
Rayfield:Notify({
   Title = "Welcome!",
   Content = "Moseeri Hub Loaded",
   Duration = 4,
   Image = 13047715178,
   Actions = {
      Okay = { Name = "Close", Callback = function() print("User accepted") end }
   }
})

-- // Tab: Auto Farm
local Tab = Window:CreateTab("🏹 Auto Farm")
local Section = Tab:CreateSection("Farming Control")

-- Global vars
getgenv().autoFarm = false
getgenv().selectedMob = ""
getgenv().delay = 0.1

-- เก็บรายชื่อม็อบจาก Workspace
local mobs = {}
for _, v in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
    if not table.find(mobs, v.Name) then
        table.insert(mobs, v.Name)
    end
end

-- Dropdown: เลือกม็อบ
Section:CreateDropdown({
   Name = "Select Mob",
   Options = mobs,
   CurrentOption = mobs[1],
   Callback = function(option)
      getgenv().selectedMob = option
   end,
})

-- Slider: กำหนด Delay
Section:CreateSlider({
   Name = "Delay Between Warps",
   Range = {0.05, 1},
   Increment = 0.05,
   Suffix = "Sec",
   CurrentValue = 0.1,
   Callback = function(value)
      getgenv().delay = value
   end,
})

-- Toggle: เปิด/ปิด AutoFarm
Section:CreateToggle({
   Name = "Enable Auto Farm",
   CurrentValue = false,
   Callback = function(state)
      getgenv().autoFarm = state
      if state then
         -- เริ่มฟังก์ชัน AutoFarm
         spawn(function()
            while getgenv().autoFarm do
               local mob = workspace.Monster.Mon:FindFirstChild(getgenv().selectedMob)
               if mob and mob:FindFirstChild("HumanoidRootPart") then
                  local plr = game.Players.LocalPlayer
                  plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
               end
               task.wait(getgenv().delay)
            end
         end)
      end
   end,
})
