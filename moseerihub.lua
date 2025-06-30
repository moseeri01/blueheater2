local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
   Name = "Moseeri Hub",
   LoadingTitle = "Loading...",
   LoadingSubtitle = "Auto Farm System",
   ConfigurationSaving = {
      Enabled = true,
      FolderName = "Moseeri",
      FileName = "HubData"
   },
KeySystem = true,
KeySettings = {
   Title = "Moseeri Key",
   Subtitle = "Get your key from Discord",
   Note = "https://discord.gg/uGX2X3xWv",
   FileName = "MoseeriKey",
   SaveKey = true,
   GrabKeyFromSite = true,
   Key = {"https://raw.githubusercontent.com/moseeri01/blueheater2/main/key.txt"}
}

})

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

-- Section: Auto Farm
local Tab = Window:CreateTab("🏹 Auto Farm")
local Section = Tab:CreateSection("Farming Control")

getgenv().autoFarm = false
getgenv().selectedMob = ""
getgenv().delay = 0.1

-- Dropdown
local mobs = {}
for _, v in pairs(game:GetService("Workspace").Monster.Mon:GetChildren()) do
   if not table.find(mobs, v.Name) then
      table.insert(mobs, v.Name)
   end
end

Section:CreateDropdown({
   Name = "Select Mob",
   Options = mobs,
   CurrentOption = mobs[1],
   Callback = function(Option)
      getgenv().selectedMob = Option
   end,
})

-- Delay Slider
Section:CreateSlider({
   Name = "Delay Between Warps",
   Range = {0.05, 1},
   Increment = 0.05,
   Suffix = "Sec",
   CurrentValue = 0.1,
   Callback = function(Value)
      getgenv().delay = Value
   end,
})

-- Toggle AutoFarm
Section:CreateToggle({
   Name = "Auto Farm",
   CurrentValue = false,
   Callback = function(Value)
      getgenv().autoFarm = Value
      if Value then
         AutoFarm()
      end
   end,
})

-- Farming Function
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
