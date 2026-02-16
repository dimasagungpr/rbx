-- =====================================================
-- UI Garden Incremental
-- =====================================================

-- Services
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer
local Mouse = LP:GetMouse()

-- =====================================================
-- GLOBAL STATE / CLEANUP
-- =====================================================
local GLOBAL_KEY = "GardenIncremental__State"
local ENV = (getgenv and getgenv()) or _G
if ENV[GLOBAL_KEY] and ENV[GLOBAL_KEY].Cleanup then
    pcall(ENV[GLOBAL_KEY].Cleanup)
end

local State = {
    Connections = {},
    RemoteConnections = {},
    RemoteInvokeOld = {},
    ScreenGui = nil,
    Mt = nil,
    OldNamecall = nil,
    Hooked = false,
    RemoteHookEnabled = false,
    RemoteHookConn = nil,
    C2SLastCapture = "",
    C2SCaptureArmed = false,
    C2SCaptureExpires = 0
}

State.RuneTeleportData = State.RuneTeleportData or {}

-- =====================================================
-- GLOBAL CLICK SPEED (shared registry across tabs)
-- =====================================================
local GlobalClickCooldowns = {
    Default = 0.6
}

local function setGlobalClickCooldown(key, v)
    local k = key
    local value = v
    if value == nil and type(k) ~= "string" then
        value = k
        k = "Default"
    end
    k = k or "Default"
    local n = tonumber(value)
    if n then
        GlobalClickCooldowns[k] = math.clamp(n, 0.1, 10)
    end
    return GlobalClickCooldowns[k] or GlobalClickCooldowns.Default
end

local function getGlobalClickCooldown(key)
    local k = key or "Default"
    return GlobalClickCooldowns[k] or GlobalClickCooldowns.Default
end

ENV.GardenIncremental_SetClickCooldown = setGlobalClickCooldown
ENV.GardenIncremental_GetClickCooldown = getGlobalClickCooldown

local function trackConnection(conn)
    if conn then
        State.Connections[#State.Connections + 1] = conn
    end
    return conn
end

local function cleanupAll()
    for _, conn in ipairs(State.Connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    State.Connections = {}

    for _, conn in ipairs(State.RemoteConnections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    State.RemoteConnections = {}

    for obj, oldFn in pairs(State.RemoteInvokeOld) do
        pcall(function()
            if oldFn == true then
                obj.OnClientInvoke = nil
            else
                obj.OnClientInvoke = oldFn
            end
        end)
    end
    State.RemoteInvokeOld = {}

    if State.Hooked and State.Mt and State.OldNamecall then
        pcall(function()
            setreadonly(State.Mt, false)
            State.Mt.__namecall = State.OldNamecall
            setreadonly(State.Mt, true)
        end)
    end
    State.Hooked = false
    State.Mt = nil
    State.OldNamecall = nil

    if State.ScreenGui and State.ScreenGui.Parent then
        State.ScreenGui:Destroy()
    end
    State.ScreenGui = nil

    if ENV and ENV[GLOBAL_KEY] then
        ENV[GLOBAL_KEY] = nil
    end
end

ENV[GLOBAL_KEY] = State

-- [FUNC] Construct teleport data
local function makeData(pos, camCFrame, camFocus, fov, camType, zoom, minZoom, maxZoom)
    return {
        position = pos,
        camera = {
            cframe = camCFrame,
            focus = camFocus,
            fov = fov,
            type = camType,
            zoom = zoom,
            min_zoom = minZoom,
            max_zoom = maxZoom
        }
    }
end

local function isRuneLabel(label)
    if type(label) ~= "string" then
        return false
    end
    return string.find(string.lower(label), "rune", 1, true) ~= nil
end

local function registerRuneLocations(worldName, list)
    if type(worldName) ~= "string" or type(list) ~= "table" then
        return
    end
    local out = {}
    for _, item in ipairs(list) do
        if item and isRuneLabel(item.Label) and item.Data then
            out[#out + 1] = {
                Label = item.Label,
                Data = item.Data,
                Key = worldName .. " :: " .. tostring(item.Label)
            }
        end
    end
    State.RuneTeleportData[worldName] = out
end

-- =====================================================
-- EARLY LOG CAPTURE
-- =====================================================
local ConsoleLogBuffer = {}
local MaxConsoleLogs = 200
local function getLogHistoryErrors()
    if not LogService.GetLogHistory then
        return {}
    end
    local ok, history = pcall(function()
        return LogService:GetLogHistory()
    end)
    if not ok or type(history) ~= "table" then
        return {}
    end
    local out = {}
    for _, item in ipairs(history) do
        if item.messageType == Enum.MessageType.MessageError then
            out[#out + 1] = {
                Message = item.message,
                Type = item.messageType,
                Time = os.time()
            }
        end
    end
    return out
end
local function pushConsoleLog(message, msgType)
    if msgType ~= Enum.MessageType.MessageError then
        return
    end
    ConsoleLogBuffer[#ConsoleLogBuffer + 1] = {
        Message = message,
        Type = msgType,
        Time = os.time()
    }
    if #ConsoleLogBuffer > MaxConsoleLogs then
        table.remove(ConsoleLogBuffer, 1)
    end
end

trackConnection(LogService.MessageOut:Connect(function(message, msgType)
    pushConsoleLog(message, msgType)
end))

-- =====================================================
-- CONFIG SAVE / LOAD
-- =====================================================
local CONFIG_FOLDER = "FunScripts"
local CONFIG_FILE = CONFIG_FOLDER .. "/DemoConfig.json"

local Config = {
    InfiniteJump = false,
    WalkSpeed = 16,
    WalkSpeedEnabled = false,
    NoFog = false,
    NoFX = false,
    LowGraphics = false,
    FullBright = false,
    ManualFogStart = 100000,
    ManualFogEnd = 100000,
    DisableBloom = true,
    DisableBlur = true,
    DisableSunRays = true,
    DisableColorCorrection = true,
    ManualGraphicsQuality = "Level01",
    ManualGraphicsShadows = false,
    ManualBrightness = 2,
    ManualClockTime = 12,
    ManualFullBrightShadows = false,
    FirstRun = true,
    ActionLogger = false,
    RemoteSpy = false,
    RemoteLogger = false,
    Theme = "Default",
    LogFilter = "",
    WindowWidth = 640,
    WindowHeight = 430,
    HellStarterEnabled = false,
    HellStarterUseUpgradeAll = true,
    HellStarterSkipMaxed = true,
    HellStarterClickSpeed = 0.6,
    HellStarterTeleportEnabled = false,
    HellStarterTeleportHold = 15,
    HellStarterTeleportStep = 3,
    HellStarterItems = {},
    HellStarterDroppers = {},
    AutoReloadEnabled = false,
    AutoReloadSource = "",
    AutoReloadUrl = "",
    AutoReloadFile = ""
}

local MINIMIZE_ICON_URL = "https://img.icons8.com/liquid-glass/96/hacking.png"
local MINIMIZED_ICON_SIZE = 48
local function resolveMinimizeIcon()
    if getcustomasset and writefile and isfile and game and game.HttpGet then
        local iconPath = CONFIG_FOLDER .. "/minimize_icon.png"
        if not isfile(iconPath) then
            pcall(function()
                local data = game:HttpGet(MINIMIZE_ICON_URL)
                writefile(iconPath, data)
            end)
        end
        if isfile(iconPath) then
            local ok, asset = pcall(getcustomasset, iconPath)
            if ok and asset then
                return asset
            end
        end
    end
    return MINIMIZE_ICON_URL
end

local function loadConfig()
    if isfile and isfile(CONFIG_FILE) and readfile then
        local ok, data = pcall(readfile, CONFIG_FILE)
        if ok and data then
            local ok2, decoded = pcall(function()
                return HttpService:JSONDecode(data)
            end)
            if ok2 and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    if Config[k] ~= nil then
                        Config[k] = v
                    end
                end
            end
        end
    end
end

local function saveConfig()
    if writefile and makefolder then
        if not (isfolder and isfolder(CONFIG_FOLDER)) then
            pcall(makefolder, CONFIG_FOLDER)
        end
        local ok, encoded = pcall(function()
            return HttpService:JSONEncode(Config)
        end)
        if ok and encoded then
            pcall(writefile, CONFIG_FILE, encoded)
        end
    end
end

loadConfig()

if Config.FirstRun then
    Config.NoFog = false
    Config.NoFX = false
    Config.LowGraphics = false
    Config.FullBright = false
    Config.FirstRun = false
    saveConfig()
end

-- =====================================================
-- AUTO RELOAD ON TELEPORT/RECONNECT
-- =====================================================
local function trimText(v)
    if type(v) ~= "string" then
        return ""
    end
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readAutoReloadFile(pathValue)
    local path = trimText(pathValue)
    if #path == 0 then
        return nil, "missing"
    end
    if not readfile then
        return nil, "file_no_read"
    end
    if isfile and not isfile(path) then
        return nil, "file_missing"
    end
    local ok, data = pcall(readfile, path)
    if ok and type(data) == "string" and #data > 0 then
        return data, nil
    end
    return nil, "file_read_fail"
end

local function resolveAutoReloadSource()
    if ENV then
        local src = trimText(ENV.GardenIncremental_Source)
        if #src > 0 then
            return src, nil
        end
        local url = trimText(ENV.GardenIncremental_Url)
        if #url > 0 then
            return ("loadstring(game:HttpGet(%q))()"):format(url), nil
        end
        local fileSrc, fileErr = readAutoReloadFile(ENV.GardenIncremental_File)
        if fileSrc then
            return fileSrc, nil
        elseif fileErr and fileErr ~= "missing" then
            return nil, fileErr
        end
    end

    local cfgSrc = trimText(Config.AutoReloadSource)
    if #cfgSrc > 0 then
        return cfgSrc, nil
    end
    local cfgUrl = trimText(Config.AutoReloadUrl)
    if #cfgUrl > 0 then
        return ("loadstring(game:HttpGet(%q))()"):format(cfgUrl), nil
    end
    local cfgFileSrc, cfgFileErr = readAutoReloadFile(Config.AutoReloadFile)
    if cfgFileSrc then
        return cfgFileSrc, nil
    elseif cfgFileErr and cfgFileErr ~= "missing" then
        return nil, cfgFileErr
    end

    return nil, "missing"
end

local function queueOnTeleport(code)
    if type(code) ~= "string" or #code == 0 then
        return false
    end
    local q = queue_on_teleport
        or queueonteleport
        or (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
    if type(q) ~= "function" then
        return false
    end
    local ok = pcall(q, code)
    return ok == true
end

local function applyAutoReloadQueue()
    if not Config.AutoReloadEnabled then
        return false, "disabled"
    end
    local src, reason = resolveAutoReloadSource()
    if not src then
        return false, reason or "missing"
    end
    local ok = queueOnTeleport(src)
    return ok == true, ok and "queued" or "noqueue"
end

if Config.AutoReloadEnabled then
    local ok, reason = applyAutoReloadQueue()
    if not ok then
        if reason == "missing" then
            warn("[GardenIncremental] AutoReloadEnabled=true tapi sumber script belum diset.")
        elseif reason == "noqueue" then
            warn("[GardenIncremental] queue_on_teleport tidak tersedia.")
        elseif reason == "file_missing" then
            warn("[GardenIncremental] AutoReloadFile tidak ditemukan.")
        elseif reason == "file_no_read" then
            warn("[GardenIncremental] readfile tidak tersedia.")
        elseif reason == "file_read_fail" then
            warn("[GardenIncremental] gagal membaca AutoReloadFile.")
        end
    end
end

-- =====================================================
-- THEME SYSTEM
-- =====================================================
local Themes = {
    Default = {
        Main = Color3.fromRGB(30, 30, 36),
        Panel = Color3.fromRGB(40, 40, 48),
        Accent = Color3.fromRGB(0, 170, 255),
        Text = Color3.fromRGB(235, 235, 235),
        Muted = Color3.fromRGB(170, 170, 170)
    },
    Dark = {
        Main = Color3.fromRGB(20, 20, 24),
        Panel = Color3.fromRGB(32, 32, 40),
        Accent = Color3.fromRGB(255, 120, 0),
        Text = Color3.fromRGB(235, 235, 235),
        Muted = Color3.fromRGB(150, 150, 150)
    },
    Light = {
        Main = Color3.fromRGB(235, 235, 235),
        Panel = Color3.fromRGB(250, 250, 250),
        Accent = Color3.fromRGB(0, 120, 255),
        Text = Color3.fromRGB(35, 35, 35),
        Muted = Color3.fromRGB(90, 90, 90)
    },
    Ocean = {
        Main = Color3.fromRGB(16, 26, 36),
        Panel = Color3.fromRGB(22, 36, 48),
        Accent = Color3.fromRGB(0, 200, 200),
        Text = Color3.fromRGB(220, 240, 245),
        Muted = Color3.fromRGB(140, 170, 180)
    }
}

local ThemeRegistry = {}
local function registerTheme(inst, prop, role)
    ThemeRegistry[#ThemeRegistry + 1] = {inst = inst, prop = prop, role = role}
end

local ToggleRenders = {}
local TabButtons = {}
local ActiveTabButton
local NamecallLogHandler
local getMainRemote
local setRemoteHooking
local addLogEntry
local addLog
local confirmDialog
local TeleportButtons = {}
local ActiveTeleportButton
local setupAutoShop

local function applyTheme(name)
    local t = Themes[name] or Themes.Default
    for _, item in ipairs(ThemeRegistry) do
        if item.inst and item.inst.Parent then
            item.inst[item.prop] = t[item.role]
        end
    end
    for _, render in ipairs(ToggleRenders) do
        pcall(render)
    end
    for _, btn in ipairs(TabButtons) do
        if btn and btn.Parent then
            local indicator = btn:FindFirstChild("ActiveIndicator")
            if btn == ActiveTabButton then
                btn.BackgroundColor3 = t.Panel
                btn.TextColor3 = t.Text
                if indicator then
                    indicator.BackgroundColor3 = t.Accent
                    indicator.Visible = true
                end
            else
                btn.BackgroundColor3 = t.Main
                btn.TextColor3 = t.Muted
                if indicator then
                    indicator.Visible = false
                end
            end
        end
    end
    for _, btn in ipairs(TeleportButtons) do
        if btn and btn.Parent then
            if btn == ActiveTeleportButton then
                btn.BackgroundColor3 = t.Accent
                btn.TextColor3 = Color3.new(1, 1, 1)
            else
                btn.BackgroundColor3 = t.Main
                btn.TextColor3 = t.Text
            end
        end
    end
end

-- =====================================================
-- UI ROOT
-- =====================================================
pcall(function()
    local cg = game:GetService("CoreGui")
    local oldGui = cg:FindFirstChild("GardenIncrementalUI")
    if oldGui then
        oldGui:Destroy()
    end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "GardenIncrementalUI"
ScreenGui.ResetOnSpawn = false

if gethui then
    ScreenGui.Parent = gethui()
elseif syn and syn.protect_gui then
    syn.protect_gui(ScreenGui)
    ScreenGui.Parent = game:GetService("CoreGui")
else
    ScreenGui.Parent = game:GetService("CoreGui")
end
State.ScreenGui = ScreenGui

local function addCorner(inst, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 6)
    corner.Parent = inst
    return corner
end

local function addStroke(inst, role, thickness, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = thickness or 1
    stroke.Transparency = transparency or 0.55
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = inst
    if role then
        registerTheme(stroke, "Color", role)
    end
    return stroke
end

local function addGradient(inst, rotation, alphaStart, alphaEnd)
    local grad = Instance.new("UIGradient")
    grad.Rotation = rotation or 90
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, alphaStart or 0),
        NumberSequenceKeypoint.new(1, alphaEnd or 0.25)
    })
    grad.Parent = inst
    return grad
end

local function createLoadingUI()
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0, 320, 0, 130)
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.new(0.5, 0, 0.5, 0)
    card.BorderSizePixel = 0
    card.ZIndex = 101
    card.Parent = ScreenGui
    registerTheme(card, "BackgroundColor3", "Panel")
    addCorner(card, 10)
    addStroke(card, "Muted", 1, 0.7)
    local scale = Instance.new("UIScale")
    scale.Parent = card

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 24)
    title.Position = UDim2.new(0, 10, 0, 10)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Loading UI..."
    title.ZIndex = 102
    title.Parent = card
    registerTheme(title, "TextColor3", "Text")

    local percentLabel = Instance.new("TextLabel")
    percentLabel.Size = UDim2.new(0, 60, 0, 20)
    percentLabel.Position = UDim2.new(1, -70, 0, 12)
    percentLabel.BackgroundTransparency = 1
    percentLabel.Font = Enum.Font.Gotham
    percentLabel.TextSize = 12
    percentLabel.TextXAlignment = Enum.TextXAlignment.Right
    percentLabel.Text = "0%"
    percentLabel.ZIndex = 102
    percentLabel.Parent = card
    registerTheme(percentLabel, "TextColor3", "Muted")

    local barBg = Instance.new("Frame")
    barBg.Size = UDim2.new(1, -20, 0, 10)
    barBg.Position = UDim2.new(0, 10, 0, 52)
    barBg.BorderSizePixel = 0
    barBg.ZIndex = 102
    barBg.Parent = card
    registerTheme(barBg, "BackgroundColor3", "Main")
    addCorner(barBg, 6)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.new(0, 0, 1, 0)
    barFill.BorderSizePixel = 0
    barFill.ZIndex = 103
    barFill.Parent = barBg
    registerTheme(barFill, "BackgroundColor3", "Accent")
    addCorner(barFill, 6)

    local note = Instance.new("TextLabel")
    note.Size = UDim2.new(1, -20, 0, 30)
    note.Position = UDim2.new(0, 10, 0, 74)
    note.BackgroundTransparency = 1
    note.Font = Enum.Font.Gotham
    note.TextSize = 12
    note.TextXAlignment = Enum.TextXAlignment.Left
    note.TextWrapped = true
    note.Text = "Menyiapkan modul UI..."
    note.ZIndex = 102
    note.Parent = card
    registerTheme(note, "TextColor3", "Muted")

    return {
        Card = card,
        Scale = scale,
        Set = function(_, percent, text)
            local clamped = math.clamp(math.floor(percent or 0), 0, 100)
            percentLabel.Text = tostring(clamped) .. "%"
            barFill.Size = UDim2.new(clamped / 100, 0, 1, 0)
            if text then
                note.Text = text
            end
        end
    }
end

local LoadingUI = createLoadingUI()
LoadingUI:Set(2, "Menyiapkan tema...")
applyTheme(Config.Theme or "Default")

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, Config.WindowWidth or 640, 0, Config.WindowHeight or 430)
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.new(0.5, 0, 0.5, 0)
Main.BorderSizePixel = 0
Main.Parent = ScreenGui
Main.Visible = false
registerTheme(Main, "BackgroundColor3", "Main")
addCorner(Main, 10)
addStroke(Main, "Muted", 1, 0.6)
addGradient(Main, 90, 0, 0.15)

local function computeUIScale()
    local cam = workspace.CurrentCamera
    if not cam then return 1 end
    local vp = cam.ViewportSize
    if not vp or vp.X <= 0 or vp.Y <= 0 then return 1 end
    local baseW, baseH = 1280, 720
    local scale = math.min(vp.X / baseW, vp.Y / baseH)
    return math.clamp(scale, 0.65, 1.15)
end

local MainScale = Instance.new("UIScale")
MainScale.Scale = computeUIScale()
MainScale.Parent = Main

if LoadingUI.Scale then
    LoadingUI.Scale.Scale = MainScale.Scale
end

trackConnection(RunService.RenderStepped:Connect(function()
    local newScale = computeUIScale()
    if math.abs(newScale - MainScale.Scale) > 0.01 then
        MainScale.Scale = newScale
        if LoadingUI.Scale then
            LoadingUI.Scale.Scale = newScale
        end
    end
end))

local TitleBar = Instance.new("TextLabel")
TitleBar.Size = UDim2.new(1, -120, 0, 32)
TitleBar.Position = UDim2.new(0, 12, 0, 0)
TitleBar.BackgroundTransparency = 1
TitleBar.Text = "Garden Incremental"
TitleBar.Font = Enum.Font.GothamSemibold
TitleBar.TextSize = 16
TitleBar.TextXAlignment = Enum.TextXAlignment.Left
TitleBar.Parent = Main
registerTheme(TitleBar, "TextColor3", "Text")

local VersionLabel = Instance.new("TextLabel")
VersionLabel.Size = UDim2.new(0, 60, 0, 18)
VersionLabel.Position = UDim2.new(1, -124, 0, 7)
VersionLabel.BackgroundTransparency = 1
VersionLabel.Font = Enum.Font.Gotham
VersionLabel.TextSize = 12
VersionLabel.TextXAlignment = Enum.TextXAlignment.Right
VersionLabel.Text = "V1.0.0"
VersionLabel.Parent = Main
registerTheme(VersionLabel, "TextColor3", "Muted")

local AccentLine = Instance.new("Frame")
AccentLine.Size = UDim2.new(1, 0, 0, 2)
AccentLine.Position = UDim2.new(0, 0, 0, 30)
AccentLine.BorderSizePixel = 0
AccentLine.Parent = Main
registerTheme(AccentLine, "BackgroundColor3", "Accent")

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Size = UDim2.new(0, 24, 0, 20)
MinimizeBtn.Position = UDim2.new(1, -58, 0, 6)
MinimizeBtn.BorderSizePixel = 0
MinimizeBtn.Text = "-"
MinimizeBtn.AutoButtonColor = false
MinimizeBtn.Font = Enum.Font.GothamSemibold
MinimizeBtn.TextSize = 14
MinimizeBtn.Parent = Main
registerTheme(MinimizeBtn, "BackgroundColor3", "Panel")
registerTheme(MinimizeBtn, "TextColor3", "Text")
addCorner(MinimizeBtn, 4)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 24, 0, 20)
CloseBtn.Position = UDim2.new(1, -30, 0, 6)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "x"
CloseBtn.AutoButtonColor = false
CloseBtn.Font = Enum.Font.GothamSemibold
CloseBtn.TextSize = 12
CloseBtn.Parent = Main
registerTheme(CloseBtn, "BackgroundColor3", "Panel")
registerTheme(CloseBtn, "TextColor3", "Text")
addCorner(CloseBtn, 4)

local MinimizedIcon = Instance.new("ImageButton")
MinimizedIcon.Size = UDim2.new(1, 0, 1, 0)
MinimizedIcon.Position = UDim2.new(0, 0, 0, 0)
MinimizedIcon.BorderSizePixel = 0
MinimizedIcon.AutoButtonColor = false
MinimizedIcon.Active = true
MinimizedIcon.Visible = false
MinimizedIcon.Parent = Main
registerTheme(MinimizedIcon, "BackgroundColor3", "Panel")
MinimizedIcon.Image = resolveMinimizeIcon()
MinimizedIcon.ScaleType = Enum.ScaleType.Fit
MinimizedIcon.ImageTransparency = 0
addCorner(MinimizedIcon, 10)
addStroke(MinimizedIcon, "Muted", 1, 0.6)

local Minimized = false
local Dragging = false
local DragMoved = false
local DragStart, StartPos

local function setMainAnchorTopRight()
    local absPos = Main.AbsolutePosition
    local absSize = Main.AbsoluteSize
    Main.AnchorPoint = Vector2.new(1, 0)
    Main.Position = UDim2.new(0, absPos.X + absSize.X, 0, absPos.Y)
end

setMainAnchorTopRight()

trackConnection(TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        Dragging = true
        DragMoved = false
        DragStart = input.Position
        StartPos = Main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                Dragging = false
            end
        end)
    end
end))

trackConnection(MinimizedIcon.InputBegan:Connect(function(input)
    if not Minimized then
        return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        Dragging = true
        DragMoved = false
        DragStart = input.Position
        StartPos = Main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                Dragging = false
            end
        end)
    end
end))

trackConnection(UIS.InputChanged:Connect(function(input)
    if Dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - DragStart
        if delta.Magnitude > 3 then
            DragMoved = true
        end
        Main.Position = UDim2.new(StartPos.X.Scale, StartPos.X.Offset + delta.X, StartPos.Y.Scale, StartPos.Y.Offset + delta.Y)
    end
end))

local Body = Instance.new("Frame")
Body.Size = UDim2.new(1, 0, 1, -32)
Body.Position = UDim2.new(0, 0, 0, 32)
Body.BorderSizePixel = 0
Body.Parent = Main
registerTheme(Body, "BackgroundColor3", "Panel")
addCorner(Body, 8)

local ResizeHandles = {}
local function createResizeHandle(name, size, pos, cursor)
    local h = Instance.new("Frame")
    h.Name = name
    h.Size = size
    h.Position = pos
    h.BackgroundTransparency = 1
    h.BorderSizePixel = 0
    h.Parent = Main
    h.Active = true
    h.ZIndex = 10
    ResizeHandles[#ResizeHandles + 1] = h
    return h
end

createResizeHandle("ResizeLeft", UDim2.new(0, 6, 1, -12), UDim2.new(0, -3, 0, 6))
createResizeHandle("ResizeRight", UDim2.new(0, 6, 1, -12), UDim2.new(1, -3, 0, 6))
createResizeHandle("ResizeTop", UDim2.new(1, -12, 0, 6), UDim2.new(0, 6, 0, -3))
createResizeHandle("ResizeBottom", UDim2.new(1, -12, 0, 6), UDim2.new(0, 6, 1, -3))
createResizeHandle("ResizeBottomRight", UDim2.new(0, 12, 0, 12), UDim2.new(1, -12, 1, -12))
createResizeHandle("ResizeBottomLeft", UDim2.new(0, 12, 0, 12), UDim2.new(0, 0, 1, -12))
createResizeHandle("ResizeTopRight", UDim2.new(0, 12, 0, 12), UDim2.new(1, -12, 0, 0))
createResizeHandle("ResizeTopLeft", UDim2.new(0, 12, 0, 12), UDim2.new(0, 0, 0, 0))

local SavedSize = Main.Size
local SavedPos = Main.Position
local function setMinimized(state)
    Minimized = state
    if Minimized then
        SavedSize = Main.Size
        local absPos = Main.AbsolutePosition
        local absSize = Main.AbsoluteSize
        SavedPos = UDim2.new(0, absPos.X + absSize.X, 0, absPos.Y)
        Main.AnchorPoint = Vector2.new(1, 0)
        Main.Position = SavedPos
        Body.Visible = false
        TitleBar.Visible = false
        AccentLine.Visible = false
        MinimizeBtn.Visible = false
        CloseBtn.Visible = false
        for _, h in ipairs(ResizeHandles) do
            h.Visible = false
            h.Active = false
        end
        Main.Size = UDim2.new(0, MINIMIZED_ICON_SIZE, 0, MINIMIZED_ICON_SIZE)
        MinimizedIcon.Visible = true
        MinimizeBtn.Text = "+"
    else
        Body.Visible = true
        TitleBar.Visible = true
        AccentLine.Visible = true
        MinimizeBtn.Visible = true
        CloseBtn.Visible = true
        for _, h in ipairs(ResizeHandles) do
            h.Visible = true
            h.Active = true
        end
        Main.AnchorPoint = Vector2.new(1, 0)
        Main.Position = SavedPos
        Main.Size = SavedSize
        MinimizedIcon.Visible = false
        MinimizeBtn.Text = "-"
    end
end

trackConnection(MinimizeBtn.MouseButton1Click:Connect(function()
    setMinimized(not Minimized)
end))

trackConnection(MinimizedIcon.MouseButton1Click:Connect(function()
    if Minimized then
        if DragMoved then
            DragMoved = false
            return
        end
        setMinimized(false)
    end
end))

trackConnection(CloseBtn.MouseButton1Click:Connect(function()
    confirmDialog("Konfirmasi", "Apakah anda yakin ingin keluar dari script?", function()
        cleanupAll()
    end)
end))

local Resizing = false
local ResizeDir = nil
local ResizeStartPos
local ResizeStartSize
local ResizeStartMainPos
local MinSize = Vector2.new(520, 320)
local ResizeClickCount = 0
local ResizeClickTime = 0
local ResizeClickHandle = nil

local function centerMain()
    Main.Position = UDim2.new(0.5, 0, 0.5, 0)
end

local function beginResize(dir, input)
    if Minimized then
        return
    end
    Resizing = true
    ResizeDir = dir
    ResizeStartPos = input.Position
    ResizeStartSize = Main.Size
    ResizeStartMainPos = Main.Position
end

local function updateResize(input)
    if not Resizing then return end
    local delta = input.Position - ResizeStartPos
    local newSize = ResizeStartSize
    local newPos = ResizeStartMainPos

    if ResizeDir == "Left" or ResizeDir == "TopLeft" or ResizeDir == "BottomLeft" then
        local newW = math.max(MinSize.X, ResizeStartSize.X.Offset - delta.X)
        local dx = ResizeStartSize.X.Offset - newW
        newSize = UDim2.new(0, newW, newSize.Y.Scale, newSize.Y.Offset)
        newPos = UDim2.new(newPos.X.Scale, newPos.X.Offset + dx, newPos.Y.Scale, newPos.Y.Offset)
    end
    if ResizeDir == "Right" or ResizeDir == "TopRight" or ResizeDir == "BottomRight" then
        local newW = math.max(MinSize.X, ResizeStartSize.X.Offset + delta.X)
        newSize = UDim2.new(0, newW, newSize.Y.Scale, newSize.Y.Offset)
    end
    if ResizeDir == "Top" or ResizeDir == "TopLeft" or ResizeDir == "TopRight" then
        local newH = math.max(MinSize.Y, ResizeStartSize.Y.Offset - delta.Y)
        local dy = ResizeStartSize.Y.Offset - newH
        newSize = UDim2.new(newSize.X.Scale, newSize.X.Offset, 0, newH)
        newPos = UDim2.new(newPos.X.Scale, newPos.X.Offset, newPos.Y.Scale, newPos.Y.Offset + dy)
    end
    if ResizeDir == "Bottom" or ResizeDir == "BottomLeft" or ResizeDir == "BottomRight" then
        local newH = math.max(MinSize.Y, ResizeStartSize.Y.Offset + delta.Y)
        newSize = UDim2.new(newSize.X.Scale, newSize.X.Offset, 0, newH)
    end

    Main.Size = newSize
    Main.Position = newPos
end

local function endResize()
    Resizing = false
    ResizeDir = nil
    if Main and Main.Size then
        Config.WindowWidth = Main.Size.X.Offset
        Config.WindowHeight = Main.Size.Y.Offset
        saveConfig()
    end
end

local handleMap = {
    ResizeLeft = "Left",
    ResizeRight = "Right",
    ResizeTop = "Top",
    ResizeBottom = "Bottom",
    ResizeTopLeft = "TopLeft",
    ResizeTopRight = "TopRight",
    ResizeBottomLeft = "BottomLeft",
    ResizeBottomRight = "BottomRight"
}

for _, h in ipairs(ResizeHandles) do
    trackConnection(h.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local now = os.clock()
            if ResizeClickHandle ~= h or (now - ResizeClickTime) > 0.35 then
                ResizeClickCount = 0
            end
            ResizeClickCount += 1
            ResizeClickTime = now
            ResizeClickHandle = h
            if ResizeClickCount >= 3 then
                ResizeClickCount = 0
                centerMain()
                return
            end
            beginResize(handleMap[h.Name], input)
        end
    end))
end

trackConnection(UIS.InputChanged:Connect(function(input)
    if Resizing and input.UserInputType == Enum.UserInputType.MouseMovement then
        updateResize(input)
    end
end))

trackConnection(UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        endResize()
        if Dragging then
            SavedPos = Main.Position
        end
    end
end))

local TabBar = Instance.new("ScrollingFrame")
TabBar.Size = UDim2.new(0, 180, 1, 0)
TabBar.BorderSizePixel = 0
TabBar.Parent = Body
TabBar.CanvasSize = UDim2.new(0, 0, 0, 0)
TabBar.AutomaticCanvasSize = Enum.AutomaticSize.Y
TabBar.ScrollBarThickness = 6
TabBar.ScrollingDirection = Enum.ScrollingDirection.Y
TabBar.ClipsDescendants = true
registerTheme(TabBar, "BackgroundColor3", "Main")
addCorner(TabBar, 8)
addStroke(TabBar, "Muted", 1, 0.8)

local TabList = Instance.new("UIListLayout")
TabList.Padding = UDim.new(0, 6)
TabList.SortOrder = Enum.SortOrder.LayoutOrder
TabList.Parent = TabBar
TabList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    TabBar.CanvasSize = UDim2.new(0, 0, 0, TabList.AbsoluteContentSize.Y + 16)
end)

local TabPadding = Instance.new("UIPadding")
TabPadding.PaddingTop = UDim.new(0, 8)
TabPadding.PaddingLeft = UDim.new(0, 8)
TabPadding.PaddingRight = UDim.new(0, 8)
TabPadding.PaddingBottom = UDim.new(0, 8)
TabPadding.Parent = TabBar

local Pages = Instance.new("Frame")
Pages.Size = UDim2.new(1, -180, 1, 0)
Pages.Position = UDim2.new(0, 180, 0, 0)
Pages.BorderSizePixel = 0
Pages.Parent = Body
registerTheme(Pages, "BackgroundColor3", "Panel")
addCorner(Pages, 8)

LoadingUI:Set(15, "Menyusun layout...")

local function createTabButton(text)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 30)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamSemibold
    btn.TextSize = 13
    btn.Text = text
    btn.AutoButtonColor = false
    btn.Parent = TabBar
    registerTheme(btn, "BackgroundColor3", "Main")
    registerTheme(btn, "TextColor3", "Muted")
    addCorner(btn, 6)
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 12)
    pad.Parent = btn
    local indicator = Instance.new("Frame")
    indicator.Name = "ActiveIndicator"
    indicator.Size = UDim2.new(0, 3, 1, -10)
    indicator.Position = UDim2.new(0, 4, 0, 5)
    indicator.BorderSizePixel = 0
    indicator.Parent = btn
    indicator.Visible = false
    TabButtons[#TabButtons + 1] = btn
    return btn
end

local function createTabDivider()
    local div = Instance.new("Frame")
    div.Size = UDim2.new(1, 0, 0, 2)
    div.BorderSizePixel = 0
    div.Parent = TabBar
    registerTheme(div, "BackgroundColor3", "Muted")
    return div
end

local function createPage()
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BorderSizePixel = 0
    page.Visible = false
    page.Parent = Pages
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.ScrollBarThickness = 6
    page.ScrollingDirection = Enum.ScrollingDirection.Y
    page.ClipsDescendants = true
    registerTheme(page, "BackgroundColor3", "Panel")

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = page
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 20)
    end)

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.Parent = page

    return page
