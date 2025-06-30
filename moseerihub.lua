-- Loader + KeySystem + UI
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "by Amira",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = true,   -- เปิดระบบกรอก Key
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

-- แจ้งเตือนตอนโหลดเสร็จ
Rayfield:Notify({
   Title = "✅ Loaded",
   Content = "Welcome to Moseeri Hub!",
   Duration = 4,
   Image = 13047715178,
   Actions = {
      Close = {
         Name = "Close",
         Callback = function() end
      }
   }
})

-- Global vars
getgenv().autoFarm    = false
getgenv().selectedMob = ""
getgenv().farmDelay   = 0.1

-- เตรียม list มอนสเตอร์
local mobs = {}
for _, m in pairs(workspace:WaitForChild("Monster"):WaitForChild("Mon"):GetChildren()) do
    if not table.find(mobs, m.Name) then
        table.insert(mobs, m.Name)
    end
end
getgenv().selectedMob = mobs[1] or ""

-- ==== Main Features Tab ====
local MainTab     = Window:CreateTab("🏠 Main Features", 4483345998)
local FarmSection = MainTab:CreateSection("🔸 AutoFarm Control")

-- 1) Dropdown เลือกมอน
FarmSection:CreateDropdown({
    Name = "Select Mob",
    Options = mobs,
    CurrentOption = getgenv().selectedMob,
    Flag = "Farm_Mob",
    Callback = function(opt)
        getgenv().selectedMob = opt
    end,
})

-- 2) Slider ตั้ง Delay ระหว่าง warp
FarmSection:CreateSlider({
    Name = "Warp Delay",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = getgenv().farmDelay,
    Flag = "Farm_Delay",
    Callback = function(val)
        getgenv().farmDelay = val
    end,
})

-- 3) Toggle เปิด/ปิด AutoFarm
FarmSection:CreateToggle({
    Name = "Enable Auto Farm",
    CurrentValue = getgenv().autoFarm,
    Flag = "Toggle_AutoFarm",
    Callback = function(val)
        getgenv().autoFarm = val
        if val then
            spawn(function()
                while getgenv().autoFarm do
                    local world = workspace:FindFirstChild("Monster")
                    if world and world:FindFirstChild("Mon") then
                        local mob = world.Mon:FindFirstChild(getgenv().selectedMob)
                        if mob and mob:FindFirstChild("HumanoidRootPart") then
                            local plr = game.Players.LocalPlayer
                            plr.Character.HumanoidRootPart.CFrame =
                                mob.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
                        end
                    end
                    task.wait(getgenv().farmDelay)
                end
            end)
        end
    end,
})

-- ==== Optional: เพิ่ม Toggle อื่นๆ ตามต้องการ ====
--[[ 
FarmSection:CreateToggle({ Name = "Enable Chest Farm", ... })
-- etc
]]--
