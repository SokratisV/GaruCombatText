local ADDON, ns = ...

-- Standalone config panel for the combat feed. Open with /gct (or /garucombattext).
-- Two tabs (Damage Dealt / Healing Received). Controls are hand-built so they
-- render identically on the 2.5.5 client (no reliance on Blizzard option templates).

local function RE() if ns.RefreshEnemyText then ns.RefreshEnemyText() end end
local function RH() if ns.RefreshHealText then ns.RefreshHealText() end end
local function RK() if ns.RefreshTakenText then ns.RefreshTakenText() end end
local function RA() if ns.RefreshAnchors then ns.RefreshAnchors() end end
local function RT() if ns.RefreshTimer then ns.RefreshTimer() end end

local ATTACH = { {value="free",text="Free (movable)"}, {value="player",text="Player frame"}, {value="target",text="Target frame"} }
local TIMER_ATTACH = { {value="free",text="Free (movable)"}, {value="enemy",text="Damage Dealt feed"}, {value="taken",text="Damage Taken feed"}, {value="heal",text="Healing feed"} }
local UPDOWN = { {value="UP",text="Up"}, {value="DOWN",text="Down"} }
local ALIGN  = { {value="LEFT",text="Left"}, {value="CENTER",text="Center"}, {value="RIGHT",text="Right"} }
local SORT   = { {value="amount",text="Biggest first"}, {value="lowest",text="Smallest first"}, {value="recent",text="Most recent"} }
local VALUE  = { {value="amount",text="Healing"}, {value="both",text="Both"}, {value="mana",text="Mana only"} }

local ACCENT = { 0.40, 0.78, 1.00 }
local PAD = 14
local uid = 0
local win
local SYNC   -- current page's resync callbacks (each fill* sets this while building)

--------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------
local function Header(c, y, text)
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", PAD, y); fs:SetText(text); fs:SetTextColor(unpack(ACCENT))
    return y - 24
end

