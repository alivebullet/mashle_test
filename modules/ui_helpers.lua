local function mkCorner(parent, r)
    local c = Instance.new("UICorner", parent)
    c.CornerRadius = UDim.new(0, r or 6)
end

local function mkStroke(parent, defaultStrokeColor, color, thick)
    local s = Instance.new("UIStroke", parent)
    s.Color = color or defaultStrokeColor
    s.Thickness = thick or 1
end

return {
    mkCorner = mkCorner,
    mkStroke = mkStroke,
}
