--[[
    ASCENSION ANALYTICS V5
    Read-only HUD for the Ascension panel (reads on-screen text only).

    What's new vs V4:
      * XP curve is now an EXPONENTIAL model fitted to your real numbers
        (30 -> 25.5K, 45 -> 31.2K, 349 -> 1.83M, 350 -> 1.86M, 351 -> 1.88M).
        It re-fits itself on every ascension and grades its own predictions.
      * Tabs: STATS / ROADMAP / INSIGHTS, live XP/s graph, finish clock time,
        "XP/s you'd need" targets, adjustable goal, ascension pulse + toast.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

--==================================================
-- CONFIG
--==================================================
local Target         = 1000   -- goal (also adjustable in the INSIGHTS tab)
local MAX_TARGET     = 5000
local INTERVAL       = 0.5    -- seconds between reads
local RATE_WINDOW    = 60     -- base window for live XP/s (auto-widens if numbers are too rounded)
local IDLE_AFTER     = 15     -- seconds with no XP before status = IDLE
local SPARK_N        = 48     -- bars in the XP/s graph
local SPARK_STEP     = 5      -- seconds per bar (48 * 5s = 4 minutes)
local START_EXPANDED = false
local DEBUG          = false  -- true = print every label found in the panel

-- Real values you gave me: {ascension, required XP}
local SEED_POINTS = {
    { 30, 25500 }, { 45, 31200 },
    { 349, 1830000 }, { 350, 1860000 }, { 351, 1880000 },
}
local SEED_TOLERANCE = 0.04 -- drop the seeds if live readings disagree by more than 4%

local C = {
    bg     = Color3.fromRGB(24, 19, 15),
    stroke = Color3.fromRGB(230, 165, 30),
    gold   = Color3.fromRGB(255, 196, 28),
    text   = Color3.fromRGB(245, 236, 222),
    dim    = Color3.fromRGB(168, 150, 120),
    track  = Color3.fromRGB(10, 8, 7),
    fill   = Color3.fromRGB(255, 170, 20),
    good   = Color3.fromRGB(95, 200, 110),
    warn   = Color3.fromRGB(240, 180, 40),
    bad    = Color3.fromRGB(225, 95, 75),
    row    = Color3.fromRGB(52, 41, 30),
}

local GUI -- assigned below (declared early so the panel finder can skip our own labels)

for _, g in ipairs(PlayerGui:GetChildren()) do
    if g:IsA("ScreenGui") and g.Name:find("^AscensionAnalytics") then
        g:Destroy()
    end
end

--==================================================
-- HELPERS
--==================================================
local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function strip(s)
    s = tostring(s or "")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("\u{00A0}", " ")
    s = s:match("^%s*(.-)%s*$")
    return s
end

local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, QA = 1e15, QI = 1e18, SX = 1e21, SP = 1e24 }
local NUM = "([%d%.,]+%s*%a?%a?)"
local PAIR = NUM .. "%s*/%s*" .. NUM

local function parseNumber(s)
    s = strip(s):upper()
    s = s:gsub(",", "")
    local num, suf = s:match("^([%d%.]+)%s*(%a*)")
    if not num then return nil end
    num = tonumber(num)
    if not num then return nil end
    return num * (SUFFIX[suf] or 1)
end

local UNITS = {
    { 1e24, "Sp" }, { 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" },
    { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" },
}

local function fmtNum(n)
    if not n or n ~= n then return "-" end
    local a = math.abs(n)
    if a == math.huge then return "inf" end
    for _, u in ipairs(UNITS) do
        if a >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
    end
    if a >= 100 then return string.format("%.0f", n) end
    return string.format("%.1f", n)
end

local function fmtTime(sec)
    if not sec or sec ~= sec or sec == math.huge or sec < 0 then return "-" end
    if sec >= 3.1557e7 then
        local y = sec / 3.1557e7
        if y >= 1000 then return ">1000y" end
        return string.format("%.1fy", y)
    end
    sec = math.floor(sec)
    local d = sec // 86400
    local h = (sec % 86400) // 3600
    local m = (sec % 3600) // 60
    local s = sec % 60
    if d > 0 then return string.format("%dd %02dh", d, h)
    elseif h > 0 then return string.format("%dh %02dm", h, m)
    elseif m > 0 then return string.format("%dm %02ds", m, s)
    end
    return string.format("%ds", s)
end

local function clockAt(secFromNow)
    if not secFromNow or secFromNow ~= secFromNow or secFromNow > 3e8 then return "-" end
    local ok, s = pcall(os.date, "%a %b %d, %H:%M", os.time() + math.floor(secFromNow))
    return ok and s or "-"
end

local function dig(root, ...)
    local cur = root
    for _, name in ipairs({ ... }) do
        cur = cur and cur:FindFirstChild(name)
    end
    return cur
end

--==================================================
-- READING THE GAME UI
--==================================================
local function isText(o)
    return o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")
end

local function collectLabels(scope)
    local list = {}
    local function add(o)
        if isText(o) then list[#list + 1] = { obj = o, text = strip(o.Text) } end
    end
    add(scope)
    for _, d in ipairs(scope:GetDescendants()) do add(d) end
    return list
end

local function nameHas(obj, stop, pat)
    local o = obj
    while o and o ~= stop do
        if o.Name:lower():find(pat, 1, true) then return true end
        o = o.Parent
    end
    return false
end

-- loose = we're already inside AscHubTap, so any label with an integer will do
local function readAsc(labels, sc, loose)
    local best, bestScore
    for _, it in ipairs(labels) do
        local t = it.text:gsub(",", "")
        local n = t:match("^(%d+)$") or t:match("^[Aa]scension%s*[:#]?%s*(%d+)$")
        if not n and loose then n = t:match("^%D-(%d+)%D*$") end
        if n then
            local score = it.obj.TextSize
            if nameHas(it.obj, sc, "asc") then score += 100 end
            if nameHas(it.obj, sc, "value") then score += 10 end
            if not bestScore or score > bestScore then
                best, bestScore = tonumber(n), score
            end
        end
    end
    return best
end

local function readXP(labels)
    local texts = {}
    for _, it in ipairs(labels) do
        local a, b = it.text:match(PAIR)
        if a and b then
            local x, r = parseNumber(a), parseNumber(b)
            if x and r and r > 0 then return x, r end
        end
        texts[#texts + 1] = it.text
    end
    local a, b = table.concat(texts, " "):match(PAIR)
    if a and b then
        local x, r = parseNumber(a), parseNumber(b)
        if x and r and r > 0 then return x, r end
    end
    return nil, nil
end

-- "Legendary chest at 50" / "250 Aether Shards at 40"
local function readReward(labels, asc)
    for _, it in ipairs(labels) do
        local name, n = it.text:match("^(.-)%s+[Aa][Tt]%s+(%d+)$")
        n = tonumber(n)
        if name and #name > 0 and n and n > asc then return name, n end
    end
end

local PANEL_PATH = { "Training", "Root", "TrainingPanel", "Card", "Body", "Info" }
local scope, lastScan, usePath, failCount, dumped = nil, -10, true, 0, nil

local function scanForScope()
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if isText(d) and strip(d.Text):lower() == "ascension" and not (GUI and d:IsDescendantOf(GUI)) then
            local a = d.Parent
            for _ = 1, 6 do
                if not a or a == PlayerGui then break end
                for _, x in ipairs(a:GetDescendants()) do
                    if isText(x) and strip(x.Text):match(PAIR) then return a end
                end
                a = a.Parent
            end
        end
    end
end

local function findScope(now)
    if scope and scope.Parent then return scope end
    scope = nil
    if usePath then
        local cur = PlayerGui
        for _, name in ipairs(PANEL_PATH) do
            cur = cur and cur:FindFirstChild(name)
        end
        if cur then scope = cur return scope end
    end
    if now - lastScan >= 3 then
        lastScan = now
        scope = scanForScope()
    end
    return scope
end

--==================================================
-- XP CURVE MODEL:  required(a) = exp(p0 + r * a)
-- (exponential: every ascension costs ~1.35% more than the last)
--==================================================
local function fitExp(pts) -- pts = { {asc, requiredXP, weight}, ... }
    local sw, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, p in ipairs(pts) do
        local w, x, y = p[3] or 1, p[1], math.log(p[2])
        sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
    end
    local den = sw * sxx - sx * sx
    if #pts >= 2 and den > 1e-9 then
        local r = math.clamp((sw * sxy - sx * sy) / den, 0, 0.3)
        return { p0 = (sy - r * sx) / sw, r = r, n = #pts }
    end
    return nil
end

local seedPts, SeedAsc = {}, {}
for _, p in ipairs(SEED_POINTS) do
    seedPts[#seedPts + 1] = { p[1], p[2], 1 }
    SeedAsc[p[1]] = true
end
local seedFit = fitExp(seedPts)
local model = seedFit
local seedsOk = true
local Obs, Errs = {}, {} -- real readings seen, and how wrong our predictions were

local function refit()
    local live = {}
    local minA, maxA, top = math.huge, 0, nil
    for a, req in pairs(Obs) do
        live[#live + 1] = { a, req, 2 }
        if a < minA then minA = a end
        if a > maxA then maxA = a; top = { a, req } end
    end
    if #live == 0 then return end

    if seedsOk then
        for _, p in ipairs(live) do
            local pred = math.exp(seedFit.p0 + seedFit.r * p[1])
            if math.abs(pred / p[2] - 1) > SEED_TOLERANCE then
                seedsOk = false
                break
            end
        end
    end

    if seedsOk then
        local pts = {}
        for _, p in ipairs(seedPts) do pts[#pts + 1] = p end
        for _, p in ipairs(live) do pts[#pts + 1] = p end
        model = fitExp(pts) or seedFit
    elseif maxA - minA >= 10 then
        model = fitExp(live) or model
    else
        -- not enough live spread to trust a slope: keep the known growth, re-anchor on the latest reading
        model = { p0 = math.log(top[2]) - seedFit.r * top[1], r = seedFit.r, n = #live }
    end
end

local function modelReq(a, adj)
    return math.exp(model.p0 + model.r * a) * (adj or 1)
end

--==================================================
-- SESSION STATE
--==================================================
local S
local function resetSession()
    S = {
        startT = os.clock(), prevT = os.clock(),
        prev = nil, cum = 0, samples = {},
        lastGainT = nil, ascGained = 0, rejects = 0,
        activeTotal = 0, activeAcc = 0, fullStart = false, lastAscT = nil,
        rateRec = {},          -- { a = ascension, rate = avg XP/s during it }
        spark = {}, lastSpark = 0,
    }
end
resetSession()

local function isIdle(now)
    return now - (S.lastGainT or S.startT) > IDLE_AFTER
end

-- Feeds one reading in. Returns an event table when an ascension just happened.
local function ingest(asc, xp, req, now)
    local p = S.prev
    local ev
    if p then
        local gained = 0
        local dt = now - S.prevT
        if not isIdle(now) then
            S.activeTotal += dt
            S.activeAcc += dt
        end

        if asc == p.asc then
            gained = xp - p.xp
        elseif asc > p.asc then
            gained = math.max(0, p.req - p.xp) + xp
            for a = p.asc + 1, asc - 1 do gained += modelReq(a) end
            -- labels updating out of sync can fake a huge gain; wait a tick or two
            if asc - p.asc == 1 and gained > p.req * 3 and S.rejects < 3 then
                S.rejects += 1
                return nil
            end
            local n = asc - p.asc
            S.ascGained += n
            ev = { n = n, from = p.asc, dur = S.lastAscT and (now - S.lastAscT) or nil }
            if n == 1 and S.fullStart and S.activeAcc >= 2 then
                S.rateRec[#S.rateRec + 1] = { a = p.asc, rate = p.req / S.activeAcc }
                if #S.rateRec > 40 then table.remove(S.rateRec, 1) end
            end
            S.fullStart = true
            S.activeAcc = 0
            S.lastAscT = now
        else
            S.samples = {} -- ascension went DOWN (reset/prestige): restart windows
            S.fullStart, S.activeAcc, S.rateRec = false, 0, {}
        end

        S.rejects = 0
        if gained > 0 then
            S.cum += gained
            S.lastGainT = now
        end
    end

    S.prev = { asc = asc, xp = xp, req = req }
    S.prevT = now
    S.samples[#S.samples + 1] = { t = now, c = S.cum }
    while S.samples[1] and S.samples[1].t < now - 650 do
        table.remove(S.samples, 1)
    end
    return ev
end

local function rateOver(window, now)
    local s = S.samples
    local n = #s
    if n < 2 then return nil end
    local last = s[n]
    local first = last
    for i = n - 1, 1, -1 do
        if now - s[i].t > window then break end
        first = s[i]
    end
    local dt = last.t - first.t
    if dt < 5 then return nil end
    return (last.c - first.c) / dt, last.c - first.c
end

-- The game rounds XP to ~3 significant digits. If the gain inside the window is
-- only a few rounding steps, widen the window until the number is trustworthy.
local function rateAdaptive(now, req)
    local quant = 10 ^ (math.floor(math.log10(req)) - 2)
    local rate
    for _, w in ipairs({ RATE_WINDOW, RATE_WINDOW * 2, RATE_WINDOW * 5, 600 }) do
        local r, gained = rateOver(w, now)
        if r then
            rate = r
            if gained >= quant * 5 then break end
        end
    end
    return rate
end

-- Is your XP/s growing from ascension to ascension? (log-linear fit over completed ascensions)
local function trendGrowth()
    local recs = S.rateRec
    local n = #recs
    if n < 6 then return nil, n end
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    local minA, maxA = math.huge, 0
    for _, rc in ipairs(recs) do
        local x, y = rc.a, math.log(rc.rate)
        sx += x; sy += y; sxx += x * x; sxy += x * y
        if x < minA then minA = x end
        if x > maxA then maxA = x end
    end
    if maxA - minA < 5 then return nil, n end
    local den = n * sxx - sx * sx
    if den < 1e-9 then return nil, n end
    return math.clamp((n * sxy - sx * sy) / den, -0.05, 0.12), n
end

local function milestones(asc)
    local set, list = {}, {}
    local function add(n)
        if n > asc and n < Target and not set[n] then
            set[n] = true
            list[#list + 1] = n
        end
    end
    add((asc // 50 + 1) * 50)
    add((asc // 100 + 1) * 100)
    add((asc // 100 + 2) * 100)
    add((asc // 250 + 1) * 250)
    add(500); add(750)
    table.sort(list)
    local out = {}
    for i = 1, math.min(4, #list) do out[#out + 1] = list[i] end
    if Target > asc then out[#out + 1] = Target end
    return out
end

--==================================================
-- GUI
--==================================================
local WIDTH = 262

GUI = new("ScreenGui", {
    Name = "AscensionAnalyticsV5",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
}, PlayerGui)

local Main = new("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(WIDTH, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    Position = UDim2.fromOffset(400, 120),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
    Active = true,
}, GUI)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, Main)
local MainStroke = new("UIStroke", { Color = C.stroke, Thickness = 1.5, Transparency = 0.35 }, Main)
local Scale = new("UIScale", {}, Main)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, Main)

-- Header: drag to move, tap to expand/collapse
local Header = new("TextButton", {
    Name = "Header", Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1,
    Text = "", AutoButtonColor = false, LayoutOrder = 1,
}, Main)

new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 6), Size = UDim2.fromOffset(110, 12),
    Text = "ASCENSION", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Header)

local AscLabel = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 17), Size = UDim2.new(0.62, 0, 0, 26),
    RichText = true, Text = "-", Font = Enum.Font.GothamBold, TextSize = 22, TextColor3 = C.gold,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Header)

local StatusText = new("TextLabel", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -24, 0, 6), Size = UDim2.fromOffset(90, 12),
    Text = "STARTING", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.dim,
    TextXAlignment = Enum.TextXAlignment.Right,
}, Header)

local StatusDot = new("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 8),
    Size = UDim2.fromOffset(8, 8), BackgroundColor3 = C.dim, BorderSizePixel = 0,
}, Header)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, StatusDot)

local MoreLabel = new("TextLabel", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -12, 0, 28), Size = UDim2.fromOffset(60, 14),
    Text = START_EXPANDED and "LESS" or "MORE", Font = Enum.Font.GothamBold, TextSize = 10,
    TextColor3 = C.stroke, TextXAlignment = Enum.TextXAlignment.Right,
}, Header)

-- XP bar for the current ascension
local BarWrap = new("Frame", { Name = "BarWrap", Size = UDim2.new(1, 0, 0, 12), BackgroundTransparency = 1, LayoutOrder = 2 }, Main)
local Track = new("Frame", {
    Position = UDim2.fromOffset(12, 2), Size = UDim2.new(1, -24, 0, 6),
    BackgroundColor3 = C.track, BorderSizePixel = 0,
}, BarWrap)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, Track)
local Fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.fill, BorderSizePixel = 0 }, Track)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, Fill)

-- Body
local Body = new("Frame", {
    Name = "Body", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, LayoutOrder = 3,
}, Main)
new("UIPadding", {
    PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
    PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 10),
}, Body)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 1) }, Body)

local Toast = new("TextLabel", {
    Name = "Toast", LayoutOrder = -1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Visible = false, TextWrapped = true, Text = "",
    Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.good, TextXAlignment = Enum.TextXAlignment.Left,
}, Body)

local Notice = new("TextLabel", {
    Name = "Notice", LayoutOrder = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Visible = false, TextWrapped = true, Text = "",
    Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.warn, TextXAlignment = Enum.TextXAlignment.Left,
}, Body)

local Rows = {}
local function addRow(parent, key, order, labelText, labelWidth)
    labelWidth = labelWidth or 0.58
    local row = new("Frame", {
        Name = key, Size = UDim2.new(1, 0, 0, 19), BackgroundTransparency = 1, LayoutOrder = order,
    }, parent)
    local l = new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(labelWidth, 0, 1, 0), Text = labelText,
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.dim,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    local v = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromScale(labelWidth, 0), Size = UDim2.new(1 - labelWidth, 0, 1, 0),
        Text = "-", Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    Rows[key] = { row = row, label = l, value = v }
end

-- always visible
addRow(Body, "xps", 10, "XP / SEC")
addRow(Body, "next", 11, "NEXT ASCENSION")
addRow(Body, "goal", 12, "ETA TO " .. Target)

-- expandable area with tabs
local TabArea = new("Frame", {
    Name = "TabArea", LayoutOrder = 20, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Visible = START_EXPANDED,
}, Body)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, TabArea)
new("Frame", { LayoutOrder = 0, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.row, BorderSizePixel = 0 }, TabArea)
local TabBar = new("Frame", { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, TabArea)

local TabNames = { "STATS", "ROADMAP", "INSIGHTS" }
local Pages, TabBtns = {}, {}

local function selectTab(i)
    for j = 1, #TabNames do
        Pages[j].Visible = (j == i)
        TabBtns[j].TextColor3 = (j == i) and C.gold or C.dim
        TabBtns[j].BackgroundTransparency = (j == i) and 0 or 1
    end
end

for i, name in ipairs(TabNames) do
    Pages[i] = new("Frame", {
        Name = "Page" .. i, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, Visible = (i == 1),
    }, TabArea)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 1) }, Pages[i])
    local b = new("TextButton", {
        Position = UDim2.new((i - 1) / 3, 2, 0, 0), Size = UDim2.new(1 / 3, -4, 1, 0),
        BackgroundColor3 = C.row, Text = name, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.dim,
        AutoButtonColor = false,
    }, TabBar)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    b.Activated:Connect(function() selectTab(i) end)
    TabBtns[i] = b
