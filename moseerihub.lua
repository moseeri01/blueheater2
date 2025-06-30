local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Auto Farm System",
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
        Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
    }
})

-- 📌 MAIN TAB (Star Stream Style)
local MainTab = Window:CreateTab("🛡 Main Features")

-- 🧲 TOGGLES
local MainSection = MainTab:CreateSection("Toggles")

getgenv().autoFarm = false
getgenv().killAura = false
getgenv().dodge = false
getgenv().chestFarm = false
getgenv().bossOnly = false
getgenv().killWithStaff = false
getgenv().killSpeed = 0.1

MainSection:CreateToggle({
    Name = "Enable Auto Farm",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().autoFarm = Value
        if Value then
            AutoFarm()
        end
    end,
})

MainSection:CreateToggle({
    Name = "Enable Chest Farm",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().chestFarm = Value
    end,
})

MainSection:CreateToggle({
    Name = "Enable Dodge Mechanism",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().dodge = Value
    end,
})

MainSection:CreateToggle({
    Name = "Boss Prioritization",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().bossOnly = Value
    end,
})

MainSection:CreateToggle({
    Name = "Enable Kill Aura",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().killAura = Value
    end,
})

MainSection:CreateToggle({
    Name = "Kill Aura (With Staff)",
    CurrentValue = false,
    Callback = function(Value)
        getgenv().killWithStaff = Value
    end,
})

MainSection:CreateParagraph
