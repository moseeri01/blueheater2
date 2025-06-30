local Rayfield = loadstring(game:HttpGet("https://raw.githubusercontent.com/shlexware/Rayfield/main/source.lua"))()

local Window = Rayfield:CreateWindow({
   Name = "moseeri hub",
   LoadingTitle = "Moseeri Hub Loading....",
   LoadingSubtitle = "by amira",
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil, -- Create a custom folder for your hub/game
      FileName = "Big Hub"
   }
                
   },
   KeySystem = true, -- Set this to true to use our key system
   KeySettings = {
      Title = "Moseeri Key",
      Subtitle = "Get your key from Discord",
      Note = "https://discord.gg/uGX2X3Wv",
      FileName = "MoseeriKey", -- It is recommended to use something unique as other scripts using Rayfield may overwrite your key file
      SaveKey = true, -- The user's key will be saved, but if you change the key, they will be unable to use your script
      GrabKeyFromSite = true, -- If this is true, set Key below to the RAW site you would like Rayfield to get the key from
      Key = {"https://raw.githubusercontent.com/moseeri01/key/main/key.txt"} -- List of keys that will be accepted by the system, can be RAW file links (pastebin, github etc) or simple strings ("hello","key22")
   }
})

local MainTab = Window:CreateTab("🎃Home 1", nil) -- Title, Image
local MainSection = MainTab:CreateSection("Main")

local ScreenGui = Instance.new("ScreenGui")
local MainGui = Instance.new("Frame")
local Topbar = Instance.new("Frame")
local TextLabel = Instance.new("TextLabel")
local Close = Instance.new("TextButton")
local InstantFinishQuiz = Instance.new("TextButton")
local BypassAntiSpam = Instance.new("TextButton")
local AntiSpamBypassFrame = Instance.new("Frame")
local Topbar_2 = Instance.new("Frame")
local TextLabel_2 = Instance.new("TextLabel")
local Close_2 = Instance.new("TextButton")
local TextSpam = Instance.new("TextBox")
local StartSpam = Instance.new("TextButton")
local PreventPointReset = Instance.new("TextButton")

--Properties:

ScreenGui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

MainGui.Name = "MainGui"
MainGui.Parent = ScreenGui
MainGui.BackgroundColor3 = Color3.fromRGB(52, 52, 52)
MainGui.BorderSizePixel = 0
MainGui.Position = UDim2.new(0.5, -246, 0.5, -152)
MainGui.Size = UDim2.new(0, 493, 0, 305)

Topbar.Name = "Topbar"
Topbar.Parent = MainGui
Topbar.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
Topbar.BorderSizePixel = 0
Topbar.Size = UDim2.new(0, 493, 0, 35)

TextLabel.Parent = Topbar
TextLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
TextLabel.BackgroundTransparency = 1.000
TextLabel.BorderSizePixel = 0
TextLabel.Position = UDim2.new(0.296146035, 0, 0, 0)
TextLabel.Size = UDim2.new(0, 200, 0, 35)
TextLabel.Font = Enum.Font.SourceSansSemibold
TextLabel.Text = "Pastriez Trolling Gui"
TextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TextLabel.TextScaled = true
TextLabel.TextSize = 14.000
TextLabel.TextWrapped = true

Close.Name = "Close"
Close.Parent = Topbar
Close.BackgroundColor3 = Color3.fromRGB(255, 96, 85)
Close.BorderSizePixel = 0
Close.Position = UDim2.new(0.9290061, 0, 0, 0)
Close.Size = UDim2.new(0, 35, 0, 35)
Close.Font = Enum.Font.SourceSansSemibold
Close.Text = "X"
Close.TextColor3 = Color3.fromRGB(255, 255, 255)
Close.TextScaled = true
Close.TextSize = 14.000
Close.TextWrapped = true