end
selectTab(1)

-- STATS page
addRow(Pages[1], "left", 10, "XP LEFT (NOW)")
addRow(Pages[1], "ascph", 11, "ASC / HOUR")
addRow(Pages[1], "trend", 12, "XP/S vs 5 MIN")
addRow(Pages[1], "pct", 13, "PROGRESS")
addRow(Pages[1], "reward", 14, "REWARD", 0.7)
addRow(Pages[1], "session", 15, "SESSION")

local SparkWrap = new("Frame", { LayoutOrder = 20, Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1 }, Pages[1])
local SparkCaption = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 12),
    Text = "XP/S - LAST 4 MIN", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
}, SparkWrap)
local SparkArea = new("Frame", {
    Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 36),
    BackgroundColor3 = C.track, BackgroundTransparency = 0.3, BorderSizePixel = 0,
}, SparkWrap)
new("UICorner", { CornerRadius = UDim.new(0, 5) }, SparkArea)
local SparkBars = {}
for i = 1, SPARK_N do
    SparkBars[i] = new("Frame", {
        AnchorPoint = Vector2.new(0, 1), Position = UDim2.new((i - 1) / SPARK_N, 0, 1, -2),
        Size = UDim2.new(1 / SPARK_N, -1, 0.03, 0), BackgroundColor3 = C.fill,
        BackgroundTransparency = 0.8, BorderSizePixel = 0,
    }, SparkArea)
