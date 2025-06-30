-- โหลด Rayfield UI
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

-- สร้างหน้าต่าง UI
local Window = Rayfield:CreateWindow({
   Name = "Moseeri Hub",
   LoadingTitle = "กำลังโหลด Auto Farm",
   LoadingSubtitle = "Powered by Rayfield",
   ConfigurationSaving = {
      Enabled = false
   },
   KeySystem = false
})

-- สร้างแท็บ "Auto Farm"
local FarmTab = Window:CreateTab("Auto Farm", nil)
local FarmSection = FarmTab:CreateSection("ตั้งค่าการฟาร์ม")

-- ตัวแปรควบคุม
getgenv().AutofarmEnabled = false
getgenv().SelectedMob = nil
getgenv().FarmDelay = 0.3

-- รอสักครู่เพื่อให้ UI โหลดเสร็จ
task.defer(function()
    task.wait(0.5)

    -- ดึงชื่อมอนสเตอร์จาก Workspace
    local mobs = {}
    local path = workspace:FindFirstChild("Monster") and workspace.Monster:FindFirstChild("Mon")
    if path then
        for _, mob in ipairs(path:GetChildren()) do
            mobs[#mobs+1] = mob.Name
        end
    end

    -- Dropdown: เลือกมอนสเตอร์
    FarmSection:CreateDropdown({
        Name = "เลือกมอนสเตอร์",
        Options = mobs,
        CurrentOption = mobs[1] or "",
        Callback = function(option) getgenv().SelectedMob = option end
    })

    -- Slider: ตั้งดีเลย์การตี
    FarmSection:CreateSlider({
        Name = "Delay (วินาที)",
        Range = {0.05, 1},
        Increment = 0.05,
        CurrentValue = getgenv().FarmDelay,
        Callback = function(val) getgenv().FarmDelay = val end
    })

    -- Toggle: เปิด/ปิด Auto Farm
    FarmSection:CreateToggle({
        Name = "เปิด Auto Farm",
        CurrentValue = false,
        Callback = function(state)
            getgenv().AutofarmEnabled = state
            if state then
                spawn(function()
                    while getgenv().AutofarmEnabled do
                        if getgenv().SelectedMob and path then
                            local mob = path:FindFirstChild(getgenv().SelectedMob)
                            if mob and mob:FindFirstChild("HumanoidRootPart") then
                                local plr = game.Players.LocalPlayer
                                plr.Character.HumanoidRootPart.CFrame = mob.HumanoidRootPart.CFrame * CFrame.new(0,0,2)
                            end
                        end
                        task.wait(getgenv().FarmDelay)
                    end
                end)
            end
        end
    })
end)
