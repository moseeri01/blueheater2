-- moseerihub.lua
-- 1️⃣ เรียกไลบรารี Rayfield
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- 2️⃣ สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
   Name = "🔥 Moseeri Hub",
   LoadingTitle = "Loading Moseeri Hub...",
   LoadingSubtitle = "Auto Farm System",
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil,
      FileName = "MoseeriHubConfig"
   },
   Discord = {
      Enabled = false,
   },
   KeySystem = true,
   KeySettings = {
      Title = "Moseeri Key",
      Subtitle = "Get your key from Discord",
      Note = "https://discord.gg/uGX2X3xWvY",
      FileName = "MoseeriKey",
      SaveKey = true,
      GrabKeyFromSite = true,
      Key = {
         "https://raw.githubusercontent.com/moseeri01/key/main/key.txt"
      }
   }
})

-- 3️⃣ แจ้งเตือนเมื่อโหลดเสร็จ
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

-- 4️⃣ สร้างแท็บ Home
local HomeTab = Window:CreateTab("🏠 Home", nil)
local HomeSection = HomeTab:CreateSection("Main")

HomeSection:CreateLabel("Welcome to Moseeri Hub!")

-- ปุ่ม Rejoin Server
HomeSection:CreateButton({
   Name = "Rejoin Server",
   Callback = function()
      game:GetService("TeleportService"):Teleport(game.PlaceId)
   end,
})

-- ปุ่ม Destroy GUI
HomeSection:CreateButton({
   Name = "Destroy GUI",
   Callback = function()
      Rayfield:Destroy()
   end,
})

-- 5️⃣ สร้างแท็บ Teleports
local TP = Window:CreateTab("🏝 Teleports", nil)
local TPsec = TP:CreateSection("Maps")

TPsec:CreateButton({ Name = "Starter Island", Callback = function()
   local plr = game.Players.LocalPlayer
   plr.Character:SetPrimaryPartCFrame(CFrame.new(0,10,0))
end })
TPsec:CreateButton({ Name = "Pirate Island", Callback = function()
   local plr = game.Players.LocalPlayer
   plr.Character:SetPrimaryPartCFrame(CFrame.new(100,10,0))
end })
TPsec:CreateButton({ Name = "Pineapple Paradise", Callback = function()
   local plr = game.Players.LocalPlayer
   plr.Character:SetPrimaryPartCFrame(CFrame.new(200,10,0))
end })

-- 6️⃣ สร้างแท็บ Auto Farm
local AF = Window:CreateTab("🏹 Auto Farm", nil)
local AFsec = AF:CreateSection("Farming Control")

-- ตัวแปร global
getgenv().autoFarm    = false
getgenv().selectedMob = nil
getgenv().delayWarp   = 0.1

-- หาโฟลเดอร์ม็อบใน Workspace (ตรวจสอบชื่อจริงในเกม)
local monContainer = workspace:WaitForChild("Monster", 5)
if not monContainer then warn("❌ ไม่พบโฟลเดอร์ Monster") return end
local monFolder = monContainer:WaitForChild("Mon", 5)
if not monFolder then warn("❌ ไม่พบโฟลเดอร์ Mon") return end

-- เตรียมชื่อม็อบ
local mobList = {}
local function updateMobs()
   table.clear(mobList)
   for _, m in ipairs(monFolder:GetChildren()) do
      if not table.find(mobList, m.Name) then
         table.insert(mobList, m.Name)
      end
   end
   dropdown:Refresh(mobList)
end
updateMobs()
monFolder.ChildAdded:Connect(updateMobs)
monFolder.ChildRemoved:Connect(updateMobs)

-- Dropdown เลือกม็อบ
local dropdown = AFsec:CreateDropdown({
   Name = "Select Mob",
   Options = mobList,
   CurrentOption = mobList[1],
   Callback = function(opt)
      getgenv().selectedMob = opt
   end,
})

-- ปุ่ม Refresh Mob List
AFsec:CreateButton({
   Name = "Refresh Mob List",
   Callback = function()
      updateMobs()
      Rayfield:Notify({
         Title = "Refreshed",
         Content = "Mob list has been updated",
         Duration = 2
      })
   end,
})

-- Slider ปรับดีเลย์
AFsec:CreateSlider({
   Name = "Warp Delay",
   Range = {0.05, 1},
   Increment = 0.05,
   Suffix = "s",
   CurrentValue = getgenv().delayWarp,
   Callback = function(v)
      getgenv().delayWarp = v
   end,
})

-- Toggle เริ่ม/หยุด
AFsec:CreateToggle({
   Name = "Enable Auto Farm",
   CurrentValue = false,
   Callback = function(val)
      getgenv().autoFarm = val
      if val then
         spawn(function()
            while getgenv().autoFarm do
               local mob = monFolder:FindFirstChild(getgenv().selectedMob)
               if mob and mob:FindFirstChild("HumanoidRootPart") then
                  local plr = game.Players.LocalPlayer
                  plr.Character:SetPrimaryPartCFrame(
                     mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                  )
               end
               task.wait(getgenv().delayWarp)
            end
         end)
      end
   end,
})