end

local ResetWrap = new("Frame", { LayoutOrder = 30, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, Pages[1])
local ResetBtn = new("TextButton", {
    Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.row,
    Text = "RESET SESSION", Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.dim,
}, ResetWrap)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, ResetBtn)
ResetBtn.Activated:Connect(function() resetSession() end)

-- ROADMAP page
for i = 1, 5 do addRow(Pages[2], "ms" .. i, 10 + i, "ASC") end
addRow(Pages[2], "finish", 20, "FINISH CLOCK")
addRow(Pages[2], "ettrend", 21, "ETA IF RATE GROWS", 0.64)
addRow(Pages[2], "rategrowth", 22, "YOUR XP/S GROWTH", 0.5)

-- INSIGHTS page
addRow(Pages[3], "dbl", 10, "COST DOUBLES EVERY")
addRow(Pages[3], "costgrowth", 11, "COST GROWTH")
addRow(Pages[3], "nextcost", 12, "NEXT ASC COSTS")
addRow(Pages[3], "finalcost", 13, "LAST STEP COSTS")
addRow(Pages[3], "harder", 14, "LAST STEP vs NOW")
addRow(Pages[3], "need7", 15, "XP/S FOR 7 DAYS")
addRow(Pages[3], "need30", 16, "XP/S FOR 30 DAYS")
addRow(Pages[3], "needx", 17, "30D PACE vs YOURS")
addRow(Pages[3], "err", 18, "MODEL ERROR")

