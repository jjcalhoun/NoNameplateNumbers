-- NoNameplateNumbers
-- Hides the aura timer text on the default nameplates, and leaves cooldown
-- numbers everywhere else in the game untouched.
--
-- Nothing here depends on Blizzard's frame keys (UnitFrame.BuffFrame,
-- button.Cooldown and friends), because those get renamed between expansions.
-- Cooldowns are found by asking every cooldown that starts whether it lives
-- under a nameplate, and text is found by walking the aura icons themselves.

local ADDON_NAME, ns = ...

local UnitIsUnit, UnitIsFriend = UnitIsUnit, UnitIsFriend
local GetNamePlates = C_NamePlate and C_NamePlate.GetNamePlates
local GetNamePlateForUnit = C_NamePlate and C_NamePlate.GetNamePlateForUnit
local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
local strsub, strmatch, strlower, strfind = string.sub, string.match, string.lower, string.find

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "NoNameplateNumbers"

ns.defaults = {
	enabled = true,            -- master switch
	enemy = true,              -- auras on enemy nameplates
	friendly = true,           -- auras on friendly nameplates
	personal = true,           -- auras on the personal resource display
	suppressThirdParty = true, -- ask OmniCC / ElvUI style timers to stay off
	forceHideText = true,      -- hide timer text drawn as a plain font string
	hideSwipe = false,         -- optionally hide the dark cooldown swipe as well
}

-- cooldowns we know belong to a nameplate: cooldown -> nameplate frame
local tracked = setmetatable({}, { __mode = "k" })
-- nameplate frame -> set of its cooldowns
local plateCooldowns = setmetatable({}, { __mode = "k" })
-- font strings we hid ourselves: region -> { alpha, shown }
local hiddenText = setmetatable({}, { __mode = "k" })

local applying = false -- re-entrancy guard for our own widget calls
local EMPTY = {}

-- ---------------------------------------------------------------------------
-- Safe frame access
--
-- Nameplates can hold forbidden frames, and touching one of those throws. Any
-- walk that hits one has to skip it rather than take the rest of the addon
-- down with it.
-- ---------------------------------------------------------------------------

local function _forbidden(obj) return obj.IsForbidden and obj:IsForbidden() end
local function Forbidden(obj)
	if not obj then return true end
	local ok, res = pcall(_forbidden, obj)
	return (not ok) or res == true
end

local function _children(frame) return { frame:GetChildren() } end
local function Children(frame)
	local ok, list = pcall(_children, frame)
	return ok and list or EMPTY
end

local function _regions(frame) return { frame:GetRegions() } end
local function Regions(frame)
	local ok, list = pcall(_regions, frame)
	return ok and list or EMPTY
end

local function _objectType(obj) return obj:GetObjectType() end
local function ObjectType(obj)
	local ok, kind = pcall(_objectType, obj)
	return ok and kind or nil
end

-- ---------------------------------------------------------------------------
-- Which nameplate does a cooldown belong to?
-- ---------------------------------------------------------------------------

local function FindNamePlate(frame)
	local depth = 0
	while frame and depth < 12 do
		if frame.namePlateUnitToken ~= nil then
			return frame
		end
		local name = frame.GetName and frame:GetName()
		if name and strmatch(name, "^NamePlate%d+$") then
			return frame
		end
		frame = frame.GetParent and frame:GetParent()
		depth = depth + 1
	end
	return nil
end

local function Track(cd, plate)
	tracked[cd] = plate
	local set = plateCooldowns[plate]
	if not set then
		set = {}
		plateCooldowns[plate] = set
	end
	set[cd] = true
end

local function PlateOf(cd)
	local plate = tracked[cd]
	if plate ~= nil then
		return plate or nil
	end
	plate = FindNamePlate(cd)
	if plate then
		Track(cd, plate)
	else
		tracked[cd] = false -- ordinary cooldown, never look at it again
	end
	return plate
end

