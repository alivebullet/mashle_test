-- AnimationDetectorUI.lua
-- LocalScript — place in StarterPlayerScripts
-- Enhanced version with pause, search, export, player filtering, theme constants, and better cleanup.
local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local RunService       = game:GetService("RunService")

local DEFAULT_DETECTION_RADIUS = 100
local MAX_DETECTION_RADIUS     = 200
local MAX_LOG_ENTRIES       = 100
local BUILD_TAG = "probe-chips-search-fix2-2026-04-17"

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")
local rangeSphere = nil
local rangeVisualizerConn = nil
local unpackArgs = table.unpack or unpack

-- ========== MODULES ==========
local Theme = require("modules/theme")
local AnimationFilters = require("modules/animation_filters")
local RemoteHelpers = require("modules/remote_helpers")
local StateProbe = require("modules/state_probe")
local UIHelpers = require("modules/ui_helpers")

local extractIdNumber = AnimationFilters.extractIdNumber
local shouldLogAnimation = AnimationFilters.shouldLogAnimation

local getRemotePath = RemoteHelpers.getRemotePath
local serializeArg = RemoteHelpers.serializeArg
local deepSerializeArg = RemoteHelpers.deepSerializeArg
local serializeArgs = RemoteHelpers.serializeArgs
local buildCode = RemoteHelpers.buildCode
local tryClipboard = RemoteHelpers.tryClipboard
local mkCorner = UIHelpers.mkCorner
local function mkStroke(parent, color, thick)
	UIHelpers.mkStroke(parent, Theme.StrokeColor, color, thick)
end

local function asArray(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

-- State probe UI storage
local stateProbeEntries = {}  -- Keyed by "path :: fieldName"
local stateProbeView = {
	filterTypes = {
		{ label = "All", value = "All" },
		{ label = "Bool", value = "boolean" },
		{ label = "Num", value = "number" },
		{ label = "Str", value = "string" },
		{ label = "Inst", value = "Instance" },
		{ label = "Enum", value = "EnumItem" },
		{ label = "Tbl", value = "table" },
		{ label = "Vec3", value = "Vector3" },
		{ label = "Vec2", value = "Vector2" },
		{ label = "CF", value = "CFrame" },
		{ label = "Clr", value = "Color3" },
	},
	selectedFilter = "All",
	searchText = "",
	nextOrder = 0,
}
local stateProbeContainer
local stateProbeSelectedEntry
local stateProbeSelectedEvent
local stateProbeDetailFrame
local stateProbeDetailTitle
local stateProbeDetailBody
local stateProbeCopyPathBtn
local stateProbeCopyValueBtn
local stateProbeCopyLogBtn
local showStateProbeDetail
local flashStateProbeBtn

local function getStateProbeFilterType()
	return stateProbeView.selectedFilter or "All"
end

local function stateProbeMatchesFilter(event)
	local filterType = getStateProbeFilterType()
	if filterType ~= "All" and event.valueType ~= filterType then
		return false
	end

	local search = string.lower(stateProbeView.searchText or "")
	if search == "" then
		return true
	end

	local haystack = string.lower(table.concat({
		event.displayLabel or "",
		event.path or "",
		event.fullPath or "",
		event.value or "",
	}, " "))
	return string.find(haystack, search, 1, true) ~= nil
end

local function applyStateProbeFilter()
	for _, event in pairs(stateProbeEntries) do
		if event.button then
			event.button.Visible = stateProbeMatchesFilter(event)
		end
	end
	for _, chip in ipairs(asArray(stateProbeView.filterChips)) do
		local active = chip.value == getStateProbeFilterType()
		chip.button.BackgroundColor3 = active and Color3.fromRGB(70, 120, 95) or Color3.fromRGB(42, 56, 72)
		chip.button.TextColor3 = active and Color3.fromRGB(240, 255, 245) or Theme.TextPrimary
	end
end

local function getStateProbeEntryLabel(event)
	if event.fieldName == "Value" and event.instanceName and event.instanceName ~= "" then
		return event.instanceName
	end
	return event.fieldName or "Unknown"
end

local function onStateProbeEvent(event)
	if not stateProbeContainer then return end
	
	-- Create unique key for deduplication
	local key = event.path .. " :: " .. event.fieldName
	
	-- Skip if already exists
	if stateProbeEntries[key] then return end
	
	stateProbeEntries[key] = event
	stateProbeView.nextOrder = stateProbeView.nextOrder + 1
	event.order = stateProbeView.nextOrder
	event.displayLabel = getStateProbeEntryLabel(event)
	
	-- Create entry display
	local entryButton = Instance.new("TextButton")
	entryButton.Size = UDim2.new(0, 180, 0, 40)
	entryButton.BackgroundColor3 = Color3.fromRGB(25, 35, 50)
	entryButton.BorderSizePixel = 0
	entryButton.AutoButtonColor = false
	entryButton.Text = event.displayLabel .. " = " .. event.value
	entryButton.TextColor3 = Color3.fromRGB(180, 220, 255)
	entryButton.TextXAlignment = Enum.TextXAlignment.Left
	entryButton.TextYAlignment = Enum.TextYAlignment.Center
	entryButton.Font = Enum.Font.Gotham
	entryButton.TextSize = 10
	entryButton.LayoutOrder = event.order
	entryButton.TextWrapped = true
	entryButton.Parent = stateProbeContainer
	mkCorner(entryButton, 4)
	mkStroke(entryButton, Color3.fromRGB(100, 150, 200), 1)

	event.button = entryButton

	entryButton.MouseEnter:Connect(function()
		if stateProbeSelectedEntry ~= entryButton then
			entryButton.BackgroundColor3 = Color3.fromRGB(35, 50, 70)
		end
	end)
	entryButton.MouseLeave:Connect(function()
		if stateProbeSelectedEntry ~= entryButton then
			entryButton.BackgroundColor3 = Color3.fromRGB(25, 35, 50)
		end
	end)
	entryButton.MouseButton1Click:Connect(function()
		if showStateProbeDetail then
			showStateProbeDetail(event)
		end
	end)

	applyStateProbeFilter()
end

local watchLocalCharacterState = StateProbe.createWatcher(onStateProbeEvent)

-- ========== CLEANUP OLD UI ==========
if playerGui:FindFirstChild("AnimationDetectorUI") then
	playerGui.AnimationDetectorUI:Destroy()
end

-- ========== SCREEN GUI ==========
local screenGui = Instance.new("ScreenGui")
screenGui.Name           = "AnimationDetectorUI"
screenGui.ResetOnSpawn   = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent         = playerGui

-- Reopen button
local reopenBtn = Instance.new("TextButton")
reopenBtn.Size             = UDim2.new(0, 130, 0, 32)
reopenBtn.Position         = UDim2.new(0, 20, 0, 80)
reopenBtn.BackgroundColor3 = Color3.fromRGB(45, 35, 55)
reopenBtn.Text             = "📋 Show Detector"
reopenBtn.TextColor3       = Color3.fromRGB(230, 200, 255)
reopenBtn.Font             = Enum.Font.GothamBold
reopenBtn.TextSize         = 12
reopenBtn.BorderSizePixel  = 0
reopenBtn.Visible          = false
reopenBtn.Parent           = screenGui
mkCorner(reopenBtn, 6);
mkStroke(reopenBtn, Color3.fromRGB(100, 80, 130))

local reopenCloseBtn = Instance.new("TextButton")
reopenCloseBtn.Size             = UDim2.new(0, 24, 0, 32)
reopenCloseBtn.Position         = UDim2.new(0, 156, 0, 80)
reopenCloseBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
reopenCloseBtn.Text             = "X"
reopenCloseBtn.TextColor3       = Theme.TextPrimary
reopenCloseBtn.Font             = Enum.Font.GothamBold
reopenCloseBtn.TextSize         = 12
reopenCloseBtn.BorderSizePixel  = 0
reopenCloseBtn.Visible          = false
reopenCloseBtn.Parent           = screenGui
mkCorner(reopenCloseBtn, 6)

-- ===== Main Frame =====
local mainFrame = Instance.new("Frame")
mainFrame.Name             = "MainFrame"
mainFrame.Size             = UDim2.new(0, 560, 0, 360)
mainFrame.Position         = UDim2.new(0, 20, 0, 80)
mainFrame.BackgroundColor3 = Theme.Background
mainFrame.BorderSizePixel  = 0
mainFrame.Active           = true
mainFrame.Parent           = screenGui
mkCorner(mainFrame, 8);
mkStroke(mainFrame)

-- ===== Title Bar =====
local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Theme.TitleBar
titleBar.BorderSizePixel  = 0
titleBar.Active           = true
titleBar.Parent           = mainFrame
mkCorner(titleBar, 8)

do local titleLabel = Instance.new("TextLabel")
titleLabel.Size               = UDim2.new(0, 210, 1, 0)
titleLabel.Position           = UDim2.new(0, 12, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text               = "Combat & Remote Detector"
titleLabel.TextColor3         = Color3.fromRGB(255, 120, 120)
titleLabel.TextXAlignment     = Enum.TextXAlignment.Left
titleLabel.Font               = Enum.Font.GothamBold
titleLabel.TextSize           = 13
titleLabel.Parent             = titleBar end

local settingsBtn = Instance.new("TextButton")
settingsBtn.Size             = UDim2.new(0, 24, 0, 22)
settingsBtn.Position         = UDim2.new(0, 228, 0, 5)
settingsBtn.BackgroundColor3 = Theme.ButtonDefault
settingsBtn.Text             = "⚙"
settingsBtn.TextColor3       = Theme.TextPrimary
settingsBtn.Font             = Enum.Font.GothamBold
settingsBtn.TextSize         = 12
settingsBtn.BorderSizePixel  = 0
settingsBtn.ZIndex           = 3
settingsBtn.Parent           = titleBar
mkCorner(settingsBtn, 4)

local strictBtn = Instance.new("TextButton")
strictBtn.Size             = UDim2.new(0, 60, 0, 22)
strictBtn.Position         = UDim2.new(1, -215, 0, 5)
strictBtn.BackgroundColor3 = Theme.ButtonDefault
strictBtn.Text             = "Strict: OFF"
strictBtn.TextColor3       = Theme.TextPrimary
strictBtn.Font             = Enum.Font.Gotham
strictBtn.TextSize         = 10
strictBtn.BorderSizePixel  = 0
strictBtn.Parent           = titleBar
mkCorner(strictBtn, 4)

local clearBtn = Instance.new("TextButton")
clearBtn.Size             = UDim2.new(0, 50, 0, 22)
clearBtn.Position         = UDim2.new(1, -150, 0, 5)
clearBtn.BackgroundColor3 = Theme.ButtonDefault
clearBtn.Text             = "Clear"
clearBtn.TextColor3       = Theme.TextPrimary
clearBtn.Font             = Enum.Font.Gotham
clearBtn.TextSize         = 11
clearBtn.BorderSizePixel  = 0
clearBtn.Parent           = titleBar
mkCorner(clearBtn, 4)

-- Animation Pause Button (in Title Bar)
local pauseAnimBtn = Instance.new("TextButton")
pauseAnimBtn.Size             = UDim2.new(0, 60, 0, 22)
pauseAnimBtn.Position         = UDim2.new(1, -95, 0, 5)
pauseAnimBtn.BackgroundColor3 = Theme.ButtonDefault
pauseAnimBtn.Text             = "⏸ Pause"
pauseAnimBtn.TextColor3       = Theme.TextPrimary
pauseAnimBtn.Font             = Enum.Font.Gotham
pauseAnimBtn.TextSize         = 10
pauseAnimBtn.BorderSizePixel  = 0
pauseAnimBtn.Parent           = titleBar
mkCorner(pauseAnimBtn, 4)

-- Remote Pause Button (in Title Bar, hidden by default)
local pauseRemotesBtn = Instance.new("TextButton")
pauseRemotesBtn.Size             = UDim2.new(0, 60, 0, 22)
pauseRemotesBtn.Position         = UDim2.new(1, -95, 0, 5)
pauseRemotesBtn.BackgroundColor3 = Theme.ButtonDefault
pauseRemotesBtn.Text             = "⏸ Pause"
pauseRemotesBtn.TextColor3       = Theme.TextPrimary
pauseRemotesBtn.Font             = Enum.Font.Gotham
pauseRemotesBtn.TextSize         = 10
pauseRemotesBtn.BorderSizePixel  = 0
pauseRemotesBtn.Visible          = false
pauseRemotesBtn.Parent           = titleBar
mkCorner(pauseRemotesBtn, 4)

local probeBtn = Instance.new("TextButton")
probeBtn.Size             = UDim2.new(0, 70, 0, 22)
probeBtn.Position         = UDim2.new(0, 258, 0, 5)
probeBtn.BackgroundColor3 = Color3.fromRGB(60, 100, 80)
probeBtn.Text             = "Probe"
probeBtn.TextColor3       = Theme.TextPrimary
probeBtn.Font             = Enum.Font.Gotham
probeBtn.TextSize         = 10
probeBtn.BorderSizePixel  = 0
probeBtn.Parent           = titleBar
mkCorner(probeBtn, 4)
probeBtn.MouseButton1Click:Connect(function()
	local frame = screenGui:FindFirstChild("StateProbeFrame")
	if frame then
		frame.Visible = not frame.Visible
	end
end)

local mainCloseBtn = Instance.new("TextButton")
mainCloseBtn.Size             = UDim2.new(0, 24, 0, 22)
mainCloseBtn.Position         = UDim2.new(1, -30, 0, 5)
mainCloseBtn.BackgroundColor3 = Theme.ButtonDanger
mainCloseBtn.Text             = "X"
mainCloseBtn.TextColor3       = Theme.TextPrimary
mainCloseBtn.Font             = Enum.Font.GothamBold
mainCloseBtn.TextSize         = 12
mainCloseBtn.BorderSizePixel  = 0
mainCloseBtn.Parent           = titleBar
mkCorner(mainCloseBtn, 4)

mainCloseBtn.MouseEnter:Connect(function() mainCloseBtn.BackgroundColor3 = Color3.fromRGB(220,80,80) end)
mainCloseBtn.MouseLeave:Connect(function() mainCloseBtn.BackgroundColor3 = Theme.ButtonDanger end)

local confirmFrame = Instance.new("Frame")
confirmFrame.Size = UDim2.new(0, 320, 0, 140)
confirmFrame.Position = UDim2.new(0.5, -160, 0.5, -70)
confirmFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
confirmFrame.BorderSizePixel = 0
confirmFrame.Visible = false
confirmFrame.Parent = screenGui
mkCorner(confirmFrame, 10)
mkStroke(confirmFrame, Color3.fromRGB(80, 80, 100))

do
	local confirmTitle = Instance.new("TextLabel")
	confirmTitle.Size = UDim2.new(1, -20, 0, 28)
	confirmTitle.Position = UDim2.new(0, 10, 0, 10)
	confirmTitle.BackgroundTransparency = 1
	confirmTitle.Text = "Confirm Permanent Close"
	confirmTitle.TextColor3 = Color3.fromRGB(240, 240, 250)
	confirmTitle.Font = Enum.Font.GothamBold
	confirmTitle.TextSize = 14
	confirmTitle.TextXAlignment = Enum.TextXAlignment.Left
	confirmTitle.Parent = confirmFrame

	local confirmText = Instance.new("TextLabel")
	confirmText.Size = UDim2.new(1, -20, 0, 60)
	confirmText.Position = UDim2.new(0, 10, 0, 45)
	confirmText.BackgroundTransparency = 1
	confirmText.Text = "Do you want to permanently close the script?\nYes will destroy all UI created by this script."
	confirmText.TextColor3 = Color3.fromRGB(200, 200, 210)
	confirmText.Font = Enum.Font.Gotham
	confirmText.TextSize = 12
	confirmText.TextWrapped = true
	confirmText.TextYAlignment = Enum.TextYAlignment.Top
	confirmText.Parent = confirmFrame

	local confirmButtons = Instance.new("Frame")
	confirmButtons.Size = UDim2.new(1, -20, 0, 36)
	confirmButtons.Position = UDim2.new(0, 10, 1, -46)
	confirmButtons.BackgroundTransparency = 1
	confirmButtons.Parent = confirmFrame

	local confirmYes = Instance.new("TextButton")
	confirmYes.Size = UDim2.new(0.48, 0, 1, 0)
	confirmYes.Position = UDim2.new(0, 0, 0, 0)
	confirmYes.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	confirmYes.Text = "Yes"
	confirmYes.TextColor3 = Theme.TextPrimary
	confirmYes.Font = Enum.Font.GothamBold
	confirmYes.TextSize = 12
	confirmYes.BorderSizePixel = 0
	confirmYes.Parent = confirmButtons
	mkCorner(confirmYes, 6)

	local confirmNo = Instance.new("TextButton")
	confirmNo.Size = UDim2.new(0.48, 0, 1, 0)
	confirmNo.Position = UDim2.new(0.52, 0, 0, 0)
	confirmNo.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
	confirmNo.Text = "No"
	confirmNo.TextColor3 = Theme.TextPrimary
	confirmNo.Font = Enum.Font.GothamBold
	confirmNo.TextSize = 12
	confirmNo.BorderSizePixel = 0
	confirmNo.Parent = confirmButtons
	mkCorner(confirmNo, 6)

	local function destroyScriptUI()
		if rangeVisualizerConn then
			rangeVisualizerConn:Disconnect()
			rangeVisualizerConn = nil
		end
		if rangeSphere then
			rangeSphere:Destroy()
			rangeSphere = nil
		end
		if screenGui and screenGui.Parent then screenGui:Destroy() end
		if detailFrame and detailFrame.Parent then detailFrame:Destroy() end
		if remDetailFrame and remDetailFrame.Parent then remDetailFrame:Destroy() end
	end

	confirmYes.MouseButton1Click:Connect(function()
		destroyScriptUI()
	end)

	confirmNo.MouseButton1Click:Connect(function()
		confirmFrame.Visible = false
	end)
end

mainCloseBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = false
	reopenBtn.Visible = true
	reopenCloseBtn.Visible = true
end)

reopenBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = true
	reopenBtn.Visible = false
	reopenCloseBtn.Visible = false
end)

reopenCloseBtn.MouseButton1Click:Connect(function()
	confirmFrame.Visible = true
end)

-- ===== Tab Bar =====
local tabBar = Instance.new("Frame")
tabBar.Size             = UDim2.new(1, 0, 0, 28)
tabBar.Position         = UDim2.new(0, 0, 0, 32)
tabBar.BackgroundColor3 = Color3.fromRGB(18, 18, 23)
tabBar.BorderSizePixel  = 0
tabBar.Parent           = mainFrame

local animTabBtn = Instance.new("TextButton")
animTabBtn.Size             = UDim2.new(0.5, -4, 1, -6)
animTabBtn.Position         = UDim2.new(0, 4, 0, 3)
animTabBtn.BackgroundColor3 = Theme.TabActive
animTabBtn.Text             = "🎬  Animations"
animTabBtn.TextColor3       = Theme.TabTextActive
animTabBtn.Font             = Enum.Font.GothamBold
animTabBtn.TextSize         = 11
animTabBtn.BorderSizePixel  = 0
animTabBtn.Parent           = tabBar
mkCorner(animTabBtn, 4)

