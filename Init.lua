local ADDON, ns = ...

-- Build the feeds once we're in the world (deferred out of combat for safety).
ns.On("PLAYER_LOGIN", function()
    ns.RunWhenSafe(function()
        if ns.BuildEnemyText then ns.BuildEnemyText() end
        if ns.BuildHealText then ns.BuildHealText() end
        if ns.BuildTakenText then ns.BuildTakenText() end
    end)
end)

-- Slash: open the config panel; /gct test toggles the preview, /gct reset restores.
SLASH_GARUCOMBATTEXT1 = "/gct"
SLASH_GARUCOMBATTEXT2 = "/garucombattext"
SlashCmdList.GARUCOMBATTEXT = function(msg)
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "test" then
        ns.test.combat = not ns.test.combat
        if not ns.test.combat then
            if ns.ClearEnemyText then ns.ClearEnemyText() end
            if ns.ClearHealText then ns.ClearHealText() end
            if ns.ClearTakenText then ns.ClearTakenText() end
        end
        print("|cff66ccffGaru Combat Text|r: preview " .. (ns.test.combat and "ON" or "OFF"))
    elseif msg == "unlock" then
        if ns.SetLocked then ns.SetLocked(false) end
    elseif msg == "lock" then
        if ns.SetLocked then ns.SetLocked(true) end
    elseif msg == "reset" then
        if ns.ResetSettings then ns.ResetSettings() end
    else
        if ns.ToggleOptions then ns.ToggleOptions() end
    end
end
