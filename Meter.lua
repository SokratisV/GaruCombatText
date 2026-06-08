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
    return f
end

local function release(s, key, t)
    t:Hide()
    s.trackers[key] = nil
    s.pool[#s.pool + 1] = t
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
    for key, d in pairs(snap) do             -- rebuild from saved totals, no pop
        local t = table.remove(s.pool) or newTracker(s)
        t.total, t.label, t.school, t.iconTex = d.total, d.label, d.school, d.iconTex
        t.mana = d.mana or 0
        t.curY, t.alpha, t.size = nil, 1, nil
        t.last, t.pop, t.popT = GetTime(), 1, 1
        t.appliedAlign = nil
        s.trackers[key] = t
        t:Show()
    end
end

local function switchGUID(M, s, guid)
    if M.cfg().persist then
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
        t.total = 0
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

local function bump(M, s, key, label, amount, school, crit, iconTex)
    local cfg = M.cfg()
    local t = ensureTracker(s, key)
    t.label   = label
    t.school  = school
    t.iconTex = iconTex
    t.isMana  = (type(key) == "string" and key:sub(1, 5) == "mana:") or false
    t.isCount = (type(key) == "string" and key:sub(1, 5) == "miss:") or false
    t.last    = GetTime()
    t.pop     = (crit and cfg.crit) and 1.9 or 1.45
    t.popT    = 0
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
    local amt = ns.FormatNumber(t.total)
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

local MANA_COLOR = { 0.35, 0.62, 1.00 }

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

-- Floating, Apex-style growing numbers.
local function layoutFloat(s, list, dt, cfg, maxhp)
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

            -- size: grows with the running total relative to the unit's max HP
            local size = cfg.fontSize
            if cfg.scaleBySeverity then
                local sev = math.min(1, (t.total / maxhp) / (math.max(1, cfg.bigPct) / 100))
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
            t.text:SetTextColor(c[1], c[2], c[3])

            local txt = valueString(t, cfg)
            if cfg.showLabel and t.label then
                local cap = cfg.maxLabel or 0
                if cap <= 0 then
                    cap = autoLabelChars(s.areaW, size, txt, cfg.showIcon and t.iconTex)
                end
                txt = abbrevN(t.label, cap) .. "  " .. txt
            end
            t.text:SetText(txt)
            layoutMana(t, cfg, "after")

            if cfg.showIcon and t.iconTex then
                t.icon:SetTexture(t.iconTex); t.icon:Show()
            else
                t.icon:Hide()
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
                -- frac runs 0..1 along the arc; Grow = Down reverses which end fills first.
                local ang
                if cfg.arcFixed then
                    local frac = slot / math.max(1, (cfg.maxLines or 6) - 1)
                    if cfg.growth == "DOWN" then frac = 1 - frac end
                    ang = center - span / 2 + frac * span
                elseif n <= 1 then
                    ang = center
                else
                    local frac = slot / (n - 1)
                    if cfg.growth == "DOWN" then frac = 1 - frac end
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
            t.bar:SetValue(t.total)

            t.name:SetText(cfg.showLabel and abbrev(t.label or "", cfg) or "")
            t.name:SetTextColor(0.96, 0.96, 0.96)
            t.text:SetText(valueString(t, cfg))
            if t.isMana then
                t.text:SetTextColor(MANA_COLOR[1], MANA_COLOR[2], MANA_COLOR[3])
            else
                t.text:SetTextColor(1, 1, 1)
            end

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

local function update(M, s, dt)
    local cfg = M.cfg()
    local now = GetTime()
    local maxhp = UnitHealthMax(s.frame.unit)
    maxhp = (maxhp and maxhp > 0) and maxhp or 1

    local aw = areaWidth(M, s)
    if s.areaW ~= aw then s.areaW = aw; s.container:SetWidth(aw) end

    local noFade = cfg.persist or M.noFade

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

    if cfg.style == "meter" then
        layoutMeter(s, list, dt, cfg)
    else
        layoutFloat(s, list, dt, cfg, maxhp)
    end

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
    s.container:SetFrameStrata("HIGH")
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
    local M = { streams = {}, cfg = opts.cfg, noFade = opts.noFade,
                windowed = opts.windowed, rolling = true }

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
        local curGUID = UnitGUID(frame.unit)
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

    -- re-sync a frame to its current GUID (e.g. on target change)
    function M:Retarget(frame)
        local s = frame and M.streams[frame]
        if s then switchGUID(M, s, UnitGUID(frame.unit)) end
    end

    function M:Clear()
        for _, s in pairs(M.streams) do resetStream(s) end
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
