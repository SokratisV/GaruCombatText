local ADDON, ns = ...

-- Standalone config panel. Open with /gct (or /garucombattext).
-- Controls live in row-containers and are laid out dynamically: settings that don't
-- apply to the current mode (free vs pinned, stacked vs radial) are hidden and the
-- rest re-flow to close the gap.

local function RE() if ns.RefreshEnemyText then ns.RefreshEnemyText() end end
local function RH() if ns.RefreshHealText then ns.RefreshHealText() end end
local function RK() if ns.RefreshTakenText then ns.RefreshTakenText() end end
local function RA() if ns.RefreshAnchors then ns.RefreshAnchors() end end
local function RT() if ns.RefreshTimer then ns.RefreshTimer() end end

local ATTACH = { {value="free",text="Free (movable)"}, {value="player",text="Player frame"}, {value="target",text="Target frame"} }
local TIMER_ATTACH = { {value="free",text="Free (movable)"}, {value="enemy",text="Damage Dealt feed"}, {value="taken",text="Damage Taken feed"}, {value="heal",text="Healing feed"} }
local UPDOWN = { {value="UP",text="Up"}, {value="DOWN",text="Down"} }
local ALIGN  = { {value="LEFT",text="Left"}, {value="CENTER",text="Center"}, {value="RIGHT",text="Right"} }
local LAYOUT = { {value="stack",text="Stacked (line)"}, {value="radial",text="Radial (arc)"} }
local FACING = { {value=90,text="Up"}, {value=270,text="Down"}, {value=0,text="Right"}, {value=180,text="Left"} }
local SORT   = { {value="amount",text="Biggest first"}, {value="lowest",text="Smallest first"}, {value="recent",text="Most recent"} }
local VALUE  = { {value="amount",text="Healing"}, {value="both",text="Both"}, {value="mana",text="Mana only"} }

local ACCENT = { 0.40, 0.78, 1.00 }
local PAD = 14
local CW  = 378
local uid = 0
local win
local SYNC   -- current page's value-resync callbacks (for Copy & mirror)
local PAGE   -- current page's ordered rows: { {frame, h, vis}, ... }