local function UnitOf(plate)
	return plate.namePlateUnitToken
		or (plate.UnitFrame and (plate.UnitFrame.unit or plate.UnitFrame.displayedUnit))
end

local function ShouldHide(unit)
	local db = ns.db
	if not db or not db.enabled then return false end
	if unit then
		if UnitIsUnit(unit, "player") then return db.personal end
		if UnitIsFriend("player", unit) then return db.friendly end
	end
	return db.enemy
end

-- ---------------------------------------------------------------------------
-- Timer text drawn as a plain font string
--
-- SetHideCountdownNumbers only covers the countdown the cooldown widget draws
-- itself. Anything else - Blizzard drawing the duration as its own font string,
-- or a timer addon that ignores noCooldownCount - is a font string sitting on
-- the aura icon or on the cooldown, and gets hidden here instead.
-- ---------------------------------------------------------------------------

local function LooksLikeCount(key)
	if not key then return false end
	key = strlower(key)
	return (strfind(key, "count", 1, true) or strfind(key, "stack", 1, true)
		or strfind(key, "charge", 1, true) or strfind(key, "application", 1, true)) ~= nil
end

-- The parent key a region is stored under, e.g. "Duration" or "Count".
local function _keyFor(parent, region)
	for k, v in pairs(parent) do
		if v == region and type(k) == "string" then return k end
	end
end
local function KeyFor(parent, region)
	local ok, key = pcall(_keyFor, parent, region)
	return ok and key or nil
end

local function HideRegion(region, hide)
	if hide then
		if not hiddenText[region] then
			hiddenText[region] = { alpha = region:GetAlpha(), shown = region:IsShown() }
		end
		-- alpha as well as hiding: an OnUpdate that only calls SetText and
		-- Show cannot bring the text back.
		region:SetAlpha(0)
		region:Hide()
	else
		local saved = hiddenText[region]
		if saved then
			region:SetAlpha(saved.alpha or 1)
			if saved.shown then region:Show() end
			hiddenText[region] = nil
		end
	end
end

-- Font strings on the cooldown itself, and in any small child frame of it.
local function SuppressCooldownText(frame, hide, depth)
	for _, region in ipairs(Regions(frame)) do
		if not Forbidden(region) and ObjectType(region) == "FontString" then
			if hide or hiddenText[region] then
				HideRegion(region, hide)
			end
		end
	end
	if depth < 2 then
		for _, child in ipairs(Children(frame)) do
			if not Forbidden(child) then
				SuppressCooldownText(child, hide, depth + 1)
			end
		end
	end
end

-- Font strings on the aura icon that owns the cooldown - the duration text -
-- while leaving the stack count alone.
local function SuppressIconText(icon, hide)
	for _, region in ipairs(Regions(icon)) do
		if not Forbidden(region) and ObjectType(region) == "FontString" then
			if hiddenText[region] then
				HideRegion(region, hide)
			elseif hide and not LooksLikeCount(KeyFor(icon, region)) then
				HideRegion(region, true)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------------

local function ApplyToCooldown(cd, hide)
	local db = ns.db
	applying = true

	if cd.nnnHidden ~= hide then
		cd:SetHideCountdownNumbers(hide)
		cd.nnnHidden = hide
	end

	-- The flag OmniCC, ElvUI and most other timer addons honour.
	local optOut = (hide and db.suppressThirdParty) or nil
	if cd.noCooldownCount ~= optOut then
		cd.noCooldownCount = optOut
		-- Timer addons only re-read the flag when a cooldown starts, so restart
		-- the running one to make the change visible immediately.
		local start, duration = cd:GetCooldownTimes()
		if start and duration and duration > 0 then
			cd:SetCooldown(start / 1000, duration / 1000)
		end
	end

	if db.forceHideText or cd.nnnTextHidden then
		local hideText = (hide and db.forceHideText) or false
		SuppressCooldownText(cd, hideText, 0)
		local icon = cd.GetParent and cd:GetParent()
		if icon and not Forbidden(icon) then
			SuppressIconText(icon, hideText)
		end
		cd.nnnTextHidden = hideText or nil
	end

	local drawSwipe = not (hide and db.hideSwipe)
	if cd.nnnSwipe ~= drawSwipe then
		cd:SetDrawSwipe(drawSwipe)
		cd.nnnSwipe = drawSwipe
	end

	applying = false
