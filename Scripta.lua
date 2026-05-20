-- AI Walk PRO — Smart Navigation + Path Visualizer
-- LocalScript → StarterCharacterScripts

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

local player    = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid  = character:WaitForChild("Humanoid")
local rootPart  = character:WaitForChild("HumanoidRootPart")

-- ════════════════════════════════════════════════
--                   НАСТРОЙКИ
-- ════════════════════════════════════════════════
local Cfg = {
    WalkSpeed        = 16,
    RunSpeed         = 26,
    WanderRadius     = 55,
    WanderInterval   = 3.5,
    DangerRadius     = 22,
    FleeRadius       = 48,
    StuckThreshold   = 1.4,   -- минимум движения за тик
    StuckTime        = 2.2,
    JumpHeight       = 7.5,   -- если препятствие ниже — прыгаем
    ScanRays         = 16,    -- лучей вокруг персонажа
    ScanDist         = 6,
    PathAgentH       = 5,
    PathAgentR       = 2,
    LineLifetime     = 0.18,  -- время жизни сегмента линии
    LineThickness    = 0.12,
}

-- ════════════════════════════════════════════════
--                  STATE MACHINE
-- ════════════════════════════════════════════════
local S = { IDLE="IDLE", WANDER="WANDER", FLEE="FLEE", STUCK="STUCK" }

local AI = {
    running      = false,
    state        = S.IDLE,
    waypoints    = {},
    wpIdx        = 1,
    stuckTimer   = 0,
    stuckPos     = Vector3.new(),
    retries      = 0,
    lastWander   = 0,
    threatLvl    = 0,
    statusMsg    = "Idle",
    lineparts    = {},   -- пул сегментов линии
}

-- ════════════════════════════════════════════════
--            ФИОЛЕТОВАЯ ЛИНИЯ ПУТИ
-- ════════════════════════════════════════════════
local lineFolder = Instance.new("Folder")
lineFolder.Name   = "AIPathLine"
lineFolder.Parent = workspace