local remoteTabBtn = Instance.new("TextButton")
remoteTabBtn.Size             = UDim2.new(0.5, -4, 1, -6)
remoteTabBtn.Position         = UDim2.new(0.5, 0, 0, 3)
remoteTabBtn.BackgroundColor3 = Theme.TabInactive
remoteTabBtn.Text             = "📡  Remotes"
remoteTabBtn.TextColor3       = Theme.TabTextInactive
remoteTabBtn.Font             = Enum.Font.Gotham
remoteTabBtn.TextSize         = 11
remoteTabBtn.BorderSizePixel  = 0
remoteTabBtn.Parent           = tabBar
mkCorner(remoteTabBtn, 4)

-- ===== Status Label =====
local statusLabel = Instance.new("TextLabel")
statusLabel.Size               = UDim2.new(1, -276, 0, 18)
statusLabel.Position           = UDim2.new(0, 8, 0, 62)
statusLabel.BackgroundTransparency = 1
statusLabel.Text               = "Detected: 0  | Filtered: 0"
statusLabel.TextColor3         = Color3.fromRGB(160, 200, 255)
statusLabel.TextXAlignment     = Enum.TextXAlignment.Left
statusLabel.Font               = Enum.Font.Gotham
statusLabel.TextSize           = 11
statusLabel.Parent             = mainFrame

local openPausedRemotesBtn = Instance.new("TextButton")
openPausedRemotesBtn.Size = UDim2.new(0, 142, 0, 18)
openPausedRemotesBtn.Position = UDim2.new(1, -150, 0, 62)
openPausedRemotesBtn.BackgroundColor3 = Color3.fromRGB(42, 74, 120)
openPausedRemotesBtn.Text = "Open Paused Remotes"
openPausedRemotesBtn.TextColor3 = Theme.TextPrimary
openPausedRemotesBtn.Font = Enum.Font.Gotham
openPausedRemotesBtn.TextSize = 10
openPausedRemotesBtn.BorderSizePixel = 0
openPausedRemotesBtn.Visible = false
openPausedRemotesBtn.Parent = mainFrame
mkCorner(openPausedRemotesBtn, 4)

local openPausedAnimationsBtn = Instance.new("TextButton")
openPausedAnimationsBtn.Size = UDim2.new(0, 142, 0, 18)
openPausedAnimationsBtn.Position = UDim2.new(1, -150, 0, 62)
openPausedAnimationsBtn.BackgroundColor3 = Color3.fromRGB(42, 74, 120)
openPausedAnimationsBtn.Text = "Open Paused Animations"
openPausedAnimationsBtn.TextColor3 = Theme.TextPrimary
openPausedAnimationsBtn.Font = Enum.Font.Gotham
openPausedAnimationsBtn.TextSize = 10
openPausedAnimationsBtn.BorderSizePixel = 0
openPausedAnimationsBtn.Visible = false
openPausedAnimationsBtn.Parent = mainFrame
mkCorner(openPausedAnimationsBtn, 4)

-- ===== ANIMATIONS Content =====
local animContent = Instance.new("Frame")
animContent.Size              = UDim2.new(1, 0, 1, -82)
animContent.Position          = UDim2.new(0, 0, 0, 82)
animContent.BackgroundTransparency = 1
animContent.Visible           = true
animContent.Parent            = mainFrame

local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size               = UDim2.new(1, -16, 1, -8)
scrollFrame.Position           = UDim2.new(0, 8, 0, 0)
scrollFrame.BackgroundColor3   = Color3.fromRGB(15, 15, 20)
scrollFrame.BorderSizePixel    = 0
scrollFrame.ScrollBarThickness = 6
scrollFrame.ScrollBarImageColor3 = Theme.ScrollBarColor
scrollFrame.CanvasSize         = UDim2.new(0, 0, 0, 0)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.Parent             = animContent
mkCorner(scrollFrame, 4)
Instance.new("UIListLayout", scrollFrame).SortOrder = Enum.SortOrder.LayoutOrder
do
	local sfPad = Instance.new("UIPadding", scrollFrame)
	sfPad.PaddingTop = UDim.new(0,4)
	sfPad.PaddingLeft = UDim.new(0,6)
	sfPad.PaddingRight = UDim.new(0,6)
end
do local ll = scrollFrame:FindFirstChildOfClass("UIListLayout");
ll.Padding = UDim.new(0,2) end

-- ===== REMOTES Content =====
local remoteContent = Instance.new("Frame")
remoteContent.Size              = UDim2.new(1, 0, 1, -82)
remoteContent.Position          = UDim2.new(0, 0, 0, 82)
remoteContent.BackgroundTransparency = 1
remoteContent.Visible           = false
remoteContent.Parent            = mainFrame

-- ===== SETTINGS Content =====
local settingsContent = Instance.new("Frame")
settingsContent.Size              = UDim2.new(1, 0, 1, -82)
settingsContent.Position          = UDim2.new(0, 0, 0, 82)
settingsContent.BackgroundTransparency = 1
settingsContent.Visible           = false
settingsContent.Parent            = mainFrame

local settingsPanel = Instance.new("Frame")
settingsPanel.Size = UDim2.new(1, -16, 1, -8)
settingsPanel.Position = UDim2.new(0, 8, 0, 0)
settingsPanel.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
settingsPanel.BorderSizePixel = 0
settingsPanel.Parent = settingsContent
mkCorner(settingsPanel, 4)
mkStroke(settingsPanel, Color3.fromRGB(48, 48, 60))

do local settingsTitle = Instance.new("TextLabel")
settingsTitle.Size = UDim2.new(1, -20, 0, 24)
settingsTitle.Position = UDim2.new(0, 10, 0, 10)
settingsTitle.BackgroundTransparency = 1
settingsTitle.Text = "Settings"
settingsTitle.TextColor3 = Theme.TextPrimary
settingsTitle.TextXAlignment = Enum.TextXAlignment.Left
settingsTitle.Font = Enum.Font.GothamBold
settingsTitle.TextSize = 13
settingsTitle.Parent = settingsPanel end

local detectionSection = Instance.new("Frame")
detectionSection.Size = UDim2.new(1, -20, 1, -42)
detectionSection.Position = UDim2.new(0, 10, 0, 40)
detectionSection.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
detectionSection.BorderSizePixel = 0
detectionSection.Parent = settingsPanel
mkCorner(detectionSection, 6)
mkStroke(detectionSection, Color3.fromRGB(62, 62, 82))

do local detectionSectionTitle = Instance.new("TextLabel")
detectionSectionTitle.Size = UDim2.new(1, -16, 0, 18)
detectionSectionTitle.Position = UDim2.new(0, 8, 0, 8)
detectionSectionTitle.BackgroundTransparency = 1
detectionSectionTitle.Text = "Detection Range"
detectionSectionTitle.TextColor3 = Theme.TextPrimary
detectionSectionTitle.TextXAlignment = Enum.TextXAlignment.Left
detectionSectionTitle.Font = Enum.Font.GothamBold
detectionSectionTitle.TextSize = 11
detectionSectionTitle.Parent = detectionSection end

local rangeValueLabel = Instance.new("TextLabel")
rangeValueLabel.Size = UDim2.new(1, -20, 0, 22)
rangeValueLabel.Position = UDim2.new(0, 10, 0, 30)
rangeValueLabel.BackgroundTransparency = 1
rangeValueLabel.Text = "Detection Range: 100 studs"
rangeValueLabel.TextColor3 = Color3.fromRGB(165, 215, 255)
rangeValueLabel.TextXAlignment = Enum.TextXAlignment.Left
rangeValueLabel.Font = Enum.Font.Gotham
rangeValueLabel.TextSize = 11
rangeValueLabel.Parent = detectionSection

local rangeSliderTrack = Instance.new("Frame")
rangeSliderTrack.Size = UDim2.new(1, -20, 0, 12)
rangeSliderTrack.Position = UDim2.new(0, 10, 0, 54)
rangeSliderTrack.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
rangeSliderTrack.BorderSizePixel = 0
rangeSliderTrack.Parent = detectionSection
mkCorner(rangeSliderTrack, 6)

local rangeSliderFill = Instance.new("Frame")
rangeSliderFill.Size = UDim2.new(0.5, 0, 1, 0)
rangeSliderFill.BackgroundColor3 = Color3.fromRGB(75, 120, 185)
rangeSliderFill.BorderSizePixel = 0
rangeSliderFill.Parent = rangeSliderTrack
mkCorner(rangeSliderFill, 6)

local rangeSliderKnob = Instance.new("Frame")
rangeSliderKnob.Size = UDim2.new(0, 14, 0, 14)
rangeSliderKnob.Position = UDim2.new(0.5, -7, 0.5, -7)
rangeSliderKnob.BackgroundColor3 = Color3.fromRGB(210, 220, 240)
rangeSliderKnob.BorderSizePixel = 0
rangeSliderKnob.Parent = rangeSliderTrack
mkCorner(rangeSliderKnob, 7)

do local rangeMinLabel = Instance.new("TextLabel")
rangeMinLabel.Size = UDim2.new(0, 28, 0, 16)
rangeMinLabel.Position = UDim2.new(0, 10, 0, 70)
rangeMinLabel.BackgroundTransparency = 1
rangeMinLabel.Text = "0"
rangeMinLabel.TextColor3 = Theme.TextMuted
rangeMinLabel.Font = Enum.Font.Gotham
rangeMinLabel.TextSize = 10
rangeMinLabel.TextXAlignment = Enum.TextXAlignment.Left
rangeMinLabel.Parent = detectionSection
local rangeMaxLabel = Instance.new("TextLabel")
rangeMaxLabel.Size = UDim2.new(0, 40, 0, 16)
rangeMaxLabel.Position = UDim2.new(1, -50, 0, 70)
rangeMaxLabel.BackgroundTransparency = 1
rangeMaxLabel.Text = "200"
rangeMaxLabel.TextColor3 = Theme.TextMuted
rangeMaxLabel.Font = Enum.Font.Gotham
rangeMaxLabel.TextSize = 10
rangeMaxLabel.TextXAlignment = Enum.TextXAlignment.Right
rangeMaxLabel.Parent = detectionSection end

local visualizeRangeBtn = Instance.new("TextButton")
visualizeRangeBtn.Size = UDim2.new(0, 170, 0, 24)
visualizeRangeBtn.Position = UDim2.new(0, 10, 0, 92)
visualizeRangeBtn.BackgroundColor3 = Theme.ButtonDefault
visualizeRangeBtn.Text = "Visualize Range: OFF"
visualizeRangeBtn.TextColor3 = Theme.TextPrimary
visualizeRangeBtn.Font = Enum.Font.Gotham
visualizeRangeBtn.TextSize = 10
visualizeRangeBtn.BorderSizePixel = 0
visualizeRangeBtn.Parent = detectionSection
mkCorner(visualizeRangeBtn, 4)

do local visualSettingsLabel = Instance.new("TextLabel")
visualSettingsLabel.Size = UDim2.new(1, -20, 0, 20)
visualSettingsLabel.Position = UDim2.new(0, 10, 0, 120)
visualSettingsLabel.BackgroundTransparency = 1
visualSettingsLabel.Text = "Color & Opacity"
visualSettingsLabel.TextColor3 = Theme.TextPrimary
visualSettingsLabel.TextXAlignment = Enum.TextXAlignment.Left
visualSettingsLabel.Font = Enum.Font.GothamBold
visualSettingsLabel.TextSize = 11
visualSettingsLabel.Parent = detectionSection end

local colorPreviewLabel = Instance.new("TextLabel")
colorPreviewLabel.Size = UDim2.new(0, 48, 0, 16)
colorPreviewLabel.Position = UDim2.new(0, 8, 0, 6)
colorPreviewLabel.BackgroundTransparency = 1
colorPreviewLabel.Text = "Color"
colorPreviewLabel.TextColor3 = Theme.TextSecondary
colorPreviewLabel.TextXAlignment = Enum.TextXAlignment.Left
colorPreviewLabel.Font = Enum.Font.Gotham
colorPreviewLabel.TextSize = 10
colorPreviewLabel.Parent = detectionSection

local colorHexLabel = Instance.new("TextLabel")
colorHexLabel.Size = UDim2.new(0, 62, 0, 16)
colorHexLabel.Position = UDim2.new(1, -92, 0, 6)
colorHexLabel.BackgroundTransparency = 1
colorHexLabel.Text = "#4B82FF"
colorHexLabel.TextColor3 = Theme.TextMuted
colorHexLabel.TextXAlignment = Enum.TextXAlignment.Right
colorHexLabel.Font = Enum.Font.Gotham
colorHexLabel.TextSize = 10
colorHexLabel.Parent = detectionSection

local colorPreviewSwatch = Instance.new("Frame")
colorPreviewSwatch.Size = UDim2.new(0, 20, 0, 20)
colorPreviewSwatch.Position = UDim2.new(1, -26, 0, 4)
colorPreviewSwatch.BackgroundColor3 = Color3.fromRGB(75, 130, 255)
colorPreviewSwatch.BorderSizePixel = 0
colorPreviewSwatch.Parent = detectionSection
mkCorner(colorPreviewSwatch, 4)
mkStroke(colorPreviewSwatch, Color3.fromRGB(85, 85, 105))

local colorPickerFrame = Instance.new("Frame")
colorPickerFrame.Size = UDim2.new(1, -20, 0, 88)
colorPickerFrame.Position = UDim2.new(0, 10, 0, 136)
colorPickerFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
colorPickerFrame.BorderSizePixel = 0
colorPickerFrame.Visible = true
colorPickerFrame.ZIndex = 8
colorPickerFrame.Parent = detectionSection
mkCorner(colorPickerFrame, 6)
mkStroke(colorPickerFrame, Color3.fromRGB(78, 78, 98))

colorPreviewLabel.Parent = colorPickerFrame
colorHexLabel.Parent = colorPickerFrame
colorPreviewSwatch.Parent = colorPickerFrame

do local colorPickerTitle = Instance.new("TextLabel")
colorPickerTitle.Size = UDim2.new(1, -16, 0, 18)
colorPickerTitle.Position = UDim2.new(0, 8, 0, 5)
colorPickerTitle.BackgroundTransparency = 1
colorPickerTitle.Text = ""
colorPickerTitle.TextColor3 = Theme.TextPrimary
colorPickerTitle.TextXAlignment = Enum.TextXAlignment.Left
colorPickerTitle.Font = Enum.Font.GothamBold
colorPickerTitle.TextSize = 10
colorPickerTitle.ZIndex = 9
colorPickerTitle.Parent = colorPickerFrame
local hueLabel = Instance.new("TextLabel")
hueLabel.Size = UDim2.new(0, 56, 0, 16)
hueLabel.Position = UDim2.new(0, 8, 0, 24)
hueLabel.BackgroundTransparency = 1
hueLabel.Text = "Hue"
hueLabel.TextColor3 = Theme.TextSecondary
hueLabel.TextXAlignment = Enum.TextXAlignment.Left
hueLabel.Font = Enum.Font.Gotham
hueLabel.TextSize = 10
hueLabel.ZIndex = 9
hueLabel.Parent = colorPickerFrame end

local hueValueLabel = Instance.new("TextLabel")
hueValueLabel.Size = UDim2.new(0, 42, 0, 16)
hueValueLabel.Position = UDim2.new(1, -50, 0, 24)
hueValueLabel.BackgroundTransparency = 1
hueValueLabel.Text = "0°"
hueValueLabel.TextColor3 = Theme.TextMuted
hueValueLabel.TextXAlignment = Enum.TextXAlignment.Right
hueValueLabel.Font = Enum.Font.Gotham
hueValueLabel.TextSize = 10
hueValueLabel.ZIndex = 9
hueValueLabel.Parent = colorPickerFrame

local hueTrack = Instance.new("Frame")
hueTrack.Size = UDim2.new(1, -74, 0, 10)
hueTrack.Position = UDim2.new(0, 64, 0, 27)
hueTrack.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
hueTrack.BorderSizePixel = 0
hueTrack.Active = true
hueTrack.ZIndex = 9
hueTrack.Parent = colorPickerFrame
mkCorner(hueTrack, 5)

do local hueGradient = Instance.new("UIGradient")
hueGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
	ColorSequenceKeypoint.new(0.16, Color3.fromRGB(255, 255, 0)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
	ColorSequenceKeypoint.new(0.66, Color3.fromRGB(0, 0, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
})
hueGradient.Parent = hueTrack end

local hueKnob = Instance.new("Frame")
hueKnob.Size = UDim2.new(0, 12, 0, 12)
hueKnob.Position = UDim2.new(0, -6, 0.5, -6)
hueKnob.BackgroundColor3 = Color3.fromRGB(230, 230, 240)
hueKnob.BorderSizePixel = 0
hueKnob.ZIndex = 10
hueKnob.Parent = hueTrack
mkCorner(hueKnob, 6)
mkStroke(hueKnob, Color3.fromRGB(20, 20, 24))

local satLabel = Instance.new("TextLabel")
satLabel.Size = UDim2.new(0, 56, 0, 16)
satLabel.Position = UDim2.new(0, 8, 0, 46)
satLabel.BackgroundTransparency = 1
satLabel.Text = "Saturation"
satLabel.TextColor3 = Theme.TextSecondary
satLabel.TextXAlignment = Enum.TextXAlignment.Left
satLabel.Font = Enum.Font.Gotham
satLabel.TextSize = 10
satLabel.ZIndex = 9
satLabel.Parent = colorPickerFrame

local satValueLabel = Instance.new("TextLabel")
satValueLabel.Size = UDim2.new(0, 42, 0, 16)
satValueLabel.Position = UDim2.new(1, -50, 0, 46)
satValueLabel.BackgroundTransparency = 1
satValueLabel.Text = "100%"
satValueLabel.TextColor3 = Theme.TextMuted
satValueLabel.TextXAlignment = Enum.TextXAlignment.Right
satValueLabel.Font = Enum.Font.Gotham
satValueLabel.TextSize = 10
satValueLabel.ZIndex = 9
satValueLabel.Parent = colorPickerFrame

local satTrack = Instance.new("Frame")
satTrack.Size = UDim2.new(1, -74, 0, 10)
satTrack.Position = UDim2.new(0, 64, 0, 49)
satTrack.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
satTrack.BorderSizePixel = 0
satTrack.Active = true
satTrack.ZIndex = 9
satTrack.Parent = colorPickerFrame
mkCorner(satTrack, 5)

local satGradient = Instance.new("UIGradient")
satGradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(75, 130, 255))
satGradient.Parent = satTrack

local satKnob = Instance.new("Frame")
satKnob.Size = UDim2.new(0, 12, 0, 12)
satKnob.Position = UDim2.new(1, -6, 0.5, -6)
satKnob.BackgroundColor3 = Color3.fromRGB(230, 230, 240)
satKnob.BorderSizePixel = 0
satKnob.ZIndex = 10
satKnob.Parent = satTrack
mkCorner(satKnob, 6)
mkStroke(satKnob, Color3.fromRGB(20, 20, 24))