local Stepper = new("Frame", { LayoutOrder = 30, Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1 }, Pages[3])
local function stepBtn(text, anchorX, delta)
    local b = new("TextButton", {
        AnchorPoint = Vector2.new(anchorX, 0), Position = UDim2.new(anchorX, 0, 0, 6), Size = UDim2.fromOffset(48, 24),
        BackgroundColor3 = C.row, Text = text, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text,
    }, Stepper)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    b.Activated:Connect(function() Target = math.clamp(Target + delta, 10, MAX_TARGET) end)
end
stepBtn("-50", 0, -50)
stepBtn("+50", 1, 50)
local TargetLabel = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -104, 0, 24),
    Text = "TARGET " .. Target, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.gold,
}, Stepper)

-- Screen fitting / dragging ---------------------------------------------------
local expanded = START_EXPANDED

local function clampedPos(x, y)
    local vp, sz = GUI.AbsoluteSize, Main.AbsoluteSize
    return UDim2.fromOffset(
        math.clamp(x, 0, math.max(0, vp.X - sz.X)),
        math.clamp(y, 0, math.max(0, vp.Y - sz.Y))
    )
end

local function clamp()
    local p = Main.AbsolutePosition
    Main.Position = clampedPos(p.X, p.Y)
end

local function rescale()
    Scale.Scale = math.clamp(GUI.AbsoluteSize.Y / 500, 0.9, 1.2)
