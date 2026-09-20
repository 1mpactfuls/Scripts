--// made by impactfuls
local Luna = loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/refs/heads/main/source.lua", true))()

local Window = Luna:CreateWindow({
    Name = "Gun Slinger | by impacfuls",
    Subtitle = nil,
    LogoID = "96112932578672",
    LoadingEnabled = true,
    LoadingTitle = "Gun Slinger | Loading",
    LoadingSubtitle = "By x_1mpactfuls. , credits to rick/sh4k4r6o on discord",
    
    ConfigSettings = {
        RootFolder = nil,
        ConfigFolder = "Gun Slinger"
    }
})

local MainTab = Window:CreateTab({
    Name = "Silent Aim",
    Icon = "my_location",
    ImageSource = "Material",
    ShowTitle = true
})

local SettingTab = Window:CreateTab({
    Name = "Settings",
    Icon = "settings",
    ImageSource = "Material",
    ShowTitle = true
})

--// this is for x_1mpactfuls. just make sure to credit me if u use it
local RICK = {
    Camera = game:GetService("Workspace").CurrentCamera,
    Players = game:GetService("Players"),
    LocalPlayer = game:GetService("Players").LocalPlayer,
    RunService = game:GetService("RunService"),
    TweenService = game:GetService("TweenService"),
    CoreGui = game:GetService("CoreGui"),

    SilentEnabled = false,
    SilentVisible = true,
    SRadius = 100,
    SColor = Color3.new(255, 255, 255),
    SFilled = false,
    STransparency = 1,
    SThickness = 1.5,

    SChecks = false,
    STeamCheck = false,
    SFriendCheck = false,
    SVehicleCheck = false,
    SCivilianCheck = false,

    ClosestEnemy = nil
}

RICK.Silent = Drawing.new("Circle")
RICK.Silent.Visible = RICK.SilentVisible
RICK.Silent.Radius = RICK.SRadius
RICK.Silent.Color = RICK.SColor
RICK.Silent.Thickness = RICK.SThickness
RICK.Silent.Transparency = RICK.STransparency
RICK.Silent.Filled = RICK.SFilled
RICK.Silent.Position = Vector2.new(RICK.Camera.ViewportSize.X / 2, RICK.Camera.ViewportSize.Y / 2)

MainTab:CreateSection("Silent Aim")

local function EnemyInFov(target)
    if not RICK.SilentEnabled then return false end
    local targetPos = RICK.Camera:WorldToViewportPoint(target.Position)
    local screenCenter = Vector2.new(RICK.Camera.ViewportSize.X / 2, RICK.Camera.ViewportSize.Y / 2)
    return (Vector2.new(targetPos.X, targetPos.Y) - screenCenter).Magnitude <= RICK.Silent.Radius
end

local function GetClosestEnemy()
    if not RICK.SilentEnabled then return nil end
    local closest, minDist = nil, math.huge
    
    for _, target in ipairs(RICK.Players:GetPlayers()) do
        if target == RICK.LocalPlayer then continue end
        
        if RICK.SChecks then
            if RICK.STeamCheck and target.Team == RICK.LocalPlayer.Team then continue end
            if RICK.SFriendCheck and RICK.LocalPlayer:IsFriendsWith(target.UserId) then continue end
            if RICK.SVehicleCheck and target.Character and target.Character:FindFirstChild("Humanoid") and target.Character.Humanoid:GetState() == Enum.HumanoidStateType.Seated then continue end
            if RICK.SCivilianCheck and target.Team and target.Team.Name == "Civilians" then continue end
        end
        
        local char = target.Character
        if char and char:FindFirstChild("HumanoidRootPart") and EnemyInFov(char.HumanoidRootPart) then
            local dist = (RICK.LocalPlayer.Character.HumanoidRootPart.Position - char.HumanoidRootPart.Position).Magnitude
            if dist < minDist then
                minDist = dist
                closest = target
            end
        end
    end
    
    return closest
end

local mt = getrawmetatable(game)
local old = mt.__namecall
setreadonly(mt, false)