--------------------------------------------------------------------------
-- Controls (each lives in its own row container; vis is an optional predicate)
--------------------------------------------------------------------------
local function addRow(c, h, vis)
    local row = CreateFrame("Frame", nil, c)
    row:SetSize(CW, h)
    PAGE[#PAGE + 1] = { frame = row, h = h, vis = vis }
    return row
end

local function Header(c, text, vis)
    local row = addRow(c, 24, vis)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", PAD, 0); fs:SetText(text); fs:SetTextColor(unpack(ACCENT))
end

local function Note(c, text, vis)
    local row = addRow(c, 44, vis)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", PAD, -2); fs:SetWidth(CW - 24); fs:SetJustifyH("LEFT"); fs:SetText(text)
end

local function Button(c, label, onclick, vis)
    local row = addRow(c, 30, vis)
    local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    b:SetSize(238, 22); b:SetPoint("TOPLEFT", PAD, -2)
    b:SetText(label); b:SetScript("OnClick", onclick)
end

local function Checkbox(c, label, get, set, vis)
    local row = addRow(c, 26, vis)
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(22, 22); cb:SetPoint("TOPLEFT", PAD, 0)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("LEFT", cb, "RIGHT", 3, 0); t:SetText(label)
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    if SYNC then SYNC[#SYNC + 1] = function() cb:SetChecked(get()) end end
end

local function Slider(c, label, lo, hi, step, get, set, vis)
    uid = uid + 1
    local row = addRow(c, 42, vis)
    local cap = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", PAD, 0); cap:SetText(label)

    local eb = CreateFrame("EditBox", "GCFEdit" .. uid, row, "InputBoxTemplate")
    eb:SetSize(52, 18); eb:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, 0)
    eb:SetAutoFocus(false); eb:SetMaxLetters(7); eb:SetJustifyH("CENTER")

    local s = CreateFrame("Slider", "GCFSlider" .. uid, row)
    s:SetOrientation("HORIZONTAL"); s:SetSize(248, 14); s:SetPoint("TOPLEFT", PAD, -18)
    s:SetHitRectInsets(0, 0, -6, -6); s:SetMinMaxValues(lo, hi); s:SetValueStep(step)
    pcall(s.SetObeyStepOnDrag, s, true)

    local track = s:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(0.30, 0.30, 0.34, 0.9); track:SetHeight(4)
    track:SetPoint("LEFT", s, "LEFT", 0, 0); track:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1); thumb:SetSize(10, 16)
    s:SetThumbTexture(thumb)

    local function fmt(v) return step < 1 and string.format("%.2f", v) or tostring(math.floor(v + 0.5)) end
    local function refresh(v) eb:SetText(fmt(v)); eb:SetCursorPosition(0) end
    s:SetValue(get()); refresh(get())
    s:SetScript("OnValueChanged", function(_, v)
        if step >= 1 then v = math.floor(v + 0.5) end
        set(v); refresh(v)
    end)
    eb:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v then
            if v < lo then v = lo elseif v > hi then v = hi end
            s:SetValue(v)
        else
            refresh(s:GetValue())
        end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) refresh(s:GetValue()); self:ClearFocus() end)
    if SYNC then SYNC[#SYNC + 1] = function() local v = get(); s:SetValue(v); refresh(v) end end
end

local function Dropdown(c, label, choices, get, set, vis)
    uid = uid + 1
    local row = addRow(c, 46, vis)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", PAD, 0); fs:SetText(label)
    local dd = CreateFrame("Frame", "GCFDrop" .. uid, row, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", PAD - 16, -16)
    UIDropDownMenu_SetWidth(dd, 150)
    local function setText() for _, o in ipairs(choices) do if o.value == get() then UIDropDownMenu_SetText(dd, o.text); return end end end
    UIDropDownMenu_Initialize(dd, function(_, level)
        for _, o in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.checked = o.text, (o.value == get())
            info.func = function() set(o.value); setText(); CloseDropDownMenus() end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    setText()
    if SYNC then SYNC[#SYNC + 1] = setText end
end

--------------------------------------------------------------------------
-- Copy & mirror, and the shared layout / free-position control groups
--------------------------------------------------------------------------
local FLIP = { LEFT = "RIGHT", RIGHT = "LEFT" }
local ARCFLIP = { [0] = 180, [180] = 0 }
local function copyMirror(dst, src)
    for _, k in ipairs({ "growth", "fontSize", "lineSpacing", "maxLines", "sortMode", "showLabel", "showIcon", "schoolColors", "layout", "radius", "arc" }) do
        dst[k] = src[k]
    end
    dst.align    = FLIP[src.align] or src.align
    dst.arcAngle = ARCFLIP[src.arcAngle] or src.arcAngle
    dst.xOffset  = -(src.xOffset or 0)
    dst.yOffset  = src.yOffset or 0
    local p = src.point
    if p and type(p[2]) == "number" then dst.point = { p[1] or "CENTER", -p[2], p[3] or 0 } end
end

-- Layout dropdown + the stack-only and radial-only sub-settings.
local function LayoutControls(c, t, refresh, reflow)
    local stackVis  = function() return t.layout ~= "radial" end
    local radialVis = function() return t.layout == "radial" end
    Dropdown(c, "Layout", LAYOUT, function() return t.layout end, function(v) t.layout = v; refresh(); reflow() end)
    Dropdown(c, "Text alignment", ALIGN, function() return t.align end, function(v) t.align = v; refresh() end, stackVis)
    Dropdown(c, "Grow", UPDOWN, function() return t.growth end, function(v) t.growth = v; RT() end, stackVis)
    Slider(c, "Line spacing", 8, 60, 1, function() return t.lineSpacing end, function(v) t.lineSpacing = v; refresh(); RT() end, stackVis)
    Slider(c, "Arc radius", 20, 400, 2, function() return t.radius end, function(v) t.radius = v end, radialVis)
    Slider(c, "Arc span (deg)", 20, 360, 5, function() return t.arc end, function(v) t.arc = v end, radialVis)
    Dropdown(c, "Arc facing", FACING, function() return t.arcAngle end, function(v) t.arcAngle = v end, radialVis)
end

-- Free-position X/Y, shown only while the feed is in Free (movable) mode.
local function FreeControls(c, t)
    local freeVis = function() return t.attach == "free" end
    Slider(c, "Free position X", -1500, 1500, 1, function() return (t.point and t.point[2]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", v, p[3] or 0 }; RA() end, freeVis)
    Slider(c, "Free position Y", -1000, 1000, 1, function() return (t.point and t.point[3]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", p[2] or 0, v }; RA() end, freeVis)
end

--------------------------------------------------------------------------
-- Page contents
--------------------------------------------------------------------------
local function fillDamage(c, reflow)
    local et = ns.db.enemyText
    local syncs = {}; SYNC = syncs
    Header(c, "Damage Dealt (per target)")
    Button(c, "Copy & mirror from Healing", function()
        copyMirror(et, ns.db.healText); RA(); RE(); RT()
        for _, f in ipairs(syncs) do f() end; reflow()
    end)
    Checkbox(c, "Enabled", function() return et.enabled end, function(v) et.enabled = v; RE() end)
    Dropdown(c, "Attach to", ATTACH, function() return et.attach end, function(v) et.attach = v; RA(); RE(); reflow() end)
    LayoutControls(c, et, RE, reflow)
    FreeControls(c, et)
    Slider(c, "Fine X offset", -150, 150, 1, function() return et.xOffset end, function(v) et.xOffset = v; RE() end)
    Slider(c, "Fine Y offset", -150, 150, 1, function() return et.yOffset end, function(v) et.yOffset = v; RE() end)
    Slider(c, "Max sources shown", 1, 12, 1, function() return et.maxLines end, function(v) et.maxLines = v; RT() end)
    Slider(c, "Font size", 8, 40, 1, function() return et.fontSize end, function(v) et.fontSize = v end)
    Dropdown(c, "Sort order", SORT, function() return et.sortMode end, function(v) et.sortMode = v end)
    Checkbox(c, "Count pet / totem damage", function() return et.includePet end, function(v) et.includePet = v end)
    Checkbox(c, "Show source name", function() return et.showLabel end, function(v) et.showLabel = v end)
    Checkbox(c, "Show spell icon", function() return et.showIcon end, function(v) et.showIcon = v end)
    Checkbox(c, "Show mana spent per spell", function() return et.showMana end, function(v) et.showMana = v end)
    Checkbox(c, "Remember each target's totals", function() return et.persist end, function(v) et.persist = v; RE() end)
    Checkbox(c, "Color by damage school", function() return et.schoolColors end, function(v) et.schoolColors = v end)
    Checkbox(c, "Hide Blizzard floating text", function() return et.hideBlizzardFCT end, function(v) et.hideBlizzardFCT = v; RE() end)
    Slider(c, "Ignore hits below", 0, 3000, 25, function() return et.threshold end, function(v) et.threshold = v end)
    SYNC = nil
end

local function fillTaken(c, reflow)
    local tk = ns.db.takenText
    local syncs = {}; SYNC = syncs
    Header(c, "Damage Taken (by type)")
    Button(c, "Copy & mirror from Damage Dealt", function()
        copyMirror(tk, ns.db.enemyText); RA(); RK(); RT()
        for _, f in ipairs(syncs) do f() end; reflow()
    end)
    Checkbox(c, "Enabled", function() return tk.enabled end, function(v) tk.enabled = v; RK() end)
    Dropdown(c, "Attach to", ATTACH, function() return tk.attach end, function(v) tk.attach = v; RA(); RK(); reflow() end)
    LayoutControls(c, tk, RK, reflow)
    FreeControls(c, tk)
    Slider(c, "Fine X offset", -150, 150, 1, function() return tk.xOffset end, function(v) tk.xOffset = v; RK() end)
    Slider(c, "Fine Y offset", -150, 150, 1, function() return tk.yOffset end, function(v) tk.yOffset = v; RK() end)
    Slider(c, "Max sources shown", 1, 12, 1, function() return tk.maxLines end, function(v) tk.maxLines = v; RT() end)
    Slider(c, "Font size", 8, 40, 1, function() return tk.fontSize end, function(v) tk.fontSize = v end)
    Dropdown(c, "Sort order", SORT, function() return tk.sortMode end, function(v) tk.sortMode = v end)
    Checkbox(c, "Show attack name", function() return tk.showLabel end, function(v) tk.showLabel = v end)
    Checkbox(c, "Show spell icon", function() return tk.showIcon end, function(v) tk.showIcon = v end)
    Checkbox(c, "Color by damage school", function() return tk.schoolColors end, function(v) tk.schoolColors = v end)
    Checkbox(c, "Show misses & avoids (dodge/parry/block/...)", function() return tk.showAvoid end, function(v) tk.showAvoid = v; RK() end)
    Slider(c, "Ignore hits below", 0, 3000, 25, function() return tk.threshold end, function(v) tk.threshold = v end)
    SYNC = nil
end

local function fillHealing(c, reflow)
    local h = ns.db.healText
    local syncs = {}; SYNC = syncs
    Header(c, "Healing Received (per spell)")
    Button(c, "Copy & mirror from Damage Dealt", function()
        copyMirror(h, ns.db.enemyText); RA(); RH(); RT()
        for _, f in ipairs(syncs) do f() end; reflow()
    end)
    Checkbox(c, "Enabled", function() return h.enabled end, function(v) h.enabled = v; RH() end)
    Dropdown(c, "Attach to", ATTACH, function() return h.attach end, function(v) h.attach = v; RA(); RH(); reflow() end)
    LayoutControls(c, h, RH, reflow)
    FreeControls(c, h)
    Slider(c, "Fine X offset", -150, 150, 1, function() return h.xOffset end, function(v) h.xOffset = v; RH() end)
    Slider(c, "Fine Y offset", -150, 150, 1, function() return h.yOffset end, function(v) h.yOffset = v; RH() end)
    Slider(c, "Max rows", 1, 12, 1, function() return h.maxLines end, function(v) h.maxLines = v; RT() end)
    Slider(c, "Font size", 8, 40, 1, function() return h.fontSize end, function(v) h.fontSize = v end)
    Dropdown(c, "Sort order", SORT, function() return h.sortMode end, function(v) h.sortMode = v end)
    Dropdown(c, "Value shown", VALUE, function() return h.valueMode end, function(v) h.valueMode = v end)
    Checkbox(c, "Show source name", function() return h.showLabel end, function(v) h.showLabel = v end)
    Checkbox(c, "Show spell icon", function() return h.showIcon end, function(v) h.showIcon = v end)
    Checkbox(c, "Color by spell school", function() return h.schoolColors end, function(v) h.schoolColors = v end)
    Checkbox(c, "Show mana spent on heals", function() return h.showMana end, function(v) h.showMana = v end)
    Checkbox(c, "Count mana gains (Innervate, etc.)", function() return h.includeMana end, function(v) h.includeMana = v end)
    Slider(c, "Ignore heals below", 0, 5000, 25, function() return h.threshold end, function(v) h.threshold = v end)
    Slider(c, "Rolling window (s)", 1, 30, 1, function() return h.windowSecs end, function(v) h.windowSecs = v end)
    Slider(c, "Keep after combat (s)", 0, 60, 1, function() return h.holdSecs end, function(v) h.holdSecs = v end)
    SYNC = nil
end

local function fillTimer(c, reflow)
    local t = ns.db.combatTimer
    local syncs = {}; SYNC = syncs
    local freeVis = function() return t.attach == "free" end
    Header(c, "Combat Timer")
    Checkbox(c, "Enabled", function() return t.enabled end, function(v) t.enabled = v; RT() end)
    Dropdown(c, "Position", TIMER_ATTACH, function() return t.attach end, function(v) t.attach = v; RT(); reflow() end)
    Slider(c, "Font size", 8, 40, 1, function() return t.fontSize end, function(v) t.fontSize = v; RT() end)
    Slider(c, "Fine X offset", -200, 200, 1, function() return t.xOffset end, function(v) t.xOffset = v; RT() end)
    Slider(c, "Fine Y offset", -200, 200, 1, function() return t.yOffset end, function(v) t.yOffset = v; RT() end)
    Slider(c, "Free position X", -1500, 1500, 1, function() return (t.point and t.point[2]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", v, p[3] or 0 }; RT() end, freeVis)
    Slider(c, "Free position Y", -1000, 1000, 1, function() return (t.point and t.point[3]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", p[2] or 0, v }; RT() end, freeVis)
    Note(c, "How long you've been fighting your current target. Attached to a feed it auto-sits past that feed's numbers; Fine offset nudges. 'Free' uses Free position X/Y (or drag it when unlocked).")
    SYNC = nil
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------
local function relayout(c, rows)
    local y = -10
    for _, e in ipairs(rows) do
        if (not e.vis) or e.vis() then
            e.frame:ClearAllPoints()
            e.frame:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
            e.frame:Show()
            y = y - e.h
        else
            e.frame:Hide()
        end
    end
    c:SetHeight(-y + 12)
    local sf = c:GetParent()
    if sf and sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
end

local function makePage(name, fill)
    local scroll = CreateFrame("ScrollFrame", name, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -98)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)
    local c = CreateFrame("Frame", nil, scroll)
    c:SetSize(CW, 1)
    scroll:SetScrollChild(c)
    PAGE = {}
    local rows = PAGE
    local function reflow() relayout(c, rows) end
    fill(c, reflow)
    reflow()
    scroll:Hide()
    return scroll
end

local tabs = {}
local tabX = 14
local function selectTab(i)
    for j, t in ipairs(tabs) do
        t.scroll:SetShown(j == i)
        t.label:SetTextColor(j == i and ACCENT[1] or 0.7, j == i and ACCENT[2] or 0.7, j == i and ACCENT[3] or 0.7)
        t.underline:SetShown(j == i)
    end
end

local function makeTab(i, text, scroll)
    local b = CreateFrame("Button", nil, win)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("LEFT", 1, 0); b.label:SetText(text)
    local w = math.ceil(b.label:GetStringWidth()) + 4
    b:SetSize(w, 22); b:SetPoint("TOPLEFT", tabX, -68)
    tabX = tabX + w + 20
    b.underline = b:CreateTexture(nil, "OVERLAY")
    b.underline:SetColorTexture(unpack(ACCENT)); b.underline:SetHeight(2)
    b.underline:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, -3)
    b.underline:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, -3)
    b.scroll = scroll
    b:SetScript("OnClick", function() selectTab(i) end)
    tabs[i] = b
end

local function build()
    if win then return end
    win = CreateFrame("Frame", "GarUICombatFeedOptions", UIParent, "BackdropTemplate")
    win:SetSize(440, 580); win:SetPoint("CENTER"); win:SetFrameStrata("DIALOG")   -- above the feeds (HIGH) so it covers them
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    win:SetBackdropColor(0.05, 0.05, 0.06, 0.97); win:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "GarUICombatFeedOptions")

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12); title:SetText("|cff66ccffGaru Combat Text|r")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local unlock = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    unlock:SetSize(22, 22); unlock:SetPoint("TOPLEFT", 12, -36)
    local ut = unlock:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ut:SetPoint("LEFT", unlock, "RIGHT", 3, 0); ut:SetText("Unlock anchors (drag the markers to move)")
    unlock:SetChecked(not ns.db.locked)
    unlock:SetScript("OnClick", function(self) if ns.SetLocked then ns.SetLocked(not self:GetChecked()) end end)

    local dmg   = makePage("GCFScrollDamage", fillDamage)
    local taken = makePage("GCFScrollTaken", fillTaken)
    local heal  = makePage("GCFScrollHealing", fillHealing)
    local timer = makePage("GCFScrollTimer", fillTimer)
    tabX = 14
    makeTab(1, "Damage Dealt", dmg)
    makeTab(2, "Damage Taken", taken)
    makeTab(3, "Healing", heal)
    makeTab(4, "Timer", timer)

    local testBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    testBtn:SetSize(100, 22); testBtn:SetPoint("BOTTOMRIGHT", -12, 10)
    local function updTest() testBtn:SetText(ns.test.combat and "Preview: ON" or "Preview") end
    testBtn:SetScript("OnClick", function()
        ns.test.combat = not ns.test.combat
        if not ns.test.combat then
            if ns.ClearEnemyText then ns.ClearEnemyText() end
            if ns.ClearHealText then ns.ClearHealText() end
            if ns.ClearTakenText then ns.ClearTakenText() end
        end
        updTest()
    end)
    testBtn:SetScript("OnShow", updTest)
    updTest()

    local note = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 14, 15); note:SetPoint("RIGHT", testBtn, "LEFT", -8, 0); note:SetJustifyH("LEFT")
    note:SetText("Only the settings that apply to the current mode are shown.  /gct unlock to drag.")

    selectTab(1)
    win:Hide()   -- start hidden so the first /gct opens it (frames default to shown)
end

function ns.ToggleOptions()
    build()
    if win:IsShown() then win:Hide() else win:Show() end
end
