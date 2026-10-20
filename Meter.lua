local ADDON, ns = ...

-- Shared "meter" engine behind the Enemy (damage dealt) and Healing (healing
-- received) displays. A meter owns a set of per-frame streams; each stream keeps
-- one recycled "tracker" line per source (a spell, melee, ...) and renders them
-- either as floating Apex-style numbers or as compact damage-meter rows/bars.
--
-- A meter is created with ns.Meter.New{ cfg = <fn returning its db table>,
-- noFade = <bool> }. Clients feed it via :Bump / :BumpMana and manage anchoring
-- and visibility via :Refresh.

ns.Meter = {}

local SCHOOL_COLOR = {
    [1]  = { 1.00, 0.95, 0.80 },  -- Physical
    [2]  = { 1.00, 0.90, 0.50 },  -- Holy
    [4]  = { 1.00, 0.50, 0.10 },  -- Fire
    [8]  = { 0.40, 1.00, 0.40 },  -- Nature
    [16] = { 0.55, 0.95, 1.00 },  -- Frost
    [32] = { 0.55, 0.55, 1.00 },  -- Shadow
    [64] = { 0.95, 0.55, 1.00 },  -- Arcane
}
local NEUTRAL = { 1.00, 0.95, 0.85 }
local CRIT_GOLD = { 1.00, 0.82, 0.25 }
local NEUTRAL_WHITE = { 1, 1, 1 }
local MANA_COLOR = { 0.35, 0.62, 1.00 }
local BURST_TEX = "Interface\\Cooldown\\star4"                       -- the cooldown "bling"
local SKULL_TEX = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"

-- Effects (each feed's own switches; see Options.lua's Effects section):
--   roll       a total counts up to its new value instead of jumping to it
--   splash     each hit floats off its row as +N and fades
--   critFlash  a crit pops bigger, flashes gold, and a star bursts behind it
--   killMark   a skull on the row whose attack killed the enemy (Damage Dealt)
local ROLL_RATE   = 9      -- how fast a rolling total closes the gap (per second)
local SPLASH_LIFE = 0.9    -- how long a splash floats, in seconds
local SPLASH_MAX  = 12     -- splashes in the air at once, per feed
local FLASH_LIFE  = 0.7    -- a crit's gold and its star
local SKULL_IN    = 0.35   -- the skull dropping into place
local AVOID_COLOR = { 0.72, 0.74, 0.80 }   -- miss / dodge / parry / block count rows
local ALIGN_POINT = { LEFT = "LEFT", CENTER = "CENTER", RIGHT = "RIGHT" }
ns.Meter.SCHOOL_COLOR = SCHOOL_COLOR

-- Compact engagement duration: "12s" under a minute, "1:23" past it.
local function fmtDuration(sec)
    sec = math.floor((sec or 0) + 0.5)
    if sec >= 60 then return string.format("%d:%02d", math.floor(sec / 60), sec % 60) end
    return sec .. "s"
end

