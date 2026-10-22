-- Loads every file of the addon in TOC order against a permissive WoW stub, then
-- drives a fight through the real event handlers and checks what reaches each
-- feed's meter. Run by tests/run.py, which sets ORDER (file names), FILES (name ->
-- source) and FOREVER (true: C_DamageMeter present and the combat log dead).

-- WoW's own table helpers, which the addon uses as globals.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove

local clock = 0
function GetTime() return clock end
local timers = {}
C_Timer = {
    After = function(d, fn) timers[#timers + 1] = { at = clock + math.max(d, 0.001), fn = fn } end,
    NewTicker = function(d, fn) return { Cancel = function() end } end,
    NewTimer = function(d, fn) local t = { Cancel = function(self) self.dead = true end }
        timers[#timers + 1] = { at = clock + d, fn = function() if not t.dead then fn() end end }; return t end,
}

-- Every frame, and anything unknown: a permissive object. Get* answer 0, Is* false.
local frames = {}
local Stub
local function method(name)
    -- GetHighlightTexture and the like hand back a widget, not a number
    if name:find("^Get.*Texture$") then return function() return Stub() end end
    if name:find("^Get") then return function() return 0 end end
    if name:find("^Is") or name:find("^Has") then return function() return false end end
    return function(self, ...) return self end
end
-- Children a template puts on a frame. They exist only where a template made them
-- (TEMPLATES, below), exactly as on a real frame: asking a plain one gives nil.
local CHILDREN = { Instructions = true, Dropdown = true, IncrementButton = true, DecrementButton = true,
                   Label = true, MinText = true, MaxText = true, RightText = true, Slider = true }
local StubMT = {}
StubMT.__index = function(self, k)
    -- Widget methods are capitalised; anything else is a field the addon keeps on
    -- the frame itself, which starts out nil just as on a real frame.
    if type(k) ~= "string" or not k:match("^[A-Z]") or CHILDREN[k] then return nil end
    local m = method(k)
    rawset(self, k, m)
    return m
end
StubMT.__call = function() return Stub() end
function Stub() return setmetatable({}, StubMT) end

local onEvent = {}   -- every frame's OnEvent script, with what it registered
local onUpdate = {}
-- Textures and font strings keep whether they are shown and how faded, as frames do.
local function visible(r)
    r.shown, r.alpha = true, 1
    r.Show = function(self) self.shown = true end
    r.Hide = function(self) self.shown = false end
    r.SetShown = function(self, v) self.shown = v and true or false end
    r.IsShown = function(self) return self.shown ~= false end
    r.SetAlpha = function(self, a) self.alpha = a end
    r.GetAlpha = function(self) return self.alpha end
    return r
end
local function newTexture() return visible(Stub()) end
local function newText()
    local fs = visible(Stub())
    fs.SetText = function(self, t) self.text = t end
    fs.GetText = function(self) return self.text end
    fs.GetStringWidth = function() return 40 end
    fs.GetStringHeight = function() return 12 end
    return fs
end
-- Frames keep what a player could see or set: shown, checked, typed text, scripts.
local function newFrame()
    local f = Stub()
    f.events, f.scripts, f.shown = {}, {}, true
    f.RegisterEvent = function(self, ev) self.events[ev] = true end
    f.RegisterUnitEvent = function(self, ev) self.events[ev] = true end
    f.UnregisterEvent = function(self, ev) self.events[ev] = nil end
    f.SetScript = function(self, what, fn)
        self.scripts[what] = fn
        if what == "OnEvent" then onEvent[self] = fn end
        if what == "OnUpdate" then onUpdate[self] = fn end
        return self
    end
    f.HookScript = function(self, what, fn)
        local old = self.scripts[what]
        self.scripts[what] = old and function(...) old(...); fn(...) end or fn
    end
    f.GetScript = function(self, what) return self.scripts[what] end
    f.Show = function(self)
        if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
    end
    f.Hide = function(self)
        if self.shown then self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    end
    f.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
    f.IsShown = function(self) return self.shown ~= false end
    f.SetChecked = function(self, v) self.checked = v and true or false end
    f.GetChecked = function(self) return self.checked end
    f.SetText = function(self, t) self.text = t end
    f.GetText = function(self) return self.text end
    f.CreateFontString = function() return newText() end
    f.CreateTexture = function() return newTexture() end
    f.SetAlpha = function(self, a) self.alpha = a end
    f.GetAlpha = function(self) return self.alpha or 1 end
    f.SetScale = function(self, v) self.scale = v end
    f.GetScale = function(self) return self.scale or 1 end
    f.GetParent = function(self) return self.parent end
    f.GetFontString = function(self) self.fs = self.fs or newText(); return self.fs end
    f.GetWidth = function() return 100 end
    f.GetHeight = function(self) return self.height or 26 end
    f.SetHeight = function(self, h) self.height = h end
    f.GetStringWidth = function() return 40 end
    frames[#frames + 1] = f
    return f
end

-- Working fakes of the Blizzard templates the settings window is built from, so its
-- main path runs here rather than only its fallbacks.
local function fakeDropdown(dd)
    function dd:SetupMenu(gen) self.gen = gen; self:GenerateMenu() end
    function dd:GenerateMenu()
        local radios = {}
        local root = {
            CreateRadio = function(_, text, isSel, setSel, data)
                radios[#radios + 1] = { text = text, isSel = isSel, setSel = setSel, data = data }
            end,
            CreateDivider = function() end,
        }
        if self.gen then self.gen(self, root) end
        self.radios, self.text = radios, nil
        for _, r in ipairs(radios) do if r.isSel(r.data) then self.text = r.text end end
    end
end
MinimalSliderWithSteppersMixin = { Event = { OnValueChanged = "OnValueChanged" }, Label = { Right = 1 } }
local TEMPLATES = {
    SettingsDropdownWithButtonsTemplate = function(f)
        f.Label = newText()
        f.Dropdown, f.IncrementButton, f.DecrementButton = newFrame(), newFrame(), newFrame()
        fakeDropdown(f.Dropdown)
    end,
    WowStyle1DropdownTemplate = function(f) fakeDropdown(f) end,
    MinimalSliderWithSteppersTemplate = function(f)
        f.Slider, f.MinText, f.MaxText, f.RightText = newFrame(), newText(), newText(), newText()
        f.callbacks = {}
        function f:RegisterCallback(ev, fn, owner) self.callbacks[#self.callbacks + 1] = { fn = fn, owner = owner } end
        function f:Init(value, lo, hi, steps) self.lo, self.hi, self.steps = lo, hi, steps; self:SetValue(value) end
        function f:SetValue(v)
            v = math.min(self.hi or v, math.max(self.lo or v, v))
            self.value = v
            for _, c in ipairs(self.callbacks) do c.fn(c.owner, v) end
        end
        function f:GetValue() return self.value end
    end,
    SearchBoxTemplate = function(f) f.Instructions = newText() end,
}
-- BARE: a client without Blizzard's newer templates or menus, so the window takes
-- its fallbacks (a bare slider, the old dropdown, a plain box for search).
local MODERN = { SettingsDropdownWithButtonsTemplate = true, WowStyle1DropdownTemplate = true,
                 MinimalSliderWithSteppersTemplate = true, SearchBoxTemplate = true }
function CreateFrame(kind, name, parent, template)
    for t in tostring(template or ""):gmatch("[^,%s]+") do
        if BARE and MODERN[t] then error("no such template: " .. t) end
    end
    local f = newFrame()
    f.frameKind, f.parent = kind, parent
    for t in tostring(template or ""):gmatch("[^,%s]+") do
        if TEMPLATES[t] then TEMPLATES[t](f) end
    end
    if kind == "Slider" then
        -- a real slider reports a new value through its OnValueChanged script
        function f:SetMinMaxValues(lo, hi) self.lo, self.hi = lo, hi end
        function f:SetValue(v)
            v = math.min(self.hi or v, math.max(self.lo or v, v))
            self.value = v
            if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
        end
        function f:GetValue() return self.value end
    end
    if name then rawset(_G, name, f) end
    return f
end
-- Blizzard's context menus: what was offered, as items the test can pick from
MenuUtil = {
    CreateContextMenu = function(owner, gen)
        local items = {}
        local root = {
            CreateTitle = function(_, t) items[#items + 1] = { kind = "title", text = t } end,
            CreateButton = function(_, t, fn) items[#items + 1] = { kind = "button", text = t, fn = fn } end,
            CreateCheckbox = function(_, t, isSel, setSel)
                items[#items + 1] = { kind = "check", text = t, isSel = isSel, setSel = setSel }
            end,
            CreateDivider = function() end,
        }
        gen(owner, root)
        lastMenu = items
    end,
}
function ToggleDropDownMenu(_, _, dd) lastLegacyMenu = dd end
-- the old dropdown, for the bare client
local menuButtons
function UIDropDownMenu_Initialize(dd, fn) dd.init = fn end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) if menuButtons then menuButtons[#menuButtons + 1] = info end end
function UIDropDownMenu_SetWidth() end
function UIDropDownMenu_SetText(dd, t) dd.text = t end
function CloseDropDownMenus() end
function legacyMenu(dd)
    menuButtons = {}
    dd.init(dd, 1)
    local out = menuButtons
    menuButtons = nil
    return out
end
UIParent = newFrame()
WorldFrame = newFrame()
UISpecialFrames = {}
StaticPopupDialogs = {}
function StaticPopup_Show(which) lastPopup = which end
function strtrim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function fire(ev, ...)
    for f, fn in pairs(onEvent) do
        if f.events[ev] then fn(f, ev, ...) end
    end
end
local function tick(dt)
    for f, fn in pairs(onUpdate) do fn(f, dt) end
end
local function advance(to)
    while true do
        local idx, best
        for i, t in ipairs(timers) do
            if t.at <= to and (not best or t.at < best.at) then idx, best = i, t end
        end
        if not best then break end
        table.remove(timers, idx)
        clock = best.at
        best.fn()
    end
    clock = to
end

SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end
if FOREVER then C_DamageMeter = {} end
Enum = { PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 } }
function GetLocale() return "enUS" end
function InCombatLockdown() return false end
local target = "Creature-A"
plates = {}   -- other enemies' nameplates: token -> GUID
function UnitGUID(u)
    if u == "target" then return target end
    if u == "player" then return "Player-1" end
    return plates[u]
end
function UnitIsUnit(a, b)
    if plates[a] and b == "target" then return plates[a] == target end
    return a == b
end
function UnitCanAttack(_, u) return plates[u] ~= nil end
function UnitExists(u) return u ~= "pet" end
function UnitName() return "Tester" end
function UnitClass() return "Warlock", "WARLOCK" end
function UnitHealthMax() return 1000 end
function UnitPowerType() return 0 end
function UnitIsDead() return false end
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
local DESC = {
    [686] = "Sends a shadowy bolt at the enemy, causing 13 to 18 Shadow damage.",
    [2050] = "Heal your target for 47 to 58.",
    [172]  = "Corrupts the target, causing 40 Shadow damage over 12 sec.",
}
C_Spell = {
    GetSpellDescription = function(id) return DESC[id] end,
    IsSpellHelpful = function(id) return id == 2050 end,
    GetSpellTexture = function(id) return "tex" .. id end,
    GetSpellName = function(id) return "S" .. id end,
    GetSpellInfo = function(id) return { name = "S" .. id, iconID = "tex" .. id } end,
    GetSpellPowerCost = function(id) return { { type = 0, cost = 25 } } end,
}
C_CVar = { GetCVar = function() return "1" end, SetCVar = function() return true end }
SlashCmdList = {}
GetCVar = C_CVar.GetCVar
-- Anything else the addon touches: a stub, so a load stops only on real errors.
-- Globals this client genuinely lacks: feature detection must see nil.
local ABSENT = {}
if not FOREVER then ABSENT.C_DamageMeter = true end
if BARE then ABSENT.MenuUtil = true; ABSENT.MinimalSliderWithSteppersMixin = true; MinimalSliderWithSteppersMixin = nil; MenuUtil = nil end
setmetatable(_G, { __index = function(_, k)
    -- Constants (COMBATLOG_OBJECT_TYPE_PET, ...) stay undefined: the addon has
    -- numeric fallbacks for them, and a stub table would break the arithmetic.
    -- Lowercase names are Lua's or the test's own (lastMenu): an unknown one is nil,
    -- as in game, never a stub that would read as something being there.
    if type(k) ~= "string" or k:match("^[A-Z0-9_]+$") or k:match("^%l") or ABSENT[k] then return nil end
    return Stub()
end })
-- ...but feature checks must see the truth for these.
rawset(_G, "CombatLogGetCurrentEventInfo", nil)
rawset(_G, "GetSpellTexture", nil)
rawset(_G, "GetSpellInfo", nil)

local ns = {}
local bumps = {}   -- every Bump/BumpMana a feed makes: { feed, mana, key, label, amount, crit, school }
allMeters = {}     -- every meter a feed made, to look inside one afterwards
local function meterOf(feedKey)
    for _, M in ipairs(allMeters) do if M.cfg() == ns.db[feedKey] then return M end end
end
for _, name in ipairs(ORDER) do
    local chunk, err = loadstring(FILES[name], "@" .. name)
    if not chunk then error("load " .. name .. ": " .. tostring(err)) end
    local ok, e = pcall(chunk, "GaruCombatText", ns)
    if not ok then error("run " .. name .. ": " .. tostring(e)) end
    if name == "Meter.lua" then
        -- The feeds keep their meters private; record what each one is fed.
        local New = ns.Meter.New
        ns.Meter.New = function(opts)
            local M = New(opts)
            allMeters[#allMeters + 1] = M
            local function feed()
                for _, k in ipairs({ "enemyText", "healText", "doneText", "takenText", "actionsText" }) do
                    if ns.db and M.cfg() == ns.db[k] then return k end
                end
            end
            local Bump, BumpMana = M.Bump, M.BumpMana
            M.Bump = function(self, frame, key, label, amount, school, crit, icon)
                bumps[#bumps + 1] = { feed = feed(), key = key, label = label, amount = amount, crit = crit, school = school }
                return Bump(self, frame, key, label, amount, school, crit, icon)
            end
            M.BumpMana = function(self, frame, key, label, mana, school, icon)
                bumps[#bumps + 1] = { feed = feed(), mana = true, key = key, amount = mana }
                return BumpMana(self, frame, key, label, mana, school, icon)
            end
            return M
        end
    end
end
local function fed(feed, key, amount, mana)
    for _, b in ipairs(bumps) do
        if b.feed == feed and b.key == key and (amount == nil or b.amount == amount) and (b.mana or false) == (mana or false) then
            return b
        end
    end
end

local pass, fail = 0, 0
local function check(name, ok, why)
    if ok then pass = pass + 1 else fail = fail + 1; print("FAIL  " .. name .. (why and (": " .. why) or "")) end
end

check("Forever flags", (ns.UseUnitCombat == (FOREVER and true or false)) and (ns.CombatLogLive == (not FOREVER)),
      "UseUnitCombat=" .. tostring(ns.UseUnitCombat) .. " CombatLogLive=" .. tostring(ns.CombatLogLive))
check("summary off", ns.SummaryMode == false, tostring(ns.SummaryMode))
check("Actions available", ns.ActionsAvailable == true, tostring(ns.ActionsAvailable))

-- Saved variables arrive, the world loads.
fire("ADDON_LOADED", "GaruCombatText")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
check("db exists", type(ns.db) == "table")
check("anchors exist", ns.frames and ns.frames.target and ns.takenHostFrame and ns.healHostFrame
      and ns.actionsHostFrame and true or false)

check("the defaults count every enemy", ns.db.enemyText.scope == "all" and ns.db.actionsText.scope == "all",
      tostring(ns.db.enemyText.scope) .. " / " .. tostring(ns.db.actionsText.scope))

if FOREVER then
    -- off by default; on, to see the mana paths
    ns.db.healText.showMana, ns.db.enemyText.showMana = true, true
    ns.db.doneText.enabled = true   -- off by default
    -- per target, which the fights below are about (every enemy has its own, further down)
    ns.db.enemyText.scope = "target"; ns.EnemyScopeChanged()
    ns.db.actionsText.scope = "target"; ns.ActionsScopeChanged()
    -- The recorder, switched on the way a player would.
    local slash = SlashCmdList.GARUCOMBATTEXT
    check("/gct is registered", type(slash) == "function")
    local okT, errT = pcall(slash, "trace")
    check("/gct trace turns the recorder on", okT and ns.UC.Tracing(), errT)
    -- Drive a fight through the real handlers. An error inside a feed's
    -- subscriber propagates up to the pcall around each event.
    advance(10)
    fire("PLAYER_REGEN_DISABLED")
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 686)
    advance(11)
    local ok, err = pcall(fire, "UNIT_COMBAT", "target", "WOUND", "CRITICAL", 300, 32)
    check("Damage Dealt path runs", ok, err)
    -- the effects, on that crit: it rolls up, splashes, and flourishes, then settles
    do
        local em0 = meterOf("enemyText")
        local s0 = em0.streams[ns.frames.target]
        local t0 = em0:Trackers(ns.frames.target)["spell:686"]
        check("a crit starts its flourish", t0 and t0.flashT == 0, t0 and tostring(t0.flashT))
        check("a crit jumps further than a hit", t0 and t0.pop > 2, t0 and tostring(t0.pop))
        check("a hit splashes off its row", s0.splashes and #s0.splashes == 1, s0.splashes and tostring(#s0.splashes))
        local okT, errT = pcall(tick, 0.05)
        check("effects draw", okT, errT)
        check("a rolling total is on its way up", t0.shown > 0 and t0.shown < 300, tostring(t0.shown))
        check("the crit's star bursts", t0.burst:IsShown())
        check("the splash shows", s0.splashes[1] and s0.splashes[1].fs:IsShown())
        check("Damage Dealt splashes off the right of its numbers", t0.edgeSide == "right", tostring(t0.edgeSide))
        ns.db.enemyText.splashSide = "LEFT"; tick(0.05)
        check("Splash side: Left", t0.edgeSide == "left", tostring(t0.edgeSide))
        ns.db.enemyText.splashSide = "RIGHT"
        for _ = 1, 25 do tick(0.05) end
        check("the total has rolled all the way", t0.shown == 300, tostring(t0.shown))
        check("the flourish is over", t0.flashT == nil and not t0.burst:IsShown())
        check("the splash has gone", #s0.splashes == 0, tostring(#s0.splashes))
        -- an ordinary hit pops a little; with Pop on each hit off, not at all
        em0:Bump(ns.frames.target, "spell:686", "Shadow Bolt", 10, 32, false, nil)
        check("a hit pops", t0.pop > 1 and t0.pop < 2, tostring(t0.pop))
        ns.db.enemyText.pop = false
        em0:Bump(ns.frames.target, "spell:686", "Shadow Bolt", 10, 32, false, nil)
        check("Pop on each hit off: no jump", t0.pop == 1, tostring(t0.pop))
        ns.db.enemyText.pop = true
        for _ = 1, 25 do tick(0.05) end
        -- Stacked, horizontal: rows side by side, growing right or left from the anchor
        local c = ns.db.enemyText
        c.layout, c.stackDir, c.growthH = "stack", "horizontal", "RIGHT"
        em0:Bump(ns.frames.target, "spell:172", "Corruption", 5, 32, false, nil)
        for _ = 1, 40 do tick(0.05) end
        local big, small = t0, em0:Trackers(ns.frames.target)["spell:172"]
        check("horizontal, growing right: the biggest at the anchor, the next to its right",
              big.curX and small.curX and big.curX >= 0 and small.curX > big.curX and big.curY == 0,
              tostring(big.curX) .. " / " .. tostring(small and small.curX))
        c.growthH = "LEFT"
        for _ = 1, 40 do tick(0.05) end
        check("horizontal, growing left: the next to its left", small.curX < big.curX and big.curX <= 0,
              tostring(big.curX) .. " / " .. tostring(small.curX))
        c.growthH = "CENTER"
        for _ = 1, 60 do tick(0.05) end
        check("horizontal, centred: the line straddles the anchor", big.curX < -5 and small.curX > 5,
              tostring(big.curX) .. " / " .. tostring(small.curX))
        c.layout, c.stackDir, c.growthH = "radial", "vertical", "RIGHT"
        for _ = 1, 40 do tick(0.05) end
    end
    ok, err = pcall(fire, "PLAYER_SWING", nil, 0)
    check("swing path runs", ok, err)
    advance(11.1)
    ok, err = pcall(fire, "UNIT_COMBAT", "target", "DODGE", "", 0, 1)
    check("Actions path runs", ok, err)
    ok, err = pcall(fire, "UNIT_COMBAT", "player", "WOUND", "", 40, 4)
    check("Damage Received path runs", ok, err)
    ok, err = pcall(fire, "UNIT_COMBAT", "player", "DODGE", "", 0, 1)
    check("Taken avoid path runs", ok, err)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 2050)
    advance(11.2)
    ok, err = pcall(fire, "UNIT_COMBAT", "player", "HEAL", "", 55, 2)
    check("Healing path runs", ok, err)
    ok, err = pcall(fire, "UNIT_COMBAT", "player", "ENERGIZE", "", 25, nil)
    check("mana gain path runs", ok, err)
    ok, err = pcall(fire, "UNIT_COMBAT", "target", "WOUND", "", SECRET, 32)
    check("a hidden amount does not error", ok, err)
    for i = 1, 30 do
        ok, err = pcall(tick, 0.05)
        if not ok then break end
    end
    check("meters draw what they were fed (OnUpdate)", ok, err)
    advance(12)
    fire("PLAYER_REGEN_ENABLED")
    for i = 1, 30 do ok, err = pcall(tick, 0.05); if not ok then break end end
    check("after combat", ok, err)
    ok, err = pcall(fire, "PLAYER_TARGET_CHANGED")
    check("target change", ok, err)
    ok, err = pcall(ns.UC.PrintProbe)
    check("/gct probe", ok, err)

    -- A kill, end to end: the killing swing is never reported, the meter settles it
    -- after the fight, and clicking the corpse again shows the whole total.
    advance(20)
    target = "Creature-Z"; fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    fire("PLAYER_SWING", 2.4, 0)
    advance(20.5); fire("UNIT_COMBAT", "target", "WOUND", "", 44, 1)
    advance(23); fire("PLAYER_SWING", 2.4, 0)
    target = nil; fire("PLAYER_TARGET_CHANGED")             -- dies at the swing
    advance(23.3); fire("PLAYER_REGEN_ENABLED")
    ns.DM.TYPES = { damage = 0, taken = 1, healing = 2 }   -- Enum.DamageMeterType, as the client has it
    ns.DM.Capture = function() return { ["spell:6603"] = { id = 6603, amount = 91 } } end
    ok, err = pcall(advance, 30)
    check("settling runs", ok, err)
    target = "Creature-Z"; fire("PLAYER_TARGET_CHANGED")    -- click the corpse
    local em = meterOf("enemyText")
    local tr = em and em:Trackers(ns.frames.target)
    check("the corpse shows the killing blow in its Melee total", tr and tr.swing and tr.swing.total == 91,
          tr and tr.swing and tostring(tr.swing.total) or "no Melee row")
    check("and the skull on Melee, the attack that killed it", tr and tr.swing and tr.swing.kills == 1,
          tr and tr.swing and tostring(tr.swing.kills) or "no Melee row")
    tick(0.05)
    check("the skull is drawn", tr and tr.swing and tr.swing.skull:IsShown())

    -- A killing bolt, end to end: reported on the dying unit's nameplate just after
    -- the target clears, it goes on that unit's totals, live.
    advance(32)
    target = "Creature-Y"; fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 686)
    advance(33); target = nil; fire("PLAYER_TARGET_CHANGED")   -- the bolt kills it
    plates.nameplate6 = "Creature-Y"
    advance(33.03); fire("UNIT_COMBAT", "nameplate6", "WOUND", "", 280, 32)
    advance(33.3); fire("PLAYER_REGEN_ENABLED")
    ns.DM.Capture = function() return { ["spell:686"] = { id = 686, amount = 280 } } end
    ok, err = pcall(advance, 39)
    check("settling after a killing bolt runs", ok, err)
    plates.nameplate6 = nil
    target = "Creature-Y"; fire("PLAYER_TARGET_CHANGED")    -- click the corpse
    tr = em and em:Trackers(ns.frames.target)
    check("the corpse shows the killing bolt, once", tr and tr["spell:686"] and tr["spell:686"].total == 280,
          tr and tr["spell:686"] and tostring(tr["spell:686"].total) or "no Shadow Bolt row")
    check("and the skull on Shadow Bolt", tr and tr["spell:686"] and tr["spell:686"].kills == 1,
          tr and tr["spell:686"] and tostring(tr["spell:686"].kills) or "no Shadow Bolt row")

    -- Every enemy, end to end: one set of totals across a target switch and another
    -- enemy's nameplate, the meter's figures once the fight is over, and a fresh
    -- start on the next fight's first hit.
    ns.db.enemyText.scope = "all"; ns.EnemyScopeChanged()
    local function total(k)
        local t = em:Trackers(ns.frames.target)
        return t and t[k] and t[k].total
    end
    advance(40)
    target = "Creature-G1"; fire("PLAYER_TARGET_CHANGED")
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 686)
    advance(41); fire("UNIT_COMBAT", "target", "WOUND", "", 300, 32)
    fire("PLAYER_REGEN_DISABLED")
    advance(41.5); target = "Creature-G2"; fire("PLAYER_TARGET_CHANGED")   -- on to the next one
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 686)
    advance(42.5); fire("UNIT_COMBAT", "target", "WOUND", "", 250, 32)
    check("every enemy: one total across targets", total("spell:686") == 550, tostring(total("spell:686")))
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 172)                  -- Corruption on G2
    advance(43); target = "Creature-G3"; fire("PLAYER_TARGET_CHANGED")
    plates.nameplate7 = "Creature-G2"
    advance(45.5); fire("UNIT_COMBAT", "nameplate7", "WOUND", "", 12, 32)  -- G2's tick, on its plate
    check("every enemy: a tick on another enemy's nameplate", total("spell:172") == 12, tostring(total("spell:172")))
    advance(47.5); fire("PLAYER_REGEN_ENABLED")
    ns.DM.Capture = function() return { ["spell:686"] = { id = 686, amount = 600 }, ["spell:172"] = { id = 172, amount = 24 } } end
    advance(54)
    check("every enemy: the meter's totals once the fight is over", total("spell:686") == 600 and total("spell:172") == 24,
          tostring(total("spell:686")) .. " / " .. tostring(total("spell:172")))
    advance(60); fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 686)
    advance(61); fire("UNIT_COMBAT", "target", "WOUND", "", 111, 32)
    check("every enemy: the next fight's first hit starts new totals", total("spell:686") == 111 and total("spell:172") == nil,
          tostring(total("spell:686")) .. " / " .. tostring(total("spell:172")))
    plates.nameplate7 = nil
    ns.db.enemyText.scope = "target"; ns.EnemyScopeChanged()

    -- What reached each feed's meter.
    local b = fed("enemyText", "spell:686", 300)
    check("Damage Dealt: Shadow Bolt 300 on its line", b ~= nil)
    check("Damage Dealt: the crit came through", b and b.crit == true, b and tostring(b.crit))
    check("Damage Dealt: its school came through", b and b.school == 32, b and tostring(b.school))
    check("Damage Dealt: mana spent on its line", fed("enemyText", "spell:686", 25, true) ~= nil)
    check("Actions: the dodge", fed("actionsText", "miss:DODGE", 1) ~= nil)
    check("Damage Received: Fire 40 on the Fire line", fed("takenText", "school:4", 40) ~= nil)
    check("Actions: your own dodge, beside the ones your target made", fed("actionsText", "avoid:DODGE", 1) ~= nil)
    check("Damage Received: no avoid rows any more", fed("takenText", "miss:DODGE") == nil and fed("takenText", "avoid:DODGE") == nil)
    do
        local am = meterOf("actionsText")
        am:Bump(ns.actionsHostFrame, "miss:DODGE", "Dodge", 1, 1, false, nil)
        am:Bump(ns.actionsHostFrame, "avoid:DODGE", "Dodge", 1, 1, false, nil)
        local tr2 = am and am:Trackers(ns.actionsHostFrame)
        local theirs, yours = tr2 and tr2["miss:DODGE"], tr2 and tr2["avoid:DODGE"]
        check("Actions: their dodge counts against you, your dodge for you",
              theirs and yours and theirs.good == false and yours.good == true and theirs.isCount and yours.isCount,
              tostring(theirs and theirs.good) .. " / " .. tostring(yours and yours.good))
    end
    check("Healing: Lesser Heal 55 on its line", fed("healText", "spell:2050", 55) ~= nil)
    check("Healing Done: your Lesser Heal on yourself", fed("doneText", "spell:2050", 55) ~= nil)
    local manaBumps = 0
    for _, x in ipairs(bumps) do if x.feed == "healText" and x.mana and x.key == "spell:2050" then manaBumps = manaBumps + 1 end end
    check("Healing: its mana, exactly once", manaBumps == 1, tostring(manaBumps))
    check("Healing: mana gained", fed("healText", "mana:gain", 25) ~= nil)
    -- What the recorder wrote: plain text, the reports and what became of them.
    local lines = ns.db.trace and ns.db.trace.lines or {}
    local function has(pattern)
        for _, l in ipairs(lines) do if l:find(pattern) then return true end end
        return false
    end
    check("trace: the cast", has(" C player 686 32 true "))
    check("trace: the swing's raw payload", has(" S %- 0 main$"))
    check("trace: a report on the target", has(" U target WOUND CRITICAL 300 32$"))
    check("trace: what became of it", has(" > cast spell:686$"))
    check("trace: a hidden amount written as s", has(" U target WOUND \"\" s 32$"))
    check("trace: combat start", has(" R%+$"))
    local okOff = pcall(slash, "trace")
    check("/gct trace again turns it off, lines kept", okOff and not ns.UC.Tracing() and #ns.db.trace.lines > 0)
    if fail > 0 then print("TRACE:\n" .. table.concat(lines, "\n")) end

    local hiddenFed = false
    for _, x in ipairs(bumps) do if x.amount == SECRET then hiddenFed = true end end
    check("a hidden amount never reaches a meter", not hiddenFed)
    if fail > 0 then
        local lines = { ("BUMPS (%d):"):format(#bumps) }
        for _, x in ipairs(bumps) do
            lines[#lines + 1] = ("  %s %s %s %s"):format(tostring(x.feed), x.mana and "mana" or "-", tostring(x.key), tostring(x.amount))
        end
        print(table.concat(lines, "\n"))
    end
    ok, err = pcall(ns.PrintStatus)
    check("/gct status", ok, err)
end

-- The settings window, driven the way a player would: open it, visit every page,
-- work every control, search, switch a feed off and on again, reset.
do
    local function shownRows()
        local out = {}
        for _, f in ipairs(frames) do
            if rawget(f, "row") and f:IsShown() then out[#out + 1] = f end
        end
        return out
    end
    local function frameFor(row)
        for _, f in ipairs(frames) do if rawget(f, "row") == row and f:IsShown() then return f end end
    end
    local function labelled(label)
        for _, f in ipairs(shownRows()) do if f.row.label == label then return f end end
    end
    local function settle() advance(clock + 0.01) end   -- a change redraws a frame later
    local slash = SlashCmdList.GARUCOMBATTEXT
    ns.db.doneText.enabled = true   -- off by default: on, so its page has rows to work
    local ok, err = pcall(slash, "")
    local win = rawget(_G, "GaruCombatTextOptions")
    check("/gct opens the settings window", ok and win and win:IsShown(), err)
    if win then
        local nav, byName = {}, {}
        for _, f in ipairs(frames) do
            if rawget(f, "dot") and rawget(f, "selected") and f.scripts.OnClick then
                nav[#nav + 1] = f
                byName[f.text.text] = f
            end
        end
        check("seven pages in the list", #nav == 7, tostring(#nav))
        local function open(name)
            local b = byName[name]
            if b then b.scripts.OnClick(b); settle() end
            return b ~= nil
        end

        local problems, worked = {}, 0
        for _, b in ipairs(nav) do
            local name = b.text.text
            local okc, errc = pcall(b.scripts.OnClick, b); settle()
            if not okc then problems[#problems + 1] = name .. ": " .. tostring(errc) end
            local rows = {}
            for _, f in ipairs(shownRows()) do rows[#rows + 1] = f.row end
            if #rows == 0 and name ~= "Actions" then problems[#problems + 1] = name .. ": no rows" end
            for _, row in ipairs(rows) do
                local f = frameFor(row)
                if f then
                    local okr, errr = pcall(function()
                        if row.kind == "toggle" then
                            local before = row.get()
                            f.check:SetChecked(not before); f.check.scripts.OnClick(f.check); settle()
                            assert(row.get() == not before, "a click did not change it")
                            local g = frameFor(row)
                            g.check:SetChecked(before); g.check.scripts.OnClick(g.check); settle()
                            assert(row.get() == before, "a second click did not change it back")
                        elseif row.kind == "choice" and f.legacy then
                            local before = row.get()
                            local buttons = legacyMenu(f.legacy)
                            assert(#buttons == #row.choices, "the old menu does not list every choice")
                            for i, info in ipairs(buttons) do
                                info.func(); settle()
                                assert(row.get() == row.choices[i].value, "picking " .. tostring(info.text) .. " did not set it")
                            end
                            row.set(before); settle()
                        elseif row.kind == "choice" then
                            local before = row.get()
                            local radios = f.dropdown and f.dropdown.radios
                            assert(radios and #radios == #row.choices, "its menu does not list every choice")
                            for _, r in ipairs(radios) do
                                r.setSel(r.data); settle()
                                assert(row.get() == r.data, "picking " .. tostring(r.text) .. " did not set it")
                            end
                            row.set(before); settle()
                        elseif row.kind == "slider" then
                            local before = row.get()
                            f.slider:SetValue(row.min); assert(row.get() == row.min, "dragging to the left end")
                            f.slider:SetValue(row.max); assert(row.get() == row.max, "dragging to the right end")
                            f.edit:SetText(tostring(row.min)); f.edit.scripts.OnEnterPressed(f.edit)
                            assert(row.get() == row.min, "typing a value in")
                            f.slider:SetValue(before); row.set(before)
                        elseif row.kind == "button" and row.buttonText ~= "Reset" then
                            f.button.scripts.OnClick(f.button); settle()
                        end
                    end)
                    if okr then worked = worked + 1
                    else problems[#problems + 1] = name .. " / " .. tostring(row.label) .. ": " .. tostring(errr) end
                end
            end
        end
        check("every control on every page works (" .. worked .. " worked)", #problems == 0 and worked > 40,
              table.concat(problems, "; "))
        print(("window: %d controls worked across %d pages"):format(worked, #nav))

        -- The preview: the page's feed, drawn small, fed made-up hits, fitted to its box.
        local pvm
        for _, M in ipairs(allMeters) do if M.strata == "DIALOG" then pvm = M end end
        open("Damage Dealt")
        for _ = 1, 30 do tick(0.05) end
        local pvRows = 0
        for _, s in pairs(pvm and pvm.streams or {}) do for _ in pairs(s.trackers) do pvRows = pvRows + 1 end end
        check("the preview shows Damage Dealt's rows", pvRows == 4, tostring(pvRows))
        local host
        for f in pairs(pvm and pvm.streams or {}) do host = f end
        local r0 = ns.db.enemyText.radius
        ns.db.enemyText.radius = 380; tick(0.05)
        local small = host and host:GetScale()
        ns.db.enemyText.radius = r0; tick(0.05)
        check("a wide arc is drawn smaller to fit", small and small < host:GetScale(),
              tostring(small) .. " vs " .. tostring(host and host:GetScale()))
        open("General")
        check("no preview on a page without a feed", host and not host:GetParent():IsShown())

        -- A row that stops applying goes, and comes back.
        open("Damage Dealt")
        ns.db.enemyText.attach = "player"; ns.RefreshOptions()
        check("pinned to a frame: no Free position", labelled("Free position X") == nil)
        ns.db.enemyText.attach = "free"; ns.RefreshOptions()
        check("free again: Free position is back", labelled("Free position X") ~= nil)

        -- Search finds a setting on every page that has it, with its page above it.
        local search = win.search
        search:SetText("font"); search.scripts.OnTextChanged(search)
        local found, crumbed = 0, 0
        for _, f in ipairs(shownRows()) do
            if f.row.label == "Font size" then
                found = found + 1
                if f.crumb.text and f.crumb.text:find(">") then crumbed = crumbed + 1 end
            end
        end
        check("search: Font size from all six pages, each with its page named", found == 6 and crumbed == 6,
              found .. " found, " .. crumbed .. " with a page")
        check("search: and nothing that does not match", #shownRows() == found,
              #shownRows() .. " rows shown for " .. found .. " matches")
        search:SetText(""); search.scripts.OnTextChanged(search)

        -- Copy to...: from the page you are on to any other feed, or all of them.
        local function copyMenu()
            lastMenu, lastLegacyMenu = nil, nil
            win.copyButton.scripts.OnClick(win.copyButton); settle()
            if lastMenu then return lastMenu end
            local items = {}
            for _, info in ipairs(lastLegacyMenu and legacyMenu(lastLegacyMenu) or {}) do
                items[#items + 1] = { kind = info.isTitle and "title" or (info.isNotRadio and "check" or "button"),
                    text = info.text, fn = info.func, setSel = info.func }
            end
            return items
        end
        local function item(items, text)
            for _, it in ipairs(items) do if it.text == text then return it end end
        end
        local function pick(text) local it = item(copyMenu(), text); assert(it, "no " .. text .. " in the menu"); (it.fn or it.setSel)(); settle() end
        local okCopy, errCopy = pcall(function()
            open("Damage Dealt")
            assert(win.copyButton:IsShown(), "no Copy to on a feed page")
            ns.db.general.copyPosition, ns.db.general.copyMirror = false, false
            ns.db.enemyText.fontSize, ns.db.enemyText.align = 31, "LEFT"
            ns.db.enemyText.point = { "CENTER", 123, 45 }
            ns.db.enemyText.threshold = 777
            ns.db.healText.point = { "CENTER", -50, -30 }
            local items = copyMenu()
            assert(item(items, "Damage Received") and item(items, "Actions") and item(items, "Healing Received")
                and item(items, "All other feeds"), "the menu does not offer every other feed and all")
            assert(not item(items, "Damage Dealt"), "the menu offers the page itself")
            pick("Damage Received")
            assert(ns.db.takenText.fontSize == 31, "copying to one feed")
            assert(ns.db.healText.fontSize ~= 31, "copying to one feed touched another")
            pick("All other feeds")
            assert(ns.db.healText.fontSize == 31 and ns.db.actionsText.fontSize == 31, "copying to all")
            assert(ns.db.healText.point[2] == -50, "the position went along without being asked")
            assert(ns.db.healText.threshold ~= 777, "what a feed counts went along")
            pick("Position too")
            assert(ns.db.general.copyPosition == true, "Position too did not stick")
            pick("Healing Received")
            assert(ns.db.healText.point[2] == 123 and ns.db.healText.align == "LEFT", "Position too")
            pick("Mirror left to right")
            pick("Healing Received")
            assert(ns.db.healText.point[2] == -123 and ns.db.healText.align == "RIGHT", "mirrored to the other side")
            open("Combat Timer")
            assert(not win.copyButton:IsShown(), "Copy to on the timer page")
        end)
        check("Copy to: one feed, all feeds, position, mirrored", okCopy, errCopy)

        -- Nothing done in the window writes to chat: the window shows what changed.
        do
            local realPrint, said = print, {}
            print = function(...) said[#said + 1] = table.concat({ tostringall and tostringall(...) or ... }, " ") end
            local okQuiet, errQuiet = pcall(function()
                win.lock.scripts.OnClick(win.lock); settle()
                win.lock.scripts.OnClick(win.lock); settle()
                win.preview.scripts.OnClick(win.preview); settle()
                win.preview.scripts.OnClick(win.preview); settle()
                open("Damage Dealt")
                pick("All other feeds")
                local f = labelled("Names")
                f.check:SetChecked(not f.row.get()); f.check.scripts.OnClick(f.check); settle()
                StaticPopupDialogs.GARUCOMBATTEXT_RESET.OnAccept(); settle()
            end)
            print = realPrint
            check("the window writes nothing to chat", okQuiet and #said == 0,
                  errQuiet or table.concat(said, " | "))
        end

        -- A feed switched off shows one card; Turn on brings its settings back.
        ns.db.enemyText.enabled = false
        open("Damage Dealt")
        check("a feed that is off has no settings shown", #shownRows() == 0, tostring(#shownRows()))
        local turnOn
        for _, f in ipairs(frames) do if rawget(f, "text") == "Turn on" then turnOn = f end end
        if turnOn then turnOn.scripts.OnClick(turnOn); settle() end
        check("Turn on turns it on and brings its settings back", ns.db.enemyText.enabled == true and #shownRows() > 10)

        -- Reset asks first, then puts everything back.
        open("General")
        local resetRow = labelled("Reset all settings")
        if resetRow then resetRow.button.scripts.OnClick(resetRow.button); settle() end
        check("Reset asks before it resets", lastPopup == "GARUCOMBATTEXT_RESET", tostring(lastPopup))
        ns.db.enemyText.fontSize = 33
        local okReset, errReset = pcall(StaticPopupDialogs.GARUCOMBATTEXT_RESET.OnAccept)
        check("...and resets when told to", okReset and ns.db.enemyText.fontSize ~= 33, errReset)
        open("Healing Received"); open("Healing Cast")
        check("the window still works after a reset", #shownRows() > 10, tostring(#shownRows()))
        win:Hide()
    end
end

if not FOREVER then
    -- Every enemy on Classic: the combat log's hits on any enemy, not just your target.
    local info
    CombatLogGetCurrentEventInfo = function() return unpack(info) end
    local function cleu(destGUID, destFlags, amount)
        info = { 0, "SPELL_DAMAGE", false, "Player-1", "Me", 0x511, 0, destGUID, "Mob", destFlags, 0,
                 133, "Fireball", 4, amount, 0, 4, 0, 0, 0, false }
        fire("COMBAT_LOG_EVENT_UNFILTERED")
    end
    local em = meterOf("enemyText")
    local function fireball()
        local t = em:Trackers(ns.frames.target)
        return t and t["spell:133"] and t["spell:133"].total
    end
    ns.db.enemyText.scope = "target"; ns.EnemyScopeChanged()
    target = "Creature-T"; fire("PLAYER_TARGET_CHANGED")
    cleu("Creature-Other", 0xa48, 70)
    check("Classic, your target: a hit on another enemy is not counted", fireball() == nil, tostring(fireball()))
    ns.db.enemyText.scope = "all"; ns.EnemyScopeChanged()
    cleu("Creature-Other", 0xa48, 70)
    cleu("Creature-T", 0x10a48, 30)
    check("Classic, every enemy: hits on any enemy, one total", fireball() == 100, tostring(fireball()))
    ns.db.enemyText.scope = "target"; ns.EnemyScopeChanged()
    -- Thorns comes through the combat log as DAMAGE_SHIELD
    info = { 0, "DAMAGE_SHIELD", false, "Player-1", "Me", 0x511, 0, "Creature-T", "Mob", 0x10a48, 0,
             782, "Thorns", 8, 6, 0, 8, 0, 0, 0, false }
    fire("COMBAT_LOG_EVENT_UNFILTERED")
    local tt = em:Trackers(ns.frames.target)
    check("Classic: Thorns (DAMAGE_SHIELD) on your target is counted", tt and tt["spell:782"] and tt["spell:782"].total == 6,
          tt and tt["spell:782"] and tostring(tt["spell:782"].total) or "no Thorns row")
    -- Healing Done: your heal on a friend, its effective part (100 less 30 overhealing)
    ns.db.doneText.enabled = true
    info = { 0, "SPELL_HEAL", false, "Player-1", "Me", 0x511, 0, "Player-2", "Friend", 0x514, 0,
             2061, "Flash Heal", 2, 100, 30, 0, false }
    fire("COMBAT_LOG_EVENT_UNFILTERED")
    check("Classic: Healing Done counts your heal on a friend, less overhealing", fed("doneText", "spell:2061", 70) ~= nil)
    -- an attack on you that you avoided, from your target: on Actions, as yours
    info = { 0, "SWING_MISSED", false, "Creature-T", "Mob", 0x10a48, 0, "Player-1", "Me", 0x511, 0, "PARRY" }
    fire("COMBAT_LOG_EVENT_UNFILTERED")
    local at = meterOf("actionsText"):Trackers(ns.actionsHostFrame)
    check("Classic: your parry of your target's swing, on Actions", at and at["avoid:PARRY"] and at["avoid:PARRY"].total == 1,
          at and at["avoid:PARRY"] and tostring(at["avoid:PARRY"].total) or "no Parry row")
    -- your killing blow: PARTY_KILL names you, and the last thing of yours on it gets the skull
    cleu("Creature-T", 0x10a48, 40)
    info = { 0, "PARTY_KILL", false, "Player-1", "Me", 0x511, 0, "Creature-T", "Mob", 0x10a48, 0 }
    fire("COMBAT_LOG_EVENT_UNFILTERED")
    tt = em:Trackers(ns.frames.target)
    check("Classic: a killing blow marks its spell", tt and tt["spell:133"] and tt["spell:133"].kills == 1,
          tt and tt["spell:133"] and tostring(tt["spell:133"].kills) or "no Fireball row")
    CombatLogGetCurrentEventInfo = nil

    -- Classic: the combat-log path is the live one, UnitCombat stays out of it.
    check("no UNIT_COMBAT listener on Classic", (function()
        for f in pairs(onEvent) do if f.events.UNIT_COMBAT then return false end end
        return true
    end)())
    check("CLEU registered on Classic", (function()
        for f in pairs(onEvent) do if f.events.COMBAT_LOG_EVENT_UNFILTERED then return true end end
        return false
    end)())
end

-- Profiles: every setting, anchor and position out as one string, and back in.
do
    local function deep(t) local c = {} for k, v in pairs(t) do c[k] = type(v) == "table" and deep(v) or v end return c end
    local function flat(t, p, acc)
        acc = acc or {}
        for k, v in pairs(t) do
            local key = p .. "." .. tostring(k)
            if type(v) == "table" then flat(v, key, acc) else acc[key] = v end
        end
        return acc
    end
    local function differences(a, b)
        local fa, fb, d = flat(a, ""), flat(b, ""), {}
        for k, v in pairs(fa) do if fb[k] ~= v then d[#d + 1] = k end end
        for k in pairs(fb) do if fa[k] == nil then d[#d + 1] = k end end
        table.sort(d)
        return d
    end
    local function settingsOnly(db)
        local c = deep(db)
        c.trace, c.weaponProcs = nil, nil
        if c.general then c.general.optionsPage = nil end
        return c
    end
    -- a few settings moved off their defaults first, positions included
    ns.db.enemyText.point = { "TOPLEFT", 123, -45 }
    ns.db.healText.fontSize, ns.db.doneText.enabled, ns.db.locked = 22, true, true
    ns.db.combatTimer.point = { "CENTER", 7, -300 }
    ns.db.takenText.barColor = { 0.1, 0.2, 0.3 }
    local saved = settingsOnly(ns.db)
    local okE, s = pcall(ns.Profile.Export)
    check("export: one profile string", okE and type(s) == "string" and s:sub(1, 5) == "GCT1:", tostring(s):sub(1, 40))
    -- everything changed, then the string put back
    ns.db.enemyText.point = { "CENTER", 0, 0 }
    ns.db.healText.fontSize, ns.db.doneText.enabled, ns.db.locked = 9, false, false
    ns.db.actionsText.scope, ns.db.enemyText.radius = "target", 333
    local okI, ok, why = pcall(ns.Profile.Import, s)
    check("import: the string applies", okI and ok, tostring(why))
    local d = differences(saved, settingsOnly(ns.db))
    check("import: every setting and position back exactly as exported", #d == 0, table.concat(d, ", "))
    -- bad strings: refused, and nothing changes
    local before = settingsOnly(ns.db)
    for _, bad in ipairs({ "", "hello", "GCT1:@@@@", "GCT1:" .. ("QUJD"):rep(3), s:sub(1, #s - 12) }) do
        local okB, okb, whyb = pcall(ns.Profile.Import, bad)
        check("import refuses a bad string (" .. bad:sub(1, 12) .. ")", okB and okb == false and type(whyb) == "string" and whyb ~= "",
              okB and tostring(whyb) or tostring(okb))
    end
    check("a refused import changes nothing", #differences(before, settingsOnly(ns.db)) == 0)
    -- another addon's, or a newer version's
    local other = ns.Profile.Encode({ addon = "SomethingElse", version = 1, settings = {} })
    check("import refuses another addon's profile", ns.Profile.Import(other) == false)
    local newer = ns.Profile.Encode({ addon = "GaruCombatText", version = 2, settings = {} })
    check("import refuses a newer version's profile", ns.Profile.Import(newer) == false)
    -- wrong types and unknown keys dropped, missing ones from the defaults
    local odd = ns.Profile.Encode({ addon = "GaruCombatText", version = 1, settings = {
        enemyText = { fontSize = "huge", radius = 99, point = { "CENTER", "x", 5 } }, bogus = { x = 1 } } })
    local okO = ns.Profile.Import(odd)
    check("import keeps what is sound and fills the rest from the defaults",
          okO and ns.db.enemyText.fontSize == ns.defaults.enemyText.fontSize and ns.db.enemyText.radius == 99
          and ns.db.enemyText.point[2] == ns.defaults.enemyText.point[2] and ns.db.bogus == nil
          and ns.db.healText.fontSize == ns.defaults.healText.fontSize,
          tostring(ns.db.enemyText.fontSize) .. " " .. tostring(ns.db.enemyText.radius))
    -- from the settings window
    local win = rawget(_G, "GaruCombatTextOptions")
    local okW, errW = pcall(ns.OpenProfile, "export")
    local pf = rawget(_G, "GaruCombatTextProfile")
    check("the export window shows the string", okW and pf and pf:IsShown() and pf.edit:GetText() == ns.Profile.Export(), errW)
    pcall(ns.OpenProfile, "import")
    pf.edit:SetText(s); pf.action.scripts.OnClick(pf.action)
    check("the import window applies a pasted string", ns.db.enemyText.point[2] == 123, tostring(ns.db.enemyText.point[2]))
    pf.edit:SetText("nonsense"); pf.action.scripts.OnClick(pf.action)
    check("and says why a bad one is refused", (pf.status.text or ""):find("not a Garu Combat Text profile") ~= nil, tostring(pf.status.text))
    pf:Hide()
end

print(("%s: %d passed, %d failed"):format(FOREVER and "Forever" or (BARE and "Classic, bare" or "Classic"), pass, fail))
if fail > 0 then error("failures") end