InstantFinishQuiz.Name = "InstantFinishQuiz"
InstantFinishQuiz.Parent = MainGui
InstantFinishQuiz.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
InstantFinishQuiz.BorderSizePixel = 0
InstantFinishQuiz.Position = UDim2.new(0.0304259658, 0, 0.163934425, 0)
InstantFinishQuiz.Size = UDim2.new(0, 100, 0, 100)
InstantFinishQuiz.Font = Enum.Font.SourceSansSemibold
InstantFinishQuiz.Text = "Instant Finish Quiz (MUST BE IN QUIZ CENTER)"
InstantFinishQuiz.TextColor3 = Color3.fromRGB(255, 255, 255)
InstantFinishQuiz.TextScaled = true
InstantFinishQuiz.TextSize = 14.000
InstantFinishQuiz.TextWrapped = true

BypassAntiSpam.Name = "BypassAntiSpam"
BypassAntiSpam.Parent = MainGui
BypassAntiSpam.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
BypassAntiSpam.BorderSizePixel = 0
BypassAntiSpam.Position = UDim2.new(0.263691694, 0, 0.163934425, 0)
BypassAntiSpam.Size = UDim2.new(0, 100, 0, 100)
BypassAntiSpam.Font = Enum.Font.SourceSansSemibold
BypassAntiSpam.Text = "Bypass Anti-Spam"
BypassAntiSpam.TextColor3 = Color3.fromRGB(255, 255, 255)
BypassAntiSpam.TextScaled = true
BypassAntiSpam.TextSize = 14.000
BypassAntiSpam.TextWrapped = true

AntiSpamBypassFrame.Name = "AntiSpamBypassFrame"
AntiSpamBypassFrame.Parent = MainGui
AntiSpamBypassFrame.BackgroundColor3 = Color3.fromRGB(52, 52, 52)
AntiSpamBypassFrame.BorderSizePixel = 0
AntiSpamBypassFrame.Position = UDim2.new(0.306288034, 0, 1.08524585, 0)
AntiSpamBypassFrame.Size = UDim2.new(0, 189, 0, 121)
AntiSpamBypassFrame.Visible = false

Topbar_2.Name = "Topbar"
Topbar_2.Parent = AntiSpamBypassFrame
Topbar_2.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
Topbar_2.BorderSizePixel = 0
Topbar_2.Size = UDim2.new(0, 189, 0, 23)

TextLabel_2.Parent = Topbar_2
TextLabel_2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
TextLabel_2.BackgroundTransparency = 1.000
TextLabel_2.BorderSizePixel = 0
TextLabel_2.Position = UDim2.new(0.153439149, 0, 0, 0)
TextLabel_2.Size = UDim2.new(0, 130, 0, 23)
TextLabel_2.Font = Enum.Font.SourceSansSemibold
TextLabel_2.Text = "Gui Manager"
TextLabel_2.TextColor3 = Color3.fromRGB(255, 255, 255)
TextLabel_2.TextScaled = true
TextLabel_2.TextSize = 14.000
TextLabel_2.TextWrapped = true

Close_2.Name = "Close"
Close_2.Parent = Topbar_2
Close_2.BackgroundColor3 = Color3.fromRGB(255, 96, 85)
Close_2.BorderSizePixel = 0
Close_2.Position = UDim2.new(0.878306866, 0, 0, 0)
Close_2.Size = UDim2.new(0, 23, 0, 23)
Close_2.Font = Enum.Font.SourceSansSemibold
Close_2.Text = "X"
Close_2.TextColor3 = Color3.fromRGB(255, 255, 255)
Close_2.TextScaled = true
Close_2.TextSize = 14.000
Close_2.TextWrapped = true

TextSpam.Name = "TextSpam"
TextSpam.Parent = AntiSpamBypassFrame
TextSpam.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
TextSpam.BorderSizePixel = 0
TextSpam.Position = UDim2.new(0.095238097, 0, 0.289256215, 0)
TextSpam.Size = UDim2.new(0, 153, 0, 32)
TextSpam.Font = Enum.Font.SourceSansSemibold
TextSpam.Text = "Enter text here..."
TextSpam.TextColor3 = Color3.fromRGB(255, 255, 255)
TextSpam.TextSize = 21.000
TextSpam.TextWrapped = true

