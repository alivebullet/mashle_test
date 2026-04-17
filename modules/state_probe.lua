local RemoteHelpers = require("modules/remote_helpers")

local getRemotePath = RemoteHelpers.getRemotePath
local serializeArg = RemoteHelpers.serializeArg

local function safeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function newWeakSet()
    return setmetatable({}, { __mode = "k" })
end

local function asArray(value)
    if type(value) == "table" then
        return value
    end
    return {}
end

local function getInstanceProbePath(root, instance)
    local result = safeGet(function()
        if not root or not instance then
            return "?"
        end

        local parts = {}
        local current = instance
        while current and current ~= root do
            table.insert(parts, 1, current.Name)
            current = current.Parent
        end

        if current ~= root then
            return instance:GetFullName()
        end

        table.insert(parts, 1, root.Name)
        return table.concat(parts, "/")
    end)

    return result or tostring(instance)
end

local function formatStateProbeValue(value)
    if typeof(value) == "Instance" then
        return getRemotePath(value)
    end

    local ok, serialized = pcall(serializeArg, value)
    if ok then
        return serialized
    end

    return tostring(value)
end

local function stateProbeLog(root, eventName, instance, fieldName, value, callback)
    local path = getInstanceProbePath(root, instance)
    local fullPath = safeGet(function()
        return instance:GetFullName()
    end) or path
    local fieldStr = tostring(fieldName)
    local valueType = typeof(value)
    local valueStr = formatStateProbeValue(value)
    local valuePath = valueType == "Instance" and getRemotePath(value) or nil
    local msg = ("[StateProbe][%s] %s :: %s = %s"):format(eventName, path, fieldStr, valueStr)

    if callback then
        callback({
            eventName = eventName,
            path = path,
            fullPath = fullPath,
            fieldName = fieldStr,
            value = valueStr,
            rawValue = value,
            valueType = valueType,
            valuePath = valuePath,
            instance = instance,
            instanceName = safeGet(function() return instance.Name end) or tostring(instance),
            instanceClassName = safeGet(function() return instance.ClassName end) or typeof(instance),
            parentName = safeGet(function()
                return instance.Parent and instance.Parent.Name or "nil"
            end) or "nil",
            message = msg,
        })
    end
end

local function disconnectAll(connections)
    for _, conn in ipairs(asArray(connections)) do
        conn:Disconnect()
    end
    if type(connections) == "table" then
        table.clear(connections)
    end
end

local function watchLocalCharacterState(character, state)
    disconnectAll(state.connections)
    state.seenInstances = newWeakSet()
    state.seenValueObjects = newWeakSet()

    if not character then
        return
    end

    local function bind(signal, fn)
        local conn = signal:Connect(fn)
        table.insert(state.connections, conn)
        return conn
    end

    local function watchAttributes(instance, logExisting)
        if state.seenInstances[instance] then return end
        state.seenInstances[instance] = true

        if logExisting then
            local attributes = safeGet(function()
                return instance:GetAttributes()
            end)
            if type(attributes) == "table" then
                for name, value in pairs(attributes) do
                    stateProbeLog(character, "InitialAttribute", instance, name, value, state.callback)
                end
            end
        end

        bind(instance.AttributeChanged, function(name)
            stateProbeLog(character, "AttributeChanged", instance, name, instance:GetAttribute(name), state.callback)
        end)
    end

    local function watchValueObject(valueObject)
        if state.seenValueObjects[valueObject] then return end
        state.seenValueObjects[valueObject] = true

        stateProbeLog(character, "InitialValue", valueObject, "Value", valueObject.Value, state.callback)
        bind(valueObject:GetPropertyChangedSignal("Value"), function()
            stateProbeLog(character, "ValueChanged", valueObject, "Value", valueObject.Value, state.callback)
        end)
    end

    local function inspectInstance(instance)
        watchAttributes(instance, true)
        if instance:IsA("ValueBase") then
            watchValueObject(instance)
        elseif instance:IsA("Humanoid") then
            stateProbeLog(character, "InitialHumanoidState", instance, "HumanoidState", instance:GetState(), state.callback)
            bind(instance.StateChanged, function(_oldState, newState)
                stateProbeLog(character, "HumanoidStateChanged", instance, "HumanoidState", newState, state.callback)
            end)
        end
    end

    inspectInstance(character)
    for _, instance in ipairs(character:GetDescendants()) do
        inspectInstance(instance)
    end

    bind(character.DescendantAdded, function(instance)
        inspectInstance(instance)
        stateProbeLog(character, "DescendantAdded", instance, "ClassName", instance.ClassName, state.callback)
    end)
end

local function createWatcher(onProbeEvent)
    local state = {
        connections = {},
        seenInstances = newWeakSet(),
        seenValueObjects = newWeakSet(),
        callback = onProbeEvent,
    }

    return function(character)
        watchLocalCharacterState(character, state)
    end
end

return {
    createWatcher = createWatcher,
}