local opacitySlider
do
	local function createSimpleSlider(parent, y, labelText, minVal, maxVal)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 74, 0, 16)
		label.Position = UDim2.new(0, 10, 0, y)
		label.BackgroundTransparency = 1
		label.Text = labelText
		label.TextColor3 = Theme.TextSecondary
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.Gotham
		label.TextSize = 10
		label.Parent = parent

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Size = UDim2.new(0, 40, 0, 16)
		valueLabel.Position = UDim2.new(1, -50, 0, y)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Text = tostring(minVal)
		valueLabel.TextColor3 = Theme.TextMuted
		valueLabel.TextXAlignment = Enum.TextXAlignment.Right
		valueLabel.Font = Enum.Font.Gotham
		valueLabel.TextSize = 10
		valueLabel.Parent = parent

		local track = Instance.new("Frame")
		track.Size = UDim2.new(1, -130, 0, 10)
		track.Position = UDim2.new(0, 84, 0, y + 3)
		track.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
		track.BorderSizePixel = 0
		track.Parent = parent
		mkCorner(track, 5)

		local fill = Instance.new("Frame")
		fill.Size = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3 = Color3.fromRGB(75, 120, 185)
		fill.BorderSizePixel = 0
		fill.Parent = track
		mkCorner(fill, 5)

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 12, 0, 12)
		knob.Position = UDim2.new(0, -6, 0.5, -6)
		knob.BackgroundColor3 = Color3.fromRGB(210, 220, 240)
		knob.BorderSizePixel = 0
		knob.Parent = track
		mkCorner(knob, 6)

		return {
			min = minVal,
			max = maxVal,
			label = label,
			valueLabel = valueLabel,
			track = track,
			fill = fill,
			knob = knob,
		}
	end

	opacitySlider = createSimpleSlider(colorPickerFrame, 68, "Opacity", 0, 100)
end
opacitySlider.fill.BackgroundColor3 = Color3.fromRGB(120, 120, 170)

local settingsBackBtn = Instance.new("TextButton")
settingsBackBtn.Size = UDim2.new(0, 90, 0, 24)
settingsBackBtn.Position = UDim2.new(1, -100, 0, 10)
settingsBackBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
settingsBackBtn.Text = "Back"
settingsBackBtn.TextColor3 = Theme.TextPrimary
settingsBackBtn.Font = Enum.Font.GothamBold
settingsBackBtn.TextSize = 11
settingsBackBtn.BorderSizePixel = 0
settingsBackBtn.Parent = settingsPanel
mkCorner(settingsBackBtn, 4)

-- Search bar for remotes
local remoteSearchFrame = Instance.new("Frame")
remoteSearchFrame.Size = UDim2.new(1, -16, 0, 26)
remoteSearchFrame.Position = UDim2.new(0, 8, 0, 0)
remoteSearchFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 23)
remoteSearchFrame.BorderSizePixel = 0
remoteSearchFrame.Parent = remoteContent
mkCorner(remoteSearchFrame, 4)

local searchBox = Instance.new("TextBox")
searchBox.Size = UDim2.new(1, -10, 1, -6)
searchBox.Position = UDim2.new(0, 5, 0, 3)
searchBox.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
searchBox.Text = ""
searchBox.PlaceholderText = "🔍 Filter remotes..."
searchBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
searchBox.TextColor3 = Theme.TextPrimary
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 11
searchBox.BorderSizePixel = 0
searchBox.ClearTextOnFocus = false
searchBox.Parent = remoteSearchFrame
mkCorner(searchBox, 4)

local remoteScroll = Instance.new("ScrollingFrame")
remoteScroll.Size               = UDim2.new(1, -16, 1, -78)
remoteScroll.Position           = UDim2.new(0, 8, 0, 32)
remoteScroll.BackgroundColor3   = Color3.fromRGB(15, 15, 20)
remoteScroll.BorderSizePixel    = 0
remoteScroll.ScrollBarThickness = 6
remoteScroll.ScrollBarImageColor3 = Theme.ScrollBarColor
remoteScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
remoteScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
remoteScroll.Parent             = remoteContent
mkCorner(remoteScroll, 4)
do
	local remLL = Instance.new("UIListLayout", remoteScroll)
	remLL.SortOrder = Enum.SortOrder.LayoutOrder
	remLL.Padding = UDim.new(0, 2)
	local remPad = Instance.new("UIPadding", remoteScroll)
	remPad.PaddingTop = UDim.new(0,4)
	remPad.PaddingLeft = UDim.new(0,6)
	remPad.PaddingRight = UDim.new(0,6)
end

-- ===== Remote Action Bar =====
local remoteActionBar = Instance.new("Frame")
remoteActionBar.Size             = UDim2.new(1, -16, 0, 38)
remoteActionBar.Position         = UDim2.new(0, 8, 1, -42)
remoteActionBar.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
remoteActionBar.BorderSizePixel  = 0
remoteActionBar.Parent           = remoteContent
mkCorner(remoteActionBar, 5);
mkStroke(remoteActionBar, Color3.fromRGB(50, 50, 65))

local copyCodeBtn, copyPathBtn, runCodeBtn, clearRemBtn
do
	local actionColors = {
		Color3.fromRGB(48, 88, 150), Color3.fromRGB(42, 112, 72),
		Color3.fromRGB(68, 110, 45), Color3.fromRGB(130, 48, 48),
	}
	local actionLabels = { "Copy Code", "Copy Path", "Run Code", "Clear" }
	local actionBtns = {}
	for i = 1, 4 do
		local btn = Instance.new("TextButton")
		btn.Size             = UDim2.new(0.25, -5, 1, -10)
		btn.Position         = UDim2.new((i-1)*0.25, (i==1 and 5 or 3), 0, 5)
		btn.BackgroundColor3 = actionColors[i]
		btn.Text             = actionLabels[i]
		btn.TextColor3       = Theme.TextPrimary
		btn.Font             = Enum.Font.Gotham; btn.TextSize = 10
		btn.BorderSizePixel  = 0
		btn.AutoButtonColor = false
		btn.Parent           = remoteActionBar
		mkCorner(btn, 4)
		btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.25 end)
		btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0    end)
		actionBtns[i] = btn
	end
	copyCodeBtn, copyPathBtn, runCodeBtn, clearRemBtn = actionBtns[1], actionBtns[2], actionBtns[3], actionBtns[4]
end

-- Export logs button for remotes
local exportRemotesBtn = Instance.new("TextButton")
exportRemotesBtn.Size = UDim2.new(0, 58, 0, 18)
exportRemotesBtn.Position = UDim2.new(1, -212, 0, 62)
exportRemotesBtn.BackgroundColor3 = Theme.ButtonDefault
exportRemotesBtn.Text = "📤 Export"
exportRemotesBtn.TextColor3 = Theme.TextPrimary
exportRemotesBtn.Font = Enum.Font.Gotham
exportRemotesBtn.TextSize = 10
exportRemotesBtn.BorderSizePixel = 0
exportRemotesBtn.Visible = false
exportRemotesBtn.Parent = mainFrame
mkCorner(exportRemotesBtn, 4)

local exportAnimationsBtn = Instance.new("TextButton")
exportAnimationsBtn.Size = UDim2.new(0, 58, 0, 18)
exportAnimationsBtn.Position = UDim2.new(1, -212, 0, 62)
exportAnimationsBtn.BackgroundColor3 = Theme.ButtonDefault
exportAnimationsBtn.Text = "📤 Export"
exportAnimationsBtn.TextColor3 = Theme.TextPrimary
exportAnimationsBtn.Font = Enum.Font.Gotham
exportAnimationsBtn.TextSize = 10
exportAnimationsBtn.BorderSizePixel = 0
exportAnimationsBtn.Visible = false
exportAnimationsBtn.Parent = mainFrame
mkCorner(exportAnimationsBtn, 4)

-- Filter by local player toggle
local localPlayerFilterBtn = Instance.new("TextButton")
localPlayerFilterBtn.Size = UDim2.new(0, 52, 0, 18)
localPlayerFilterBtn.Position = UDim2.new(1, -268, 0, 62)
localPlayerFilterBtn.BackgroundColor3 = Theme.ButtonDefault
localPlayerFilterBtn.Text = "All"
localPlayerFilterBtn.TextColor3 = Theme.TextPrimary
localPlayerFilterBtn.Font = Enum.Font.Gotham
localPlayerFilterBtn.TextSize = 10
localPlayerFilterBtn.BorderSizePixel = 0
localPlayerFilterBtn.Visible = false
localPlayerFilterBtn.Parent = mainFrame
mkCorner(localPlayerFilterBtn, 4)

-- ===== Resize grip (main) =====
local resizeGrip = Instance.new("TextButton")
resizeGrip.Size                   = UDim2.new(0, 16, 0, 16)
resizeGrip.Position               = UDim2.new(1, -18, 1, -18)
resizeGrip.BackgroundColor3       = Theme.ScrollBarColor
resizeGrip.BackgroundTransparency = 0.4
resizeGrip.Text                   = "⇲"
resizeGrip.TextColor3             = Theme.TextPrimary
resizeGrip.Font                   = Enum.Font.GothamBold;
resizeGrip.TextSize = 12
resizeGrip.BorderSizePixel        = 0;
resizeGrip.AutoButtonColor = false
resizeGrip.Parent                 = mainFrame
mkCorner(resizeGrip, 3)
resizeGrip.MouseEnter:Connect(function() resizeGrip.BackgroundTransparency = 0   end)
resizeGrip.MouseLeave:Connect(function() resizeGrip.BackgroundTransparency = 0.4 end)

-- ========== STATE (Includes new Pause tables) ==========
local detectionCount      = 0
local filteredCount       = 0
local remoteCount         = 0
local entryOrder          = 0
local strictMode          = false
local currentAnimDetail   = nil
local selectedRemoteData  = nil
local selectedRemoteEntry = nil
local activeTab           = "animations"
local animLogPaused       = false
local remoteLogPaused     = false
local remoteFilterLocal   = false  -- show only local player's remotes
local remoteSearchText    = ""
local pausedIndividualRemotes = {} -- Tracks specifically paused remotes
local pausedRemoteArchive = {} -- Keeps a restorable snapshot of paused remotes
local pausedAnimationArchive = {}
local pausedIndividualAnimations = {} -- animId -> data when individually paused
local animEntries = {}
local seenAnimationEntries = {}
local detectionRadius     = DEFAULT_DETECTION_RADIUS
local previousTab         = "animations"
local activeSliderUpdate  = nil
local rangeVisualizerEnabled = false
local rangeColorR, rangeColorG, rangeColorB = 75, 130, 255
local rangeOpacityPercent = 22
local rangeHue, rangeSat, rangeVal = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB):ToHSV()

local function getOriginPosition()
	local c = localPlayer.Character
	if c and c:FindFirstChild("HumanoidRootPart") then
		return c.HumanoidRootPart.Position
	end
end

local function updateRangeVisualizer()
	if not rangeVisualizerEnabled then
		if rangeVisualizerConn then
			rangeVisualizerConn:Disconnect()
			rangeVisualizerConn = nil
		end
		if rangeSphere then
			rangeSphere:Destroy()
			rangeSphere = nil
		end
		return
	end

	if not rangeSphere then
		rangeSphere = Instance.new("Part")
		rangeSphere.Name = "AnimDetectRangeSphere"
		rangeSphere.Shape = Enum.PartType.Ball
		rangeSphere.Anchored = true
		rangeSphere.CanCollide = false
		rangeSphere.CanQuery = false
		rangeSphere.CastShadow = false
		rangeSphere.Material = Enum.Material.ForceField
		rangeSphere.Color = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB)
		rangeSphere.Transparency = 1 - (rangeOpacityPercent / 100)
		rangeSphere.Parent = workspace
	end

	local diameter = math.max(0.1, detectionRadius * 2)
	rangeSphere.Size = Vector3.new(diameter, diameter, diameter)
	rangeSphere.Color = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB)
	local origin = getOriginPosition()
	if origin then
		rangeSphere.Position = origin
		rangeSphere.Transparency = 1 - (rangeOpacityPercent / 100)
	else
		rangeSphere.Transparency = 1
	end

	if not rangeVisualizerConn then
		rangeVisualizerConn = RunService.RenderStepped:Connect(function()
			if not rangeVisualizerEnabled then return end
			if not rangeSphere then return end
			local nowOrigin = getOriginPosition()
			if nowOrigin then
				rangeSphere.Position = nowOrigin
				rangeSphere.Transparency = 1 - (rangeOpacityPercent / 100)
				rangeSphere.Color = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB)
			else
				rangeSphere.Transparency = 1
			end
		end)
	end
end

local function setSimpleSliderValue(slider, value)
	local clamped = math.clamp(math.floor(value + 0.5), slider.min, slider.max)
	local alpha = (clamped - slider.min) / math.max(1, (slider.max - slider.min))
	slider.fill.Size = UDim2.new(alpha, 0, 1, 0)
	slider.knob.Position = UDim2.new(alpha, -6, 0.5, -6)
	slider.valueLabel.Text = tostring(clamped)
	return clamped
end

local function updateRangeSliderVisual()
	local alpha = detectionRadius / MAX_DETECTION_RADIUS
	rangeSliderFill.Size = UDim2.new(alpha, 0, 1, 0)
	rangeSliderKnob.Position = UDim2.new(alpha, -7, 0.5, -7)
	rangeValueLabel.Text = ("Detection Range: %d studs"):format(detectionRadius)
	updateRangeVisualizer()
end

local function setDetectionRadius(value)
	detectionRadius = math.clamp(math.floor(value + 0.5), 0, MAX_DETECTION_RADIUS)
	updateRangeSliderVisual()
end

local function setRangeColorFromState()
	if rangeSphere then
		rangeSphere.Color = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB)
		rangeSphere.Transparency = 1 - (rangeOpacityPercent / 100)
	end
end

local function updateColorPickerUI()
	local color = Color3.fromRGB(rangeColorR, rangeColorG, rangeColorB)
	colorPreviewSwatch.BackgroundColor3 = color
	colorHexLabel.Text = ("#%02X%02X%02X"):format(rangeColorR, rangeColorG, rangeColorB)
	hueKnob.Position = UDim2.new(math.clamp(rangeHue, 0, 1), -6, 0.5, -6)
	hueValueLabel.Text = ("%d°"):format(math.floor((rangeHue * 360) + 0.5) % 360)
	satKnob.Position = UDim2.new(math.clamp(rangeSat, 0, 1), -6, 0.5, -6)
	satValueLabel.Text = ("%d%%"):format(math.floor((rangeSat * 100) + 0.5))
	satGradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromHSV(rangeHue, 1, 1))
end

local function setRangeColorFromHSV(h, s, v)
	rangeHue = math.clamp(h, 0, 1)
	rangeSat = math.clamp(s, 0, 1)
	rangeVal = math.clamp(v, 0, 1)
	local color = Color3.fromHSV(rangeHue, rangeSat, rangeVal)
	rangeColorR = math.floor(color.R * 255 + 0.5)
	rangeColorG = math.floor(color.G * 255 + 0.5)
	rangeColorB = math.floor(color.B * 255 + 0.5)
	updateColorPickerUI()
	setRangeColorFromState()
	updateRangeVisualizer()
end

-- ========== STATUS ==========
local function updateStatus()
	if activeTab == "animations" then
		local pauseIndicator = animLogPaused and " ⏸" or ""
		statusLabel.Text       = ("Detected: %d  | Filtered: %d%s"):format(detectionCount, filteredCount, pauseIndicator)
		statusLabel.TextColor3 = Color3.fromRGB(160, 200, 255)
	else
		local pauseIndicator = remoteLogPaused and " ⏸" or ""
		statusLabel.Text       = ("Logged: %d%s  |  Click entry to inspect"):format(remoteCount, pauseIndicator)
		statusLabel.TextColor3 = Color3.fromRGB(155, 225, 180)
	end
end

-- ========== TAB SWITCHING ==========
local applyRemoteFilter = function() end
local function setTab(tab)
	activeTab = tab
	if tab == "animations" then
		previousTab = "animations"
		animContent.Visible    = true
		remoteContent.Visible  = false
		settingsContent.Visible = false
		statusLabel.Visible = true
		openPausedAnimationsBtn.Visible = true
		exportAnimationsBtn.Visible = true
		openPausedRemotesBtn.Visible = false
		exportRemotesBtn.Visible = false
		localPlayerFilterBtn.Visible = false
		settingsBtn.BackgroundColor3 = Theme.ButtonDefault
		animTabBtn.BackgroundColor3   = Theme.TabActive
		animTabBtn.TextColor3         = Theme.TabTextActive
		animTabBtn.Font               = Enum.Font.GothamBold
		remoteTabBtn.BackgroundColor3 = Theme.TabInactive
		remoteTabBtn.TextColor3       = Theme.TabTextInactive
		remoteTabBtn.Font             = Enum.Font.Gotham
		strictBtn.Visible       = true
		clearBtn.Visible        = true
		pauseAnimBtn.Visible    = true
		pauseRemotesBtn.Visible = false
	elseif tab == "remotes" then
		previousTab = "remotes"
		animContent.Visible    = false
		remoteContent.Visible  = true
		settingsContent.Visible = false
		statusLabel.Visible = true
		openPausedAnimationsBtn.Visible = false
		exportAnimationsBtn.Visible = false
		openPausedRemotesBtn.Visible = true
		exportRemotesBtn.Visible = true
		localPlayerFilterBtn.Visible = true
		settingsBtn.BackgroundColor3 = Theme.ButtonDefault
		remoteTabBtn.BackgroundColor3 = Color3.fromRGB(28, 40, 62)
		remoteTabBtn.TextColor3       = Color3.fromRGB(150, 205, 255)
		remoteTabBtn.Font             = Enum.Font.GothamBold
		animTabBtn.BackgroundColor3   = Theme.TabInactive
		animTabBtn.TextColor3         = Theme.TabTextInactive
		animTabBtn.Font               = Enum.Font.Gotham
		strictBtn.Visible       = false
		clearBtn.Visible        = false
		pauseAnimBtn.Visible    = false
		pauseRemotesBtn.Visible = true
		if type(applyRemoteFilter) == "function" then
			applyRemoteFilter()  -- reapply search filter when tab shown
		end
	else
		animContent.Visible     = false
		remoteContent.Visible   = false
		settingsContent.Visible = true
		statusLabel.Visible = false
		openPausedAnimationsBtn.Visible = false
		exportAnimationsBtn.Visible = false
		openPausedRemotesBtn.Visible = false
		exportRemotesBtn.Visible = false
		localPlayerFilterBtn.Visible = false
		strictBtn.Visible       = false
		clearBtn.Visible        = false
		pauseAnimBtn.Visible    = false
		pauseRemotesBtn.Visible = false
		animTabBtn.BackgroundColor3   = Theme.TabInactive
		animTabBtn.TextColor3         = Theme.TabTextInactive
		animTabBtn.Font               = Enum.Font.Gotham
		remoteTabBtn.BackgroundColor3 = Theme.TabInactive
		remoteTabBtn.TextColor3       = Theme.TabTextInactive
		remoteTabBtn.Font             = Enum.Font.Gotham
		settingsBtn.BackgroundColor3  = Color3.fromRGB(60, 95, 145)
	end
	updateStatus()
