local IGNORED_NAME_PATTERNS = {
    "run", "walk", "idle", "jump", "fall", "climb", "swim", "sit", "wave", "point",
    "cheer", "laugh", "dance", "pose", "stand", "mood", "emote", "toollunge", "toolhold",
    "toolnone", "toolslash",
}

local IGNORED_IDS = {
    ["507767714"] = true, ["507767968"] = true, ["507766388"] = true, ["507766666"] = true,
    ["507765000"] = true, ["507765644"] = true, ["507767715"] = true, ["507768375"] = true,
    ["507768716"] = true, ["180426354"] = true, ["180435571"] = true, ["180435792"] = true,
    ["180436334"] = true, ["180436148"] = true, ["180425148"] = true,
}

local COMBAT_KEYWORDS = {
    "attack", "swing", "slash", "stab", "punch", "kick", "hit", "combo", "m1", "heavy",
    "light", "block", "parry", "dodge", "dash", "ability", "skill", "cast", "shoot", "fire",
    "reload", "sword", "fight", "strike", "uppercut", "jab", "hook", "throw", "grab", "slam",
    "smash", "critical", "ult", "special", "weapon", "melee", "combat", "spell", "magic",
}

local function lower(s)
    return string.lower(s or "")
end

local function matchesAny(str, patterns)
    str = lower(str)
    for _, p in ipairs(patterns) do
        if string.find(str, p, 1, true) then
            return true
        end
    end
    return false
end

local function extractIdNumber(animId)
    return string.match(animId or "", "%d+")
end

local function shouldLogAnimation(animName, animId)
    local idNum = extractIdNumber(animId)
    if idNum and IGNORED_IDS[idNum] then
        return false
    end
    if matchesAny(animName, COMBAT_KEYWORDS) then
        return true
    end
    if matchesAny(animName, IGNORED_NAME_PATTERNS) then
        return false
    end
    return true
end

return {
    extractIdNumber = extractIdNumber,
    shouldLogAnimation = shouldLogAnimation,
}
