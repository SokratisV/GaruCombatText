-- Loads every file of the addon in TOC order against a permissive WoW stub, then
-- drives a fight through the real event handlers and checks what reaches each
-- feed's meter. Run by tests/run.py, which sets ORDER (file names), FILES (name ->
-- source) and FOREVER (true: C_DamageMeter present and the combat log dead).

local clock = 0
function GetTime() return clock end
local timers = {}
C_Timer = {
    After = function(d, fn) timers[#timers + 1] = { at = clock + d, fn = fn } end,
    NewTicker = function(d, fn) return { Cancel = function() end } end,
    NewTimer = function(d, fn) local t = { Cancel = function(self) self.dead = true end }
        timers[#timers + 1] = { at = clock + d, fn = function() if not t.dead then fn() end end }; return t end,
}

-- Every frame, and anything unknown: a permissive object. Get* answer 0, Is* false.
local frames = {}
local Stub
local function method(name)
    if name:find("^Get") then return function() return 0 end end
    if name:find("^Is") or name:find("^Has") then return function() return false end end
    return function(self, ...) return self end
end
local StubMT = {}
StubMT.__index = function(self, k)
    -- Widget methods are capitalised; anything else is a field the addon keeps on
    -- the frame itself, which starts out nil just as on a real frame.
    if type(k) ~= "string" or not k:match("^[A-Z]") then return nil end
    local m = method(k)
    rawset(self, k, m)
    return m
end
StubMT.__call = function() return Stub() end
function Stub() return setmetatable({}, StubMT) end

local onEvent = {}   -- every frame's OnEvent script, with what it registered
local onUpdate = {}
local function newFrame()
    local f = Stub()
    f.events = {}
    f.RegisterEvent = function(self, ev) self.events[ev] = true end
    f.RegisterUnitEvent = function(self, ev) self.events[ev] = true end
    f.UnregisterEvent = function(self, ev) self.events[ev] = nil end
    f.SetScript = function(self, what, fn)
        if what == "OnEvent" then onEvent[self] = fn end
        if what == "OnUpdate" then onUpdate[self] = fn end
        return self
    end
    f.GetScript = function() return nil end
    f.CreateFontString = function() return Stub() end
    f.CreateTexture = function() return Stub() end
    f.IsShown = function() return true end
    f.GetWidth = function() return 100 end
    f.GetStringWidth = function() return 40 end
    frames[#frames + 1] = f
    return f
end
function CreateFrame() return newFrame() end
UIParent = newFrame()
WorldFrame = newFrame()

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
function UnitGUID(u) if u == "target" then return target end if u == "player" then return "Player-1" end end
function UnitIsUnit(a, b) return a == b end
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
setmetatable(_G, { __index = function(_, k)
    -- Constants (COMBATLOG_OBJECT_TYPE_PET, ...) stay undefined: the addon has
    -- numeric fallbacks for them, and a stub table would break the arithmetic.
    if type(k) ~= "string" or k:match("^[A-Z0-9_]+$") or ABSENT[k] then return nil end
    return Stub()
end })
-- ...but feature checks must see the truth for these.
rawset(_G, "CombatLogGetCurrentEventInfo", nil)
rawset(_G, "GetSpellTexture", nil)
rawset(_G, "GetSpellInfo", nil)

local ns = {}
local bumps = {}   -- every Bump/BumpMana a feed makes: { feed, mana, key, label, amount, crit, school }
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
            local function feed()
                for _, k in ipairs({ "enemyText", "healText", "takenText", "actionsText" }) do
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

if FOREVER then
    ns.db.healText.showMana = true   -- off by default; on, to see the mana path
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
    ok, err = pcall(fire, "PLAYER_SWING", nil, 0)
    check("swing path runs", ok, err)
    advance(11.1)
    ok, err = pcall(fire, "UNIT_COMBAT", "target", "DODGE", "", 0, 1)
    check("Actions path runs", ok, err)
    ok, err = pcall(fire, "UNIT_COMBAT", "player", "WOUND", "", 40, 4)
    check("Damage Taken path runs", ok, err)
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

    -- What reached each feed's meter.
    local b = fed("enemyText", "spell:686", 300)
    check("Damage Dealt: Shadow Bolt 300 on its line", b ~= nil)
    check("Damage Dealt: the crit came through", b and b.crit == true, b and tostring(b.crit))
    check("Damage Dealt: its school came through", b and b.school == 32, b and tostring(b.school))
    check("Damage Dealt: mana spent on its line", fed("enemyText", "spell:686", 25, true) ~= nil)
    check("Actions: the dodge", fed("actionsText", "miss:DODGE", 1) ~= nil)
    check("Damage Taken: Fire 40 on the Fire line", fed("takenText", "school:4", 40) ~= nil)
    check("Damage Taken: your dodge as an avoid row", fed("takenText", "miss:DODGE", 1) ~= nil)
    check("Healing: Lesser Heal 55 on its line", fed("healText", "spell:2050", 55) ~= nil)
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

if not FOREVER then
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

print(("%s: %d passed, %d failed"):format(FOREVER and "Forever" or "Classic", pass, fail))
if fail > 0 then error("failures") end