end

animTabBtn.MouseButton1Click:Connect(function()  setTab("animations") end)
remoteTabBtn.MouseButton1Click:Connect(function() setTab("remotes")   end)
settingsBtn.MouseButton1Click:Connect(function() setTab("settings") end)
settingsBackBtn.MouseButton1Click:Connect(function() setTab(previousTab) end)

strictBtn.MouseButton1Click:Connect(function()
	strictMode = not strictMode
	strictBtn.Text             = strictMode and "Strict: ON" or "Strict: OFF"
	strictBtn.BackgroundColor3 = strictMode and Color3.fromRGB(120,60,60) or Theme.ButtonDefault
end)

pauseAnimBtn.MouseButton1Click:Connect(function()
	animLogPaused = not animLogPaused
	pauseAnimBtn.Text = animLogPaused and "▶ Resume" or "⏸ Pause"
	updateStatus()
end)

pauseRemotesBtn.MouseButton1Click:Connect(function()
	remoteLogPaused = not remoteLogPaused
	pauseRemotesBtn.Text = remoteLogPaused and "▶ Resume" or "⏸ Pause"
	updateStatus()
end)

localPlayerFilterBtn.MouseButton1Click:Connect(function()
	remoteFilterLocal = not remoteFilterLocal
	localPlayerFilterBtn.Text = remoteFilterLocal and "Local" or "All"
	localPlayerFilterBtn.BackgroundColor3 = remoteFilterLocal and Color3.fromRGB(60,100,60) or Theme.ButtonDefault
	if type(applyRemoteFilter) == "function" then
		applyRemoteFilter()
	end
end)

local function updateSliderFromInputX(inputX)
	local left = rangeSliderTrack.AbsolutePosition.X
	local width = math.max(1, rangeSliderTrack.AbsoluteSize.X)
	local alpha = math.clamp((inputX - left) / width, 0, 1)
	setDetectionRadius(alpha * MAX_DETECTION_RADIUS)
end

local function sliderValueFromInput(slider, inputX)
	local left = slider.track.AbsolutePosition.X
	local width = math.max(1, slider.track.AbsoluteSize.X)
	local alpha = math.clamp((inputX - left) / width, 0, 1)
	return slider.min + (slider.max - slider.min) * alpha
end

local function beginSliderDrag(updateFn, inputPos)
	activeSliderUpdate = updateFn
	updateFn(inputPos)
end

local function updateHueFromInput(inputX)
	local left = hueTrack.AbsolutePosition.X
	local width = math.max(1, hueTrack.AbsoluteSize.X)
	local hue = math.clamp((inputX - left) / width, 0, 1)
	setRangeColorFromHSV(hue, rangeSat, 1)
end

local function updateSaturationFromInput(inputX)
	local left = satTrack.AbsolutePosition.X
	local width = math.max(1, satTrack.AbsoluteSize.X)
	local sat = math.clamp((inputX - left) / width, 0, 1)
	setRangeColorFromHSV(rangeHue, sat, 1)
end

hueTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		beginSliderDrag(function(pos)
			updateHueFromInput(pos.X)
		end, i.Position)
	end
end)

satTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		beginSliderDrag(function(pos)
			updateSaturationFromInput(pos.X)
		end, i.Position)
	end
end)

rangeSliderTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		beginSliderDrag(function(pos)
			updateSliderFromInputX(pos.X)
		end, i.Position)
	end
end)

opacitySlider.track.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		beginSliderDrag(function(pos)
			rangeOpacityPercent = setSimpleSliderValue(opacitySlider, sliderValueFromInput(opacitySlider, pos.X))
			setRangeColorFromState()
			updateRangeVisualizer()
		end, i.Position)
	end
end)

UserInputService.InputChanged:Connect(function(i)
	if not activeSliderUpdate then return end
	if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
		activeSliderUpdate(i.Position)
	end
end)

UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		activeSliderUpdate = nil
	end
end)

visualizeRangeBtn.MouseButton1Click:Connect(function()
	rangeVisualizerEnabled = not rangeVisualizerEnabled
	visualizeRangeBtn.Text = rangeVisualizerEnabled and "Visualize Range: ON" or "Visualize Range: OFF"
	visualizeRangeBtn.BackgroundColor3 = rangeVisualizerEnabled and Color3.fromRGB(60, 100, 150) or Theme.ButtonDefault
	updateRangeVisualizer()
end)

setDetectionRadius(DEFAULT_DETECTION_RADIUS)
setSimpleSliderValue(opacitySlider, rangeOpacityPercent)
updateColorPickerUI()

-- ========== RICH TEXT HELPERS ==========
local function bT(s)     return "<b>"..s.."</b>" end
local function cT(s, h)  return ('<font color="#%s">%s</font>'):format(h, s) end
local function sec(name) return "\n"..cT("— "..name.." —", "5599DD").."\n" end
local function safeGet(fn) local ok,r = pcall(fn); return ok and r or "N/A" end

-- ========== ANIMATION DETAIL PANEL ==========
local detailFrame = Instance.new("Frame")
detailFrame.Size             = UDim2.new(0, 360, 0, 420)
detailFrame.Position         = UDim2.new(0, 490, 0, 80)
detailFrame.BackgroundColor3 = Theme.Background
detailFrame.BorderSizePixel  = 0
detailFrame.Visible          = false
detailFrame.Active           = true
detailFrame.Parent           = screenGui
mkCorner(detailFrame, 8);
mkStroke(detailFrame, Color3.fromRGB(80, 80, 100))

local detailTitleBar = Instance.new("Frame")
detailTitleBar.Size             = UDim2.new(1, 0, 0, 32)
detailTitleBar.BackgroundColor3 = Color3.fromRGB(45, 35, 55)
detailTitleBar.BorderSizePixel  = 0; detailTitleBar.Active = true
detailTitleBar.Parent           = detailFrame
mkCorner(detailTitleBar, 8)

do local detailTitleLabel = Instance.new("TextLabel")
detailTitleLabel.Size               = UDim2.new(1, -40, 1, 0)
detailTitleLabel.Position           = UDim2.new(0, 12, 0, 0)
detailTitleLabel.BackgroundTransparency = 1
detailTitleLabel.Text               = "Animation Details"
detailTitleLabel.TextColor3         = Color3.fromRGB(230, 200, 255)
detailTitleLabel.TextXAlignment     = Enum.TextXAlignment.Left
detailTitleLabel.Font               = Enum.Font.GothamBold; detailTitleLabel.TextSize = 13
detailTitleLabel.Parent             = detailTitleBar
local animCloseBtn = Instance.new("TextButton")
animCloseBtn.Size             = UDim2.new(0, 24, 0, 22)
animCloseBtn.Position         = UDim2.new(1, -30, 0, 5)
animCloseBtn.BackgroundColor3 = Theme.ButtonDanger
animCloseBtn.Text             = "X";
animCloseBtn.TextColor3 = Theme.TextPrimary
animCloseBtn.Font             = Enum.Font.GothamBold;
animCloseBtn.TextSize = 12
animCloseBtn.BorderSizePixel  = 0; animCloseBtn.Parent = detailTitleBar
mkCorner(animCloseBtn, 4)
animCloseBtn.MouseEnter:Connect(function() animCloseBtn.BackgroundColor3 = Color3.fromRGB(220,80,80) end)
animCloseBtn.MouseLeave:Connect(function() animCloseBtn.BackgroundColor3 = Theme.ButtonDanger end)
animCloseBtn.MouseButton1Click:Connect(function() detailFrame.Visible = false end) end

local animDetailScroll = Instance.new("ScrollingFrame")
animDetailScroll.Size               = UDim2.new(1, -16, 1, -82)
animDetailScroll.Position           = UDim2.new(0, 8, 0, 40)
animDetailScroll.BackgroundColor3   = Color3.fromRGB(15, 15, 20)
animDetailScroll.BorderSizePixel    = 0
animDetailScroll.ScrollBarThickness = 6
animDetailScroll.ScrollBarImageColor3 = Theme.ScrollBarColor
animDetailScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
animDetailScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
animDetailScroll.Parent             = detailFrame
mkCorner(animDetailScroll, 4)
do
	local adPad = Instance.new("UIPadding", animDetailScroll)
	adPad.PaddingTop = UDim.new(0,6)
	adPad.PaddingBottom = UDim.new(0,6)
end

local animDetailText = Instance.new("TextLabel")
animDetailText.Size               = UDim2.new(1, -16, 0, 0)
animDetailText.Position           = UDim2.new(0, 8, 0, 0)
animDetailText.AutomaticSize      = Enum.AutomaticSize.Y
animDetailText.BackgroundTransparency = 1
animDetailText.Text               = ""
animDetailText.TextColor3         = Color3.fromRGB(220, 220, 230)
animDetailText.TextXAlignment     = Enum.TextXAlignment.Left
animDetailText.TextYAlignment     = Enum.TextYAlignment.Top
animDetailText.Font               = Enum.Font.Code; animDetailText.TextSize = 11
animDetailText.TextWrapped        = true;
animDetailText.RichText = true
animDetailText.Parent             = animDetailScroll

local copyIdBtn = Instance.new("TextButton")
copyIdBtn.Size             = UDim2.new(0.5, -12, 0, 28)
copyIdBtn.Position         = UDim2.new(0, 8, 1, -36)
copyIdBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
copyIdBtn.Text             = "Print ID to Console"
copyIdBtn.TextColor3       = Theme.TextPrimary
copyIdBtn.Font             = Enum.Font.Gotham; copyIdBtn.TextSize = 11
copyIdBtn.BorderSizePixel  = 0; copyIdBtn.Parent = detailFrame
mkCorner(copyIdBtn, 4)

local ignoreBtn = Instance.new("TextButton")
ignoreBtn.Size             = UDim2.new(0.5, -12, 0, 28)
ignoreBtn.Position         = UDim2.new(0.5, 4, 1, -36)
ignoreBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 110)
ignoreBtn.Text             = "Pause This Anim"
ignoreBtn.TextColor3       = Theme.TextPrimary
ignoreBtn.Font             = Enum.Font.GothamBold; ignoreBtn.TextSize = 11
ignoreBtn.BorderSizePixel  = 0; ignoreBtn.Parent = detailFrame
mkCorner(ignoreBtn, 4)

local refreshAnimBtn = Instance.new("TextButton")
refreshAnimBtn.Size = UDim2.new(1, -16, 0, 22)
refreshAnimBtn.Position = UDim2.new(0, 8, 1, -64)
refreshAnimBtn.BackgroundColor3 = Theme.ButtonDefault
refreshAnimBtn.Text = "🔄 Refresh"
refreshAnimBtn.TextColor3 = Theme.TextPrimary
refreshAnimBtn.Font = Enum.Font.Gotham; refreshAnimBtn.TextSize = 10
refreshAnimBtn.BorderSizePixel = 0; refreshAnimBtn.Parent = detailFrame
mkCorner(refreshAnimBtn, 4)

local animDetailResizeGrip = Instance.new("TextButton")
animDetailResizeGrip.Size                   = UDim2.new(0, 16, 0, 16)
animDetailResizeGrip.Position               = UDim2.new(1, -18, 1, -18)
animDetailResizeGrip.BackgroundColor3       = Theme.ScrollBarColor
animDetailResizeGrip.BackgroundTransparency = 0.4
animDetailResizeGrip.Text                   = "⇲"
animDetailResizeGrip.TextColor3             = Theme.TextPrimary
animDetailResizeGrip.Font                   = Enum.Font.GothamBold;
animDetailResizeGrip.TextSize = 12
animDetailResizeGrip.BorderSizePixel        = 0;
animDetailResizeGrip.AutoButtonColor = false
animDetailResizeGrip.Parent                 = detailFrame
mkCorner(animDetailResizeGrip, 3)
animDetailResizeGrip.MouseEnter:Connect(function() animDetailResizeGrip.BackgroundTransparency = 0   end)
animDetailResizeGrip.MouseLeave:Connect(function() animDetailResizeGrip.BackgroundTransparency = 0.4 end)

-- ========== REMOTE DETAIL PANEL ==========
local remDetailFrame = Instance.new("Frame")
remDetailFrame.Name             = "RemoteDetailFrame"
remDetailFrame.Size             = UDim2.new(0, 390, 0, 480)
remDetailFrame.Position         = UDim2.new(0, 490, 0, 80)
remDetailFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
remDetailFrame.BorderSizePixel  = 0
remDetailFrame.Visible          = false
remDetailFrame.Active           = true
remDetailFrame.Parent           = screenGui
mkCorner(remDetailFrame, 8)
mkStroke(remDetailFrame, Color3.fromRGB(55, 80, 120))

local rdTitleBar = Instance.new("Frame")
rdTitleBar.Size             = UDim2.new(1, 0, 0, 32)
rdTitleBar.BackgroundColor3 = Color3.fromRGB(28, 38, 58)
rdTitleBar.BorderSizePixel  = 0; rdTitleBar.Active = true
rdTitleBar.Parent           = remDetailFrame
mkCorner(rdTitleBar, 8)

local rdTitleLabel = Instance.new("TextLabel")
rdTitleLabel.Size               = UDim2.new(1, -44, 1, 0)
rdTitleLabel.Position           = UDim2.new(0, 12, 0, 0)
rdTitleLabel.BackgroundTransparency = 1
rdTitleLabel.Text               = "📡  Remote Details"
rdTitleLabel.TextColor3         = Color3.fromRGB(150, 205, 255)
rdTitleLabel.TextXAlignment     = Enum.TextXAlignment.Left
rdTitleLabel.Font               = Enum.Font.GothamBold; rdTitleLabel.TextSize = 13
rdTitleLabel.TextTruncate       = Enum.TextTruncate.AtEnd
rdTitleLabel.Parent             = rdTitleBar

do local rdCloseBtn = Instance.new("TextButton")
rdCloseBtn.Size             = UDim2.new(0, 24, 0, 22)
rdCloseBtn.Position         = UDim2.new(1, -30, 0, 5)
rdCloseBtn.BackgroundColor3 = Theme.ButtonDanger
rdCloseBtn.Text             = "X"; rdCloseBtn.TextColor3 = Theme.TextPrimary
rdCloseBtn.Font             = Enum.Font.GothamBold; rdCloseBtn.TextSize = 12
rdCloseBtn.BorderSizePixel  = 0; rdCloseBtn.Parent = rdTitleBar
mkCorner(rdCloseBtn, 4)
rdCloseBtn.MouseEnter:Connect(function() rdCloseBtn.BackgroundColor3 = Color3.fromRGB(220,80,80) end)
rdCloseBtn.MouseLeave:Connect(function() rdCloseBtn.BackgroundColor3 = Theme.ButtonDanger end)
rdCloseBtn.MouseButton1Click:Connect(function() remDetailFrame.Visible = false end) end

local rdScroll = Instance.new("ScrollingFrame")
rdScroll.Size               = UDim2.new(1, -16, 1, -90)
rdScroll.Position           = UDim2.new(0, 8, 0, 40)
rdScroll.BackgroundColor3   = Color3.fromRGB(12, 13, 18)
rdScroll.BorderSizePixel    = 0
rdScroll.ScrollBarThickness = 6
rdScroll.ScrollBarImageColor3 = Color3.fromRGB(70, 110, 160)
rdScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
rdScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
rdScroll.Parent             = remDetailFrame
mkCorner(rdScroll, 4)
do
	local rdPad = Instance.new("UIPadding", rdScroll)
	rdPad.PaddingTop = UDim.new(0,6)
	rdPad.PaddingBottom = UDim.new(0,8)
	rdPad.PaddingLeft = UDim.new(0,8)
	rdPad.PaddingRight = UDim.new(0,6)
end

local rdBodyText = Instance.new("TextLabel")
rdBodyText.Size               = UDim2.new(1, 0, 0, 0)
rdBodyText.AutomaticSize      = Enum.AutomaticSize.Y
rdBodyText.BackgroundTransparency = 1
rdBodyText.Text               = ""
rdBodyText.TextColor3         = Color3.fromRGB(210, 220, 235)
rdBodyText.TextXAlignment     = Enum.TextXAlignment.Left
rdBodyText.TextYAlignment     = Enum.TextYAlignment.Top
rdBodyText.Font               = Enum.Font.Code; rdBodyText.TextSize = 11
rdBodyText.TextWrapped        = true; rdBodyText.RichText = true
rdBodyText.Parent             = rdScroll

-- Bottom action bar on the remote detail panel
local rdBtnBar = Instance.new("Frame")
rdBtnBar.Size             = UDim2.new(1, -16, 0, 38)
rdBtnBar.Position         = UDim2.new(0, 8, 1, -44)
rdBtnBar.BackgroundColor3 = Color3.fromRGB(18, 24, 36)
rdBtnBar.BorderSizePixel  = 0; rdBtnBar.Parent = remDetailFrame
mkCorner(rdBtnBar, 5); mkStroke(rdBtnBar, Color3.fromRGB(45, 70, 110))

local rdCopyCodeBtn, rdCopyPathBtn, rdRunCodeBtn, rdPauseBtn
do
	local function makeRdBtn(label, color, idx, total)
		local w = 1 / total
		local btn = Instance.new("TextButton")
		btn.Size             = UDim2.new(w, -5, 1, -10)
		btn.Position         = UDim2.new(w*(idx-1), (idx==1 and 5 or 3), 0, 5)
		btn.BackgroundColor3 = color
		btn.Text             = label
		btn.TextColor3       = Theme.TextPrimary
		btn.Font             = Enum.Font.Gotham; btn.TextSize = 10
		btn.BorderSizePixel  = 0; btn.AutoButtonColor = false
		btn.Parent           = rdBtnBar
		mkCorner(btn, 4)
		btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.25 end)
		btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0    end)
		return btn
	end

	rdCopyCodeBtn = makeRdBtn("📋 Copy Code", Color3.fromRGB(48, 88, 150), 1, 4)
	rdCopyPathBtn = makeRdBtn("🔗 Copy Path", Color3.fromRGB(40, 105, 70), 2, 4)
	rdRunCodeBtn  = makeRdBtn("▶ Run Code",  Color3.fromRGB(65, 105, 40), 3, 4)
	rdPauseBtn    = makeRdBtn("⏸ Pause",     Color3.fromRGB(130, 48, 48), 4, 4)
end

rdPauseBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then return end
	local rName = selectedRemoteData.remoteName
	pausedIndividualRemotes[rName] = not pausedIndividualRemotes[rName]
	
	if pausedIndividualRemotes[rName] then
		pausedRemoteArchive[rName] = selectedRemoteData
		rdPauseBtn.Text = "▶ Resume"
		rdPauseBtn.BackgroundColor3 = Color3.fromRGB(120, 100, 40)
	else
		pausedRemoteArchive[rName] = nil
		rdPauseBtn.Text = "⏸ Pause"
		rdPauseBtn.BackgroundColor3 = Color3.fromRGB(130, 48, 48)
	end