StartSpam.Name = "StartSpam"
StartSpam.Parent = AntiSpamBypassFrame
StartSpam.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
StartSpam.BorderSizePixel = 0
StartSpam.Position = UDim2.new(0.216931224, 0, 0.65289253, 0)
StartSpam.Size = UDim2.new(0, 105, 0, 30)
StartSpam.Font = Enum.Font.SourceSansSemibold
StartSpam.Text = "Spam"
StartSpam.TextColor3 = Color3.fromRGB(255, 255, 255)
StartSpam.TextSize = 28.000
StartSpam.TextWrapped = true

PreventPointReset.Name = "PreventPointReset"
PreventPointReset.Parent = MainGui
PreventPointReset.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
PreventPointReset.BorderSizePixel = 0
PreventPointReset.Position = UDim2.new(0.496957421, 0, 0.16393441, 0)
PreventPointReset.Size = UDim2.new(0, 100, 0, 100)
PreventPointReset.Font = Enum.Font.SourceSansSemibold
PreventPointReset.Text = "Break/Prevent Point reset events"
PreventPointReset.TextColor3 = Color3.fromRGB(255, 255, 255)
PreventPointReset.TextScaled = true
PreventPointReset.TextSize = 14.000
PreventPointReset.TextWrapped = true


local function YBOWCK_fake_script() -- Close.LocalScript 
	local script = Instance.new('LocalScript', Close)

	script.Parent.MouseButton1Click:Connect(function()
		script.Parent.Parent.Parent:Destroy()
	end)
end
coroutine.wrap(YBOWCK_fake_script)()
local function QYVO_fake_script() -- Topbar.LocalScript 
	local script = Instance.new('LocalScript', Topbar)

	frame = script.Parent.Parent
	frame.Draggable = true
	frame.Active = true
	frame.Selectable = true
end
coroutine.wrap(QYVO_fake_script)()
local function QZLXVQP_fake_script() -- InstantFinishQuiz.LocalScript 
	local script = Instance.new('LocalScript', InstantFinishQuiz)

	script.Parent.MouseButton1Click:Connect(function()
		local remote = game:GetService("ReplicatedStorage").JobCenterManager.SubmitAnswer 
		remote:FireServer("QuestionOne", "AnswerTwo")
		remote:FireServer("QuestionTwo", "AnswerOne")
		remote:FireServer("QuestionThree", "AnswerThree")
		remote:FireServer("QuestionFour", "AnswerFour")
		remote:FireServer("QuestionFive", "AnswerOne")
		remote:FireServer("QuestionSix", "AnswerTwo")
		remote:FireServer("QuestionSeven", "AnswerOne")
		remote:FireServer("QuestionEight", "AnswerFour")
		remote:FireServer("QuestionNine", "AnswerThree")
		remote:FireServer("QuestionTen", "AnswerTwo")
		remote:FireServer("QuestionEleven", "AnswerTwo")
		remote:FireServer("QuestionTwelve", "AnswerThree")
		game:GetService("ReplicatedStorage").Rank:InvokeServer(12)
	end)
end
coroutine.wrap(QZLXVQP_fake_script)()
local function OJADVM_fake_script() -- BypassAntiSpam.LocalScript 
	local script = Instance.new('LocalScript', BypassAntiSpam)

	script.Parent.MouseButton1Click:Connect(function()
		script.Parent.Parent.AntiSpamBypassFrame.Visible = true
	end)
end
coroutine.wrap(OJADVM_fake_script)()
local function AIIULJI_fake_script() -- Close_2.LocalScript 
	local script = Instance.new('LocalScript', Close_2)

	script.Parent.MouseButton1Click:Connect(function()
		script.Parent.Parent.Parent.Visible = false
	end)
end
coroutine.wrap(AIIULJI_fake_script)()
local function TYXSDJH_fake_script() -- Topbar_2.LocalScript 
	local script = Instance.new('LocalScript', Topbar_2)

	frame1 = script.Parent.Parent
	frame1.Draggable = true
	frame1.Active = true
	frame1.Selectable = true