local function makeSeg(a, b)
    local mid  = (a + b) / 2
    local dist = (b - a).Magnitude
    if dist < 0.1 then return end

    local p = Instance.new("Part")
    p.Anchored           = true
    p.CanCollide         = false
    p.CanTouch           = false
    p.CastShadow         = false
    p.Size               = Vector3.new(Cfg.LineThickness, Cfg.LineThickness, dist)
    p.CFrame             = CFrame.lookAt(mid, b)
    p.BrickColor         = BrickColor.new("Bright violet")
    p.Material           = Enum.Material.Neon
    p.LocalTransparencyModifier = 0
    p.Transparency       = 0.15
    p.Parent             = lineFolder

    -- авто-удаление
    game:GetService("Debris"):AddItem(p, Cfg.LineLifetime * (#AI.waypoints + 2))
    return p
end

local function drawPath(wps)
    -- Чистим старые сегменты
    for _, seg in ipairs(AI.lineparts) do
        if seg and seg.Parent then seg:Destroy() end
    end
    AI.lineparts = {}

    if not wps or #wps < 2 then return end
    for i = 1, #wps - 1 do
        local a = wps[i].Position  + Vector3.new(0, 0.25, 0)
        local b = wps[i+1].Position + Vector3.new(0, 0.25, 0)
        local seg = makeSeg(a, b)
        if seg then table.insert(AI.lineparts, seg) end
    end
end

local function clearLine()
    for _, seg in ipairs(AI.lineparts) do
        if seg and seg.Parent then seg:Destroy() end
    end
    AI.lineparts = {}
end

-- ════════════════════════════════════════════════
--           СКАНЕР ПРЕПЯТСТВИЙ (360°)
-- ════════════════════════════════════════════════
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }

local function scanObstacles()
    -- Возвращает таблицу {angle, dist, canJump, normal}
    local results = {}
    local origin  = rootPart.Position + Vector3.new(0, 0.5, 0)

    for i = 0, Cfg.ScanRays - 1 do
        local angle = (i / Cfg.ScanRays) * math.pi * 2
        local dir   = Vector3.new(math.sin(angle), 0, math.cos(angle))

        -- Луч на уровне груди
        local hit = workspace:Raycast(origin, dir * Cfg.ScanDist, rayParams)
        if hit then
            -- Проверяем верхний луч — можно ли перепрыгнуть?
            local topOrigin = rootPart.Position + Vector3.new(0, Cfg.JumpHeight, 0)
            local topHit    = workspace:Raycast(topOrigin, dir * (Cfg.ScanDist * 0.8), rayParams)
            local canJump   = (topHit == nil)

            table.insert(results, {
                angle   = angle,
                dist    = hit.Distance,
                canJump = canJump,
                pos     = hit.Position,
                normal  = hit.Normal,
            })
        end
    end
    return results
end

local function shouldJump(obs)
    -- Если впереди препятствие которое можно перепрыгнуть
    local fwd = rootPart.CFrame.LookVector
    for _, o in ipairs(obs) do
        local dir = Vector3.new(math.sin(o.angle), 0, math.cos(o.angle))
        local dot = fwd:Dot(dir)
        if dot > 0.6 and o.dist < 4.5 and o.canJump then
            return true
        end
    end
    return false
end

-- ════════════════════════════════════════════════
--           PATHFINDING
-- ════════════════════════════════════════════════
local function buildPath(dest)
    local path = PathfindingService:CreatePath({
        AgentHeight  = Cfg.PathAgentH,
        AgentRadius  = Cfg.PathAgentR,
        AgentCanJump = true,
        Costs        = { Water = 25, Obstacle = 15 },
    })
    local ok = pcall(function() path:ComputeAsync(rootPart.Position, dest) end)
    if ok and path.Status == Enum.PathStatus.Success then
        local wps = path:GetWaypoints()
        drawPath(wps)
        return wps
    end
    return nil
end

local function nextWaypoint()
    if not AI.waypoints or AI.wpIdx > #AI.waypoints then return true end
    local wp   = AI.waypoints[AI.wpIdx]
    local dist = (rootPart.Position - wp.Position).Magnitude

    -- Прыжок по метке пути
    if wp.Action == Enum.PathWaypointAction.Jump then
        humanoid.Jump = true
    end

    if dist < 3.2 then
        AI.wpIdx += 1
        return AI.wpIdx > #AI.waypoints
    end

    humanoid:MoveTo(wp.Position)
    return false
end

-- ════════════════════════════════════════════════
--         ОБНАРУЖЕНИЕ УГРОЗЫ (только игроки)
-- ════════════════════════════════════════════════
local function nearestEnemy()
    local best, bestD = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (rootPart.Position - r.Position).Magnitude
                if d < bestD then best, bestD = r, d end
            end
        end
    end
    return best, bestD
end

local function threatLevel(d)
    if d < 10 then return 3 end
    if d < 16 then return 2 end
    if d < Cfg.DangerRadius then return 1 end
    return 0
end

-- ════════════════════════════════════════════════
--         НАПРАВЛЕНИЕ ПОБЕГА
-- ════════════════════════════════════════════════
local function fleeDest(myPos, threatPos)
    local away = (myPos - threatPos)
    away = Vector3.new(away.X, 0, away.Z).Unit
    local best, bestD = myPos + away * Cfg.FleeRadius, 0

    for deg = 0, 330, 30 do
        local rad = math.rad(deg)
        local d   = Vector3.new(
            away.X * math.cos(rad) - away.Z * math.sin(rad),
            0,
            away.X * math.sin(rad) + away.Z * math.cos(rad)
        )
        local cand = myPos + d * Cfg.FleeRadius
        local ray  = workspace:Raycast(myPos + Vector3.new(0,1,0),
                        (cand - myPos).Unit * Cfg.FleeRadius, rayParams)
        local dist = ray and (myPos - ray.Position).Magnitude or Cfg.FleeRadius
        if dist > bestD then bestD = dist; best = myPos + d * math.min(dist * 0.85, Cfg.FleeRadius) end
    end
    return best
end

-- ════════════════════════════════════════════════
--         ВОССТАНОВЛЕНИЕ ПРИ ЗАСТРЕВАНИИ
-- ════════════════════════════════════════════════
local function recoverStuck()
    AI.statusMsg = "Stuck → recovering"
    humanoid.Jump = true
    task.wait(0.25)
    local dirs = {
        rootPart.CFrame.RightVector,
       -rootPart.CFrame.RightVector,
       -rootPart.CFrame.LookVector,
    }
    humanoid:MoveTo(rootPart.Position + dirs[math.random(1,3)] * 7)
    task.wait(0.6)
    AI.state   = S.WANDER
    AI.retries = 0
    AI.stuckTimer = 0
end

-- ════════════════════════════════════════════════
--              ГЛАВНЫЙ AI-ЦИКЛ
-- ════════════════════════════════════════════════
local function aiLoop()
    while AI.running do
        -- ── Застревание ──────────────────────────
        local movedDist = (rootPart.Position - AI.stuckPos).Magnitude
        if movedDist < Cfg.StuckThreshold then
            AI.stuckTimer += 0.1
            if AI.stuckTimer > Cfg.StuckTime then
                recoverStuck()
                AI.stuckPos = rootPart.Position
                task.wait(0.1)
                continue
            end
        else
            AI.stuckTimer = 0
        end
        AI.stuckPos = rootPart.Position

        -- ── Сканируем препятствия ─────────────────
        local obs = scanObstacles()
        if shouldJump(obs) then
            humanoid.Jump = true
        end

        -- ── Угрозы ───────────────────────────────
        local threat, tDist = nearestEnemy()
        AI.threatLvl = threatLevel(tDist)

        if AI.threatLvl > 0 and threat then
            -- РЕЖИМ ПОБЕГА
            AI.state = S.FLEE
            humanoid.WalkSpeed = Cfg.RunSpeed + AI.threatLvl * 3
            AI.statusMsg = string.format("FLEEING  threat=%d  dist=%.0f", AI.threatLvl, tDist)

            local dest = fleeDest(rootPart.Position, threat.Position)
            local wps  = buildPath(dest)
            if wps then
                AI.waypoints = wps
                AI.wpIdx     = 2
                while AI.running do
                    -- Каждые 0.12 с проверяем новое направление
                    local _, nd = nearestEnemy()
                    if nd > Cfg.FleeRadius * 1.25 then break end

                    local done = nextWaypoint()
                    -- Прыжок на ходу
                    if shouldJump(scanObstacles()) then humanoid.Jump = true end
                    if done then break end
                    task.wait(0.05)
                end
                clearLine()
            end

        else
            -- РЕЖИМ БЛУЖДАНИЯ
            AI.state = S.WANDER
            humanoid.WalkSpeed = Cfg.WalkSpeed
            AI.statusMsg = "Wandering"

            local now = tick()
            if now - AI.lastWander > Cfg.WanderInterval then
                AI.lastWander = now
                local angle  = math.random() * math.pi * 2
                local radius = math.random(12, Cfg.WanderRadius)
                local dest   = rootPart.Position + Vector3.new(
                    math.cos(angle) * radius, 0, math.sin(angle) * radius)

                local wps = buildPath(dest)
                if wps then
                    AI.waypoints = wps
                    AI.wpIdx     = 2
                end
            end

            local done = nextWaypoint()
            if done then clearLine() end
        end

        task.wait(0.08)  -- ~12 тиков/с — плавно и быстро
    end

    -- Остановка
    humanoid:MoveTo(rootPart.Position)
    humanoid.WalkSpeed = 16
    clearLine()
    AI.statusMsg = "Stopped"
end

-- ════════════════════════════════════════════════
--                   MINI GUI
-- ════════════════════════════════════════════════
local sg = Instance.new("ScreenGui")
sg.Name            = "AIWalkGUI"
sg.ResetOnSpawn    = false
sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
sg.Parent          = player.PlayerGui

-- Кнопка сворачивания
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size             = UDim2.new(0, 46, 0, 46)
toggleBtn.Position         = UDim2.new(0, 6, 0.45, 0)
toggleBtn.BackgroundColor3 = Color3.fromRGB(38, 38, 58)
toggleBtn.TextColor3       = Color3.fromRGB(180, 130, 255)
toggleBtn.Text             = "◈"
toggleBtn.Font             = Enum.Font.GothamBold
toggleBtn.TextSize         = 20
toggleBtn.BorderSizePixel  = 0
toggleBtn.ZIndex           = 10
toggleBtn.Parent           = sg
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 13)