end)

local rdResizeGrip = Instance.new("TextButton")
rdResizeGrip.Size                   = UDim2.new(0, 16, 0, 16)
rdResizeGrip.Position               = UDim2.new(1, -18, 1, -18)
rdResizeGrip.BackgroundColor3       = Color3.fromRGB(70, 110, 160)
rdResizeGrip.BackgroundTransparency = 0.4
rdResizeGrip.Text                   = "⇲"
rdResizeGrip.TextColor3             = Color3.fromRGB(200, 220, 245)
rdResizeGrip.Font                   = Enum.Font.GothamBold; rdResizeGrip.TextSize = 12
rdResizeGrip.BorderSizePixel        = 0; rdResizeGrip.AutoButtonColor = false
rdResizeGrip.Parent                 = remDetailFrame
mkCorner(rdResizeGrip, 3)
rdResizeGrip.MouseEnter:Connect(function() rdResizeGrip.BackgroundTransparency = 0   end)
rdResizeGrip.MouseLeave:Connect(function() rdResizeGrip.BackgroundTransparency = 0.4 end)

-- ========== STATE PROBE PANEL ==========
local stateProbeFrame = Instance.new("Frame")
stateProbeFrame.Name             = "StateProbeFrame"
stateProbeFrame.Size             = UDim2.new(0, 460, 0, 420)
stateProbeFrame.Position         = UDim2.new(0, 20, 0, 240)
stateProbeFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
stateProbeFrame.BorderSizePixel  = 0
stateProbeFrame.Visible          = false
stateProbeFrame.Active           = true
stateProbeFrame.Parent           = screenGui
mkCorner(stateProbeFrame, 8)
mkStroke(stateProbeFrame, Color3.fromRGB(80, 120, 100))

local spTitleBar = Instance.new("Frame")
spTitleBar.Size             = UDim2.new(1, 0, 0, 32)
spTitleBar.BackgroundColor3 = Color3.fromRGB(28, 45, 38)
spTitleBar.BorderSizePixel  = 0; spTitleBar.Active = true
spTitleBar.Parent           = stateProbeFrame
mkCorner(spTitleBar, 8)

do
	local spTitleLabel = Instance.new("TextLabel")
	spTitleLabel.Size               = UDim2.new(1, -88, 1, 0)
	spTitleLabel.Position           = UDim2.new(0, 12, 0, 0)
	spTitleLabel.BackgroundTransparency = 1
	spTitleLabel.Text               = "State Probe"
	spTitleLabel.TextColor3         = Color3.fromRGB(150, 220, 180)
	spTitleLabel.TextXAlignment     = Enum.TextXAlignment.Left
	spTitleLabel.Font               = Enum.Font.GothamBold; spTitleLabel.TextSize = 13
	spTitleLabel.TextTruncate       = Enum.TextTruncate.AtEnd
	spTitleLabel.ZIndex             = 1
	spTitleLabel.Parent             = spTitleBar

	local spClearBtn = Instance.new("TextButton")
	spClearBtn.Size             = UDim2.new(0, 40, 0, 22)
	spClearBtn.Position         = UDim2.new(1, -86, 0, 5)
	spClearBtn.BackgroundColor3 = Color3.fromRGB(80, 100, 60)
	spClearBtn.Text             = "Clear"; spClearBtn.TextColor3 = Theme.TextPrimary
	spClearBtn.Font             = Enum.Font.GothamBold; spClearBtn.TextSize = 10
	spClearBtn.BorderSizePixel  = 0; spClearBtn.Parent = spTitleBar
	spClearBtn.ZIndex           = 3
	mkCorner(spClearBtn, 4)
	spClearBtn.MouseEnter:Connect(function() spClearBtn.BackgroundColor3 = Color3.fromRGB(120, 140, 80) end)
	spClearBtn.MouseLeave:Connect(function() spClearBtn.BackgroundColor3 = Color3.fromRGB(80, 100, 60) end)

	local spCloseBtn = Instance.new("TextButton")
	spCloseBtn.Size             = UDim2.new(0, 24, 0, 22)
	spCloseBtn.Position         = UDim2.new(1, -30, 0, 5)
	spCloseBtn.BackgroundColor3 = Theme.ButtonDanger
	spCloseBtn.Text             = "X"; spCloseBtn.TextColor3 = Theme.TextPrimary
	spCloseBtn.Font             = Enum.Font.GothamBold; spCloseBtn.TextSize = 12
	spCloseBtn.BorderSizePixel  = 0; spCloseBtn.Parent = spTitleBar
	spCloseBtn.ZIndex           = 3
	mkCorner(spCloseBtn, 4)
	spCloseBtn.MouseEnter:Connect(function() spCloseBtn.BackgroundColor3 = Color3.fromRGB(220,80,80) end)
	spCloseBtn.MouseLeave:Connect(function() spCloseBtn.BackgroundColor3 = Theme.ButtonDanger end)
	spCloseBtn.MouseButton1Click:Connect(function() stateProbeFrame.Visible = false end)

	local spSearchBox = Instance.new("TextBox")
	spSearchBox.Size               = UDim2.new(1, -16, 0, 24)
	spSearchBox.Position           = UDim2.new(0, 8, 0, 38)
	spSearchBox.BackgroundColor3   = Color3.fromRGB(24, 30, 40)
	spSearchBox.BorderSizePixel    = 0
	spSearchBox.PlaceholderText    = "Search name or path..."
	spSearchBox.PlaceholderColor3  = Color3.fromRGB(145, 150, 160)
	spSearchBox.Text               = ""
	spSearchBox.TextColor3         = Theme.TextPrimary
	spSearchBox.Font               = Enum.Font.Gotham
	spSearchBox.TextSize           = 10
	spSearchBox.ClearTextOnFocus   = false
	spSearchBox.Parent             = stateProbeFrame
	spSearchBox.ZIndex             = 2
	mkCorner(spSearchBox, 4)
	stateProbeView.searchBox = spSearchBox

	local spChipScroll = Instance.new("ScrollingFrame")
	spChipScroll.Size               = UDim2.new(1, -16, 0, 28)
	spChipScroll.Position           = UDim2.new(0, 8, 0, 68)
	spChipScroll.BackgroundTransparency = 1
	spChipScroll.BorderSizePixel    = 0
	spChipScroll.ScrollBarThickness = 4
	spChipScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 150, 120)
	spChipScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
	spChipScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
	pcall(function()
		spChipScroll.ScrollingDirection = Enum.ScrollingDirection.X
	end)
	spChipScroll.Parent             = stateProbeFrame
	spChipScroll.ZIndex             = 2

	do
		local chipLayout = Instance.new("UIListLayout")
		chipLayout.FillDirection = Enum.FillDirection.Horizontal
		chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		chipLayout.Padding = UDim.new(0, 6)
		chipLayout.Parent = spChipScroll
		local chipPad = Instance.new("UIPadding")
		chipPad.PaddingLeft = UDim.new(0, 2)
		chipPad.PaddingRight = UDim.new(0, 2)
		chipPad.Parent = spChipScroll
	end

	stateProbeView.filterChips = {}
	for _, filter in ipairs(stateProbeView.filterTypes) do
		local chip = Instance.new("TextButton")
		chip.Size = UDim2.new(0, math.max(42, 14 + (#filter.label * 7)), 0, 22)
		chip.BackgroundColor3 = Color3.fromRGB(42, 56, 72)
		chip.BorderSizePixel = 0
		chip.AutoButtonColor = false
		chip.Text = filter.label
		chip.TextColor3 = Theme.TextPrimary
		chip.Font = Enum.Font.GothamBold
		chip.TextSize = 9
		chip.ZIndex = 3
		chip.Parent = spChipScroll
		mkCorner(chip, 4)
		chip.MouseEnter:Connect(function()
			if stateProbeView.selectedFilter ~= filter.value then
				chip.BackgroundColor3 = Color3.fromRGB(58, 76, 96)
			end
		end)
		chip.MouseLeave:Connect(function()
			if stateProbeView.selectedFilter ~= filter.value then
				chip.BackgroundColor3 = Color3.fromRGB(42, 56, 72)
			end
		end)
		chip.MouseButton1Click:Connect(function()
			stateProbeView.selectedFilter = filter.value
			applyStateProbeFilter()
		end)
		table.insert(stateProbeView.filterChips, {
			button = chip,
			value = filter.value,
		})
	end

	spSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		stateProbeView.searchText = spSearchBox.Text or ""
		applyStateProbeFilter()
	end)

	local spScroll = Instance.new("ScrollingFrame")
	spScroll.Size               = UDim2.new(1, -16, 1, -140)
	spScroll.Position           = UDim2.new(0, 8, 0, 102)
	spScroll.BackgroundColor3   = Color3.fromRGB(12, 13, 18)
	spScroll.BorderSizePixel    = 0
	spScroll.ScrollBarThickness = 6
	spScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 150, 120)
	spScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
	spScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	pcall(function()
		spScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	end)
	spScroll.Parent             = stateProbeFrame
	mkCorner(spScroll, 4)

	local spGridLayout = Instance.new("UIGridLayout", spScroll)
	spGridLayout.CellSize = UDim2.new(0, 190, 0, 50)
	spGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	spGridLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	spGridLayout.StartCorner = Enum.StartCorner.TopLeft
	do
		local spPad = Instance.new("UIPadding", spScroll)
		spPad.PaddingTop = UDim.new(0,6)
		spPad.PaddingBottom = UDim.new(0,8)
		spPad.PaddingLeft = UDim.new(0,8)
		spPad.PaddingRight = UDim.new(0,6)
	end

	stateProbeContainer = spScroll

	local spBtnBar = Instance.new("Frame")
	spBtnBar.Size             = UDim2.new(0, 156, 0, 30)
	spBtnBar.Position         = UDim2.new(0, 8, 1, -38)
	spBtnBar.BackgroundColor3 = Color3.fromRGB(18, 24, 36)
	spBtnBar.BorderSizePixel  = 0
	spBtnBar.ZIndex           = 2
	spBtnBar.Parent           = stateProbeFrame
	mkCorner(spBtnBar, 5)
	mkStroke(spBtnBar, Color3.fromRGB(60, 90, 80))

	local spCopyAllBtn = Instance.new("TextButton")
	spCopyAllBtn.Size             = UDim2.new(1, -8, 1, -8)
	spCopyAllBtn.Position         = UDim2.new(0, 4, 0, 4)
	spCopyAllBtn.BackgroundColor3 = Color3.fromRGB(48, 88, 150)
	spCopyAllBtn.Text             = "Copy Visible"
	spCopyAllBtn.TextColor3       = Theme.TextPrimary
	spCopyAllBtn.Font             = Enum.Font.GothamBold
	spCopyAllBtn.TextSize         = 10
	spCopyAllBtn.BorderSizePixel  = 0
	spCopyAllBtn.ZIndex           = 3
	spCopyAllBtn.Parent           = spBtnBar
	spCopyAllBtn.AutoButtonColor  = false
	mkCorner(spCopyAllBtn, 4)
	spCopyAllBtn.MouseEnter:Connect(function() spCopyAllBtn.BackgroundTransparency = 0.25 end)
	spCopyAllBtn.MouseLeave:Connect(function() spCopyAllBtn.BackgroundTransparency = 0 end)
	stateProbeView.copyAllBtn = spCopyAllBtn

	spClearBtn.MouseButton1Click:Connect(function()
		stateProbeEntries = {}
		stateProbeView.nextOrder = 0
		stateProbeSelectedEntry = nil
		stateProbeSelectedEvent = nil
		spScroll:ClearAllChildren()
		spGridLayout = Instance.new("UIGridLayout", spScroll)
		spGridLayout.CellSize = UDim2.new(0, 190, 0, 50)
		spGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		spGridLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		spGridLayout.StartCorner = Enum.StartCorner.TopLeft
		local spPad = Instance.new("UIPadding", spScroll)
		spPad.PaddingTop = UDim.new(0,6)
		spPad.PaddingBottom = UDim.new(0,8)
		spPad.PaddingLeft = UDim.new(0,8)
		spPad.PaddingRight = UDim.new(0,6)
		if stateProbeDetailFrame then
			stateProbeDetailFrame.Visible = false
		end
		applyStateProbeFilter()
	end)

	applyStateProbeFilter()
end

local spResizeGrip = Instance.new("TextButton")
spResizeGrip.Size                   = UDim2.new(0, 16, 0, 16)
spResizeGrip.Position               = UDim2.new(1, -18, 1, -18)
spResizeGrip.BackgroundColor3       = Color3.fromRGB(100, 150, 120)
spResizeGrip.BackgroundTransparency = 0.4
spResizeGrip.Text                   = "⇲"
spResizeGrip.TextColor3             = Color3.fromRGB(200, 245, 220)
spResizeGrip.Font                   = Enum.Font.GothamBold; spResizeGrip.TextSize = 12
spResizeGrip.BorderSizePixel        = 0; spResizeGrip.AutoButtonColor = false
spResizeGrip.Parent                 = stateProbeFrame
mkCorner(spResizeGrip, 3)
spResizeGrip.MouseEnter:Connect(function() spResizeGrip.BackgroundTransparency = 0   end)
spResizeGrip.MouseLeave:Connect(function() spResizeGrip.BackgroundTransparency = 0.4 end)

stateProbeDetailFrame = Instance.new("Frame")
stateProbeDetailFrame.Name             = "StateProbeDetailFrame"
stateProbeDetailFrame.Size             = UDim2.new(0, 390, 0, 360)
stateProbeDetailFrame.Position         = UDim2.new(0, 450, 0, 570)
stateProbeDetailFrame.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
stateProbeDetailFrame.BorderSizePixel  = 0
stateProbeDetailFrame.Visible          = false
stateProbeDetailFrame.Active           = true
stateProbeDetailFrame.Parent           = screenGui
mkCorner(stateProbeDetailFrame, 8)
mkStroke(stateProbeDetailFrame, Color3.fromRGB(90, 140, 110))

local spdTitleBar = Instance.new("Frame")
spdTitleBar.Size             = UDim2.new(1, 0, 0, 32)
spdTitleBar.BackgroundColor3 = Color3.fromRGB(32, 52, 42)
spdTitleBar.BorderSizePixel  = 0
spdTitleBar.Active           = true
spdTitleBar.Parent           = stateProbeDetailFrame
mkCorner(spdTitleBar, 8)

stateProbeDetailTitle = Instance.new("TextLabel")
stateProbeDetailTitle.Size               = UDim2.new(1, -44, 1, 0)
stateProbeDetailTitle.Position           = UDim2.new(0, 12, 0, 0)
stateProbeDetailTitle.BackgroundTransparency = 1
stateProbeDetailTitle.Text               = "Probe Details"
stateProbeDetailTitle.TextColor3         = Color3.fromRGB(180, 230, 200)
stateProbeDetailTitle.TextXAlignment     = Enum.TextXAlignment.Left
stateProbeDetailTitle.Font               = Enum.Font.GothamBold
stateProbeDetailTitle.TextSize           = 13
stateProbeDetailTitle.TextTruncate       = Enum.TextTruncate.AtEnd
stateProbeDetailTitle.Parent             = spdTitleBar

do local spdCloseBtn = Instance.new("TextButton")
	spdCloseBtn.Size             = UDim2.new(0, 24, 0, 22)
	spdCloseBtn.Position         = UDim2.new(1, -30, 0, 5)
	spdCloseBtn.BackgroundColor3 = Theme.ButtonDanger
	spdCloseBtn.Text             = "X"
	spdCloseBtn.TextColor3       = Theme.TextPrimary
	spdCloseBtn.Font             = Enum.Font.GothamBold
	spdCloseBtn.TextSize         = 12
	spdCloseBtn.BorderSizePixel  = 0
	spdCloseBtn.Parent           = spdTitleBar
	mkCorner(spdCloseBtn, 4)
	spdCloseBtn.MouseEnter:Connect(function() spdCloseBtn.BackgroundColor3 = Color3.fromRGB(220,80,80) end)
	spdCloseBtn.MouseLeave:Connect(function() spdCloseBtn.BackgroundColor3 = Theme.ButtonDanger end)
	spdCloseBtn.MouseButton1Click:Connect(function() stateProbeDetailFrame.Visible = false end)
end

local spdScroll = Instance.new("ScrollingFrame")
spdScroll.Size               = UDim2.new(1, -16, 1, -90)
spdScroll.Position           = UDim2.new(0, 8, 0, 40)
spdScroll.BackgroundColor3   = Color3.fromRGB(12, 13, 18)
spdScroll.BorderSizePixel    = 0
spdScroll.ScrollBarThickness = 6
spdScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 150, 120)
spdScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
spdScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
spdScroll.Parent             = stateProbeDetailFrame
mkCorner(spdScroll, 4)
do
	local spdPad = Instance.new("UIPadding", spdScroll)
	spdPad.PaddingTop = UDim.new(0,6)
	spdPad.PaddingBottom = UDim.new(0,8)
	spdPad.PaddingLeft = UDim.new(0,8)
	spdPad.PaddingRight = UDim.new(0,6)
end

stateProbeDetailBody = Instance.new("TextLabel")
stateProbeDetailBody.Size               = UDim2.new(1, 0, 0, 0)
stateProbeDetailBody.AutomaticSize      = Enum.AutomaticSize.Y
stateProbeDetailBody.BackgroundTransparency = 1
stateProbeDetailBody.Text               = ""
stateProbeDetailBody.TextColor3         = Color3.fromRGB(210, 220, 235)
stateProbeDetailBody.TextXAlignment     = Enum.TextXAlignment.Left
stateProbeDetailBody.TextYAlignment     = Enum.TextYAlignment.Top
stateProbeDetailBody.Font               = Enum.Font.Code
stateProbeDetailBody.TextSize           = 11
stateProbeDetailBody.TextWrapped        = true
stateProbeDetailBody.Parent             = spdScroll

local spdBtnBar = Instance.new("Frame")
spdBtnBar.Size             = UDim2.new(1, -16, 0, 38)
spdBtnBar.Position         = UDim2.new(0, 8, 1, -44)
spdBtnBar.BackgroundColor3 = Color3.fromRGB(18, 24, 36)
spdBtnBar.BorderSizePixel  = 0
spdBtnBar.Parent           = stateProbeDetailFrame
mkCorner(spdBtnBar, 5)
mkStroke(spdBtnBar, Color3.fromRGB(60, 90, 80))

do
	local function makeProbeBtn(label, color, idx, total)
		local w = 1 / total
		local btn = Instance.new("TextButton")
		btn.Size             = UDim2.new(w, -5, 1, -10)
		btn.Position         = UDim2.new(w*(idx-1), (idx == 1 and 5 or 3), 0, 5)
		btn.BackgroundColor3 = color
		btn.Text             = label
		btn.TextColor3       = Theme.TextPrimary
		btn.Font             = Enum.Font.Gotham
		btn.TextSize         = 10
		btn.BorderSizePixel  = 0
		btn.AutoButtonColor  = false
		btn.Parent           = spdBtnBar
		mkCorner(btn, 4)
		btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.25 end)
		btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0 end)
		return btn
	end

	stateProbeCopyPathBtn  = makeProbeBtn("Copy Path",  Color3.fromRGB(40, 105, 70), 1, 3)
	stateProbeCopyValueBtn = makeProbeBtn("Copy Value", Color3.fromRGB(48, 88, 150), 2, 3)
	stateProbeCopyLogBtn   = makeProbeBtn("Copy Log",   Color3.fromRGB(110, 80, 40), 3, 3)