end
rescale()
GUI:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    rescale()
    clamp()
end)

local function setExpanded(v)
    expanded = v
    TabArea.Visible = v
    MoreLabel.Text = v and "LESS" or "MORE"
    task.defer(clamp)
end

local dragging, dragStart, startPos = false, nil, nil

Header.InputBegan:Connect(function(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = Main.AbsolutePosition
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                if (input.Position - dragStart).Magnitude < 8 then
                    setExpanded(not expanded) -- a tap, not a drag
                end
            end
        end)
    end
end)

local moveConn = UIS.InputChanged:Connect(function(input)
    if not dragging then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
        local d = input.Position - dragStart
        Main.Position = clampedPos(startPos.X + d.X, startPos.Y + d.Y)
    end
end)
GUI.Destroying:Connect(function() moveConn:Disconnect() end)

task.defer(function()
    task.wait()
    local vp, sz = GUI.AbsoluteSize, Main.AbsoluteSize
    Main.Position = clampedPos(vp.X - sz.X - 12, vp.Y * 0.29)
end)

--==================================================
-- RENDER
--==================================================
local function setStatus(text, color)
    StatusText.Text = text
    StatusText.TextColor3 = color
    StatusDot.BackgroundColor3 = color
end

local function setRow(key, text)
    Rows[key].value.Text = text
