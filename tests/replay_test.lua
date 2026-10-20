-- Replays a fight recorded in game with /gct trace (tests/fights/*.txt) through
-- UnitCombat.lua, and checks that every hit on the target was placed as the
-- player's. Run by tests/run.py, which sets UC_SRC (the file's source) and FIGHT
-- (the recording's text).
--
-- The recording keeps what the game said: casts, swings with their payload,
-- UNIT_COMBAT reports, target changes, combat starting and ending. Lines starting
-- ">" are what the matcher decided at the time; they are ignored here, and the
-- current matcher decides afresh. What a spell's description said is rebuilt from
-- the facts the cast line recorded.
--
-- A recording may say "# expect-unplaced: N" when N hits really were someone else's,
-- or could not be placed live (a shield hit whose blow was never reported).

-- WoW's own table helpers, which the addon uses as globals.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove

local clock = 0
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = clock + d, fn = fn } end }
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
    if to > clock then clock = to end
end

SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end
C_DamageMeter = {}
Enum = { PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 } }
function GetLocale() return "enUS" end

local target, class = nil, "WARRIOR"
-- A nameplate's unit is known only where the recorder marked a report on it
-- "dying": the plate of the target that had just cleared.
local plates, cleared = {}, nil
function UnitGUID(u)
    if u == "target" then return target end
    if u == "player" then return "Player-1" end
    return plates[u]
end
function UnitIsUnit(a, b) if a == "target" and b == "player" then return false end return a == b end
-- the recorded fights are against creatures: those can be attacked
function UnitCanAttack(_, u)
    local g = UnitGUID(u)
    return type(g) == "string" and g:find("^Creature") ~= nil
end
function UnitExists(u) if u == "target" then return target ~= nil end return u ~= "pet" end
function UnitName() return "Tester" end
function UnitClass() return "X", class end
inFight = false
function UnitAffectingCombat() return inFight end

-- Descriptions rebuilt from what each cast line recorded about its spell.
local SCHOOL_WORD = { [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature",
                      [16] = "Frost", [32] = "Shadow", [64] = "Arcane" }
local DESC, HELPFUL = {}, {}
local PROC_TEXT = {
    seal    = "Only one Seal can be active. Each melee attack deals 1 %s damage. Unleashing this Seal's energy will judge an enemy.",
    poison  = "Coats a weapon with poison. Each strike has a chance of inflicting 1 %s damage.",
    enchant = "Permanently enchant a melee weapon to often strike for 1 additional %s damage.",
    imbue   = "Imbue the weapon. Each hit causes 1 additional %s damage.",
}
local BOLT_WORD = { [4] = "Fireball", [16] = "Frostbolt", [32] = "Shadow Bolt" }
local function learn(spell, school, direct, ticks, offensive, duration, heals, hot, proc)
    if DESC[spell] ~= nil or HELPFUL[spell] ~= nil then return end
    local dur = duration or 30
    local kind = type(proc) == "string" and proc:match("^proc:(%a+)$")
    if kind then
        if kind == "oil" then
            DESC[spell] = "When applied to a melee weapon it gives a 10% chance of casting "
                .. (BOLT_WORD[school] or "Frostbolt") .. " at the opponent when it hits."
        elseif PROC_TEXT[kind] and SCHOOL_WORD[school] then
            DESC[spell] = PROC_TEXT[kind]:format(SCHOOL_WORD[school])
        end
        return
    end
    if heals then
        HELPFUL[spell] = true
        DESC[spell] = hot and ("Heals the target of 1 damage over " .. dur .. " sec.") or "Heals a friendly target for 1."
    elseif not offensive then
        HELPFUL[spell] = true
        DESC[spell] = "Changes your form."
    elseif school and SCHOOL_WORD[school] then
        local s = SCHOOL_WORD[school]
        if direct and ticks then
            DESC[spell] = "Burns for 1 " .. s .. " damage and then an additional 1 " .. s .. " damage over " .. dur .. " sec."
        elseif ticks then
            DESC[spell] = "Causing 1 " .. s .. " damage over " .. dur .. " sec."
        else
            DESC[spell] = "Causing 1 " .. s .. " damage."
        end
    end
    -- Offensive with no school recorded: left without a description, as an
    -- unloaded or non-English one would be.
end
-- Your damage shields, as the recorder's A lines say: school:spell pairs, or none.
local shieldAuras = {}
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id) return shieldAuras[id] end,
    GetAuraDataByIndex = function() return nil end,
}
C_Spell = {
    GetSpellDescription = function(id) return DESC[id] end,
    IsSpellHelpful = function(id) return HELPFUL[id] or false end,
}

local handlers, ns = {}, {}
function ns.On(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end
function ns.IsSecret(v) return issecretvalue(v) end
function ns.SpellName(id) return "S" .. id end
function ns.SpellTexture(id) return "tex" .. id end
local function fire(ev, ...) for _, fn in ipairs(handlers[ev] or {}) do fn(ev, ...) end end

assert(loadstring(UC_SRC, "@UnitCombat.lua"))("GaruCombatText", ns)

local placed, avoided = {}, 0
ns.UC.Subscribe("dealt", function(r) placed[#placed + 1] = { at = clock, key = r.key, amount = r.amount } end)
ns.UC.Subscribe("avoided", function() avoided = avoided + 1 end)

local function value(word)
    if word == nil or word == "-" then return nil end
    if word == "s" then return SECRET end
    if word == '""' then return "" end
    if word == "true" then return true end
    if word == "false" then return false end
    return tonumber(word) or word
end

local allowed, hits, misses = 0, {}, 0
local offset = 0
for line in FIGHT:gmatch("[^\n]+") do
    local n = line:match("^#%s*expect%-unplaced:%s*(%d+)")
    if n then allowed = tonumber(n) end
    if not line:find("^#") then
        local words = {}
        for w in line:gmatch("%S+") do words[#words + 1] = w end
        local t, kind = tonumber(words[1]), words[2]
        if t and kind then
            -- A /reload starts the recorder's clock again from zero: carry on from
            -- where the replay is, after a gap that lets everything in flight lapse.
            if t + offset < clock then offset = clock + 30 - t end
            t = t + offset
            advance(t)
            if kind == "P" then
                if words[4] then class = words[4] end
                fire("PLAYER_ENTERING_WORLD")   -- a login or /reload
            elseif kind == "T" then
                if value(words[3]) == nil and target then cleared = target end
                target = value(words[3])
                fire("PLAYER_TARGET_CHANGED")
            elseif kind == "R+" then
                inFight = true
                fire("PLAYER_REGEN_DISABLED")
            elseif kind == "R-" then
                inFight = false
                fire("PLAYER_REGEN_ENABLED")
            elseif kind == "C" then
                local unit, spell = words[3], tonumber(words[4])
                if words[5] ~= "auto" then
                    learn(spell, value(words[5]), value(words[6]), value(words[7]), value(words[8]),
                          value(words[9]), value(words[10]), value(words[11]), words[12])
                end
                fire("UNIT_SPELLCAST_SUCCEEDED", unit, "guid", spell)
            elseif kind == "A" then
                shieldAuras = {}
                for i = 3, #words do
                    local spell = tonumber((words[i]:match(":(%d+)$")))
                    if spell then shieldAuras[spell] = { spellId = spell, sourceUnit = "player" } end
                end
                ns.UC.RebuildShields()
            elseif kind == "S" then
                fire("PLAYER_SWING", value(words[3]), value(words[4]))
            elseif kind == "U" then
                local unit, event, flag, amount, school = words[3], words[4], value(words[5]), value(words[6]), value(words[7])
                local dying = words[8] == "dying"
                if dying and unit:find("^nameplate") then plates[unit] = cleared end
                if unit == "target" or dying then
                    if event == "WOUND" and type(amount) == "number" and amount > 0 then
                        -- a killing blow reported on its plate and on target is one hit
                        local last = hits[#hits]
                        if not (last and last.at == t and last.amount == amount and last.unit ~= unit) then
                            hits[#hits + 1] = { at = t, amount = amount, unit = unit }
                        end
                    elseif event ~= "WOUND" or amount == 0 then
                        misses = misses + 1
                    end
                end
                fire("UNIT_COMBAT", unit, event, flag, amount, school)
            end
        end
    end
end
advance(clock + 2)

local missing = #hits - #placed
local parts = {}
for _, p in ipairs(placed) do parts[#parts + 1] = ("%.2f %s %s"):format(p.at, p.key, tostring(p.amount)) end
print("placed: " .. table.concat(parts, ", "))
if missing > allowed then
    local got = {}
    for _, p in ipairs(placed) do got[#got + 1] = p.amount end
    for _, h in ipairs(hits) do
        local found = false
        for i, a in ipairs(got) do if a == h.amount then table.remove(got, i); found = true; break end end
        if not found then print(("FAIL  unplaced: %.2f hit for %d"):format(h.at, h.amount)) end
    end
end
print(("%d passed, %d failed  (%d of %d hits placed, %d misses, %d avoids placed)"):format(
    missing > allowed and 0 or 1, missing > allowed and 1 or 0, #placed, #hits, misses, avoided))
if missing > allowed then error("failures") end