end

local function createSection(parent, title)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 24)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 13
    label.Text = title
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = parent
    registerTheme(label, "TextColor3", "Text")
    return label
end

local function createSubSection(parent, title)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 20)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = title
    label.Parent = parent
    registerTheme(label, "TextColor3", "Muted")
    return label
end

local function createSectionBox(parent, title)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, 0, 0, 0)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.BorderSizePixel = 0
    container.Parent = parent
    registerTheme(container, "BackgroundColor3", "Panel")
    addCorner(container, 8)
    addStroke(container, "Muted", 1, 0.8)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = container

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 22)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 13
    label.Text = title
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = container
    registerTheme(label, "TextColor3", "Text")

    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, 0, 0, 1)
    divider.BorderSizePixel = 0
    divider.Parent = container
    registerTheme(divider, "BackgroundColor3", "Muted")

    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.BackgroundTransparency = 1
    content.Parent = container

    local stack = Instance.new("UIListLayout")
    stack.Padding = UDim.new(0, 8)
    stack.SortOrder = Enum.SortOrder.LayoutOrder
    stack.Parent = container

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 8)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = content

    return content
end

local function createSubSectionBox(parent, title)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, 0, 0, 0)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.BorderSizePixel = 0
    container.Parent = parent
    registerTheme(container, "BackgroundColor3", "Main")
    addCorner(container, 8)
    addStroke(container, "Muted", 1, 0.85)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 10)
    pad.PaddingRight = UDim.new(0, 10)
    pad.Parent = container

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 20)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 11
    label.Text = title
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = container
    registerTheme(label, "TextColor3", "Muted")

    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.BackgroundTransparency = 1
    content.Parent = container

    local stack = Instance.new("UIListLayout")
    stack.Padding = UDim.new(0, 6)
    stack.SortOrder = Enum.SortOrder.LayoutOrder
    stack.Parent = container

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 6)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = content

    return content
end

local function createParagraph(parent, title, content)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = frame

    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1, 0, 0, 18)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamSemibold
    t.TextSize = 12
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Text = title
    t.Parent = frame
    registerTheme(t, "TextColor3", "Text")

    local c = Instance.new("TextLabel")
    c.Size = UDim2.new(1, 0, 0, 0)
    c.AutomaticSize = Enum.AutomaticSize.Y
    c.BackgroundTransparency = 1
    c.Font = Enum.Font.Gotham
    c.TextSize = 12
    c.TextWrapped = true
    c.TextXAlignment = Enum.TextXAlignment.Left
    c.TextYAlignment = Enum.TextYAlignment.Top
    c.Text = content
    c.Parent = frame
    registerTheme(c, "TextColor3", "Muted")

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 4)
    list.Parent = frame

    return {
        Destroy = function()
            frame:Destroy()
        end
    }
end

local function createInput(parent, text, flag, currentValue, callback)
    local value = currentValue or ""
    if flag and Config[flag] ~= nil then
        value = tostring(Config[flag])
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 30)
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0, 120, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text
    label.Parent = frame
    registerTheme(label, "TextColor3", "Text")

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -130, 1, -8)
    box.Position = UDim2.new(0, 125, 0, 4)
    box.BorderSizePixel = 0
    box.ClearTextOnFocus = false
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.Text = value
    box.Parent = frame
    registerTheme(box, "BackgroundColor3", "Panel")
    registerTheme(box, "TextColor3", "Text")
    addCorner(box, 6)

    local disabled = false

    local function setValue(v, silent)
        value = v or ""
        if flag then
            Config[flag] = value
            saveConfig()
        end
        if callback and not silent then
            callback(value)
        end
    end

    box.FocusLost:Connect(function()
        if disabled then
            return
        end
        setValue(box.Text, false)
    end)

    if callback then
        callback(value)
    end

    return {
        Set = function(_, v)
            box.Text = v or ""
            setValue(box.Text, true)
        end,
        Get = function()
            return value
        end,
        SetEnabled = function(_, enabled)
            disabled = not enabled
            label.TextTransparency = disabled and 0.4 or 0
            box.TextTransparency = disabled and 0.4 or 0
            box.Active = enabled
            if box:IsA("TextBox") then
                box.TextEditable = enabled
            end
        end,
        Frame = frame,
        Box = box,
        Label = label,
        Destroy = function()
            frame:Destroy()
        end
    }
end

local function createContainer(parent, height)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, height or 160)
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 6)
    pad.PaddingRight = UDim.new(0, 6)
    pad.Parent = frame

    return frame
end

local function createButton(parent, text, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 30)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
    btn.Text = text
    btn.AutoButtonColor = false
    btn.Parent = parent
    registerTheme(btn, "BackgroundColor3", "Main")
    registerTheme(btn, "TextColor3", "Text")
    addCorner(btn, 6)

    local disabled = false

    btn.MouseButton1Click:Connect(function()
        if disabled then
            return
        end
        if callback then
            callback()
        end
    end)

    return {
        Button = btn,
        Frame = btn,
        SetEnabled = function(_, enabled)
            disabled = not enabled
            btn.TextTransparency = disabled and 0.4 or 0
        end,
        Destroy = function()
            btn:Destroy()
        end
    }
end

local function createToggle(parent, text, flag, currentValue, callback)
    local state = currentValue
    if flag and Config[flag] ~= nil then
        state = Config[flag]
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 30)
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -50, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text
    label.Parent = frame
    registerTheme(label, "TextColor3", "Text")

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 40, 0, 20)
    btn.Position = UDim2.new(1, -45, 0.5, -10)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamSemibold
    btn.TextSize = 11
    btn.AutoButtonColor = false
    btn.Parent = frame
    addCorner(btn, 10)

    local disabled = false

    local function render()
        if state then
            btn.Text = "ON"
            btn.BackgroundColor3 = (Themes[Config.Theme] or Themes.Default).Accent
            btn.TextColor3 = Color3.new(1, 1, 1)
        else
            btn.Text = "OFF"
            btn.BackgroundColor3 = (Themes[Config.Theme] or Themes.Default).Panel
            btn.TextColor3 = (Themes[Config.Theme] or Themes.Default).Text
        end
    end

    local function setState(val, silent)
        state = val
        if flag then
            Config[flag] = val
            saveConfig()
        end
        render()
        if callback and not silent then
            callback(val)
        end
    end

    btn.MouseButton1Click:Connect(function()
        if disabled then
            return
        end
        setState(not state, false)
    end)

    render()
    ToggleRenders[#ToggleRenders + 1] = render
    if callback then
        callback(state)
    end

    return {
        Set = function(_, v)
            setState(v, true)
        end,
        Get = function()
            return state
        end,
        SetEnabled = function(_, enabled)
            disabled = not enabled
            label.TextTransparency = disabled and 0.4 or 0
            btn.TextTransparency = disabled and 0.4 or 0
        end,
        Frame = frame,
        Button = btn,
        Label = label,
        Destroy = function()
            frame:Destroy()
        end
    }
end

local function createSlider(parent, text, flag, rangeMin, rangeMax, currentValue, callback, decimals, formatFn)
    local value = currentValue
    if flag and Config[flag] ~= nil then
        value = Config[flag]
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 44)
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local function formatValue(v)
        if formatFn then
            local ok, res = pcall(formatFn, v)
            if ok and res ~= nil then
                return tostring(res)
            end
        end
        if type(decimals) == "number" then
            local d = math.clamp(math.floor(decimals + 0.5), 0, 6)
            return string.format("%." .. tostring(d) .. "f", v)
        end
        return tostring(v)
    end

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 18)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text .. ": " .. formatValue(value)
    label.Parent = frame
    registerTheme(label, "TextColor3", "Text")

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, -20, 0, 8)
    bar.Position = UDim2.new(0, 10, 0, 26)
    bar.BorderSizePixel = 0
    bar.Parent = frame
    registerTheme(bar, "BackgroundColor3", "Panel")
    addCorner(bar, 6)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BorderSizePixel = 0
    fill.Parent = bar
    registerTheme(fill, "BackgroundColor3", "Accent")
    addCorner(fill, 6)

    local function setValue(v, silent)
        value = math.clamp(v, rangeMin, rangeMax)
        label.Text = text .. ": " .. formatValue(value)
        fill.Size = UDim2.new((value - rangeMin) / (rangeMax - rangeMin), 0, 1, 0)
        if flag then
            Config[flag] = value
            saveConfig()
        end
        if callback and not silent then
            callback(value)
        end
    end

    local dragging = false
    local disabled = false
    bar.InputBegan:Connect(function(input)
        if disabled then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            local pos = (input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X
            setValue(rangeMin + (rangeMax - rangeMin) * pos, false)
        end
    end)

    trackConnection(UIS.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local pos = (input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X
            setValue(rangeMin + (rangeMax - rangeMin) * pos, false)
        end
    end))

    trackConnection(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))

    setValue(value, true)
    if callback then
        callback(value)
    end

    return {
        Set = function(_, v)
            setValue(v, true)
        end,
        Get = function()
            return value
        end,
        SetEnabled = function(_, enabled)
            disabled = not enabled
            label.TextTransparency = disabled and 0.4 or 0
            bar.BackgroundTransparency = disabled and 0.4 or 0
            fill.BackgroundTransparency = disabled and 0.4 or 0
        end,
        Destroy = function()
            frame:Destroy()
        end
    }
end

local function createDropdown(parent, text, flag, options, currentOption, callback)
    local selected = currentOption
    if flag and Config[flag] ~= nil then
        selected = Config[flag]
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 30)
    frame.BorderSizePixel = 0
    frame.Parent = parent
    registerTheme(frame, "BackgroundColor3", "Main")
    addCorner(frame, 6)
    addStroke(frame, "Muted", 1, 0.8)

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.AutoButtonColor = false
    btn.Text = text .. ": " .. tostring(selected)
    btn.Parent = frame
    registerTheme(btn, "TextColor3", "Text")

    local list = Instance.new("Frame")
    list.Size = UDim2.new(1, 0, 0, 0)
    list.Position = UDim2.new(0, 0, 1, 2)
    list.BorderSizePixel = 0
    list.Visible = false
    list.Parent = frame
    registerTheme(list, "BackgroundColor3", "Panel")
    addCorner(list, 6)

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 2)
    listLayout.Parent = list

    local function setSelected(v, silent)
        selected = v
        btn.Text = text .. ": " .. tostring(selected)
        if flag then
            Config[flag] = v
            saveConfig()
        end
        if callback and not silent then
            callback(v)
        end
    end

    for _, opt in ipairs(options) do
        local optBtn = Instance.new("TextButton")
        optBtn.Size = UDim2.new(1, 0, 0, 24)
        optBtn.BorderSizePixel = 0
        optBtn.Font = Enum.Font.Gotham
        optBtn.TextSize = 12
        optBtn.Text = tostring(opt)
        optBtn.AutoButtonColor = false
        optBtn.Parent = list
        registerTheme(optBtn, "BackgroundColor3", "Main")
        registerTheme(optBtn, "TextColor3", "Text")
        addCorner(optBtn, 6)

        optBtn.MouseButton1Click:Connect(function()
            list.Visible = false
            setSelected(opt, false)
        end)
    end

    btn.MouseButton1Click:Connect(function()
        list.Visible = not list.Visible
        list.Size = UDim2.new(1, 0, 0, #options * 26)
    end)

    setSelected(selected, true)
    if callback then
        callback(selected)
    end

    return {
        Set = function(_, v)
            setSelected(v, true)
        end,
        Get = function()
            return selected
        end,
        Destroy = function()
            frame:Destroy()
        end
    }
end

local function createTab(name)
    local tabButton = createTabButton(name)
    local page = createPage()

    local function setActive()
        for _, child in ipairs(Pages:GetChildren()) do
            if child:IsA("GuiObject") then
                child.Visible = false
            end
        end
        page.Visible = true

        ActiveTabButton = tabButton
        applyTheme(Config.Theme or "Default")
    end

    tabButton.MouseButton1Click:Connect(setActive)

    return {
        Show = setActive,
        GetPage = function()
            return page
        end,
        CreateSection = function(_, title)
            return createSection(page, title)
        end,
        CreateSubSection = function(_, title)
            return createSubSection(page, title)
        end,
        CreateParagraph = function(_, opts)
            return createParagraph(page, opts.Title, opts.Content)
        end,
        CreateInput = function(_, opts)
            return createInput(page, opts.Name, opts.Flag, opts.CurrentValue, opts.Callback)
        end,
        CreateContainer = function(_, height)
            return createContainer(page, height)
        end,
        CreateButton = function(_, opts)
            return createButton(page, opts.Name, opts.Callback)
        end,
        CreateToggle = function(_, opts)
            return createToggle(page, opts.Name, opts.Flag, opts.CurrentValue, opts.Callback)
        end,
        CreateSlider = function(_, opts)
            return createSlider(
                page,
                opts.Name,
                opts.Flag,
                opts.Range[1],
                opts.Range[2],
                opts.CurrentValue,
                opts.Callback,
                opts.Decimals,
                opts.Format
            )
        end,
        CreateDropdown = function(_, opts)
            return createDropdown(page, opts.Name, opts.Flag, opts.Options, opts.CurrentOption, opts.Callback)
        end
    }
end

-- =====================================================
-- NOTIFY
-- =====================================================
local function notify(title, content, duration)
    local notif = Instance.new("Frame")
    notif.Size = UDim2.new(0, 260, 0, 0)
    notif.AutomaticSize = Enum.AutomaticSize.Y
    notif.Position = UDim2.new(1, -270, 0, 10)
    notif.BorderSizePixel = 0
    notif.Parent = ScreenGui
    registerTheme(notif, "BackgroundColor3", "Main")
    addCorner(notif, 8)
    addStroke(notif, "Muted", 1, 0.8)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = notif

    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1, 0, 0, 18)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamSemibold
    t.TextSize = 12
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Text = title
    t.Parent = notif
    registerTheme(t, "TextColor3", "Text")

    local c = Instance.new("TextLabel")
    c.Size = UDim2.new(1, 0, 0, 0)
    c.AutomaticSize = Enum.AutomaticSize.Y
    c.BackgroundTransparency = 1
    c.Font = Enum.Font.Gotham
    c.TextSize = 12
    c.TextWrapped = true
    c.TextXAlignment = Enum.TextXAlignment.Left
    c.TextYAlignment = Enum.TextYAlignment.Top
    c.Text = content
    c.Parent = notif
    registerTheme(c, "TextColor3", "Muted")

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 4)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = notif

    local minSize = Instance.new("UISizeConstraint")
    minSize.MinSize = Vector2.new(260, 48)
    minSize.Parent = notif

    task.delay(duration or 4, function()
        if notif and notif.Parent then
            notif:Destroy()
        end
    end)
end

confirmDialog = function(title, content, onConfirm)
    local dialog = Instance.new("Frame")
    dialog.Size = UDim2.new(0, 320, 0, 0)
    dialog.AutomaticSize = Enum.AutomaticSize.Y
    dialog.Position = UDim2.new(0.5, -160, 0.5, 0)
    dialog.BorderSizePixel = 0
    dialog.Parent = ScreenGui
    dialog.ZIndex = 200
    registerTheme(dialog, "BackgroundColor3", "Main")
    addCorner(dialog, 10)
    addStroke(dialog, "Muted", 1, 0.6)
    addGradient(dialog, 90, 0, 0.15)

    local titleBar = Instance.new("TextLabel")
    titleBar.Size = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundTransparency = 1
    titleBar.Font = Enum.Font.GothamSemibold
    titleBar.TextSize = 14
    titleBar.TextXAlignment = Enum.TextXAlignment.Left
    titleBar.Text = title or "Konfirmasi"
    titleBar.ZIndex = 201
    titleBar.Parent = dialog
    registerTheme(titleBar, "TextColor3", "Text")

    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 2)
    line.Position = UDim2.new(0, 0, 0, 26)
    line.BorderSizePixel = 0
    line.Parent = dialog
    registerTheme(line, "BackgroundColor3", "Accent")

    local body = Instance.new("Frame")
    body.Size = UDim2.new(1, -16, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Position = UDim2.new(0, 8, 0, 32)
    body.BackgroundTransparency = 1
    body.Parent = dialog

    local c = Instance.new("TextLabel")
    c.Size = UDim2.new(1, 0, 0, 0)
    c.AutomaticSize = Enum.AutomaticSize.Y
    c.BackgroundTransparency = 1
    c.Font = Enum.Font.Gotham
    c.TextSize = 12
    c.TextWrapped = true
    c.TextXAlignment = Enum.TextXAlignment.Left
    c.TextYAlignment = Enum.TextYAlignment.Top
    c.Text = content
    c.ZIndex = 201
    c.Parent = body
    registerTheme(c, "TextColor3", "Muted")

    local btnRow = Instance.new("Frame")
    btnRow.Size = UDim2.new(1, 0, 0, 28)
    btnRow.BackgroundTransparency = 1
    btnRow.Parent = body
    btnRow.LayoutOrder = 2

    local btnYes = Instance.new("TextButton")
    btnYes.Size = UDim2.new(0.5, -6, 1, 0)
    btnYes.Position = UDim2.new(0, 0, 0, 0)
    btnYes.BorderSizePixel = 0
    btnYes.Text = "Keluar"
    btnYes.Font = Enum.Font.GothamSemibold
    btnYes.TextSize = 12
    btnYes.AutoButtonColor = false
    btnYes.Parent = btnRow
    btnYes.ZIndex = 201
    registerTheme(btnYes, "BackgroundColor3", "Accent")
    registerTheme(btnYes, "TextColor3", "Text")
    addCorner(btnYes, 6)

    local btnNo = Instance.new("TextButton")
    btnNo.Size = UDim2.new(0.5, -6, 1, 0)
    btnNo.Position = UDim2.new(0.5, 6, 0, 0)
    btnNo.BorderSizePixel = 0
    btnNo.Text = "Batal"
    btnNo.Font = Enum.Font.GothamSemibold
    btnNo.TextSize = 12
    btnNo.AutoButtonColor = false
    btnNo.Parent = btnRow
    btnNo.ZIndex = 201
    registerTheme(btnNo, "BackgroundColor3", "Main")
    registerTheme(btnNo, "TextColor3", "Text")
    addCorner(btnNo, 6)

    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 8)
    list.Parent = body

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 2)
    pad.PaddingRight = UDim.new(0, 2)
    pad.Parent = body

    btnYes.MouseButton1Click:Connect(function()
        if dialog then
            dialog:Destroy()
        end
        if onConfirm then
            onConfirm()
        end
    end)

    btnNo.MouseButton1Click:Connect(function()
        if dialog then
            dialog:Destroy()
        end
    end)
end

-- =====================================================
-- TABS
-- =====================================================
local teleportWithData
LoadingUI:Set(35, "Membuat tab utama...")
local HomeTab = createTab("Home")

notify("Script Loaded", "Script berhasil", 5)

HomeTab:CreateSection("Home")

local HomeTeleportData = {
    Label = "Default",
    Data = makeData(
        Vector3.new(-9.783, 19.500, -2.133),
        CFrame.new(-17.691278, 28.521162, -8.227553, -0.610420883, 0.476587325, -0.632653773, 0.000000000, 0.798727334, 0.601693094, 0.792077124, 0.367286026, -0.487559944),
        CFrame.new(-9.783107, 20.999998, -2.133054, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        12.500000,
        0.500,
        40.000
    )
}

HomeTab:CreateButton({
    Name = "Teleport to Home",
    Callback = function()
        teleportWithData(HomeTeleportData.Data)
    end
})

local function fireReincarnation()
    local remote = getMainRemote and getMainRemote() or nil
    if not remote then
        return
    end
    pcall(function()
        remote:FireServer("Reincarnation")
    end)
end

HomeTab:CreateButton({
    Name = "Reincarnation",
    Callback = function()
        fireReincarnation()
    end
})

HomeTab:CreateSection("Logging")

local HomeLogEnabled = false
local HomeLogConnection = nil
local HomeLogs = {}

local HomeLogContainer = HomeTab:CreateContainer(200)
local HomeLogTitle = Instance.new("TextLabel")
HomeLogTitle.Size = UDim2.new(1, 0, 0, 18)
HomeLogTitle.BackgroundTransparency = 1
HomeLogTitle.Font = Enum.Font.GothamSemibold
HomeLogTitle.TextSize = 12
HomeLogTitle.TextXAlignment = Enum.TextXAlignment.Left
HomeLogTitle.Text = "Logs (Developer Console Errors)"
HomeLogTitle.Parent = HomeLogContainer
registerTheme(HomeLogTitle, "TextColor3", "Text")

local HomeLogScroll = Instance.new("ScrollingFrame")
HomeLogScroll.Size = UDim2.new(1, 0, 1, -22)
HomeLogScroll.Position = UDim2.new(0, 0, 0, 20)
HomeLogScroll.BorderSizePixel = 0
HomeLogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
HomeLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
HomeLogScroll.ScrollBarThickness = 6
HomeLogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
HomeLogScroll.ClipsDescendants = true
HomeLogScroll.Parent = HomeLogContainer
registerTheme(HomeLogScroll, "BackgroundColor3", "Panel")

local HomeLogList = Instance.new("UIListLayout")
HomeLogList.Padding = UDim.new(0, 6)
HomeLogList.SortOrder = Enum.SortOrder.LayoutOrder
HomeLogList.Parent = HomeLogScroll

trackConnection(HomeLogList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    HomeLogScroll.CanvasSize = UDim2.new(0, 0, 0, HomeLogList.AbsoluteContentSize.Y + 12)
end))

local HomeLogPad = Instance.new("UIPadding")
HomeLogPad.PaddingTop = UDim.new(0, 6)
HomeLogPad.PaddingBottom = UDim.new(0, 6)
HomeLogPad.PaddingLeft = UDim.new(0, 6)
HomeLogPad.PaddingRight = UDim.new(0, 6)
HomeLogPad.Parent = HomeLogScroll

local function clearHomeLogs()
    for i = #HomeLogs, 1, -1 do
        if HomeLogs[i].Frame then
            HomeLogs[i].Frame:Destroy()
        end
        table.remove(HomeLogs, i)
    end
end

local function addHomeLogEntry(msg)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BorderSizePixel = 0
    frame.Parent = HomeLogScroll
    registerTheme(frame, "BackgroundColor3", "Main")

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = frame

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 18)
    header.BackgroundTransparency = 1
    header.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 1, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Error"
    title.Parent = header
    registerTheme(title, "TextColor3", "Text")

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 50, 1, 0)
    copyBtn.Position = UDim2.new(1, -55, 0, 0)
    copyBtn.BorderSizePixel = 0
    copyBtn.Font = Enum.Font.Gotham
    copyBtn.TextSize = 11
    copyBtn.Text = "Copy"
    copyBtn.AutoButtonColor = false
    copyBtn.Parent = header
    registerTheme(copyBtn, "BackgroundColor3", "Panel")
    registerTheme(copyBtn, "TextColor3", "Text")

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Gotham
    body.TextSize = 12
    body.TextWrapped = true
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.Text = msg
    body.Parent = frame
    registerTheme(body, "TextColor3", "Muted")

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 4)
    list.Parent = frame

    copyBtn.MouseButton1Click:Connect(function()
        if setclipboard then
            setclipboard(msg)
            notify("Copied", "Log disalin ke clipboard", 2)
        else
            notify("Copy Failed", "setclipboard tidak tersedia", 2)
        end
    end)

    HomeLogs[#HomeLogs + 1] = {Frame = frame, Text = msg}
end

local function loadHomeLogsFromBuffer()
    clearHomeLogs()
    local history = getLogHistoryErrors()
    for _, item in ipairs(history) do
        addHomeLogEntry(item.Message)
    end
    for _, item in ipairs(ConsoleLogBuffer) do
        addHomeLogEntry(item.Message)
    end
end

HomeTab:CreateToggle({
    Name = "Enable Logging",
    CurrentValue = false,
    Callback = function(v)
        HomeLogEnabled = v
        if HomeLogEnabled then
            loadHomeLogsFromBuffer()
            if HomeLogConnection then
                HomeLogConnection:Disconnect()
            end
            HomeLogConnection = trackConnection(LogService.MessageOut:Connect(function(message, msgType)
                if msgType == Enum.MessageType.MessageError then
                    addHomeLogEntry(message)
                end
            end))
        else
            if HomeLogConnection then
                HomeLogConnection:Disconnect()
                HomeLogConnection = nil
            end
        end
    end
})

HomeTab:CreateButton({
    Name = "Clear All Logs",
    Callback = function()
        clearHomeLogs()
        ConsoleLogBuffer = {}
    end
})

-- =====================================================
-- PLAYER TAB
-- =====================================================
LoadingUI:Set(45, "Menambahkan modul player...")
local PlayerTab = createTab("Player")
PlayerTab:CreateSection("Movement")

local InfiniteJump = false

PlayerTab:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Flag = "InfiniteJump",
    Callback = function(Value)
        InfiniteJump = Value
    end
})

trackConnection(UIS.JumpRequest:Connect(function()
    if InfiniteJump and LP.Character then
        local hum = LP.Character:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end))

local WalkSpeedSlider
PlayerTab:CreateToggle({
    Name = "Enable WalkSpeed",
    CurrentValue = false,
    Flag = "WalkSpeedEnabled",
    Callback = function(Value)
        if WalkSpeedSlider and WalkSpeedSlider.SetEnabled then
            WalkSpeedSlider:SetEnabled(Value)
        end
        if Value and LP.Character then
            local hum = LP.Character:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.WalkSpeed = Config.WalkSpeed or 16
            end
        end
    end
})

WalkSpeedSlider = PlayerTab:CreateSlider({
    Name = "WalkSpeed",
    Range = {0, 300},
    Increment = 1,
    Suffix = "Speed",
    CurrentValue = 16,
    Flag = "WalkSpeed",
    Callback = function(Value)
        if not Config.WalkSpeedEnabled then
            return
        end
        if LP.Character then
            local hum = LP.Character:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.WalkSpeed = Value
            end
        end
    end
})

if WalkSpeedSlider and WalkSpeedSlider.SetEnabled then
    WalkSpeedSlider:SetEnabled(Config.WalkSpeedEnabled == true)
end

-- =====================================================
-- VISUAL TAB
-- =====================================================
LoadingUI:Set(55, "Menambahkan modul visual...")
local VisualTab = createTab("Visual")
VisualTab:CreateSection("Display Optimization")

local DefaultLighting = {
    FogStart = Lighting.FogStart,
    FogEnd = Lighting.FogEnd,
    Brightness = Lighting.Brightness,
    GlobalShadows = Lighting.GlobalShadows,
    ClockTime = Lighting.ClockTime
}

local function TogglePostFX(state)
    for _, v in ipairs(Lighting:GetChildren()) do
        if v:IsA("BloomEffect") or v:IsA("BlurEffect") or v:IsA("SunRaysEffect") or v:IsA("ColorCorrectionEffect") then
            v.Enabled = state
        end
    end
end

VisualTab:CreateToggle({
    Name = "No Fog",
    CurrentValue = false,
    Flag = "NoFog",
    Callback = function(Value)
        if Value then
            Lighting.FogStart = 1e5
            Lighting.FogEnd = 1e5
        else
            Lighting.FogStart = DefaultLighting.FogStart
            Lighting.FogEnd = DefaultLighting.FogEnd
        end
    end
})

VisualTab:CreateToggle({
    Name = "Disable Effects",
    CurrentValue = false,
    Flag = "NoFX",
    Callback = function(Value)
        TogglePostFX(not Value)
    end
})

VisualTab:CreateToggle({
    Name = "Low Graphics Mode",
    CurrentValue = false,
    Flag = "LowGraphics",
    Callback = function(Value)
        pcall(function()
            if Value then
                Lighting.GlobalShadows = false
                if settings and settings().Rendering then
                    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
                end
            else
                Lighting.GlobalShadows = DefaultLighting.GlobalShadows
                if settings and settings().Rendering then
                    settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
                end
            end
        end)
    end
})

VisualTab:CreateToggle({
    Name = "Full Bright",
    CurrentValue = false,
    Flag = "FullBright",
    Callback = function(Value)
        if Value then
            Lighting.Brightness = 2
            Lighting.ClockTime = 12
            Lighting.GlobalShadows = false
        else
            Lighting.Brightness = DefaultLighting.Brightness
            Lighting.ClockTime = DefaultLighting.ClockTime
            Lighting.GlobalShadows = DefaultLighting.GlobalShadows
        end
    end
})

-- =====================================================
-- [HEAD] TELEPORT HELPERS
-- =====================================================
-- [FUNC] Parse camera type from enum/string
local function parseCameraType(value)
    if typeof(value) == "EnumItem" then
        return value
    end
    if type(value) == "string" then
        local name = value:gsub("Enum%.CameraType%.", "")
        local ok, item = pcall(function()
            return Enum.CameraType[name]
        end)
        if ok and item then
            return item
        end
    end
    return Enum.CameraType.Custom
end

-- [FUNC] Teleport with camera snapshot (short lock, then restore zoom range)
teleportWithData = function(data)
    if not data or not data.position then return end
    if LP.Character then
        LP.Character:PivotTo(CFrame.new(data.position))
    end
    local cam = workspace.CurrentCamera
    if cam and data.camera then
        local targetType = parseCameraType(data.camera.type)
        local targetSubject = cam.CameraSubject
        local targetFOV = data.camera.fov or cam.FieldOfView
        local targetCFrame = data.camera.cframe or cam.CFrame
        local targetFocus = data.camera.focus or cam.Focus
        local targetZoom = data.camera.zoom or (targetCFrame.Position - targetFocus.Position).Magnitude
        local oldMinZoom = LP.CameraMinZoomDistance
        local oldMaxZoom = LP.CameraMaxZoomDistance
        local oldCamMode = LP.CameraMode

        cam.CameraType = Enum.CameraType.Scriptable
        cam.FieldOfView = targetFOV
        cam.CFrame = targetCFrame
        cam.Focus = targetFocus
        pcall(function()
            LP.CameraMinZoomDistance = targetZoom
            LP.CameraMaxZoomDistance = targetZoom
            LP.CameraMode = Enum.CameraMode.Classic
        end)

        local lockSeconds = 0.25
        local startTime = os.clock()
        local rsConn
        rsConn = RunService.RenderStepped:Connect(function()
            if not cam then
                if rsConn then
                    rsConn:Disconnect()
                end
                return
            end
            cam.FieldOfView = targetFOV
            cam.CFrame = targetCFrame
            cam.Focus = targetFocus
            pcall(function()
                LP.CameraMinZoomDistance = targetZoom
                LP.CameraMaxZoomDistance = targetZoom
            end)
            if (os.clock() - startTime) >= lockSeconds then
                if rsConn then
                    rsConn:Disconnect()
                end
                cam.CameraSubject = targetSubject
                cam.CameraType = targetType
                task.delay(0.05, function()
                    pcall(function()
                        LP.CameraMinZoomDistance = oldMinZoom
                        LP.CameraMaxZoomDistance = oldMaxZoom
                        LP.CameraMode = oldCamMode
                    end)
                end)
            end
        end)
        trackConnection(rsConn)
    end
end

-- =====================================================
-- [HEAD] DEV / SPY TAB
-- =====================================================
LoadingUI:Set(65, "Menambahkan modul dev...")
local DevTab = createTab("Spy / Dev")

DevTab:CreateSection("Teleport Tools")

-- [SECTION] Saved Position State
local SavedPosition = nil
local SavedCamera = nil

-- [FUNC] Save current player + camera snapshot
DevTab:CreateButton({
    Name = "Save Current Position",
    Callback = function()
        if LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") then
            SavedPosition = LP.Character.HumanoidRootPart.Position
            local cam = workspace.CurrentCamera
            if cam then
                local zoom = (cam.CFrame.Position - cam.Focus.Position).Magnitude
                SavedCamera = {
                    CFrame = cam.CFrame,
                    Focus = cam.Focus,
                    FOV = cam.FieldOfView,
                    Type = cam.CameraType,
                    Subject = cam.CameraSubject,
                    Zoom = zoom,
                    MinZoom = LP.CameraMinZoomDistance,
                    MaxZoom = LP.CameraMaxZoomDistance
                }
            end
            notify("Position Saved", tostring(SavedPosition), 3)
        end
    end
})

-- [FUNC] Teleport to saved snapshot (with short camera lock)
DevTab:CreateButton({
    Name = "Teleport to Saved Position",
    Callback = function()
        if SavedPosition and LP.Character then
            LP.Character:PivotTo(CFrame.new(SavedPosition))
            local cam = workspace.CurrentCamera
            if cam and SavedCamera then
                local targetType = SavedCamera.Type or cam.CameraType
                local targetSubject = SavedCamera.Subject or cam.CameraSubject
                local targetFOV = SavedCamera.FOV or cam.FieldOfView
                local targetCFrame = SavedCamera.CFrame or cam.CFrame
                local targetFocus = SavedCamera.Focus or cam.Focus
                local targetZoom = SavedCamera.Zoom
                local oldMinZoom = LP.CameraMinZoomDistance
                local oldMaxZoom = LP.CameraMaxZoomDistance

                cam.CameraType = Enum.CameraType.Scriptable
                cam.FieldOfView = targetFOV
                cam.CFrame = targetCFrame
                cam.Focus = targetFocus
                if targetZoom then
                    pcall(function()
                        LP.CameraMinZoomDistance = targetZoom
                        LP.CameraMaxZoomDistance = targetZoom
                    end)
                end

                local lockSeconds = 0.35
                local startTime = os.clock()
                local rsConn
                rsConn = RunService.RenderStepped:Connect(function()
                    if not cam then
                        if rsConn then
                            rsConn:Disconnect()
                        end
                        return
                    end
                    cam.FieldOfView = targetFOV
                    cam.CFrame = targetCFrame
                    cam.Focus = targetFocus
                    if targetZoom then
                        pcall(function()
                            LP.CameraMinZoomDistance = targetZoom
                            LP.CameraMaxZoomDistance = targetZoom
                        end)
                    end
                    if (os.clock() - startTime) >= lockSeconds then
                        if rsConn then
                            rsConn:Disconnect()
                        end
                        cam.CameraSubject = targetSubject
                        cam.CameraType = targetType
                        task.delay(0.1, function()
                            pcall(function()
                                LP.CameraMinZoomDistance = oldMinZoom
                                LP.CameraMaxZoomDistance = oldMaxZoom
                            end)
                        end)
                    end
                end)
                trackConnection(rsConn)
            end
        end
    end
})

