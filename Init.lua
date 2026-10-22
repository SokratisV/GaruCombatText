local ADDON, ns = ...

-- Build the feeds once we're in the world (deferred out of combat for safety).
ns.On("PLAYER_LOGIN", function()
    ns.RunWhenSafe(function()
        if ns.BuildEnemyText then ns.BuildEnemyText() end
        if ns.BuildHealText then ns.BuildHealText() end
        if ns.BuildDoneText then ns.BuildDoneText() end
        if ns.BuildTakenText then ns.BuildTakenText() end
        if ns.BuildActionsText then ns.BuildActionsText() end
    end)
end)

-- The preview: made-up numbers in every feed, to place and style them out of combat.
-- Turning it off clears what it drew. Shared by /gct test and the settings window.
function ns.SetPreview(on)
    ns.test.combat = on and true or false
    if not ns.test.combat then
        if ns.ClearEnemyText then ns.ClearEnemyText() end
        if ns.ClearHealText then ns.ClearHealText() end
        if ns.ClearDoneText then ns.ClearDoneText() end
        if ns.ClearTakenText then ns.ClearTakenText() end
        if ns.ClearActionsText then ns.ClearActionsText() end
    end
    if ns.RefreshOptions then ns.RefreshOptions() end
end

-- Slash: open the config panel; /gct test toggles the preview, /gct reset restores.
SLASH_GARUCOMBATTEXT1 = "/gct"
SLASH_GARUCOMBATTEXT2 = "/garucombattext"
local P = "|cff66ccffGaru Combat Text|r: "
SlashCmdList.GARUCOMBATTEXT = function(msg)
    local L = ns.L
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "test" then
        ns.SetPreview(not ns.test.combat)
        print(P .. (ns.test.combat and L["preview on."] or L["preview off."]))
    elseif msg == "unlock" then
        if ns.SetLocked then ns.SetLocked(false) end
        print(P .. L["anchors unlocked. Drag the markers."])
    elseif msg == "lock" then
        if ns.SetLocked then ns.SetLocked(true) end
        print(P .. L["anchors locked."])
    elseif msg == "status" then
        ns.PrintStatus()
    elseif msg == "trace" then
        -- The fight recorder: every cast, swing and hit, and what was made of it,
        -- saved with the settings so it can be read back off disk.
        if not (ns.UseUnitCombat and ns.UC.SetTrace) then
            print(P .. L["the recorder is for the WoW Forever client."])
        elseif ns.UC.Tracing() then
            local n = ns.UC.TraceSize()
            ns.UC.SetTrace(false)
            print(P .. L["recorder off, %d lines kept. /reload to write them to disk."]:format(n))
        else
            ns.UC.SetTrace(true)
            print(P .. L["recorder on. Fight something, then /reload to write it to disk."])
        end
    elseif msg == "probe" then
        if ns.UseUnitCombat and ns.UC.PrintProbe then ns.UC.PrintProbe()
        elseif ns.PrintProbe then ns.PrintProbe()
        else print(P .. L["nothing to probe on this client."]) end
    elseif msg == "export" or msg == "import" then
        if ns.OpenProfile then ns.OpenProfile(msg) end
    elseif msg == "reset" then
        if ns.ResetSettings then ns.ResetSettings() end
        print(P .. L["settings reset to defaults."])
    else
        if ns.ToggleOptions then ns.ToggleOptions() end
    end
end