end

local function ApplyToPlate(plate, unit)
	local set = plateCooldowns[plate]
	if not set then return end
	local hide = ShouldHide(unit or UnitOf(plate))
	for cd in pairs(set) do
		ApplyToCooldown(cd, hide)
	end
end

-- Fallback discovery: auras that were already running before we hooked (right
-- after login, or on a nameplate that just appeared) never call SetCooldown
-- again, so walk the plate once and pick up every cooldown widget in it.
local function Discover(plate, frame, depth)
	for _, child in ipairs(Children(frame)) do
		if not Forbidden(child) then
			if ObjectType(child) == "Cooldown" and child.SetHideCountdownNumbers then
				if tracked[child] ~= plate then
					Track(child, plate)
				end
			elseif depth < 6 then
				Discover(plate, child, depth + 1)
			end
		end
	end
end

local function ScanPlate(plate, unit)
	Discover(plate, plate, 0)
	ApplyToPlate(plate, unit)
end

function ns.RefreshAll()
	if GetNamePlates then
		for _, plate in ipairs(GetNamePlates()) do
			ScanPlate(plate)
		end
	end
	-- also cover plates that are no longer shown but keep their cooldowns
	for cd, plate in pairs(tracked) do
		if plate then
			ApplyToCooldown(cd, ShouldHide(UnitOf(plate)))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Every cooldown in the game runs through these two widget methods. The very
-- first call per cooldown decides whether it lives on a nameplate, after that
-- it is a single table lookup, so ordinary cooldowns cost next to nothing.
local function HookCooldownWidgets()
	local probe = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
	local meta = getmetatable(probe)
	local index = meta and meta.__index
	if type(index) ~= "table" or type(index.SetCooldown) ~= "function" then
		ns.hookFailed = true
		return
	end

	hooksecurefunc(index, "SetCooldown", function(self)
		if applying then return end
		local plate = PlateOf(self)
		if plate then
			ApplyToCooldown(self, ShouldHide(UnitOf(plate)))
		end
	end)

	-- Blizzard turns the numbers back on for some aura frames after setting the
	-- cooldown, so put our answer back when that happens on a nameplate.
	if type(index.SetHideCountdownNumbers) == "function" then
		hooksecurefunc(index, "SetHideCountdownNumbers", function(self, value)
			if applying or value then return end
			local plate = PlateOf(self)
			if plate and ShouldHide(UnitOf(plate)) then
				self.nnnHidden = nil
				ApplyToCooldown(self, true)
			end
		end)
	end

	ns.hooked = true
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("UNIT_AURA")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "UNIT_AURA" then
		if ns.db and strsub(arg1, 1, 9) == "nameplate" then
			local plate = GetNamePlateForUnit and GetNamePlateForUnit(arg1)
			if plate then
				ApplyToPlate(plate, arg1)
			end
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" then
		local plate = GetNamePlateForUnit and GetNamePlateForUnit(arg1)
		if plate then
			ScanPlate(plate, arg1)
		end

	elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		NoNameplateNumbersDB = NoNameplateNumbersDB or {}
		ns.db = NoNameplateNumbersDB
		for key, value in pairs(ns.defaults) do
			if ns.db[key] == nil then
				ns.db[key] = value
			end
		end
		if ns.InitOptions then
			ns.InitOptions()
		end

	elseif event == "PLAYER_LOGIN" then
		HookCooldownWidgets()
		ns.RefreshAll()
	end
end)

-- ---------------------------------------------------------------------------
-- Diagnostics - /nnn debug
-- ---------------------------------------------------------------------------