end
coroutine.wrap(TYXSDJH_fake_script)()
local function TDJMMEU_fake_script() -- StartSpam.LocalScript 
	local script = Instance.new('LocalScript', StartSpam)

	script.Parent.MouseButton1Click:Connect(function()
		local A_1 = script.Parent.Parent.TextSpam.Text
		local A_2 = "All"
		local Event = game:GetService("ReplicatedStorage").DefaultChatSystemChatEvents.SayMessageRequest
		Event:FireServer(A_1, A_2)
	end)
end
coroutine.wrap(TDJMMEU_fake_script)()
local function FWWDG_fake_script() -- PreventPointReset.LocalScript 
	local script = Instance.new('LocalScript', PreventPointReset)

	script.Parent.MouseButton1Click:Connect(function()
		game.ReplicatedStorage.OrderSystem.PointCheater:Destroy()
		game.StarterGui.PointCheaterGUI:Destroy()
		game.ReplicatedStorage.ClaimCashRegisters.CheckRegister:Destroy()
		game.ReplicatedStorage.CLEARPOINTS:Destroy()
	end)
end
coroutine.wrap(FWWDG_fake_script)()


Rayfield:Notify({
   Title = "Script Exeucted",
   Content = "Notification Content",
   Duration = 6.5,
   Image = nil,
   Actions = { -- Notification Buttons
      Ignore = {
         Name = "Okay!",
         Callback = function()
         print("The user tapped Okay!")
      end
   },
},
})

local Button = MainTab:CreateButton({
   Name = "Infinite Jump",
   Callback = function()
  local InfiniteJumpEnabled = true
game:GetService("UserInputService").JumpRequest:connect(function()
	if InfiniteJumpEnabled then
		game:GetService"Players".LocalPlayer.Character:FindFirstChildOfClass'Humanoid':ChangeState("Jumping")
	end
end)
local InfiniteJump = CreateButton("Infinite Jump: Off", StuffFrame)
InfiniteJump.Position = UDim2.new(0,10,0,130)
InfiniteJump.Size = UDim2.new(0,150,0,30)
InfiniteJump.MouseButton1Click:connect(function()
	local state = InfiniteJump.Text:sub(string.len("Infinite Jump: ") + 1) --too lazy to count lol
	local new = state == "Off" and "On" or state == "On" and "Off"
	InfiniteJumpEnabled = new == "On"
	InfiniteJump.Text = "Infinite Jump: " .. new
end)
   end,
})

local Slider = MainTab:CreateSlider({
   Name = "Walkspeed Slider 🎨",
   Range = {0, 400},
   Increment = 1,
   Suffix = "Speed",
   CurrentValue = 16,
   Flag = "Slider1", -- A flag is the identifier for the configuration file, make sure every element has a different flag if you're using configuration saving to ensure no overlaps
   Callback = function(Value)
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = (Value)
   end,
})

local lp = game:FindService("Players").LocalPlayer