-- [SECTION] Copy Data Logger (Editable Fields)
local CopyLogFields = {
    Position = "",
    CamCFrame = "",
    CamFocus = "",
    CamFOV = "",
    CamType = "",
    CamZoom = "",
    CamMinZoom = "",
    CamMaxZoom = "",
    CamMode = ""
}

local CopyLogInputs = {}

local function setCopyLogField(key, value)
    CopyLogFields[key] = value or ""
    if CopyLogInputs[key] then
        CopyLogInputs[key]:Set(CopyLogFields[key])
    end
end

local function getCopyLogField(key)
    return (CopyLogInputs[key] and CopyLogInputs[key]:Get()) or CopyLogFields[key] or ""
end

local function parseNumber(text)
    local normalized = tostring(text):gsub(",", ".")
    return tonumber(normalized)
end

local function parseVector3(text)
    local nums = {}
    for num in tostring(text):gmatch("[-%d%.]+") do
        nums[#nums + 1] = tonumber(num)
    end
    if #nums >= 3 then
        return Vector3.new(nums[1], nums[2], nums[3])
    end
    return nil
end

local function parseCFrame(text)
    local nums = {}
    for num in tostring(text):gmatch("[-%d%.]+") do
        nums[#nums + 1] = tonumber(num)
    end
    if #nums >= 12 then
        return CFrame.new(
            nums[1], nums[2], nums[3],
            nums[4], nums[5], nums[6],
            nums[7], nums[8], nums[9],
            nums[10], nums[11], nums[12]
        )
    elseif #nums >= 3 then
        return CFrame.new(nums[1], nums[2], nums[3])
    end
    return nil
end

local function buildDataFromCopyLog()
    local pos = parseVector3(getCopyLogField("Position"))
    local camCFrame = parseCFrame(getCopyLogField("CamCFrame"))
    local camFocus = parseCFrame(getCopyLogField("CamFocus"))
    local fov = parseNumber(getCopyLogField("CamFOV"))
    local camType = parseCameraType(getCopyLogField("CamType"))
    local zoom = parseNumber(getCopyLogField("CamZoom"))
    local minZoom = parseNumber(getCopyLogField("CamMinZoom"))
    local maxZoom = parseNumber(getCopyLogField("CamMaxZoom"))

    return {
        position = pos,
        camera = {
            cframe = camCFrame,
            focus = camFocus,
            fov = fov,
            type = camType,
            zoom = zoom,
            min_zoom = minZoom,
            max_zoom = maxZoom
        }
    }
end

-- [FUNC] Copy current position to clipboard + update editable log fields
DevTab:CreateButton({
    Name = "Copy Current Position",
    Callback = function()
        if LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") then
            local pos = LP.Character.HumanoidRootPart.Position
            local cam = workspace.CurrentCamera
            local camData = ""
            if cam then
                local cf = cam.CFrame
                local focus = cam.Focus
                local zoom = (cf.Position - focus.Position).Magnitude
                local cfx, cfy, cfz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
                local fx, fy, fz, fr00, fr01, fr02, fr10, fr11, fr12, fr20, fr21, fr22 = focus:GetComponents()
                camData = (
                    "    {Label = \"Default\", Data = makeData(\n" ..
                    "        Vector3.new(%.3f, %.3f, %.3f),\n" ..
                    "        CFrame.new(%.6f, %.6f, %.6f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f),\n" ..
                    "        CFrame.new(%.6f, %.6f, %.6f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f),\n" ..
                    "        %.3f,\n" ..
                    "        %s,\n" ..
                    "        %.6f,\n" ..
                    "        %.3f,\n" ..
                    "        %.3f\n" ..
                    "    )},"
                ):format(
                    pos.X, pos.Y, pos.Z,
                    cfx, cfy, cfz, r00, r01, r02, r10, r11, r12, r20, r21, r22,
                    fx, fy, fz, fr00, fr01, fr02, fr10, fr11, fr12, fr20, fr21, fr22,
                    cam.FieldOfView, tostring(cam.CameraType),
                    zoom,
                    LP.CameraMinZoomDistance,
                    LP.CameraMaxZoomDistance
                )
                setCopyLogField("CamCFrame", ("%.6f, %.6f, %.6f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f")
                    :format(cfx, cfy, cfz, r00, r01, r02, r10, r11, r12, r20, r21, r22))
                setCopyLogField("CamFocus", ("%.6f, %.6f, %.6f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f, %.9f")
                    :format(fx, fy, fz, fr00, fr01, fr02, fr10, fr11, fr12, fr20, fr21, fr22))
                setCopyLogField("CamFOV", string.format("%.3f", cam.FieldOfView))
                setCopyLogField("CamType", tostring(cam.CameraType))
                setCopyLogField("CamZoom", string.format("%.6f", zoom))
            end
            setCopyLogField("Position", string.format("%.3f, %.3f, %.3f", pos.X, pos.Y, pos.Z))
            local text = camData ~= "" and camData or ("{ position = Vector3.new(%.3f, %.3f, %.3f) }"):format(pos.X, pos.Y, pos.Z)
            if setclipboard then
                setclipboard(text)
                notify("Copied", text, 3)
            else
                notify("Copy Failed", "setclipboard tidak tersedia", 2)
            end
        end
    end
})

DevTab:CreateSection("Copy Data Logger")
CopyLogInputs.Position = DevTab:CreateInput({
    Name = "Position (x, y, z)",
    CurrentValue = CopyLogFields.Position,
    Callback = function(v)
        CopyLogFields.Position = v
    end
})
CopyLogInputs.CamCFrame = DevTab:CreateInput({
    Name = "Camera CFrame (12 nums)",
    CurrentValue = CopyLogFields.CamCFrame,
    Callback = function(v)
        CopyLogFields.CamCFrame = v
    end
})
CopyLogInputs.CamFocus = DevTab:CreateInput({
    Name = "Camera Focus (12 nums)",
    CurrentValue = CopyLogFields.CamFocus,
    Callback = function(v)
        CopyLogFields.CamFocus = v
    end
})
CopyLogInputs.CamFOV = DevTab:CreateInput({
    Name = "Camera FOV",
    CurrentValue = CopyLogFields.CamFOV,
    Callback = function(v)
        CopyLogFields.CamFOV = v
    end
})
CopyLogInputs.CamType = DevTab:CreateInput({
    Name = "Camera Type",
    CurrentValue = CopyLogFields.CamType,
    Callback = function(v)
        CopyLogFields.CamType = v
    end
})
CopyLogInputs.CamZoom = DevTab:CreateInput({
    Name = "Camera Zoom",
    CurrentValue = CopyLogFields.CamZoom,
    Callback = function(v)
        CopyLogFields.CamZoom = v
    end
})
CopyLogInputs.CamMinZoom = DevTab:CreateInput({
    Name = "Min Zoom",
    CurrentValue = CopyLogFields.CamMinZoom,
    Callback = function(v)
        CopyLogFields.CamMinZoom = v
    end
})
CopyLogInputs.CamMaxZoom = DevTab:CreateInput({
    Name = "Max Zoom",
    CurrentValue = CopyLogFields.CamMaxZoom,
    Callback = function(v)
        CopyLogFields.CamMaxZoom = v
    end
})
CopyLogInputs.CamMode = DevTab:CreateInput({
    Name = "Camera Mode",
    CurrentValue = CopyLogFields.CamMode,
    Callback = function(v)
        CopyLogFields.CamMode = v
    end
})

DevTab:CreateButton({
    Name = "Test Teleport From Fields",
    Callback = function()
        local data = buildDataFromCopyLog()
        if not data.position then
            notify("Test Teleport", "Position tidak valid. Format: x, y, z", 3)
            return
        end
        teleportWithData(data)
    end
})

DevTab:CreateSection("Action Logger")

local LogActions = false

DevTab:CreateToggle({
    Name = "Enable Action Logger",
    CurrentValue = false,
    Flag = "ActionLogger",
    Callback = function(Value)
        LogActions = Value
    end
})

trackConnection(Mouse.Button1Down:Connect(function()
    if LogActions then
        print("[ACTION] Mouse Click:", Mouse.Hit.Position)
    end
end))

trackConnection(UIS.InputBegan:Connect(function(input, gp)
    if LogActions and not gp then
        print("[ACTION] Input:", input.KeyCode.Name)
    end
end))

-- =====================================================
-- CURRENCY TRACKER (Billboard / HUD Scan)
-- =====================================================
DevTab:CreateSection("Currency Tracker")

local CurrencyNames = {
    "Sunite",
    "Plutite",
    "Neptunite",
    "Uranite",
    "Saturnite",
    "Jupiterite",
    "Mercuryte",
    "Venusite",
    "Marsite",
    "Moonlite",
    "Light Points",
    "Cosmic Points",
    "Cosmic Rank",
    "Planetify"
}

local CurrencyRows = {}
local CurrencyMap = {}
local CurrencyScanConn = nil
local CurrencyScanEnabled = false
local CurrencyScanInterval = 4
local CurrencyScanAccum = 0
local CurrencyUpdateInterval = 0.2
local CurrencyUpdateAccum = 0
local CurrencyAutoMode = false
local CurrencyAutoConns = {}

local CurrencyNamesLower = {}
for i, name in ipairs(CurrencyNames) do
    CurrencyNamesLower[i] = string.lower(name)
end

local CurrencyContainer = DevTab:CreateContainer(170)
local CurrencyTitle = Instance.new("TextLabel")
CurrencyTitle.Size = UDim2.new(1, 0, 0, 18)
CurrencyTitle.BackgroundTransparency = 1
CurrencyTitle.Font = Enum.Font.GothamSemibold
CurrencyTitle.TextSize = 12
CurrencyTitle.TextXAlignment = Enum.TextXAlignment.Left
CurrencyTitle.Text = "Live Currency Values"
CurrencyTitle.Parent = CurrencyContainer
registerTheme(CurrencyTitle, "TextColor3", "Text")

local CurrencyScroll = Instance.new("ScrollingFrame")
CurrencyScroll.Size = UDim2.new(1, 0, 1, -22)
CurrencyScroll.Position = UDim2.new(0, 0, 0, 20)
CurrencyScroll.BorderSizePixel = 0
CurrencyScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
CurrencyScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
CurrencyScroll.ScrollBarThickness = 6
CurrencyScroll.ScrollingDirection = Enum.ScrollingDirection.Y
CurrencyScroll.ClipsDescendants = true
CurrencyScroll.Parent = CurrencyContainer
registerTheme(CurrencyScroll, "BackgroundColor3", "Panel")

local CurrencyList = Instance.new("UIListLayout")
CurrencyList.Padding = UDim.new(0, 6)
CurrencyList.SortOrder = Enum.SortOrder.LayoutOrder
CurrencyList.Parent = CurrencyScroll

CurrencyList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    CurrencyScroll.CanvasSize = UDim2.new(0, 0, 0, CurrencyList.AbsoluteContentSize.Y + 12)
end)

local CurrencyPad = Instance.new("UIPadding")
CurrencyPad.PaddingTop = UDim.new(0, 6)
CurrencyPad.PaddingBottom = UDim.new(0, 6)
CurrencyPad.PaddingLeft = UDim.new(0, 6)
CurrencyPad.PaddingRight = UDim.new(0, 6)
CurrencyPad.Parent = CurrencyScroll

local function createCurrencyRow(name)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 26)
    frame.BorderSizePixel = 0
    frame.Parent = CurrencyScroll
    registerTheme(frame, "BackgroundColor3", "Main")

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = frame

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = name .. ": (not found)"
    label.Parent = frame
    registerTheme(label, "TextColor3", "Text")

    CurrencyRows[name] = label
end

for _, name in ipairs(CurrencyNames) do
    createCurrencyRow(name)
end

local function scoreLabel(label)
    if not label or not label.Parent then return 0 end
    if LP.Character and label:IsDescendantOf(LP.Character) then
        return 3
    end
    if LP.PlayerGui and label:IsDescendantOf(LP.PlayerGui) then
        return 2
    end
    return 1
end

local function scanForCurrencies(root)
    if not root then return end
    for _, inst in ipairs(root:GetDescendants()) do
        if inst:IsA("TextLabel") then
            local text = inst.Text or ""
            if text ~= "" then
                local lowerText = string.lower(text)
                for i, name in ipairs(CurrencyNames) do
                    if string.find(lowerText, CurrencyNamesLower[i], 1, true) then
                        local best = CurrencyMap[name]
                        if not best or scoreLabel(inst) > scoreLabel(best) then
                            CurrencyMap[name] = inst
                        end
                    end
                end
            end
        end
    end
end

local function scanBillboards(root)
    if not root then return end
    for _, inst in ipairs(root:GetDescendants()) do
        if inst:IsA("BillboardGui") then
            scanForCurrencies(inst)
        end
    end
end

local function updateCurrencyRows()
    for _, name in ipairs(CurrencyNames) do
        local lbl = CurrencyRows[name]
        local src = CurrencyMap[name]
        if src and src.Parent and src:IsA("TextLabel") then
            lbl.Text = name .. ": " .. tostring(src.Text)
        else
            lbl.Text = name .. ": (not found)"
        end
    end
end

local function isCurrencyMapEmpty()
    for _, name in ipairs(CurrencyNames) do
        if CurrencyMap[name] ~= nil then
            return false
        end
    end
    return true
end

local function hasInvalidCurrencyMap()
    for _, name in ipairs(CurrencyNames) do
        local src = CurrencyMap[name]
        if src and (not src.Parent or not src:IsA("TextLabel")) then
            return true
        end
    end
    return false
end

local function scanOnce()
    CurrencyMap = {}
    if LP.Character then
        scanBillboards(LP.Character)
        scanForCurrencies(LP.Character)
    end
    if LP.PlayerGui then
        scanBillboards(LP.PlayerGui)
        scanForCurrencies(LP.PlayerGui)
    end
    scanBillboards(workspace)
end