end

local spdResizeGrip = Instance.new("TextButton")
spdResizeGrip.Size                   = UDim2.new(0, 16, 0, 16)
spdResizeGrip.Position               = UDim2.new(1, -18, 1, -18)
spdResizeGrip.BackgroundColor3       = Color3.fromRGB(100, 150, 120)
spdResizeGrip.BackgroundTransparency = 0.4
spdResizeGrip.Text                   = "⇲"
spdResizeGrip.TextColor3             = Color3.fromRGB(200, 245, 220)
spdResizeGrip.Font                   = Enum.Font.GothamBold
spdResizeGrip.TextSize               = 12
spdResizeGrip.BorderSizePixel        = 0
spdResizeGrip.AutoButtonColor        = false
spdResizeGrip.Parent                 = stateProbeDetailFrame
mkCorner(spdResizeGrip, 3)
spdResizeGrip.MouseEnter:Connect(function() spdResizeGrip.BackgroundTransparency = 0 end)
spdResizeGrip.MouseLeave:Connect(function() spdResizeGrip.BackgroundTransparency = 0.4 end)

-- ========== DRAG / RESIZE ==========
local function bindDrag(bar, frame)
	local active, origin, startP = false, nil, nil
	bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			active = true; origin = i.Position; startP = frame.Position
		end
	end)
	bar.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			active = false
		end
	end)
	return function(inputPos)
		if active and origin and startP then
			local d = inputPos - origin
			frame.Position = UDim2.new(startP.X.Scale, startP.X.Offset+d.X, startP.Y.Scale, startP.Y.Offset+d.Y)
		end
	end
end

local function bindResize(grip, frame, minWidth, minHeight, maxWidth, maxHeight)
	local active, origin, startSz = false, nil, nil
	minWidth = minWidth or 320
	minHeight = minHeight or 240
	maxWidth = maxWidth or 1200
	maxHeight = maxHeight or 900
	grip.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			active = true; origin = i.Position; startSz = frame.AbsoluteSize
		end
	end)
	grip.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			active = false
		end
	end)
	return function(inputPos)
		if active and origin and startSz then
			local d = inputPos - origin
			frame.Size = UDim2.new(0, math.clamp(startSz.X+d.X, minWidth, maxWidth),
				0, math.clamp(startSz.Y+d.Y, minHeight, maxHeight))
		end
	end
end

do
	local dragMainFrame = bindDrag(titleBar, mainFrame)
	local dragDetailFrame = bindDrag(detailTitleBar, detailFrame)
	local dragRemoteDetailFrame = bindDrag(rdTitleBar, remDetailFrame)
	local dragStateProbeFrame = bindDrag(spTitleBar, stateProbeFrame)
	local dragStateProbeDetailFrame = bindDrag(spdTitleBar, stateProbeDetailFrame)

	local resizeMainFrame = bindResize(resizeGrip, mainFrame, 560, 360)
	local resizeDetailFrame = bindResize(animDetailResizeGrip, detailFrame, 360, 420)
	local resizeRemoteDetailFrame = bindResize(rdResizeGrip, remDetailFrame, 390, 480)
	local resizeStateProbeFrame = bindResize(spResizeGrip, stateProbeFrame, 420, 480)
	local resizeStateProbeDetailFrame = bindResize(spdResizeGrip, stateProbeDetailFrame, 390, 360)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
		dragMainFrame(input.Position)
		dragDetailFrame(input.Position)
		dragRemoteDetailFrame(input.Position)
		dragStateProbeFrame(input.Position)
		dragStateProbeDetailFrame(input.Position)
		resizeMainFrame(input.Position)
		resizeDetailFrame(input.Position)
		resizeRemoteDetailFrame(input.Position)
		resizeStateProbeFrame(input.Position)
		resizeStateProbeDetailFrame(input.Position)
	end)
end


-- ========== REMOTE DETAIL VIEW ==========
local function showRemoteDetail(data)
	selectedRemoteData     = data
	remDetailFrame.Visible = true

	rdTitleLabel.Text = "📡  " .. (data.remoteName or "Remote")

	local remoteType = safeGet(function()
		if typeof(data.remote) ~= "Instance" then
			return typeof(data.remote)
		end
		return data.remote:IsA("RemoteEvent") and "RemoteEvent" or "RemoteFunction"
	end)
	local parentName = safeGet(function()
		if typeof(data.remote) ~= "Instance" then
			return "nil"
		end
		return data.remote.Parent and data.remote.Parent.Name or "nil"
	end)
	local fullPath = getRemotePath(data.remote)

	local TYPE_COLORS = {
		string   = "88CC88", number  = "88CCFF", boolean = "FFCC66",
		Instance = "CC88FF", table   = "FF9966", Vector3 = "66DDCC",
		Vector2  = "66DDCC", CFrame  = "66DDCC", Color3  = "FF88AA",
		EnumItem = "DDCC88",
	}

	local argBlocks = {}
	if #data.args == 0 then
		table.insert(argBlocks, cT("  (no arguments passed)", "666688"))
	else
		for i, v in ipairs(asArray(data.args)) do
			local t = typeof(v)
			local typeColor = TYPE_COLORS[t] or "AAAAAA"
			local ok, serialized = pcall(deepSerializeArg, v, 0, "  ")
			if not ok then serialized = tostring(v) end

			local header = cT(bT(("[%d]"):format(i)), "CCCCDD") .. "  " .. cT(t, typeColor)
			local valueStr = cT(serialized, "C8D4E8")
			table.insert(argBlocks, header .. "\n  " .. valueStr)
		end
	end

	local isFireServer = (data.method == "FireServer")
	local methodColor  = isFireServer and "FFB844" or "44BBFF"
	local code         = buildCode(data.remote, data.method, data.argsStr)

	local lines = {
		sec("REMOTE"),
		bT("Name   ") .. cT(data.remoteName or "?", "E0D0FF"),
		bT("Type   ") .. cT(remoteType, "AADDFF"),
		bT("Method ") .. cT(data.method, methodColor),
		bT("Parent ") .. cT(parentName, "CCCCCC"),
		bT("Time   ") .. cT(data.timestamp or "?", "999999"),

		sec("FULL PATH"),
		cT(fullPath, "77BBFF"),

		sec("ARGUMENTS  [" .. #data.args .. "]"),
		table.concat(argBlocks, "\n\n"),

		sec("GENERATED CODE"),
		cT(code, "99FFAA"),
	}

	rdBodyText.Text = table.concat(lines, "\n")
	rdScroll.CanvasPosition = Vector2.new(0, 0)
	
	-- Update Individual Pause state
	if pausedIndividualRemotes[data.remoteName] then
		rdPauseBtn.Text = "▶ Resume"
		rdPauseBtn.BackgroundColor3 = Color3.fromRGB(120, 100, 40)
	else
		rdPauseBtn.Text = "⏸ Pause"
		rdPauseBtn.BackgroundColor3 = Color3.fromRGB(130, 48, 48)
	end
end

flashStateProbeBtn = function(btn, msg, orig)
	btn.Text = msg
	task.delay(1.3, function()
		if btn and btn.Parent then
			btn.Text = orig
		end
	end)
end

showStateProbeDetail = function(event)
	if stateProbeSelectedEntry and stateProbeSelectedEntry ~= event.button then
		stateProbeSelectedEntry.BackgroundColor3 = Color3.fromRGB(25, 35, 50)
	end

	stateProbeSelectedEvent = event
	stateProbeSelectedEntry = event.button
	if stateProbeSelectedEntry then
		stateProbeSelectedEntry.BackgroundColor3 = Color3.fromRGB(55, 85, 65)
	end

	stateProbeDetailFrame.Visible = true
	stateProbeDetailTitle.Text = (event.displayLabel or event.fieldName or "Probe") .. " Details"

	local lines = {
		("Event: %s"):format(event.eventName or "?"),
		("Field: %s"):format(event.fieldName or "?"),
		("Instance: %s"):format(event.instanceName or "?"),
		("Class: %s"):format(event.instanceClassName or "?"),
		("Parent: %s"):format(event.parentName or "nil"),
		("Relative Path: %s"):format(event.path or "?"),
		("Full Path: %s"):format(event.fullPath or event.path or "?"),
		("Value Type: %s"):format(event.valueType or "?"),
		("Value: %s"):format(event.value or "nil"),
	}

	if event.valuePath then
		lines[#lines + 1] = ("Value Path: %s"):format(event.valuePath)
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "Log Line:"
	lines[#lines + 1] = event.message or ""

	stateProbeDetailBody.Text = table.concat(lines, "\n")
end

stateProbeView.copyAllBtn.MouseButton1Click:Connect(function()
	local visibleEvents = {}
	for _, event in pairs(stateProbeEntries) do
		if event.button and event.button.Visible then
			visibleEvents[#visibleEvents + 1] = event
		end
	end

	table.sort(visibleEvents, function(a, b)
		return (a.order or 0) < (b.order or 0)
	end)

	if #visibleEvents == 0 then
		flashStateProbeBtn(stateProbeView.copyAllBtn, "No Entries", "Copy Visible")
		return
	end

	local lines = {}
	for _, event in ipairs(visibleEvents) do
		lines[#lines + 1] = ("%s = %s | %s | %s"):format(
			event.displayLabel or event.fieldName or "Unknown",
			event.value or "nil",
			event.valueType or "?",
			event.fullPath or event.path or "?"
		)
	end

	local payload = table.concat(lines, "\n")
	if tryClipboard(payload) then
		flashStateProbeBtn(stateProbeView.copyAllBtn, "Copied", "Copy Visible")
	else
		flashStateProbeBtn(stateProbeView.copyAllBtn, "Clipboard Off", "Copy Visible")
	end
end)

stateProbeCopyPathBtn.MouseButton1Click:Connect(function()
	if not stateProbeSelectedEvent then
		flashStateProbeBtn(stateProbeCopyPathBtn, "Select One", "Copy Path")
		return
	end
	local path = stateProbeSelectedEvent.fullPath or stateProbeSelectedEvent.path or ""
	if tryClipboard(path) then
		flashStateProbeBtn(stateProbeCopyPathBtn, "Copied", "Copy Path")
	else
		flashStateProbeBtn(stateProbeCopyPathBtn, "Clipboard Off", "Copy Path")
	end
end)

stateProbeCopyValueBtn.MouseButton1Click:Connect(function()
	if not stateProbeSelectedEvent then
		flashStateProbeBtn(stateProbeCopyValueBtn, "Select One", "Copy Value")
		return
	end
	local value = stateProbeSelectedEvent.value or ""
	if tryClipboard(value) then
		flashStateProbeBtn(stateProbeCopyValueBtn, "Copied", "Copy Value")
	else
		flashStateProbeBtn(stateProbeCopyValueBtn, "Clipboard Off", "Copy Value")
	end
end)

stateProbeCopyLogBtn.MouseButton1Click:Connect(function()
	if not stateProbeSelectedEvent then
		flashStateProbeBtn(stateProbeCopyLogBtn, "Select One", "Copy Log")
		return
	end
	local event = stateProbeSelectedEvent
	local payload = table.concat({
		("Event: %s"):format(event.eventName or "?"),
		("Field: %s"):format(event.fieldName or "?"),
		("Path: %s"):format(event.fullPath or event.path or "?"),
		("Value: %s"):format(event.value or "nil"),
		event.message or "",
	}, "\n")
	if tryClipboard(payload) then
		flashStateProbeBtn(stateProbeCopyLogBtn, "Copied", "Copy Log")
	else
		flashStateProbeBtn(stateProbeCopyLogBtn, "Clipboard Off", "Copy Log")
	end
end)

local function flashRd(btn, msg, orig)
	btn.Text = msg; task.delay(1.3, function() btn.Text = orig end)
end

rdCopyCodeBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then return end
	local code = buildCode(selectedRemoteData.remote, selectedRemoteData.method, selectedRemoteData.argsStr)
	if tryClipboard(code) then flashRd(rdCopyCodeBtn, "✔ Copied!", "📋 Copy Code")
	else flashRd(rdCopyCodeBtn, "Clipboard Off", "📋 Copy Code") end
end)

rdCopyPathBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then return end
	local path = getRemotePath(selectedRemoteData.remote)
	if tryClipboard(path) then flashRd(rdCopyPathBtn, "✔ Copied!", "🔗 Copy Path")
	else flashRd(rdCopyPathBtn, "Clipboard Off", "🔗 Copy Path") end
end)

rdRunCodeBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then return end
	local data = selectedRemoteData
	local remote = data.remote
	local args = data.args or {}
	local ok, runErr

	if data.method == "FireServer" and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
		ok, runErr = pcall(function()
			remote:FireServer(unpackArgs(args))
		end)
	elseif data.method == "InvokeServer" and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
		ok, runErr = pcall(function()
			remote:InvokeServer(unpackArgs(args))
		end)
	else
		ok, runErr = false, "Remote is missing or method/type does not match."
	end

	if ok then
		flashRd(rdRunCodeBtn, "✔ Done!", "▶ Run Code")
	else
		flashRd(rdRunCodeBtn, "⚠ Error!", "▶ Run Code")
	end
end)

-- ========== ANIMATION DETAIL VIEW ==========
local function refreshAnimDetail()
	if not currentAnimDetail then return end
	local data = currentAnimDetail
	local track    = data.track
	local character = data.character
	local humanoid = data.humanoid

	local function bText(t) return "<b>"..t.."</b>" end
	local function cText(t,h) return ('<font color="#%s">%s</font>'):format(h,t) end
	local function section(title) return "\n"..cText(bText(title),"A090FF").."\n" end

	local priority  = safeGet(function() return tostring(track.Priority) end)
	local length    = safeGet(function() return ("%.3fs"):format(track.Length) end)
	local speed     = safeGet(function() return ("%.2f"):format(track.Speed) end)
	local weight    = safeGet(function() return ("%.2f"):format(track.WeightCurrent) end)
	local timePos   = safeGet(function() return ("%.3fs"):format(track.TimePosition) end)
	local looped    = safeGet(function() return tostring(track.Looped) end)
	local isPlaying = safeGet(function() return tostring(track.IsPlaying) end)

	local player   = Players:GetPlayerFromCharacter(character)
	local charName = character and character.Name or "Unknown"
	local dispName = player and player.DisplayName or "(NPC)"
	local userName = player and ("@"..player.Name) or ""
	local userId   = player and tostring(player.UserId) or "N/A"
	local accAge   = player and (tostring(player.AccountAge).." days") or "N/A"
	local teamName = player and (player.Team and player.Team.Name or "No team") or "N/A"
	local health   = humanoid and ("%.0f / %.0f"):format(humanoid.Health,humanoid.MaxHealth) or "N/A"
	local walkSpd  = humanoid and tostring(humanoid.WalkSpeed) or "N/A"
	local rigType  = humanoid and tostring(humanoid.RigType)   or "N/A"
	local state    = humanoid and tostring(humanoid:GetState()) or "N/A"
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local pos      = rootPart and rootPart.Position
	local posStr   = pos and ("(%.1f, %.1f, %.1f)"):format(pos.X,pos.Y,pos.Z) or "N/A"
	local origin
	if localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart") then
		origin = localPlayer.Character.HumanoidRootPart.Position
	end
	local curDist  = (pos and origin) and ("%.1f studs"):format((pos-origin).Magnitude) or "N/A"
	local tool     = character and character:FindFirstChildWhichIsA("Tool")
	local toolName = tool and tool.Name or "None"

	local playingTracks = {}
	if humanoid then
		local anim = humanoid:FindFirstChildOfClass("Animator")
		if anim then
			local ok, tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
			if ok and tracks then
				for _, t in ipairs(asArray(tracks)) do
					table.insert(playingTracks,
						("  • %s  [%s]"):format(t.Name~=""and t.Name or "Unnamed",
						t.Animation and t.Animation.AnimationId or "?"))
				end
			end
		end
	end

	local lines = {
		section("🎬 ANIMATION"),
		bText("Name: ")          .. (data.animName or "Unnamed"),
		bText("Asset ID: ")      .. cText(data.animId or "Unknown","FFD080"),
		bText("Priority: ")      .. priority,
		bText("Length: ")        .. length,
		bText("Speed: ")         .. speed,
		bText("Weight: ")        .. weight,
		bText("Time Position: ") .. timePos,
		bText("Looped: ")        .. looped,
		bText("Is Playing: ")    .. isPlaying,
		bText("Detected At: ")   .. data.timestamp,
		section("👤 CHARACTER"),
		bText("Name: ")         .. charName,
		bText("Display Name: ") .. dispName,
		bText("Username: ")     .. userName,
		bText("Is Player: ")    .. (player and "Yes" or "No (NPC)"),
		bText("User ID: ")      .. userId,
		bText("Account Age: ")  .. accAge,
		bText("Team: ")         .. teamName,
		section("❤️ HUMANOID"),
		bText("Health: ")       .. health,
		bText("Walk Speed: ")   .. walkSpd,
		bText("Rig Type: ")     .. rigType,
		bText("State: ")        .. state,
		bText("Equipped Tool: ").. toolName,
		section("📍 POSITION"),
		bText("World Position: ")      .. posStr,
		bText("Distance (detected): ") .. ("%.1f studs"):format(data.distance),
		bText("Distance (now): ")      .. curDist,
		section("🎞️ PLAYING TRACKS"),
		#playingTracks > 0 and table.concat(playingTracks,"\n") or "  (none)",
	}

	animDetailText.Text = table.concat(lines, "\n")
	animDetailScroll.CanvasPosition = Vector2.new(0, 0)
end

local function showAnimDetailView(data)
	currentAnimDetail    = data
	detailFrame.Visible  = true
	local idNum = extractIdNumber(data and data.animId)
	if idNum and pausedIndividualAnimations[idNum] then
		ignoreBtn.Text = "Resume Anim"
		ignoreBtn.BackgroundColor3 = Color3.fromRGB(42, 112, 72)
	else
		ignoreBtn.Text = "Pause This Anim"
		ignoreBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 110)
	end
	refreshAnimDetail()
end

ignoreBtn.MouseButton1Click:Connect(function()
	if not currentAnimDetail then return end
	local idNum = extractIdNumber(currentAnimDetail.animId)
	if not idNum then return end
	if pausedIndividualAnimations[idNum] then
		pausedIndividualAnimations[idNum] = nil
		ignoreBtn.Text = "Pause This Anim"
		ignoreBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 110)
	else
		pausedIndividualAnimations[idNum] = currentAnimDetail
		for i = #animEntries, 1, -1 do
			local e = animEntries[i]
			if extractIdNumber(e.data and e.data.animId) == idNum then
				e.button:Destroy()
				table.remove(animEntries, i)
			end
		end
		ignoreBtn.Text = "Resume Anim"
		ignoreBtn.BackgroundColor3 = Color3.fromRGB(42, 112, 72)
		detailFrame.Visible = false
	end
