-- 🌐 โหลด Rayfield UI
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- 🪟 สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
    Name = "👑 Moseeri Hub",
    LoadingTitle = "Loading Moseeri Hub...",
    LoadingSubtitle = "Made by Moseeri",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    Discord = {
        Enabled = false
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Hub Key",
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

-- ✅ แท็บ Home
local MainTab = Window:CreateTab("🏠 Home", nil)
local MainSection = MainTab:CreateSection("Main Controls")

Rayfield:Notify({
   Title = "You executed the script",
   Content = "Very cool gui",
   Duration = 5,
   Image = 13047715178,
   Actions = {
      Ignore = {
         Name = "Okay!",
         Callback = function()
            print("The user tapped Okay!")
         end
      },
   },
})

MainTab:CreateButton({
   Name = "Infinite Jump Toggle",
   Callback = function()
      _G.infinjump = not _G.infinjump
      if _G.infinJumpStarted == nil then
         _G.infinJumpStarted = true
         game.StarterGui:SetCore("SendNotification", {Title="Youtube Hub", Text="Infinite Jump Activated!", Duration=5})
         local plr = game:GetService('Players').LocalPlayer
         local m = plr:GetMouse()
         m.KeyDown:connect(function(k)
            if _G.infinjump then
               if k:byte() == 32 then
                  local humanoid = game:GetService("Players").LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                  humanoid:ChangeState("Jumping")
                  wait()
                  humanoid:ChangeState("Seated")
               end
            end
         end)
      end
   end,
})

MainTab:CreateSlider({
   Name = "WalkSpeed Slider",
   Range = {1, 350},
   Increment = 1,
   Suffix = "Speed",
   CurrentValue = 16,
   Flag = "sliderws",
   Callback = function(Value)
      game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = Value
   end,
})

MainTab:CreateSlider({
   Name = "JumpPower Slider",
   Range = {1, 350},
   Increment = 1,
   Suffix = "Jump",
   CurrentValue = 50,
   Flag = "sliderjp",
   Callback = function(Value)
      game.Players.LocalPlayer.Character.Humanoid.JumpPower = Value
   end,
})

MainTab:CreateDropdown({
   Name = "Select Area",
   Options = {"Starter World", "Pirate Island", "Pineapple Paradise"},
   CurrentOption = {"Starter World"},
   MultipleOptions = false,
   Flag = "dropdownarea",
   Callback = function(Option)
      print("Selected Area: "..Option)
   end,
})

MainTab:CreateInput({
   Name = "Walkspeed (Input)",
   PlaceholderText = "1-500",
   RemoveTextAfterFocusLost = true,
   Callback = function(Text)
      local speed = tonumber(Text)
      if speed then
         game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = speed
      end
   end,
})

MainTab:CreateSection("Other")

MainTab:CreateToggle({
   Name = "Auto Farm",
   CurrentValue = false,
   Flag = "ToggleAutoFarm",
   Callback = function(Value)
      print("Auto Farm:", Value)
   end,
})

-- 🏝 แท็บ Teleports
local TPTab = Window:CreateTab("🏝 Teleports", nil)

TPTab:CreateButton({
   Name = "Starter Island",
   Callback = function()
      game.Players.LocalPlayer.Character:PivotTo(CFrame.new(0, 10, 0))
   end,
})

TPTab:CreateButton({
   Name = "Pirate Island",
   Callback = function()
      game.Players.LocalPlayer.Character:PivotTo(CFrame.new(100, 10, 0))
   end,
})

TPTab:CreateButton({
   Name = "Pineapple Paradise",
   Callback = function()
      game.Players.LocalPlayer.Character:PivotTo(CFrame.new(200, 10, 0))
   end,
})

-- 🎲 แท็บ Misc (ถ้ายังไม่ได้ใช้งาน ก็ยังไม่ต้องใส่)
-- local MiscTab = Window:CreateTab("🎲 Misc", nil)
