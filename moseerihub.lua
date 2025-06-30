local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Moseeri Hub Loading...",
    LoadingSubtitle = "Star Stream Style",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil,
        FileName = "MoseeriHub"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Get your key from Discord",
        Note = "https://discord.gg/uGX2X3WvY",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
    }
})

-- MAIN FEATURES Tab
local TabMain = Window:CreateTab("Main Features", nil)
local SectionFarm = TabMain:CreateSection("Auto Farming")

SectionFarm:CreateToggle({
    Name = "Enable Auto Farm",
    CurrentValue = false,
    Callback = function(v)
        getgenv().autoFarm = v
        if v then
            print("Auto Farm On")
            -- Auto farm function here
        end
    end
})
SectionFarm:CreateToggle({
    Name = "Enable Chest Farm",
    CurrentValue = false,
    Callback = function(v)
        getgenv().chestFarm = v
        -- Chest farm function here
    end
})
SectionFarm:CreateToggle({
    Name = "Enable Dodge Mechanism",
    CurrentValue = false,
    Callback = function(v)
        getgenv().dodgeMechanism = v
        -- Dodge code here
    end
})
SectionFarm:CreateToggle({
    Name = "Boss Prioritization",
    CurrentValue = false,
    Callback = function(v)
        getgenv().bossPriority = v
        -- Prioritize boss code here
    end
})
SectionFarm:CreateToggle({
    Name = "Enable Kill Aura",
    CurrentValue = false,
    Callback = function(v)
        getgenv().killAura = v
        -- Kill aura code here
    end
})
SectionFarm:CreateToggle({
    Name = "Kill Aura (With Staff)",
    CurrentValue = false,
    Callback = function(v)
        getgenv().killAuraStaff = v
        -- Kill aura staff code here
    end
})
SectionFarm:CreateParagraph({
    Title = "About Kill Aura With Staff",
    Content = "Even though it appears to work from a distance, you need to be close for it to deal damage."
})
SectionFarm:CreateSlider({
    Name = "Kill Aura Speed",
    Range = {0.05, 1},
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = 0.1,
    Callback = function(Value)
        getgenv().killAuraSpeed = Value
    end,
})

-- DUNGEON & TOWER Tab
local TabDungeon = Window:CreateTab("Dungeon & Tower", nil)
local SectionDungeon = TabDungeon:CreateSection("Dungeon Scripts")
SectionDungeon:CreateButton({
    Name = "Auto Dungeon",
    Callback = function()
        print("Auto Dungeon!")
    end,
})

-- PLAYER Tab
local TabPlayer = Window:CreateTab("Player", nil)
local SectionPlayer = TabPlayer:CreateSection("Player Options")
SectionPlayer:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Callback = function(v)
        getgenv().infJump = v
        -- Infinite Jump code
    end
})
SectionPlayer:CreateSlider({
    Name = "Walkspeed",
    Range = {10, 100},
    Increment = 1,
    Suffix = "Speed",
    CurrentValue = 16,
    Callback = function(Value)
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = Value
    end,
})

-- สามารถเพิ่ม Tab อื่นๆ ได้เช่น "Place", "Misc", "Settings" ตามตัวอย่างในคลิป