local function clearCurrencyAutoConns()
    for _, conn in ipairs(CurrencyAutoConns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    CurrencyAutoConns = {}
end

local function attachCurrencyAutoMode()
    clearCurrencyAutoConns()
    local function onDescendantAdded(inst)
        if not inst then return end
        if inst:IsA("TextLabel") then
            local text = inst.Text or ""
            if text ~= "" then
                local lowerText = string.lower(text)
                for i, name in ipairs(CurrencyNames) do
                    if string.find(lowerText, CurrencyNamesLower[i], 1, true) then
                        local best = CurrencyMap[name]
                        if not best or scoreLabel(inst) > scoreLabel(best) then
                            CurrencyMap[name] = inst
                        end
                    end
                end
            end
        elseif inst:IsA("BillboardGui") then
            scanForCurrencies(inst)
        end
    end

    if LP.Character then
        CurrencyAutoConns[#CurrencyAutoConns + 1] = LP.Character.DescendantAdded:Connect(onDescendantAdded)
    end
    if LP.PlayerGui then
        CurrencyAutoConns[#CurrencyAutoConns + 1] = LP.PlayerGui.DescendantAdded:Connect(onDescendantAdded)
    end
    CurrencyAutoConns[#CurrencyAutoConns + 1] = workspace.DescendantAdded:Connect(onDescendantAdded)
    CurrencyAutoConns[#CurrencyAutoConns + 1] = LP.CharacterAdded:Connect(function()
        if CurrencyAutoMode then
            attachCurrencyAutoMode()
        end
    end)
end

DevTab:CreateToggle({
    Name = "Auto Scan (Live)",
    CurrentValue = false,
    Callback = function(v)
        CurrencyScanEnabled = v
        if CurrencyScanEnabled then
            if CurrencyScanConn then
                CurrencyScanConn:Disconnect()
            end
            CurrencyScanAccum = 0
            CurrencyUpdateAccum = 0
            scanOnce()
            updateCurrencyRows()
            CurrencyScanConn = RunService.Heartbeat:Connect(function(dt)
                CurrencyScanAccum += dt
                CurrencyUpdateAccum += dt
                if CurrencyUpdateAccum >= CurrencyUpdateInterval then
                    CurrencyUpdateAccum = 0
                    updateCurrencyRows()
                end
                if CurrencyAutoMode and (isCurrencyMapEmpty() or hasInvalidCurrencyMap()) then
                    CurrencyScanAccum = 0
                    scanOnce()
                elseif CurrencyScanAccum >= CurrencyScanInterval then
                    CurrencyScanAccum = 0
                    scanOnce()
                end
            end)
            trackConnection(CurrencyScanConn)
        else
            if CurrencyScanConn then
                CurrencyScanConn:Disconnect()
                CurrencyScanConn = nil
            end
        end
    end
})

DevTab:CreateButton({
    Name = "Re Full Scan",
    Callback = function()
        scanOnce()
        updateCurrencyRows()
    end
})

DevTab:CreateToggle({
    Name = "Auto Mode (Event Driven)",
    CurrentValue = false,
    Callback = function(v)
        CurrencyAutoMode = v
        if CurrencyAutoMode then
            attachCurrencyAutoMode()
        else
            clearCurrencyAutoConns()
        end
    end
})

do
    local RemoteToolsSection = createSectionBox(DevTab:GetPage(), "Remote Tools")
    local RemoteToolsControls = {}

    local function addControl(ctrl)
        RemoteToolsControls[#RemoteToolsControls + 1] = ctrl
        return ctrl
    end

    local RemoteToolsEnabled = false
    local RemoteSpy = false
    local RemoteLoggerEnabled = false

    local function setRemoteToolsEnabled(enabled)
        RemoteToolsEnabled = enabled
        if not enabled then
            RemoteSpy = false
            RemoteLoggerEnabled = false
            State.C2SCaptureArmed = false
        end
        if setRemoteHooking then
            setRemoteHooking(enabled)
        end
        for _, ctrl in ipairs(RemoteToolsControls) do
            if ctrl and ctrl.SetEnabled then
                ctrl:SetEnabled(enabled)
            end
        end
    end

    createToggle(RemoteToolsSection, "Enable Remote Tools (Hook Remotes)", nil, false, function(v)
        setRemoteToolsEnabled(v)
    end)

    createSubSection(RemoteToolsSection, "Remote Spy (Client-Side)")

    local function simpleSerialize(v)
        local t = typeof(v)
        if t == "Instance" then
            return "<Instance " .. v.ClassName .. "> " .. v:GetFullName()
        elseif t == "Vector3" then
            return ("<Vector3 %.3f, %.3f, %.3f>"):format(v.X, v.Y, v.Z)
        elseif t == "CFrame" then
            local x, y, z = v.Position.X, v.Position.Y, v.Position.Z
            return ("<CFrame %.3f, %.3f, %.3f>"):format(x, y, z)
        elseif t == "Color3" then
            return ("<Color3 %.3f, %.3f, %.3f>"):format(v.R, v.G, v.B)
        elseif t == "EnumItem" then
            return tostring(v)
        elseif t == "table" then
            local parts = {}
            local count = 0
            for k, val in pairs(v) do
                count = count + 1
                if count > 8 then
                    parts[#parts + 1] = "..."
                    break
                end
                parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. simpleSerialize(val)
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
        return tostring(v)
    end

    addControl(createToggle(RemoteToolsSection, "Enable Remote Spy", nil, false, function(Value)
        if not RemoteToolsEnabled then
            return
        end
        RemoteSpy = Value
    end))

    if hookfunction and getrawmetatable and setreadonly and newcclosure then
        local mt = getrawmetatable(game)
        setreadonly(mt, false)

        local old = mt.__namecall
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            local args = {...}

            if RemoteToolsEnabled and RemoteSpy and (method == "FireServer" or method == "InvokeServer") then
                print("========== REMOTE SPY ==========")
                print("Remote:", self:GetFullName())
                print("Method:", method)
                for i, v in ipairs(args) do
                    print("Arg[" .. i .. "]:", v)
                end
            end

            if NamecallLogHandler then
                pcall(NamecallLogHandler, self, method, args)
            end

            return old(self, ...)
        end)
        State.Mt = mt
        State.OldNamecall = old
        State.Hooked = true
        setreadonly(mt, true)
    end

    createSubSection(RemoteToolsSection, "Remote Logger")

    RemoteLoggerEnabled = false
    local RemoteLoggerIncludeC2S = true
    local RemoteLoggerIncludeS2C = true
    local MaxLogs = 40
    local Logs = {}
    local LogFilterText = Config.LogFilter or ""

    local function parseFilters(text)
        local out = {}
        for token in string.gmatch(text or "", "([^,]+)") do
            local t = string.lower(string.gsub(token, "^%s*(.-)%s*$", "%1"))
            if t ~= "" then
                out[#out + 1] = t
            end
        end
        return out
    end

    local function isFiltered(fullText)
        local filters = parseFilters(LogFilterText)
        if #filters == 0 then
            return false
        end
        local lowerText = string.lower(fullText)
        for _, f in ipairs(filters) do
            if string.find(lowerText, f, 1, true) then
                return true
            end
        end
        return false
    end

    local function refreshFilters()
        for _, item in ipairs(Logs) do
            if item and item.Frame then
                item.Frame.Visible = not isFiltered(item.Text or "")
            end
        end
    end

    local function serializeValue(v, depth, seen)
        depth = depth or 0
        seen = seen or {}
        if depth > 3 then
            return "<depth>"
        end
        local t = typeof(v)
        if t == "Instance" then
            return "<Instance " .. v.ClassName .. "> " .. v:GetFullName()
        elseif t == "Vector3" then
            return ("<Vector3 %.3f, %.3f, %.3f>"):format(v.X, v.Y, v.Z)
        elseif t == "CFrame" then
            local x, y, z = v.Position.X, v.Position.Y, v.Position.Z
            return ("<CFrame %.3f, %.3f, %.3f>"):format(x, y, z)
        elseif t == "Color3" then
            return ("<Color3 %.3f, %.3f, %.3f>"):format(v.R, v.G, v.B)
        elseif t == "EnumItem" then
            return tostring(v)
        elseif t == "table" then
            if seen[v] then
                return "<table:ref>"
            end
            seen[v] = true
            local parts = {}
            local count = 0
            for k, val in pairs(v) do
                count = count + 1
                if count > 20 then
                    parts[#parts + 1] = "..."
                    break
                end
                local key = "[" .. serializeValue(k, depth + 1, seen) .. "]"
                local value = serializeValue(val, depth + 1, seen)
                parts[#parts + 1] = key .. " = " .. value
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
        return tostring(v)
    end

    addControl(createToggle(RemoteToolsSection, "Enable Remote Logger", nil, false, function(v)
        if not RemoteToolsEnabled then
            return
        end
        RemoteLoggerEnabled = v
    end))

    addControl(createToggle(RemoteToolsSection, "Log Client->Server (Fire/Invoke)", nil, true, function(v)
        if not RemoteToolsEnabled then
            return
        end
        RemoteLoggerIncludeC2S = v
    end))

    addControl(createToggle(RemoteToolsSection, "Log Server->Client (OnClient)", nil, true, function(v)
        if not RemoteToolsEnabled then
            return
        end
        RemoteLoggerIncludeS2C = v
    end))

    addControl(createInput(RemoteToolsSection, "Filter (comma)", "LogFilter", LogFilterText, function(v)
        if not RemoteToolsEnabled then
            return
        end
        LogFilterText = v or ""
        refreshFilters()
    end))

    addControl(createButton(RemoteToolsSection, "Clear All Logs", function()
        if not RemoteToolsEnabled then
            return
        end
        for i = #Logs, 1, -1 do
            if Logs[i].Frame then
                Logs[i].Frame:Destroy()
            end
            table.remove(Logs, i)
        end
    end))

    addControl(createButton(RemoteToolsSection, "Copy Last C2S", function()
        if not RemoteToolsEnabled then
            return
        end
        if State.C2SLastCapture == "" then
            notify("C2S", "Belum ada capture", 2)
            return
        end
        if setclipboard then
            pcall(setclipboard, State.C2SLastCapture)
            notify("C2S", "Copied last C2S", 2)
        else
            notify("Copy Failed", "setclipboard tidak tersedia", 2)
        end
    end))

    addControl(createButton(RemoteToolsSection, "Arm C2S Capture (8s)", function()
        if not RemoteToolsEnabled then
            return
        end
        State.C2SLastCapture = ""
        State.C2SCaptureArmed = true
        State.C2SCaptureExpires = os.clock() + 8
        notify("C2S Capture", "Klik Buy/Buy All dalam 8 detik", 3)
    end))

    addControl(createButton(RemoteToolsSection, "C2S Hook Status", function()
        if not RemoteToolsEnabled then
            return
        end
        local okHook = (hookfunction and getrawmetatable and setreadonly and newcclosure) and true or false
        local active = State.Hooked and State.Mt and State.OldNamecall and true or false
        notify("C2S Status", "hookfn=" .. tostring(okHook) .. " | active=" .. tostring(active), 3)
    end))

    local LogContainer = createContainer(RemoteToolsSection, 200)
    local LogTitle = Instance.new("TextLabel")
    LogTitle.Size = UDim2.new(1, 0, 0, 18)
    LogTitle.BackgroundTransparency = 1
    LogTitle.Font = Enum.Font.GothamSemibold
    LogTitle.TextSize = 12
    LogTitle.TextXAlignment = Enum.TextXAlignment.Left
    LogTitle.Text = "Logs (Client<->Server Remotes)"
    LogTitle.Parent = LogContainer
    registerTheme(LogTitle, "TextColor3", "Text")

    local LogScroll = Instance.new("ScrollingFrame")
    LogScroll.Size = UDim2.new(1, 0, 1, -22)
    LogScroll.Position = UDim2.new(0, 0, 0, 20)
    LogScroll.BorderSizePixel = 0
    LogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    LogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    LogScroll.ScrollBarThickness = 6
    LogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    LogScroll.ClipsDescendants = true
    LogScroll.Parent = LogContainer
    registerTheme(LogScroll, "BackgroundColor3", "Panel")

    local LogList = Instance.new("UIListLayout")
    LogList.Padding = UDim.new(0, 6)
    LogList.SortOrder = Enum.SortOrder.LayoutOrder
    LogList.Parent = LogScroll

    trackConnection(LogList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        LogScroll.CanvasSize = UDim2.new(0, 0, 0, LogList.AbsoluteContentSize.Y + 12)
    end))

    local LogPad = Instance.new("UIPadding")
    LogPad.PaddingTop = UDim.new(0, 6)
    LogPad.PaddingBottom = UDim.new(0, 6)
    LogPad.PaddingLeft = UDim.new(0, 6)
    LogPad.PaddingRight = UDim.new(0, 6)
    LogPad.Parent = LogScroll

    LogFilterText = LogFilterText or ""
    refreshFilters()

    addLogEntry = function(label, remoteName, args)
        if not RemoteToolsEnabled or not RemoteLoggerEnabled then return end
        if label == ".OnClientEvent" and not RemoteLoggerIncludeS2C then return end
        if (label == ":FireServer" or label == ":InvokeServer" or label == ":FireServer (Unreliable)") and not RemoteLoggerIncludeC2S then
            return
        end

        if #Logs >= MaxLogs then
            if Logs[1] and Logs[1].Frame then
                Logs[1].Frame:Destroy()
            end
            table.remove(Logs, 1)
        end

        local argText = {}
        for i, v in ipairs(args) do
            argText[#argText + 1] = "[" .. i .. "] " .. serializeValue(v)
        end

        local fullName = remoteName .. " " .. label
        local content = table.concat(argText, "\n")
        local fullText = fullName .. "\n" .. content

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 0, 0)
        frame.AutomaticSize = Enum.AutomaticSize.Y
        frame.BorderSizePixel = 0
        frame.Parent = LogScroll
        registerTheme(frame, "BackgroundColor3", "Main")

        local pad = Instance.new("UIPadding")
        pad.PaddingTop = UDim.new(0, 6)
        pad.PaddingBottom = UDim.new(0, 6)
        pad.PaddingLeft = UDim.new(0, 8)
        pad.PaddingRight = UDim.new(0, 8)
        pad.Parent = frame

        local header = Instance.new("Frame")
        header.Size = UDim2.new(1, 0, 0, 18)
        header.BackgroundTransparency = 1
        header.Parent = frame

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -120, 1, 0)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamSemibold
        title.TextSize = 12
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = fullName
        title.Parent = header
        registerTheme(title, "TextColor3", "Text")

        local copyBtn = Instance.new("TextButton")
        copyBtn.Size = UDim2.new(0, 50, 1, 0)
        copyBtn.Position = UDim2.new(1, -110, 0, 0)
        copyBtn.BorderSizePixel = 0
        copyBtn.Font = Enum.Font.Gotham
        copyBtn.TextSize = 11
        copyBtn.Text = "Copy"
        copyBtn.AutoButtonColor = false
        copyBtn.Parent = header
        registerTheme(copyBtn, "BackgroundColor3", "Panel")
        registerTheme(copyBtn, "TextColor3", "Text")

        local delBtn = Instance.new("TextButton")
        delBtn.Size = UDim2.new(0, 50, 1, 0)
        delBtn.Position = UDim2.new(1, -55, 0, 0)
        delBtn.BorderSizePixel = 0
        delBtn.Font = Enum.Font.Gotham
        delBtn.TextSize = 11
        delBtn.Text = "Del"
        delBtn.AutoButtonColor = false
        delBtn.Parent = header
        registerTheme(delBtn, "BackgroundColor3", "Panel")
        registerTheme(delBtn, "TextColor3", "Text")

        local body = Instance.new("TextLabel")
        body.Size = UDim2.new(1, 0, 0, 0)
        body.AutomaticSize = Enum.AutomaticSize.Y
        body.BackgroundTransparency = 1
        body.Font = Enum.Font.Gotham
        body.TextSize = 12
        body.TextWrapped = true
        body.TextXAlignment = Enum.TextXAlignment.Left
        body.TextYAlignment = Enum.TextYAlignment.Top
        body.Text = content
        body.Parent = frame
        registerTheme(body, "TextColor3", "Muted")

        local list = Instance.new("UIListLayout")
        list.Padding = UDim.new(0, 4)
        list.Parent = frame

        copyBtn.MouseButton1Click:Connect(function()
            if setclipboard then
                setclipboard(fullText)
                notify("Copied", "Log disalin ke clipboard", 2)
            else
                notify("Copy Failed", "setclipboard tidak tersedia", 2)
            end
        end)

        delBtn.MouseButton1Click:Connect(function()
            for i = #Logs, 1, -1 do
                if Logs[i] and Logs[i].Frame == frame then
                    table.remove(Logs, i)
                    break
                end
            end
            frame:Destroy()
        end)

        frame.Visible = not isFiltered(fullText)
        table.insert(Logs, {Frame = frame, Text = fullText})
    end

    addLog = function(remote, args)
        addLogEntry(".OnClientEvent", remote:GetFullName(), args)
    end

    NamecallLogHandler = function(self, method, args)
        if not RemoteToolsEnabled or not RemoteLoggerEnabled then return end
        if typeof(self) ~= "Instance" then return end

        local class = self.ClassName
        if not (class == "RemoteEvent" or class == "RemoteFunction" or class == "BindableEvent" or class == "BindableFunction" or class == "UnreliableRemoteEvent") then
            return
        end
        if method == "FireServer" then
            local label = ":FireServer"
            if class == "UnreliableRemoteEvent" then
                label = ":FireServer (Unreliable)"
            end
            State.C2SLastCapture = self:GetFullName() .. " " .. label .. "\n" .. table.concat((function()
                local out = {}
                for i, v in ipairs(args) do
                    out[#out + 1] = "[" .. i .. "] " .. serializeValue(v)
                end
                return out
            end)(), "\n")
            if State.C2SCaptureArmed then
                if os.clock() > State.C2SCaptureExpires then
                    State.C2SCaptureArmed = false
                else
                    State.C2SCaptureArmed = false
                    if setclipboard then
                        pcall(setclipboard, State.C2SLastCapture)
                    end
                    notify("C2S Captured", "Captured & copied", 3)
                end
            end
            addLogEntry(label, self:GetFullName(), args)
            return
        end
        if method == "InvokeServer" then
            State.C2SLastCapture = self:GetFullName() .. " :InvokeServer\n" .. table.concat((function()
                local out = {}
                for i, v in ipairs(args) do
                    out[#out + 1] = "[" .. i .. "] " .. serializeValue(v)
                end
                return out
            end)(), "\n")
            if State.C2SCaptureArmed then
                if os.clock() > State.C2SCaptureExpires then
                    State.C2SCaptureArmed = false
                else
                    State.C2SCaptureArmed = false
                    if setclipboard then
                        pcall(setclipboard, State.C2SLastCapture)
                    end
                    notify("C2S Captured", "Captured & copied", 3)
                end
            end
            addLogEntry(":InvokeServer", self:GetFullName(), args)
            return
        end
        if method == "Fire" then
            addLogEntry(":Fire", self:GetFullName(), args)
            return
        end
    end

    setRemoteToolsEnabled(false)
end
local function hookRemote(obj)
    if not addLogEntry then
        return
    end
    if obj:IsA("RemoteEvent") or obj.ClassName == "UnreliableRemoteEvent" then
        local conn = obj.OnClientEvent:Connect(function(...)
            addLog(obj, {...})
        end)
        State.RemoteConnections[#State.RemoteConnections + 1] = conn
    end
    if obj:IsA("RemoteFunction") then
        if State.RemoteInvokeOld[obj] == nil then
            State.RemoteInvokeOld[obj] = true
        end
        pcall(function()
            obj.OnClientInvoke = function(...)
                addLogEntry(".OnClientInvoke", obj:GetFullName(), {...})
            end
        end)
    end
end

setRemoteHooking = function(enabled)
    if enabled then
        if State.RemoteHookEnabled then
            return
        end
        State.RemoteHookEnabled = true
        local descendants = game:GetDescendants()
        local total = #descendants
        for i = 1, total do
            pcall(hookRemote, descendants[i])
        end
        if State.RemoteHookConn then
            State.RemoteHookConn:Disconnect()
        end
        State.RemoteHookConn = game.DescendantAdded:Connect(function(inst)
            pcall(hookRemote, inst)
        end)
        trackConnection(State.RemoteHookConn)
    else
        if not State.RemoteHookEnabled then
            return
        end
        State.RemoteHookEnabled = false
        if State.RemoteHookConn then
            State.RemoteHookConn:Disconnect()
            State.RemoteHookConn = nil
        end
        for _, conn in ipairs(State.RemoteConnections) do
            pcall(function()
                conn:Disconnect()
            end)
        end
        State.RemoteConnections = {}
        for obj, oldFn in pairs(State.RemoteInvokeOld) do
            pcall(function()
                if oldFn == true then
                    obj.OnClientInvoke = nil
                else
                    obj.OnClientInvoke = oldFn
                end
            end)
        end
        State.RemoteInvokeOld = {}
    end
end

-- =====================================================
-- =====================================================
-- [HEAD] SETTINGS TAB
-- =====================================================
LoadingUI:Set(75, "Menambahkan pengaturan UI...")
local SettingsTab = createTab("Settings")
SettingsTab:CreateSection("UI Settings")

SettingsTab:CreateDropdown({
    Name = "Theme",
    Options = {"Default", "Dark", "Light", "Ocean"},
    CurrentOption = "Default",
    Flag = "Theme",
    Callback = function(Theme)
        Config.Theme = Theme
        applyTheme(Theme)
        saveConfig()
    end
})

SettingsTab:CreateSection("Auto Reload")
SettingsTab:CreateParagraph({
    Title = "Info",
    Content = "Gunakan salah satu sumber. Prioritas: Source > URL > File. Fitur ini membutuhkan queue_on_teleport dari executor."
})

local AutoReloadUIReady = false
local function notifyAutoReloadResult(ok, reason)
    if ok then
        notify("Auto Reload", "Queued untuk teleport berikutnya", 3)
        return
    end
    if reason == "missing" then
        notify("Auto Reload", "Sumber script belum diisi", 3)
    elseif reason == "noqueue" then
        notify("Auto Reload", "queue_on_teleport tidak tersedia", 3)
    elseif reason == "disabled" then
        notify("Auto Reload", "Auto Reload masih OFF", 3)
    elseif reason == "file_missing" then
        notify("Auto Reload", "File path tidak ditemukan", 3)
    elseif reason == "file_no_read" then
        notify("Auto Reload", "readfile tidak tersedia", 3)
    elseif reason == "file_read_fail" then
        notify("Auto Reload", "Gagal membaca file", 3)
    end
end

SettingsTab:CreateToggle({
    Name = "Auto Reload on Reconnect",
    Flag = "AutoReloadEnabled",
    CurrentValue = Config.AutoReloadEnabled,
    Callback = function(v)
        if not AutoReloadUIReady then
            return
        end
        if v then
            local ok, reason = applyAutoReloadQueue()
            notifyAutoReloadResult(ok, reason)
        end
    end
})

SettingsTab:CreateInput({
    Name = "Source (raw)",
    Flag = "AutoReloadSource",
    CurrentValue = Config.AutoReloadSource,
    Callback = function()
        if not AutoReloadUIReady then
            return
        end
        if Config.AutoReloadEnabled then
            applyAutoReloadQueue()
        end
    end
})

SettingsTab:CreateInput({
    Name = "URL",
    Flag = "AutoReloadUrl",
    CurrentValue = Config.AutoReloadUrl,
    Callback = function()
        if not AutoReloadUIReady then
            return
        end
        if Config.AutoReloadEnabled then
            applyAutoReloadQueue()
        end
    end
})

SettingsTab:CreateInput({
    Name = "File Path",
    Flag = "AutoReloadFile",
    CurrentValue = Config.AutoReloadFile,
    Callback = function()
        if not AutoReloadUIReady then
            return
        end
        if Config.AutoReloadEnabled then
            applyAutoReloadQueue()
        end
    end
})

SettingsTab:CreateButton({
    Name = "Queue Now (Test)",
    Callback = function()
        local ok, reason = applyAutoReloadQueue()
        notifyAutoReloadResult(ok, reason)
    end
})

AutoReloadUIReady = true

createTabDivider()
State.Tabs = State.Tabs or {}
State.Tabs.RuneLocation = createTab("Rune Location")

local function createVirtualButtonRow(parent, items)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BorderSizePixel = 0
    row.Parent = parent
    row.BackgroundTransparency = 1

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = row

    for _, item in ipairs(items) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / 3, -4, 1, 0)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 11
        btn.Text = tostring(item.Label)
        btn.AutoButtonColor = false
        btn.Parent = row
        registerTheme(btn, "BackgroundColor3", "Main")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)

        btn.MouseButton1Click:Connect(function()
            teleportWithData(item.Data)
        end)
    end
end

local function createVirtualGrid(parent, list)
    local items = {}
    for i = 1, #list do
        items[#items + 1] = list[i]
        if #items == 3 or i == #list then
            createVirtualButtonRow(parent, items)
            items = {}
        end
    end
end

local function initRuneLocationTab()
    if not State.Tabs or not State.Tabs.RuneLocation then
        return
    end
    if State.RuneLocationInitialized then
        return
    end
    State.RuneLocationInitialized = true

    local tab = State.Tabs.RuneLocation
    local page = tab:GetPage()

    local worldOrder = {
        "Forest",
        "Winter",
        "Desert",
        "Mines",
        "Cyber",
        "Ocean",
        "Mushroom World",
        "Space World",
        "Heaven World",
        "Hell World",
        "500K Event",
        "Halloween",
        "Thanksgiving",
        "3M Event",
        "Christmas Event",
        "5M Event",
        "Valentine Event"
    }

    for _, worldName in ipairs(worldOrder) do
        local section = createSectionBox(page, worldName)
        local runeList = State.RuneTeleportData[worldName] or {}
        if #runeList == 0 then
            createParagraph(section, "Rune", "Tidak ada data rune untuk world ini.")
        else
            createVirtualGrid(section, runeList)
        end
    end
end

local function initWorldTabs()
createTabDivider()
State.Tabs = State.Tabs or {}
State.Tabs.Forest = createTab("Forest")
State.Tabs.Winter = createTab("Winter")
State.Tabs.Desert = createTab("Desert")
State.Tabs.Mines = createTab("Mines")
State.Tabs.Cyber = createTab("Cyber")
State.Tabs.Ocean = createTab("Ocean")
State.MushroomTab = createTab("Mushroom World")
State.Tabs.Space = createTab("Space World")
local TeleportSection = createSectionBox(State.Tabs.Space:GetPage(), "Teleport")

-- =====================================================
-- [SUBHEAD] Space World Teleport Helpers
-- =====================================================
local function createButtonRow(parent, items, onClick)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BorderSizePixel = 0
    row.Parent = parent
    row.BackgroundTransparency = 1

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = row

    for _, item in ipairs(items) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / 3, -4, 1, 0)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 11
        btn.Text = item.Label
        btn.AutoButtonColor = false
        btn.Parent = row
        registerTheme(btn, "BackgroundColor3", "Main")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)
        TeleportButtons[#TeleportButtons + 1] = btn

        btn.MouseButton1Click:Connect(function()
            ActiveTeleportButton = btn
            applyTheme(Config.Theme or "Default")
            if onClick then
                onClick(item)
            end
        end)
    end
end

local function createGrid(parent, list, onClick)
    local items = {}
    for i = 1, #list do
        items[#items + 1] = list[i]
        if #items == 3 or i == #list then
            createButtonRow(parent, items, onClick)
            items = {}
        end
    end
end

local function fireWorldTeleport(worldName)
    if not worldName or worldName == "" then
        return
    end
    local remote = nil
    if getMainRemote then
        remote = getMainRemote()
    end
    if not remote then
        local ok, r = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.MainRemote
        end)
        if ok and r then
            remote = r
        end
    end
    if not remote then
        return
    end
    pcall(function()
        remote:FireServer("TeleportTo", worldName)
    end)
end

local function fireBuyArea(areaName)
    if not areaName or areaName == "" then
        return
    end
    local remote = nil
    if getMainRemote then
        remote = getMainRemote()
    end
    if not remote then
        local ok, r = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.MainRemote
        end)
        if ok and r then
            remote = r
        end
    end
    if not remote then
        return
    end
    pcall(function()
        remote:FireServer("BuyArea", areaName)
    end)
end

local function getPromptNotificationRemote()
    local ok, remote = pcall(function()
        return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
    end)
    if ok and remote and remote:IsA("RemoteEvent") then
        return remote
    end
    return nil
end

local function classifyPromptMessage(msg)
    if type(msg) ~= "string" then
        return nil
    end
    local lower = string.lower(msg)
    if string.find(lower, "you need to buy this area first", 1, true) then
        return "need_buy"
    end
    if (string.find(lower, "don't have enough", 1, true) or string.find(lower, "dont have enough", 1, true)) and
        string.find(lower, "to buy this area", 1, true) then
        return "not_enough"
    end
    return nil
end

local function waitPromptMessageMatch(timeoutSeconds)
    local remote = getPromptNotificationRemote()
    if not remote then
        return nil
    end
    local captured = nil
    local conn
    conn = remote.OnClientEvent:Connect(function(...)
        local args = {...}
        for _, v in ipairs(args) do
            if type(v) == "string" then
                local kind = classifyPromptMessage(v)
                if kind then
                    captured = {Kind = kind, Text = v}
                    break
                end
            end
        end
    end)
    local start = os.clock()
    local timeout = timeoutSeconds or 2.5
    while not captured and (os.clock() - start) < timeout do
        task.wait(0.05)
    end
    if conn then
        conn:Disconnect()
    end
    return captured
end

local function fireWithPromptWait(actionFn, timeoutSeconds)
    local remote = getPromptNotificationRemote()
    if not remote then
        actionFn()
        return nil
    end
    local captured = nil
    local conn
    conn = remote.OnClientEvent:Connect(function(...)
        local args = {...}
        for _, v in ipairs(args) do
            if type(v) == "string" then
                local kind = classifyPromptMessage(v)
                if kind then
                    captured = {Kind = kind, Text = v}
                    break
                end
            end
        end
    end)
    actionFn()
    local start = os.clock()
    local timeout = timeoutSeconds or 2.5
    while not captured and (os.clock() - start) < timeout do
        task.wait(0.05)
    end
    if conn then
        conn:Disconnect()
    end
    return captured
end

local function teleportHomeWithBuy(areaName)
    if not areaName or areaName == "" then
        return
    end
    task.spawn(function()
        local msg = fireWithPromptWait(function()
            fireWorldTeleport(areaName)
        end, 2.5)
        if not msg then
            return
        end
        if msg.Kind == "need_buy" then
            local buyMsg = fireWithPromptWait(function()
                fireBuyArea(areaName)
            end, 2.5)
            if buyMsg and buyMsg.Kind == "not_enough" then
                notify("Teleport to " .. areaName, "Uang tidak cukup", 5)
                return
            end
            task.wait(0.1)
            local retryMsg = fireWithPromptWait(function()
                fireWorldTeleport(areaName)
            end, 2.5)
            if retryMsg and retryMsg.Kind == "not_enough" then
                notify("Teleport to " .. areaName, "Uang tidak cukup", 5)
            end
            return
        end
        if msg.Kind == "not_enough" then
            notify("Teleport to " .. areaName, "Uang tidak cukup", 5)
        end
    end)
end

local function initWorldTeleports()
do
    local ForestTeleportSection = createSectionBox(State.Tabs.Forest:GetPage(), "Teleport")
    createButton(ForestTeleportSection, "Home", function()
        fireWorldTeleport("Forest")
    end)
    createButton(ForestTeleportSection, "Buy World", function()
        fireBuyArea("Forest")
    end)
    local ForestList = {
        {Label = "Reincarnation", Data = makeData(
            Vector3.new(5.688, 19.000, 22.620),
            CFrame.new(3.640704, 32.026222, -0.594986, -0.996133089, 0.038948622, -0.078752235, 0.000000000, 0.896365047, 0.443316728, 0.087857328, 0.441602468, -0.892898858),
            CFrame.new(5.688260, 20.499998, 22.620361, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            25.999973,
            0.500,
            40.000
        )},
        {Label = "Ticket Shop", Data = makeData(
            Vector3.new(-13.439, 19.201, 85.278),
            CFrame.new(5.131074, 27.627468, 90.108078, 0.251725823, -0.328588486, 0.910309672, 0.000000000, 0.940598249, 0.339521557, -0.967798591, -0.085466340, 0.236772880),
            CFrame.new(-13.439223, 20.701237, 85.277916, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            20.399977,
            0.500,
            40.000
        )},
        {Label = "Runes", Data = makeData(
            Vector3.new(-13.233, 20.099, -14.525),
            CFrame.new(-36.016521, 34.151733, 3.417183, 0.618687451, 0.312079877, -0.720993757, 0.000000000, 0.917718410, 0.397231579, 0.785637140, -0.245762199, 0.567780912),
            CFrame.new(-13.233118, 21.599215, -14.524694, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600002,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Forest", ForestList)
    createGrid(ForestTeleportSection, ForestList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local WinterTeleportSection = createSectionBox(State.Tabs.Winter:GetPage(), "Teleport")
    createButton(WinterTeleportSection, "Home", function()
        fireWorldTeleport("Winter")
    end)
    createButton(WinterTeleportSection, "Buy World", function()
        fireBuyArea("Winter")
    end)
    local WinterList = {
        {Label = "Passive Shards Shop", Data = makeData(
            Vector3.new(1484.535, 18.098, 79.519),
            CFrame.new(1497.478760, 25.320576, 85.072540, 0.394256741, -0.345924526, 0.851409376, 0.000000000, 0.926451564, 0.376413971, -0.919000268, -0.148403749, 0.365259826),
            CFrame.new(1484.534668, 19.597879, 79.519424, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203153,
            0.500,
            40.000
        )},
        {Label = "Passive Roll", Data = makeData(
            Vector3.new(1516.296, 18.561, 83.984),
            CFrame.new(1503.163696, 26.569178, 79.943626, -0.294034064, 0.409156203, -0.863791168, 0.000000000, 0.903741121, 0.428079486, 0.955794930, 0.125869945, -0.265730679),
            CFrame.new(1516.296143, 20.060999, 83.983582, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203249,
            0.500,
            40.000
        )},
        {Label = "Tier Roll", Data = makeData(
            Vector3.new(1512.674, 15.997, 1.453),
            CFrame.new(1491.860840, 31.086452, 0.383994, -0.051283818, 0.545489192, -0.836547434, 0.000000000, 0.837649643, 0.546207964, 0.998684049, 0.028011629, -0.042957876),
            CFrame.new(1512.674194, 17.496799, 1.452786, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880047,
            0.500,
            40.000
        )},
        {Label = "Ice Shop", Data = makeData(
            Vector3.new(1474.930, 18.561, -98.030),
            CFrame.new(1486.628296, 25.966484, -94.269417, 0.306021839, -0.412391514, 0.858069837, 0.000000000, 0.901310682, 0.433173239, -0.952024460, -0.132560477, 0.275820762),
            CFrame.new(1474.930176, 20.060999, -98.029701, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633066,
            0.500,
            40.000
        )},
        {Label = "Milestone", Data = makeData(
            Vector3.new(1512.674, 15.997, 1.453),
            CFrame.new(1491.860840, 31.086452, 0.383994, -0.051283818, 0.545489192, -0.836547434, 0.000000000, 0.837649643, 0.546207964, 0.998684049, 0.028011629, -0.042957876),
            CFrame.new(1512.674194, 17.496799, 1.452786, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880047,
            0.500,
            40.000
        )},
        {Label = "Boss", Data = makeData(
            Vector3.new(1486.732, 18.393, -180.705),
            CFrame.new(1476.835571, 24.304148, -172.430679, 0.641454339, 0.248214230, -0.725896776, 0.000000000, 0.946211576, 0.323548943, 0.767161310, -0.207541868, 0.606951416),
            CFrame.new(1486.731812, 19.893179, -180.705292, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633101,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(1454.642, 15.610, -15.706),
            CFrame.new(1433.811646, 28.496862, -19.566528, -0.182229251, 0.465488881, -0.866090477, 0.000000000, 0.880839229, 0.473415673, 0.983256161, 0.086270183, -0.160514653),
            CFrame.new(1454.642456, 17.110479, -15.705901, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.051544,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Winter", WinterList)
    createGrid(WinterTeleportSection, WinterList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local DesertTeleportSection = createSectionBox(State.Tabs.Desert:GetPage(), "Teleport")
    createButton(DesertTeleportSection, "Home", function()
        fireWorldTeleport("Desert")
    end)
    createButton(DesertTeleportSection, "Buy World", function()
        fireBuyArea("Desert")
    end)
    local DesertList = {
        {Label = "Sacrifice", Data = makeData(
            Vector3.new(2614.331, 14.993, 49.230),
            CFrame.new(2619.790039, 23.690708, 37.002373, -0.913122058, -0.193005964, 0.359105527, 0.000000000, 0.880837977, 0.473417908, -0.407686234, 0.432288349, -0.804312646),
            CFrame.new(2614.330566, 16.493240, 49.230499, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203174,
            0.500,
            40.000
        )},
        {Label = "Better Points", Data = makeData(
            Vector3.new(2559.386, 14.493, -2.146),
            CFrame.new(2546.067627, 21.795351, 2.336460, 0.318965644, 0.361703217, -0.876031816, 0.000000000, 0.924312115, 0.381637543, 0.947766304, -0.121729262, 0.294823796),
            CFrame.new(2559.386230, 15.993239, -2.145805, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203302,
            0.500,
            40.000
        )},
        {Label = "Oil Shop", Data = makeData(
            Vector3.new(2618.648, 15.210, -49.626),
            CFrame.new(2608.193604, 21.872202, -39.869930, 0.682258964, 0.248230696, -0.687680304, 0.000000000, 0.940596819, 0.339525521, 0.731110573, -0.231644332, 0.641730666),
            CFrame.new(2618.648438, 16.710327, -49.626289, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203126,
            0.500,
            40.000
        )},
        {Label = "Fossils", Data = makeData(
            Vector3.new(2645.560, 14.493, 6.615),
            CFrame.new(2630.879883, 19.511374, 4.807576, -0.122209154, 0.229672924, -0.965564787, 0.000000000, 0.972856939, 0.231407478, 0.992504358, 0.028280113, -0.118892029),
            CFrame.new(2645.559570, 15.993239, 6.615115, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203214,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(2447.432, 12.081, -8.576),
            CFrame.new(2436.589111, 22.728329, -14.044039, -0.450248271, 0.537215114, -0.713215590, 0.000000000, 0.798760056, 0.601649761, 0.892903388, 0.270891756, -0.359640360),
            CFrame.new(2447.432373, 13.581326, -8.576355, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203275,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Desert", DesertList)
    createGrid(DesertTeleportSection, DesertList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local MinesTeleportSection = createSectionBox(State.Tabs.Mines:GetPage(), "Teleport")
    createButton(MinesTeleportSection, "Home", function()
        fireWorldTeleport("Mines")
    end)
    createButton(MinesTeleportSection, "Buy World", function()
        fireBuyArea("Mines")
    end)
    local MinesList = {
        {Label = "Milestones", Data = makeData(
            Vector3.new(3656.122, 14.492, -9.657),
            CFrame.new(3652.164307, 20.547853, 2.567032, 0.951381981, 0.102941677, -0.290302008, 0.000000000, 0.942498028, 0.334211707, 0.308013380, -0.317963004, 0.896675706),
            CFrame.new(3656.122070, 15.991518, -9.657419, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633096,
            0.500,
            40.000
        )},
        {Label = "Sell ores", Data = makeData(
            Vector3.new(3653.821, 14.492, 25.575),
            CFrame.new(3655.571533, 22.648075, 13.806721, -0.989119947, -0.071829185, 0.128383145, 0.000000000, 0.872695327, 0.488265038, -0.147111058, 0.482952684, -0.863200426),
            CFrame.new(3653.821289, 15.991518, 25.574800, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633078,
            0.500,
            40.000
        )},
        {Label = "Pickaxe Shop", Data = makeData(
            Vector3.new(3692.154, 14.492, 26.067),
            CFrame.new(3682.919189, 21.123217, 17.450344, -0.682247519, 0.275205195, -0.677348137, 0.000000000, 0.926451147, 0.376415223, 0.731121302, 0.256808341, -0.632068992),
            CFrame.new(3692.153564, 15.991518, 26.067390, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633103,
            0.500,
            40.000
        )},
        {Label = "Workers Shop", Data = makeData(
            Vector3.new(3761.531, 17.880, 26.900),
            CFrame.new(3765.265381, 25.833832, 15.486748, -0.950409770, -0.147233292, 0.273940891, 0.000000000, 0.880837679, 0.473418325, -0.311000407, 0.449941397, -0.837156773),
            CFrame.new(3761.530762, 19.379683, 26.899773, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633069,
            0.500,
            40.000
        )},
        {Label = "Worker Trait", Data = makeData(
            Vector3.new(3760.204, 15.759, -8.829),
            CFrame.new(3761.437012, 22.603525, 3.652063, 0.995158315, -0.038532835, 0.090417527, 0.000000000, 0.919944584, 0.392048627, -0.098285854, -0.390150458, 0.915490329),
            CFrame.new(3760.204346, 17.258696, -8.828889, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633079,
            0.500,
            40.000
        )},
        {Label = "Minify", Data = makeData(
            Vector3.new(3801.725, 14.912, 7.956),
            CFrame.new(3792.272705, 19.865250, -1.241910, -0.697409332, 0.181542501, -0.693298340, 0.000000000, 0.967384458, 0.253312856, 0.716673076, 0.176662743, -0.674662888),
            CFrame.new(3801.724609, 16.411816, 7.955823, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633158,
            0.500,
            40.000
        )},
        {Label = "Prestige", Data = makeData(
            Vector3.new(3807.135, 14.492, -41.822),
            CFrame.new(3804.802979, 20.036755, -29.013096, 0.983824134, 0.053154033, -0.171069741, 0.000000000, 0.954963982, 0.296722144, 0.179137394, -0.291922420, 0.939516485),
            CFrame.new(3807.135254, 15.991518, -41.821598, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633091,
            0.500,
            40.000
        )},
        {Label = "Refinery", Data = makeData(
            Vector3.new(3691.123, 15.016, 132.358),
            CFrame.new(3679.385498, 23.439075, 132.763596, 0.034559265, 0.507540286, -0.860934794, 0.000000000, 0.861449420, 0.507843673, 0.999402642, -0.017550703, 0.029771056),
            CFrame.new(3691.122803, 16.515602, 132.357727, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633178,
            0.500,
            40.000
        )},
        {Label = "Pickaxe Enchants", Data = makeData(
            Vector3.new(3682.664, 16.843, 168.097),
            CFrame.new(3689.107422, 24.455635, 157.753387, -0.848791718, -0.237068459, 0.472600520, 0.000000000, 0.893845320, 0.448375523, -0.528727472, 0.380577445, -0.758688450),
            CFrame.new(3682.664307, 18.342896, 168.096649, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633136,
            0.500,
            40.000
        )},
        {Label = "Rune 1", Data = makeData(
            Vector3.new(3694.882, 15.582, -0.348),
            CFrame.new(3687.418945, 27.313175, -5.397151, -0.560342968, 0.621581197, -0.547405481, 0.000000000, 0.660909712, 0.750465572, 0.828260779, 0.420518100, -0.370336026),
            CFrame.new(3694.881836, 17.082020, -0.348331, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633117,
            0.500,
            40.000
        )},
        {Label = "Rune 2", Data = makeData(
            Vector3.new(3663.043, 15.578, 118.063),
            CFrame.new(3659.363770, 25.881180, 127.800369, 0.935447037, 0.228253171, -0.269887507, 0.000000000, 0.763544142, 0.645755649, 0.353466779, -0.604070187, 0.714255154),
            CFrame.new(3663.043213, 17.077541, 118.062874, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633091,
            0.500,
            40.000
        )},
        {Label = "Rune 3", Data = makeData(
            Vector3.new(3775.579, 15.496, 12.903),
            CFrame.new(3784.918701, 25.441692, 18.127495, 0.488156796, -0.540699899, 0.685088813, 0.000000000, 0.784971833, 0.619531572, -0.872756004, -0.302428544, 0.383189321),
            CFrame.new(3775.578857, 16.995569, 12.903443, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633062,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Mines", MinesList)
    createGrid(MinesTeleportSection, MinesList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local CyberTeleportSection = createSectionBox(State.Tabs.Cyber:GetPage(), "Teleport")
    createButton(CyberTeleportSection, "Home", function()
        fireWorldTeleport("Cyber")
    end)
    createButton(CyberTeleportSection, "Buy World", function()
        fireBuyArea("Cyber")
    end)
    local CyberList = {
        {Label = "Energy Shop", Data = makeData(
            Vector3.new(5526.205, 15.366, 21.824),
            CFrame.new(5543.679688, 23.797445, 27.019924, 0.285010904, -0.340665936, 0.895943940, 0.000000000, 0.934711754, 0.355406702, -0.958524227, -0.101294786, 0.266403079),
            CFrame.new(5526.205078, 16.865593, 21.823999, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504107,
            0.500,
            40.000
        )},
        {Label = "Power Shop", Data = makeData(
            Vector3.new(5598.063, 15.365, -52.749),
            CFrame.new(5591.055176, 20.625202, -34.939743, 0.930548728, 0.070598193, -0.359298080, 0.000000000, 0.981237650, 0.192802578, 0.366168320, -0.179412201, 0.913089275),
            CFrame.new(5598.062988, 16.864780, -52.748638, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504025,
            0.500,
            40.000
        )},
        {Label = "Charge Shop", Data = makeData(
            Vector3.new(5592.175, 15.363, 84.046),
            CFrame.new(5597.482910, 22.860453, 66.262512, -0.958225250, -0.087945469, 0.272157699, 0.000000000, 0.951552451, 0.307486206, -0.286014348, 0.294641048, -0.911801755),
            CFrame.new(5592.174805, 16.863241, 84.046295, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503986,
            0.500,
            40.000
        )},
        {Label = "Circuit Shop", Data = makeData(
            Vector3.new(5813.718, 15.568, 26.326),
            CFrame.new(5795.148926, 22.960747, 25.392265, -0.050235484, 0.301729023, -0.952069342, 0.000000000, 0.953272998, 0.302110463, 0.998737454, 0.015176665, -0.047888126),
            CFrame.new(5813.718262, 17.068384, 26.326275, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504168,
            0.500,
            40.000
        )},
        {Label = "Upgrade PC (Cores)", Data = makeData(
            Vector3.new(5779.062, 15.360, -44.662),
            CFrame.new(5774.031250, 23.792198, -27.139288, 0.961167812, 0.098079778, -0.257947117, 0.000000000, 0.934711456, 0.355407357, 0.275964409, -0.341606110, 0.898414671),
            CFrame.new(5779.062012, 16.860332, -44.661968, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503939,
            0.500,
            40.000
        )},
        {Label = "Tech Tree", Data = makeData(
            Vector3.new(5706.621, 101.935, -245.200),
            CFrame.new(5708.908691, 116.445381, -259.549500, -0.987525344, -0.105032779, 0.117310263, 0.000000000, 0.745017290, 0.667045176, -0.157459766, 0.658724010, -0.735723555),
            CFrame.new(5706.620605, 103.435333, -245.199951, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504005,
            0.500,
            40.000
        )},
        {Label = "Cyber Shop", Data = makeData(
            Vector3.new(5754.847, 15.482, 2.240),
            CFrame.new(5740.769043, 23.500961, 14.060647, 0.643061757, 0.255947262, -0.721777439, 0.000000000, 0.942496657, 0.334215790, 0.765814364, -0.214921400, 0.606083512),
            CFrame.new(5754.846680, 16.982416, 2.239594, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504065,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(5541.205, 15.902, 34.389),
            CFrame.new(5523.230469, 24.231348, 31.116262, -0.179136649, 0.344463736, -0.921550214, 0.000000000, 0.936702132, 0.350127339, 0.983824193, 0.062720641, -0.167797685),
            CFrame.new(5541.204590, 17.402464, 34.388988, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504190,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Cyber", CyberList)
    createGrid(CyberTeleportSection, CyberList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local OceanTeleportSection = createSectionBox(State.Tabs.Ocean:GetPage(), "Teleport")
    createButton(OceanTeleportSection, "Home", function()
        fireWorldTeleport("Ocean")
    end)
    createButton(OceanTeleportSection, "Buy World", function()
        fireBuyArea("Ocean")
    end)
    local OceanList = {
        {Label = "Coin Shop", Data = makeData(
            Vector3.new(-84.245, 15.909, -1909.452),
            CFrame.new(-92.179611, 26.739017, -1894.273682, 0.886207998, 0.221630886, -0.406835407, 0.000000000, 0.878148913, 0.478387415, 0.463287443, -0.423950762, 0.778222680),
            CFrame.new(-84.244690, 17.408550, -1909.452148, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504011,
            0.500,
            40.000
        )},
        {Label = "Sell Fish", Data = makeData(
            Vector3.new(-52.805, 15.910, -1894.369),
            CFrame.new(-55.200657, 27.784790, -1910.709473, -0.989423394, 0.077163368, -0.122830078, 0.000000000, 0.846773565, 0.531953573, 0.145056590, 0.526327312, -0.837817490),
            CFrame.new(-52.804977, 17.409569, -1894.368652, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504023,
            0.500,
            40.000
        )},
        {Label = "Rods Shop", Data = makeData(
            Vector3.new(-52.589, 15.910, -1918.950),
            CFrame.new(-57.254658, 24.853153, -1901.536255, 0.965928316, 0.098773256, -0.239220500, 0.000000000, 0.924309611, 0.381643951, 0.258809954, -0.368640691, 0.892816722),
            CFrame.new(-52.588902, 17.409569, -1918.949707, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503962,
            0.500,
            40.000
        )},
        {Label = "Prestige", Data = makeData(
            Vector3.new(35.145, 15.409, -1897.175),
            CFrame.new(16.789160, 20.127487, -1902.927246, -0.299031794, 0.157488123, -0.941157520, 0.000000000, 0.986286879, 0.165039822, 0.954243124, 0.049352154, -0.294931144),
            CFrame.new(35.145496, 16.908550, -1897.174927, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503994,
            0.500,
            40.000
        )},
        {Label = "Depth", Data = makeData(
            Vector3.new(-36.976, 19.489, -2056.097),
            CFrame.new(-20.304077, 27.195210, -2048.101807, 0.432391793, -0.286926121, 0.854816318, 0.000000000, 0.948020101, 0.318210751, -0.901685834, -0.137591720, 0.409916103),
            CFrame.new(-36.976414, 20.988827, -2056.096924, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504047,
            0.500,
            40.000
        )},
        {Label = "Aquarium", Data = makeData(
            Vector3.new(-27.464, 16.010, -1953.105),
            CFrame.new(-10.825624, 25.559849, -1946.877563, 0.350525141, -0.386536628, 0.853066027, 0.000000000, 0.910856903, 0.412722498, -0.936553359, -0.144669607, 0.319278210),
            CFrame.new(-27.463823, 17.510109, -1953.104736, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503990,
            0.500,
            40.000
        )},
        {Label = "Pearls Shop", Data = makeData(
            Vector3.new(-6.951, 15.910, -1950.234),
            CFrame.new(-24.716681, 24.853159, -1953.296509, -0.169855535, 0.376098603, -0.910878181, 0.000000000, 0.924309313, 0.381644309, 0.985468924, 0.064824395, -0.156999066),
            CFrame.new(-6.950912, 17.409569, -1950.234375, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504005,
            0.500,
            40.000
        )},
        {Label = "Fisherman Shop", Data = makeData(
            Vector3.new(6.584, 19.477, -2013.135),
            CFrame.new(-11.778711, 27.495384, -2013.981079, -0.046050403, 0.333863378, -0.941495955, 0.000000000, 0.942495823, 0.334217936, 0.998939097, 0.015390871, -0.043402314),
            CFrame.new(6.584225, 20.976797, -2013.134521, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504002,
            0.500,
            40.000
        )},
        {Label = "Relics", Data = makeData(
            Vector3.new(44.049, 19.477, -2049.437),
            CFrame.new(25.760534, 27.702478, -2050.280029, -0.046050407, 0.344470203, -0.937667131, 0.000000000, 0.938662946, 0.344836026, 0.998939157, 0.015879840, -0.043225810),
            CFrame.new(44.048794, 20.976797, -2049.437012, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503998,
            0.500,
            40.000
        )},
        {Label = "Enchants Rod", Data = makeData(
            Vector3.new(8.075, 15.910, -1876.339),
            CFrame.new(-1.638691, 21.601154, -1892.724243, -0.860203445, 0.109593071, -0.498035491, 0.000000000, 0.976634026, 0.214909047, 0.509950936, 0.184865505, -0.840103984),
            CFrame.new(8.074993, 17.409569, -1876.338867, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503990,
            0.500,
            40.000
        )},
        {Label = "Fisherman Traits", Data = makeData(
            Vector3.new(-7.731, 20.055, -2097.168),
            CFrame.new(-9.150262, 27.447569, -2078.629639, 0.997080326, 0.023069723, -0.072792828, 0.000000000, 0.953271985, 0.302113801, 0.076361038, -0.301231742, 0.950488567),
            CFrame.new(-7.730510, 21.555141, -2097.167969, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504002,
            0.500,
            40.000
        )},
        {Label = "Milestone", Data = makeData(
            Vector3.new(-12.070, 16.224, -1848.307),
            CFrame.new(-10.960073, 22.344925, -1867.223633, -0.998281598, -0.013882399, 0.056931511, 0.000000000, 0.971533477, 0.236902446, -0.058599643, 0.236495346, -0.969863892),
            CFrame.new(-12.070465, 17.724379, -1848.307373, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504034,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(-81.523, 16.510, -1887.714),
            CFrame.new(-95.313461, 30.093876, -1894.363037, -0.434279412, 0.558064044, -0.707082689, 0.000000000, 0.784968615, 0.619535506, 0.900778115, 0.269051522, -0.340895772),
            CFrame.new(-81.522522, 18.010454, -1887.714233, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503992,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Ocean", OceanList)
    createGrid(OceanTeleportSection, OceanList, function(item)
        teleportWithData(item.Data)
    end)
end

  do
      local MushroomTeleportSection = createSectionBox(State.MushroomTab:GetPage(), "Teleport")
      createButton(MushroomTeleportSection, "Home", function()
          fireWorldTeleport("Mushroom World")
      end)
      createButton(MushroomTeleportSection, "Buy World", function()
          fireBuyArea("Mushroom World")
      end)
      local MushroomList = {
          {Label = "Home (Unofficial)", Data = makeData(
              Vector3.new(1796.507, 15.092, -1947.680),
              CFrame.new(1783.967651, 20.732552, -1946.964478, 0.056972563, 0.312557608, -0.948188841, 0.000000000,
  0.949731350, 0.313066125, 0.998375654, -0.017836180, 0.054108638),
              CFrame.new(1796.507202, 16.592346, -1947.680054, 1.000000000, 0.000000000, 0.000000000, 0.000000000,
  1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              13.224738,
              0.500,
              40.000
          )},
          {Label = "Perk", Data = makeData(
              Vector3.new(1963.915, 18.819, -1933.641),
              CFrame.new(1953.011475, 26.843781, -1937.305054, -0.318528295, 0.467683554, -0.824507058, 0.000000000,
  0.869812727, 0.493382156, 0.947913408, 0.157156169, -0.277059942),
              CFrame.new(1963.915283, 20.318949, -1933.640991, 1.000000000, 0.000000000, 0.000000000, 0.000000000,
  1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              13.224668,
              0.500,
              40.000
          )},
          {Label = "Seed Shop", Data = makeData(
              Vector3.new(1804.104, 15.092, -1968.615),
              CFrame.new(1808.584229, 24.238993, -1951.240723, 0.968319833, -0.097901441, 0.229721680, 0.000000000, 0.919941664, 0.392055333, -0.249713331, -0.379634947, 0.890797675),
              CFrame.new(1804.103760, 16.592346, -1968.614868, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504019,
              0.500,
              40.000
          )},
          {Label = "Fungus Shop", Data = makeData(
              Vector3.new(1834.716, 15.092, -1925.022),
              CFrame.new(1819.225098, 23.627050, -1934.559326, -0.524274945, 0.307138503, -0.794230282, 0.000000000, 0.932688832, 0.360682070, 0.851549149, 0.189096570, -0.488985330),
              CFrame.new(1834.715820, 16.592308, -1925.022217, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504013,
              0.500,
              40.000
          )},
          {Label = "Milestone", Data = makeData(
              Vector3.new(1835.331, 15.092, -1982.877),
              CFrame.new(1817.138428, 23.318024, -1984.923950, -0.111806244, 0.342675626, -0.932776928, 0.000000000, 0.938662350, 0.344837725, 0.993730068, 0.038555011, -0.104948305),
              CFrame.new(1835.331299, 16.592310, -1982.877075, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.503986,
              0.500,
              40.000
          )},
          {Label = "Spores Shop", Data = makeData(
              Vector3.new(1817.428, 18.812, -2061.365),
              CFrame.new(1830.399658, 25.783215, -2047.867188, 0.721028447, -0.194372177, 0.665084600, 0.000000000, 0.959848940, 0.280517608, -0.692905426, -0.202261180, 0.692078412),
              CFrame.new(1817.427856, 20.311998, -2061.365479, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.503992,
              0.500,
              40.000
          )},
          {Label = "Toxic Mushroom Shop", Data = makeData(
              Vector3.new(1841.913, 18.812, -2052.954),
              CFrame.new(1826.785645, 28.859879, -2061.814941, -0.505423188, 0.378164619, -0.775589466, 0.000000000, 0.898846924, 0.438262880, 0.862871647, 0.221508220, -0.454298049),
              CFrame.new(1841.912720, 20.311998, -2052.954346, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.503969,
              0.500,
              40.000
          )},
          {Label = "Glowy Crystals", Data = makeData(
              Vector3.new(1867.056, 18.812, -2085.995),
              CFrame.new(1850.763672, 28.561760, -2092.843994, -0.387506783, 0.389931649, -0.835339427, 0.000000000, 0.906138897, 0.422980428, 0.921866894, 0.163907781, -0.351134956),
              CFrame.new(1867.056152, 20.311951, -2085.995361, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504051,
              0.500,
              40.000
          )},
          {Label = "Auras", Data = makeData(
              Vector3.new(1784.383, 18.812, -2109.326),
              CFrame.new(1801.805298, 28.361778, -2105.850830, 0.195594564, -0.404752761, 0.893262506, 0.000000000, 0.910855830, 0.412724614, -0.980684817, -0.080726691, 0.178158447),
              CFrame.new(1784.383057, 20.311998, -2109.325684, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504051,
              0.500,
              40.000
          )},
          {Label = "Plant Plot 1", Data = makeData(
              Vector3.new(1821.934, 15.875, -1909.829),
              CFrame.new(1818.992310, 23.683229, -1925.073853, -0.981890798, 0.071312420, -0.175513402, 0.000000000, 0.926447988, 0.376422822, 0.189447656, 0.369606107, -0.909670770),
              CFrame.new(1821.933716, 17.374762, -1909.828735, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              16.758945,
              0.500,
              40.000
          )},
          {Label = "Magic Energy", Data = makeData(
              Vector3.new(1999.457, 18.319, -1941.725),
              CFrame.new(1981.025146, 24.653196, -1945.885132, -0.220177427, 0.241774350, -0.945022285, 0.000000000, 0.968796730, 0.247856781, 0.975459874, 0.054572467, -0.213307157),
              CFrame.new(1999.456909, 19.818998, -1941.724731, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504059,
              0.500,
              40.000
          )},
          {Label = "Plant Plot 2", Data = makeData(
              Vector3.new(1834.254, 18.898, -2137.026),
              CFrame.new(1836.213867, 26.395699, -2118.570557, 0.994410932, -0.032464683, 0.100463986, 0.000000000, 0.951551020, 0.307491273, -0.105579197, -0.305772692, 0.946232677),
              CFrame.new(1834.254395, 20.398390, -2137.025879, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504004,
              0.500,
              40.000
          )},
          {Label = "Plant Plot 3", Data = makeData(
              Vector3.new(1967.392, 19.967, -1985.897),
              CFrame.new(1960.443970, 25.010784, -1968.020874, 0.932074666, 0.065830939, -0.356234789, 0.000000000, 0.983350515, 0.181719705, 0.362266392, -0.169376329, 0.916555941),
              CFrame.new(1967.391968, 21.466524, -1985.897339, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.503960,
              0.500,
              40.000
          )},
          {Label = "Rune", Data = makeData(
              Vector3.new(1782.607, 15.685, -1934.729),
              CFrame.new(1765.799561, 26.515253, -1938.026733, -0.192512363, 0.469442606, -0.861720800, 0.000000000, 0.878146946, 0.478391111, 0.981294572, 0.092096202, -0.169054136),
              CFrame.new(1782.606567, 17.184713, -1934.729492, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
              70.000,
              Enum.CameraType.Custom,
              19.504005,
              0.500,
              40.000
          )}
      }
      registerRuneLocations("Mushroom World", MushroomList)
      createGrid(MushroomTeleportSection, MushroomList, function(item)
          teleportWithData(item.Data)
      end)
  end

  do
      local MushroomFeaturedSection = createSectionBox(State.MushroomTab:GetPage(), "Featured")

      local function fireMushroomRemote(action, arg2, arg3)
          local remote = getMainRemote and getMainRemote() or nil
          if not remote then
              return
          end
          pcall(function()
              if arg2 == nil then
                  remote:FireServer(action)
              elseif arg3 == nil then
                  remote:FireServer(action, arg2)
              else
                  remote:FireServer(action, arg2, arg3)
              end
          end)
      end

      createButton(MushroomFeaturedSection, "Buy All Seed Shop", function()
          fireMushroomRemote("BuyAllSeed", "Mushrooms")
      end)

      createButton(MushroomFeaturedSection, "Sell All", function()
          fireMushroomRemote("SellPlant", "Mushrooms", "Red Mushroom")
      end)

      createButton(MushroomFeaturedSection, "Milestones Up", function()
          fireMushroomRemote("ScoreReset")
      end)

      createButton(MushroomFeaturedSection, "Glowy Crystals", function()
          fireMushroomRemote("GlowyReset")
      end)

      createButton(MushroomFeaturedSection, "Magic Energy Reset", function()
          fireMushroomRemote("ConvertCurrency", "Magic Energy")
      end)
  end

  State.InitMushroom = function()
      local MushroomAutomationSection = createSectionBox(State.MushroomTab:GetPage(), "Automation")
      local function setControlsEnabled(controls, enabled)
          for _, ctrl in ipairs(controls) do
              if ctrl and ctrl.SetEnabled then
                  ctrl:SetEnabled(enabled)
              end
          end
      end

      local function createListDropdownRow(parent, labelText, onToggle)
          local frame = Instance.new("Frame")
          frame.Size = UDim2.new(1, 0, 0, 30)
          frame.BorderSizePixel = 0
          frame.Parent = parent
          registerTheme(frame, "BackgroundColor3", "Main")
          addCorner(frame, 6)
          addStroke(frame, "Muted", 1, 0.8)

          local label = Instance.new("TextLabel")
          label.Size = UDim2.new(1, -50, 1, 0)
          label.BackgroundTransparency = 1
          label.Font = Enum.Font.Gotham
          label.TextSize = 13
          label.TextXAlignment = Enum.TextXAlignment.Left
          label.Text = labelText
          label.Parent = frame
          registerTheme(label, "TextColor3", "Text")

          local btn = Instance.new("TextButton")
          btn.Size = UDim2.new(0, 30, 0, 20)
          btn.Position = UDim2.new(1, -35, 0.5, -10)
          btn.BorderSizePixel = 0
          btn.Font = Enum.Font.GothamSemibold
          btn.TextSize = 12
          btn.AutoButtonColor = false
          btn.Parent = frame
          registerTheme(btn, "BackgroundColor3", "Panel")
          registerTheme(btn, "TextColor3", "Text")
          addCorner(btn, 6)

          local enabled = true
          local expanded = false

          local function setExpanded(state)
              expanded = state and true or false
              btn.Text = expanded and "v" or ">"
          end

          btn.MouseButton1Click:Connect(function()
              if not enabled then
                  return
              end
              setExpanded(not expanded)
              if onToggle then
                  onToggle(expanded)
              end
          end)

          setExpanded(false)

          return {
              SetEnabled = function(_, value)
                  enabled = value and true or false
                  label.TextTransparency = enabled and 0 or 0.4
                  btn.TextTransparency = enabled and 0 or 0.4
              end,
              SetExpanded = function(_, value)
                  setExpanded(value)
              end,
              Frame = frame
          }
      end

      local FungusAutoEnabled = false
      local FungusAutoConn = nil
      local FungusAutoAccum = 0
      local FungusAutoInterval = 0.25
      local FungusDefaultClickCooldown = 0.6
      local FungusLastClick = 0
      local FungusUseUpgradeAll = true
      local FungusMaxed = {}
      local FungusPromptConn = nil
      local FungusSkipMaxed = true
      local FungusItemEnabled = {}
      State.FungusAutoIndex = 1
      State.FungusAutoOrder = {
          "Fungus Multiplier",
          "Fungus Multiplier II",
          "Mushrooms Multiplier",
          "Score Multiplier",
          "Score Multiplier II",
          "Score Multiplier III",
          "Mushroom Plant Capacity",
          "Plant Max Size Cap",
          "Mushroom Growth Speed",
          "Mushroom Inventory",
          "Spores Multiplier",
          "Glowy Crystals Multiplier",
          "Magic Energy Multiplier",
          "Extra Fungus Multiplier",
          "Spores Multiplier II",
          "Glowy Crystals Multiplier II"
      }

      setGlobalClickCooldown("FungusShop", FungusDefaultClickCooldown)
      for _, name in ipairs(State.FungusAutoOrder) do
          FungusItemEnabled[name] = true
      end

      local function attachFungusPromptListener()
          if FungusPromptConn then
              return
          end
          local ok, remote = pcall(function()
              return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
          end)
          if not ok or not remote or not remote:IsA("RemoteEvent") then
              return
          end
          FungusPromptConn = remote.OnClientEvent:Connect(function(_, msg)
              if not FungusAutoEnabled then
                  return
              end
              if type(msg) ~= "string" then
                  return
              end
              local lower = string.lower(msg)
              if not string.find(lower, "already reached max upgrade", 1, true) then
                  return
              end
              for _, name in ipairs(State.FungusAutoOrder) do
                  if string.find(lower, string.lower(name), 1, true) then
                      FungusMaxed[name] = true
                  end
              end
          end)
          trackConnection(FungusPromptConn)
      end

      local function detachFungusPromptListener()
          if FungusPromptConn then
              FungusPromptConn:Disconnect()
              FungusPromptConn = nil
          end
      end

      local function getNextFungusName()
          local total = #State.FungusAutoOrder
          for _ = 1, total do
              local name = State.FungusAutoOrder[State.FungusAutoIndex]
              State.FungusAutoIndex += 1
              if State.FungusAutoIndex > total then
                  State.FungusAutoIndex = 1
              end
              if FungusItemEnabled[name] and (not FungusSkipMaxed or not FungusMaxed[name]) then
                  return name
              end
          end
          return nil
      end

      local FungusBox = createSubSectionBox(MushroomAutomationSection, "Auto Buy Fungus Shop")
      local FungusControls = {}
      local function addFungusControl(ctrl)
          FungusControls[#FungusControls + 1] = ctrl
          return ctrl
      end

      createToggle(FungusBox, "On/Off", nil, false, function(v)
          FungusAutoEnabled = v
          setControlsEnabled(FungusControls, FungusAutoEnabled)
          if FungusAutoEnabled then
              if FungusAutoConn then
                  FungusAutoConn:Disconnect()
              end
              FungusAutoAccum = 0
              State.FungusAutoIndex = 1
              FungusMaxed = {}
              attachFungusPromptListener()
              FungusAutoConn = RunService.Heartbeat:Connect(function(dt)
                  FungusAutoAccum += dt
                  if FungusAutoAccum >= FungusAutoInterval then
                      FungusAutoAccum = 0
                      local remote = getMainRemote and getMainRemote() or nil
                      if not remote then return end
                      local now = os.clock()
                      if now - FungusLastClick < getGlobalClickCooldown("FungusShop") then
                          return
                      end
                      local action = FungusUseUpgradeAll and "UpgradeAll" or "Upgrade"
                      local name = getNextFungusName()
                      if name then
                          pcall(function()
                              remote:FireServer(action, "Fungus", name)
                          end)
                      else
                          return
                      end
                      FungusLastClick = now
                  end
              end)
              trackConnection(FungusAutoConn)
          else
              if FungusAutoConn then
                  FungusAutoConn:Disconnect()
                  FungusAutoConn = nil
              end
              detachFungusPromptListener()
          end
      end)

      addFungusControl(createToggle(FungusBox, "Mode: Upgrade All", nil, true, function(v)
          FungusUseUpgradeAll = v
      end))

      addFungusControl(createSlider(FungusBox, "Click Speed (sec)", nil, 0.1, 5, FungusDefaultClickCooldown, function(v)
          setGlobalClickCooldown("FungusShop", v)
      end, 1))

      addFungusControl(createToggle(FungusBox, "Skip Maxed Items", nil, true, function(v)
          FungusSkipMaxed = v
      end))

      local FungusListContainer
      addFungusControl(createListDropdownRow(FungusBox, "Item List", function(open)
          if FungusListContainer then
              FungusListContainer.Visible = open
          end
      end))

      local FungusListContent = createSubSectionBox(FungusBox, "Item List")
      FungusListContainer = FungusListContent.Parent
      FungusListContainer.Visible = false

      for _, name in ipairs(State.FungusAutoOrder) do
          addFungusControl(createToggle(FungusListContent, name, nil, true, function(v)
              FungusItemEnabled[name] = v
          end))
      end

      setControlsEnabled(FungusControls, false)

      local SporesAutoEnabled = false
      local SporesAutoConn = nil
      local SporesAutoAccum = 0
      local SporesAutoInterval = 0.25
      local SporesDefaultClickCooldown = 0.6
      local SporesLastClick = 0
      local SporesUseUpgradeAll = true
      local SporesMaxed = {}
      local SporesPromptConn = nil
      local SporesSkipMaxed = true
      local SporesItemEnabled = {}
      State.SporesAutoIndex = 1
      State.SporesAutoOrder = {
          "Spores Multiplier",
          "Fungus Multiplier",
          "Score Multiplier",
          "Mushrooms Multiplier",
          "Mushroom Inventory",
          "Plant Max Size Cap",
          "Glowy Crystal Multiplier",
          "Magic Energy Multiplier",
          "Extra Spores Multiplier"
      }

      setGlobalClickCooldown("SporesShop", SporesDefaultClickCooldown)
      for _, name in ipairs(State.SporesAutoOrder) do
          SporesItemEnabled[name] = true
      end

      local function attachSporesPromptListener()
          if SporesPromptConn then
              return
          end
          local ok, remote = pcall(function()
              return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
          end)
          if not ok or not remote or not remote:IsA("RemoteEvent") then
              return
          end
          SporesPromptConn = remote.OnClientEvent:Connect(function(_, msg)
              if not SporesAutoEnabled then
                  return
              end
              if type(msg) ~= "string" then
                  return
              end
              local lower = string.lower(msg)
              if not string.find(lower, "already reached max upgrade", 1, true) then
                  return
              end
              for _, name in ipairs(State.SporesAutoOrder) do
                  if string.find(lower, string.lower(name), 1, true) then
                      SporesMaxed[name] = true
                  end
              end
          end)
          trackConnection(SporesPromptConn)
      end

      local function detachSporesPromptListener()
          if SporesPromptConn then
              SporesPromptConn:Disconnect()
              SporesPromptConn = nil
          end
      end

      local function getNextSporesName()
          local total = #State.SporesAutoOrder
          for _ = 1, total do
              local name = State.SporesAutoOrder[State.SporesAutoIndex]
              State.SporesAutoIndex += 1
              if State.SporesAutoIndex > total then
                  State.SporesAutoIndex = 1
              end
              if SporesItemEnabled[name] and (not SporesSkipMaxed or not SporesMaxed[name]) then
                  return name
              end
          end
          return nil
      end

      local SporesBox = createSubSectionBox(MushroomAutomationSection, "Auto Buy Spores Shop")
      local SporesControls = {}
      local function addSporesControl(ctrl)
          SporesControls[#SporesControls + 1] = ctrl
          return ctrl
      end

      createToggle(SporesBox, "On/Off", nil, false, function(v)
          SporesAutoEnabled = v
          setControlsEnabled(SporesControls, SporesAutoEnabled)
          if SporesAutoEnabled then
              if SporesAutoConn then
                  SporesAutoConn:Disconnect()
              end
              SporesAutoAccum = 0
              State.SporesAutoIndex = 1
              SporesMaxed = {}
              attachSporesPromptListener()
              SporesAutoConn = RunService.Heartbeat:Connect(function(dt)
                  SporesAutoAccum += dt
                  if SporesAutoAccum >= SporesAutoInterval then
                      SporesAutoAccum = 0
                      local remote = getMainRemote and getMainRemote() or nil
                      if not remote then return end
                      local now = os.clock()
                      if now - SporesLastClick < getGlobalClickCooldown("SporesShop") then
                          return
                      end
                      local action = SporesUseUpgradeAll and "UpgradeAll" or "Upgrade"
                      local name = getNextSporesName()
                      if name then
                          pcall(function()
                              remote:FireServer(action, "Spores", name)
                          end)
                      else
                          return
                      end
                      SporesLastClick = now
                  end
              end)
              trackConnection(SporesAutoConn)
          else
              if SporesAutoConn then
                  SporesAutoConn:Disconnect()
                  SporesAutoConn = nil
              end
              detachSporesPromptListener()
          end
      end)

      addSporesControl(createToggle(SporesBox, "Mode: Upgrade All", nil, true, function(v)
          SporesUseUpgradeAll = v
      end))

      addSporesControl(createSlider(SporesBox, "Click Speed (sec)", nil, 0.1, 5, SporesDefaultClickCooldown, function(v)
          setGlobalClickCooldown("SporesShop", v)
      end, 1))

      addSporesControl(createToggle(SporesBox, "Skip Maxed Items", nil, true, function(v)
          SporesSkipMaxed = v
      end))

      local SporesListContainer
      addSporesControl(createListDropdownRow(SporesBox, "Item List", function(open)
          if SporesListContainer then
              SporesListContainer.Visible = open
          end
      end))

      local SporesListContent = createSubSectionBox(SporesBox, "Item List")
      SporesListContainer = SporesListContent.Parent
      SporesListContainer.Visible = false

      for _, name in ipairs(State.SporesAutoOrder) do
          addSporesControl(createToggle(SporesListContent, name, nil, true, function(v)
              SporesItemEnabled[name] = v
          end))
      end

      setControlsEnabled(SporesControls, false)
  end

  -- [SECTION] Farming Teleports
  -- =====================================================
-- [SECTION] Space World - Auto Buy Farming Shop
-- =====================================================
local FarmingAutoEnabled = false
local FarmingAutoConn = nil
local FarmingAutoInterval = 0.25
local FarmingAutoAccum = 0
local FarmingDefaultClickCooldown = 0.6
local FarmingLastClick = 0
local FarmingActiveShop = nil
State.FarmingAutoIndex = 1

local FarmingShopItems = {
    Dirtite = {
        "Dirtite",
        "Dirtite II",
        "Moonlite",
        "Moonlite II",
        "Venusite",
        "Coins Multiplier",
        "Ore Multiplier"
    },
    Moonlite = {
        "Dirtite",
        "Moonlite",
        "Marsite",
        "Mercuryte",
        "Ore Inventory",
        "Fish Inventory"
    },
    Marsite = {
        "Moonlite",
        "Marsite",
        "Venusite",
        "Jupiterite",
        "Ore Multiplier",
        "Glowy Crystals"
    },
    Venusite = {
        "Marsite",
        "Venusite",
        "Mercuryte",
        "Cosmic Points",
        "Mushroom Inventory"
    },
    Mercuryte = {
        "Venusite",
        "Mercuryte",
        "Jupiterite",
        "Saturnite",
        "Tier Luck",
        "Tier Bulk"
    },
    Jupiterite = {
        "Mercuryte",
        "Jupiterite",
        "Saturnite",
        "Saturnite II",
        "Uranite",
        "Coins Multiplier",
        "Glowy Crystals"
    },
    Saturnite = {
        "Jupiterite",
        "Saturnite",
        "Uranite",
        "Uranite II",
        "Neptunite",
        "Coin Multiplier",
        "Worker XP",
        "Fishing XP"
    },
    Uranite = {
        "Saturnite",
        "Uranite",
        "Jupiterite",
        "Neptunite",
        "Tier Luck",
        "Passive Shards",
        "Ore Multiplier",
        "Coins Multiplier",
        "Glowy Crystals"
    },
    Neptunite = {
        "Neptunite",
        "Uranite",
        "Saturnite",
        "Plutite",
        "Passive Shards",
        "Light Points Multiplier"
    },
    Plutite = {
        "Infinite Plutite",
        "Infinite Neptunite",
        "Infinite Uranite",
        "Infinite Saturnite",
        "Infinite Jupiterite",
        "Infinite Mercuryte",
        "Infinite Venusite",
        "Infinite Marsite",
        "Infinite Moonlite",
        "Infinite Dirtite"
    },
    Sunite = {
        "Infinite Sunite",
        "Infinite Plutite",
        "Infinite Neptunite",
        "Infinite Uranite",
        "Infinite Saturnite",
        "Infinite Jupiterite",
        "Infinite Mercuryte",
        "Infinite Venusite",
        "Infinite Marsite",
        "Infinite Moonlite",
        "Infinite Dirtite",
        "Rune Bulk"
    }
}

setGlobalClickCooldown("FarmingShop", FarmingDefaultClickCooldown)

local function setFarmingAutoShop(name)
    FarmingActiveShop = name
    State.FarmingAutoIndex = 1
end

createButton(TeleportSection, "Home", function()
    fireWorldTeleport("Space World")
end)
createButton(TeleportSection, "Buy World", function()
    fireBuyArea("Space World")
end)

createToggle(TeleportSection, "Auto Buy Farming", nil, false, function(v)
    FarmingAutoEnabled = v
    if FarmingAutoEnabled then
        if FarmingAutoConn then
            FarmingAutoConn:Disconnect()
        end
        FarmingAutoAccum = 0
        FarmingAutoConn = RunService.Heartbeat:Connect(function(dt)
            FarmingAutoAccum += dt
            if FarmingAutoAccum >= FarmingAutoInterval then
                FarmingAutoAccum = 0
                if not FarmingActiveShop then
                    return
                end
                local items = FarmingShopItems[FarmingActiveShop]
                if not items or #items == 0 then
                    return
                end
                local now = os.clock()
                if now - FarmingLastClick < getGlobalClickCooldown("FarmingShop") then
                    return
                end
                local remote = getMainRemote and getMainRemote() or nil
                if not remote then
                    return
                end
                local itemName = items[State.FarmingAutoIndex]
                State.FarmingAutoIndex += 1
                if State.FarmingAutoIndex > #items then
                    State.FarmingAutoIndex = 1
                end
                pcall(function()
                    remote:FireServer("UpgradeAll", FarmingActiveShop, itemName)
                end)
                FarmingLastClick = now
            end
        end)
        trackConnection(FarmingAutoConn)
    else
        if FarmingAutoConn then
            FarmingAutoConn:Disconnect()
            FarmingAutoConn = nil
        end
    end
end)

createSlider(TeleportSection, "Farming Click Speed (sec)", nil, 0.1, 5, FarmingDefaultClickCooldown, function(v)
    setGlobalClickCooldown("FarmingShop", v)
end, 1)

local PlanetifyAutoEnabled = false
local PlanetifyAutoConn = nil
local PlanetifyAutoAccum = 0
local PlanetifyAutoInterval = 5

local function firePlanetifyUp()
    local remote = getMainRemote and getMainRemote() or nil
    if not remote then
        return
    end
    pcall(function()
        remote:FireServer("PlanetifyUp")
    end)
end

createToggle(TeleportSection, "Auto Upgrade Planetify", nil, false, function(v)
    PlanetifyAutoEnabled = v
    if PlanetifyAutoEnabled then
        if PlanetifyAutoConn then
            PlanetifyAutoConn:Disconnect()
        end
        PlanetifyAutoAccum = 0
        firePlanetifyUp()
        PlanetifyAutoConn = RunService.Heartbeat:Connect(function(dt)
            PlanetifyAutoAccum += dt
            if PlanetifyAutoAccum >= PlanetifyAutoInterval then
                PlanetifyAutoAccum = 0
                firePlanetifyUp()
            end
        end)
        trackConnection(PlanetifyAutoConn)
    else
        if PlanetifyAutoConn then
            PlanetifyAutoConn:Disconnect()
            PlanetifyAutoConn = nil
        end
    end
end)

createButton(TeleportSection, "Upgrade Planetify", function()
    firePlanetifyUp()
end)

-- [SECTION] Farming Teleports
local FarmingSection = createSubSectionBox(TeleportSection, "Farming")
local FarmingList = {
    {Label = "Off", Data = makeData(
        Vector3.new(1350.989, 14.000, 1837.671),
        CFrame.new(1348.699951, 15.408682, 1847.589722, 0.974393725, -0.002014387, -0.224839613, 0.000000000, 0.999959946, -0.008958858, 0.224848613, 0.008729455, 0.974354684),
        CFrame.new(1350.988770, 15.499881, 1837.671021, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179767,
        0.500,
        40.000
    )},
    {Label = "Dirtite", Data = makeData(
        Vector3.new(1537.805, 7.117, 1847.591),
        CFrame.new(1528.735107, 11.330198, 1861.700439, 0.841190636, 0.086346850, -0.533800125, 0.000000000, 0.987168372, 0.159683138, 0.540738702, -0.134323955, 0.830396771),
        CFrame.new(1537.805054, 8.616975, 1847.590942, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        16.991276,
        0.500,
        40.000
    )},
    {Label = "Moonlite", Data = makeData(
        Vector3.new(1508.873, 8.290, 1858.007),
        CFrame.new(1518.843140, 13.063017, 1866.004150, 0.625704587, -0.193504289, 0.755678475, 0.000000000, 0.968743861, 0.248063311, -0.780060112, -0.155214354, 0.606147468),
        CFrame.new(1508.873413, 9.790308, 1858.007202, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193076,
        0.500,
        40.000
    )},
    {Label = "Marsite", Data = makeData(
        Vector3.new(1511.441, 8.345, 1935.476),
        CFrame.new(1520.044189, 14.466647, 1944.345703, 0.717809558, -0.243914172, 0.652116001, 0.000000000, 0.936625957, 0.350330859, -0.696239471, -0.251470834, 0.672319114),
        CFrame.new(1511.440796, 9.844719, 1935.475830, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193000,
        0.500,
        40.000
    )},
    {Label = "Venusite", Data = makeData(
        Vector3.new(1553.479, 8.388, 1936.836),
        CFrame.new(1544.007080, 13.947904, 1928.597900, -0.656242728, 0.232171014, -0.717943013, 0.000000000, 0.951485157, 0.307694733, 0.754549861, 0.201922432, -0.624405205),
        CFrame.new(1553.478882, 9.888475, 1936.835693, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.192999,
        0.500,
        40.000
    )},
    {Label = "Mercuryte", Data = makeData(
        Vector3.new(1560.474, 13.857, 2044.468),
        CFrame.new(1550.212769, 18.485125, 2036.788086, -0.599218488, 0.189828783, -0.777754605, 0.000000000, 0.971482158, 0.237112448, 0.800585508, 0.142082170, -0.582130075),
        CFrame.new(1560.473755, 15.356892, 2044.468140, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193063,
        0.500,
        40.000
    )},
    {Label = "Jupiterite", Data = makeData(
        Vector3.new(1507.067, 13.997, 2041.918),
        CFrame.new(1514.134399, 18.913727, 2052.520752, 0.832089007, -0.143643469, 0.535718620, 0.000000000, 0.965881586, 0.258984059, -0.554642141, -0.215497792, 0.803699434),
        CFrame.new(1507.066650, 15.496941, 2041.917603, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.192964,
        0.500,
        40.000
    )},
    {Label = "Saturnite", Data = makeData(
        Vector3.new(1388.847, 14.858, 1931.079),
        CFrame.new(1398.133667, 21.941149, 1923.552612, -0.629673660, -0.328747690, 0.703872144, 0.000000000, 0.906047940, 0.423175126, -0.776859701, 0.266462237, -0.570514560),
        CFrame.new(1388.847412, 16.358183, 1931.079468, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193089,
        0.500,
        40.000
    )},
    {Label = "Uranite", Data = makeData(
        Vector3.new(1392.464, 15.014, 1863.205),
        CFrame.new(1383.630005, 20.926165, 1871.954346, 0.703717947, 0.237600029, -0.669572532, 0.000000000, 0.942423463, 0.334422082, 0.710479498, -0.235338822, 0.663200259),
        CFrame.new(1392.463745, 16.514122, 1863.204712, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193073,
        0.500,
        40.000
    )},
    {Label = "Neptunite", Data = makeData(
        Vector3.new(1325.698, 15.001, 1931.861),
        CFrame.new(1335.290161, 21.812218, 1939.198364, 0.607569277, -0.319782197, 0.727048099, 0.000000000, 0.915370226, 0.402613163, -0.794266641, -0.244615391, 0.556150854),
        CFrame.new(1325.698242, 16.500526, 1931.861084, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.192978,
        0.500,
        40.000
    )},
    {Label = "Plutite", Data = makeData(
        Vector3.new(1326.639, 15.021, 1862.472),
        CFrame.new(1334.038696, 19.762333, 1868.665894, 0.641903698, -0.244157791, 0.726874590, 0.000000000, 0.947950602, 0.318417430, -0.766785264, -0.204393327, 0.608493030),
        CFrame.new(1326.639282, 16.520918, 1862.471558, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179779,
        0.500,
        40.000
    )},
    {Label = "Sunite", Data = makeData(
        Vector3.new(1367.133, 14.919, 1911.106),
        CFrame.new(1374.885620, 18.384340, 1904.808228, -0.630487323, -0.149821639, 0.761603057, 0.000000000, 0.981194913, 0.193019480, -0.776199579, 0.121696338, -0.618630946),
        CFrame.new(1367.132690, 16.419447, 1911.105713, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179737,
        0.500,
        40.000
    )}
}
createGrid(FarmingSection, FarmingList, function(item)
    if item.Label == "Off" then
        setFarmingAutoShop(nil)
        teleportWithData(item.Data)
        return
    end
    teleportWithData(item.Data)
    setFarmingAutoShop(item.Label)
end)

-- [SECTION] Upgrade Teleports
local UpgradesSection = createSubSectionBox(TeleportSection, "Upgrades")
local UpgradeList = {
    {Label = "Planetify", Data = makeData(
        Vector3.new(1349.213, 14.000, 1841.135),
        CFrame.new(1348.220215, 18.136295, 1850.917480, 0.994891346, 0.026145127, -0.097507425, 0.000000000, 0.965881050, 0.258986235, 0.100951798, -0.257663161, 0.960946679),
        CFrame.new(1349.212769, 15.499880, 1841.135254, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179774,
        0.500,
        40.000
    )},
    {Label = "Cosmic", Data = makeData(
        Vector3.new(1342.559, 14.000, 1950.314),
        CFrame.new(1345.764282, 18.080660, 1941.003174, -0.945552766, -0.082516216, 0.314834923, 0.000000000, 0.967327535, 0.253530324, -0.325468808, 0.239726305, -0.914659202),
        CFrame.new(1342.559326, 15.499784, 1950.314209, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179786,
        0.500,
        40.000
    )},
    {Label = "Light Point", Data = makeData(
        Vector3.new(1580.509, 13.182, 2086.330),
        CFrame.new(1573.286621, 17.373627, 2079.680176, -0.677312553, 0.194543391, -0.709507287, 0.000000000, 0.964403629, 0.264434695, 0.735695422, 0.179104939, -0.653202653),
        CFrame.new(1580.509277, 14.681747, 2086.329590, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        10.179769,
        0.500,
        40.000
    )},
    {Label = "Rarities", Data = makeData(
        Vector3.new(1534.464, 13.743, 2123.736),
        CFrame.new(1536.074341, 21.832954, 2112.384033, -0.990087509, -0.069984615, 0.121773958, 0.000000000, 0.867015183, 0.498281628, -0.140451923, 0.493342429, -0.858420908),
        CFrame.new(1534.463867, 15.243335, 2123.736328, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224648,
        0.500,
        40.000
    )},
    {Label = "Milestones", Data = makeData(
        Vector3.new(1308.464, 14.000, 1896.676),
        CFrame.new(1321.018677, 19.640011, 1896.302368, -0.029771226, -0.312925488, 0.949310958, 0.000000000, 0.949731946, 0.313064277, -0.999556720, 0.009320308, -0.028274683),
        CFrame.new(1308.464355, 15.499832, 1896.676270, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224669,
        0.500,
        40.000
    )}
}
createGrid(UpgradesSection, UpgradeList, function(item)
    teleportWithData(item.Data)
    setFarmingAutoShop(nil)
end)

-- [SECTION] Rune Teleports
local RunesSection = createSubSectionBox(TeleportSection, "Runes")
local RuneList = {
    {Label = "Rune 1", Data = makeData(
        Vector3.new(1578.512, 8.243, 1908.216),
        CFrame.new(1574.903687, 19.520142, 1900.074707, -0.914211333, 0.299600005, -0.272868961, 0.000000000, 0.673355281, 0.739319086, 0.405237734, 0.675893903, -0.615589023),
        CFrame.new(1578.512329, 9.742876, 1908.215698, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224710,
        0.500,
        40.000
    )},
    {Label = "Rune 2", Data = makeData(
        Vector3.new(1489.634, 14.257, 2078.613),
        CFrame.new(1499.110962, 24.800543, 2080.426758, 0.187963307, -0.671668887, 0.716610610, 0.000000000, 0.729615211, 0.683857977, -0.982176006, -0.128540203, 0.137140900),
        CFrame.new(1489.634033, 15.756733, 2078.613037, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224684,
        0.500,
        40.000
    )},
    {Label = "Rune 3", Data = makeData(
        Vector3.new(1338.119, 14.581, 1889.744),
        CFrame.new(1327.494873, 23.738945, 1887.906616, -0.170450062, 0.570582867, -0.803356767, 0.000000000, 0.815287411, 0.579056561, 0.985366344, 0.098700225, -0.138965786),
        CFrame.new(1338.119019, 16.081100, 1889.744385, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224690,
        0.500,
        40.000
    )}
}
registerRuneLocations("Space World", RuneList)
createGrid(RunesSection, RuneList, function(item)
    teleportWithData(item.Data)
    setFarmingAutoShop(nil)
end)

end

initWorldTeleports()

local function initEventTabs()
State.Tabs.Heaven = createTab("Heaven World")
State.Tabs.Hell = createTab("Hell World")
createTabDivider()
State.Tabs.Event500K = createTab("500K Event")
State.Tabs.Halloween = createTab("Halloween")
State.Tabs.Thanksgiving = createTab("Thanksgiving")
State.Tabs.Event3M = createTab("3M Event")
State.Tabs.Christmas = createTab("Christmas Event")
State.Tabs.FiveM = createTab("5M Event")
State.Tabs.Valentine = createTab("Valentine Event")
local function getGraceRemote()
    local ok, remote = pcall(function()
        return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.MainRemote
    end)
    if ok and remote then
        return remote
    end
    return nil
end
State.InitValentine = function()
    local tab = State.Tabs.Valentine
    local ValentineTeleportSection = createSectionBox(tab:GetPage(), "Teleport")
    createButton(ValentineTeleportSection, "Home", function()
        fireWorldTeleport("Valentine Event")
    end)
    local ValentineList = {
        {Label = "Hearts Shop", Data = makeData(
            Vector3.new(-2040.686, 14.117, 4049.567),
            CFrame.new(-2027.499390, 23.525322, 4056.531738, 0.467003912, -0.414262772, 0.781213045, 0.000000000, 0.883470118, 0.468487740, -0.884255290, -0.218785614, 0.412583947),
            CFrame.new(-2040.686401, 15.617151, 4049.567139, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            16.880228,
            0.500,
            40.000
        )},
        {Label = "Love Shop", Data = makeData(
            Vector3.new(-1983.894, 14.117, 4005.831),
            CFrame.new(-1988.285400, 21.079636, 4021.187500, 0.961453974, 0.088979825, -0.260170966, 0.000000000, 0.946193039, 0.323602915, 0.274966091, -0.311129302, 0.909720957),
            CFrame.new(-1983.893677, 15.617151, 4005.831299, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            16.880133,
            0.500,
            40.000
        )},
        {Label = "Heart Rank", Data = makeData(
            Vector3.new(-1972.060, 14.617, 4091.901),
            CFrame.new(-1985.925537, 22.735849, 4084.908936, -0.450254291, 0.350105762, -0.821399450, 0.000000000, 0.919922829, 0.392099440, 0.892900407, 0.176544458, -0.414199203),
            CFrame.new(-1972.060181, 16.117128, 4091.900635, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            16.880148,
            0.500,
            40.000
        )},
        {Label = "Passive", Data = makeData(
            Vector3.new(-1990.651, 14.617, 4116.184),
            CFrame.new(-1990.299805, 25.575970, 4102.207520, -0.999684215, -0.014081959, 0.020813992, 0.000000000, 0.828248203, 0.560361385, -0.025130138, 0.560184419, -0.827986658),
            CFrame.new(-1990.651123, 16.116953, 4116.184082, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            16.880188,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(-1978.654, 15.275, 4041.959),
            CFrame.new(-1978.351685, 27.382614, 4055.086914, 0.999734581, -0.014476158, 0.017920133, 0.000000000, 0.777894437, 0.628395081, -0.023036715, -0.628228307, 0.777688026),
            CFrame.new(-1978.654175, 16.775175, 4041.959473, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            16.880135,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Valentine Event", ValentineList)
    createGrid(ValentineTeleportSection, ValentineList, function(item)
        teleportWithData(item.Data)
    end)

    local ValentineAutomationSection = createSectionBox(tab:GetPage(), "Automation")

    setupAutoShop(ValentineAutomationSection, {
        ToggleName = "Auto Buy Hearts Shop",
        DisplayName = "Auto Buy Hearts Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Hearts",
        Items = {
            "Infinite Hearts",
            "Hearts II",
            "Hearts III",
            "Love",
            "Valentine Bulk",
            "Valentine Shards Chance",
            "Valentine Luck",
            "Connor Balanced it Returns!",
            "Infinite Love"
        },
        CooldownKey = "ValentineHearts",
        DefaultCooldown = 0.6,
        StateIndexKey = "ValentineHeartsAutoIndex",
        StateOrderKey = "ValentineHeartsAutoOrder"
    })

    setupAutoShop(ValentineAutomationSection, {
        ToggleName = "Auto Buy Love Shop",
        DisplayName = "Auto Buy Love Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Love",
        Items = {
            "Hearts",
            "Love",
            "Clicks",
            "Clicker Tokens",
            "Fish Multiplier",
            "Light Points",
            "Madness",
            "Sins",
            "Sunite",
            "Rune Bulk",
            "Rune Luck"
        },
        CooldownKey = "ValentineLove",
        DefaultCooldown = 0.6,
        StateIndexKey = "ValentineLoveAutoIndex",
        StateOrderKey = "ValentineLoveAutoOrder"
    })
end

do
    local HellTeleportSection = createSectionBox(State.Tabs.Hell:GetPage(), "Teleport")
    createButton(HellTeleportSection, "Home", function()
        fireWorldTeleport("Hell World")
    end)
    createButton(HellTeleportSection, "Buy World", function()
        fireBuyArea("Hell World")
    end)
    local DropperSection = createSubSectionBox(HellTeleportSection, "Dropper")
    local DropperList = {
        {Label = "One", Data = makeData(
            Vector3.new(1534.491, 7.918, 3798.073),
            CFrame.new(1528.418823, 23.701048, 3806.732910, 0.818755865, 0.461416394, -0.341663152, 0.000000000, 0.595084965, 0.803662837, 0.574141741, -0.658003688, 0.487229377),
            CFrame.new(1534.491089, 9.417870, 3798.073486, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772654,
            0.500,
            40.000
        )},
        {Label = "Two", Data = makeData(
            Vector3.new(1547.148, 7.918, 3793.994),
            CFrame.new(1554.241821, 22.212158, 3804.086426, 0.818145394, -0.413929135, 0.399125129, 0.000000000, 0.694116831, 0.719862461, -0.575011432, -0.588952184, 0.567888498),
            CFrame.new(1547.148315, 9.418330, 3793.993652, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772562,
            0.500,
            40.000
        )},
        {Label = "Three", Data = makeData(
            Vector3.new(1553.044, 7.918, 3782.647),
            CFrame.new(1564.829102, 22.689465, 3783.574463, 0.078451701, -0.744417369, 0.663089871, 0.000000000, 0.665139854, 0.746718824, -0.996917903, -0.058581360, 0.052181356),
            CFrame.new(1553.044312, 9.418330, 3782.646973, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772577,
            0.500,
            40.000
        )},
        {Label = "Four", Data = makeData(
            Vector3.new(1554.268, 7.932, 3771.766),
            CFrame.new(1565.648926, 22.636124, 3768.303711, -0.291043341, -0.710790098, 0.640368044, 0.000000000, 0.669344008, 0.742952645, -0.956709802, 0.216231421, -0.194808140),
            CFrame.new(1554.267944, 9.431924, 3771.765869, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772568,
            0.500,
            40.000
        )},
        {Label = "Five", Data = makeData(
            Vector3.new(1547.536, 7.918, 3762.687),
            CFrame.new(1554.781128, 22.689468, 3753.346191, -0.790159523, -0.457664937, 0.407664895, 0.000000000, 0.665139675, 0.746719003, -0.612901151, 0.590027153, -0.525566459),
            CFrame.new(1547.535889, 9.418330, 3762.686768, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772533,
            0.500,
            40.000
        )},
        {Label = "Six", Data = makeData(
            Vector3.new(1535.116, 7.918, 3758.026),
            CFrame.new(1535.961670, 23.760986, 3747.564697, -0.996751368, -0.064996175, 0.047561705, 0.000000000, 0.590538502, 0.807009518, -0.080539539, 0.804387867, -0.588620126),
            CFrame.new(1535.116333, 9.418330, 3758.026123, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772671,
            0.500,
            40.000
        )},
        {Label = "Seven", Data = makeData(
            Vector3.new(1522.323, 7.918, 3761.808),
            CFrame.new(1517.094971, 24.597157, 3754.183350, -0.824714720, 0.483011454, -0.294186234, 0.000000000, 0.520178199, 0.854057729, 0.565548956, 0.704353988, -0.428998619),
            CFrame.new(1522.323364, 9.418330, 3761.807861, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772621,
            0.500,
            40.000
        )},
        {Label = "Eight", Data = makeData(
            Vector3.new(1512.525, 7.851, 3771.357),
            CFrame.new(1503.687500, 24.370922, 3767.868896, -0.367143840, 0.786107242, -0.497233063, 0.000000000, 0.534564853, 0.845127404, 0.930164158, 0.310283333, -0.196262181),
            CFrame.new(1512.524658, 9.350810, 3771.356934, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772606,
            0.500,
            40.000
        )},
        {Label = "Nine", Data = makeData(
            Vector3.new(1514.179, 7.918, 3782.525),
            CFrame.new(1506.086426, 25.188061, 3783.824463, 0.158509895, 0.876087785, -0.455351174, 0.000000000, 0.461181700, 0.887305737, 0.987357318, -0.140646741, 0.073101871),
            CFrame.new(1514.179199, 9.418330, 3782.525146, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772608,
            0.500,
            40.000
        )},
        {Label = "Ten", Data = makeData(
            Vector3.new(1521.391, 7.618, 3794.951),
            CFrame.new(1515.554932, 22.781784, 3804.703369, 0.858068466, 0.394812584, -0.328392297, 0.000000000, 0.639473677, 0.768813014, 0.513535261, -0.659694195, 0.548712194),
            CFrame.new(1521.391357, 9.117979, 3794.951416, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            17.772564,
            0.500,
            40.000
        )}
    }
    State.HellTeleports = State.HellTeleports or {}
    State.HellTeleports.Dropper = State.HellTeleports.Dropper or {}
    for _, item in ipairs(DropperList) do
        State.HellTeleports.Dropper[item.Label] = item.Data
    end
    createGrid(DropperSection, DropperList, function(item)
        teleportWithData(item.Data)
    end)

    local HellList = {
        {Label = "Madness Shop", Data = makeData(
            Vector3.new(1473.467, 8.418, 3875.737),
            CFrame.new(1481.869141, 21.914501, 3862.857178, -0.837532520, -0.336074769, 0.430805087, 0.000000000, 0.788460791, 0.615085125, -0.546387434, 0.515153766, -0.660361588),
            CFrame.new(1473.466675, 9.917869, 3875.736816, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503992,
            0.500,
            40.000
        )},
        {Label = "Hell Rank", Data = makeData(
            Vector3.new(1453.755, 6.917, 3839.862),
            CFrame.new(1469.700073, 13.144405, 3850.050781, 0.538469136, -0.204231873, 0.817520916, 0.000000000, 0.970183969, 0.242369920, -0.842645288, -0.130508721, 0.522414088),
            CFrame.new(1453.755127, 8.417223, 3839.861572, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504040,
            0.500,
            40.000
        )},
        {Label = "Sins Shop", Data = makeData(
            Vector3.new(1624.898, 7.417, 3854.722),
            CFrame.new(1606.193726, 18.282265, 3841.251465, -0.584383786, 0.305446982, -0.751796305, 0.000000000, 0.926453710, 0.376408517, 0.811477304, 0.219967037, -0.541404605),
            CFrame.new(1624.898438, 8.917222, 3854.721680, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880051,
            0.500,
            40.000
        )},
        {Label = "Ember Tree 1", Data = makeData(
            Vector3.new(1532.551, 6.917, 3875.136),
            CFrame.new(1532.652832, 47.809532, 3868.190430, -0.999892652, -0.014428793, 0.002544191, 0.000000000, 0.173648581, 0.984807730, -0.014651380, 0.984701991, -0.173629940),
            CFrame.new(1532.551025, 8.417223, 3875.135742, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000023,
            0.500,
            40.000
        )},
        {Label = "Ember Tree 2", Data = makeData(
            Vector3.new(1532.130, 6.917, 3903.638),
            CFrame.new(1532.231689, 47.809532, 3896.693115, -0.999892652, -0.014428793, 0.002544191, 0.000000000, 0.173648581, 0.984807730, -0.014651380, 0.984701991, -0.173629940),
            CFrame.new(1532.129883, 8.417223, 3903.638428, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000023,
            0.500,
            40.000
        )},
        {Label = "Curses Roll", Data = makeData(
            Vector3.new(1590.580, 7.417, 3871.864),
            CFrame.new(1602.701782, 39.813530, 3849.537598, -0.878821611, -0.368554652, 0.303051174, 0.000000000, 0.635127068, 0.772407651, -0.477150440, 0.678808510, -0.558163404),
            CFrame.new(1590.579712, 8.917223, 3871.864014, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            39.999939,
            0.500,
            40.000
        )},
        {Label = "Hell XP Shop", Data = makeData(
            Vector3.new(1558.933, 7.217, 3829.225),
            CFrame.new(1545.091797, 14.504358, 3816.761719, -0.669123828, 0.220504314, -0.709683895, 0.000000000, 0.954966068, 0.296715349, 0.743151009, 0.198539317, -0.638990462),
            CFrame.new(1558.933472, 8.717222, 3829.224609, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504013,
            0.500,
            40.000
        )},
        {Label = "Ember Milestone", Data = makeData(
            Vector3.new(1512.262, 7.017, 3813.122),
            CFrame.new(1530.427124, 12.061178, 3819.277344, 0.320935100, -0.172092095, 0.931335032, 0.000000000, 0.983353257, 0.181704029, -0.947101176, -0.058315203, 0.315592587),
            CFrame.new(1512.262329, 8.517222, 3813.122070, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504021,
            0.500,
            40.000
        )},
        {Label = "Milestone", Data = makeData(
            Vector3.new(1477.510, 7.417, 3821.921),
            CFrame.new(1482.308716, 17.365757, 3838.832275, 0.962025285, -0.118238114, 0.246022791, 0.000000000, 0.901312768, 0.433169246, -0.272960544, -0.416719764, 0.867085576),
            CFrame.new(1477.510254, 8.917223, 3821.920654, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503996,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(1521.693, 8.031, 3858.946),
            CFrame.new(1505.974731, 17.580893, 3850.665771, -0.466070175, 0.365145415, -0.805882990, 0.000000000, 0.910861850, 0.412711322, 0.884747744, 0.192352444, -0.424525559),
            CFrame.new(1521.692627, 9.531371, 3858.945801, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503998,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Hell World", HellList)
    State.HellTeleports = State.HellTeleports or {}
    for _, item in ipairs(HellList) do
        if item.Label == "Madness Shop" then
            State.HellTeleports.Madness = item.Data
            break
        end
    end
    createGrid(HellTeleportSection, HellList, function(item)
        teleportWithData(item.Data)
    end)
end

State.InitHell = function()
    local tab = State.Tabs.Hell
    local HellAutomationSection = createSectionBox(tab:GetPage(), "Automation")

    setupAutoShop(HellAutomationSection, {
        ToggleName = "Auto Buy Madness Shop",
        DisplayName = "Auto Buy Madness Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Madness",
        Items = {
            "Madness Multiplier",
            "Madness Multiplier II",
            "Ember Multiplier",
            "Hell XP Multiplier",
            "Sins Multiplier",
            "Madness Press Speed",
            "Connor Madnessly Balanced It"
        },
        CooldownKey = "HellMadness",
        DefaultCooldown = 0.6,
        StateIndexKey = "HellMadnessAutoIndex",
        StateOrderKey = "HellMadnessAutoOrder"
    })

    setupAutoShop(HellAutomationSection, {
        ToggleName = "Auto Buy Hell XP Shop",
        DisplayName = "Auto Buy Hell XP Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Hell XP",
        Items = {
            "Hell XP Multiplier",
            "Madness Multiplier",
            "Ember Multiplier",
            "Sins Multiplier"
        },
        CooldownKey = "HellXP",
        DefaultCooldown = 0.6,
        StateIndexKey = "HellXPAutoIndex",
        StateOrderKey = "HellXPAutoOrder"
    })

    setupAutoShop(HellAutomationSection, {
        ToggleName = "Auto Buy Sins Shop",
        DisplayName = "Auto Buy Sins Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Sins",
        Items = {
            "Madness Multiplier",
            "Ember Multiplier",
            "Sins Multiplier",
            "Hell XP Multiplier"
        },
        CooldownKey = "Sins",
        DefaultCooldown = 0.6,
        StateIndexKey = "SinsAutoIndex",
        StateOrderKey = "SinsAutoOrder"
    })

    local FullAutomationSection = createSectionBox(tab:GetPage(), "Full Automation")
    local StarterAutomationSection = createSubSectionBox(FullAutomationSection, "Starter Automation")

    local StarterShops = {
        {
            Key = "Madness",
            Title = "Madness Shop",
            ShopName = "Madness",
            Items = {
                "Madness Multiplier",
                "Madness Multiplier II",
                "Ember Multiplier",
                "Hell XP Multiplier",
                "Sins Multiplier",
                "Madness Press Speed",
                "Connor Madnessly Balanced It"
            }
        },
        {
            Key = "HellXP",
            Title = "Hell XP Shop",
            ShopName = "Hell XP",
            Items = {
                "Hell XP Multiplier",
                "Madness Multiplier",
                "Ember Multiplier",
                "Sins Multiplier"
            }
        },
        {
            Key = "Sins",
            Title = "Sins Shop",
            ShopName = "Sins",
            Items = {
                "Madness Multiplier",
                "Ember Multiplier",
                "Sins Multiplier",
                "Hell XP Multiplier"
            }
        }
    }

    local DropperRank = {
        One = 1,
        Two = 2,
        Three = 3,
        Four = 4,
        Five = 5,
        Six = 6,
        Seven = 7,
        Eight = 8,
        Nine = 9,
        Ten = 10
    }

    local DropperOrder = {}
    for name in pairs(DropperRank) do
        DropperOrder[#DropperOrder + 1] = name
    end
    table.sort(DropperOrder, function(a, b)
        return (DropperRank[a] or 0) > (DropperRank[b] or 0)
    end)

    local function ensureStarterConfig()
        if Config.HellStarterEnabled == nil then Config.HellStarterEnabled = false end
        if Config.HellStarterUseUpgradeAll == nil then Config.HellStarterUseUpgradeAll = true end
        if Config.HellStarterSkipMaxed == nil then Config.HellStarterSkipMaxed = true end
        if Config.HellStarterClickSpeed == nil then Config.HellStarterClickSpeed = 0.6 end
        if Config.HellStarterTeleportEnabled == nil then Config.HellStarterTeleportEnabled = false end
        if Config.HellStarterTeleportHold == nil then Config.HellStarterTeleportHold = 15 end
        if Config.HellStarterTeleportStep == nil then Config.HellStarterTeleportStep = 3 end

        if type(Config.HellStarterItems) ~= "table" then
            Config.HellStarterItems = {}
        end
        for _, shop in ipairs(StarterShops) do
            if type(Config.HellStarterItems[shop.Key]) ~= "table" then
                Config.HellStarterItems[shop.Key] = {}
            end
            for _, item in ipairs(shop.Items) do
                if Config.HellStarterItems[shop.Key][item] == nil then
                    Config.HellStarterItems[shop.Key][item] = true
                end
            end
        end

        if type(Config.HellStarterDroppers) ~= "table" then
            Config.HellStarterDroppers = {}
        end
        for _, name in ipairs(DropperOrder) do
            if Config.HellStarterDroppers[name] == nil then
                Config.HellStarterDroppers[name] = (name == "One")
            end
        end
    end

    ensureStarterConfig()
    saveConfig()

    local function setControlsEnabled(controls, enabled)
        for _, ctrl in ipairs(controls) do
            if ctrl and ctrl.SetEnabled then
                ctrl:SetEnabled(enabled)
            end
        end
    end

    local function createListDropdownRow(parent, labelText, onToggle)
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 0, 30)
        frame.BorderSizePixel = 0
        frame.Parent = parent
        registerTheme(frame, "BackgroundColor3", "Main")
        addCorner(frame, 6)
        addStroke(frame, "Muted", 1, 0.8)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -50, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = labelText
        label.Parent = frame
        registerTheme(label, "TextColor3", "Text")

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 30, 0, 20)
        btn.Position = UDim2.new(1, -35, 0.5, -10)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.AutoButtonColor = false
        btn.Parent = frame
        registerTheme(btn, "BackgroundColor3", "Panel")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)

        local enabled = true
        local expanded = false

        local function setExpanded(state)
            expanded = state and true or false
            btn.Text = expanded and "v" or ">"
        end

        btn.MouseButton1Click:Connect(function()
            if not enabled then
                return
            end
            setExpanded(not expanded)
            if onToggle then
                onToggle(expanded)
            end
        end)

        setExpanded(false)

        return {
            SetEnabled = function(_, value)
                enabled = value and true or false
                label.TextTransparency = enabled and 0 or 0.4
                btn.TextTransparency = enabled and 0 or 0.4
            end,
            SetExpanded = function(_, value)
                setExpanded(value)
            end,
            Frame = frame
        }
    end

    local function addListHeader(parent, text)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 0, 18)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamSemibold
        label.TextSize = 12
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = text
        label.Parent = parent
        registerTheme(label, "TextColor3", "Text")
        return label
    end

    local function addListDivider(parent)
        local div = Instance.new("Frame")
        div.Size = UDim2.new(1, 0, 0, 1)
        div.BorderSizePixel = 0
        div.Parent = parent
        registerTheme(div, "BackgroundColor3", "Muted")
        return div
    end

    local itemEnabled = Config.HellStarterItems
    local dropperEnabled = Config.HellStarterDroppers

    local starterEnabled = Config.HellStarterEnabled == true
    local useUpgradeAll = Config.HellStarterUseUpgradeAll == true
    local skipMaxedEnabled = Config.HellStarterSkipMaxed == true
    local teleportEnabled = Config.HellStarterTeleportEnabled == true
    local autoBuyConn = nil
    local promptConn = nil
    local maxed = {}
    local lastClick = 0
    local accum = 0
    local interval = 0.25
    local teleportToken = 0

    State.HellStarterShopIndex = 1
    State.HellStarterItemIndex = State.HellStarterItemIndex or {}

    setGlobalClickCooldown("HellStarterAuto", Config.HellStarterClickSpeed)

    local function attachPromptListener()
        if promptConn then
            return
        end
        local ok, remote = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
        end)
        if not ok or not remote or not remote:IsA("RemoteEvent") then
            return
        end
        promptConn = remote.OnClientEvent:Connect(function(_, msg)
            if not starterEnabled then
                return
            end
            if type(msg) ~= "string" then
                return
            end
            local lower = string.lower(msg)
            if not string.find(lower, "already reached max upgrade", 1, true) then
                return
            end
            for _, shop in ipairs(StarterShops) do
                for _, item in ipairs(shop.Items) do
                    if string.find(lower, string.lower(item), 1, true) then
                        maxed[shop.Key] = maxed[shop.Key] or {}
                        maxed[shop.Key][item] = true
                    end
                end
            end
        end)
        trackConnection(promptConn)
    end

    local function detachPromptListener()
        if promptConn then
            promptConn:Disconnect()
            promptConn = nil
        end
    end

    local function getNextStarterItem()
        local totalShops = #StarterShops
        for _ = 1, totalShops do
            local shop = StarterShops[State.HellStarterShopIndex]
            State.HellStarterShopIndex += 1
            if State.HellStarterShopIndex > totalShops then
                State.HellStarterShopIndex = 1
            end

            local items = shop.Items
            local idx = State.HellStarterItemIndex[shop.Key] or 1
            for _ = 1, #items do
                local name = items[idx]
                idx += 1
                if idx > #items then
                    idx = 1
                end
                local enabled = itemEnabled[shop.Key] and itemEnabled[shop.Key][name]
                local isMaxed = maxed[shop.Key] and maxed[shop.Key][name]
                if enabled and (not skipMaxedEnabled or not isMaxed) then
                    State.HellStarterItemIndex[shop.Key] = idx
                    return shop.ShopName, name
                end
            end
            State.HellStarterItemIndex[shop.Key] = idx
        end
        return nil
    end

    local function startAutoBuy()
        if autoBuyConn then
            autoBuyConn:Disconnect()
            autoBuyConn = nil
        end
        accum = 0
        lastClick = 0
        maxed = {}
        State.HellStarterShopIndex = 1
        for _, shop in ipairs(StarterShops) do
            State.HellStarterItemIndex[shop.Key] = 1
        end
        attachPromptListener()
        autoBuyConn = RunService.Heartbeat:Connect(function(dt)
            if not starterEnabled then
                return
            end
            accum += dt
            if accum < interval then
                return
            end
            accum = 0
            local remote = getMainRemote and getMainRemote() or nil
            if not remote then
                return
            end
            local now = os.clock()
            if now - lastClick < getGlobalClickCooldown("HellStarterAuto") then
                return
            end
            local shopName, itemName = getNextStarterItem()
            if not shopName or not itemName then
                return
            end
            local action = useUpgradeAll and "UpgradeAll" or "Upgrade"
            pcall(function()
                remote:FireServer(action, shopName, itemName)
            end)
            lastClick = now
        end)
        trackConnection(autoBuyConn)
    end

    local function stopAutoBuy()
        if autoBuyConn then
            autoBuyConn:Disconnect()
            autoBuyConn = nil
        end
        detachPromptListener()
    end

    local function stopTeleportLoop()
        teleportToken += 1
    end

    local function startTeleportLoop()
        stopTeleportLoop()
        teleportToken += 1
        local token = teleportToken
        task.spawn(function()
            while token == teleportToken and starterEnabled and teleportEnabled do
                local madnessData = State.HellTeleports and State.HellTeleports.Madness or nil
                if madnessData then
                    teleportWithData(madnessData)
                end
                local holdSeconds = math.clamp(tonumber(Config.HellStarterTeleportHold) or 15, 15, 900)
                local startHold = os.clock()
                while token == teleportToken and starterEnabled and teleportEnabled and (os.clock() - startHold) < holdSeconds do
                    task.wait(0.1)
                end
                if token ~= teleportToken or not starterEnabled or not teleportEnabled then
                    break
                end
                local stepSeconds = math.clamp(tonumber(Config.HellStarterTeleportStep) or 3, 1, 10)
                for _, name in ipairs(DropperOrder) do
                    if token ~= teleportToken or not starterEnabled or not teleportEnabled then
                        break
                    end
                    if dropperEnabled[name] then
                        local data = State.HellTeleports and State.HellTeleports.Dropper and State.HellTeleports.Dropper[name] or nil
                        if data then
                            teleportWithData(data)
                        end
                        local startStep = os.clock()
                        while token == teleportToken and starterEnabled and teleportEnabled and (os.clock() - startStep) < stepSeconds do
                            task.wait(0.1)
                        end
                    end
                end
            end
        end)
    end

    local function applyStarterEnabled()
        starterEnabled = Config.HellStarterEnabled == true
        useUpgradeAll = Config.HellStarterUseUpgradeAll == true
        skipMaxedEnabled = Config.HellStarterSkipMaxed == true
        teleportEnabled = Config.HellStarterTeleportEnabled == true
        if starterEnabled then
            startAutoBuy()
        else
            stopAutoBuy()
        end
        if starterEnabled and teleportEnabled then
            startTeleportLoop()
        else
            stopTeleportLoop()
        end
    end

    local StarterControls = {}
    local function addStarterControl(ctrl)
        StarterControls[#StarterControls + 1] = ctrl
        return ctrl
    end

    local StarterEnabledToggle = createToggle(StarterAutomationSection, "On/Off", "HellStarterEnabled", Config.HellStarterEnabled, function(v)
        setControlsEnabled(StarterControls, v)
        applyStarterEnabled()
    end)

    local StarterModeToggle = addStarterControl(createToggle(StarterAutomationSection, "Mode: Upgrade All", "HellStarterUseUpgradeAll", Config.HellStarterUseUpgradeAll, function(v)
        useUpgradeAll = v
    end))

    local StarterClickSlider = addStarterControl(createSlider(StarterAutomationSection, "Click Speed (sec)", "HellStarterClickSpeed", 0.1, 5, Config.HellStarterClickSpeed, function(v)
        setGlobalClickCooldown("HellStarterAuto", v)
    end, 1))

    local StarterSkipToggle = addStarterControl(createToggle(StarterAutomationSection, "Skip Maxed Items", "HellStarterSkipMaxed", Config.HellStarterSkipMaxed, function(v)
        skipMaxedEnabled = v
    end))

    local itemListContainer
    addStarterControl(createListDropdownRow(StarterAutomationSection, "Item List", function(open)
        if itemListContainer then
            itemListContainer.Visible = open
        end
    end))

    local itemListContent = createSubSectionBox(StarterAutomationSection, "Item List")
    itemListContainer = itemListContent.Parent
    itemListContainer.Visible = false

    local ItemToggleRefs = {}
    for i, shop in ipairs(StarterShops) do
        addListHeader(itemListContent, shop.Title)
        for _, item in ipairs(shop.Items) do
            local ctrl = createToggle(itemListContent, item, nil, itemEnabled[shop.Key][item], function(v)
                itemEnabled[shop.Key][item] = v
                Config.HellStarterItems[shop.Key][item] = v
                saveConfig()
            end)
            ItemToggleRefs[shop.Key] = ItemToggleRefs[shop.Key] or {}
            ItemToggleRefs[shop.Key][item] = ctrl
            addStarterControl(ctrl)
        end
        if i < #StarterShops then
            addListDivider(itemListContent)
        end
    end

    local TeleportBox = createSubSectionBox(StarterAutomationSection, "Auto Teleport")
    local StarterTeleportToggle = addStarterControl(createToggle(TeleportBox, "Enable Auto Teleport", "HellStarterTeleportEnabled", Config.HellStarterTeleportEnabled, function(v)
        teleportEnabled = v
        if starterEnabled and teleportEnabled then
            startTeleportLoop()
        else
            stopTeleportLoop()
        end
    end))

    local StarterHoldSlider = addStarterControl(createSlider(TeleportBox, "Madness Hold (sec)", "HellStarterTeleportHold", 15, 900, Config.HellStarterTeleportHold, nil, 0))

    local StarterStepSlider = addStarterControl(createSlider(TeleportBox, "Dropper Step (sec)", "HellStarterTeleportStep", 1, 10, Config.HellStarterTeleportStep, nil, 1))

    local dropperListContainer
    addStarterControl(createListDropdownRow(TeleportBox, "Dropper List", function(open)
        if dropperListContainer then
            dropperListContainer.Visible = open
        end
    end))

    local dropperListContent = createSubSectionBox(TeleportBox, "Dropper List")
    dropperListContainer = dropperListContent.Parent
    dropperListContainer.Visible = false

    local DropperToggleRefs = {}
    for _, name in ipairs(DropperOrder) do
        local ctrl = createToggle(dropperListContent, "Dropper " .. name, nil, dropperEnabled[name], function(v)
            dropperEnabled[name] = v
            Config.HellStarterDroppers[name] = v
            saveConfig()
        end)
        DropperToggleRefs[name] = ctrl
        addStarterControl(ctrl)
    end

    createButton(StarterAutomationSection, "Reset Starter Automation", function()
        local defaults = {
            Enabled = false,
            UseUpgradeAll = true,
            SkipMaxed = true,
            ClickSpeed = 0.6,
            TeleportEnabled = false,
            TeleportHold = 15,
            TeleportStep = 3
        }

        Config.HellStarterEnabled = defaults.Enabled
        Config.HellStarterUseUpgradeAll = defaults.UseUpgradeAll
        Config.HellStarterSkipMaxed = defaults.SkipMaxed
        Config.HellStarterClickSpeed = defaults.ClickSpeed
        Config.HellStarterTeleportEnabled = defaults.TeleportEnabled
        Config.HellStarterTeleportHold = defaults.TeleportHold
        Config.HellStarterTeleportStep = defaults.TeleportStep

        if StarterModeToggle and StarterModeToggle.Set then
            StarterModeToggle:Set(defaults.UseUpgradeAll)
        end
        if StarterSkipToggle and StarterSkipToggle.Set then
            StarterSkipToggle:Set(defaults.SkipMaxed)
        end
        if StarterClickSlider and StarterClickSlider.Set then
            StarterClickSlider:Set(defaults.ClickSpeed)
        end
        if StarterTeleportToggle and StarterTeleportToggle.Set then
            StarterTeleportToggle:Set(defaults.TeleportEnabled)
        end
        if StarterHoldSlider and StarterHoldSlider.Set then
            StarterHoldSlider:Set(defaults.TeleportHold)
        end
        if StarterStepSlider and StarterStepSlider.Set then
            StarterStepSlider:Set(defaults.TeleportStep)
        end

        for _, shop in ipairs(StarterShops) do
            for _, item in ipairs(shop.Items) do
                itemEnabled[shop.Key][item] = true
                Config.HellStarterItems[shop.Key][item] = true
                if ItemToggleRefs[shop.Key] and ItemToggleRefs[shop.Key][item] then
                    ItemToggleRefs[shop.Key][item]:Set(true)
                end
            end
        end

        for _, name in ipairs(DropperOrder) do
            local val = (name == "One")
            dropperEnabled[name] = val
            Config.HellStarterDroppers[name] = val
            if DropperToggleRefs[name] then
                DropperToggleRefs[name]:Set(val)
            end
        end

        if StarterEnabledToggle and StarterEnabledToggle.Set then
            StarterEnabledToggle:Set(defaults.Enabled)
        end
        setGlobalClickCooldown("HellStarterAuto", defaults.ClickSpeed)
        saveConfig()
        setControlsEnabled(StarterControls, defaults.Enabled)
        applyStarterEnabled()
    end)

    setControlsEnabled(StarterControls, starterEnabled)
    applyStarterEnabled()
end

do
    local Event500KTeleportSection = createSectionBox(State.Tabs.Event500K:GetPage(), "Teleport")
    createButton(Event500KTeleportSection, "Home", function()
        teleportHomeWithBuy("500K Event")
    end)
    local Event500KList = {
        {Label = "Ascend", Data = makeData(
            Vector3.new(-2295.990, 25.150, -54.778),
            CFrame.new(-2290.416016, 35.197639, -71.399429, -0.948105156, -0.139349654, 0.285794318, 0.000000000, 0.898845613, 0.438265592, -0.317957103, 0.415521860, -0.852200091),
            CFrame.new(-2295.990234, 26.649710, -54.778114, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504028,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(-2276.094, 26.249, -80.425),
            CFrame.new(-2287.787842, 42.744099, -84.760132, -0.347580701, 0.720886588, -0.599591732, 0.000000000, 0.639462113, 0.768822670, 0.937650025, 0.267227918, -0.222264707),
            CFrame.new(-2276.093506, 27.748981, -80.425079, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503941,
            0.500,
            40.000
        )},
        {Label = "Tree 1", Data = makeData(
            Vector3.new(-2235.672, 26.086, -189.510),
            CFrame.new(-2242.218262, 64.155159, -174.681534, 0.914822817, 0.369211853, -0.163651317, 0.000000000, 0.405222595, 0.914218068, 0.403855354, -0.836347520, 0.370706886),
            CFrame.new(-2235.672119, 27.586439, -189.509811, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000011,
            0.500,
            40.000
        )},
        {Label = "Tree 2", Data = makeData(
            Vector3.new(-2198.955, 25.151, -217.756),
            CFrame.new(-2201.445801, 65.785721, -209.863708, 0.953615010, 0.294515729, -0.062281270, 0.000000000, 0.206894591, 0.978363335, 0.301028997, -0.932981968, 0.197297782),
            CFrame.new(-2198.954590, 26.651192, -217.755615, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            39.999996,
            0.500,
            40.000
        )},
        {Label = "Tree 3", Data = makeData(
            Vector3.new(-2247.844, 25.151, -232.860),
            CFrame.new(-2249.394043, 66.043503, -226.089645, 0.974763453, 0.219848618, -0.038765401, 0.000000000, 0.173648879, 0.984807730, 0.223240137, -0.959954560, 0.169266582),
            CFrame.new(-2247.843506, 26.651192, -232.860306, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000000,
            0.500,
            40.000
        )},
        {Label = "Tree 4", Data = makeData(
            Vector3.new(-2221.199, 25.987, -253.984),
            CFrame.new(-2223.045654, 66.879623, -247.288223, 0.964005291, 0.261843741, -0.046170160, 0.000000000, 0.173648342, 0.984807730, 0.265883118, -0.949359834, 0.167397916),
            CFrame.new(-2221.198730, 27.487316, -253.984146, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000004,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("500K Event", Event500KList)
    createGrid(Event500KTeleportSection, Event500KList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local HalloweenTeleportSection = createSectionBox(State.Tabs.Halloween:GetPage(), "Teleport")
    createButton(HalloweenTeleportSection, "Home", function()
        teleportHomeWithBuy("Halloween")
    end)
    local HalloweenList = {
        {Label = "Flesh Shop", Data = makeData(
            Vector3.new(-2285.308, 19.919, -2138.265),
            CFrame.new(-2285.977295, 31.302032, -2161.088379, -0.999569833, 0.011649705, -0.026914433, 0.000000000, 0.917720020, 0.397228032, 0.029327499, 0.397057146, -0.917325258),
            CFrame.new(-2285.307617, 21.418999, -2138.265381, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.879951,
            0.500,
            40.000
        )},
        {Label = "Fleshify", Data = makeData(
            Vector3.new(-2214.776, 19.919, -2157.964),
            CFrame.new(-2232.713135, 32.622929, -2149.059326, 0.444644213, 0.437339455, -0.781681359, 0.000000000, 0.872697353, 0.488261580, 0.895707309, -0.217102692, 0.388039798),
            CFrame.new(-2214.775879, 21.418791, -2157.963623, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.946989,
            0.500,
            40.000
        )},
        {Label = "Sword Crafting", Data = makeData(
            Vector3.new(-2159.469, 19.924, -2234.667),
            CFrame.new(-2162.267822, 31.480072, -2214.232178, 0.990749240, 0.059472892, -0.121979445, 0.000000000, 0.898853481, 0.438249350, 0.135705605, -0.434195220, 0.890538335),
            CFrame.new(-2159.468750, 21.423563, -2234.667480, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947107,
            0.500,
            40.000
        )},
        {Label = "Sword enchants", Data = makeData(
            Vector3.new(-2139.681, 19.919, -2192.644),
            CFrame.new(-2155.138184, 31.591566, -2206.213623, -0.659731865, 0.333152533, -0.673619509, 0.000000000, 0.896365285, 0.443316102, 0.751501083, 0.292469770, -0.591360748),
            CFrame.new(-2139.680664, 21.418791, -2192.643555, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947048,
            0.500,
            40.000
        )},
        {Label = "Candy Corn", Data = makeData(
            Vector3.new(-1977.522, 23.558, -2207.680),
            CFrame.new(-1975.137573, 46.906532, -2174.258789, 0.997464955, -0.038867608, 0.059606303, 0.000000000, 0.837649584, 0.546207964, -0.071158990, -0.544823289, 0.835526168),
            CFrame.new(-1977.521851, 25.058212, -2207.679932, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000084,
            0.500,
            40.000
        )},
        {Label = "Refined Candy Corn", Data = makeData(
            Vector3.new(-1951.021, 24.559, -2084.695),
            CFrame.new(-1941.997803, 31.781582, -2095.510010, -0.767842770, -0.241146296, 0.593519986, 0.000000000, 0.926450908, 0.376415670, -0.640638292, 0.289028049, -0.711368680),
            CFrame.new(-1951.021240, 26.058859, -2084.694824, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203297,
            0.500,
            40.000
        )},
        {Label = "Refined Candy Corn Upgrade", Data = makeData(
            Vector3.new(-1930.651, 23.358, -2101.947),
            CFrame.new(-1939.576660, 29.775299, -2111.004150, -0.712264240, 0.253161699, -0.654667020, 0.000000000, 0.932691813, 0.360674679, 0.701911449, 0.256895661, -0.664322972),
            CFrame.new(-1930.651489, 24.858192, -2101.947266, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633186,
            0.500,
            40.000
        )},
        {Label = "Mutation Roller", Data = makeData(
            Vector3.new(-1889.595, 24.002, -2126.313),
            CFrame.new(-1887.338867, 36.152672, -2148.684326, -0.994952023, -0.042958423, 0.090692058, 0.000000000, 0.903741598, 0.428078443, -0.100351758, 0.425917506, -0.899179518),
            CFrame.new(-1889.595337, 25.502079, -2126.312744, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880001,
            0.500,
            40.000
        )},
        {Label = "Trick or Treat", Data = makeData(
            Vector3.new(-1858.588, 24.202, -2152.789),
            CFrame.new(-1880.230103, 36.479126, -2158.660645, -0.261842459, 0.418060958, -0.869864047, 0.000000000, 0.901310205, 0.433174133, 0.965110600, 0.113423377, -0.236001298),
            CFrame.new(-1858.587891, 25.701752, -2152.788818, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880020,
            0.500,
            40.000
        )},
        {Label = "Candy Corn Tree", Data = makeData(
            Vector3.new(-1888.203, 23.058, -2196.563),
            CFrame.new(-1897.413696, 38.960514, -2178.486572, 0.891011178, 0.262796462, -0.370185196, 0.000000000, 0.815419376, 0.578870654, 0.453981310, -0.515780210, 0.726547837),
            CFrame.new(-1888.203491, 24.558212, -2196.562988, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.879930,
            0.500,
            40.000
        )},
        {Label = "Soul Shop", Data = makeData(
            Vector3.new(-1879.392, 26.558, -2344.654),
            CFrame.new(-1876.126343, 36.922359, -2314.498535, 0.994187653, -0.030200295, 0.103339195, 0.000000000, 0.959850967, 0.280510992, -0.107661717, -0.278880566, 0.954271853),
            CFrame.new(-1879.391846, 28.058212, -2344.653564, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600039,
            0.500,
            40.000
        )},
        {Label = "Soul Tree", Data = makeData(
            Vector3.new(-1837.486, 26.558, -2334.889),
            CFrame.new(-1864.238037, 44.867821, -2334.328857, 0.020951884, 0.531832874, -0.846590102, 0.000000000, 0.846775889, 0.531949699, 0.999780416, -0.011145349, 0.017741553),
            CFrame.new(-1837.485840, 28.058212, -2334.889404, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.599955,
            0.500,
            40.000
        )},
        {Label = "Rune 1", Data = makeData(
            Vector3.new(-2278.916, 20.627, -2164.964),
            CFrame.new(-2297.861572, 33.444126, -2158.675781, 0.314996094, 0.468070805, -0.825643539, 0.000000000, 0.869929075, 0.493176967, 0.949092984, -0.155348822, 0.274024248),
            CFrame.new(-2278.915527, 22.127195, -2164.963867, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947016,
            0.500,
            40.000
        )},
        {Label = "Rune 2", Data = makeData(
            Vector3.new(-1940.854, 23.870, -2161.581),
            CFrame.new(-1941.739624, 37.903503, -2142.379395, 0.998939037, 0.025153507, -0.038574766, 0.000000000, 0.837649822, 0.546207607, 0.046051182, -0.545628130, 0.836761177),
            CFrame.new(-1940.854492, 25.369678, -2161.580566, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947010,
            0.500,
            40.000
        )},
        {Label = "Boss 1", Data = makeData(
            Vector3.new(-2092.624, 19.919, -2027.826),
            CFrame.new(-2076.988770, 33.313568, -2052.577881, -0.845453262, -0.201025277, 0.494770318, 0.000000000, 0.926450491, 0.376417011, -0.534049392, 0.318242997, -0.783270597),
            CFrame.new(-2092.623535, 21.418791, -2027.826416, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600105,
            0.500,
            40.000
        )},
        {Label = "Boss 2", Data = makeData(
            Vector3.new(-2217.817, 19.919, -2027.757),
            CFrame.new(-2211.418213, 29.768099, -2057.554688, -0.977711976, -0.055472907, 0.202489734, 0.000000000, 0.964462817, 0.264218599, -0.209950805, 0.258329690, -0.942966819),
            CFrame.new(-2217.816895, 21.418791, -2027.756836, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600096,
            0.500,
            40.000
        )},
        {Label = "Boss 3", Data = makeData(
            Vector3.new(-2220.480, 19.919, -2260.211),
            CFrame.new(-2228.719482, 29.595963, -2230.820068, 0.962882936, 0.069847323, -0.260725409, 0.000000000, 0.965938628, 0.258771241, 0.269919187, -0.249166414, 0.930085897),
            CFrame.new(-2220.480469, 21.418791, -2260.210693, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.599941,
            0.500,
            40.000
        )},
        {Label = "Boss 4", Data = makeData(
            Vector3.new(-2090.565, 19.734, -2263.877),
            CFrame.new(-2086.972412, 32.797325, -2234.693604, 0.992502272, -0.044726547, 0.113747679, 0.000000000, 0.930640101, 0.365935594, -0.122225188, -0.363191903, 0.923662603),
            CFrame.new(-2090.566895, 21.233759, -2263.881348, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600012,
            0.500,
            40.000
        )},
        {Label = "Mob 10", Data = makeData(
            Vector3.new(-2258.677, 19.419, -2138.837),
            CFrame.new(-2246.477051, 36.128731, -2150.935303, -0.704145789, -0.470645428, 0.531668782, 0.000000000, 0.748770833, 0.662829041, -0.710055530, 0.466728270, -0.527243733),
            CFrame.new(-2258.677246, 20.918791, -2138.836670, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.946981,
            0.500,
            40.000
        )},
        {Label = "Mob 10", Data = makeData(
            Vector3.new(-2305.207, 19.419, -2149.039),
            CFrame.new(-2286.398193, 33.015614, -2143.894043, 0.263863444, -0.508480787, 0.819648445, 0.000000000, 0.849764049, 0.527163446, -0.964560032, -0.139099166, 0.224221677),
            CFrame.new(-2305.206787, 20.918793, -2149.039307, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947113,
            0.500,
            40.000
        )},
        {Label = "Mob 10", Data = makeData(
            Vector3.new(-2274.982, 19.419, -2178.434),
            CFrame.new(-2288.335938, 34.517139, -2165.654297, 0.691394150, 0.428139031, -0.581954718, 0.000000000, 0.805498421, 0.592598081, 0.722477913, -0.409718841, 0.556916773),
            CFrame.new(-2274.981934, 20.918791, -2178.433838, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.946920,
            0.500,
            40.000
        )},
        {Label = "Mob 90", Data = makeData(
            Vector3.new(-2252.533, 19.419, -2174.950),
            CFrame.new(-2267.866455, 36.128735, -2182.702393, -0.451180369, 0.591530442, -0.668227494, 0.000000000, 0.748770595, 0.662829220, 0.892432690, 0.299055547, -0.337830663),
            CFrame.new(-2252.532715, 20.918791, -2174.950195, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.946951,
            0.500,
            40.000
        )},
        {Label = "Mob 90", Data = makeData(
            Vector3.new(-2231.636, 19.919, -2164.387),
            CFrame.new(-2246.969727, 36.628754, -2172.139160, -0.451180369, 0.591530442, -0.668227494, 0.000000000, 0.748770595, 0.662829220, 0.892432690, 0.299055547, -0.337830663),
            CFrame.new(-2231.635986, 21.418812, -2164.386963, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.946949,
            0.500,
            40.000
        )},
        {Label = "Mob 90", Data = makeData(
            Vector3.new(-2244.742, 19.419, -2118.371),
            CFrame.new(-2233.265625, 39.126701, -2126.329834, -0.569861412, -0.652032197, 0.500112057, 0.000000000, 0.608600736, 0.793476701, -0.821740806, 0.452171743, -0.346818060),
            CFrame.new(-2244.741699, 20.918791, -2118.371338, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            22.947025,
            0.500,
            40.000
        )},
        {Label = "Mob 700", Data = makeData(
            Vector3.new(-2207.332, 19.419, -2097.701),
            CFrame.new(-2213.806152, 28.429708, -2107.057617, -0.822337270, 0.313481271, -0.474858880, 0.000000000, 0.834549308, 0.550933301, 0.569000423, 0.453052998, -0.686280966),
            CFrame.new(-2207.332275, 20.918791, -2097.701416, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633175,
            0.500,
            40.000
        )},
        {Label = "Mob 700", Data = makeData(
            Vector3.new(-2231.430, 19.419, -2088.590),
            CFrame.new(-2220.060547, 28.429712, -2088.160889, 0.037680522, -0.550542355, 0.833956480, 0.000000000, 0.834549189, 0.550933599, -0.999289870, -0.020759465, 0.031446245),
            CFrame.new(-2231.429932, 20.918791, -2088.589600, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633072,
            0.500,
            40.000
        )},
        {Label = "Mob 700", Data = makeData(
            Vector3.new(-2221.462, 19.419, -2135.914),
            CFrame.new(-2232.647949, 28.621281, -2134.725830, 0.105579346, 0.561827600, -0.820489287, 0.000000000, 0.825100839, 0.564985394, 0.994410813, -0.059650790, 0.087113619),
            CFrame.new(-2221.462158, 20.918791, -2135.913574, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            13.633085,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Halloween", HalloweenList)
    createGrid(HalloweenTeleportSection, HalloweenList, function(item)
        teleportWithData(item.Data)
    end)

    State.InitHalloween = function()
        local HalloweenAutomationSection = createSectionBox(State.Tabs.Halloween:GetPage(), "Automation")
        setupAutoShop(HalloweenAutomationSection, {
            ToggleName = "Auto Buy Flesh Shop",
            DisplayName = "Auto Buy Flesh Shop",
            ModeToggleName = "Mode: Upgrade All",
            SpeedLabel = "Click Speed (sec)",
            ShopName = "Flesh",
            Items = {
                "Flesh Multiplier",
                "Flesh Multiplier II",
                "Mob Damage Multiplier",
                "Attack Speed",
                "Halloween Bulk",
                "Halloween Luck",
                "Sword Enchants Gems Chance",
                "Unlock Candy Corn",
                "Candy Corn Multiplier III",
                "Refined Candy Multiplier III",
                "Factorized Candy Multiplier V"
            },
            CooldownKey = "HalloweenFlesh",
            DefaultCooldown = 0.6,
            StateIndexKey = "HalloweenFleshAutoIndex",
            StateOrderKey = "HalloweenFleshAutoOrder"
        })
    end
end

do
    local ThanksgivingTeleportSection = createSectionBox(State.Tabs.Thanksgiving:GetPage(), "Teleport")
    createButton(ThanksgivingTeleportSection, "Home", function()
        teleportHomeWithBuy("Thanksgiving")
    end)
    local ThanksgivingList = {
        {Label = "Turkey Shop", Data = makeData(
            Vector3.new(-2282.325, 15.991, 2087.762),
            CFrame.new(-2297.520020, 25.541430, 2069.781006, -0.763789833, 0.208844021, -0.610744894, 0.000000000, 0.946209133, 0.323555887, 0.645465076, 0.247128695, -0.722704887),
            CFrame.new(-2282.324707, 17.491360, 2087.761963, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880032,
            0.500,
            40.000
        )},
        {Label = "Turkey Up Damage", Data = makeData(
            Vector3.new(-2286.388, 16.206, 2068.115),
            CFrame.new(-2304.635010, 32.222630, 2059.435791, -0.429556966, 0.526895583, -0.733390629, 0.000000000, 0.812135458, 0.583468914, 0.903039694, 0.250633150, -0.348858476),
            CFrame.new(-2286.388184, 17.705923, 2068.115479, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880079,
            0.500,
            40.000
        )},
        {Label = "Pre Level", Data = makeData(
            Vector3.new(-2280.226, 16.397, 2097.637),
            CFrame.new(-2295.303467, 30.045383, 2082.013428, -0.719575763, 0.339061320, -0.606010079, 0.000000000, 0.872692823, 0.488269746, 0.694413960, 0.351347089, -0.627968609),
            CFrame.new(-2280.225830, 17.897234, 2097.637207, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880014,
            0.500,
            40.000
        )},
        {Label = "Next Level", Data = makeData(
            Vector3.new(-2287.233, 16.397, 2104.400),
            CFrame.new(-2302.310303, 30.045383, 2088.776367, -0.719575763, 0.339061320, -0.606010079, 0.000000000, 0.872692823, 0.488269746, 0.694413960, 0.351347089, -0.627968609),
            CFrame.new(-2287.232666, 17.897234, 2104.400146, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880014,
            0.500,
            40.000
        )},
        {Label = "Token Shop", Data = makeData(
            Vector3.new(-2316.901, 15.491, 2040.879),
            CFrame.new(-2323.509277, 26.616344, 2062.849609, 0.957624197, 0.111422241, -0.265595615, 0.000000000, 0.922140598, 0.386854947, 0.288020730, -0.370461643, 0.883064151),
            CFrame.new(-2316.901367, 16.991394, 2040.878906, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880032,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(-2341.132, 16.370, 2099.476),
            CFrame.new(-2354.765625, 31.576828, 2083.814697, -0.754245102, 0.361739188, -0.547959208, 0.000000000, 0.834549308, 0.550933540, 0.656593144, 0.415538937, -0.629454553),
            CFrame.new(-2341.132324, 17.869602, 2099.475586, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880079,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Thanksgiving", ThanksgivingList)
    createGrid(ThanksgivingTeleportSection, ThanksgivingList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local Event3MTeleportSection = createSectionBox(State.Tabs.Event3M:GetPage(), "Teleport")
    createButton(Event3MTeleportSection, "Home", function()
        teleportHomeWithBuy("3M Event")
    end)
    local Event3MList = {
        {Label = "3M Shop", Data = makeData(
            Vector3.new(-376.230, 16.793, 2042.069),
            CFrame.new(-388.213837, 25.225172, 2055.806641, 0.753568947, 0.233635798, -0.614449501, 0.000000000, 0.934710324, 0.355410486, 0.657368898, -0.267826319, 0.704368651),
            CFrame.new(-376.229614, 18.293245, 2042.068604, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504023,
            0.500,
            40.000
        )},
        {Label = "Potion Shop", Data = makeData(
            Vector3.new(-294.845, 15.991, 2070.316),
            CFrame.new(-310.442261, 28.236837, 2065.660645, -0.286014646, 0.527920187, -0.799684823, 0.000000000, 0.834547877, 0.550935388, 0.958225250, 0.157575592, -0.238692909),
            CFrame.new(-294.845215, 17.491394, 2070.316162, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.504005,
            0.500,
            40.000
        )},
        {Label = "Elevation", Data = makeData(
            Vector3.new(-308.799, 15.991, 2099.406),
            CFrame.new(-306.161530, 30.086281, 2084.749756, -0.984197199, -0.114348486, 0.135204837, 0.000000000, 0.763541162, 0.645759225, -0.177076042, 0.635554433, -0.751475036),
            CFrame.new(-308.798553, 17.491394, 2099.406494, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503975,
            0.500,
            40.000
        )},
        {Label = "Passive", Data = makeData(
            Vector3.new(-414.549, 16.794, 2074.148),
            CFrame.new(-396.920258, 23.249952, 2075.702393, 0.087842517, -0.268621266, 0.959232211, 0.000000000, 0.962954581, 0.269663692, -0.996134341, -0.023687938, 0.084588356),
            CFrame.new(-414.548767, 18.294146, 2074.147949, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            18.377722,
            0.500,
            40.000
        )},
        {Label = "Tree 1", Data = makeData(
            Vector3.new(-376.771, 16.614, 2174.095),
            CFrame.new(-376.742828, 55.848480, 2160.823242, -0.999997795, -0.001967276, 0.000691928, 0.000000000, 0.331794232, 0.943351805, -0.002085411, 0.943349719, -0.331793547),
            CFrame.new(-376.770508, 18.114405, 2174.094971, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            40.000000,
            0.500,
            40.000
        )},
        {Label = "Tree 2", Data = makeData(
            Vector3.new(-377.774, 16.614, 2208.942),
            CFrame.new(-378.372223, 51.552864, 2186.999023, -0.999629200, 0.022765476, -0.014944974, 0.000000000, 0.548788190, 0.835961521, 0.027232684, 0.835651517, -0.548584640),
            CFrame.new(-377.774414, 18.114405, 2208.942383, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            39.999989,
            0.500,
            40.000
        )},
        {Label = "Minions", Data = makeData(
            Vector3.new(-311.161, 16.598, 2046.919),
            CFrame.new(-322.367065, 26.889526, 2058.532227, 0.719588339, 0.332193792, -0.609786689, 0.000000000, 0.878147960, 0.478389114, 0.694400847, -0.344243228, 0.631905079),
            CFrame.new(-311.160583, 18.097818, 2046.919312, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            18.377682,
            0.500,
            40.000
        )},
        {Label = "Rune 1", Data = makeData(
            Vector3.new(-364.514, 16.611, 2102.254),
            CFrame.new(-380.290161, 30.746696, 2116.761719, 0.676882327, 0.373822302, -0.634103537, 0.000000000, 0.861446917, 0.507847726, 0.736091316, -0.343753159, 0.583098114),
            CFrame.new(-364.513672, 18.111444, 2102.254150, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.880047,
            0.500,
            40.000
        )},
        {Label = "Rune 2", Data = makeData(
            Vector3.new(-343.613, 16.582, 2064.344),
            CFrame.new(-359.120483, 31.317451, 2078.604736, 0.676882267, 0.391566694, -0.623302400, 0.000000000, 0.846773267, 0.531953990, 0.736091256, -0.360070229, 0.573165834),
            CFrame.new(-343.612732, 18.082438, 2064.344482, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.879929,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("3M Event", Event3MList)
    createGrid(Event3MTeleportSection, Event3MList, function(item)
        teleportWithData(item.Data)
    end)
end

do
    local ChristmasTeleportSection = createSectionBox(State.Tabs.Christmas:GetPage(), "Teleport")
    createButton(ChristmasTeleportSection, "Home", function()
        teleportHomeWithBuy("Christmas Event")
    end)
    local ChristmasList = {
        {Label = "Candy Cane Shop", Data = makeData(
            Vector3.new(-4078.632, 14.753, -22.723),
            CFrame.new(-4065.713623, 22.292000, -17.451403, 0.377832770, -0.367797047, 0.849686980, 0.000000000, 0.917713642, 0.397243112, -0.925873935, -0.150091469, 0.346742243),
            CFrame.new(-4078.631592, 16.252632, -22.722994, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203208,
            0.500,
            40.000
        )},
        {Label = "Milk Shop", Data = makeData(
            Vector3.new(-4030.130, 14.653, 33.750),
            CFrame.new(-4024.478027, 22.738323, 21.267654, -0.910975277, -0.178671494, 0.371753365, 0.000000000, 0.901305556, 0.433183998, -0.412460983, 0.394619912, -0.821067035),
            CFrame.new(-4030.129883, 16.152540, 33.750500, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203205,
            0.500,
            40.000
        )},
        {Label = "Boss", Data = makeData(
            Vector3.new(-3956.069, 15.153, -22.492),
            CFrame.new(-3969.000244, 34.169048, -34.533123, -0.681481421, 0.515227735, -0.519734144, 0.000000000, 0.710178971, 0.704021275, 0.731835485, 0.479777426, -0.483973742),
            CFrame.new(-3956.069336, 16.653000, -22.491856, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.879961,
            0.500,
            40.000
        )},
        {Label = "Damage Up", Data = makeData(
            Vector3.new(-3948.530, 15.653, -34.233),
            CFrame.new(-3961.460449, 34.669235, -46.274586, -0.681481421, 0.515227735, -0.519734144, 0.000000000, 0.710178971, 0.704021275, 0.731835485, 0.479777426, -0.483973742),
            CFrame.new(-3948.529541, 17.153187, -34.233318, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            24.879961,
            0.500,
            40.000
        )},
        {Label = "Cookies Shop", Data = makeData(
            Vector3.new(-3950.000, 15.153, -16.744),
            CFrame.new(-3956.110352, 20.709223, -25.940693, -0.832916617, 0.190834999, -0.519453526, 0.000000000, 0.938660860, 0.344841897, 0.553398550, 0.287224561, -0.781826198),
            CFrame.new(-3950.000244, 16.653000, -16.744415, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            11.762563,
            0.500,
            40.000
        )},
        {Label = "Next Level", Data = makeData(
            Vector3.new(-3952.720, 15.653, -1.995),
            CFrame.new(-3955.827637, 27.301355, -7.065711, -0.852635741, 0.450792700, -0.264193535, 0.000000000, 0.505627990, 0.862751663, 0.522505760, 0.735612929, -0.431116492),
            CFrame.new(-3952.719971, 17.153187, -1.994678, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            11.762580,
            0.500,
            40.000
        )},
        {Label = "Pre Level", Data = makeData(
            Vector3.new(-3945.432, 15.653, -6.462),
            CFrame.new(-3948.539551, 27.301355, -11.533158, -0.852635741, 0.450792700, -0.264193535, 0.000000000, 0.505627990, 0.862751663, 0.522505760, 0.735612929, -0.431116492),
            CFrame.new(-3945.431885, 17.153187, -6.462125, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            11.762580,
            0.500,
            40.000
        )},
        {Label = "Santa House", Data = makeData(
            Vector3.new(-4078.338, 14.653, -62.542),
            CFrame.new(-4069.680664, 25.191797, -47.583694, 0.865496933, -0.232152030, 0.443869978, 0.000000000, 0.886119723, 0.463456601, -0.500914276, -0.401120275, 0.766933858),
            CFrame.new(-4078.337891, 16.152540, -62.541973, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            19.503996,
            0.500,
            40.000
        )},
        {Label = "Tree 1", Data = makeData(
            Vector3.new(-4024.671, 14.653, -72.131),
            CFrame.new(-4024.057861, 37.363960, -48.716015, 0.999657154, -0.017577140, 0.019409774, 0.000000000, 0.741233408, 0.671247482, -0.026185781, -0.671017349, 0.740979195),
            CFrame.new(-4024.671143, 16.152540, -72.130959, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600000,
            0.500,
            40.000
        )},
        {Label = "Tree 2", Data = makeData(
            Vector3.new(-4024.917, 14.653, -103.420),
            CFrame.new(-4024.495850, 38.525967, -81.107956, 0.999822140, -0.013351330, 0.013316875, 0.000000000, 0.706192613, 0.708019793, -0.018857284, -0.707893848, 0.706067085),
            CFrame.new(-4024.916748, 16.152540, -103.419678, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            31.600004,
            0.500,
            40.000
        )},
        {Label = "Rune", Data = makeData(
            Vector3.new(-4034.828, 15.620, -7.132),
            CFrame.new(-4022.731445, 23.859962, -13.408045, -0.460517138, -0.393522859, 0.795653045, 0.000000000, 0.896358073, 0.443330735, -0.887650728, 0.204161406, -0.412788332),
            CFrame.new(-4034.827881, 17.119917, -7.132341, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            15.203171,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("Christmas Event", ChristmasList)
    createGrid(ChristmasTeleportSection, ChristmasList, function(item)
        teleportWithData(item.Data)
    end)

    State.InitChristmas = function()
        local ChristmasAutomationSection = createSectionBox(State.Tabs.Christmas:GetPage(), "Automation")

        setupAutoShop(ChristmasAutomationSection, {
            ToggleName = "Auto Buy Candy Cane Shop",
            DisplayName = "Auto Buy Candy Cane Shop",
            ModeToggleName = "Mode: Upgrade All",
            SpeedLabel = "Click Speed (sec)",
            ShopName = "Candy Cane",
            Items = {
                "Candy Cane Multiplier",
                "Mini Candy Cane Multipier",
                "Infinite Candy Cane",
                "Free Christmas Bulk",
                "Christmas Luck",
                "Christmas Bulk",
                "Gingerbread Multi",
                "Christmas Spirit"
            },
            CooldownKey = "ChristmasCandyCane",
            DefaultCooldown = 0.6,
            StateIndexKey = "ChristmasCandyCaneAutoIndex",
            StateOrderKey = "ChristmasCandyCaneAutoOrder"
        })

        setupAutoShop(ChristmasAutomationSection, {
            ToggleName = "Auto Buy Milk Shop",
            DisplayName = "Auto Buy Milk Shop",
            ModeToggleName = "Mode: Upgrade All",
            SpeedLabel = "Click Speed (sec)",
            ShopName = "Milk",
            Items = {
                "Milk Multiplier",
                "Cookies Multiplier",
                "Christmas Bulk",
                "Christmas Luck",
                "Candy Cane Multiplier",
                "Gingerbread Multiplier",
                "Christmas Spirit Multiplier",
                "Milk Multiplier II",
                "Christmas Bulk Multiplier",
                "Christmas Luck Multiplier"
            },
            CooldownKey = "ChristmasMilk",
            DefaultCooldown = 0.6,
            StateIndexKey = "ChristmasMilkAutoIndex",
            StateOrderKey = "ChristmasMilkAutoOrder"
        })

        setupAutoShop(ChristmasAutomationSection, {
            ToggleName = "Auto Buy Cookies Shop",
            DisplayName = "Auto Buy Cookies Shop",
            ModeToggleName = "Mode: Upgrade All",
            SpeedLabel = "Click Speed (sec)",
            ShopName = "Cookies",
            Items = {
                "Cookies Multiplier",
                "Mini Cookies Multiplier",
                "Santa Damage",
                "Santa Respawn Speed",
                "Santa Attack Speed",
                "Milk Multiplier",
                "Connor Balanced it",
                "Candy Cane",
                "Gingerbread",
                "Connor Balanced It Final Part",
                "Christmas Spirit multi",
                "Blizz Said Rank6 was hard",
                "Ultra Santa Damage"
            },
            CooldownKey = "ChristmasCookies",
            DefaultCooldown = 0.6,
            StateIndexKey = "ChristmasCookiesAutoIndex",
            StateOrderKey = "ChristmasCookiesAutoOrder"
        })
    end
end
local HeavenTeleportSection = createSectionBox(State.Tabs.Heaven:GetPage(), "Teleport")
createButton(HeavenTeleportSection, "Home", function()
    fireWorldTeleport("Heaven World")
end)
createButton(HeavenTeleportSection, "Buy World", function()
    fireBuyArea("Heaven World")
end)
local HeavenList = {
    {Label = "Roll Rarity", Data = makeData(
        Vector3.new(-4156.508, 16.928, 2069.737),
        CFrame.new(-4155.907227, 25.840816, 2080.672119, 0.998492897, -0.030761035, 0.045449782, 0.000000000, 0.828151584, 0.560504317, -0.054880995, -0.559659600, 0.826903462),
        CFrame.new(-4156.508301, 18.428308, 2069.736572, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224702,
        0.500,
        40.000
    )},
    {Label = "Increase Grace", Data = makeData(
        Vector3.new(-4157.667, 16.971, 2029.196),
        CFrame.new(-4161.286621, 26.064939, 2039.399170, 0.942443669, 0.192010447, -0.273737073, 0.000000000, 0.818677306, 0.574253976, 0.334365040, -0.541202009, 0.771557212),
        CFrame.new(-4157.666504, 18.470596, 2029.195557, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224712,
        0.500,
        40.000
    )},
    {Label = "View Glory", Data = makeData(
        Vector3.new(-4019.002, 15.991, 2071.887),
        CFrame.new(-4032.912598, 25.722851, 2066.520996, -0.359897941, 0.450938851, -0.816778839, 0.000000000, 0.875440657, 0.483325690, 0.932991683, 0.173947915, -0.315069288),
        CFrame.new(-4019.002197, 17.491386, 2071.886963, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        17.030849,
        0.500,
        40.000
    )},
    {Label = "Increase Glory", Data = makeData(
        Vector3.new(-4010.934, 16.983, 2070.257),
        CFrame.new(-4021.764160, 25.875393, 2068.801758, -0.133189067, 0.555318534, -0.820903182, 0.000000000, 0.828282773, 0.560310483, 0.991090775, 0.074627228, -0.110318176),
        CFrame.new(-4010.933838, 18.483175, 2070.257080, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.193132,
        0.500,
        40.000
    )},
    {Label = "Transcend Rank Up", Data = makeData(
        Vector3.new(-4139.377, 15.491, 2088.698),
        CFrame.new(-4144.363770, 22.381298, 2077.699463, -0.910784006, 0.168275982, -0.377035409, 0.000000000, 0.913177013, 0.407563180, 0.412883192, 0.371202022, -0.831707001),
        CFrame.new(-4139.377441, 16.991394, 2088.698486, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224713,
        0.500,
        40.000
    )},
    {Label = "Prestige", Data = makeData(
        Vector3.new(-4153.603, 15.994, 2130.044),
        CFrame.new(-4165.019043, 22.333181, 2125.446289, -0.373537064, 0.339439780, -0.863279045, 0.000000000, 0.930643439, 0.365927339, 0.927615225, 0.136687428, -0.347629815),
        CFrame.new(-4153.602539, 17.493898, 2130.043701, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224652,
        0.500,
        40.000
    )},
    {Label = "Heaven Tree", Data = makeData(
        Vector3.new(-4151.697, 15.491, 2168.389),
        CFrame.new(-4153.026367, 24.828236, 2157.819336, -0.992188632, 0.073923253, -0.100483254, 0.000000000, 0.805503547, 0.592590809, 0.124745868, 0.587961853, -0.799211621),
        CFrame.new(-4151.697266, 16.991394, 2168.388672, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224730,
        0.500,
        40.000
    )},
    {Label = "View Divinity", Data = makeData(
        Vector3.new(-4294.839, 15.991, 2067.794),
        CFrame.new(-4283.051758, 23.287127, 2069.327881, 0.129036605, -0.434586406, 0.891338527, 0.000000000, 0.898853064, 0.438250273, -0.991639793, -0.056550328, 0.115984961),
        CFrame.new(-4294.839355, 17.491394, 2067.793945, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224633,
        0.500,
        40.000
    )},
    {Label = "Blessing", Data = makeData(
        Vector3.new(-4276.872, 15.991, 2046.210),
        CFrame.new(-4276.546387, 22.538385, 2058.429443, 0.999645293, -0.010163699, 0.024616420, 0.000000000, 0.924313784, 0.381633401, -0.026632102, -0.381498039, 0.923985958),
        CFrame.new(-4276.872070, 17.491394, 2046.209961, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        13.224747,
        0.500,
        40.000
    )},
    {Label = "Rune", Data = makeData(
        Vector3.new(-4035.115, 16.794, 2090.486),
        CFrame.new(-4028.479248, 27.137203, 2106.553223, 0.924275875, -0.173082665, 0.340230048, 0.000000000, 0.891295791, 0.453422219, -0.381725162, -0.419087231, 0.823803246),
        CFrame.new(-4035.114990, 18.293655, 2090.485840, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
        70.000,
        Enum.CameraType.Custom,
        19.503902,
        0.500,
        40.000
    )}
}
registerRuneLocations("Heaven World", HeavenList)
createGrid(HeavenTeleportSection, HeavenList, function(item)
    teleportWithData(item.Data)
end)

do
    local HeavenTeleportAutomation = createSubSectionBox(HeavenTeleportSection, "Automation")

    local GloryAutoEnabled = false
    local GloryAutoConn = nil
    local GloryAutoAccum = 0
    local GloryAutoInterval = 0.25
    local GloryLastClick = 0

    State.GloryAutoIndex = 1
    State.GloryAutoOrder = {
        "Grace",
        "Grace II",
        "Grace III",
        "Heavenly Luck",
        "Heavenly Bulk",
        "Heaven Points",
        "Heaven Points II",
        "Glory"
    }

    setGlobalClickCooldown("Glory", 0.6)

    createToggle(HeavenTeleportAutomation, "Auto Buy Glory", nil, false, function(v)
        GloryAutoEnabled = v
        if GloryAutoEnabled then
            if GloryAutoConn then
                GloryAutoConn:Disconnect()
            end
            GloryAutoAccum = 0
            State.GloryAutoIndex = 1
            GloryAutoConn = RunService.Heartbeat:Connect(function(dt)
                GloryAutoAccum += dt
                if GloryAutoAccum >= GloryAutoInterval then
                    GloryAutoAccum = 0
                    local remote = getGraceRemote()
                    if not remote then return end
                    local now = os.clock()
                    if now - GloryLastClick < getGlobalClickCooldown("Glory") then
                        return
                    end
                    local itemName = State.GloryAutoOrder[State.GloryAutoIndex]
                    State.GloryAutoIndex += 1
                    if State.GloryAutoIndex > #State.GloryAutoOrder then
                        State.GloryAutoIndex = 1
                    end
                    if itemName then
                        pcall(function()
                            remote:FireServer("UpgradeAll", "Glory", itemName)
                        end)
                    end
                    GloryLastClick = now
                end
            end)
            trackConnection(GloryAutoConn)
        else
            if GloryAutoConn then
                GloryAutoConn:Disconnect()
                GloryAutoConn = nil
            end
        end
    end)

    createSlider(HeavenTeleportAutomation, "Glory Click Speed (sec)", nil, 0.1, 5, 0.6, function(v)
        setGlobalClickCooldown("Glory", v)
    end, 1)
end

local function setupHeavenAutoShop(section, opts)
    local function setControlsEnabled(controls, enabled)
        for _, ctrl in ipairs(controls) do
            if ctrl and ctrl.SetEnabled then
                ctrl:SetEnabled(enabled)
            end
        end
    end

    local function createListDropdownRow(parent, labelText, onToggle)
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 0, 30)
        frame.BorderSizePixel = 0
        frame.Parent = parent
        registerTheme(frame, "BackgroundColor3", "Main")
        addCorner(frame, 6)
        addStroke(frame, "Muted", 1, 0.8)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -50, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = labelText
        label.Parent = frame
        registerTheme(label, "TextColor3", "Text")

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 30, 0, 20)
        btn.Position = UDim2.new(1, -35, 0.5, -10)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.AutoButtonColor = false
        btn.Parent = frame
        registerTheme(btn, "BackgroundColor3", "Panel")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)

        local enabled = true
        local expanded = false

        local function setExpanded(state)
            expanded = state and true or false
            btn.Text = expanded and "v" or ">"
        end

        btn.MouseButton1Click:Connect(function()
            if not enabled then
                return
            end
            setExpanded(not expanded)
            if onToggle then
                onToggle(expanded)
            end
        end)

        setExpanded(false)

        return {
            SetEnabled = function(_, value)
                enabled = value and true or false
                label.TextTransparency = enabled and 0 or 0.4
                btn.TextTransparency = enabled and 0 or 0.4
            end,
            SetExpanded = function(_, value)
                setExpanded(value)
            end,
            Frame = frame
        }
    end

    local enabled = false
    local conn = nil
    local accum = 0
    local interval = opts.Interval or 0.25
    local lastClick = 0
    local useUpgradeAll = true
    local maxed = {}
    local promptConn = nil
    local skipMaxedEnabled = true
    local itemEnabled = {}

    State[opts.StateIndexKey] = 1
    State[opts.StateOrderKey] = opts.Items

    setGlobalClickCooldown(opts.CooldownKey, opts.DefaultCooldown or 0.6)
    for _, name in ipairs(opts.Items) do
        itemEnabled[name] = true
    end

    local function attachPromptListener()
        if promptConn then
            return
        end
        local ok, remote = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
        end)
        if not ok or not remote or not remote:IsA("RemoteEvent") then
            return
        end
        promptConn = remote.OnClientEvent:Connect(function(_, msg)
            if not enabled then
                return
            end
            if type(msg) ~= "string" then
                return
            end
            local lower = string.lower(msg)
            if not string.find(lower, "already reached max upgrade", 1, true) then
                return
            end
            for _, name in ipairs(State[opts.StateOrderKey]) do
                if string.find(lower, string.lower(name), 1, true) then
                    maxed[name] = true
                end
            end
        end)
        trackConnection(promptConn)
    end

    local function detachPromptListener()
        if promptConn then
            promptConn:Disconnect()
            promptConn = nil
        end
    end

    local function getNextName()
        local list = State[opts.StateOrderKey]
        local total = #list
        for _ = 1, total do
            local idxKey = opts.StateIndexKey
            local name = list[State[idxKey]]
            State[idxKey] += 1
            if State[idxKey] > total then
                State[idxKey] = 1
            end
            if itemEnabled[name] and (not skipMaxedEnabled or not maxed[name]) then
                return name
            end
        end
        return nil
    end

    local container = createSubSectionBox(section, opts.DisplayName or opts.ToggleName or "Auto Buy Shop")
    local childControls = {}

    local function addControl(ctrl)
        childControls[#childControls + 1] = ctrl
        return ctrl
    end

    createToggle(container, "On/Off", nil, false, function(v)
        enabled = v
        setControlsEnabled(childControls, enabled)
        if enabled then
            if conn then
                conn:Disconnect()
            end
            accum = 0
            State[opts.StateIndexKey] = 1
            maxed = {}
            attachPromptListener()
            conn = RunService.Heartbeat:Connect(function(dt)
                accum += dt
                if accum >= interval then
                    accum = 0
                    local remote = getGraceRemote()
                    if not remote then return end
                    local now = os.clock()
                    if now - lastClick < getGlobalClickCooldown(opts.CooldownKey) then
                        return
                    end
                    local action = useUpgradeAll and "UpgradeAll" or "Upgrade"
                    local name = getNextName()
                    if name then
                        pcall(function()
                            remote:FireServer(action, opts.ShopName, name)
                        end)
                    else
                        return
                    end
                    lastClick = now
                end
            end)
            trackConnection(conn)
        else
            if conn then
                conn:Disconnect()
                conn = nil
            end
            detachPromptListener()
        end
    end)

    addControl(createToggle(container, opts.ModeToggleName or "Mode: Upgrade All", nil, true, function(v)
        useUpgradeAll = v
    end))

    addControl(createSlider(container, opts.SpeedLabel or "Click Speed (sec)", nil, 0.1, 5, opts.DefaultCooldown or 0.6, function(v)
        setGlobalClickCooldown(opts.CooldownKey, v)
    end, 1))

    addControl(createToggle(container, "Skip Maxed Items", nil, true, function(v)
        skipMaxedEnabled = v
    end))

    local listContainer
    addControl(createListDropdownRow(container, "Item List", function(open)
        if listContainer then
            listContainer.Visible = open
        end
    end))

    local listContent = createSubSectionBox(container, "Item List")
    listContainer = listContent.Parent
    listContainer.Visible = false

    for _, name in ipairs(opts.Items) do
        addControl(createToggle(listContent, name, nil, true, function(v)
            itemEnabled[name] = v
        end))
    end

    setControlsEnabled(childControls, false)
end

setupAutoShop = function(section, opts)
    local function setControlsEnabled(controls, enabled)
        for _, ctrl in ipairs(controls) do
            if ctrl and ctrl.SetEnabled then
                ctrl:SetEnabled(enabled)
            end
        end
    end

    local function createListDropdownRow(parent, labelText, onToggle)
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 0, 30)
        frame.BorderSizePixel = 0
        frame.Parent = parent
        registerTheme(frame, "BackgroundColor3", "Main")
        addCorner(frame, 6)
        addStroke(frame, "Muted", 1, 0.8)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -50, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = labelText
        label.Parent = frame
        registerTheme(label, "TextColor3", "Text")

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 30, 0, 20)
        btn.Position = UDim2.new(1, -35, 0.5, -10)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.AutoButtonColor = false
        btn.Parent = frame
        registerTheme(btn, "BackgroundColor3", "Panel")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)

        local enabled = true
        local expanded = false

        local function setExpanded(state)
            expanded = state and true or false
            btn.Text = expanded and "v" or ">"
        end

        btn.MouseButton1Click:Connect(function()
            if not enabled then
                return
            end
            setExpanded(not expanded)
            if onToggle then
                onToggle(expanded)
            end
        end)

        setExpanded(false)

        return {
            SetEnabled = function(_, value)
                enabled = value and true or false
                label.TextTransparency = enabled and 0 or 0.4
                btn.TextTransparency = enabled and 0 or 0.4
            end,
            SetExpanded = function(_, value)
                setExpanded(value)
            end,
            Frame = frame
        }
    end

    local enabled = false
    local conn = nil
    local accum = 0
    local interval = opts.Interval or 0.25
    local lastClick = 0
    local useUpgradeAll = true
    local maxed = {}
    local promptConn = nil
    local skipMaxedEnabled = true
    local itemEnabled = {}

    State[opts.StateIndexKey] = 1
    State[opts.StateOrderKey] = opts.Items

    setGlobalClickCooldown(opts.CooldownKey, opts.DefaultCooldown or 0.6)
    for _, name in ipairs(opts.Items) do
        itemEnabled[name] = true
    end

    local function attachPromptListener()
        if promptConn then
            return
        end
        local ok, remote = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
        end)
        if not ok or not remote or not remote:IsA("RemoteEvent") then
            return
        end
        promptConn = remote.OnClientEvent:Connect(function(_, msg)
            if not enabled then
                return
            end
            if type(msg) ~= "string" then
                return
            end
            local lower = string.lower(msg)
            if not string.find(lower, "already reached max upgrade", 1, true) then
                return
            end
            for _, name in ipairs(State[opts.StateOrderKey]) do
                if string.find(lower, string.lower(name), 1, true) then
                    maxed[name] = true
                end
            end
        end)
        trackConnection(promptConn)
    end

    local function detachPromptListener()
        if promptConn then
            promptConn:Disconnect()
            promptConn = nil
        end
    end

    local function getNextName()
        local list = State[opts.StateOrderKey]
        local total = #list
        for _ = 1, total do
            local idxKey = opts.StateIndexKey
            local name = list[State[idxKey]]
            State[idxKey] += 1
            if State[idxKey] > total then
                State[idxKey] = 1
            end
            if itemEnabled[name] and (not skipMaxedEnabled or not maxed[name]) then
                return name
            end
        end
        return nil
    end

    local container = createSubSectionBox(section, opts.DisplayName or opts.ToggleName or "Auto Buy Shop")
    local childControls = {}

    local function addControl(ctrl)
        childControls[#childControls + 1] = ctrl
        return ctrl
    end

    createToggle(container, "On/Off", nil, false, function(v)
        enabled = v
        setControlsEnabled(childControls, enabled)
        if enabled then
            if conn then
                conn:Disconnect()
            end
            accum = 0
            State[opts.StateIndexKey] = 1
            maxed = {}
            attachPromptListener()
            conn = RunService.Heartbeat:Connect(function(dt)
                accum += dt
                if accum >= interval then
                    accum = 0
                    local remote = nil
                    if opts.GetRemote then
                        remote = opts.GetRemote()
                    elseif getMainRemote then
                        remote = getMainRemote()
                    end
                    if not remote then return end
                    local now = os.clock()
                    if now - lastClick < getGlobalClickCooldown(opts.CooldownKey) then
                        return
                    end
                    local action = useUpgradeAll and "UpgradeAll" or "Upgrade"
                    local name = getNextName()
                    if name then
                        pcall(function()
                            remote:FireServer(action, opts.ShopName, name)
                        end)
                    else
                        return
                    end
                    lastClick = now
                end
            end)
            trackConnection(conn)
        else
            if conn then
                conn:Disconnect()
                conn = nil
            end
            detachPromptListener()
        end
    end)

    addControl(createToggle(container, opts.ModeToggleName or "Mode: Upgrade All", nil, true, function(v)
        useUpgradeAll = v
    end))

    addControl(createSlider(container, opts.SpeedLabel or "Click Speed (sec)", nil, 0.1, 5, opts.DefaultCooldown or 0.6, function(v)
        setGlobalClickCooldown(opts.CooldownKey, v)
    end, 1))

    addControl(createToggle(container, "Skip Maxed Items", nil, true, function(v)
        skipMaxedEnabled = v
    end))

    local listContainer
    addControl(createListDropdownRow(container, "Item List", function(open)
        if listContainer then
            listContainer.Visible = open
        end
    end))

    local listContent = createSubSectionBox(container, "Item List")
    listContainer = listContent.Parent
    listContainer.Visible = false

    for _, name in ipairs(opts.Items) do
        addControl(createToggle(listContent, name, nil, true, function(v)
            itemEnabled[name] = v
        end))
    end

    setControlsEnabled(childControls, false)
end

State.InitFiveM = function()
    local FiveMTeleportSection = createSectionBox(State.Tabs.FiveM:GetPage(), "Teleport")
    createButton(FiveMTeleportSection, "Home", function()
        fireWorldTeleport("5M Event")
    end)
    local FiveMTeleportList = {
        {Label = "Clicks Shop", Data = makeData(
            Vector3.new(-42.440, 14.117, 3978.721),
            CFrame.new(-53.744595, 23.892162, 4000.623291, 0.888619244, 0.145973042, -0.434796244, 0.000000000, 0.948000312, 0.318269700, 0.458645731, -0.282820582, 0.842411220),
            CFrame.new(-42.439892, 15.617151, 3978.720703, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            25.999912,
            0.500,
            40.000
        )},
        {Label = "Clicker Tokens Shop", Data = makeData(
            Vector3.new(-7.455, 14.617, 3997.470),
            CFrame.new(-10.638369, 23.903797, 4016.054932, 0.985645175, 0.064442426, -0.156046882, 0.000000000, 0.924285829, 0.381700873, 0.168829650, -0.376221627, 0.911018014),
            CFrame.new(-7.455012, 16.117100, 3997.470215, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            20.399954,
            0.500,
            40.000
        )},
        {Label = "Milestone Up", Data = makeData(
            Vector3.new(-0.921, 14.617, 4015.551),
            CFrame.new(-16.696320, 22.391117, 4004.239990, -0.582687378, 0.249942675, -0.773307323, 0.000000000, 0.951532841, 0.307547420, 0.812696397, 0.179204002, -0.554446161),
            CFrame.new(-0.920850, 16.117149, 4015.550781, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            20.400051,
            0.500,
            40.000
        )},
        {Label = "Tree", Data = makeData(
            Vector3.new(-117.199, 14.117, 4041.364),
            CFrame.new(-104.131653, 38.049431, 4039.934570, -0.108698055, -0.857667744, 0.502584159, 0.000000000, 0.505579770, 0.862779915, -0.994074762, 0.093782499, -0.054955546),
            CFrame.new(-117.198845, 15.617151, 4041.363525, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            26.000011,
            0.500,
            40.000
        )},
        {Label = "Event Legend", Data = makeData(
            Vector3.new(-81.982, 14.117, 4101.043),
            CFrame.new(-73.793541, 22.002190, 4107.702637, 0.630943120, -0.401564479, 0.663819909, 0.000000000, 0.855626523, 0.517593920, -0.775829196, -0.326572329, 0.539851546),
            CFrame.new(-81.982422, 15.617151, 4101.042969, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            12.336031,
            0.500,
            40.000
        )},
        {Label = "Bytes Upgrade", Data = makeData(
            Vector3.new(-60.355, 14.517, 4136.737),
            CFrame.new(-51.984009, 26.749435, 4114.584473, -0.935445905, -0.145905659, 0.321951330, 0.000000000, 0.910830438, 0.412780702, -0.353470147, 0.386134028, -0.852032483),
            CFrame.new(-60.354744, 16.017138, 4136.737305, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            25.999989,
            0.500,
            40.000
        )},
        {Label = "Rune 1", Data = makeData(
            Vector3.new(-65.269, 15.275, 4062.770),
            CFrame.new(-80.431313, 31.827337, 4077.586914, 0.698918164, 0.414051235, -0.583159566, 0.000000000, 0.815377831, 0.578929305, 0.715201735, -0.404624194, 0.569882333),
            CFrame.new(-65.269165, 16.775175, 4062.770020, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            25.999973,
            0.500,
            40.000
        )},
        {Label = "Rune 2", Data = makeData(
            Vector3.new(-43.136, 15.275, 4040.341),
            CFrame.new(-54.345493, 36.385136, 4053.217285, 0.754254699, 0.495213300, -0.431119084, 0.000000000, 0.656611204, 0.754229248, 0.656581938, -0.568880975, 0.495252132),
            CFrame.new(-43.136398, 16.775175, 4040.340820, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000, 0.000000000, 0.000000000, 0.000000000, 1.000000000),
            70.000,
            Enum.CameraType.Custom,
            25.999956,
            0.500,
            40.000
        )}
    }
    registerRuneLocations("5M Event", FiveMTeleportList)
    createGrid(FiveMTeleportSection, FiveMTeleportList, function(item)
        teleportWithData(item.Data)
    end)

    local FiveMAutomationSection = createSectionBox(State.Tabs.FiveM:GetPage(), "Automation")
    local function setControlsEnabled(controls, enabled)
        for _, ctrl in ipairs(controls) do
            if ctrl and ctrl.SetEnabled then
                ctrl:SetEnabled(enabled)
            end
        end
    end

    local function createListDropdownRow(parent, labelText, onToggle)
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 0, 30)
        frame.BorderSizePixel = 0
        frame.Parent = parent
        registerTheme(frame, "BackgroundColor3", "Main")
        addCorner(frame, 6)
        addStroke(frame, "Muted", 1, 0.8)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -50, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = labelText
        label.Parent = frame
        registerTheme(label, "TextColor3", "Text")

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 30, 0, 20)
        btn.Position = UDim2.new(1, -35, 0.5, -10)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.AutoButtonColor = false
        btn.Parent = frame
        registerTheme(btn, "BackgroundColor3", "Panel")
        registerTheme(btn, "TextColor3", "Text")
        addCorner(btn, 6)

        local enabled = true
        local expanded = false

        local function setExpanded(state)
            expanded = state and true or false
            btn.Text = expanded and "v" or ">"
        end

        btn.MouseButton1Click:Connect(function()
            if not enabled then
                return
            end
            setExpanded(not expanded)
            if onToggle then
                onToggle(expanded)
            end
        end)

        setExpanded(false)

        return {
            SetEnabled = function(_, value)
                enabled = value and true or false
                label.TextTransparency = enabled and 0 or 0.4
                btn.TextTransparency = enabled and 0 or 0.4
            end,
            SetExpanded = function(_, value)
                setExpanded(value)
            end,
            Frame = frame
        }
    end

    local FiveMClicksAutoEnabled = false
    local FiveMClicksAutoConn = nil
    local FiveMClicksAutoAccum = 0
    local FiveMClicksAutoInterval = 0.25
    local FiveMClicksDefaultClickCooldown = 0.6
    local FiveMClicksLastClick = 0
    local FiveMClicksUseUpgradeAll = true
    local FiveMClicksMaxed = {}
    local FiveMClicksPromptConn = nil
    local FiveMClicksSkipMaxed = true
    local FiveMClicksItemEnabled = {}
    State.FiveMClicksAutoIndex = 1
    State.FiveMClicksAutoOrder = {
        "Free 5M Bulk",
        "Click Multiplier",
        "Click Multiplier II",
        "Click Multiplier III",
        "Click Multiplier IV",
        "5M Bulk",
        "5M Luck",
        "Bytes",
        "Clicker Tokens",
        "Bytes II",
        "Infinite Clicks",
        "Event Tier Timer",
        "Event Tier Luck",
        "Event Tier Bulk",
        "Event Tier Luck II"
    }

    setGlobalClickCooldown("FiveMClicks", FiveMClicksDefaultClickCooldown)
    for _, name in ipairs(State.FiveMClicksAutoOrder) do
        FiveMClicksItemEnabled[name] = true
    end

    local function attachFiveMClicksPromptListener()
        if FiveMClicksPromptConn then
            return
        end
        local ok, remote = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.PromptNotification
        end)
        if not ok or not remote or not remote:IsA("RemoteEvent") then
            return
        end
        FiveMClicksPromptConn = remote.OnClientEvent:Connect(function(_, msg)
            if not FiveMClicksAutoEnabled then
                return
            end
            if type(msg) ~= "string" then
                return
            end
            local lower = string.lower(msg)
            if not string.find(lower, "already reached max upgrade", 1, true) then
                return
            end
            for _, name in ipairs(State.FiveMClicksAutoOrder) do
                if string.find(lower, string.lower(name), 1, true) then
                    FiveMClicksMaxed[name] = true
                end
            end
        end)
        trackConnection(FiveMClicksPromptConn)
    end

    local function detachFiveMClicksPromptListener()
        if FiveMClicksPromptConn then
            FiveMClicksPromptConn:Disconnect()
            FiveMClicksPromptConn = nil
        end
    end

    local function getNextFiveMClicksName()
        local total = #State.FiveMClicksAutoOrder
        for _ = 1, total do
            local name = State.FiveMClicksAutoOrder[State.FiveMClicksAutoIndex]
            State.FiveMClicksAutoIndex += 1
            if State.FiveMClicksAutoIndex > total then
                State.FiveMClicksAutoIndex = 1
            end
            if FiveMClicksItemEnabled[name] and (not FiveMClicksSkipMaxed or not FiveMClicksMaxed[name]) then
                return name
            end
        end
        return nil
    end

    local FiveMClicksBox = createSubSectionBox(FiveMAutomationSection, "Auto Buy Clicks Shop")
    local FiveMClicksControls = {}
    local function addFiveMClicksControl(ctrl)
        FiveMClicksControls[#FiveMClicksControls + 1] = ctrl
        return ctrl
    end

    createToggle(FiveMClicksBox, "On/Off", nil, false, function(v)
        FiveMClicksAutoEnabled = v
        setControlsEnabled(FiveMClicksControls, FiveMClicksAutoEnabled)
        if FiveMClicksAutoEnabled then
            if FiveMClicksAutoConn then
                FiveMClicksAutoConn:Disconnect()
            end
            FiveMClicksAutoAccum = 0
            State.FiveMClicksAutoIndex = 1
            FiveMClicksMaxed = {}
            attachFiveMClicksPromptListener()
            FiveMClicksAutoConn = RunService.Heartbeat:Connect(function(dt)
                FiveMClicksAutoAccum += dt
                if FiveMClicksAutoAccum >= FiveMClicksAutoInterval then
                    FiveMClicksAutoAccum = 0
                    local remote = getMainRemote and getMainRemote() or nil
                    if not remote then return end
                    local now = os.clock()
                    if now - FiveMClicksLastClick < getGlobalClickCooldown("FiveMClicks") then
                        return
                    end
                    local action = FiveMClicksUseUpgradeAll and "UpgradeAll" or "Upgrade"
                    local name = getNextFiveMClicksName()
                    if name then
                        pcall(function()
                            remote:FireServer(action, "Clicks", name)
                        end)
                    else
                        return
                    end
                    FiveMClicksLastClick = now
                end
            end)
            trackConnection(FiveMClicksAutoConn)
        else
            if FiveMClicksAutoConn then
                FiveMClicksAutoConn:Disconnect()
                FiveMClicksAutoConn = nil
            end
            detachFiveMClicksPromptListener()
        end
    end)

    addFiveMClicksControl(createToggle(FiveMClicksBox, "Mode: Upgrade All", nil, true, function(v)
        FiveMClicksUseUpgradeAll = v
    end))

    addFiveMClicksControl(createSlider(FiveMClicksBox, "Click Speed (sec)", nil, 0.1, 5, FiveMClicksDefaultClickCooldown, function(v)
        setGlobalClickCooldown("FiveMClicks", v)
    end, 1))

    addFiveMClicksControl(createToggle(FiveMClicksBox, "Skip Maxed Items", nil, true, function(v)
        FiveMClicksSkipMaxed = v
    end))

    local FiveMClicksListContainer
    addFiveMClicksControl(createListDropdownRow(FiveMClicksBox, "Item List", function(open)
        if FiveMClicksListContainer then
            FiveMClicksListContainer.Visible = open
        end
    end))

    local FiveMClicksListContent = createSubSectionBox(FiveMClicksBox, "Item List")
    FiveMClicksListContainer = FiveMClicksListContent.Parent
    FiveMClicksListContainer.Visible = false

    for _, name in ipairs(State.FiveMClicksAutoOrder) do
        addFiveMClicksControl(createToggle(FiveMClicksListContent, name, nil, true, function(v)
            FiveMClicksItemEnabled[name] = v
        end))
    end

    setControlsEnabled(FiveMClicksControls, false)
end

if State.InitValentine then
    State.InitValentine()
    State.InitValentine = nil
end

if State.InitHalloween then
    State.InitHalloween()
    State.InitHalloween = nil
end

if State.InitChristmas then
    State.InitChristmas()
    State.InitChristmas = nil
end

if State.InitMushroom then
    State.InitMushroom()
    State.InitMushroom = nil
end

if State.InitFiveM then
    State.InitFiveM()
    State.InitFiveM = nil
end

if State.InitHell then
    State.InitHell()
    State.InitHell = nil
end

do
    local HeavenAutomationSection = createSectionBox(State.Tabs.Heaven:GetPage(), "Automation")

    setupHeavenAutoShop(HeavenAutomationSection, {
        ToggleName = "Auto Buy Grace Shop",
        DisplayName = "Auto Buy Grace Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Grace",
        Items = {
            "Grace",
            "Grace II",
            "Heavenly Luck",
            "Heavenly Luck II",
            "Heavenly Bulk",
            "Heavenly Bulk II",
            "Heaven Points"
        },
        CooldownKey = "Grace",
        DefaultCooldown = 0.6,
        StateIndexKey = "GraceAutoIndex",
        StateOrderKey = "GraceAutoOrder"
    })

    setupHeavenAutoShop(HeavenAutomationSection, {
        ToggleName = "Auto Buy Divinity Shop",
        DisplayName = "Auto Buy Divinity Shop",
        ModeToggleName = "Mode: Upgrade All",
        SpeedLabel = "Click Speed (sec)",
        ShopName = "Divinity",
        Items = {
            "Glory",
            "Divinity",
            "Heaven Points",
            "Heavenly Bulk"
        },
        CooldownKey = "Divinity",
        DefaultCooldown = 0.6,
        StateIndexKey = "DivinityAutoIndex",
        StateOrderKey = "DivinityAutoOrder"
    })
end

end

initEventTabs()

local function initSpaceAutomation()
    local AutomationSection = createSectionBox(State.Tabs.Space:GetPage(), "Automation")

    -- =====================================================
    -- [SECTION] Space World Automation
    -- =====================================================
    getMainRemote = function()
        local ok, remote = pcall(function()
            return game:GetService("ReplicatedStorage").Packages.Knit.Services.RemotesService.RE.MainRemote
        end)
        if ok and remote then
            return remote
        end
        return nil
    end

    State.SpaceAuto = State.SpaceAuto or {}
    State.SpaceAuto.Enabled = State.SpaceAuto.Enabled or false
    State.SpaceAuto.Conn = nil
    State.SpaceAuto.Accum = 0
    State.SpaceAuto.Interval = 5

    State.FireCosmicRankUp = function()
        local remote = getMainRemote()
        if not remote then
            return
        end
        pcall(function()
            remote:FireServer("CosmicRankUp")
        end)
    end

    createToggle(AutomationSection, "Auto Rank Up Cosmic", nil, false, function(v)
        State.SpaceAuto.Enabled = v
        if State.SpaceAuto.Enabled then
            if State.SpaceAuto.Conn then
                State.SpaceAuto.Conn:Disconnect()
            end
            State.SpaceAuto.Accum = 0
            State.FireCosmicRankUp()
            State.SpaceAuto.Conn = RunService.Heartbeat:Connect(function(dt)
                State.SpaceAuto.Accum += dt
                if State.SpaceAuto.Accum >= State.SpaceAuto.Interval then
                    State.SpaceAuto.Accum = 0
                    State.FireCosmicRankUp()
                end
            end)
            trackConnection(State.SpaceAuto.Conn)
        else
            if State.SpaceAuto.Conn then
                State.SpaceAuto.Conn:Disconnect()
                State.SpaceAuto.Conn = nil
            end
        end
    end)

    createButton(AutomationSection, "Rank Up Cosmic", function()
        State.FireCosmicRankUp()
    end)

    -- =====================================================
    -- [SECTION] Space World - Auto Buy Light Points Shop
    -- =====================================================
    setupAutoShop(AutomationSection, {
        ToggleName = "Auto Buy Light Points Shop",
        DisplayName = "Auto Buy Light Points Shop",
        ModeToggleName = "Light Points Mode: Upgrade All",
        SpeedLabel = "Light Points Click Speed (sec)",
        ShopName = "Light Points",
        Items = {
            "Light Points Multiplier",
            "Light Points Multiplier II",
            "Cosmic Points",
            "Cosmic Points II",
            "Cosmic Luck",
            "Cosmic Bulk",
            "Cosmic Speed",
            "Cosmic Luck II",
            "Rune Luck",
            "Rune Bulk",
            "Neptunite",
            "Plutite"
        },
        CooldownKey = "LightPoints",
        DefaultCooldown = 0.6,
        StateIndexKey = "LightAutoIndex",
        StateOrderKey = "LightAutoOrder"
    })
end

initSpaceAutomation()

end

initWorldTabs()
initRuneLocationTab()

-- =====================================================
-- INITIAL STATE
-- =====================================================
applyTheme(Config.Theme or "Default")
HomeTab:Show()

LoadingUI:Set(85, "Menyiapkan UI...")
task.wait(0.02)

LoadingUI:Set(98, "Finishing...")
task.wait(0.02)

Main.Visible = true
task.delay(0.1, function()
    if LoadingUI.Card then
        LoadingUI.Card:Destroy()
    end
end)
