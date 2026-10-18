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
-- A recording may say "# expect-unplaced: N" when N hits really were someone else's.

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
function UnitGUID(u) if u == "target" then return target end if u == "player" then return "Player-1" end end
function UnitIsUnit(a, b) if a == "target" and b == "player" then return false end return a == b end
function UnitExists(u) if u == "target" then return target ~= nil end return u ~= "pet" end
function UnitName() return "Tester" end
function UnitClass() return "X", class end

-- Descriptions rebuilt from what each cast line recorded about its spell.
local SCHOOL_WORD = { [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature",
                      [16] = "Frost", [32] = "Shadow", [64] = "Arcane" }
local DESC, HELPFUL = {}, {}
local function learn(spell, school, direct, ticks, offensive, duration, heals, hot)
    if DESC[spell] ~= nil or HELPFUL[spell] ~= nil then return end
    local dur = duration or 30
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
for line in FIGHT:gmatch("[^\n]+") do
    local n = line:match("^#%s*expect%-unplaced:%s*(%d+)")
    if n then allowed = tonumber(n) end
    if not line:find("^#") then
        local words = {}
        for w in line:gmatch("%S+") do words[#words + 1] = w end
        local t, kind = tonumber(words[1]), words[2]
        if t and kind then
            advance(t)
            if kind == "P" then
                if words[4] then class = words[4] end
            elseif kind == "T" then
                target = value(words[3])
                fire("PLAYER_TARGET_CHANGED")
            elseif kind == "R+" then
                fire("PLAYER_REGEN_DISABLED")
            elseif kind == "R-" then
                fire("PLAYER_REGEN_ENABLED")
            elseif kind == "C" then
                local unit, spell = words[3], tonumber(words[4])
                if words[5] ~= "auto" then
                    learn(spell, value(words[5]), value(words[6]), value(words[7]), value(words[8]),
                          value(words[9]), value(words[10]), value(words[11]))
                end
                fire("UNIT_SPELLCAST_SUCCEEDED", unit, "guid", spell)
            elseif kind == "S" then
                fire("PLAYER_SWING", value(words[3]), value(words[4]))
            elseif kind == "U" then
                local unit, event, flag, amount, school = words[3], words[4], value(words[5]), value(words[6]), value(words[7])
                if unit == "target" then
                    if event == "WOUND" and type(amount) == "number" and amount > 0 then
                        hits[#hits + 1] = { at = t, amount = amount }
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
