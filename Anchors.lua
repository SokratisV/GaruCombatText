local ADDON, ns = ...

-- A simple movable anchor point per feed. The feed's text is placed at this point
-- (aligned Left/Center/Right relative to it) and grows up or down. The point is
-- positioned freely (dragged when unlocked) or pinned to the Player / Target / Focus
-- frame. Each anchor carries a .unit so target routing and scaling keep working:
--   enemyText anchor .unit = "target"  (damage you deal to your current target)
--   healText  anchor .unit = "player"  (healing you receive)

local anchors = {}

local DEFAULT_POINT = {
    enemyText   = { "CENTER",  250,  40 },
    healText    = { "CENTER", -250,  40 },
    takenText   = { "CENTER",  250, -120 },
    actionsText = { "CENTER", -250, -120 },
}

local function attachFrame(cfg)
    if cfg.attach == "player" then return PlayerFrame end
    if cfg.attach == "target" then return TargetFrame end
    if cfg.attach == "focus"  then return FocusFrame end
    return nil
end

local function savePoint(key)
    local _, _, rp, x, y = anchors[key]:GetPoint()
    ns.db[key].point = { rp or "CENTER", math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
end

local function apply(key)
    local f, cfg = anchors[key], ns.db[key]
    -- normalize / initialize the free point (accept legacy {point,relPoint,x,y}) so the
    -- manual "Free position" inputs always have a real value to read.
    local p = cfg.point or DEFAULT_POINT[key]
    if type(p[2]) ~= "number" then p = { p[2], p[3], p[4] } end
    cfg.point = { p[1] or "CENTER", math.floor(p[2] or 0), math.floor(p[3] or 0) }
    f:ClearAllPoints()
    local af = attachFrame(cfg)
    if af then
        f:SetPoint("CENTER", af, "CENTER", 0, 0)
        f:EnableMouse(false)
    else
        f:SetPoint("CENTER", UIParent, cfg.point[1], cfg.point[2], cfg.point[3])
        f:EnableMouse(not ns.db.locked)
    end
    local editing = (not ns.db.locked) and not af
    f.bg:SetShown(editing); f.border:SetShown(editing); f.dot:SetShown(editing); f.label:SetShown(editing)
end

local function makeAnchor(key, label, unit)
    local f = CreateFrame("Frame", "GaruCombatText_" .. key .. "Anchor", UIParent)
    f.unit = unit
    f:SetSize(26, 26)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not ns.db.locked and not attachFrame(ns.db[key]) then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePoint(key) end)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(f); f.bg:SetColorTexture(0.10, 0.45, 0.75, 0.25); f.bg:Hide()
    f.border = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.border:SetAllPoints(f)
    f.border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f.border:SetBackdropBorderColor(0.40, 0.78, 1.00, 0.85); f.border:Hide()
    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetColorTexture(0.40, 0.78, 1.00, 1); f.dot:SetSize(4, 4); f.dot:SetPoint("CENTER"); f.dot:Hide()
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.label:SetPoint("BOTTOM", f, "TOP", 0, 2); f.label:SetText(label); f.label:Hide()

    anchors[key] = f
    return f
end

makeAnchor("enemyText", "Damage Dealt", "target")
makeAnchor("healText", "Healing Received", "player")
makeAnchor("takenText", "Damage Taken", "player")
makeAnchor("actionsText", "Actions", "target")
ns.frames.target    = anchors.enemyText   -- EnemyText anchors + routes target damage here
ns.healHostFrame    = anchors.healText    -- HealText anchors here
ns.takenHostFrame   = anchors.takenText   -- TakenText anchors here
ns.actionsHostFrame = anchors.actionsText -- ActionsText anchors here (per current target)

function ns.RefreshAnchors()
    apply("enemyText"); apply("healText"); apply("takenText"); apply("actionsText")
end

function ns.SetLocked(v)
    ns.db.locked = v and true or false
    ns.RefreshAnchors()
    if ns.RefreshTimer then ns.RefreshTimer() end
    print("|cff66ccffGaru Combat Text|r: anchors " .. (ns.db.locked and "LOCKED" or "UNLOCKED -- drag the markers"))
end

-- ns.db isn't ready until ADDON_LOADED, so position the anchors at login (and on
-- every world entry / reload), not at file load.
ns.On("PLAYER_LOGIN", function() ns.RunWhenSafe(ns.RefreshAnchors) end)
ns.On("PLAYER_ENTERING_WORLD", function() ns.RefreshAnchors() end)