end)

copyIdBtn.MouseButton1Click:Connect(function()
	if currentAnimDetail then
		local animId = currentAnimDetail.animId or ""
		if tryClipboard(animId) then
			copyIdBtn.Text = "Copied ID!"
		else
			copyIdBtn.Text = "Clipboard Off"
		end
		task.delay(1.3, function()
			if copyIdBtn and copyIdBtn.Parent then
				copyIdBtn.Text = "Print ID to Console"
			end
		end)
	end
end)
refreshAnimBtn.MouseButton1Click:Connect(refreshAnimDetail)

-- ========== ANIMATION LOG ENTRY ==========
local function addLogEntry(data)
	local idNum = extractIdNumber(data and data.animId)
	local characterKey = safeGet(function()
		return data.character and data.character:GetFullName()
	end) or (data.character and data.character.Name) or "UnknownCharacter"
	local animKey = table.concat({
		characterKey,
		tostring(data.animId or "UnknownAnim"),
		tostring(data.animName or "Unnamed"),
	}, "|")

	if seenAnimationEntries[animKey] then
		return
	end

	if animLogPaused or (idNum and pausedIndividualAnimations[idNum]) then
		filteredCount += 1
		pausedAnimationArchive[#pausedAnimationArchive + 1] = data
		if #pausedAnimationArchive > MAX_LOG_ENTRIES then
			table.remove(pausedAnimationArchive, 1)
		end
		updateStatus()
		return
	end
	detectionCount += 1; updateStatus()

	local children = {}
	for _, c in ipairs(scrollFrame:GetChildren()) do
		if c:IsA("TextButton") then table.insert(children, c) end
	end
	if #children >= MAX_LOG_ENTRIES then
		table.sort(children, function(a,b) return a.LayoutOrder < b.LayoutOrder end)
		local oldest = children[1]
		for i, e in ipairs(asArray(animEntries)) do
			if e.button == oldest then
				table.remove(animEntries, i)
				break
			end
		end
		oldest:Destroy()
	end

	entryOrder += 1
	local entry = Instance.new("TextButton")
	entry.Size = UDim2.new(1,-4,0,38); entry.BackgroundColor3 = Theme.EntryBg
	entry.BorderSizePixel = 0; entry.LayoutOrder = entryOrder
	entry.AutoButtonColor = false; entry.Text = ""; entry.Parent = scrollFrame
	mkCorner(entry, 4)

	local player = data.player or Players:GetPlayerFromCharacter(data.character)
	local displayName = player and (player.DisplayName .. " (@" .. player.Name .. ")") or data.character.Name

	local top = Instance.new("TextLabel", entry)
	top.Size = UDim2.new(1,-8,0,16); top.Position = UDim2.new(0,6,0,2)
	top.BackgroundTransparency = 1
	top.Text = ("[%s] %s — %.1f studs"):format(data.timestamp, displayName, data.distance)
	top.TextColor3 = Color3.fromRGB(255,160,140); top.TextXAlignment = Enum.TextXAlignment.Left
	top.Font = Enum.Font.GothamBold; top.TextSize = 11

	local bot = Instance.new("TextLabel", entry)
	bot.Size = UDim2.new(1,-8,0,16); bot.Position = UDim2.new(0,6,0,18)
	bot.BackgroundTransparency = 1
	bot.Text = ("%s  (%s)"):format(data.animName, data.animId)
	bot.TextColor3 = Theme.TextSecondary; bot.TextXAlignment = Enum.TextXAlignment.Left
	bot.Font = Enum.Font.Code; bot.TextSize = 10; bot.TextTruncate = Enum.TextTruncate.AtEnd

	entry.MouseEnter:Connect(function()  entry.BackgroundColor3 = Theme.EntryHover end)
	entry.MouseLeave:Connect(function()  entry.BackgroundColor3 = Theme.EntryBg end)
	entry.MouseButton1Click:Connect(function() showAnimDetailView(data) end)
	table.insert(animEntries, { button = entry, data = data, player = player, dedupeKey = animKey })
	seenAnimationEntries[animKey] = true
	task.defer(function()
		scrollFrame.CanvasPosition = Vector2.new(0, scrollFrame.AbsoluteCanvasSize.Y)
	end)
end

clearBtn.MouseButton1Click:Connect(function()
	for _, c in ipairs(scrollFrame:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	animEntries = {}
	seenAnimationEntries = {}
	detectionCount = 0; filteredCount = 0; updateStatus()
end)

-- ========== REMOTE LOG ENTRY ==========
local remoteEntries = {}

applyRemoteFilter = function()
	local searchLower = remoteSearchText:lower()
	for _, entryData in ipairs(asArray(remoteEntries)) do
		local btn = entryData.button
		if btn then
			local visible = true
			if remoteFilterLocal and entryData.player ~= localPlayer then
				visible = false
			end
			if visible and searchLower ~= "" then
				if not string.find(entryData.remoteName:lower(), searchLower, 1, true) then
					visible = false
				end
			end
			btn.Visible = visible
		end
	end
end

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	remoteSearchText = searchBox.Text
	applyRemoteFilter()
end)

local function addRemoteEntry(data)
	if remoteLogPaused then return end
	if remoteFilterLocal and data.player ~= localPlayer then return end

	remoteCount += 1; updateStatus()

	local children = {}
	for _, c in ipairs(remoteScroll:GetChildren()) do
		if c:IsA("TextButton") then table.insert(children, c) end
	end
	if #children >= MAX_LOG_ENTRIES then
		table.sort(children, function(a,b) return a.LayoutOrder < b.LayoutOrder end)
		local oldest = children[1]
		for i, e in ipairs(asArray(remoteEntries)) do
			if e.button == oldest then
				table.remove(remoteEntries, i)
				break
			end
		end
		oldest:Destroy()
	end

	entryOrder += 1
	local isFire  = (data.method == "FireServer")
	local bgBadge = isFire and Color3.fromRGB(90,55,20) or Color3.fromRGB(20,55,100)
	local fgBadge = isFire and Color3.fromRGB(255,185,90) or Color3.fromRGB(110,200,255)

	local entry = Instance.new("TextButton")
	entry.Size = UDim2.new(1,-4,0,44); entry.BackgroundColor3 = Theme.EntryBg
	entry.BorderSizePixel = 0; entry.LayoutOrder = entryOrder
	entry.AutoButtonColor = false; entry.Text = ""; entry.Parent = remoteScroll
	mkCorner(entry, 4)

	local badge = Instance.new("TextLabel", entry)
	badge.Size = UDim2.new(0,84,0,15); badge.Position = UDim2.new(0,6,0,4)
	badge.BackgroundColor3 = bgBadge; badge.Text = data.method
	badge.TextColor3 = fgBadge; badge.TextXAlignment = Enum.TextXAlignment.Center
	badge.Font = Enum.Font.GothamBold; badge.TextSize = 8; badge.BorderSizePixel = 0
	mkCorner(badge, 3)

	local ts = Instance.new("TextLabel", entry)
	ts.Size = UDim2.new(0,58,0,15); ts.Position = UDim2.new(1,-62,0,4)
	ts.BackgroundTransparency = 1; ts.Text = data.timestamp
	ts.TextColor3 = Color3.fromRGB(110,110,130); ts.TextXAlignment = Enum.TextXAlignment.Right
	ts.Font = Enum.Font.Gotham; ts.TextSize = 9

	local nameLine = Instance.new("TextLabel", entry)
	nameLine.Size = UDim2.new(1,-10,0,14); nameLine.Position = UDim2.new(0,6,0,20)
	nameLine.BackgroundTransparency = 1; nameLine.Text = data.remoteName
	nameLine.TextColor3 = Color3.fromRGB(215,190,255); nameLine.TextXAlignment = Enum.TextXAlignment.Left
	nameLine.Font = Enum.Font.GothamBold; nameLine.TextSize = 11
	nameLine.TextTruncate = Enum.TextTruncate.AtEnd

	local argsLine = Instance.new("TextLabel", entry)
	argsLine.Size = UDim2.new(1,-10,0,12); argsLine.Position = UDim2.new(0,6,0,31)
	argsLine.BackgroundTransparency = 1; argsLine.Text = data.argsPreview
	argsLine.TextColor3 = Color3.fromRGB(140,155,165); argsLine.TextXAlignment = Enum.TextXAlignment.Left
	argsLine.Font = Enum.Font.Code; argsLine.TextSize = 9
	argsLine.TextTruncate = Enum.TextTruncate.AtEnd

	entry.MouseEnter:Connect(function()
		if selectedRemoteEntry ~= entry then
			entry.BackgroundColor3 = Theme.EntryHover
		end
	end)
	entry.MouseLeave:Connect(function()
		if selectedRemoteEntry ~= entry then
			entry.BackgroundColor3 = Theme.EntryBg
		end
	end)
	entry.MouseButton1Click:Connect(function()
		if selectedRemoteEntry and selectedRemoteEntry ~= entry then
			selectedRemoteEntry.BackgroundColor3 = Theme.EntryBg
		end
		selectedRemoteEntry = entry
		entry.BackgroundColor3 = Theme.EntrySelected
		showRemoteDetail(data)
	end)

	table.insert(remoteEntries, {button = entry, remoteName = data.remoteName, player = data.player, data = data})
	applyRemoteFilter()

	task.defer(function()
		remoteScroll.CanvasPosition = Vector2.new(0, remoteScroll.AbsoluteCanvasSize.Y)
	end)
end
openPausedRemotesBtn.MouseButton1Click:Connect(function()
	pcall(loadstring([[
		local args = ...
		local pGui = args[1]
		local T = args[2]
		local mkC = args[3]
		local mkS = args[4]
		local pIR = args[5]
		local pRA = args[6]
		local Plrs = args[7]
		local showRD = args[8]

		if not pGui:FindFirstChild("PausedRemotesPopup") then
			local gui = Instance.new("ScreenGui")
			gui.Name = "PausedRemotesPopup"
			gui.ResetOnSpawn = false
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.DisplayOrder = 20
			gui.Enabled = false
			gui.Parent = pGui

			local win = Instance.new("Frame", gui)
			win.Name = "Win"
			win.Size = UDim2.new(0, 480, 0, 360)
			win.Position = UDim2.new(0.5, -240, 0.5, -180)
			win.BackgroundColor3 = T.Background
			win.BorderSizePixel = 0
			mkC(win, 8); mkS(win, T.StrokeColor)

			local tb = Instance.new("Frame", win)
			tb.Name = "TitleBar"
			tb.Size = UDim2.new(1,0,0,32)
			tb.BackgroundColor3 = T.TitleBar
			tb.BorderSizePixel = 0
			mkC(tb, 8)
			local tf = Instance.new("Frame", win)
			tf.Size = UDim2.new(1,0,0,8)
			tf.Position = UDim2.new(0,0,0,24)
			tf.BackgroundColor3 = T.TitleBar
			tf.BorderSizePixel = 0

			local tl = Instance.new("TextLabel", tb)
			tl.Name = "TitleLbl"
			tl.Size = UDim2.new(1,-40,1,0)
			tl.Position = UDim2.new(0,10,0,0)
			tl.BackgroundTransparency = 1
			tl.Text = "Paused Remotes"
			tl.TextColor3 = T.TextPrimary
			tl.Font = Enum.Font.GothamBold
			tl.TextSize = 13
			tl.TextXAlignment = Enum.TextXAlignment.Left

			local cb = Instance.new("TextButton", tb)
			cb.Size = UDim2.new(0,26,0,20)
			cb.Position = UDim2.new(1,-30,0.5,-10)
			cb.BackgroundColor3 = T.ButtonDanger
			cb.Text = "X"
			cb.TextColor3 = Color3.fromRGB(255,255,255)
			cb.Font = Enum.Font.GothamBold
			cb.TextSize = 11
			cb.BorderSizePixel = 0
			cb.AutoButtonColor = false
			mkC(cb, 4)

			local sc = Instance.new("ScrollingFrame", win)
			sc.Name = "Scroll"
			sc.Size = UDim2.new(1,-8,1,-40)
			sc.Position = UDim2.new(0,4,0,36)
			sc.BackgroundTransparency = 1
			sc.BorderSizePixel = 0
			sc.ScrollBarThickness = 4
			sc.ScrollBarImageColor3 = T.ScrollBarColor
			sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
			sc.CanvasSize = UDim2.new(0,0,0,0)
			local ly = Instance.new("UIListLayout", sc)
			ly.SortOrder = Enum.SortOrder.LayoutOrder
			ly.Padding = UDim.new(0,3)

			local rg = Instance.new("TextButton", win)
			rg.Name = "ResizeGrip"
			rg.Size = UDim2.new(0,16,0,16)
			rg.Position = UDim2.new(1,-18,1,-18)
			rg.BackgroundColor3 = T.ScrollBarColor
			rg.BackgroundTransparency = 0.35
			rg.Text = "⇲"
			rg.TextColor3 = T.TextPrimary
			rg.Font = Enum.Font.GothamBold
			rg.TextSize = 11
			rg.BorderSizePixel = 0
			rg.AutoButtonColor = false
			rg.ZIndex = 10
			mkC(rg, 3)

			local UIS = game:GetService("UserInputService")
			local RS = game:GetService("RunService")
			win.Active = true

			local dragging, resizing = false, false
			local dragOffsetX, dragOffsetY = 0, 0
			local resizeStartMouse, resizeStartSize = nil, nil
			local endedConn, hbConn, enabledConn, ancestryConn

			local function disconnectAll()
				if endedConn then endedConn:Disconnect(); endedConn = nil end
				if hbConn then hbConn:Disconnect(); hbConn = nil end
				if enabledConn then enabledConn:Disconnect(); enabledConn = nil end
				if ancestryConn then ancestryConn:Disconnect(); ancestryConn = nil end
			end

			cb.MouseButton1Click:Connect(function()
				dragging = false
				resizing = false
				disconnectAll()
				gui.Enabled = false
			end)

			win.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
				end
			end)

			tb.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
					local mp = UIS:GetMouseLocation()
					local wp = win.AbsolutePosition
					dragOffsetX = mp.X - wp.X
					dragOffsetY = mp.Y - wp.Y
					dragging = true
				end
			end)

			rg.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
					resizeStartMouse = UIS:GetMouseLocation()
					resizeStartSize = win.AbsoluteSize
					resizing = true
				end
			end)

			endedConn = UIS.InputEnded:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					dragging = false
					resizing = false
					gui.DisplayOrder = 20
				end
			end)

			hbConn = RS.Heartbeat:Connect(function()
				if dragging then
					local mp = UIS:GetMouseLocation()
					win.Position = UDim2.new(0, mp.X - dragOffsetX, 0, mp.Y - dragOffsetY)
				elseif resizing and resizeStartMouse and resizeStartSize then
					local mp = UIS:GetMouseLocation()
					local dx = mp.X - resizeStartMouse.X
					local dy = mp.Y - resizeStartMouse.Y
					win.Size = UDim2.new(0, math.clamp(resizeStartSize.X + dx, 360, 1200), 0, math.clamp(resizeStartSize.Y + dy, 260, 900))
				end
			end)

			enabledConn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
				if not gui.Enabled then
					dragging = false
					resizing = false
					disconnectAll()
				end
			end)

			ancestryConn = gui.AncestryChanged:Connect(function(_, parent)
				if not parent then
					disconnectAll()
				end
			end)
		end

		local popG = pGui:FindFirstChild("PausedRemotesPopup")
		if not popG then return end
		local win = popG:FindFirstChild("Win")
		if not win then return end
		local scroll = win:FindFirstChild("Scroll")
		if not scroll then return end

		for _, c in ipairs(scroll:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end

		local names = {}
		for rName in pairs(pIR) do
			if pRA[rName] then table.insert(names, rName) end
		end
		table.sort(names)

		for i, rName in ipairs(names) do
			local data = pRA[rName]
			if data then
				local row = Instance.new("Frame", scroll)
				row.Size = UDim2.new(1,-4,0,54)
				row.BackgroundColor3 = T.EntryBg
				row.BorderSizePixel = 0
				row.LayoutOrder = i
				mkC(row, 4)

				local clickArea = Instance.new("TextButton", row)
				clickArea.Size = UDim2.new(1,-82,1,0)
				clickArea.Position = UDim2.new(0,0,0,0)
				clickArea.BackgroundTransparency = 1
				clickArea.Text = ""
				clickArea.AutoButtonColor = false

				local badge = Instance.new("TextLabel", row)
				badge.Size = UDim2.new(0,28,0,12)
				badge.Position = UDim2.new(0,4,0,4)
				badge.BackgroundColor3 = Color3.fromRGB(180,60,60)
				badge.TextColor3 = Color3.fromRGB(255,255,255)
				badge.Text = data.method or "?"
				badge.Font = Enum.Font.GothamBold
				badge.TextSize = 8
				badge.BorderSizePixel = 0
				mkC(badge, 3)

				local ts = Instance.new("TextLabel", row)
				ts.Size = UDim2.new(0,58,0,15)
				ts.Position = UDim2.new(1,-144,0,4)
				ts.BackgroundTransparency = 1
				ts.Text = data.timestamp or ""
				ts.TextColor3 = Color3.fromRGB(110,110,130)
				ts.TextXAlignment = Enum.TextXAlignment.Right
				ts.Font = Enum.Font.Gotham
				ts.TextSize = 9

				local nl = Instance.new("TextLabel", row)
				nl.Size = UDim2.new(1,-92,0,14)
				nl.Position = UDim2.new(0,6,0,20)
				nl.BackgroundTransparency = 1
				nl.Text = data.remoteName or rName
				nl.TextColor3 = Color3.fromRGB(215,190,255)
				nl.TextXAlignment = Enum.TextXAlignment.Left
				nl.Font = Enum.Font.GothamBold
				nl.TextSize = 11
				nl.TextTruncate = Enum.TextTruncate.AtEnd

				local al = Instance.new("TextLabel", row)
				al.Size = UDim2.new(1,-92,0,12)
				al.Position = UDim2.new(0,6,0,37)
				al.BackgroundTransparency = 1
				al.Text = data.argsPreview or ""
				al.TextColor3 = Color3.fromRGB(140,155,165)
				al.TextXAlignment = Enum.TextXAlignment.Left
				al.Font = Enum.Font.Code
				al.TextSize = 9
				al.TextTruncate = Enum.TextTruncate.AtEnd

				local unpBtn = Instance.new("TextButton", row)
				unpBtn.Size = UDim2.new(0,72,0,28)
				unpBtn.Position = UDim2.new(1,-76,0.5,-14)
				unpBtn.BackgroundColor3 = Color3.fromRGB(42,112,72)
				unpBtn.Text = "Unpause"
				unpBtn.TextColor3 = Color3.fromRGB(255,255,255)
				unpBtn.Font = Enum.Font.GothamBold
				unpBtn.TextSize = 10
				unpBtn.BorderSizePixel = 0
				unpBtn.AutoButtonColor = false
				mkC(unpBtn, 4)

				local capturedName = rName
				local capturedData = data
				unpBtn.MouseButton1Click:Connect(function()
					pIR[capturedName] = nil
					pRA[capturedName] = nil
					row:Destroy()
					local tl3 = win:FindFirstChild("TitleBar") and win.TitleBar:FindFirstChild("TitleLbl")
					local remaining = 0
					for _ in pairs(pIR) do remaining += 1 end
					if tl3 then tl3.Text = ("Paused Remotes (%d)"):format(remaining) end
				end)
				clickArea.MouseButton1Click:Connect(function()
					if showRD then showRD(capturedData) end
				end)
				row.MouseEnter:Connect(function() row.BackgroundColor3 = T.EntryHover end)
				row.MouseLeave:Connect(function() row.BackgroundColor3 = T.EntryBg end)
			end
		end

		local tl2 = win:FindFirstChild("TitleBar") and win.TitleBar:FindFirstChild("TitleLbl")
		if tl2 then tl2.Text = ("Paused Remotes (%d)"):format(#names) end
		popG.Enabled = true
	]]), {playerGui, Theme, mkCorner, mkStroke, pausedIndividualRemotes, pausedRemoteArchive, Players, showRemoteDetail})