local function gplr(String)
	local Found = {}
	local strl = String:lower()
	if strl == "all" then
		for i,v in pairs(game:FindService("Players"):GetPlayers()) do
			table.insert(Found,v)
		end
	elseif strl == "others" then
		for i,v in pairs(game:FindService("Players"):GetPlayers()) do
			if v.Name ~= lp.Name then
				table.insert(Found,v)
			end
		end 
	elseif strl == "me" then
		for i,v in pairs(game:FindService("Players"):GetPlayers()) do
			if v.Name == lp.Name then
				table.insert(Found,v)
			end
		end 
	else
		for i,v in pairs(game:FindService("Players"):GetPlayers()) do
			if v.Name:lower():sub(1, #String) == String:lower() then
				table.insert(Found,v)
			end
		end 
	end
	return Found 
end

local function notif(str,dur)
	game:FindService("StarterGui"):SetCore("SendNotification", {
		Title = "yeet gui",
		Text = str,
		Icon = "rbxassetid://2005276185",
		Duration = dur or 3
	})
end

--// sds

local h = Instance.new("ScreenGui")
local Main = Instance.new("ImageLabel")
local Top = Instance.new("Frame")
local Title = Instance.new("TextLabel")
local TextBox = Instance.new("TextBox")
local TextButton = Instance.new("TextButton")

h.Name = "h"
h.Parent = game:GetService("CoreGui")
h.ResetOnSpawn = false

Main.Name = "Main"
Main.Parent = h
Main.Active = true
Main.Draggable = true
Main.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
Main.BorderSizePixel = 0
Main.Position = UDim2.new(0.174545452, 0, 0.459574461, 0)
Main.Size = UDim2.new(0, 454, 0, 218)
Main.Image = "rbxassetid://2005276185"

Top.Name = "Top"
Top.Parent = Main
Top.BackgroundColor3 = Color3.fromRGB(57, 57, 57)
Top.BorderSizePixel = 0
Top.Size = UDim2.new(0, 454, 0, 44)

Title.Name = "Title"
Title.Parent = Top
Title.BackgroundColor3 = Color3.fromRGB(49, 49, 49)
Title.BorderSizePixel = 0
Title.Position = UDim2.new(0, 0, 0.295454562, 0)
Title.Size = UDim2.new(0, 454, 0, 30)
Title.Font = Enum.Font.SourceSans
Title.Text = "FE Yeet Gui (trollface edition)"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextScaled = true
Title.TextSize = 14.000
Title.TextWrapped = true

TextBox.Parent = Main
TextBox.BackgroundColor3 = Color3.fromRGB(49, 49, 49)
TextBox.BorderSizePixel = 0
TextBox.Position = UDim2.new(0.0704845786, 0, 0.270642221, 0)
TextBox.Size = UDim2.new(0, 388, 0, 62)
TextBox.Font = Enum.Font.SourceSans
TextBox.PlaceholderText = "Who do i destroy(can be shortened)"
TextBox.Text = ""
TextBox.TextColor3 = Color3.fromRGB(255, 255, 255)
TextBox.TextScaled = true
TextBox.TextSize = 14.000
TextBox.TextWrapped = true

TextButton.Parent = Main
TextButton.BackgroundColor3 = Color3.fromRGB(49, 49, 49)
TextButton.BorderSizePixel = 0
TextButton.Position = UDim2.new(0.10352423, 0, 0.596330225, 0)
TextButton.Size = UDim2.new(0, 359, 0, 50)
TextButton.Font = Enum.Font.SourceSans
TextButton.Text = "Cheese em'"
TextButton.TextColor3 = Color3.fromRGB(255, 255, 255)
TextButton.TextScaled = true
TextButton.TextSize = 14.000
TextButton.TextWrapped = true

TextButton.MouseButton1Click:Connect(function()
	local Target = gplr(TextBox.Text)
	if Target[1] then
		Target = Target[1]
		
		local Thrust = Instance.new('BodyThrust', lp.Character.HumanoidRootPart)
		Thrust.Force = Vector3.new(9999,9999,9999)
		Thrust.Name = "YeetForce"
		repeat
			lp.Character.HumanoidRootPart.CFrame = Target.Character.HumanoidRootPart.CFrame
			Thrust.Location = Target.Character.HumanoidRootPart.Position
			game:FindService("RunService").Heartbeat:wait()
		until not Target.Character:FindFirstChild("Head")
	else
		notif("Invalid player")
	end
end)

--//fsddfsdf
notif("Loaded successfully! Created by Allaoui59", 5)

local Dropdown = MainTab:CreateDropdown({
   Name = "Select Area",
   Options = {"Random Place","Random Place 2"},
   CurrentOption = {"Random Place"},
   MultipleOptions = true,
   Flag = "Teleport 🛒", -- A flag is the identifier for the configuration file, make sure every element has a different flag if you're using configuration saving to ensure no overlaps
   Callback = function(Option)
   -- The function that takes place when the selected option is changed
   -- The variable (Option) is a table of strings for the current selected options
   end,
   print(Option)
})

local TeleportTab = Window:CreateTab("🎭Home2", nil) -- Title, Image
local Section = TeleportTab:CreateSection("scripts")

local Toggle = Tab:CreateToggle({
   Name = "Tiny Task",
   CurrentValue = false,
   Flag = "Enable", -- A flag is the identifier for the configuration file, make sure every element has a different flag if you're using configuration saving to ensure no overlaps
   Callback = function(Value)
  print(Welcome!)
   end,
})print 'hello world!'
