local _, ns = ...

-- The addon's own words, in the client's language. The English text is the key, so a
-- key a language has not translated shows in English. Spell, unit and school names come
-- from the client already in its language; what the combat log or a spell's description
-- says is read as it comes, never through this.
ns.L = setmetatable({}, { __index = function(_, k) return k end })
