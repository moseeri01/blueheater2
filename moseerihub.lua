local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "Please enter your key",
    ConfigurationSaving = { Enabled = true, FolderName = nil, FileName = "MoseeriHub" },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Grab it from Discord",
        Note = "https://discord.gg/uGX2X3WvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
    }
})

-- ดึงชื่อมอนสเตอร์มาทำ dropdown
local mobs = {}
for _, m in pairs(workspace.Monster.Mon:GetChildren()) do
  if not table.find(mobs, m.Name) then
    table.insert(mobs, m.Name)
  end
end

-- ตั้งค่าเริ่มต้น
getgenv().autoFarm    = false
getgenv().selectedMob = mobs[1] or ""
getgenv().farmDelay   = 0.1

-- ────────────────
-- Main Features Tab
-- ────────────────
local TabMain     = Window:CreateTab("Main Features", 4483345998)
local SectionFarm = TabMain:CreateSection("Auto Farming")

-- Dropdown เลือกมอน
SectionFarm:CreateDropdown({
  Name = "Select Mob",
  Options = mobs,
  CurrentOption = getgenv().selectedMob,
  Flag = "FarmMob",
  Callback = function(opt)
    getgenv().selectedMob = opt
  end
})

-- Slider ตั้ง Delay
SectionFarm:CreateSlider({
  Name = "Delay Between Warps",
  Range = {0.05, 1},
  Increment = 0.05,
  Suffix = "s",
  CurrentValue = getgenv().farmDelay,
  Flag = "FarmDelay",
  Callback = function(val)
    getgenv().farmDelay = val
  end
})

-- **Toggle “Enable Auto Farm”**  ← นี่คือปุ่มหลักที่ต้องสร้าง
SectionFarm:CreateToggle({
  Name = "Enable Auto Farm",
  CurrentValue = getgenv().autoFarm,
  Flag = "ToggleAutoFarm",
  Callback = function(val)
    getgenv().autoFarm = val
    if val then
      spawn(function()
        while getgenv().autoFarm do
          local mob = workspace.Monster.Mon:FindFirstChild(getgenv().selectedMob)
          if mob and mob:FindFirstChild("HumanoidRootPart") then
            local plr = game.Players.LocalPlayer
            plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
          end
          task.wait(getgenv().farmDelay)
        end
      end)
    end
  end
})