local function Say(text)
	print("|cff33ff99" .. ns.TITLE .. "|r " .. text)
end
ns.Say = Say

local function NameOf(obj)
	if obj.GetDebugName then
		local ok, name = pcall(obj.GetDebugName, obj)
		if ok and name and name ~= "" then return name end
	end
	local ok, name = pcall(obj.GetName, obj)
	if ok and name then return name end
	return "<unnamed>"
end

-- Everything the walk finds under a nameplate, for the report.
local function Survey(frame, depth, found)
	for _, region in ipairs(Regions(frame)) do
		if Forbidden(region) then
			found.forbidden = found.forbidden + 1
		elseif ObjectType(region) == "FontString" then
			local ok, text = pcall(region.GetText, region)
			if ok and text and text ~= "" then
				found.texts[#found.texts + 1] = {
					text = text,
					name = NameOf(region),
					shown = select(2, pcall(region.IsShown, region)) == true,
					mine = hiddenText[region] ~= nil,
				}
			end
		end
	end

	for _, child in ipairs(Children(frame)) do
		if Forbidden(child) then
			found.forbidden = found.forbidden + 1
		else
			if ObjectType(child) == "Cooldown" then
				found.cooldowns[#found.cooldowns + 1] = child
			end
			if depth < 8 then
				Survey(child, depth + 1, found)
			end
		end
	end
	return found
end

function ns.Debug()
	local db = ns.db
	Say(("debug: enabled=%s enemy=%s friendly=%s personal=%s thirdParty=%s forceHideText=%s")
		:format(tostring(db.enabled), tostring(db.enemy), tostring(db.friendly),
			tostring(db.personal), tostring(db.suppressThirdParty), tostring(db.forceHideText)))
	Say("cooldown hook: " .. (ns.hooked and "installed" or "FAILED - please report this"))

	local loaded = {}
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if isLoaded then
		for _, name in ipairs({ "OmniCC", "ElvUI", "Plater", "KuiNameplates", "TidyPlates", "ThreatPlates" }) do
			local ok, res = pcall(isLoaded, name)
			if ok and res then loaded[#loaded + 1] = name end
		end
	end
	Say("other addons: " .. (#loaded > 0 and table.concat(loaded, ", ") or "none of the usual ones"))

	local plate = GetNamePlateForUnit and GetNamePlateForUnit("target")
	if not plate then
		Say("no nameplate for your target - target something with auras and try again")
		return
	end

	local unit = UnitOf(plate)
	Say(("target plate: %s unit=%s friend=%s -> should hide = %s"):format(
		NameOf(plate), tostring(unit), tostring(unit and UnitIsFriend("player", unit)),
		tostring(ShouldHide(unit))))

	local ok, found = pcall(Survey, plate, 0, { texts = {}, cooldowns = {}, forbidden = 0 })
	if not ok then
		Say("scan failed: " .. tostring(found))
		return
	end

	Say(("found on that plate: %d cooldowns, %d font strings with text, %d forbidden frames skipped")
		:format(#found.cooldowns, #found.texts, found.forbidden))

	for i, cd in ipairs(found.cooldowns) do
		if i > 6 then break end
		local start, duration = cd:GetCooldownTimes()
		Say(("  cooldown %s tracked=%s hidden=%s noCooldownCount=%s running=%s"):format(
			NameOf(cd), tostring(tracked[cd] ~= nil and tracked[cd] ~= false),
			tostring(cd.nnnHidden), tostring(cd.noCooldownCount),
			(duration and duration > 0) and ("%.1fs"):format(duration / 1000) or "no"))
	end

	for i, entry in ipairs(found.texts) do
		if i > 14 then
			Say(("  ... and %d more font strings"):format(#found.texts - 14))
			break
		end
		Say(("  text %q shown=%s hiddenByUs=%s on %s"):format(
			entry.text, tostring(entry.shown), tostring(entry.mine), entry.name))
	end
end
