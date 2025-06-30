local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "MOSEERI HUB",
    LoadingTitle = "Loading UI...",
    LoadingSubtitle = "Comet Style",
    ConfigurationSaving = {
        Enabled = true,
        FileName = "MoseeriHub"
    },
    KeySystem = false
})

-- Tab: Main
local MainTab = Window:CreateTab("⚔ Main", nil)

-- Toggle: Auto Farm
MainTab:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Callback = function(state)
        getgenv().AutoFarm = state
        if state then
            print("Auto Farm ON")
            spawn(function()
                while getgenv().AutoFarm do
                    -- ฟาร์มอัตโนมัติ (ใส่โค้ดจริงตรงนี้)
                    task.wait(0.2)
                end
            end)
        else
            print("Auto Farm OFF")
        end
    end
})

-- Toggle: Kill Aura
MainTab:CreateToggle({
    Name = "Kill Aura",
    CurrentValue = false,
    Callback = function(state)
        print("Kill Aura: " .. tostring(state))
    end
})

-- Toggle: Infinite Jump
MainTab:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Callback = function(state)
        getgenv().InfJump = state
        if state then
            game:GetService("UserInputService").JumpRequest:Connect(function()
                if getgenv().InfJump then
                    game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid"):ChangeState("Jumping")
                end
            end)
        end
    end
})

-- Dropdown: Walkspeed
MainTab:CreateDropdown({
    Name = "Walkspeed",
    Options = {"16", "50", "100", "200"},
    CurrentOption = "16",
    Callback = function(option)
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = tonumber(option)
    end
})

-- Dropdown: JumpPower
MainTab:CreateDropdown({
    Name = "JumpPower",
    Options = {"50", "100", "150", "200"},
    CurrentOption = "50",
    Callback = function(option)
        game.Players.LocalPlayer.Character.Humanoid.JumpPower = tonumber(option)
    end
})

-- Button: Join Dead Server
MainTab:CreateButton({
    Name = "Join Dead Server",
    Callback = function()
        print("Joining low player server...")
        -- ใส่โค้ดย้ายเซิฟเบาๆ ตรงนี้
    end
})

-- Button: Anti-AFK
MainTab:CreateButton({
    Name = "Anti AFK",
    Callback = function()
        local vu = game:GetService("VirtualUser")
        game:GetService("Players").LocalPlayer.Idled:Connect(function()
            vu:Button2Down(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
            task.wait(1)
            vu:Button2Up(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
        end)
    end
})
