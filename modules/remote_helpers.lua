local function getRemotePath(remote)
    if not remote then
        return "nil"
    end

    local ok, result = pcall(function()
        local parts = {}
        local c = remote
        while c and c ~= game do
            table.insert(parts, 1, c.Name)
            c = c.Parent
        end
        table.insert(parts, 1, "game")
        return table.concat(parts, ".")
    end)

    return ok and result or tostring(remote)
end

local function serializeArg(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = typeof(v)

    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" then
        return tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t == "Instance" then
        local ok, p = pcall(getRemotePath, v)
        return ok and p or "Instance"
    elseif t == "Vector3" then
        return ("Vector3.new(%g,%g,%g)"):format(v.X, v.Y, v.Z)
    elseif t == "Vector2" then
        return ("Vector2.new(%g,%g)"):format(v.X, v.Y)
    elseif t == "CFrame" then
        local p = v.Position
        return ("CFrame.new(%g,%g,%g)"):format(p.X, p.Y, p.Z)
    elseif t == "table" then
        if seen[v] then
            return "{<cycle>}"
        end
        if depth >= 2 then
            return "{...}"
        end

        seen[v] = true
        local items, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 6 then
                table.insert(items, "...")
                break
            end
            if type(k) == "number" then
                table.insert(items, serializeArg(val, depth + 1, seen))
            else
                table.insert(items, tostring(k) .. "=" .. serializeArg(val, depth + 1, seen))
            end
        end
        seen[v] = nil

        return "{" .. table.concat(items, ", ") .. "}"
    end

    return tostring(v)
end

local function deepSerializeArg(v, depth, indent)
    depth = depth or 0
    indent = indent or ""
    local t = typeof(v)

    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" then
        return tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t == "Instance" then
        local ok, p = pcall(getRemotePath, v)
        return ok and p or tostring(v)
    elseif t == "Vector3" then
        return ("Vector3.new(%g, %g, %g)"):format(v.X, v.Y, v.Z)
    elseif t == "Vector2" then
        return ("Vector2.new(%g, %g)"):format(v.X, v.Y)
    elseif t == "CFrame" then
        local rx, ry, rz = v:ToEulerAnglesXYZ()
        local p = v.Position
        return ("CFrame.new(%g, %g, %g)  -- rot(%.1f, %.1f, %.1f) deg"):format(
            p.X,
            p.Y,
            p.Z,
            math.deg(rx),
            math.deg(ry),
            math.deg(rz)
        )
    elseif t == "Color3" then
        return ("Color3.fromRGB(%d, %d, %d)"):format(v.R * 255, v.G * 255, v.B * 255)
    elseif t == "UDim2" then
        return ("UDim2.new(%g, %g, %g, %g)"):format(v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
    elseif t == "EnumItem" then
        return tostring(v)
    elseif t == "table" then
        if depth >= 4 then
            return "{...}"
        end

        local ni = indent .. "  "
        local items = {}
        local isArr = (#v > 0)
        for k, val in pairs(v) do
            local entry
            if type(k) == "number" and isArr then
                entry = ni .. deepSerializeArg(val, depth + 1, ni)
            else
                entry = ni .. "[" .. tostring(k) .. "] = " .. deepSerializeArg(val, depth + 1, ni)
            end
            table.insert(items, entry)
        end

        if #items == 0 then
            return "{}"
        end

        return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
    end

    return "(" .. t .. ") " .. tostring(v)
end

local function serializeArgs(args)
    local parts = {}
    for _, v in ipairs(args) do
        table.insert(parts, serializeArg(v, 0, {}))
    end
    return table.concat(parts, ", ")
end

local function buildCode(remote, method, argsStr)
    local path = getRemotePath(remote)
    return argsStr ~= ""
        and ("%s:%s(%s)"):format(path, method, argsStr)
        or ("%s:%s()"):format(path, method)
end

local function tryClipboard(text)
    if setclipboard then
        pcall(setclipboard, text)
        return true
    end
    if Clipboard and Clipboard.set then
        pcall(Clipboard.set, text)
        return true
    end
    return false
end

return {
    getRemotePath = getRemotePath,
    serializeArg = serializeArg,
    deepSerializeArg = deepSerializeArg,
    serializeArgs = serializeArgs,
    buildCode = buildCode,
    tryClipboard = tryClipboard,
}