end

local function drawSpark()
    local h = S.spark
    local n = #h
    local mx = 0
    for i = 1, n do
        if h[i] > mx then mx = h[i] end
    end
    for i = 1, SPARK_N do
        local v = h[n - SPARK_N + i]
        local f = (v and mx > 0) and math.clamp(v / mx, 0.04, 1) or 0.04
        SparkBars[i].Size = UDim2.new(1 / SPARK_N, -1, f * 0.88, 0)
        SparkBars[i].BackgroundTransparency = v and 0 or 0.8
    end
    SparkCaption.Text = "XP/S - LAST " .. math.floor(SPARK_N * SPARK_STEP / 60) .. " MIN   PEAK " .. fmtNum(mx)
end

local toastId = 0
local function toast(msg)
    toastId += 1
    local id = toastId
    Toast.Text = msg
    Toast.Visible = true
    task.delay(6, function()
        if id == toastId then Toast.Visible = false end
    end)
end

local function pulse()
    MainStroke.Thickness = 4
    MainStroke.Transparency = 0
    MainStroke.Color = Color3.new(1, 1, 1)
    TweenService:Create(MainStroke, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Thickness = 1.5, Transparency = 0.35, Color = C.stroke,
    }):Play()
end

local function render(R, notice)
    Notice.Text = notice or ""
    Notice.Visible = notice ~= nil
    TargetLabel.Text = "TARGET " .. Target
    Rows.goal.label.Text = "ETA TO " .. Target

    if not R then
        AscLabel.Text = string.format('<font color="#A89678">-</font> <font size="13" color="#A89678">/ %d</font>', Target)
        setStatus("NO DATA", C.bad)
        for _, r in pairs(Rows) do r.value.Text = "-" end
        Rows.reward.row.Visible = false
        for i = 1, 5 do Rows["ms" .. i].row.Visible = false end
        Fill.Size = UDim2.fromScale(0, 1)
        return
    end

    local done = R.asc >= Target
    AscLabel.Text = string.format(
        '<font color="#FFC41C">%d</font> <font size="13" color="#A89678">/ %d</font>', R.asc, Target)
    TweenService:Create(Fill, TweenInfo.new(0.35), {
        Size = UDim2.fromScale(math.clamp(R.xp / R.req, 0, 1), 1),
    }):Play()

    -- always-visible rows
    setRow("xps", R.rate and fmtNum(R.rate) or "calculating")
    setRow("next", fmtTime(R.etaNext))
    setRow("goal", done and "DONE" or fmtTime(R.etaGoal))

    -- STATS
    setRow("left", fmtNum(R.remaining))
    setRow("ascph", R.ascph and string.format("%.2f", R.ascph) or "-")
    setRow("trend", R.trend and string.format("%+d%%", math.floor(R.trend * 100 + 0.5)) or "-")
    setRow("pct", string.format("%.2f%%", R.asc / Target * 100))
    local rw = Rows.reward
    if R.reward then
        rw.row.Visible = true
        rw.label.Text = string.format("%s @ %d", R.reward.name, R.reward.n)
        rw.value.Text = fmtTime(R.reward.eta)
    else
        rw.row.Visible = false
    end
    setRow("session", string.format("+%d / %s", R.ascGained, fmtTime(R.runtime)))
    drawSpark()

    -- ROADMAP
    for i = 1, 5 do
        local m, row = R.ms[i], Rows["ms" .. i]
        if m then
            row.row.Visible = true
            row.label.Text = (m.n == Target) and ("ASC " .. m.n .. "  (GOAL)") or ("ASC " .. m.n)
            row.value.Text = fmtTime(m.eta)
        else
            row.row.Visible = false
        end
    end
    setRow("finish", done and "DONE" or clockAt(R.etaGoal))
    setRow("ettrend", R.etaTrend and fmtTime(R.etaTrend) or "-")
    setRow("rategrowth", R.g and string.format("%+.2f%%/asc (%d)", R.g * 100, R.gn)
        or string.format("learning %d/6", R.gn or 0))

    -- INSIGHTS
    setRow("dbl", R.dbl and string.format("%.1f asc", R.dbl) or "-")
    setRow("costgrowth", string.format("+%.2f%% / asc", R.costGrowth))
    setRow("nextcost", fmtNum(R.nextCost))
    setRow("finalcost", R.finalCost and fmtNum(R.finalCost) or "-")
    setRow("harder", R.harder and ("x" .. fmtNum(R.harder)) or "-")
    setRow("need7", done and "-" or fmtNum(R.need7))
    setRow("need30", done and "-" or fmtNum(R.need30))
    setRow("needx", (R.needx and not done) and ("x" .. fmtNum(R.needx)) or "-")
    setRow("err", R.errAvg and string.format("%.2f%% (%d)", R.errAvg * 100, R.errN) or "learning")

    if R.idle then setStatus("IDLE", C.warn) else setStatus("LIVE", C.good) end