local function Checkbox(c, y, label, get, set)
    local cb = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    cb:SetSize(22, 22); cb:SetPoint("TOPLEFT", PAD, y)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("LEFT", cb, "RIGHT", 3, 0); t:SetText(label)
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    if SYNC then SYNC[#SYNC + 1] = function() cb:SetChecked(get()) end end
    return y - 26
end

-- Self-contained slider with a paired numeric input box (type a value + Enter).
-- No reliance on Blizzard's option-slider template, which doesn't draw on 2.5.5.
local function Slider(c, y, label, lo, hi, step, get, set)
    uid = uid + 1
    local cap = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", PAD, y); cap:SetText(label)

    local eb = CreateFrame("EditBox", "GCFEdit" .. uid, c, "InputBoxTemplate")
    eb:SetSize(52, 18); eb:SetPoint("TOPRIGHT", c, "TOPRIGHT", -10, y)
    eb:SetAutoFocus(false); eb:SetMaxLetters(7); eb:SetJustifyH("CENTER")

    local s = CreateFrame("Slider", "GCFSlider" .. uid, c)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(248, 14)
    s:SetPoint("TOPLEFT", PAD, y - 18)
    s:SetHitRectInsets(0, 0, -6, -6)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(step)
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
            s:SetValue(v)              -- fires OnValueChanged -> set() + refresh()
        else
            refresh(s:GetValue())
        end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) refresh(s:GetValue()); self:ClearFocus() end)
    if SYNC then SYNC[#SYNC + 1] = function() local v = get(); s:SetValue(v); refresh(v) end end
    return y - 42
end

local function Dropdown(c, y, label, choices, get, set)
    uid = uid + 1
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", PAD, y); fs:SetText(label)
    local dd = CreateFrame("Frame", "GCFDrop" .. uid, c, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", PAD - 16, y - 16)
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
    return y - 46
end

local function Button(c, y, label, onclick)
    local b = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    b:SetSize(238, 22); b:SetPoint("TOPLEFT", PAD, y - 2)
    b:SetText(label); b:SetScript("OnClick", onclick)
    return y - 30
end

-- Copy the shared layout/style from `src` into `dst`, mirrored to the opposite side:
-- alignment flips L<->R, fine X offset and the free-position X are negated.
local FLIP = { LEFT = "RIGHT", RIGHT = "LEFT" }
local function copyMirror(dst, src)
    for _, k in ipairs({ "growth", "fontSize", "lineSpacing", "maxLines", "sortMode", "showLabel", "showIcon", "schoolColors" }) do
        dst[k] = src[k]
    end
    dst.align   = FLIP[src.align] or src.align
    dst.xOffset = -(src.xOffset or 0)
    dst.yOffset = src.yOffset or 0
    local p = src.point
    if p and type(p[2]) == "number" then dst.point = { p[1] or "CENTER", -p[2], p[3] or 0 } end
end

--------------------------------------------------------------------------
-- Page contents
--------------------------------------------------------------------------
local function fillDamage(c)
    local et = ns.db.enemyText
    local syncs = {}; SYNC = syncs
    local y = -10
    y = Header(c, y, "Damage Dealt (per target)")
    y = Button(c, y, "Copy & mirror from Healing", function()
        copyMirror(et, ns.db.healText); RA(); RE(); RT()
        for _, f in ipairs(syncs) do f() end
    end)
    y = Checkbox(c, y, "Enabled",                   function() return et.enabled end, function(v) et.enabled = v; RE() end)
    y = Dropdown(c, y, "Attach to",        ATTACH,  function() return et.attach end,  function(v) et.attach = v; RA(); RE() end)
    y = Dropdown(c, y, "Text alignment",  ALIGN,   function() return et.align end,   function(v) et.align = v; RE() end)
    y = Dropdown(c, y, "Grow",            UPDOWN,  function() return et.growth end,  function(v) et.growth = v; RT() end)
    y = Slider(c, y, "Fine X offset",   -150, 150, 1, function() return et.xOffset end, function(v) et.xOffset = v; RE() end)
    y = Slider(c, y, "Fine Y offset",   -150, 150, 1, function() return et.yOffset end, function(v) et.yOffset = v; RE() end)
    y = Slider(c, y, "Free position X", -1500, 1500, 1, function() return (et.point and et.point[2]) or 0 end,
        function(v) local p = et.point or {"CENTER",0,0}; et.point = { p[1] or "CENTER", v, p[3] or 0 }; RA() end)
    y = Slider(c, y, "Free position Y", -1000, 1000, 1, function() return (et.point and et.point[3]) or 0 end,
        function(v) local p = et.point or {"CENTER",0,0}; et.point = { p[1] or "CENTER", p[2] or 0, v }; RA() end)
    y = Slider(c, y, "Max sources shown", 1, 12, 1, function() return et.maxLines end, function(v) et.maxLines = v; RT() end)
    y = Slider(c, y, "Font size",   8, 40, 1, function() return et.fontSize end, function(v) et.fontSize = v end)
    y = Slider(c, y, "Line spacing", 8, 60, 1, function() return et.lineSpacing end, function(v) et.lineSpacing = v; RE(); RT() end)
    y = Dropdown(c, y, "Sort order",   SORT,  function() return et.sortMode end, function(v) et.sortMode = v end)
    y = Checkbox(c, y, "Count pet / totem damage",    function() return et.includePet end, function(v) et.includePet = v end)
    y = Checkbox(c, y, "Show source name",            function() return et.showLabel end, function(v) et.showLabel = v end)
    y = Checkbox(c, y, "Show spell icon",             function() return et.showIcon end, function(v) et.showIcon = v end)
    y = Checkbox(c, y, "Show mana spent per spell",   function() return et.showMana end, function(v) et.showMana = v end)
    y = Checkbox(c, y, "Remember each target's totals", function() return et.persist end, function(v) et.persist = v; RE() end)
    y = Checkbox(c, y, "Color by damage school",      function() return et.schoolColors end, function(v) et.schoolColors = v end)
    y = Checkbox(c, y, "Hide Blizzard floating text", function() return et.hideBlizzardFCT end, function(v) et.hideBlizzardFCT = v; RE() end)
    y = Slider(c, y, "Ignore hits below", 0, 3000, 25, function() return et.threshold end, function(v) et.threshold = v end)
    SYNC = nil
    return y
end

local function fillHealing(c)
    local h = ns.db.healText
    local syncs = {}; SYNC = syncs
    local y = -10
    y = Header(c, y, "Healing Received (per spell)")
    y = Button(c, y, "Copy & mirror from Damage", function()
        copyMirror(h, ns.db.enemyText); RA(); RH(); RT()
        for _, f in ipairs(syncs) do f() end
    end)
    y = Checkbox(c, y, "Enabled",                   function() return h.enabled end,  function(v) h.enabled = v; RH() end)
    y = Dropdown(c, y, "Attach to",        ATTACH,  function() return h.attach end,   function(v) h.attach = v; RA(); RH() end)
    y = Dropdown(c, y, "Text alignment",  ALIGN,   function() return h.align end,    function(v) h.align = v; RH() end)
    y = Dropdown(c, y, "Grow",            UPDOWN,  function() return h.growth end,   function(v) h.growth = v; RT() end)
    y = Slider(c, y, "Fine X offset",   -150, 150, 1, function() return h.xOffset end, function(v) h.xOffset = v; RH() end)
    y = Slider(c, y, "Fine Y offset",   -150, 150, 1, function() return h.yOffset end, function(v) h.yOffset = v; RH() end)
    y = Slider(c, y, "Free position X", -1500, 1500, 1, function() return (h.point and h.point[2]) or 0 end,
        function(v) local p = h.point or {"CENTER",0,0}; h.point = { p[1] or "CENTER", v, p[3] or 0 }; RA() end)
    y = Slider(c, y, "Free position Y", -1000, 1000, 1, function() return (h.point and h.point[3]) or 0 end,
        function(v) local p = h.point or {"CENTER",0,0}; h.point = { p[1] or "CENTER", p[2] or 0, v }; RA() end)
    y = Slider(c, y, "Max rows",   1, 12, 1, function() return h.maxLines end, function(v) h.maxLines = v; RT() end)
    y = Slider(c, y, "Font size",  8, 40, 1, function() return h.fontSize end, function(v) h.fontSize = v end)
    y = Slider(c, y, "Line spacing", 8, 60, 1, function() return h.lineSpacing end, function(v) h.lineSpacing = v; RH(); RT() end)
    y = Dropdown(c, y, "Sort order",   SORT,  function() return h.sortMode end,  function(v) h.sortMode = v end)
    y = Dropdown(c, y, "Value shown",  VALUE, function() return h.valueMode end, function(v) h.valueMode = v end)
    y = Checkbox(c, y, "Show source name",           function() return h.showLabel end, function(v) h.showLabel = v end)
    y = Checkbox(c, y, "Show spell icon",            function() return h.showIcon end,  function(v) h.showIcon = v end)
    y = Checkbox(c, y, "Color by spell school",      function() return h.schoolColors end, function(v) h.schoolColors = v end)
    y = Checkbox(c, y, "Show mana spent on heals",   function() return h.showMana end,  function(v) h.showMana = v end)
    y = Checkbox(c, y, "Count mana gains (Innervate, etc.)", function() return h.includeMana end, function(v) h.includeMana = v end)
    y = Slider(c, y, "Ignore heals below", 0, 5000, 25, function() return h.threshold end, function(v) h.threshold = v end)
    y = Slider(c, y, "Rolling window (s)", 1, 30, 1, function() return h.windowSecs end, function(v) h.windowSecs = v end)
    y = Slider(c, y, "Keep after combat (s)", 0, 60, 1, function() return h.holdSecs end, function(v) h.holdSecs = v end)
    SYNC = nil
    return y
end

local function fillTaken(c)
    local tk = ns.db.takenText
    local syncs = {}; SYNC = syncs
    local y = -10
    y = Header(c, y, "Damage Taken (per enemy)")
    y = Button(c, y, "Copy & mirror from Damage Dealt", function()
        copyMirror(tk, ns.db.enemyText); RA(); RK(); RT()
        for _, f in ipairs(syncs) do f() end
    end)
    y = Checkbox(c, y, "Enabled",                   function() return tk.enabled end, function(v) tk.enabled = v; RK() end)
    y = Dropdown(c, y, "Attach to",        ATTACH,  function() return tk.attach end,  function(v) tk.attach = v; RA(); RK() end)
    y = Dropdown(c, y, "Text alignment",  ALIGN,   function() return tk.align end,   function(v) tk.align = v; RK() end)
    y = Dropdown(c, y, "Grow",            UPDOWN,  function() return tk.growth end,  function(v) tk.growth = v; RT() end)
    y = Slider(c, y, "Fine X offset",   -150, 150, 1, function() return tk.xOffset end, function(v) tk.xOffset = v; RK() end)
    y = Slider(c, y, "Fine Y offset",   -150, 150, 1, function() return tk.yOffset end, function(v) tk.yOffset = v; RK() end)
    y = Slider(c, y, "Free position X", -1500, 1500, 1, function() return (tk.point and tk.point[2]) or 0 end,
        function(v) local p = tk.point or {"CENTER",0,0}; tk.point = { p[1] or "CENTER", v, p[3] or 0 }; RA() end)
    y = Slider(c, y, "Free position Y", -1000, 1000, 1, function() return (tk.point and tk.point[3]) or 0 end,
        function(v) local p = tk.point or {"CENTER",0,0}; tk.point = { p[1] or "CENTER", p[2] or 0, v }; RA() end)
    y = Slider(c, y, "Max sources shown", 1, 12, 1, function() return tk.maxLines end, function(v) tk.maxLines = v; RT() end)
    y = Slider(c, y, "Font size",   8, 40, 1, function() return tk.fontSize end, function(v) tk.fontSize = v end)
    y = Slider(c, y, "Line spacing", 8, 60, 1, function() return tk.lineSpacing end, function(v) tk.lineSpacing = v; RK(); RT() end)
    y = Dropdown(c, y, "Sort order",   SORT,  function() return tk.sortMode end, function(v) tk.sortMode = v end)
    y = Checkbox(c, y, "Show source name",            function() return tk.showLabel end, function(v) tk.showLabel = v end)
    y = Checkbox(c, y, "Show spell icon",             function() return tk.showIcon end, function(v) tk.showIcon = v end)
    y = Checkbox(c, y, "Color by damage school",      function() return tk.schoolColors end, function(v) tk.schoolColors = v end)
    y = Checkbox(c, y, "Show misses & avoids (dodge/parry/block/...)", function() return tk.showAvoid end, function(v) tk.showAvoid = v; RK() end)
    y = Slider(c, y, "Ignore hits below", 0, 3000, 25, function() return tk.threshold end, function(v) tk.threshold = v end)
    SYNC = nil
    return y
end

local function fillTimer(c)
    local t = ns.db.combatTimer
    local syncs = {}; SYNC = syncs
    local y = -10
    y = Header(c, y, "Combat Timer")
    y = Checkbox(c, y, "Enabled",  function() return t.enabled end, function(v) t.enabled = v; RT() end)
    y = Dropdown(c, y, "Position", TIMER_ATTACH, function() return t.attach end, function(v) t.attach = v; RT() end)
    y = Slider(c, y, "Font size", 8, 40, 1, function() return t.fontSize end, function(v) t.fontSize = v; RT() end)
    y = Slider(c, y, "Fine X offset", -200, 200, 1, function() return t.xOffset end, function(v) t.xOffset = v; RT() end)
    y = Slider(c, y, "Fine Y offset", -200, 200, 1, function() return t.yOffset end, function(v) t.yOffset = v; RT() end)
    y = Slider(c, y, "Free position X", -1500, 1500, 1, function() return (t.point and t.point[2]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", v, p[3] or 0 }; RT() end)
    y = Slider(c, y, "Free position Y", -1000, 1000, 1, function() return (t.point and t.point[3]) or 0 end,
        function(v) local p = t.point or {"CENTER",0,0}; t.point = { p[1] or "CENTER", p[2] or 0, v }; RT() end)
    local info = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", PAD, y - 4); info:SetWidth(340); info:SetJustifyH("LEFT")
    info:SetText("Shows how long you've been fighting your current target. When attached to a feed it auto-sits past that feed's numbers; Fine offset nudges. 'Free' uses Free position X/Y (or drag it when unlocked).")
    SYNC = nil
    return y - 40
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------
local function makePage(name, fill)
    local scroll = CreateFrame("ScrollFrame", name, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -98)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)
    local c = CreateFrame("Frame", nil, scroll)
    c:SetSize(378, 1)
    scroll:SetScrollChild(c)
    local last = fill(c)
    c:SetHeight(-last + 12)
    scroll:Hide()
    return scroll
end

local tabs = {}
local tabX = 14   -- running x for sequential, auto-width tabs
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
    tabX = tabX + w + 20   -- even gap to the next tab
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
    win = CreateFrame("Frame", "GaruCombatTextOptions", UIParent, "BackdropTemplate")
    win:SetSize(440, 580); win:SetPoint("CENTER"); win:SetFrameStrata("HIGH")
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    win:SetBackdropColor(0.05, 0.05, 0.06, 0.97); win:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "GaruCombatTextOptions")

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
    note:SetText("Preview shows sample numbers at each anchor.  /gct unlock to drag,  /gct reset for defaults.")

    selectTab(1)
    win:Hide()   -- start hidden so the first /gct opens it (frames default to shown)
end

function ns.ToggleOptions()
    build()
    if win:IsShown() then win:Hide() else win:Show() end
end