-- Главная панель
local panel = Instance.new("Frame")
panel.Size             = UDim2.new(0, 210, 0, 280)
panel.Position         = UDim2.new(0, 60, 0.45, 0)
panel.BackgroundColor3 = Color3.fromRGB(16, 16, 26)
panel.BorderSizePixel  = 0
panel.Visible          = true
panel.Parent           = sg
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 16)

-- Полоса заголовка
local header = Instance.new("Frame")
header.Size             = UDim2.new(1, 0, 0, 38)
header.BackgroundColor3 = Color3.fromRGB(80, 40, 160)
header.BorderSizePixel  = 0
header.Parent           = panel
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 16)
-- Фикс нижних углов заголовка
local hfix = Instance.new("Frame")
hfix.Size             = UDim2.new(1, 0, 0.5, 0)
hfix.Position         = UDim2.new(0, 0, 0.5, 0)
hfix.BackgroundColor3 = Color3.fromRGB(80, 40, 160)
hfix.BorderSizePixel  = 0
hfix.Parent           = header

local titleLbl = Instance.new("TextLabel")
titleLbl.Size             = UDim2.new(1, 0, 1, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.TextColor3       = Color3.fromRGB(255, 255, 255)
titleLbl.Text             = "🤖  AI Walk PRO"
titleLbl.Font             = Enum.Font.GothamBold
titleLbl.TextSize         = 14
titleLbl.ZIndex           = 2
titleLbl.Parent           = header

-- Статус-строка
local function makeLabel(yPos, color, text)
    local f = Instance.new("Frame")
    f.Size             = UDim2.new(1, -16, 0, 28)
    f.Position         = UDim2.new(0, 8, 0, yPos)
    f.BackgroundColor3 = Color3.fromRGB(26, 22, 42)
    f.BorderSizePixel  = 0
    f.Parent           = panel
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)

    local l = Instance.new("TextLabel")
    l.Size             = UDim2.new(1, -8, 1, 0)
    l.Position         = UDim2.new(0, 6, 0, 0)
    l.BackgroundTransparency = 1
    l.TextColor3       = color
    l.Text             = text
    l.Font             = Enum.Font.Gotham
    l.TextSize         = 11
    l.TextXAlignment   = Enum.TextXAlignment.Left
    l.Parent           = f
    return l