end)

openPausedAnimationsBtn.MouseButton1Click:Connect(function()
	pcall(loadstring([[
		local args = ...
		local pGui = args[1]
		local T = args[2]
		local mkC = args[3]
		local mkS = args[4]
		local pIA = args[5]   -- pausedIndividualAnimations: idNum -> data
		local Plrs = args[6]
		local showDetail = args[7]  -- showAnimDetailView function

		local existing = pGui:FindFirstChild("PausedAnimationsPopup")
		if existing then existing:Destroy() end

		if not pGui:FindFirstChild("PausedAnimationsPopup") then
			local UIS = game:GetService("UserInputService")
			local gui = Instance.new("ScreenGui")
			gui.Name = "PausedAnimationsPopup"
			gui.ResetOnSpawn = false
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.DisplayOrder = 20
			gui.Enabled = false
			gui.Parent = pGui

			local win = Instance.new("Frame", gui)
			win.Name = "Win"
			win.Size = UDim2.new(0, 480, 0, 360)
			win.Position = UDim2.new(0.5, -200, 0.5, -140)
			win.BackgroundColor3 = T.Background
			win.BorderSizePixel = 0
			mkC(win, 8); mkS(win, T.StrokeColor)

			local tb = Instance.new("Frame", win)
			tb.Name = "TitleBar"
			tb.Size = UDim2.new(1,0,0,32)
			tb.BackgroundColor3 = T.TitleBar
			tb.BorderSizePixel = 0
			tb.Active = true
			mkC(tb, 8)
			local tf = Instance.new("Frame", win)
			tf.Size = UDim2.new(1,0,0,8)
			tf.Position = UDim2.new(0,0,0,24)
			tf.BackgroundColor3 = T.TitleBar
			tf.BorderSizePixel = 0

			local tl = Instance.new("TextLabel", tb)
			tl.Name = "TitleLbl"
			tl.Size = UDim2.new(1,-40,1,0)
			tl.Position = UDim2.new(0,10,0,0)
			tl.BackgroundTransparency = 1
			tl.Text = "Paused Animations"
			tl.TextColor3 = T.TextPrimary
			tl.Font = Enum.Font.GothamBold
			tl.TextSize = 13
			tl.TextXAlignment = Enum.TextXAlignment.Left
			tl.Active = true

			local cb = Instance.new("TextButton", tb)
			cb.Size = UDim2.new(0,26,0,20)
			cb.Position = UDim2.new(1,-30,0.5,-10)
			cb.BackgroundColor3 = T.ButtonDanger
			cb.Text = "X"
			cb.TextColor3 = Color3.fromRGB(255,255,255)
			cb.Font = Enum.Font.GothamBold
			cb.TextSize = 11
			cb.BorderSizePixel = 0
			cb.AutoButtonColor = false
			mkC(cb, 4)

			local sc = Instance.new("ScrollingFrame", win)
			sc.Name = "Scroll"
			sc.Size = UDim2.new(1,-8,1,-40)
			sc.Position = UDim2.new(0,4,0,36)
			sc.BackgroundTransparency = 1
			sc.BorderSizePixel = 0
			sc.ScrollBarThickness = 4
			sc.ScrollBarImageColor3 = T.ScrollBarColor
			sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
			sc.CanvasSize = UDim2.new(0,0,0,0)
			local ly = Instance.new("UIListLayout", sc)
			ly.SortOrder = Enum.SortOrder.LayoutOrder
			ly.Padding = UDim.new(0,3)

			local rg = Instance.new("TextButton", win)
			rg.Name = "ResizeGrip"
			rg.Size = UDim2.new(0,16,0,16)
			rg.Position = UDim2.new(1,-18,1,-18)
			rg.BackgroundColor3 = T.ScrollBarColor
			rg.BackgroundTransparency = 0.35
			rg.Text = "⇲"
			rg.TextColor3 = T.TextPrimary
			rg.Font = Enum.Font.GothamBold
			rg.TextSize = 11
			rg.BorderSizePixel = 0
			rg.AutoButtonColor = false
			rg.ZIndex = 10
			mkC(rg, 3)

			win.Active = true

			local RS = game:GetService("RunService")
			local dragging, resizing = false, false
			local dragOffsetX, dragOffsetY = 0, 0
			local resizeStartMouse, resizeStartSize = nil, nil
			local endedConn, hbConn, enabledConn, ancestryConn

			local function disconnectAll()
				if endedConn then endedConn:Disconnect(); endedConn = nil end
				if hbConn then hbConn:Disconnect(); hbConn = nil end
				if enabledConn then enabledConn:Disconnect(); enabledConn = nil end
				if ancestryConn then ancestryConn:Disconnect(); ancestryConn = nil end
			end

			cb.MouseButton1Click:Connect(function()
				dragging = false
				resizing = false
				disconnectAll()
				gui.Enabled = false
			end)

			win.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
				end
			end)

			tb.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
					local mp = UIS:GetMouseLocation()
					local wp = win.AbsolutePosition
					dragOffsetX = mp.X - wp.X
					dragOffsetY = mp.Y - wp.Y
					dragging = true
				end
			end)

			rg.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					gui.DisplayOrder = 25
					resizeStartMouse = UIS:GetMouseLocation()
					resizeStartSize = win.AbsoluteSize
					resizing = true
				end
			end)

			endedConn = UIS.InputEnded:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					dragging = false
					resizing = false
					gui.DisplayOrder = 20
				end
			end)

			hbConn = RS.Heartbeat:Connect(function()
				if dragging then
					local mp = UIS:GetMouseLocation()
					win.Position = UDim2.new(0, mp.X - dragOffsetX, 0, mp.Y - dragOffsetY)
				elseif resizing and resizeStartMouse and resizeStartSize then
					local mp = UIS:GetMouseLocation()
					local dx = mp.X - resizeStartMouse.X
					local dy = mp.Y - resizeStartMouse.Y
					win.Size = UDim2.new(0, math.clamp(resizeStartSize.X + dx, 360, 1200), 0, math.clamp(resizeStartSize.Y + dy, 260, 900))
				end
			end)

			enabledConn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
				if not gui.Enabled then
					dragging = false
					resizing = false
					disconnectAll()
				end
			end)

			ancestryConn = gui.AncestryChanged:Connect(function(_, parent)
				if not parent then
					disconnectAll()
				end
			end)
		end

		local popG = pGui:FindFirstChild("PausedAnimationsPopup")
		if not popG then return end
		local win = popG:FindFirstChild("Win")
		if not win then return end
		local scroll = win:FindFirstChild("Scroll")
		if not scroll then return end

		for _, c in ipairs(scroll:GetChildren()) do
			if c:IsA("Frame") or c:IsA("TextButton") then c:Destroy() end
		end

		local count = 0
		for idNum, data in pairs(pIA) do
			count += 1
			local player = data.player or Plrs:GetPlayerFromCharacter(data.character)
			local dn = (player and (player.DisplayName .. " (@" .. player.Name .. ")")) or (data.character and data.character.Name) or "Unknown"

			local row = Instance.new("Frame", scroll)
			row.Size = UDim2.new(1,-4,0,54)
			row.BackgroundColor3 = T.EntryBg
			row.BorderSizePixel = 0
			row.LayoutOrder = count
			mkC(row, 4)

			local clickArea = Instance.new("TextButton", row)
			clickArea.Size = UDim2.new(1,-80,1,0)
			clickArea.Position = UDim2.new(0,0,0,0)
			clickArea.BackgroundTransparency = 1
			clickArea.Text = ""
			clickArea.AutoButtonColor = false

			local top = Instance.new("TextLabel", row)
			top.Size = UDim2.new(1,-88,0,16)
			top.Position = UDim2.new(0,6,0,4)
			top.BackgroundTransparency = 1
			top.Text = ("[%s] %s"):format(data.timestamp or "?", dn)
			top.TextColor3 = Color3.fromRGB(255,160,140)
			top.TextXAlignment = Enum.TextXAlignment.Left
			top.Font = Enum.Font.GothamBold
			top.TextSize = 10
			top.TextTruncate = Enum.TextTruncate.AtEnd

			local mid = Instance.new("TextLabel", row)
			mid.Size = UDim2.new(1,-88,0,14)
			mid.Position = UDim2.new(0,6,0,20)
			mid.BackgroundTransparency = 1
			mid.Text = data.animName or "Unnamed"
			mid.TextColor3 = Color3.fromRGB(215,190,255)
			mid.TextXAlignment = Enum.TextXAlignment.Left
			mid.Font = Enum.Font.GothamBold
			mid.TextSize = 11
			mid.TextTruncate = Enum.TextTruncate.AtEnd

			local bot = Instance.new("TextLabel", row)
			bot.Size = UDim2.new(1,-88,0,12)
			bot.Position = UDim2.new(0,6,0,35)
			bot.BackgroundTransparency = 1
			bot.Text = data.animId or "Unknown"
			bot.TextColor3 = Color3.fromRGB(140,155,165)
			bot.TextXAlignment = Enum.TextXAlignment.Left
			bot.Font = Enum.Font.Code
			bot.TextSize = 9
			bot.TextTruncate = Enum.TextTruncate.AtEnd

			local unpBtn = Instance.new("TextButton", row)
			unpBtn.Size = UDim2.new(0,72,0,28)
			unpBtn.Position = UDim2.new(1,-76,0.5,-14)
			unpBtn.BackgroundColor3 = Color3.fromRGB(42,112,72)
			unpBtn.Text = "Unpause"
			unpBtn.TextColor3 = Color3.fromRGB(255,255,255)
			unpBtn.Font = Enum.Font.GothamBold
			unpBtn.TextSize = 10
			unpBtn.BorderSizePixel = 0
			unpBtn.AutoButtonColor = false
			mkC(unpBtn, 4)

			local capturedId = idNum
			local capturedData = data
			unpBtn.MouseButton1Click:Connect(function()
				pIA[capturedId] = nil
				row:Destroy()
				local tl2 = win:FindFirstChild("TitleBar") and win.TitleBar:FindFirstChild("TitleLbl")
				local remaining = 0
				for _ in pairs(pIA) do remaining += 1 end
				if tl2 then tl2.Text = ("Paused Animations (%d)"):format(remaining) end
			end)
			clickArea.MouseButton1Click:Connect(function()
				if showDetail then showDetail(capturedData) end
			end)
			row.MouseEnter:Connect(function() row.BackgroundColor3 = T.EntryHover end)
			row.MouseLeave:Connect(function() row.BackgroundColor3 = T.EntryBg end)
		end

		local tl2 = win:FindFirstChild("TitleBar") and win.TitleBar:FindFirstChild("TitleLbl")
		if tl2 then tl2.Text = ("Paused Animations (%d)"):format(count) end
		popG.Enabled = true
	]]), {playerGui, Theme, mkCorner, mkStroke, pausedIndividualAnimations, Players, showAnimDetailView})
end)

exportRemotesBtn.MouseButton1Click:Connect(function()
	local lines = {}
	for _, e in ipairs(asArray(remoteEntries)) do
		if e.button.Visible then
			local data = e.data
			if data then
				lines[#lines+1] = ("[%s] %s:%s(%s)"):format(
					data.timestamp, data.remoteName, data.method, data.argsStr)
			end
		end
	end
	local exportText = table.concat(lines, "\n")
	if tryClipboard(exportText) then
		flashRd(exportRemotesBtn, "✔ Exported!", "📤 Export")
	else
		flashRd(exportRemotesBtn, "Clipboard Off", "📤 Export")
	end
end)

exportAnimationsBtn.MouseButton1Click:Connect(function()
	local lines = {}
	for _, e in ipairs(asArray(animEntries)) do
		if e.button and e.button.Visible and e.data then
			local data = e.data
			local characterName = (data.character and data.character.Name) or "Unknown"
			lines[#lines + 1] = ("[%s] %s (%s) - %.1f studs - %s"):format(
				data.timestamp or "??:??:??",
				data.animName or "Unnamed",
				data.animId or "Unknown",
				data.distance or 0,
				characterName
			)
		end
	end
	local exportText = table.concat(lines, "\n")
	if tryClipboard(exportText) then
		flashRd(exportAnimationsBtn, "✔ Exported!", "📤 Export")
	else
		flashRd(exportAnimationsBtn, "Clipboard Off", "📤 Export")
	end
end)

-- ========== ACTION BAR BUTTONS ==========
local function flashBtn(btn, msg, orig)
	btn.Text = msg; task.delay(1.3, function() btn.Text = orig end)
end

copyCodeBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then flashBtn(copyCodeBtn,"Select entry!","Copy Code"); return end
	local code = buildCode(selectedRemoteData.remote, selectedRemoteData.method, selectedRemoteData.argsStr)
	if tryClipboard(code) then flashBtn(copyCodeBtn,"Copied!","Copy Code")
	else flashBtn(copyCodeBtn,"Clipboard Off","Copy Code") end
end)
copyPathBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then flashBtn(copyPathBtn,"Select entry!","Copy Path"); return end
	local path = getRemotePath(selectedRemoteData.remote)
	if tryClipboard(path) then flashBtn(copyPathBtn,"Copied!","Copy Path")
	else flashBtn(copyPathBtn,"Clipboard Off","Copy Path") end
end)
runCodeBtn.MouseButton1Click:Connect(function()
	if not selectedRemoteData then flashBtn(runCodeBtn,"Select entry!","Run Code"); return end
	local data = selectedRemoteData
	local remote = data.remote
	local args = data.args or {}
	local ok, re

	if data.method == "FireServer" and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
		ok, re = pcall(function()
			remote:FireServer(unpackArgs(args))
		end)
	elseif data.method == "InvokeServer" and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
		ok, re = pcall(function()
			remote:InvokeServer(unpackArgs(args))
		end)
	else
		ok, re = false, "Remote is missing or method/type does not match."
	end

	if ok then
		flashBtn(runCodeBtn,"Done!","Run Code")
	else
		flashBtn(runCodeBtn,"Error!","Run Code")
	end
end)
clearRemBtn.MouseButton1Click:Connect(function()
	for _, c in ipairs(remoteScroll:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	remoteEntries = {}
	remoteCount = 0; selectedRemoteData = nil; selectedRemoteEntry = nil
	remDetailFrame.Visible = false; updateStatus()
end)

-- ========== ANIMATION DETECTION ==========
local function onAnimationPlayed(humanoid, animationTrack)
	local character = humanoid.Parent; if not character then return end
	local origin    = getOriginPosition(); if not origin then return end
	local rootPart  = character:FindFirstChild("HumanoidRootPart"); if not rootPart then return end
	local distance  = (rootPart.Position - origin).Magnitude
	if distance > detectionRadius then return end

	local anim     = animationTrack.Animation
	local animId   = anim and anim.AnimationId or "Unknown"
	local animName = (animationTrack.Name ~= "" and animationTrack.Name)
		or (anim and anim.Name ~= "" and anim.Name) or "Unnamed"
	local player   = Players:GetPlayerFromCharacter(character)

	-- Strict mode limits logs to likely combat animations; normal mode logs everything in range.
	local passes = true
	if strictMode then
		passes = matchesAny(animName, COMBAT_KEYWORDS)
	end

	if not passes then filteredCount += 1; updateStatus(); return end

	addLogEntry({
		track = animationTrack, anim = anim, humanoid = humanoid,
		character = character,  animId = animId, animName = animName,
		player = player,
		distance = distance,    timestamp = os.date("%H:%M:%S"),
	})
end

-- Humanoid tracking with CollectionService
local HUMAN_TAG = "AnimDetectTracked"
local tracked = {}

local function trackHumanoid(humanoid)
	if tracked[humanoid] then return end
	tracked[humanoid] = true
	if CollectionService and type(CollectionService.AddTag) == "function" then
		pcall(function()
			CollectionService:AddTag(humanoid, HUMAN_TAG)
		end)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = humanoid:WaitForChild("Animator", 5)
		if not animator then return end
	end
	animator.AnimationPlayed:Connect(function(track)
		onAnimationPlayed(humanoid, track)
	end)
	humanoid.Destroying:Connect(function()
		tracked[humanoid] = nil
	end)
end

-- Initial scan
pcall(function()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Humanoid") then trackHumanoid(d) end
	end
end)

pcall(function()
	workspace.DescendantAdded:Connect(function(d)
		if d:IsA("Humanoid") then trackHumanoid(d) end
	end)
end)

if localPlayer.Character then
	watchLocalCharacterState(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(function(character)
	watchLocalCharacterState(character)
end)

-- ========== REMOTE DETECTION ==========
local function setupRemoteSpy()
	if type(hookmetamethod) ~= "function"
		or type(newcclosure) ~= "function"
		or type(getnamecallmethod) ~= "function" then
		return
	end

	local originalNamecall
	local hookOk, hookResult = pcall(function()
		return hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			if type(originalNamecall) ~= "function" then
				return nil
			end

			local method = getnamecallmethod()

			if method ~= "FireServer" and method ~= "InvokeServer" then
				return originalNamecall(self, ...)
			end

			local remote = self
			local remoteName = tostring(self)
			if typeof(self) == "Instance" then
				remoteName = self.Name
			end

			if not pausedIndividualRemotes[remoteName] then
				local args = {...}

				task.defer(function()
					local okSer, argsStr = pcall(serializeArgs, args)
					if not okSer then argsStr = "..." end

					local preview = argsStr ~= "" and ("(" .. argsStr .. ")") or "()"
					if #preview > 64 then preview = preview:sub(1, 61) .. "..." end

					pcall(addRemoteEntry, {
						remote = remote,
						remoteName = remoteName,
						method = method,
						args = args,
						argsStr = argsStr,
						argsPreview = preview,
						timestamp = os.date("%H:%M:%S"),
						player = localPlayer,
					})
				end)
			end

			return originalNamecall(self, ...)
		end))
	end)

	if not hookOk or type(hookResult) ~= "function" then
		return
	end
	originalNamecall = hookResult
end

if type(setupRemoteSpy) == "function" then
	pcall(setupRemoteSpy)
end
