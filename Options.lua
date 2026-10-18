local ADDON, ns = ...

-- The settings window (/gct), in the style of FlareUI by Malkkav (MIT): the pages in
-- a list on the left, the page's settings in the middle under headings that fold,
-- and on the right what the hovered setting does. Blizzard's own controls throughout
-- -- checkbox, stepper, minimal slider, search box -- in FlareUI's bronze.
--
-- Pages are plain data (definePages, below): each row says what it is, what it does,
-- how to read and write its value, and when it applies. The window is drawn from
-- that data and drawn again after every change, so a setting that stops applying
-- (Free position, once a feed is pinned to a frame) goes, and comes back when it
-- applies again. Sliders are the exception: redrawing mid-drag would drop the drag,
-- and nothing a slider sets changes what is shown.

local WIDTH, HEIGHT = 880, 600
local HEADER_H = 34
local LEFT_W, RIGHT_W = 170, 230
local PAD = 12
local ROW_H, SECTION_H = 26, 28
local CONTENT_W = WIDTH - 12 - LEFT_W - RIGHT_W - 2 * PAD - 14
local ICON = "Interface\\Icons\\Ability_Warrior_BloodFrenzy"

local BORDER = { 0.80, 0.60, 0.34 }
local BRONZE = { 0.61, 0.48, 0.29 }

local function RE() if ns.RefreshEnemyText then ns.RefreshEnemyText() end end
local function RH() if ns.RefreshHealText then ns.RefreshHealText() end end
local function RK() if ns.RefreshTakenText then ns.RefreshTakenText() end end
local function RAc() if ns.RefreshActionsText then ns.RefreshActionsText() end end
local function RA() if ns.RefreshAnchors then ns.RefreshAnchors() end end
local function RT() if ns.RefreshTimer then ns.RefreshTimer() end end

local ATTACH = { { value = "free", text = "Free (movable)" }, { value = "player", text = "Player frame" },
                 { value = "target", text = "Target frame" } }
local TIMER_ATTACH = { { value = "free", text = "Free (movable)" }, { value = "enemy", text = "Damage Dealt" },
                       { value = "taken", text = "Damage Taken" }, { value = "actions", text = "Actions" },
                       { value = "heal", text = "Healing" } }
local UPDOWN = { { value = "UP", text = "Up" }, { value = "DOWN", text = "Down" } }
local ALIGN  = { { value = "LEFT", text = "Left" }, { value = "CENTER", text = "Centre" }, { value = "RIGHT", text = "Right" } }
local LAYOUT = { { value = "stack", text = "Stacked" }, { value = "radial", text = "Radial (arc)" } }
local FACING = { { value = 90, text = "Up" }, { value = 270, text = "Down" }, { value = 0, text = "Right" }, { value = 180, text = "Left" } }
local SORT   = { { value = "amount", text = "Biggest first" }, { value = "lowest", text = "Smallest first" },
                 { value = "recent", text = "Most recent" } }
local VALUE  = { { value = "amount", text = "Healing" }, { value = "both", text = "Healing and mana" },
                 { value = "mana", text = "Mana only" } }

local function val(x) if type(x) == "function" then return x() end return x end
local function Sound(kit)
    local id = SOUNDKIT and SOUNDKIT[kit]
    if id and PlaySound then pcall(PlaySound, id) end
end
local function seconds(v) return v .. " s" end
local function degrees(v) return v .. "\194\176" end   -- the degree sign, in UTF-8

--------------------------------------------------------------------------
-- 1. ROW DEFINITIONS
--------------------------------------------------------------------------
-- Rows read ns.db when asked, never when made: a reset swaps the whole table out.
local function merge(row, extra)
    if extra then for k, v in pairs(extra) do row[k] = v end end
    return row
end
local function Toggle(db, field, label, desc, apply, extra)
    return merge({ kind = "toggle", label = label, desc = desc,
        get = function() return ns.db[db][field] and true or false end,
        set = function(v) ns.db[db][field] = v; if apply then apply() end end }, extra)
end
local function Choice(db, field, label, desc, choices, apply, extra)
    return merge({ kind = "choice", label = label, desc = desc, choices = choices,
        get = function() return ns.db[db][field] end,
        set = function(v) ns.db[db][field] = v; if apply then apply() end end }, extra)
end
local function Slider(db, field, label, desc, lo, hi, step, apply, extra)
    return merge({ kind = "slider", label = label, desc = desc, min = lo, max = hi, step = step,
        get = function() return ns.db[db][field] or lo end,
        set = function(v) ns.db[db][field] = v; if apply then apply() end end }, extra)
end
-- A free position lives in point = { anchor, x, y }.
local function PointSlider(db, axis, label, desc, lo, hi, apply, extra)
    local i = (axis == "x") and 2 or 3
    return merge({ kind = "slider", label = label, desc = desc, min = lo, max = hi, step = 1,
        get = function() local p = ns.db[db].point; return (p and p[i]) or 0 end,
        set = function(v)
            local p = ns.db[db].point or { "CENTER", 0, 0 }
            local np = { p[1] or "CENTER", p[2] or 0, p[3] or 0 }
            np[i] = v
            ns.db[db].point = np
            if apply then apply() end
        end }, extra)
end
local function Button(label, desc, text, run, extra)
    return merge({ kind = "button", label = label, desc = desc, buttonText = text, run = run }, extra)
end

--------------------------------------------------------------------------
-- 2. PAGES
--------------------------------------------------------------------------
-- Copy & mirror: one feed takes another's look, flipped left to right, so the two
-- sit as a pair either side of the centre.
local FLIP = { LEFT = "RIGHT", RIGHT = "LEFT" }
local ARCFLIP = { [0] = 180, [180] = 0 }
local function copyMirror(dst, src)
    for _, k in ipairs({ "growth", "fontSize", "lineSpacing", "maxLines", "sortMode", "showLabel", "showIcon",
                         "schoolColors", "layout", "radius", "arc", "arcFixed" }) do
        dst[k] = src[k]
    end
    dst.align    = FLIP[src.align] or src.align
    dst.arcAngle = ARCFLIP[src.arcAngle] or src.arcAngle
    dst.xOffset  = -(src.xOffset or 0)
    dst.yOffset  = src.yOffset or 0
    local p = src.point
    if p and type(p[2]) == "number" then dst.point = { p[1] or "CENTER", -p[2], p[3] or 0 } end
end

