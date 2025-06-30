local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
   Name = "Moseeri Hub",
   LoadingTitle = "Loading...",
   LoadingSubtitle = "By Amira",
   ConfigurationSaving = { Enabled = true, FolderName = nil, FileName = "MoseeriHub" },
   KeySystem = true,
   KeySettings = {
      Title = "Moseeri Key",
      Subtitle = "Get your key from Discord",
      Note = "https://discord.gg/uGX2X3Wv",
      FileName = "MoseeriKey",
      SaveKey = true,
      GrabKeyFromSite = true,
      Key = {"https://raw.githubusercontent.com/USERNAME/REPO/main/key.txt"}
   }
})

Rayfield:Notify({Title="Welcome!", Content="Moseeri Hub loaded", Duration=5})

-- ต่อด้วยฟังก์ชัน AutoFarm:
local MainTab = Window:CreateTab("Auto Farm")
local FarmSection = MainTab:CreateSection("ตั้งค่าฟาร์ม")

local mobs = {}
for _, v in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
    table.insert(mobs, v.Name)
end
local selectedMob = mobs[1]
local autofarm = false
local delayTime = 0.1

FarmSection:CreateDropdown({
    Name = "เลือกมอนสเตอร์",
    Options = mobs,
    CurrentOption = selectedMob,
    Flag = "MobSelect",
    Callback = function(opt) selectedMob = opt end
})

FarmSection:CreateSlider({
    Name = "Delay (วิบัติ)",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = "วินาที",
    CurrentValue = delayTime,
    Flag = "DelayTime",
    Callback = function(val) delayTime = val end
})

FarmSection:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Flag = "AutoFarmToggle",
    Callback = function(val)
        autofarm = val
        if autofarm then
            spawn(function()
                while autofarm do
                    local mob = workspace.Monster.Mon:FindFirstChild(selectedMob)
                    if mob and mob:FindFirstChild("HumanoidRootPart") then
                        local hrp = game.Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                        if hrp then
                            hrp.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                        end
                    end
                    task.wait(delayTime)
                end
            end)
        end
    end
})