mt.__namecall = newcclosure(function(obj, ...)
    local method = getnamecallmethod()
    local args = {...}
    
    if tostring(method) == "FindPartOnRayWithIgnoreList" and RICK.SilentEnabled and RICK.ClosestEnemy and RICK.ClosestEnemy.Character then
        args[1] = Ray.new(
            RICK.Camera.CFrame.Position,
            (RICK.ClosestEnemy.Character.Head.Position - RICK.Camera.CFrame.Position).Unit * 
            (RICK.Camera.CFrame.Position - RICK.ClosestEnemy.Character.Head.Position).Magnitude
        )
    end
    
    return old(obj, unpack(args))
end)

setreadonly(mt, true)

RICK.RunService.Heartbeat:Connect(function()
    RICK.ClosestEnemy = RICK.SilentEnabled and GetClosestEnemy() or nil
    RICK.Silent.Visible = RICK.SilentEnabled and RICK.SilentVisible
end)

MainTab:CreateToggle({
    Name = "Enabled",
    CurrentValue = false,
    Callback = function(Value)
        RICK.SilentEnabled = Value
        RICK.Silent.Visible = Value and RICK.SilentVisible
    end
}, "SilentEnabled")

MainTab:CreateSlider({
	Name = "Radius",
	Range = {0, 250},
	Increment = 1,
	CurrentValue = 100,
    	Callback = function(Value)
            RICK.Silent.Radius = Value
            RICK.SRadius = Value
    	end
}, "SilentRadius")

MainTab:CreateSlider({
	Name = "Thickness",
	Range = {0, 10},
	Increment = 1,
	CurrentValue = 1.5,
    	Callback = function(Value)
            RICK.Silent.Thickness = Value
            RICK.SThickness = Value
    	end
}, "SilentThickness")

MainTab:CreateToggle({
    Name = "FOV Visible",
    CurrentValue = RICK.SilentVisible,
    Callback = function(Value)
    if RICK.SilentEnabled then
            RICK.SilentVisible = Value
            RICK.Silent.Visible = Value
        end
    end
}, "SilentFov")

MainTab:CreateToggle({
    Name = "FOV Filled",
    CurrentValue = RICK.SFilled,
    Callback = function(Value)
        RICK.SFilled = Value
        RICK.Silent.Filled = Value
    end
}, "SilentFilled")

MainTab:CreateColorPicker({
	Name = "FOV Color",
	Color = RICK.SColor,
	Callback = function(Value)
        RICK.SColor = Value
        RICK.Silent.Color = Value
	end
}, "FovColor")

MainTab:CreateDivider()

MainTab:CreateSection("Checks")

MainTab:CreateToggle({
    Name = "Enabled",
    CurrentValue = RICK.SChecks,
    Callback = function(Value)
        RICK.SChecks = Value
    end
}, "ChecksEnabled")

MainTab:CreateToggle({
    Name = "Team Check",
    CurrentValue = RICK.STeamCheck,
    Callback = function(Value)
        RICK.STeamCheck = Value
    end
}, "TeamCheck")

MainTab:CreateToggle({
    Name = "Friend Check",
    CurrentValue = RICK.SFriendCheck,
    Callback = function(Value)
        RICK.SFriendCheck = Value
    end
}, "FriendCheck")

MainTab:CreateToggle({
    Name = "Vehicle Check",
    CurrentValue = RICK.SVehicleCheck,
    Callback = function(Value)
        RICK.SVehicleCheck = Value
    end
}, "VehicleCheck")

MainTab:CreateToggle({
    Name = "Civilian Check",
    CurrentValue = RICK.SCivilianCheck,
    Callback = function(Value)
        RICK.SCivilianCheck = Value
    end
}, "CivilianCheck")

SettingTab:CreateButton({
	Name = "Unload",
	Description = nil,
    Callback = function()
        Luna:Destroy()
        -- u can add stuff to turn silent aim off etc
    end
})

SettingTab:BuildThemeSection()
SettingTab:BuildConfigSection()