end

--==================================================
-- MAIN STEP
--==================================================
local function step()
    local now = os.clock()
    local sc = findScope(now)
    if not sc then
        return render(nil, "Can't find the Ascension panel yet. Open the Training UI.")
    end

    local all = collectLabels(sc)
    if DEBUG and dumped ~= sc then
        dumped = sc
        print("[AscV5] panel:", sc:GetFullName())
        for _, it in ipairs(all) do print("   ", it.obj:GetFullName(), "=", it.text) end
    end

    -- Direct paths first (Info.SlimRow.Value.AscHubTap and Info.XPNumbers), generic scan as backup
    local ascObj = dig(sc, "SlimRow", "Value", "AscHubTap")
    local xpObj = dig(sc, "XPNumbers")
    local asc = (ascObj and readAsc(collectLabels(ascObj), ascObj, true)) or readAsc(all, sc, false)
    local xp, req
    if xpObj then xp, req = readXP(collectLabels(xpObj)) end
    if not xp then xp, req = readXP(all) end

    if not asc or not xp then
        failCount += 1
        if failCount >= 10 and usePath then
            usePath, scope = false, nil
        end
        return render(nil, "Found the panel but can't read the numbers yet.")
    end
    failCount = 0

    -- grade the model: how close was its prediction to what the game actually shows?
    local newErr
    if asc >= 1 and Obs[asc] == nil and not SeedAsc[asc] then
        newErr = math.abs(modelReq(asc) / req - 1)
        Errs[#Errs + 1] = newErr
        if #Errs > 20 then table.remove(Errs, 1) end
    end
    if asc >= 1 and Obs[asc] ~= req then
        Obs[asc] = req
        refit()
    end

    local ev = ingest(asc, xp, req, now)
    if ev then
        pulse()
        local msg = ev.n > 1
            and string.format("ASCENDED  %d -> %d", ev.from, asc)
            or string.format("ASCENDED  %d -> %d  (%s)", ev.from, asc, ev.dur and fmtTime(ev.dur) or "first one seen")
        if newErr then msg = msg .. string.format("\nmodel predicted this cost within %.2f%%", newErr * 100) end
        toast(msg)
    end

    -- rates
    local idle = isIdle(now)
    local rate
    if not idle then rate = rateAdaptive(now, req) end
    local activeAvg = S.activeTotal >= 5 and S.cum / S.activeTotal or nil
    local use = (rate and rate > 0) and rate or ((activeAvg and activeAvg > 0) and activeAvg or nil)

    if now - S.lastSpark >= SPARK_STEP then
        S.lastSpark = now
        S.spark[#S.spark + 1] = idle and 0 or (rate or 0)
        if #S.spark > SPARK_N then table.remove(S.spark, 1) end
    end

    -- projections
    local adj = math.clamp(req / modelReq(asc), 0.9, 1.1)
    local remaining = math.max(0, req - xp)
    local rname, rn = readReward(all, asc)
    local upTo = math.min(math.max(Target, rn or 0), MAX_TARGET + 1000) - 1
    local pre, acc = {}, 0
    for a = asc + 1, upTo do
        acc += modelReq(a, adj)
        pre[a] = acc
    end
    local function xpTo(t)
        if t <= asc then return 0 end
        local s = remaining
        if t - 1 >= asc + 1 then s += pre[t - 1] or 0 end
        return s
    end

    local goalXP = xpTo(Target)
    local etaGoal = use and goalXP / use or nil
    local r5 = rateOver(300, now)

    local R = {
        asc = asc, xp = xp, req = req,
        rate = idle and 0 or rate,
        remaining = remaining,
        etaNext = use and remaining / use or nil,
        etaGoal = etaGoal,
        ascph = use and use * 3600 / req or nil,
        trend = (rate and rate > 0 and r5 and r5 > 0) and (rate / r5 - 1) or nil,
        idle = idle,
        ascGained = S.ascGained,
        runtime = now - S.startT,
        ms = {},
    }

    if rname then
        R.reward = { name = rname, n = rn, eta = use and xpTo(rn) / use or nil }
    end
    for _, n in ipairs(milestones(asc)) do
        R.ms[#R.ms + 1] = { n = n, eta = use and xpTo(n) / use or nil }
    end

    -- "what if my XP/s keeps growing the way it has been"
    local g, gn = trendGrowth()
    R.g, R.gn = g, gn
    if g and use and asc < Target then
        local t = remaining / use
        for a = asc + 1, Target - 1 do
            t += modelReq(a, adj) / (use * math.exp(g * (a - asc)))
        end
        R.etaTrend = t
    end

    -- insights
    R.dbl = model.r > 1e-6 and math.log(2) / model.r or nil
    R.costGrowth = (math.exp(model.r) - 1) * 100
    R.nextCost = modelReq(asc + 1, adj)
    if Target - 1 > asc then
        R.finalCost = modelReq(Target - 1, adj)
        R.harder = R.finalCost / req
    end
    R.need7 = goalXP / 604800
    R.need30 = goalXP / 2592000
    R.needx = use and R.need30 / use or nil
    if #Errs > 0 then
        local sum = 0
        for _, e in ipairs(Errs) do sum += e end
        R.errAvg, R.errN = sum / #Errs, #Errs
    end

    render(R, nil)
end

task.spawn(function()
    while GUI.Parent do
        local ok, err = pcall(step)
        if not ok then
            render(nil, "Error: " .. tostring(err))
        end
        task.wait(INTERVAL)
    end
end)

print("ASCENSION ANALYTICS V5 INITIALIZED")
