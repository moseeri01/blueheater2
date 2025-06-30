-- เรียก Rayfield (Sirius)
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- สร้างหน้าต่างหลัก
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Moseeri Hub",
    LoadingSubtitle = "by Moseeri",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Get your key from Discord",
        Note = "https://discord.gg/uGX2X3xWvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = { "https://raw.githubusercontent.com/moseeri01/key/main/key.txt" }
    }
})

-- แจ้งเตือนเมื่อโหลดเสร็จ
Rayfield:Notify({
    Title = "You executed the script",
    Content = "Very cool GUI",
    Duration = 5,
    Image = 13047715178,
    Actions = {
        Ignore = {
            Name = "Okay!",
            Callback = function()
                print("The user tapped Okay!")
            end
        }
    }
})


----------------------------------------
-- Tab: 🏠 Home
----------------------------------------
local HomeTab     = Window:CreateTab("🏠 Home", nil)
local MainSection = HomeTab:CreateSection("Main")

-- ปุ่ม Infinite Jump Toggle
MainSection:CreateButton({
    Name = "Infinite Jump Toggle",
    Callback = function()
        _G.infinjump = not _G.infinjump

        if not _G.infinJumpStarted then
            _G.infinJumpStarted = true
            game.StarterGui:SetCore("SendNotification", {
                Title = "Youtube Hub",
                Text = "Infinite Jump Activated!",
                Duration = 5
            })
            local plr = game:GetService("Players").LocalPlayer
            plr:GetMouse().KeyDown:Connect(function(k)
                if _G.infinjump and k:byte() == 32 then
                    local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
                    if h then
                        h:ChangeState("Jumping")
                        task.wait()
                        h:ChangeState("Seated")
                    end
                end
            end)
        end
    end,
})

-- Slider: WalkSpeed
MainSection:CreateSlider({
    Name = "WalkSpeed Slider",
    Range = {1, 350},
    Increment = 1,
    Suffix = "Speed",
    CurrentValue = 16,
    Flag = "sliderws",
    Callback = function(Value)
        local char = game.Players.LocalPlayer.Character
        if char then char.Humanoid.WalkSpeed = Value end
    end,
})

-- Slider: JumpPower
MainSection:CreateSlider({
    Name = "JumpPower Slider",
    Range = {1, 350},
    Increment = 1,
    Suffix = "Power",
    CurrentValue = 50,
    Flag = "sliderjp",
    Callback = function(Value)
        local char = game.Players.LocalPlayer.Character
        if char then char.Humanoid.JumpPower = Value end
    end,
})

-- Dropdown: Select Area
MainSection:CreateDropdown({
    Name = "Select Area",
    Options = {"Starter World", "Pirate Island", "Pineapple Paradise"},
    CurrentOption = "Starter World",
    MultipleOptions = false,
    Flag = "dropdownarea",
    Callback = function(Option)
        print("Selected Area:", Option)
        -- ตัวอย่าง: Teleport ไปยังโซนที่เลือก
        -- local spawn = workspace:FindFirstChild(Option.."Spawn")
        -- if spawn then
        --     game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        -- end
    end,
})

-- Input: Walkspeed
MainSection:CreateInput({
    Name = "Walkspeed",
    PlaceholderText = "1-500",
    RemoveTextAfterFocusLost = true,
    Callback = function(Text)
        local v = tonumber(Text)
        if v then
            local char = game.Players.LocalPlayer.Character
            if char then char.Humanoid.WalkSpeed = v end
        end
    end,
})

-- Section: Other
local OtherSection = MainSection -- หรือ HomeTab:CreateSection("Other")
OtherSection:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Flag = "Toggle1",
    Callback = function(Value)
        print("Farming:", Value)
        -- เรียกฟังก์ชัน Auto Farm ของคุณตรงนี้
    end,
})


----------------------------------------
-- Tab: 🏝 Teleports
----------------------------------------
local TPTab = Window:CreateTab("🏝 Teleports", nil)

TPTab:CreateButton({
    Name = "Starter Island",
    Callback = function()
        -- Teleport1
        local spawn = workspace:FindFirstChild("StarterIslandSpawn")
        if spawn then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        end
    end,
})

TPTab:CreateButton({
    Name = "Pirate Island",
    Callback = function()
        -- Teleport2
        local spawn = workspace:FindFirstChild("PirateIslandSpawn")
        if spawn then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        end
    end,
})

TPTab:CreateButton({
    Name = "Pineapple Paradise",
    Callback = function()
        -- Teleport3
        local spawn = workspace:FindFirstChild("PineappleParadiseSpawn")
        if spawn then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = spawn.CFrame
        end
    end,
})


----------------------------------------
-- Tab: 🎲 Misc
----------------------------------------
local MiscTab = Window:CreateTab("🎲 Misc", nil)
-- เพิ่มปุ่มหรือคอนโทรลอื่น ๆ ในนี้ตามต้องการ
