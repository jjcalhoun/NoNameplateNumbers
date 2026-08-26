-- NoNameplateNumbers
-- Hides the cooldown countdown text on auras shown by the default nameplates,
-- and leaves every other cooldown in the game untouched.

local ADDON_NAME, ns = ...

local UnitIsUnit, UnitIsFriend = UnitIsUnit, UnitIsFriend
local GetNamePlates = C_NamePlate and C_NamePlate.GetNamePlates
local GetNamePlateForUnit = C_NamePlate and C_NamePlate.GetNamePlateForUnit
local ipairs, pairs, strsub = ipairs, pairs, string.sub

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "NoNameplateNumbers"

ns.defaults = {
	enabled = true,          -- master switch
	enemy = true,            -- auras on enemy nameplates
	friendly = true,         -- auras on friendly nameplates
	personal = true,         -- auras on the personal resource display
	suppressThirdParty = true, -- also ask OmniCC / ElvUI style timers to stay off
	hideSwipe = false,       -- optionally hide the dark cooldown swipe as well
}

-- ---------------------------------------------------------------------------
-- Cooldown handling
-- ---------------------------------------------------------------------------

-- Aura buttons keep the same cooldown widget for their whole life, so the
-- lookup is done once per button and cached on it.
local function FindCooldown(button)
	local cd = button.nnnCooldown
	if cd ~= nil then
		return cd or nil
	end

	cd = button.Cooldown or button.cooldown
	if not cd or not cd.SetHideCountdownNumbers then
		cd = nil
		if button.GetChildren then
			for _, child in ipairs({ button:GetChildren() }) do
				if child.GetObjectType and child:GetObjectType() == "Cooldown" then
					cd = child
					break
				end
			end
		end
	end

	button.nnnCooldown = cd or false
	return cd
end

local function ApplyToCooldown(cd, hide)
	local db = ns.db

	if cd.nnnHidden ~= hide then
		cd:SetHideCountdownNumbers(hide)
		cd.nnnHidden = hide
	end

	-- The flag OmniCC, ElvUI and most other timer addons honour.
	local optOut = (hide and db.suppressThirdParty) or nil
	if cd.noCooldownCount ~= optOut then
		cd.noCooldownCount = optOut
		-- Third party timers only re-read the flag when a cooldown starts, so
		-- restart the running one to make the change visible immediately.
		if cd.GetCooldownTimes then
			local start, duration = cd:GetCooldownTimes()
			if start and duration and duration > 0 then
				cd:SetCooldown(start / 1000, duration / 1000)
			end
		end
	end

	local drawSwipe = not (hide and db.hideSwipe)
	if cd.nnnSwipe ~= drawSwipe then
		cd:SetDrawSwipe(drawSwipe)
		cd.nnnSwipe = drawSwipe
	end
end

-- ---------------------------------------------------------------------------
-- Nameplates
-- ---------------------------------------------------------------------------

local function AuraContainer(namePlate)
	local unitFrame = namePlate.UnitFrame
	if not unitFrame then return nil end
	return unitFrame.BuffFrame or unitFrame.buffFrame
end

local function ShouldHide(unit)
	local db = ns.db
	if not db.enabled then return false end
	if unit then
		if UnitIsUnit(unit, "player") then return db.personal end
		if UnitIsFriend("player", unit) then return db.friendly end
	end
	return db.enemy
end

local function ApplyToNamePlate(namePlate, unit)
	local container = AuraContainer(namePlate)
	if not container then return end

	local hide = ShouldHide(unit or namePlate.namePlateUnitToken)
	for _, button in ipairs({ container:GetChildren() }) do
		local cd = FindCooldown(button)
		if cd then
			ApplyToCooldown(cd, hide)
		end
	end
end
ns.ApplyToNamePlate = ApplyToNamePlate

local function ApplyToUnit(unit)
	local namePlate = GetNamePlateForUnit and GetNamePlateForUnit(unit)
	if namePlate then
		ApplyToNamePlate(namePlate, unit)
	end
end

-- Used by the options panel after any setting changes.
function ns.RefreshAll()
	if not GetNamePlates then return end
	for _, namePlate in ipairs(GetNamePlates()) do
		ApplyToNamePlate(namePlate)
	end
end

-- New aura buttons are pulled from a pool as auras come and go, so re-apply
-- right after the container has finished laying its buttons out.
local function HookNamePlate(namePlate)
	local container = AuraContainer(namePlate)
	if not container or container.nnnHooked then return end
	container.nnnHooked = true

	if type(container.UpdateBuffs) == "function" then
		hooksecurefunc(container, "UpdateBuffs", function(self, unit)
			ApplyToNamePlate(namePlate, unit or namePlate.namePlateUnitToken)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("NAME_PLATE_CREATED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("UNIT_AURA")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "UNIT_AURA" then
		-- Cheapest possible early out: everything that is not a nameplate unit
		-- is none of our business.
		if ns.db and ns.db.enabled and strsub(arg1, 1, 9) == "nameplate" then
			ApplyToUnit(arg1)
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" then
		ApplyToUnit(arg1)

	elseif event == "NAME_PLATE_CREATED" then
		HookNamePlate(arg1)

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
		-- Nameplates created before we loaded still need their hook.
		if GetNamePlates then
			for _, namePlate in ipairs(GetNamePlates()) do
				HookNamePlate(namePlate)
			end
		end
		ns.RefreshAll()
	end
end)
