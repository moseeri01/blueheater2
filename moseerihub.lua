local Rayfield = loadstring(game:HttpGet("https://raw.githubusercontent.com/mirroredfunction/shlexware-Rayfield/main/source.lua"))()

local Window = Rayfield:CreateWindow({
    Name = "Moseeri Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "By Amira",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = nil, -- หรือใส่ชื่อโฟลเดอร์ เช่น "MoseeriFolder"
        FileName = "MoseeriHub"
    },
    KeySystem = true,
    KeySettings = {
        Title = "Moseeri Key",
        Subtitle = "Get your key from Discord",
        Note = "https://discord.gg/uGX2X3Wv",
        FileName = "MoseeriKey",
        SaveKey = true,
        GrabKeyFromSite = true,
        Key = {"moseeri123"}, -- สำรองไว้หากเว็บโหลดไม่ได้
        KeyLink = "https://raw.githubusercontent.com/moseeri01/key/main/key.txt"
    }
})

local MainTab = Window:CreateTab("Main")
local MainSection = MainTab:CreateSection("Moseeri Feature")

MainSection:CreateButton({
    Name = "Click Me!",
    Callback = function()
        print("Hello from Moseeri Hub!")
    end
})
