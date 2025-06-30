local Rayfield = loadstring(game:HttpGet("https://raw.githubusercontent.com/shlexware/Rayfield/main/source.lua"))()

local Window = Rayfield:CreateWindow({
   Name = "moseeri hub",
   LoadingTitle = "Moseeri Hub Loading....",
   LoadingSubtitle = "by amira",
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil,
      FileName = "Big Hub"
   },
   KeySystem = true,
   KeySettings = {
      Title = "Moseeri Key",
      Subtitle = "Get your key from Discord",
      Note = "https://discord.gg/uGX2X3Wv",
      FileName = "MoseeriKey",
      SaveKey = true,
      GrabKeyFromSite = true,
      Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"}
   }
})