end

local statusLbl = makeLabel(46,  Color3.fromRGB(140, 255, 160), "Status: Idle")
local threatLbl = makeLabel(82,  Color3.fromRGB(255, 160, 100), "Threat: none")
local scanLbl   = makeLabel(118, Color3.fromRGB(160, 160, 255), "Obstacles: 0")
local speedLbl  = makeLabel(154, Color3.fromRGB(200, 200, 200), "Speed: 16")

-- Кнопка СТАРТ
local startBtn = Instance.new("TextButton")
startBtn.Size             = UDim2.new(1, -16, 0, 36)
startBtn.Position         = UDim2.new(0, 8, 0, 194)
startBtn.BackgroundColor3 = Color3.fromRGB(60, 200, 90)
startBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
startBtn.Text             = "▶  START"
startBtn.Font             = Enum.Font.GothamBold
startBtn.TextSize         = 14
startBtn.BorderSizePixel  = 0
startBtn.Parent           = panel
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 10)

-- Кнопка СТОП
local stopBtn = Instance.new("TextButton")
stopBtn.Size             = UDim2.new(1, -16, 0, 36)
stopBtn.Position         = UDim2.new(0, 8, 0, 236)
stopBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 50)
stopBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
stopBtn.Text             = "■  STOP"
stopBtn.Font             = Enum.Font.GothamBold
stopBtn.TextSize         = 14
stopBtn.BorderSizePixel  = 0
stopBtn.Parent           = panel
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 10)

-- ── Скрыть / показать ──────────────────────────
local panelVisible = true
toggleBtn.MouseButton1Click:Connect(function()
    panelVisible = not panelVisible
    panel.Visible = panelVisible
    toggleBtn.Text = panelVisible and "◈" or "▸"
end)

-- ── Старт ──────────────────────────────────────
startBtn.MouseButton1Click:Connect(function()
    if AI.running then return end
    AI.running    = true
    AI.state      = S.WANDER
    AI.stuckPos   = rootPart.Position
    AI.lastWander = 0
    startBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 55)
    task.spawn(aiLoop)
end)

-- ── Стоп ───────────────────────────────────────
stopBtn.MouseButton1Click:Connect(function()
    AI.running = false
    AI.state   = S.IDLE
    startBtn.BackgroundColor3 = Color3.fromRGB(60, 200, 90)
    clearLine()
end)

-- ════════════════════════════════════════════════
--           ОБНОВЛЕНИЕ GUI (Heartbeat)
-- ════════════════════════════════════════════════
local threatColors = {
    [0] = Color3.fromRGB(120, 255, 140),
    [1] = Color3.fromRGB(255, 230, 60),
    [2] = Color3.fromRGB(255, 150, 30),
    [3] = Color3.fromRGB(255, 50,  50),
}
local threatNames = { [0]="none", [1]="low ⚠", [2]="medium ⚡", [3]="HIGH 🔴" }

RunService.Heartbeat:Connect(function()
    if not panel.Visible then return end
    local tl = math.clamp(AI.threatLvl, 0, 3)
    statusLbl.Text       = "Status: " .. AI.statusMsg
    threatLbl.Text       = "Threat: " .. threatNames[tl]
    threatLbl.TextColor3 = threatColors[tl]

    local obs = scanObstacles()
    local jumpable = 0
    for _, o in ipairs(obs) do if o.canJump then jumpable += 1 end end
    scanLbl.Text = string.format("Obstacles: %d  jumpable: %d", #obs, jumpable)
    speedLbl.Text = "Speed: " .. tostring(math.floor(humanoid.WalkSpeed))
end)

-- ════════════════════════════════════════════════
--           РЕСЕТ ПЕРСОНАЖА
-- ════════════════════════════════════════════════
player.CharacterAdded:Connect(function(c)
    AI.running  = false
    character   = c
    humanoid    = c:WaitForChild("Humanoid")
    rootPart    = c:WaitForChild("HumanoidRootPart")
    rayParams.FilterDescendantsInstances = { character }
    AI.state    = S.IDLE
    AI.statusMsg = "Idle"
    clearLine()
    startBtn.BackgroundColor3 = Color3.fromRGB(60, 200, 90)
end)
