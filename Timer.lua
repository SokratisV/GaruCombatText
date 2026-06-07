local ADDON, ns = ...

-- Standalone "Combat M:SS" readout for your current target. Independently
-- enable/disable and position: free (its own movable marker) or anchored to the
-- Damage or Healing text anchor. Duration comes from the damage meter (ns.CombatDuration).

local function cfg() return ns.db and ns.db.combatTimer end

local function fmtDur(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local tf = CreateFrame("Frame", "GarUICombatFeed_TimerAnchor", UIParent)
tf:SetSize(64, 16)
tf:SetFrameStrata("MEDIUM")
tf:SetClampedToScreen(true)
tf:SetMovable(true)
tf:RegisterForDrag("LeftButton")

tf.text = tf:CreateFontString(nil, "OVERLAY")
tf.text:SetPoint("CENTER")
tf.text:SetShadowColor(0, 0, 0, 1); tf.text:SetShadowOffset(1, -1)
tf.bg = tf:CreateTexture(nil, "BACKGROUND")
tf.bg:SetAllPoints(tf); tf.bg:SetColorTexture(0.10, 0.45, 0.75, 0.25); tf.bg:Hide()
tf.label = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tf.label:SetPoint("BOTTOM", tf, "TOP", 0, 2); tf.label:SetText("Combat Timer"); tf.label:Hide()

tf:SetScript("OnDragStart", function(self)
    if not ns.db.locked and cfg().attach == "free" then self:StartMoving() end
end)
tf:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local _, _, rp, x, y = self:GetPoint()
    cfg().point = { rp or "CENTER", math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
end)

function ns.RefreshTimer()
    local c = cfg()
    if not c then return end
    if not c.point then c.point = { "CENTER", 0, 140 } end   -- so manual Free position has a value
    tf.text:SetFont(ns.Font(ns.db.general.font), math.max(8, c.fontSize or 12), "OUTLINE")
    tf:ClearAllPoints()
    local host, fcfg
    if c.attach == "enemy" then host, fcfg = ns.frames.target, ns.db.enemyText
    elseif c.attach == "heal" then host, fcfg = ns.healHostFrame, ns.db.healText end
    if host then
        -- auto-clear the feed's stack: push past (max sources x line spacing) in the
        -- feed's grow direction, then add the user's fine offset.
        local up = (fcfg.growth ~= "DOWN")
        local autoY = (up and 1 or -1) * ((fcfg.maxLines or 6) * (fcfg.lineSpacing or 18))
        tf:SetPoint("CENTER", host, "CENTER", c.xOffset or 0, (c.yOffset or 0) + autoY)
        tf:EnableMouse(false)
    else  -- free
        tf:SetPoint("CENTER", UIParent, c.point[1] or "CENTER", c.point[2] or 0, c.point[3] or 0)
        tf:EnableMouse((not ns.db.locked) and c.enabled)
    end
    local editing = (not ns.db.locked) and c.attach == "free" and c.enabled
    tf.bg:SetShown(editing); tf.label:SetShown(editing)
end

tf:SetScript("OnUpdate", function(self, dt)
    self.acc = (self.acc or 0) + dt
    if self.acc < 0.1 then return end
    self.acc = 0
    local c = cfg()
    if not c then return end
    local dur = (c.enabled and ns.CombatDuration) and ns.CombatDuration() or nil
    if dur then
        self.text:SetText("Combat " .. fmtDur(dur))
        self.text:SetTextColor(0.95, 0.85, 0.45)
    else
        self.text:SetText("")
    end
end)

ns.On("PLAYER_LOGIN", function() ns.RunWhenSafe(ns.RefreshTimer) end)
