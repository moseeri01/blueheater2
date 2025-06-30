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

-- 3️⃣ แจ้งเตือนตอนโหลดเสร็จ
Rayfield:Notify({
   Title = "Welcome!",
   Content = "Moseeri Hub Loaded",
   Duration = 4,
   Image = 13047715178,
   Actions = {
      Okay = { Name = "Close", Callback = function() print("User accepted") end }
   }
})

-- 4️⃣ สร้าง Tab + Section สำหรับ Auto Farm
local Tab = Window:CreateTab("🏹 Auto Farm")
local Section = Tab:CreateSection("Farming Control")

-- 5️⃣ เก็บตัวแปร global
getgenv().autoFarm     = false
getgenv().selectedMob  = nil
getgenv().warpDelay    = 0.1

-- 6️⃣ หาโฟลเดอร์ม็อบใน Workspace (ปรับชื่อโฟลเดอร์ตามเกมจริงของคุณ)
local workspace = game:GetService("Workspace")
local monRoot = workspace:WaitForChild("Monster", 10)        -- รอ Monster folder
if not monRoot then
    warn("❌ ไม่พบโฟลเดอร์ Monster ใน Workspace")
    return
end
local monFolder = monRoot:WaitForChild("Mon", 10)            -- รอ Mon subfolder
if not monFolder then
    warn("❌ ไม่พบโฟลเดอร์ Mon ภายใน Monster")
    return
end

-- 7️⃣ เตรียมอาร์เรย์ชื่อม็อบ
local mobs = {}
local function refreshMobs()
    table.clear(mobs)
    for _, m in ipairs(monFolder:GetChildren()) do
        if not table.find(mobs, m.Name) then
            table.insert(mobs, m.Name)
        end
    end
    dropdown:Refresh(mobs)
end
refreshMobs()
monFolder.ChildAdded:Connect(refreshMobs)
monFolder.ChildRemoved:Connect(refreshMobs)

-- 8️⃣ สร้าง Dropdown ให้เลือกม็อบ
local dropdown = Section:CreateDropdown({
   Name = "Select Mob",
   Options = mobs,
   CurrentOption = mobs[1],
   Callback = function(opt)
      getgenv().selectedMob = opt
   end,
})

-- 9️⃣ สร้าง Slider ให้ปรับ Delay
Section:CreateSlider({
   Name = "Warp Delay",
   Range = {0.05, 1},
   Increment = 0.05,
   Suffix = "s",
   CurrentValue = getgenv().warpDelay,
   Callback = function(v)
      getgenv().warpDelay = v
   end,
})

-- 🔟 สร้าง Toggle เริ่ม/หยุด Auto Farm
Section:CreateToggle({
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
                      plr.Character.HumanoidRootPart.CFrame = 
                        mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                  end
                  task.wait(getgenv().warpDelay)
              end
          end)
      end
   end,
})