--------------------------------------------------------------------------
-- Tracker elements (one per source, recycled through a pool)
--------------------------------------------------------------------------
-- A tracker is a positioner frame `f` (scale 1, carries the vertical stack
-- offset) wrapping a `scaler` frame (the one we pop-scale, with a zero offset so
-- scaling never shifts the line). The floating number + icon live on the scaler;
-- a status bar + label live on `f` for the meter style.
local function newTracker(s)
    local f = CreateFrame("Frame", nil, s.container)
    f:SetSize(1, 1)

    -- meter-style status bar, created first so it sits beneath the text/label
    local bar = CreateFrame("StatusBar", nil, f)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints(bar)
    bar.bg:SetColorTexture(0, 0, 0, 0.45)
    bar:Hide()
    f.bar = bar

    -- content layer (the floating number pop-scales this; sits above the bar)
    local g = CreateFrame("Frame", nil, f)
    g:SetSize(1, 1)
    g:SetPoint("CENTER")
    g:SetFrameLevel(bar:GetFrameLevel() + 2)
    f.scaler = g

    f.text = g:CreateFontString(nil, "OVERLAY")   -- the number / amount
    f.text:SetPoint("CENTER")
    f.text:SetShadowColor(0, 0, 0, 1)
    f.text:SetShadowOffset(1, -1)
    f.icon = g:CreateTexture(nil, "OVERLAY")
    f.icon:SetPoint("RIGHT", f.text, "LEFT", -4, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.name = g:CreateFontString(nil, "OVERLAY")   -- meter-style source label
    f.name:SetShadowColor(0, 0, 0, 1)
    f.name:SetShadowOffset(1, -1)
    f.name:SetWordWrap(false)
    f.name:Hide()

    f.manaText = g:CreateFontString(nil, "OVERLAY")  -- mana figure, drawn smaller
    f.manaText:SetShadowColor(0, 0, 0, 1)
    f.manaText:SetShadowOffset(1, -1)
    f.manaText:Hide()

    -- a crit's flourish: a star that bursts out behind the icon and fades
    f.burst = g:CreateTexture(nil, "ARTWORK")
    f.burst:SetTexture(BURST_TEX)
    f.burst:SetBlendMode("ADD")
    f.burst:Hide()

    -- the killing blow's mark, past the number, and how many kills when more than one
    f.skull = g:CreateTexture(nil, "OVERLAY")
    f.skull:SetTexture(SKULL_TEX)
    f.skull:Hide()
    f.skullCount = g:CreateFontString(nil, "OVERLAY")
    f.skullCount:SetShadowColor(0, 0, 0, 1)
    f.skullCount:SetShadowOffset(1, -1)
    f.skullCount:Hide()
    return f
end

local function release(s, key, t)
    t:Hide()
    s.trackers[key] = nil
    s.pool[#s.pool + 1] = t
end

-- Kills, per unit the stream has shown and per row: { [guid] = { [key] = n } }. Kept
-- apart from the remembered totals, so a kill marked before its row exists (a killing
-- swing that is only settled after the fight) still shows once the row comes.
local function killsOf(s, guid)
    if not guid then return nil end
    s.kills = s.kills or {}
    s.kills[guid] = s.kills[guid] or {}
    return s.kills[guid]
end

local function clearSplashes(s)
    for i = #(s.splashes or {}), 1, -1 do
        local sp = s.splashes[i]
        sp.fs:Hide()
        s.splashPool[#s.splashPool + 1] = sp.fs
        s.splashes[i] = nil
    end
end

local function resetStream(s)
    if not s then return end
    for key, t in pairs(s.trackers) do
        t:Hide()
        s.pool[#s.pool + 1] = t
        s.trackers[key] = nil
    end
    s.combatStart, s.lastHit = nil, nil          -- combat-duration tracking
    if s.timeFS then s.timeFS:Hide() end
    clearSplashes(s)
    if s.kills and s.guid then s.kills[s.guid] = nil end
end

--------------------------------------------------------------------------
-- Persistence: remember a frame's running totals by GUID (this session) and
-- restore them when that GUID is selected again. (Used by the enemy meter; inert
-- for the player frame, whose GUID never changes.)
--------------------------------------------------------------------------
local function snapshot(s)
    if not s.guid then return end
    local snap = {}
    for key, t in pairs(s.trackers) do
        snap[key] = { total = t.total, mana = t.mana, label = t.label, school = t.school, iconTex = t.iconTex }
    end
    s.store[s.guid] = snap
    -- the per-target combat timer is remembered alongside the totals
    s.timeStore = s.timeStore or {}
    s.timeStore[s.guid] = s.combatStart and { s.combatStart, s.lastHit } or nil
end

local function restoreInto(s, guid)
    for key, t in pairs(s.trackers) do      -- drop the live (old) lines
        t:Hide(); s.pool[#s.pool + 1] = t; s.trackers[key] = nil
    end
    -- restore this target's combat timer (or clear it if we've not fought it)
    local tw = s.timeStore and s.timeStore[guid]
    s.combatStart = tw and tw[1] or nil
    s.lastHit     = tw and tw[2] or nil
    local snap = s.store[guid]
    if not snap then return end
    local kills = s.kills and s.kills[guid]
    for key, d in pairs(snap) do             -- rebuild from saved totals, no pop
        local t = table.remove(s.pool) or newTracker(s)
        t.key = key
        t.total, t.label, t.school, t.iconTex = d.total, d.label, d.school, d.iconTex
        t.shown = d.total                    -- no count-up for totals coming back
        t.kills, t.killT, t.flashT = kills and kills[key] or 0, nil, nil
        t.mana = d.mana or 0
        t.isMana  = (type(key) == "string" and key:sub(1, 5) == "mana:") or false
        t.isCount = (type(key) == "string" and key:sub(1, 5) == "miss:") or false
        t.curX, t.curY, t.alpha, t.size = nil, nil, 1, nil
        t.last, t.pop, t.popT = GetTime(), 1, 1
        t.appliedAlign = nil
        s.trackers[key] = t
        t:Show()
    end
end

-- Per-target memory is on when the feed asks for it -- and never for a summary,
-- which keeps its own, or for an every-enemy feed, which has one set of totals.
local function persistOn(M)
    return M.cfg().persist and not M.ignorePersist and not (M.isGlobal and M.isGlobal())
end

-- What a frame's stream is keyed by: the unit it shows (your target), or, for an
-- every-enemy feed, one key for the whole fight whoever you have selected.
local function keyOf(M, frame)
    if M.isGlobal and M.isGlobal() then return "all" end
    return UnitGUID(frame.unit)
end

local function switchGUID(M, s, guid)
    -- ignorePersist: the summary keeps its own per-target memory and repaints the
    -- stream itself, so the engine's snapshot store must stay out of the way --
    -- otherwise selecting a second corpse restores the first one's rows on top of
    -- the summary we are about to draw.
    if persistOn(M) then
        snapshot(s)
        s.guid = guid
        restoreInto(s, guid)
    else
        resetStream(s)                            -- non-persist: clears the timer too
        s.guid = guid
    end
end

--------------------------------------------------------------------------
-- Accumulators
--------------------------------------------------------------------------
local function ensureTracker(s, key)
    local t = s.trackers[key]
    if not t then
        t = table.remove(s.pool) or newTracker(s)
        t.key   = key
        t.total = 0
        t.shown = 0     -- what the rolling total shows on its way to .total
        t.flashT = nil  -- a crit's flourish, while it plays
        local kills = s.kills and s.guid and s.kills[s.guid]
        t.kills = kills and kills[key] or 0
        t.killT = nil
        t.mana  = 0
        t.curX  = nil
        t.curY  = nil
        t.alpha = 0
        t.size  = nil
        t.appliedAlign = nil
        t.pop   = 1     -- pop-scale defaults: "settled", so a tracker created via
        t.popT  = 1     -- BumpMana (no bump) doesn't leave popT nil for layoutFloat
        t.casts = 0     -- how many times this spell was cast (for the mana figure)
        t.isMana = false -- a mana-gain line (Mana Tide, Innervate, ...): drawn blue
        t.isCount = false -- a count row (misses/avoids): value shown as "xN"
        -- windowed-meter bookkeeping (see windowUpdate); inert for plain meters
        t.samples    = t.samples or {}
        wipe(t.samples)
        t.windowAmt, t.windowMana, t.windowCasts = 0, 0, 0   -- sums still inside the window
        t.baseAmt,   t.baseMana,   t.baseCasts   = 0, 0, 0   -- folded older sums (accumulate mode)
        s.trackers[key] = t
    end
    return t
end

-- A hit floating off its row: +N in the row's colour (gold for a crit), on the side
-- away from the anchor. Drawn and moved in update (moveSplashes).
local function spawnSplash(M, s, t, amount, crit)
    local cfg = M.cfg()
    s.splashes = s.splashes or {}
    s.splashPool = s.splashPool or {}
    if #s.splashes >= SPLASH_MAX then          -- the oldest makes room
        local old = table.remove(s.splashes, 1)
        old.fs:Hide()
        s.splashPool[#s.splashPool + 1] = old.fs
    end
    local fs = table.remove(s.splashPool)
    if not fs then
        fs = s.container:CreateFontString(nil, "OVERLAY")
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    end
    fs:SetFont(ns.Font(ns.db.general.font), math.max(8, math.floor((cfg.fontSize or 14) * 0.72)), "OUTLINE")
    local c = (crit and cfg.critFlash and CRIT_GOLD) or (t.isMana and MANA_COLOR)
        or (cfg.schoolColors and SCHOOL_COLOR[t.school]) or NEUTRAL
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetText("+" .. ns.FormatNumber(amount))
    fs:SetAlpha(0)
    fs:Show()
    -- hits close together on one row lift off a little apart
    local lane = 0
    for _, sp in ipairs(s.splashes) do
        if sp.t == t and sp.age < 0.3 then lane = lane + 1 end
    end
    s.splashes[#s.splashes + 1] = { fs = fs, t = t, key = t.key, age = 0, lane = lane % 3 }
end

local function bump(M, s, key, label, amount, school, crit, iconTex)
    local cfg = M.cfg()
    local t = ensureTracker(s, key)
    t.label   = label
    t.school  = school
    t.iconTex = iconTex
    t.isMana  = (type(key) == "string" and key:sub(1, 5) == "mana:") or false
    t.isCount = (type(key) == "string" and key:sub(1, 5) == "miss:") or false
    t.last    = GetTime()
    local flourish = crit and cfg.critFlash and not t.isCount
    t.pop     = flourish and 2.0 or ((crit and cfg.crit) and 1.9 or 1.45)
    t.popT    = 0
    if flourish then t.flashT = 0 end
    if cfg.splash and not t.isCount and amount and amount > 0 then spawnSplash(M, s, t, amount, crit) end
    if M.windowed then
        t.samples[#t.samples + 1] = { tm = t.last, amt = amount, mana = 0, casts = 0 }
        t.windowAmt = t.windowAmt + amount
    else
        t.total = t.total + amount
    end
    s.combatStart = s.combatStart or t.last      -- first hit on this target
    s.lastHit = t.last                            -- most recent hit (freezes the timer)
    t:Show()
end

local function bumpMana(M, s, key, label, mana, school, iconTex)
    local t = ensureTracker(s, key)
    if not t.label   then t.label   = label end
    if not t.school  then t.school  = school end
    if not t.iconTex then t.iconTex = iconTex end
    t.last = GetTime()
    if M.windowed then
        t.samples[#t.samples + 1] = { tm = t.last, amt = 0, mana = mana, casts = 1 }
        t.windowMana  = t.windowMana + mana
        t.windowCasts = t.windowCasts + 1
    else
        t.mana  = (t.mana or 0) + mana
        t.casts = (t.casts or 0) + 1
    end
    t:Show()
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------
local function areaWidth(M, s)
    local cfg = M.cfg()
    if cfg.matchFrameWidth and s.frame then
        local w = s.frame:GetWidth()
        if w and w > 1 then return w end
    end
    return cfg.textWidth
end

local function glide(t, targetY, dt)
    if not t.curY then t.curY = targetY end
    t.curY = t.curY + (targetY - t.curY) * math.min(1, dt * 10)
end

-- Displayed main value: the running total, or (when a meter opts in via
-- cfg.valueMode) the value-per-mana ratio, or both. Mana is drawn separately.
local function valueString(t, cfg)
    if t.isCount then return "|cffb9bcc6\195\151" .. (t.total or 0) .. "|r" end   -- "xN"
    local mode = cfg and cfg.valueMode
    if mode == "mana" then            -- show the mana spent (blue), not the healing
        return "|cff599eff" .. ns.FormatNumber(t.mana or 0) .. "|r"
    end
    local amt = ns.FormatNumber(t.shown or t.total)   -- a rolling total, on its way up
    if (mode == "permana" or mode == "both") and (t.mana or 0) > 0 then
        local r  = t.total / t.mana
        local rs = string.format(r >= 10 and "%.0f/m" or "%.1f/m", r)
        return (mode == "both") and (amt .. "  " .. rs) or rs
    end
    return amt
end

-- Shorten a source name to N characters (clipped names get a trailing ellipsis).
-- N <= 0 means "no character cap".
local function abbrevN(label, n)
    if n and n > 0 and label and #label > n then
        return label:sub(1, n) .. "\226\128\166"   -- + ellipsis
    end
    return label
end

-- Manual cap from the options (cfg.maxLabel; 0 = no manual cap).
local function abbrev(label, cfg)
    return abbrevN(label, cfg.maxLabel or 0)
end

-- How many characters of name fit on a float line at this font size, given the
-- area width and the space the number (and icon) already take. Used when the
-- manual cap is 0 ("fit to width"): derives the limit from width + font size
-- instead of a hand-set character count. The meter style needs none of this -
-- its name fontstring is pinned left+right with word-wrap off, so the client
-- truncates it to the available pixels (and font) on its own.
local function autoLabelChars(areaW, fontSize, numberStr, hasIcon)
    local usable = areaW
    if hasIcon then usable = usable - (fontSize + 4) end       -- icon sits left of the text
    local charW = math.max(1, fontSize * 0.58)                 -- ~avg glyph width for the bold font
    local budget = math.floor(usable / charW) - (#(numberStr or "") + 2)  -- 2 = the "  " gap
    return math.max(3, budget)
end

-- Lay out the smaller, tinted mana figure beside a line's main number. `where`
-- is "after" (float: to the right of the amount) or "before" (meter: to the left
-- of the right-aligned amount). When showMana is on it always shows (0 included,
-- so lines stay aligned). Returns the mana fontstring if shown, else nil.
local function layoutMana(t, cfg, where)
    if not cfg.showMana then
        t.manaText:Hide()
        return nil
    end
    local mtxt = ns.FormatNumber(t.mana or 0)
    if t.casts and t.casts > 0 then mtxt = mtxt .. " (" .. t.casts .. ")" end
    t.manaText:SetText(mtxt)
    t.manaText:SetTextColor(MANA_COLOR[1], MANA_COLOR[2], MANA_COLOR[3])
    t.manaText:ClearAllPoints()
    if where == "before" then
        t.manaText:SetPoint("RIGHT", t.text, "LEFT", -5, 0)
    else
        t.manaText:SetPoint("LEFT", t.text, "RIGHT", 5, 0)
    end
    t.manaText:Show()
    return t.manaText
end

-- mana cost of a spell on this client (0 if unknown / not a mana spell)
function ns.Meter.SpellManaCost(spellId)
    if not spellId then return 0 end
    local ok, costs
    if C_Spell and C_Spell.GetSpellPowerCost then
        ok, costs = pcall(C_Spell.GetSpellPowerCost, spellId)
    elseif GetSpellPowerCost then
        ok, costs = pcall(GetSpellPowerCost, spellId)
    end
    if ok and type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 or c.name == "MANA" then return c.cost or 0 end
        end
    end
    return 0
end

-- A crit's flourish, while it plays: the colour to draw the number in (gold, easing
-- back to its own), and the star bursting out behind `around`.
local function flourish(t, c, dt, around, size)
    if not t.flashT then
        t.burst:Hide()
        return c[1], c[2], c[3]
    end
    t.flashT = t.flashT + dt
    local k = t.flashT / FLASH_LIFE
    if k >= 1 then
        t.flashT = nil
        t.burst:Hide()
        return c[1], c[2], c[3]
    end
    local g = (k < 0.4) and 1 or (1 - (k - 0.4) / 0.6)
    if around then
        local bs = size * (1.4 + 2.2 * k)
        t.burst:ClearAllPoints()
        t.burst:SetPoint("CENTER", around, "CENTER", 0, 0)
        t.burst:SetSize(bs, bs)
        t.burst:SetAlpha(0.9 * (1 - k))
        t.burst:Show()
    end
    return c[1] + (CRIT_GOLD[1] - c[1]) * g, c[2] + (CRIT_GOLD[2] - c[2]) * g, c[3] + (CRIT_GOLD[3] - c[3]) * g
end

-- The killing blow's skull, just past `after`, dropping into place when first marked;
-- with a count once that attack has killed more than one. Returns the last thing
-- drawn on the line, for a splash to start from, or nil when there is no skull.
local function layoutSkull(t, cfg, after, size, dt)
    if not (cfg.killMark and (t.kills or 0) > 0) then
        t.skull:Hide(); t.skullCount:Hide()
        return nil
    end
    local sc, alpha = 1, 1
    if t.killT then
        t.killT = t.killT + dt
        local k = t.killT / SKULL_IN
        if k >= 1 then t.killT = nil else sc, alpha = 1 + 1.4 * (1 - k), k end
    end
    local sz = size * 0.95
    t.skull:SetSize(sz * sc, sz * sc)
    t.skull:ClearAllPoints()
    t.skull:SetPoint("LEFT", after, "RIGHT", 4, 0)
    t.skull:SetAlpha(alpha)
    t.skull:Show()
    if t.kills > 1 then
        t.skullCount:SetFont(ns.Font(ns.db.general.font), math.max(6, math.floor(size * 0.62)), "OUTLINE")
        t.skullCount:SetText("\195\151" .. t.kills)   -- "xN"
        t.skullCount:SetTextColor(0.94, 0.58, 0.58)
        t.skullCount:ClearAllPoints()
        t.skullCount:SetPoint("LEFT", t.skull, "RIGHT", 1, 0)
        t.skullCount:Show()
        return t.skullCount
    end
    t.skullCount:Hide()
    return t.skull
end

-- Floating, Apex-style growing numbers.
-- `basis` is what severity scales against: the unit's max HP, or the biggest total
-- in the feed when the client won't hand us a readable max HP (see update()).
local function layoutFloat(s, list, dt, cfg, basis)
    local ap = ALIGN_POINT[cfg.align] or "CENTER"
    local up = (cfg.growth ~= "DOWN")
    local n  = math.min(#list, cfg.maxLines)   -- visible count (for the radial arc spread)
    for i = 1, #list do
        local t = list[i]
        local slot = i - 1
        if slot >= cfg.maxLines then
            t:Hide()
        else
            t:Show()
            if t.appliedMode ~= "float" then
                t.appliedMode, t.appliedAlign, t.size = "float", nil, nil
                t.bar:Hide(); t.name:Hide()
            end

            -- size: grows with the running total relative to the severity basis
            local size = cfg.fontSize
            if cfg.scaleBySeverity then
                local sev = math.min(1, (t.total / basis) / (math.max(1, cfg.bigPct) / 100))
                size = cfg.fontSize + (cfg.maxSize - cfg.fontSize) * sev
            end
            size = math.max(6, size)
            if size ~= t.size then
                t.size = size
                local fontPath = ns.Font(ns.db.general.font)
                t.text:SetFont(fontPath, size, "THICKOUTLINE")
                t.manaText:SetFont(fontPath, math.max(6, math.floor(size * 0.62)), "OUTLINE")
                t.icon:SetSize(size, size)
            end

            if t.appliedAlign ~= cfg.align then
                t.appliedAlign = cfg.align
                t.scaler:ClearAllPoints(); t.scaler:SetPoint(ap, t, ap, 0, 0)
                t.text:ClearAllPoints();   t.text:SetPoint(ap, t.scaler, ap, 0, 0)
                t.text:SetJustifyH(cfg.align)
                t.icon:ClearAllPoints();   t.icon:SetPoint("RIGHT", t.text, "LEFT", -4, 0)
            end

            local c = (t.isCount and AVOID_COLOR) or (t.isMana and MANA_COLOR)
                or (cfg.schoolColors and SCHOOL_COLOR[t.school]) or NEUTRAL
            local hasIcon = cfg.showIcon and t.iconTex
            t.text:SetTextColor(flourish(t, c, dt, hasIcon and t.icon or t.text, size))

            local txt = valueString(t, cfg)
            if cfg.showLabel and t.label then
                local cap = cfg.maxLabel or 0
                if cap <= 0 then
                    cap = autoLabelChars(s.areaW, size, txt, cfg.showIcon and t.iconTex)
                end
                txt = abbrevN(t.label, cap) .. "  " .. txt
            end
            t.text:SetText(txt)
            local mana = layoutMana(t, cfg, "after")

            if hasIcon then
                t.icon:SetTexture(t.iconTex); t.icon:Show()
            else
                t.icon:Hide()
            end

            -- where a splash starts: past the end of the line, or before its start
            -- when the feed lines up on the right (its rows reach out to the left)
            local tail = layoutSkull(t, cfg, mana or t.text, size, dt) or mana or t.text
            if cfg.align == "RIGHT" then
                t.edge, t.edgeSide = hasIcon and t.icon or t.text, "left"
            else
                t.edge, t.edgeSide = tail, "right"
            end

            local sc = 1
            if t.popT < 0.15 then
                t.popT = t.popT + dt
                sc = 1 + (t.pop - 1) * math.max(0, 1 - t.popT / 0.15)
            end
            t.scaler:SetScale(sc)
            t:SetAlpha(t.alpha)

            if cfg.layout == "radial" then
                -- spread the rows along an arc: facing = center angle (90 up / 270 down
                -- / 0 right / 180 left), span = total arc width, radius = distance out.
                local R      = cfg.radius or 90
                local span   = math.rad(cfg.arc or 180)
                local center = math.rad(cfg.arcAngle or 90)
                local ang
                if (not cfg.arcFixed) and n <= 1 then
                    ang = center                          -- single item: middle of the arc
                else
                    local denom = cfg.arcFixed and math.max(1, (cfg.maxLines or 6) - 1) or (n - 1)
                    local frac  = slot / denom
                    -- Map Grow to real screen direction so "Up" always fills upward, no matter
                    -- which way the arc faces: compare the heights of the two arc ends.
                    local up        = (cfg.growth ~= "DOWN")
                    local ascending = math.sin(center + span / 2) >= math.sin(center - span / 2)
                    if up ~= ascending then frac = 1 - frac end
                    ang = center - span / 2 + frac * span
                end
                local tx, ty = R * math.cos(ang), R * math.sin(ang)
                if not t.curX then t.curX = tx end
                if not t.curY then t.curY = ty end
                local lerp = math.min(1, dt * 10)
                t.curX = t.curX + (tx - t.curX) * lerp
                t.curY = t.curY + (ty - t.curY) * lerp
                t:ClearAllPoints()
                t:SetPoint("CENTER", s.container, "CENTER", t.curX, t.curY)
            else
                glide(t, up and (slot * cfg.lineSpacing) or (-slot * cfg.lineSpacing), dt)
                t:ClearAllPoints()
                t:SetPoint(ap, s.container, ap, 0, t.curY)
            end
        end
    end
end

-- Compact, damage-meter style: a row per source with an optional status bar
-- (fill = share of the leading source), label on the left, amount on the right.
local function layoutMeter(s, list, dt, cfg)
    local up   = (cfg.growth ~= "DOWN")
    local rowH = cfg.rowHeight
    local aw   = s.areaW
    local font = ns.Font(ns.db.general.font)
    local tex  = ns.Texture(ns.db.general.texture)
    local iconSz = math.max(4, rowH - 4)
    local fs = math.max(6, math.min(cfg.fontSize, rowH - 2))

    local maxTotal = 1
    for i = 1, #list do if list[i].total > maxTotal then maxTotal = list[i].total end end

    for i = 1, #list do
        local t = list[i]
        local slot = i - 1
        if slot >= cfg.maxLines then
            t:Hide()
        else
            t:Show()
            if t.appliedMode ~= "meter" then
                t.appliedMode, t.size = "meter", nil
                t.scaler:SetScale(1)
                t.icon:Show()
                t.bar:ClearAllPoints();  t.bar:SetPoint("CENTER", t, "CENTER", 0, 0)
                t.bar:SetStatusBarTexture(tex)
                t.text:ClearAllPoints(); t.text:SetPoint("RIGHT", t.bar, "RIGHT", -3, 0)
                t.text:SetJustifyH("RIGHT")
            end

            t.bar:SetSize(aw, rowH)
            if cfg.showBar then t.bar:Show() else t.bar:Hide() end
            t.name:Show()

            if fs ~= t.size then
                t.size = fs
                t.text:SetFont(font, fs, "OUTLINE")
                t.name:SetFont(font, fs, "OUTLINE")
                t.manaText:SetFont(font, math.max(6, math.floor(fs * 0.72)), "OUTLINE")
            end
            t.icon:SetSize(iconSz, iconSz)

            if cfg.showIcon and t.iconTex then
                t.icon:SetTexture(t.iconTex); t.icon:Show()
                t.icon:ClearAllPoints(); t.icon:SetPoint("LEFT", t.bar, "LEFT", 1, 0)
                t.name:ClearAllPoints(); t.name:SetPoint("LEFT", t.icon, "RIGHT", 3, 0)
            else
                t.icon:Hide()
                t.name:ClearAllPoints(); t.name:SetPoint("LEFT", t.bar, "LEFT", 4, 0)
            end

            local c = t.isMana and MANA_COLOR
                or (cfg.schoolColors and SCHOOL_COLOR[t.school]) or cfg.barColor or NEUTRAL
            t.bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)
            t.bar:SetMinMaxValues(0, maxTotal)
            t.bar:SetValue(t.shown or t.total)   -- the bar grows with a rolling total

            t.name:SetText(cfg.showLabel and abbrev(t.label or "", cfg) or "")
            t.name:SetTextColor(0.96, 0.96, 0.96)
            t.text:SetText(valueString(t, cfg))
            t.text:SetTextColor(flourish(t, t.isMana and MANA_COLOR or NEUTRAL_WHITE, dt,
                (cfg.showIcon and t.iconTex) and t.icon or t.text, iconSz))
            local tail = layoutSkull(t, cfg, t.bar, fs, dt)
            t.edge, t.edgeSide = tail or t.bar, "right"

            -- mana sits just left of the amount; the label clips before it
            local mana = layoutMana(t, cfg, "before")
            t.name:SetPoint("RIGHT", mana or t.text, "LEFT", -4, 0)
            t.name:SetJustifyH("LEFT")

            t:SetAlpha(t.alpha)

            glide(t, up and (slot * rowH) or (-slot * rowH), dt)
            t:ClearAllPoints()
            t:SetPoint("CENTER", s.container, "CENTER", 0, t.curY)
        end
    end
end

-- Windowed meters (e.g. the heal display) keep a running sum of only the last
-- `windowSecs` of samples. Samples that age past the window are "folded": while
-- the meter is accumulating (M.rolling == false: in combat / post-combat hold)
-- they move into baseAmt so they still count; once rolling resumes the base is
-- dropped (see M:SetRolling) and only in-window samples remain. Returns true if
-- the tracker is now empty (nothing in window, no base) and may be released.
local function windowUpdate(M, t, now, cfg)
    local horizon = now - (cfg.windowSecs or 5)
    local sm = t.samples
    local drop = 0
    while sm[drop + 1] and sm[drop + 1].tm < horizon do
        local e = sm[drop + 1]
        t.windowAmt   = t.windowAmt   - e.amt
        t.windowMana  = t.windowMana  - e.mana
        t.windowCasts = t.windowCasts - (e.casts or 0)
        if not M.rolling then          -- accumulating: keep aged samples in the base...
            t.baseAmt   = t.baseAmt   + e.amt
            t.baseMana  = t.baseMana  + e.mana
            t.baseCasts = t.baseCasts + (e.casts or 0)
        end                            -- ...rolling: just drop them (base stays clean)
        drop = drop + 1
    end
    if drop > 0 then                       -- compact the list (oldest are at the front)
        local n = #sm
        for j = 1, n - drop do sm[j] = sm[j + drop] end
        for j = n - drop + 1, n do sm[j] = nil end
    end
    if t.windowAmt   < 0 then t.windowAmt   = 0 end
    if t.windowMana  < 0 then t.windowMana  = 0 end
    if t.windowCasts < 0 then t.windowCasts = 0 end

    if M.rolling then
        t.total, t.mana, t.casts = t.windowAmt, t.windowMana, t.windowCasts
        return t.total <= 0 and t.windowMana <= 0 and #sm == 0
    else
        t.total = t.baseAmt  + t.windowAmt
        t.mana  = t.baseMana + t.windowMana
        t.casts = t.baseCasts + t.windowCasts
        return false
    end
end

-- Rolling totals: what each row shows closes in on its real total a little each
-- frame. A total that went down (a rolling window, a correction from the meter)
-- shows its new value at once; counts never roll.
local function rollTotals(list, dt, cfg)
    for i = 1, #list do
        local t = list[i]
        local goal = t.total or 0
        if cfg.roll and not t.isCount then
            local cur = t.shown or goal
            if cur >= goal then
                t.shown = goal
            else
                cur = cur + (goal - cur) * math.min(1, dt * ROLL_RATE)
                if goal - cur < 0.5 then cur = goal end
                t.shown = cur
            end
        else
            t.shown = goal
        end
    end
end

-- Splashes rise and drift away from their row's edge, and fade; one whose row has
-- gone, or gone to another source, goes with it.
local function moveSplashes(s, dt)
    local list = s.splashes
    if not list then return end
    for i = #list, 1, -1 do
        local sp = list[i]
        sp.age = sp.age + dt
        local t = sp.t
        local k = sp.age / SPLASH_LIFE
        if k >= 1 or s.trackers[sp.key] ~= t or not t:IsShown() or not t.edge then
            sp.fs:Hide()
            s.splashPool[#s.splashPool + 1] = sp.fs
            table.remove(list, i)
        else
            local a = (k < 0.12) and (k / 0.12) or (1 - (k - 0.12) / 0.88)
            sp.fs:SetAlpha(a * (t:GetAlpha() or 1))
            local dx, dy = 6 + 18 * k, 2 + 18 * k - sp.lane * 9
            sp.fs:ClearAllPoints()
            if t.edgeSide == "left" then
                sp.fs:SetPoint("RIGHT", t.edge, "LEFT", -dx, dy)
            else
                sp.fs:SetPoint("LEFT", t.edge, "RIGHT", dx, dy)
            end
        end
    end
end

local function update(M, s, dt)
    local cfg = M.cfg()
    local now = GetTime()

    -- Severity scaling wants the unit's max HP, but on Midnight / WoW Forever that
    -- comes back as a secret once we're tainted: comparing it throws, and dividing
    -- by it yields another secret that could never reach SetFont. Fall back to the
    -- biggest total currently in the feed (computed below, after the list is built)
    -- -- that's our own combat-log tally, so it is always a plain number.
    local maxhp = UnitHealthMax(s.frame.unit)
    if ns.IsSecret(maxhp) or not maxhp or maxhp <= 0 then maxhp = nil end

    local aw = areaWidth(M, s)
    if s.areaW ~= aw then s.areaW = aw; s.container:SetWidth(aw) end

    local noFade = M.noFade or persistOn(M)

    local list = s.sorted
    wipe(list)
    for key, t in pairs(s.trackers) do
        if M.windowed then
            if windowUpdate(M, t, now, cfg) then
                release(s, key, t)              -- fully aged out of the rolling window
            else
                t.alpha = math.min(1, (t.alpha or 0) + dt * 8)
                list[#list + 1] = t
            end
        else
            local age = now - t.last
            if not noFade and age > cfg.holdTime then
                local fp = (age - cfg.holdTime) / math.max(0.05, cfg.fadeTime)
                if fp >= 1 then
                    release(s, key, t)
                else
                    t.alpha = 1 - fp
                    list[#list + 1] = t
                end
            else
                t.alpha = math.min(1, (t.alpha or 0) + dt * 8)
                list[#list + 1] = t
            end
        end
    end

    if cfg.sortMode == "recent" then
        table.sort(list, function(a, b) return a.last > b.last end)
    elseif cfg.sortMode == "lowest" then
        table.sort(list, function(a, b) return a.total < b.total end)
    else
        table.sort(list, function(a, b) return a.total > b.total end)
    end

    -- Severity basis: the unit's max HP when we're allowed to read it, otherwise the
    -- largest total on show. Scaling then reads as "relative to the biggest number in
    -- this feed" rather than "relative to the target's health pool" -- the top line
    -- always sits at max size -- which is the closest thing to the intent that a
    -- secret max HP leaves us.
    local basis = maxhp
    if not basis then
        basis = 1
        for i = 1, #list do
            local v = list[i].total
            if v and v > basis then basis = v end
        end
    end

    rollTotals(list, dt, cfg)
    if cfg.style == "meter" then
        layoutMeter(s, list, dt, cfg)
    else
        layoutFloat(s, list, dt, cfg, basis)
    end
    moveSplashes(s, dt)

    -- Combat-duration header (clients opt in via cfg.showCombatTime, e.g. Damage
    -- Dealt). Counts from the first hit on this target; freezes at the last hit
    -- once you stop dealing damage to it. Sits just past the growth end of the stack.
    if s.timeFS then
        if #list == 0 then s.combatStart, s.lastHit = nil, nil end   -- stream emptied: reset timer
        if cfg.showCombatTime and s.combatStart then
            local endT = (s.lastHit and (now - s.lastHit) > 3) and s.lastHit or now
            local lh = (cfg.style == "meter") and (cfg.rowHeight or 14) or (cfg.lineSpacing or 18)
            local n  = math.min(#list, cfg.maxLines or #list)
            local up = (cfg.growth ~= "DOWN")
            s.timeFS:SetFont(ns.Font(ns.db.general.font), math.max(8, (cfg.fontSize or 14) - 2), "OUTLINE")
            s.timeFS:SetText("Combat " .. fmtDuration(endT - s.combatStart))
            s.timeFS:SetTextColor(0.95, 0.85, 0.45)
            s.timeFS:ClearAllPoints()
            s.timeFS:SetPoint("CENTER", s.container, "CENTER", 0, (up and 1 or -1) * (n * lh))
            s.timeFS:Show()
        else
            s.timeFS:Hide()
        end
    end

    -- Summary mode: the feed is a report with a lifetime rather than a live stream,
    -- so the whole stack dims out together as its window closes instead of each row
    -- ageing out on its own. The owner clears once the window has actually run out;
    -- this only paints the last moment of it.
    if M.expireAt then
        local left = M.expireAt - now
        local over = M.expireOver or 0.5
        s.container:SetAlpha(left < over and math.max(0, left) / over or 1)
    else
        s.container:SetAlpha(1)
    end
end

local function anchorStream(M, s)
    local cfg = M.cfg()
    s.areaW = areaWidth(M, s)
    s.container:SetWidth(s.areaW)
    s.container:ClearAllPoints()
    -- Pin the text's alignment edge to the anchor point, so Left/Center/Right place
    -- the numbers relative to that point. Radial centers on the point (arc around it).
    local ap = (cfg.layout == "radial") and "CENTER" or (ALIGN_POINT[cfg.align] or "CENTER")
    s.container:SetPoint(ap, s.frame, "CENTER", cfg.xOffset, cfg.yOffset)
end

local function getStream(M, frame)
    if not frame then return nil end
    local s = M.streams[frame]
    if s then return s end
    s = { frame = frame, pool = {}, trackers = {}, sorted = {}, store = {} }
    s.container = CreateFrame("Frame", nil, frame)
    s.container:SetSize(16, 16)   -- a sized frame reliably fires OnUpdate
    s.container:SetFrameStrata(M.strata or "HIGH")
    if M.strata then s.container:SetFrameLevel(frame:GetFrameLevel() + 5) end
    s.container:SetScript("OnUpdate", function(_, dt) update(M, s, dt) end)
    s.timeFS = s.container:CreateFontString(nil, "OVERLAY")   -- combat-duration header
    s.timeFS:SetShadowColor(0, 0, 0, 1); s.timeFS:SetShadowOffset(1, -1)
    s.timeFS:Hide()
    M.streams[frame] = s
    anchorStream(M, s)
    return s
end

--------------------------------------------------------------------------
-- Public constructor
--------------------------------------------------------------------------
function ns.Meter.New(opts)
    -- strata: drawn on this layer rather than HIGH (the settings window's preview)
    local M = { streams = {}, cfg = opts.cfg, noFade = opts.noFade,
                windowed = opts.windowed, rolling = true, strata = opts.strata }

    -- Toggle the rolling X-second window on/off. While off (in combat, or the
    -- post-combat hold) the meter accumulates and nothing ages out; turning it
    -- back on discards the accumulated base so the display collapses to just the
    -- samples still inside the window ("the last X seconds").
    function M:SetRolling(on)
        on = on and true or false
        if M.rolling == on then return end
        M.rolling = on
        if on then
            for _, s in pairs(M.streams) do
                for _, t in pairs(s.trackers) do t.baseAmt, t.baseMana, t.baseCasts = 0, 0, 0 end
            end
        end
    end

    -- route to the frame's stream, handling the per-GUID save/restore
    function M:Stream(frame)
        local s = getStream(M, frame)
        if not s then return nil end
        local curGUID = keyOf(M, frame)
        if s.guid ~= curGUID then switchGUID(M, s, curGUID) end
        return s
    end

    function M:Bump(frame, key, label, amount, school, crit, iconTex)
        local s = self:Stream(frame); if not s then return nil end
        bump(M, s, key, label, amount, school, crit, iconTex)
        return s
    end

    function M:BumpMana(frame, key, label, mana, school, iconTex)
        local s = self:Stream(frame); if not s then return nil end
        bumpMana(M, s, key, label, mana, school, iconTex)
        return s
    end

    -- Add to the totals of one particular unit, on screen or not: a killing blow
    -- settled after the fight (UnitCombat.lua), when the dead unit may no longer be
    -- your target. Off screen it goes into what is remembered for that unit, so it
    -- shows when the unit is selected again; with per-target memory off there is
    -- nowhere to keep it, and it is dropped.
    function M:BumpGUID(frame, guid, key, label, amount, school, crit, iconTex)
        local s = getStream(M, frame)
        if not s or not guid then return end
        if s.guid == guid then
            bump(M, s, key, label, amount, school, crit, iconTex)
            return
        end
        if not persistOn(M) then return end
        local snap = s.store[guid]
        if not snap then snap = {}; s.store[guid] = snap end
        local d = snap[key]
        if d then
            d.total = (d.total or 0) + amount
        else
            snap[key] = { total = amount, mana = 0, label = label, school = school, iconTex = iconTex }
        end
    end

    -- The attack under `key` killed the unit `guid` (nil: whatever the stream shows
    -- now, as for an every-enemy feed, whose one set of totals covers every kill).
    -- Its row gets the skull, now or once that unit is selected again.
    function M:MarkKill(frame, guid, key)
        local s = getStream(M, frame)
        if not s or not key then return end
        local g = guid
        if g == nil or (M.isGlobal and M.isGlobal()) then g = s.guid end
        if g ~= s.guid and not persistOn(M) then return end   -- nowhere to keep it
        local kills = killsOf(s, g)
        if not kills then return end
        kills[key] = (kills[key] or 0) + 1
        if g == s.guid then
            local t = s.trackers[key]
            if t then t.kills, t.killT = kills[key], 0 end
        end
    end

    -- Set a row to a known total: the meter's figure for the whole fight, once it
    -- ends (UnitCombat.lua). A correction, not a hit: no pop, and it does not start
    -- a new fight's totals.
    function M:SetTotal(frame, key, label, total, school, iconTex)
        local s = self:Stream(frame)
        if not s or not total then return end
        local t = s.trackers[key]
        if t then
            t.total = total
        elseif total > 0 then
            bump(M, s, key, label, total, school, false, iconTex)
            s.trackers[key].pop, s.trackers[key].popT = 1, 1
        end
    end

    -- re-sync a frame to its current GUID (e.g. on target change)
    function M:Retarget(frame)
        local s = frame and M.streams[frame]
        -- only on a real change: an every-enemy feed keeps its key, and switching
        -- to the same key would reset a stream that has no per-target memory
        if s then
            local key = keyOf(M, frame)
            if s.guid ~= key then switchGUID(M, s, key) end
        end
    end

    function M:Clear()
        for _, s in pairs(M.streams) do resetStream(s) end
    end

    -- Clear, and forget the per-GUID snapshots with it. Plain Clear empties what is
    -- on screen but leaves the store, so the next target switch would restore an
    -- earlier fight's rows. The summary owns its own memory and wants neither.
    function M:Forget()
        for _, s in pairs(M.streams) do
            resetStream(s)
            wipe(s.store)
            if s.timeStore then wipe(s.timeStore) end
            if s.kills then wipe(s.kills) end
            s.guid = nil
        end
    end

    -- Dim the feed out as `at` (a GetTime stamp) approaches, over `over` seconds.
    -- Passing nil goes back to full opacity.
    function M:SetExpiry(at, over)
        M.expireAt, M.expireOver = at, over
    end

    function M:Trackers(frame)
        local s = M.streams[frame]
        return s and s.trackers
    end

    -- current combat timing for a frame's stream: combatStart, lastHit (or nil)
    function M:CombatInfo(frame)
        local s = M.streams[frame]
        if not s then return nil end
        return s.combatStart, s.lastHit
    end

    -- ensure streams exist for `frames`, anchor all, and show/hide via allowed()
    function M:Refresh(frames, allowed)
        if frames then
            for _, f in ipairs(frames) do if f then getStream(M, f) end end
        end
        for frame, s in pairs(M.streams) do
            anchorStream(M, s)
            if allowed(frame) then
                s.container:Show()
            else
                s.container:Hide()
                resetStream(s)
            end
        end
    end

    return M
end

--------------------------------------------------------------------------
-- Every-enemy scope
--------------------------------------------------------------------------
-- A feed that is per target can instead count everything you hit, as one set of
-- totals for the fight. It is kept up through the fight and for holdSecs after it,
-- then fades; the next fight's first hit clears it and starts again. That first
-- hit, rather than combat starting, because the opening blow is reported just
-- before the game says combat began (/gct trace, 18 Oct 2026), and clearing then
-- would throw it away.
--   cfgKey: the feed's settings; its .scope is "target" or "all".
-- Gives the meter M:isGlobal(), M:Fresh() (call before adding anything: clears the
-- last fight if this is the first of a new one) and M:ScopeChanged().
function ns.Meter.AddScope(M, cfgKey)
    local inCombat, gen, fresh = false, 0, false
    M.isGlobal = function()
        local c = ns.db and ns.db[cfgKey]
        return c ~= nil and c.scope == "all"
    end
    function M:Fresh()
        if fresh and M.isGlobal() then
            fresh = false
            M:Clear()
            M.noFade = true   -- a fight is starting: hold its rows, whatever combat says yet
        end
    end
    function M:ScopeChanged()
        gen, fresh = gen + 1, false
        M.noFade = nil
        M:Clear()
    end
    ns.On("PLAYER_REGEN_DISABLED", function()
        inCombat, gen = true, gen + 1
        if M.isGlobal() then M.noFade = true end
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        inCombat, gen = false, gen + 1
        if not M.isGlobal() then return end
        fresh = true                       -- the next hit starts a new fight
        local g = gen
        local hold = (ns.db[cfgKey].holdSecs or 8)
        C_Timer.After(hold, function()
            if g == gen and not inCombat and M.isGlobal() then M.noFade = nil end
        end)
    end)
end