-- What every feed has: where it sits, how its rows are laid out, how they read.
local function FeedPage(o)
    local db, refresh = o.db, o.refresh
    local function cfg() return ns.db[db] end
    local stack  = function() return cfg().layout ~= "radial" end
    local radial = function() return cfg().layout == "radial" end
    local free   = function() return cfg().attach == "free" end
    local function moved() RA(); refresh(); RT() end
    local function laid() refresh(); RT() end

    local text = {
        Slider(db, "fontSize", "Font size", "The size of the numbers.", 8, 40, 1),
        Slider(db, "maxLines", o.rowsLabel or "Rows shown", "How many rows the feed shows at most. The rest wait until one of these goes.", 1, 12, 1, laid),
        Choice(db, "sortMode", "Order", "Biggest first keeps the largest total at the anchor; Most recent puts whatever last changed there.", SORT),
    }
    for _, r in ipairs(o.text or {}) do text[#text + 1] = r end

    local sections = {
        { title = "Position", rows = {
            Choice(db, "attach", "Attach to", "Free gives the feed its own marker: unlock the anchors to drag it, or use the two sliders below. Pinned to the Player or Target frame, it follows that frame instead.", ATTACH, moved),
            PointSlider(db, "x", "Free position X", "Left and right, from the centre of the screen.", -1500, 1500, RA, { vis = free }),
            PointSlider(db, "y", "Free position Y", "Up and down, from the centre of the screen.", -1000, 1000, RA, { vis = free }),
            Slider(db, "xOffset", "Nudge X", "A small shift left or right from the anchor, wherever the anchor is.", -150, 150, 1, refresh),
            Slider(db, "yOffset", "Nudge Y", "A small shift up or down from the anchor.", -150, 150, 1, refresh),
        } },
        { title = "Layout", rows = {
            Choice(db, "layout", "Layout", "Stacked puts the rows one under another. Radial spreads them along an arc around the anchor.", LAYOUT, laid),
            Choice(db, "growth", "Grow", "Which way new rows are added.", UPDOWN, laid),
            Choice(db, "align", "Alignment", "Which edge of the rows lines up with the anchor.", ALIGN, refresh, { vis = stack }),
            Slider(db, "lineSpacing", "Line spacing", "The space between rows, in pixels.", 8, 60, 1, laid, { vis = stack }),
            Slider(db, "radius", "Arc radius", "How far from the anchor the arc runs, in pixels.", 20, 400, 2, nil, { vis = radial }),
            Slider(db, "arc", "Arc span", "How much of a circle the arc covers.", 20, 360, 5, nil, { vis = radial, fmt = degrees }),
            Choice(db, "arcAngle", "Arc facing", "Which way the arc opens from the anchor.", FACING, nil, { vis = radial }),
            Toggle(db, "arcFixed", "Fixed slots", "Each row keeps its own place on the arc, rather than the rows spreading out to fill it.", nil, { vis = radial }),
        } },
        { title = "Text", rows = text },
    }
    if o.counting then sections[#sections + 1] = { title = "Counting", rows = o.counting } end
    if o.mirror then
        sections[#sections + 1] = { title = "Copy", rows = {
            Button("Copy from " .. o.mirror.title,
                "Takes " .. o.mirror.title .. "'s layout, text and spacing, mirrored left to right, so the two feeds sit as a pair either side of the centre. Whether each is on, and what it counts, is left alone.",
                "Copy & mirror",
                function() copyMirror(ns.db[db], ns.db[o.mirror.db]); RA(); refresh(); RT() end),
        } }
    end
    return { key = o.key, title = o.title, desc = o.desc, enabledDb = db, onToggle = refresh,
             banner = o.banner, unavailable = o.unavailable, sections = sections }
end

local SUMMARY_SHORT = "Post-fight summary on this client"
local SUMMARY_LONG = "This client hides every number while a fight is in progress and releases them when it ends, so the feeds fill in afterwards: select something that died to see the fight. Several kills in one pull each show the whole pull; the client reports no per-enemy breakdown. The hold window is on the General page."

local pages, pageByKey

local function definePages()
    local notSummary = function() return not ns.SummaryMode end
    local function half(row) row.half = true return row end

    pages = {
        FeedPage({
            key = "heal", db = "healText", refresh = RH,
            title = function() return ns.SummaryMode and "Healing Cast" or "Healing Received" end,
            desc = "Healing that lands on you, one row per spell, from anyone. Out of combat it shows a rolling window of the last few seconds; in a fight it keeps every heal, and holds the lot for a moment after.",
            banner = function()
                if ns.UseUnitCombat then
                    return "Your own heals by spell; everyone else's on one line",
                        "The game reports every heal that lands on you, but not whose it was. Your own are placed on their spell by matching your casts; anyone else's share one Healing line."
                elseif ns.SummaryMode then
                    return "Healing you cast, not received",
                        "This client's only healing meter is kept by the caster and never says who a heal landed on, so this feed shows the healing you cast. Heal yourself and it is the same number; heal someone else and it is not. " .. SUMMARY_LONG
                end
            end,
            rowsLabel = "Rows shown",
            text = {
                Choice("healText", "valueMode", "Show", "What each row's number is: the healing, the mana spent on it beside it, or only the mana.", VALUE),
                half(Toggle("healText", "showLabel", "Spell names", "The spell's name beside its number.")),
                half(Toggle("healText", "showIcon", "Spell icons", "The spell's icon beside its number.")),
                half(Toggle("healText", "schoolColors", "School colours", "Colours each row by its spell school.")),
            },
            counting = {
                half(Toggle("healText", "showMana", "Mana spent", "Puts the mana each of your heals cost on its line.")),
                half(Toggle("healText", "includeMana", "Mana gained", "Counts mana you gain (Innervate, Mana Tide, potions) as rows of their own.")),
                Slider("healText", "threshold", "Ignore heals below", "Heals smaller than this are left out.", 0, 5000, 25),
                Slider("healText", "windowSecs", "Rolling window", "Out of combat, how far back the feed looks.", 1, 30, 1, nil, { vis = notSummary, fmt = seconds }),
                Slider("healText", "holdSecs", "Hold after combat", "How long the whole fight's healing stays up once combat ends, before the rolling window takes over again.", 0, 60, 1, nil, { vis = notSummary, fmt = seconds }),
            },
            mirror = { db = "enemyText", title = "Damage Dealt" },
        }),
        FeedPage({
            key = "taken", db = "takenText", refresh = RK,
            title = "Damage Taken",
            desc = function()
                return ns.UseUnitCombat and "The damage you take this fight from every enemy together, one row per school."
                    or "The damage you take this fight from every enemy together, one row per kind of attack: all melee on one, each spell on its own."
            end,
            banner = function()
                if ns.UseUnitCombat then
                    return "Grouped by school on this client",
                        "The game says how hard you were hit and in which school, but not by what, so the rows are Physical, Fire, Shadow and the rest rather than one per attacking spell."
                elseif ns.SummaryMode then return SUMMARY_SHORT, SUMMARY_LONG end
            end,
            text = {
                half(Toggle("takenText", "showLabel", "Names", "The attack's name, or its school, beside its number.")),
                half(Toggle("takenText", "showIcon", "Icons", "An icon beside each number.")),
                half(Toggle("takenText", "schoolColors", "School colours", "Colours each row by its school.")),
            },
            counting = {
                Toggle("takenText", "showAvoid", "Misses and avoids", "Counts your dodges, parries, blocks and the attacks that missed you as rows of their own (Dodge x4).", RK),
                Slider("takenText", "threshold", "Ignore hits below", "Hits smaller than this are left out.", 0, 3000, 25),
                Slider("takenText", "holdSecs", "Hold after combat", "How long the feed stays up once combat ends.", 0, 60, 1, nil, { vis = notSummary, fmt = seconds }),
            },
            mirror = { db = "enemyText", title = "Damage Dealt" },
        }),
        FeedPage({
            key = "dealt", db = "enemyText", refresh = RE,
            title = "Damage Dealt",
            desc = "The damage you deal to your target, one row per source: melee, each spell, wand, pet. Each target keeps its own totals, and they come back when you select it again.",
            banner = function()
                if ns.UseUnitCombat then
                    return "Worked out from your casts and swings",
                        "The combat log is gone on this client, so each hit on your target is matched to your casts and swings by timing and school. Solo that is close to exact; in a group, a teammate's hit of the same school landing just after your cast can be counted as yours. The blow that kills is never reported, so it is added from Blizzard's damage meter once the fight ends. /gct probe shows how a fight was placed."
                elseif ns.SummaryMode then return SUMMARY_SHORT, SUMMARY_LONG end
            end,
            rowsLabel = "Sources shown",
            text = {
                half(Toggle("enemyText", "showLabel", "Names", "The source's name beside its number.")),
                half(Toggle("enemyText", "showIcon", "Icons", "The spell's icon beside its number.")),
                half(Toggle("enemyText", "schoolColors", "School colours", "Colours each row by its damage school.")),
            },
            counting = {
                half(Toggle("enemyText", "includePet", "Pet and totems", "Counts your pet's and totems' damage too.")),
                half(Toggle("enemyText", "showMana", "Mana spent", "Puts the mana each spell cost on its line.")),
                Toggle("enemyText", "persist", "Remember each target", "Each target keeps its totals while you look at another, and they come back when you select it again.", RE, { vis = notSummary }),
                Slider("enemyText", "threshold", "Ignore hits below", "Hits smaller than this are left out.", 0, 3000, 25),
            },
            mirror = { db = "healText", title = "Healing" },
        }),
        FeedPage({
            key = "actions", db = "actionsText", refresh = RAc,
            title = "Actions",
            desc = "How often your target avoided you this fight: dodges, parries, blocks, misses, resists. Each target keeps its own count.",
            banner = function()
                if ns.UseUnitCombat then
                    return "Worked out from your swings and casts",
                        "Your target's dodges, parries and resists are reported, but not whose attack they avoided, so each is matched to your swings and casts by timing, as Damage Dealt is."
                end
            end,
            unavailable = function()
                if not ns.ActionsAvailable then
                    return "Not available on this client. Dodges, parries and misses are combat-log facts, and the damage meter that replaced the combat log here counts damage, not misses."
                end
            end,
            rowsLabel = "Rows shown",
            text = {
                half(Toggle("actionsText", "showLabel", "Names", "The kind of avoid beside its count (Dodge x4).")),
                half(Toggle("actionsText", "showIcon", "Icons", "An icon beside each count.")),
            },
            counting = {
                half(Toggle("actionsText", "includePet", "Pet and totems", "Counts what your target avoided of your pet's and totems' attacks too.")),
                half(Toggle("actionsText", "persist", "Remember each target", "Each target keeps its count while you look at another.", RAc)),
            },
            mirror = { db = "enemyText", title = "Damage Dealt" },
        }),
        {
            key = "timer", title = "Combat Timer", enabledDb = "combatTimer", onToggle = RT,
            desc = "How long you have been fighting your current target, as Combat M:SS.",
            sections = {
                { title = "Position", rows = {
                    Choice("combatTimer", "attach", "Attach to", "Free gives the timer its own marker. Attached to a feed, it sits just past that feed's rows, wherever they grow.", TIMER_ATTACH, RT),
                    PointSlider("combatTimer", "x", "Free position X", "Left and right, from the centre of the screen.", -1500, 1500, RT,
                        { vis = function() return ns.db.combatTimer.attach == "free" end }),
                    PointSlider("combatTimer", "y", "Free position Y", "Up and down, from the centre of the screen.", -1000, 1000, RT,
                        { vis = function() return ns.db.combatTimer.attach == "free" end }),
                    Slider("combatTimer", "xOffset", "Nudge X", "A small shift left or right.", -200, 200, 1, RT),
                    Slider("combatTimer", "yOffset", "Nudge Y", "A small shift up or down.", -200, 200, 1, RT),
                } },
                { title = "Text", rows = {
                    Slider("combatTimer", "fontSize", "Font size", "The size of the timer.", 8, 40, 1, RT),
                } },
            },
        },
        {
            key = "general", title = "General",
            desc = function()
                if ns.UseUnitCombat then
                    return "On WoW Forever: hits are read live from the game and matched to your casts and swings."
                elseif ns.SummaryMode then
                    return "On WoW Forever: each fight is summarised from Blizzard's damage meter once it ends."
                end
                return "Every feed reads the combat log as it happens."
            end,
            sections = {
                { title = "Blizzard", rows = {
                    Toggle("enemyText", "hideBlizzardFCT", "Hide Blizzard's damage numbers", "Turns off the numbers Blizzard floats over the target, so only these feeds show your damage.", RE),
                } },
                { title = "Post-fight summary", vis = function() return ns.SummaryMode end, rows = {
                    Slider("summary", "holdSecs", "Keep on screen", "How long a target's summary stays reachable once you first look at it. The window runs per target.", 3, 120, 1, nil, { fmt = seconds }),
                    Slider("summary", "fadeTime", "Fade out over", "The end of that window, spent dimming out.", 0, 5, 0.1, nil, { fmt = seconds }),
                    Toggle("summary", "requireDead", "Only for something that died", "Off, the summary shows on anything you select once the fight is over, not only on corpses."),
                } },
                { title = "Tools", vis = function() return ns.UseUnitCombat end, rows = {
                    Button("Last fight, placed", "Prints how many hits on your target came through readable, and how each was placed as yours. The same as /gct probe.", "Probe",
                        function() if ns.UC and ns.UC.PrintProbe then ns.UC.PrintProbe() end end),
                    { kind = "toggle", label = "Record fights",
                      desc = "Records every cast, swing and hit, and what was made of each, into the saved settings, where a /reload writes them to disk. For working out a fight that was placed wrong. The same as /gct trace.",
                      get = function() return ns.UC and ns.UC.Tracing and ns.UC.Tracing() or false end,
                      set = function(v) if ns.UC and ns.UC.SetTrace then ns.UC.SetTrace(v) end end },
                } },
                { title = "Reset", rows = {
                    Button("Reset all settings", "Puts every setting on every page back to its default.", "Reset",
                        function()
                            if StaticPopup_Show then
                                StaticPopup_Show("GARUCOMBATTEXT_RESET")
                            else
                                ns.ResetSettings()
                            end
                        end),
                } },
            },
        },
    }
    pageByKey = {}
    for _, p in ipairs(pages) do pageByKey[p.key] = p end
end

if StaticPopupDialogs then
    StaticPopupDialogs["GARUCOMBATTEXT_RESET"] = {
        text = "Reset every Garu Combat Text setting to its default?",
        button1 = YES or "Yes", button2 = NO or "No",
        OnAccept = function() if ns.ResetSettings then ns.ResetSettings() end end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
end

local NAV = {
    { label = "Feeds", keys = { "heal", "taken", "dealt", "actions" } },
    { label = "Extras", keys = { "timer" } },
    { keys = { "general" }, gap = true },
}

--------------------------------------------------------------------------
-- 3. SMALL PIECES
--------------------------------------------------------------------------
local Panel = {}
local frame
local page, preview = {}, {}
local current
local searchText = ""
local closed = {}             -- "page:section" -> folded, for this session
local pools, used = {}, {}
local navButtons = {}
local uid = 0

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function Line(parent, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.6)
    t:SetHeight(1)
    return t
end

local function pageEnabled(p)
    if not p.enabledDb then return true end
    return ns.db[p.enabledDb].enabled and true or false
end

-- A redraw after a change, a frame later: a menu's own click is still running.
local function Changed()
    C_Timer.After(0, function() if frame and frame:IsShown() then Panel.Refresh() end end)
end

--------------------------------------------------------------------------
-- 4. THE RIGHT COLUMN: what the hovered setting does
--------------------------------------------------------------------------
local function ShowInfo(title, desc, tip)
    if not preview.title then return end
    preview.title:SetText(title or "")
    preview.desc:SetText(desc or "")
    preview.tip:SetText(tip and ("|cffffd100Tip:|r " .. tip) or "")
end

local function ShowPageInfo()
    if searchText ~= "" then
        ShowInfo("Search", "Settings from every page whose name holds what you typed.", "Clear the box to go back to the page.")
        return
    end
    local p = pageByKey and pageByKey[current]
    if p then ShowInfo(val(p.title), val(p.desc), "Hover any setting to see what it does.") end
end

--------------------------------------------------------------------------
-- 5. ROWS
--------------------------------------------------------------------------
-- One pool per kind. A row spans the page: its name on the left, its control on
-- the right; hovering it fills the right column.
local Build, Fill = {}, {}

local function RowEnter(self)
    if self.row then ShowInfo(val(self.row.label), val(self.row.desc), self.row.tip) end
    self.hover:Show()
end
local function RowLeave(self)
    self.hover:Hide()
    ShowPageInfo()
end
local function Forward(control, f)
    if not control or not control.HookScript then return end
    control:HookScript("OnEnter", function() RowEnter(f) end)
    control:HookScript("OnLeave", function() RowLeave(f) end)
end

local function NewRow(parent, kind)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(ROW_H)
    f:EnableMouse(true)
    f:SetScript("OnEnter", RowEnter)
    f:SetScript("OnLeave", RowLeave)
    f.hover = f:CreateTexture(nil, "BACKGROUND")
    f.hover:SetAllPoints()
    f.hover:SetColorTexture(1, 0.82, 0, 0.06)
    f.hover:Hide()
    f.label = Text(f, "GameFontHighlight")
    f.label:SetPoint("LEFT", 6, 0)
    f.crumb = Text(f, "GameFontDisableSmall")
    f.crumb:SetPoint("BOTTOMLEFT", f.label, "TOPLEFT", 0, 1)
    f.kind = kind
    Build[kind](f)
    return f
end

local function Acquire(parent, kind)
    pools[kind] = pools[kind] or {}
    local f = table.remove(pools[kind]) or NewRow(parent, kind)
    f:SetParent(parent)
    f:Show()
    used[#used + 1] = f
    return f
end

local function ReleaseAll()
    for _, f in ipairs(used) do
        f:Hide()
        f:ClearAllPoints()
        f.row = nil
        table.insert(pools[f.kind], f)
    end
    wipe(used)
end

-- toggle: a checkbox at the right
Build.toggle = function(f)
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("RIGHT", -4, 0)
    check:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        Sound(on and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        if f.row then f.row.set(on); Changed() end
    end)
    Forward(check, f)
    f.check = check
end
Fill.toggle = function(f, row)
    f.check:SetChecked(row.get() and true or false)
end

-- choice: Blizzard's stepper from its Settings (a dark box with an arrow either
-- side; the box opens the list, the arrows step through it). Where a client has no
-- such template, a plain dropdown; where it has no menus either, the old one.
local function SetupMenu(dropdown, f)
    dropdown:SetupMenu(function(_, root)
        local row = f.row
        if not row then return end
        for _, c in ipairs(row.choices) do
            root:CreateRadio(c.text,
                function() return row.get() == c.value end,
                function() row.set(c.value); Changed() end,
                c.value)
        end
    end)
end

Build.choice = function(f)
    local ok, stepper = pcall(CreateFrame, "Frame", nil, f, "SettingsDropdownWithButtonsTemplate")
    if ok and stepper and stepper.Dropdown and stepper.IncrementButton and stepper.DecrementButton
        and stepper.Dropdown.SetupMenu then
        if stepper.Label then stepper.Label:Hide() end
        stepper:SetPoint("RIGHT", 4, 0)
        stepper.Dropdown:SetWidth(160)
        -- the template lays its arrows out past its own right edge: placed from
        -- the row's right edge instead, so the right arrow is never clipped
        stepper.IncrementButton:ClearAllPoints()
        stepper.IncrementButton:SetPoint("RIGHT", f, "RIGHT", -6, 0)
        stepper.Dropdown:ClearAllPoints()
        stepper.Dropdown:SetPoint("RIGHT", stepper.IncrementButton, "LEFT", -5, 0)
        stepper.DecrementButton:ClearAllPoints()
        stepper.DecrementButton:SetPoint("RIGHT", stepper.Dropdown, "LEFT", -5, 0)
        Forward(stepper.Dropdown, f); Forward(stepper.IncrementButton, f); Forward(stepper.DecrementButton, f)
        SetupMenu(stepper.Dropdown, f)
        f.dropdown = stepper.Dropdown
        f:SetHeight(ROW_H + 6)
        return
    end
    if ok and stepper then stepper:Hide() end

    if MenuUtil then
        local okd, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
        if okd and dd and dd.SetupMenu then
            dd:SetWidth(180)
            dd:SetPoint("RIGHT", -6, 0)
            Forward(dd, f)
            SetupMenu(dd, f)
            f.dropdown = dd
            return
        end
    end

    uid = uid + 1
    local dd = CreateFrame("Frame", "GaruCombatTextDrop" .. uid, f, "UIDropDownMenuTemplate")
    dd:SetPoint("RIGHT", 10, -2)
    UIDropDownMenu_SetWidth(dd, 150)
    UIDropDownMenu_Initialize(dd, function(_, level)
        local row = f.row
        if not row then return end
        for _, c in ipairs(row.choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.checked = c.text, (row.get() == c.value)
            info.func = function() row.set(c.value); CloseDropDownMenus(); Changed() end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.legacy = dd
    f:SetHeight(ROW_H + 6)
end
Fill.choice = function(f, row)
    if f.dropdown then
        f.dropdown:GenerateMenu()
    elseif f.legacy then
        local text = ""
        for _, c in ipairs(row.choices) do if c.value == row.get() then text = c.text end end
        UIDropDownMenu_SetText(f.legacy, text)
    end
end

-- slider: Blizzard's minimal slider with its stepper arrows, and the value in a box
-- you can type into
local function Snap(v, step)
    if step >= 1 then return math.floor(v / step + 0.5) * step end
    local m = 1 / step
    return math.floor(v * m + 0.5) / m
end
local function ValueText(row, v)
    if row.fmt then return row.fmt(v) end
    if row.step < 1 then return string.format("%.1f", v) end
    return tostring(v)
end

local function SliderChanged(f, value)
    local row = f.row
    if f.filling or not row then return end
    value = Snap(value, row.step)
    if value ~= row.get() then row.set(value) end
    f.edit:SetText(ValueText(row, value))
end

Build.slider = function(f)
    local ok, s = pcall(CreateFrame, "Frame", nil, f, "MinimalSliderWithSteppersTemplate")
    if ok and s and s.Init and s.RegisterCallback and MinimalSliderWithSteppersMixin
        and MinimalSliderWithSteppersMixin.Event then
        s:SetWidth(180)
        s:SetPoint("RIGHT", -54, 0)
        if s.MinText then s.MinText:Hide() end
        if s.MaxText then s.MaxText:Hide() end
        s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged,
            function(_, value) SliderChanged(f, value) end, f)
        Forward(s, f); Forward(s.Slider, f)
        f.slider = s
    else
        if ok and s then s:Hide() end
        -- no template: a bare slider in the same place
        local bare = CreateFrame("Slider", nil, f)
        bare:SetOrientation("HORIZONTAL")
        bare:SetSize(170, 14)
        bare:SetPoint("RIGHT", -60, 0)
        bare:SetHitRectInsets(0, 0, -6, -6)
        pcall(bare.SetObeyStepOnDrag, bare, true)
        local track = bare:CreateTexture(nil, "ARTWORK")
        track:SetColorTexture(0.30, 0.30, 0.34, 0.9); track:SetHeight(4)
        track:SetPoint("LEFT"); track:SetPoint("RIGHT")
        local thumb = bare:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1); thumb:SetSize(10, 16)
        bare:SetThumbTexture(thumb)
        bare:SetScript("OnValueChanged", function(_, value) SliderChanged(f, value) end)
        Forward(bare, f)
        f.slider = bare
    end

    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetSize(42, 18)
    edit:SetPoint("RIGHT", -6, 0)
    edit:SetAutoFocus(false)
    edit:SetJustifyH("CENTER")
    edit:SetMaxLetters(7)
    local function restore(self)
        if f.row then self:SetText(ValueText(f.row, f.row.get())) end
        self:ClearFocus()
    end
    edit:SetScript("OnEditFocusGained", function(self)
        if f.row then self:SetText(tostring(f.row.get())) end
        self:HighlightText()
    end)
    edit:SetScript("OnEnterPressed", function(self)
        local row, v = f.row, tonumber(self:GetText())
        if row and v then
            v = Snap(math.min(row.max, math.max(row.min, v)), row.step)
            f.slider:SetValue(v)
            row.set(v)
        end
        restore(self)
    end)
    edit:SetScript("OnEscapePressed", restore)
    edit:SetScript("OnEditFocusLost", restore)
    Forward(edit, f)
    f.edit = edit
    f:SetHeight(ROW_H + 4)
end
Fill.slider = function(f, row)
    f.filling = true
    local v = row.get()
    if f.slider.Init then
        local steps = math.max(1, math.floor((row.max - row.min) / row.step + 0.5))
        f.slider:Init(v, row.min, row.max, steps, {})
    else
        f.slider:SetMinMaxValues(row.min, row.max)
        f.slider:SetValueStep(row.step)
        f.slider:SetValue(v)
    end
    f.edit:SetText(ValueText(row, v))
    f.edit:SetCursorPosition(0)
    f.filling = false
end

-- button: an action, at the right
Build.button = function(f)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetHeight(22)
    b:SetPoint("RIGHT", -4, 0)
    b:SetScript("OnClick", function()
        Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
        if f.row and f.row.run then f.row.run(); Changed() end
    end)
    Forward(b, f)
    f.button = b
end
Fill.button = function(f, row)
    f.button:SetText(val(row.buttonText) or "")
    f.button:SetWidth(math.max(90, (f.button:GetFontString() and f.button:GetFontString():GetStringWidth() or 60) + 28))
end

local function FillRow(f, row, crumb)
    f.row = row
    f.label:SetText(val(row.label) or "")
    f.crumb:SetText(crumb or "")
    f.crumb:SetShown(crumb ~= nil)
    Fill[f.kind](f, row)
    if crumb then f:SetHeight(math.max(f:GetHeight(), ROW_H + 12)) end
end

--------------------------------------------------------------------------
-- 6. THE MIDDLE COLUMN: the page
--------------------------------------------------------------------------
local function SectionClick(h)
    if not h.sectionKey then return end
    Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
    closed[h.sectionKey] = not closed[h.sectionKey] or nil
    Panel.Refresh()
end

local function SectionHeader(parent, text, y, sectionKey)
    pools.section = pools.section or {}
    local h = table.remove(pools.section)
    if not h then
        h = CreateFrame("Frame", nil, parent)
        h:SetHeight(SECTION_H)
        h.kind = "section"
        h.text = Text(h, "GameFontNormal")
        h.text:SetPoint("BOTTOMLEFT", 6, 6)
        h.sign = Text(h, "GameFontNormal")
        h.sign:SetPoint("BOTTOMRIGHT", -10, 6)
        h.line = Line(h)
        h.line:SetPoint("BOTTOMLEFT", 0, 2)
        h.line:SetPoint("BOTTOMRIGHT", 0, 2)
        h.hover = h:CreateTexture(nil, "BACKGROUND")
        h.hover:SetAllPoints()
        h.hover:SetColorTexture(1, 0.82, 0, 0.06)
        h.hover:Hide()
        h:EnableMouse(true)
        h:SetScript("OnEnter", function(self) self.hover:Show() end)
        h:SetScript("OnLeave", function(self) self.hover:Hide() end)
        h:SetScript("OnMouseUp", SectionClick)
    end
    h:SetParent(parent)
    h.sectionKey = sectionKey
    h.sign:SetText(sectionKey and (closed[sectionKey] and "+" or "-") or "")
    h.text:SetText(text)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 0, y)
    h:SetWidth(CONTENT_W)
    h:Show()
    used[#used + 1] = h
    return SECTION_H
end

-- Lays rows out from y down and returns the new y. Rows marked half go two to a
-- line, except in search results, where each row has its page written above it.
local function PlaceRows(parent, rows, y, crumbOf)
    local col, lineH = 0, 0
    for _, row in ipairs(rows) do
        local f = Acquire(parent, row.kind)
        f:ClearAllPoints()
        if row.half and not crumbOf then
            local w = math.floor(CONTENT_W / 2)
            f:SetPoint("TOPLEFT", col * w, y)
            f:SetWidth(w - (col == 0 and 8 or 0))
            FillRow(f, row)
            lineH = math.max(lineH, f:GetHeight())
            if col == 1 then y, col, lineH = y - lineH, 0, 0 else col = 1 end
        else
            if col == 1 then y, col, lineH = y - lineH, 0, 0 end
            f:SetPoint("TOPLEFT", 0, y)
            f:SetWidth(CONTENT_W)
            FillRow(f, row, crumbOf and crumbOf(row))
            y = y - f:GetHeight()
        end
    end
    if col == 1 then y = y - lineH end
    return y
end

local function visibleRows(section)
    local out = {}
    for _, row in ipairs(section.rows) do
        if not row.vis or row.vis() then out[#out + 1] = row end
    end
    return out
end

local function UpdateNav()
    for key, b in pairs(navButtons) do
        local p = pageByKey[key]
        local on = pageEnabled(p)
        b.selected:SetShown(key == current and searchText == "")
        b.dot:SetShown(p.enabledDb ~= nil)
        b.dot:SetVertexColor(on and 0.35 or 0.4, on and 0.85 or 0.4, on and 0.35 or 0.4)
        local c = on and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR
        if c then b.text:SetTextColor(c:GetRGB()) end
        b.text:SetText(val(p.title))
    end
end

local function UpdateHeaderButtons()
    if not frame then return end
    frame.lock:SetText(ns.db.locked and "Unlock anchors" or "Lock anchors")
    frame.preview:SetText(ns.test.combat and "Stop preview" or "Preview")
end

function Panel.Refresh()
    if not frame then return end
    ReleaseAll()
    local searching = searchText ~= ""
    local p = pageByKey[current]

    -- header: switch and title, description, the client's note
    local banner, bannerLong
    if searching then
        page.switch:Hide()
        page.title:SetText("Search")
        page.title:ClearAllPoints()
        page.title:SetPoint("LEFT", page.switch, "LEFT", 4, 0)
        page.desc:SetText("")
    else
        page.switch:SetShown(p.enabledDb ~= nil)
        page.switch:SetChecked(pageEnabled(p))
        page.title:SetText(val(p.title))
        page.title:ClearAllPoints()
        if p.enabledDb then
            page.title:SetPoint("LEFT", page.switch, "RIGHT", 4, 0)
        else
            page.title:SetPoint("LEFT", page.switch, "LEFT", 4, 0)
        end
        page.desc:SetText(val(p.desc) or "")
        if p.banner then banner, bannerLong = p.banner() end
    end
    page.banner:SetShown(banner ~= nil)
    page.banner.text:SetText(banner or "")
    page.banner.long = bannerLong
    local headerH = 34 + (page.desc:GetText() ~= "" and (page.desc:GetStringHeight() + 6) or 0)
    if banner then
        page.banner:ClearAllPoints()
        page.banner:SetPoint("TOPLEFT", page.header, "TOPLEFT", 0, -headerH)
        page.banner:SetPoint("RIGHT", page.header, "RIGHT")
        headerH = headerH + 30
    end
    page.header:SetHeight(headerH)

    -- body: a card when there is nothing to set, else the sections
    local cardText
    if not searching then
        cardText = p.unavailable and p.unavailable()
        page.card.button:SetShown(not cardText and not pageEnabled(p))
        if not cardText and not pageEnabled(p) then
            cardText = val(p.title) .. " is off."
        end
    end
    page.card:SetShown(cardText ~= nil)
    page.card.text:SetText(cardText or "")
    page.scroll:SetShown(cardText == nil)

    local y = 0
    if cardText == nil then
        if searching then
            local needle = searchText:lower()
            for _, sp in ipairs(pages) do
                for _, section in ipairs(sp.sections) do
                    if not section.vis or section.vis() then
                        local hits = {}
                        for _, row in ipairs(visibleRows(section)) do
                            local label = val(row.label) or ""
                            if label:lower():find(needle, 1, true) then hits[#hits + 1] = row end
                        end
                        if #hits > 0 then
                            local crumb = val(sp.title) .. "  >  " .. section.title
                            y = PlaceRows(page.content, hits, y, function() return crumb end)
                        end
                    end
                end
            end
            if y == 0 then page.empty:Show() else page.empty:Hide() end
        else
            page.empty:Hide()
            for _, section in ipairs(p.sections) do
                if not section.vis or section.vis() then
                    local rows = visibleRows(section)
                    if #rows > 0 then
                        local key = p.key .. ":" .. section.title
                        y = y - SectionHeader(page.content, section.title, y, key)
                        if not closed[key] then y = PlaceRows(page.content, rows, y) - 4 end
                    end
                end
            end
        end
    else
        page.empty:Hide()
    end
    page.content:SetHeight(math.max(1, -y + 8))
    if page.scrollLine then page.scrollLine.Update() end
    UpdateNav()
    UpdateHeaderButtons()
end

function Panel.Select(key)
    if not pageByKey[key] then return end
    current = key
    ns.db.general.optionsPage = key
    if searchText ~= "" then
        searchText = ""
        frame.search:SetText("")
    end
    page.scroll:SetVerticalScroll(0)
    Panel.Refresh()
    ShowPageInfo()
end

--------------------------------------------------------------------------
-- 7. THE WINDOW
--------------------------------------------------------------------------
-- A thin scroll line beside the page, like FlareUI's: a faint track and a bronze
-- thumb, shown only when there is something to scroll; the wheel scrolls the page.
local function AttachScrollLine(scroll, parent)
    local line = CreateFrame("Frame", nil, parent)
    line:SetWidth(8)
    line:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
    line:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    line.track = line:CreateTexture(nil, "ARTWORK")
    line.track:SetWidth(2); line.track:SetPoint("TOP"); line.track:SetPoint("BOTTOM")
    line.track:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.25)
    line.thumb = line:CreateTexture(nil, "OVERLAY")
    line.thumb:SetWidth(2)
    line.thumb:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
    function line.Update()
        local range = scroll:GetVerticalScrollRange() or 0
        local h = line:GetHeight() or 0
        if not scroll:IsShown() or range <= 0.5 or h <= 0 then line:Hide() return end
        line:Show()
        local visible = scroll:GetHeight() / (scroll:GetHeight() + range)
        local th = math.max(16, h * visible)
        line.thumb:SetHeight(th)
        line.thumb:ClearAllPoints()
        line.thumb:SetPoint("TOP", line, "TOP", 0, -(h - th) * ((scroll:GetVerticalScroll() or 0) / range))
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
    end)
    scroll:HookScript("OnVerticalScroll", line.Update)
    scroll:HookScript("OnScrollRangeChanged", line.Update)
    scroll:HookScript("OnSizeChanged", line.Update)
    return line
end

local function HeaderButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    b:SetScript("OnClick", function() Sound("IG_MAINMENU_OPTION_CHECKBOX_ON"); onClick(); Changed() end)
    return b
end

local function BuildWindow()
    definePages()
    current = pageByKey[ns.db.general.optionsPage] and ns.db.general.optionsPage or "heal"

    frame = CreateFrame("Frame", "GaruCombatTextOptions", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")   -- above the feeds (HIGH) so it covers them
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
    frame:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1)
    -- a dark base, Blizzard's Collections tile over it, and a black wash (FlareUI's)
    local base = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
    base:SetPoint("TOPLEFT", 5, -5); base:SetPoint("BOTTOMRIGHT", -5, 5)
    base:SetColorTexture(0.06, 0.055, 0.045, 0.97)
    local art = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    art:SetAllPoints(base)
    art:SetTexture("Interface\\Collections\\CollectionsBackgroundTile", "REPEAT", "REPEAT")
    art:SetHorizTile(true); art:SetVertTile(true)
    local wash = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    wash:SetAllPoints(base)
    wash:SetColorTexture(0, 0, 0, 0.5)
    frame:Hide()
    tinsert(UISpecialFrames, "GaruCombatTextOptions")
    frame:SetScript("OnShow", function()
        Sound("IG_CHARACTER_INFO_OPEN")
        Panel.Refresh()
        ShowPageInfo()
    end)
    frame:SetScript("OnHide", function() Sound("IG_CHARACTER_INFO_CLOSE") end)

    -- header: name, version, the two things you reach for most, close
    local title = Text(frame, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD + 4, -12)
    title:SetText("Garu Combat Text")
    local version = Text(frame, "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    version:SetText(meta and meta(ADDON, "Version") or "")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    frame.preview = HeaderButton(frame, function() if ns.SetPreview then ns.SetPreview(not ns.test.combat) end end)
    frame.preview:SetPoint("RIGHT", close, "LEFT", -4, 0)
    frame.lock = HeaderButton(frame, function() if ns.SetLocked then ns.SetLocked(not ns.db.locked) end end)
    frame.lock:SetPoint("RIGHT", frame.preview, "LEFT", -4, 0)
    local headerLine = Line(frame)
    headerLine:SetPoint("TOPLEFT", 6, -HEADER_H)
    headerLine:SetPoint("TOPRIGHT", -6, -HEADER_H)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", 6, -HEADER_H - 1)
    body:SetPoint("BOTTOMRIGHT", -6, 6)

    -- left column: the pages, and search
    local left = CreateFrame("Frame", nil, body)
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT")
    left:SetWidth(LEFT_W)
    local leftLine = Line(body)
    leftLine:SetWidth(1)
    leftLine:SetPoint("TOPLEFT", left, "TOPRIGHT"); leftLine:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT")

    local y = -PAD + 4
    for _, group in ipairs(NAV) do
        if group.label then
            local g = Text(left, "GameFontDisableSmall")
            g:SetPoint("TOPLEFT", PAD + 4, y - 8)
            g:SetText(group.label)
            y = y - 24
        elseif group.gap then
            y = y - 14
        end
        for _, key in ipairs(group.keys) do
            local b = CreateFrame("Button", nil, left)
            b:SetSize(LEFT_W - 2 * PAD, 24)
            b:SetPoint("TOPLEFT", PAD, y)
            b.selected = b:CreateTexture(nil, "BACKGROUND")
            b.selected:SetAllPoints()
            b.selected:SetColorTexture(1, 0.82, 0, 0.12)
            b:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
            b:GetHighlightTexture():SetAlpha(0.25)
            b.dot = b:CreateTexture(nil, "ARTWORK")
            b.dot:SetTexture("Interface\\COMMON\\Indicator-Green")
            b.dot:SetDesaturated(true)
            b.dot:SetSize(14, 14)
            b.dot:SetPoint("LEFT", 2, 0)
            b.text = Text(b, "GameFontHighlight")
            b.text:SetPoint("LEFT", 20, 0)
            b:SetScript("OnClick", function()
                Sound("IG_CHARACTER_INFO_TAB")
                Panel.Select(key)
            end)
            navButtons[key] = b
            y = y - 24
        end
    end

    local okSearch, search = pcall(CreateFrame, "EditBox", nil, left, "SearchBoxTemplate")
    if not okSearch then search = CreateFrame("EditBox", nil, left, "InputBoxTemplate"); search:SetAutoFocus(false) end
    search:SetSize(LEFT_W - 2 * PAD - 4, 22)
    search:SetPoint("BOTTOMLEFT", PAD + 4, PAD - 2)
    if search.Instructions then search.Instructions:SetText("Search settings") end
    search:HookScript("OnTextChanged", function(self)
        searchText = strtrim(self:GetText() or "")
        page.scroll:SetVerticalScroll(0)
        Panel.Refresh()
        ShowPageInfo()
    end)
    frame.search = search

    -- right column: what the hovered setting does
    local right = CreateFrame("Frame", nil, body)
    right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT")
    right:SetWidth(RIGHT_W)
    local rightBg = right:CreateTexture(nil, "BACKGROUND")
    rightBg:SetAllPoints()
    rightBg:SetColorTexture(0, 0, 0, 0.25)
    local rightLine = Line(body)
    rightLine:SetWidth(1)
    rightLine:SetPoint("TOPRIGHT", right, "TOPLEFT"); rightLine:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
    local icon = right:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("TOPLEFT", PAD, -PAD)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    preview.title = Text(right, "GameFontNormalLarge")
    preview.title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    preview.title:SetPoint("RIGHT", -PAD, 0)
    preview.title:SetWordWrap(true)
    preview.desc = Text(right, "GameFontHighlight")
    preview.desc:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -12)
    preview.desc:SetPoint("RIGHT", -PAD, 0)
    preview.desc:SetSpacing(3)
    preview.desc:SetTextColor(0.85, 0.85, 0.85)
    preview.tip = Text(right, "GameFontNormalSmall")
    preview.tip:SetPoint("TOPLEFT", preview.desc, "BOTTOMLEFT", 0, -10)
    preview.tip:SetPoint("RIGHT", -PAD, 0)
    preview.tip:SetSpacing(2)

    -- middle column: the page
    local middle = CreateFrame("Frame", nil, body)
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT", PAD, -PAD)
    middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", -PAD - 10, PAD)

    local header = CreateFrame("Frame", nil, middle)
    header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
    header:SetHeight(64)
    page.header = header
    page.switch = CreateFrame("CheckButton", nil, header, "UICheckButtonTemplate")
    page.switch:SetSize(30, 30)
    page.switch:SetPoint("TOPLEFT", -2, 2)
    page.switch:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        Sound(on and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        local p = pageByKey[current]
        if p and p.enabledDb then
            ns.db[p.enabledDb].enabled = on
            if p.onToggle then p.onToggle() end
        end
        Panel.Refresh()
    end)
    page.title = Text(header, "GameFontNormalHuge")
    page.title:SetPoint("LEFT", page.switch, "RIGHT", 4, 0)
    page.desc = Text(header, "GameFontHighlightSmall")
    page.desc:SetPoint("TOPLEFT", 4, -34)
    page.desc:SetWidth(CONTENT_W - 8)
    page.desc:SetTextColor(0.62, 0.62, 0.62)
    page.desc:SetSpacing(2)

    -- the client's note: a bronze strip; hover it for the whole story
    local banner = CreateFrame("Frame", nil, header, "BackdropTemplate")
    banner:SetHeight(26)
    banner:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    banner:SetBackdropColor(0.5, 0.35, 0, 0.35)
    banner.text = Text(banner, "GameFontNormal")
    banner.text:SetPoint("LEFT", 8, 0)
    banner.text:SetPoint("RIGHT", -8, 0)
    banner:EnableMouse(true)
    banner:SetScript("OnEnter", function(self) ShowInfo(self.text:GetText(), self.long) end)
    banner:SetScript("OnLeave", ShowPageInfo)
    banner:Hide()
    page.banner = banner

    local scroll = CreateFrame("ScrollFrame", nil, middle)
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT")
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_W, 1)
    scroll:SetScrollChild(content)
    page.scroll, page.content = scroll, content
    page.scrollLine = AttachScrollLine(scroll, middle)
    page.empty = Text(middle, "GameFontDisable")
    page.empty:SetPoint("TOP", scroll, "TOP", 0, -20)
    page.empty:SetText("No setting by that name.")
    page.empty:Hide()

    -- shown instead of the sections when the page has nothing to set
    local card = CreateFrame("Frame", nil, middle)
    card:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -20)
    card:SetPoint("RIGHT")
    card:SetHeight(120)
    card.text = Text(card, "GameFontHighlight", "CENTER")
    card.text:SetPoint("TOP", 0, -10)
    card.text:SetWidth(CONTENT_W - 40)
    card.text:SetSpacing(3)
    card.button = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.button:SetSize(120, 24)
    card.button:SetPoint("TOP", card.text, "BOTTOM", 0, -14)
    card.button:SetText("Turn on")
    card.button:SetScript("OnClick", function()
        local p = pageByKey[current]
        if p and p.enabledDb then
            Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
            ns.db[p.enabledDb].enabled = true
            if p.onToggle then p.onToggle() end
            Panel.Refresh()
        end
    end)
    card:Hide()
    page.card = card
end

function ns.ToggleOptions()
    if not frame then BuildWindow() end
    frame:SetShown(not frame:IsShown())
end

-- Something outside the window changed a setting (/gct lock, a reset): redraw it.
function ns.RefreshOptions()
    if frame and frame:IsShown() then Panel.Refresh() end
end
