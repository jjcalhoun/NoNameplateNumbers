-- NoNameplateNumbers
-- Hides the cooldown countdown text on auras shown by the default nameplates,
-- and leaves every other cooldown in the game untouched.
--
-- Nothing here depends on Blizzard's frame keys (UnitFrame.BuffFrame, .Cooldown
-- and friends), because those get renamed between expansions. Instead every
-- cooldown that starts anywhere in the game is checked once for a nameplate
-- ancestor, and only nameplate ones are ever touched.

local ADDON_NAME, ns = ...

local UnitIsUnit, UnitIsFriend = UnitIsUnit, UnitIsFriend
local GetNamePlates = C_NamePlate and C_NamePlate.GetNamePlates
local GetNamePlateForUnit = C_NamePlate and C_NamePlate.GetNamePlateForUnit
local ipairs, pairs, type = ipairs, pairs, type
local strsub, strmatch = string.sub, string.match

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "NoNameplateNumbers"

ns.defaults = {
	enabled = true,            -- master switch
	enemy = true,              -- auras on enemy nameplates
	friendly = true,           -- auras on friendly nameplates
	personal = true,           -- auras on the personal resource display
	suppressThirdParty = true, -- ask OmniCC / ElvUI style timers to stay off
	forceHideText = true,      -- hide leftover timer text drawn on the cooldown
	hideSwipe = false,         -- optionally hide the dark cooldown swipe as well
}

-- cooldowns we know belong to a nameplate: cooldown -> nameplate frame
local tracked = setmetatable({}, { __mode = "k" })
-- nameplate frame -> set of its cooldowns
local plateCooldowns = setmetatable({}, { __mode = "k" })
-- font strings we hid ourselves, so we only ever show those back
local hiddenText = setmetatable({}, { __mode = "k" })

local applying = false -- re-entrancy guard for our own widget calls

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

local function PlateOf(cd)
	local plate = tracked[cd]
	if plate ~= nil then
		return plate or nil
	end
	plate = FindNamePlate(cd)
	if plate then
		tracked[cd] = plate
		local set = plateCooldowns[plate]
		if not set then
			set = {}
			plateCooldowns[plate] = set
		end
		set[cd] = true
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
-- Applying
-- ---------------------------------------------------------------------------

-- Timer addons park their text either straight on the cooldown or in a small
-- child frame of it. Blizzard's own countdown is handled by
-- SetHideCountdownNumbers, this is only for what is left over.
local function SuppressText(frame, hide, depth)
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "FontString" then
			if hide then
				if region:IsShown() then
					region:Hide()
					hiddenText[region] = true
				end
			elseif hiddenText[region] then
				region:Show()
				hiddenText[region] = nil
			end
		end
	end

	if depth < 2 then
		for _, child in ipairs({ frame:GetChildren() }) do
			SuppressText(child, hide, depth + 1)
		end
	end
end

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
		local hideText = hide and db.forceHideText
		SuppressText(cd, hideText, 0)
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
	for _, child in ipairs({ frame:GetChildren() }) do
		if child.GetObjectType and child:GetObjectType() == "Cooldown" and child.SetHideCountdownNumbers then
			if tracked[child] ~= plate then
				tracked[child] = plate
				local set = plateCooldowns[plate]
				if not set then
					set = {}
					plateCooldowns[plate] = set
				end
				set[child] = true
			end
		elseif depth < 6 then
			Discover(plate, child, depth + 1)
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

local function NameOf(frame)
	if frame.GetDebugName then
		local ok, name = pcall(frame.GetDebugName, frame)
		if ok and name and name ~= "" then return name end
	end
	return (frame.GetName and frame:GetName()) or "<unnamed>"
end

local function DumpText(frame, plateName, depth, count)
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "FontString" and region:IsShown() then
			local text = region:GetText()
			if text and text ~= "" and strmatch(text, "%d") and count < 12 then
				count = count + 1
				Say(("  text %q on %s"):format(text, NameOf(region)))
			end
		end
	end
	if depth < 8 then
		for _, child in ipairs({ frame:GetChildren() }) do
			count = DumpText(child, plateName, depth + 1, count)
		end
	end
	return count
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

	local plates = GetNamePlates and GetNamePlates() or {}
	Say(("nameplates shown: %d"):format(#plates))

	local plate = GetNamePlateForUnit and GetNamePlateForUnit("target")
	if not plate then
		Say("no nameplate for your target - target something with auras and try again")
		return
	end

	local unit = UnitOf(plate)
	Say(("target plate: %s unit=%s friend=%s -> should hide = %s"):format(
		NameOf(plate), tostring(unit), tostring(unit and UnitIsFriend("player", unit)),
		tostring(ShouldHide(unit))))

	Discover(plate, plate, 0)
	local set, n = plateCooldowns[plate], 0
	if set then
		for cd in pairs(set) do
			n = n + 1
			if n <= 8 then
				local start, duration = cd:GetCooldownTimes()
				Say(("  cooldown %s hidden=%s noCooldownCount=%s running=%s"):format(
					NameOf(cd), tostring(cd.nnnHidden), tostring(cd.noCooldownCount),
					(duration and duration > 0) and ("%.1fs"):format(duration / 1000) or "no"))
			end
		end
	end
	Say(("  cooldowns found on that plate: %d"):format(n))
	Say("visible text on that plate:")
	DumpText(plate, NameOf(plate), 0, 0)
end
