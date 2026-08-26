-- NoNameplateNumbers
-- Hides the aura timer text on the default nameplates, and leaves cooldown
-- numbers everywhere else in the game untouched.
--
-- Two things make this less straightforward than it sounds:
--
--  * Blizzard renames nameplate frame keys between expansions, so cooldowns are
--    found by asking every cooldown that starts whether it lives under a
--    nameplate, not by looking for UnitFrame.BuffFrame and friends.
--  * Since 12.0 a lot of aura data is a "secret value": addon code may hold it
--    but not read or compare it, and trying throws. So no value that came out
--    of a Blizzard frame is ever compared here without a pcall around it, and
--    nothing is left in a half-applied state when one does throw.

local ADDON_NAME, ns = ...

local UnitIsUnit, UnitIsFriend = UnitIsUnit, UnitIsFriend
local GetNamePlates = C_NamePlate and C_NamePlate.GetNamePlates
local GetNamePlateForUnit = C_NamePlate and C_NamePlate.GetNamePlateForUnit
local ipairs, pairs, type, pcall, tostring = ipairs, pairs, type, pcall, tostring
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
-- cooldown -> the aura icon it sits on, learned on the way down
local iconOf = setmetatable({}, { __mode = "k" })
-- nameplate frame -> the frames new aura icons appear in
local plateContainers = setmetatable({}, { __mode = "k" })
-- font strings we hid ourselves: region -> { alpha, shown }
local hiddenText = setmetatable({}, { __mode = "k" })

local applying = false -- re-entrancy guard for our own widget calls
local EMPTY = {}

-- ---------------------------------------------------------------------------
-- Talking to frames without dying
--
-- Nameplates can hold forbidden frames, and aura values can be secret. Either
-- one throws when touched, so everything that reaches into a Blizzard frame
-- goes through here.
-- ---------------------------------------------------------------------------

local errorLog = {}
ns.errorLog = errorLog

local function Note(err)
	local ok, text = pcall(tostring, err)
	if not ok then text = "<unreadable error>" end
	for _, seen in ipairs(errorLog) do
		if seen == text then return end
	end
	if #errorLog < 5 then
		errorLog[#errorLog + 1] = text
	end
end

-- pcall with the error remembered for /nnn debug
local function Try(fn, a, b, c)
	local ok, err = pcall(fn, a, b, c)
	if not ok then Note(err) end
	return ok
end
ns.Try = Try

-- Every comparison of a value that came out of a Blizzard frame happens inside
-- the pcall'd helper, never on the value it hands back. A secret value may be
-- held but not read, compared or tested, and type() of a secret is itself
-- secret, so touching one outside the pcall throws.
local function _forbidden(obj) return (obj.IsForbidden and obj:IsForbidden()) == true end
local function Forbidden(obj)
	if not obj then return true end
	local ok, res = pcall(_forbidden, obj)
	return (not ok) or res == true
end

local function _isTrue(value) return (value and true) or false end
-- true, false, or nil when the value cannot be read at all
local function IsTrue(value)
	local ok, res = pcall(_isTrue, value)
	if not ok then return nil end
	return res
end

local function _str(value)
	local text = tostring(value)
	if type(text) == "string" then return text end
	return nil
end
local function Str(value)
	local ok, text = pcall(_str, value)
	if ok and text then return text end
	return "<secret>"
end
ns.Str = Str

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

local function _isShown(obj) return obj:IsShown() == true end
local function Shown(obj)
	local ok, shown = pcall(_isShown, obj)
	return ok and shown == true
end

local function _alphaOf(region)
	local alpha = region:GetAlpha()
	if type(alpha) == "number" then return alpha end
	return nil
end
local function AlphaOf(region)
	local ok, alpha = pcall(_alphaOf, region)
	if ok and alpha then return alpha end
	return 1
end

local function _isObjectType(obj, kind) return obj:GetObjectType() == kind end
local function IsObjectType(obj, kind)
	local ok, res = pcall(_isObjectType, obj, kind)
	return ok and res == true
end

-- ---------------------------------------------------------------------------
-- Which nameplate does a cooldown belong to?
-- ---------------------------------------------------------------------------

local function _isNamePlate(frame)
	if frame.namePlateUnitToken ~= nil then return true end
	local name = frame.GetName and frame:GetName()
	return (name and strmatch(name, "^NamePlate%d+$")) ~= nil
end

local function _parentOf(frame)
	return frame.GetParent and frame:GetParent()
end

-- Checked one frame at a time: a frame whose name cannot be read must not end
-- the walk, or every cooldown below it is written off as "not a nameplate".
local function FindNamePlate(frame)
	local depth = 0
	while frame and depth < 12 do
		local ok, isPlate = pcall(_isNamePlate, frame)
		if ok and isPlate == true then return frame end

		local climbed, parent = pcall(_parentOf, frame)
		if not climbed then return nil end
		frame = parent
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

local function _unitOf(plate)
	return plate.namePlateUnitToken
		or (plate.UnitFrame and (plate.UnitFrame.unit or plate.UnitFrame.displayedUnit))
end

local function UnitOf(plate)
	local ok, unit = pcall(_unitOf, plate)
	return ok and unit or nil
end

local function _shouldHide(unit)
	local db = ns.db
	if not db or not db.enabled then return false end
	if unit then
		if UnitIsUnit(unit, "player") then return db.personal end
		if UnitIsFriend("player", unit) then return db.friendly end
	end
	return db.enemy
end

local function ShouldHide(unit)
	local ok, hide = pcall(_shouldHide, unit)
	if ok then return hide end
	-- Could not tell friend from foe: fall back to the enemy setting rather
	-- than quietly stopping.
	Note(hide)
	local db = ns.db
	return (db and db.enabled and db.enemy) or false
end

-- ---------------------------------------------------------------------------
-- Timer text drawn as a plain font string
--
-- SetHideCountdownNumbers only covers the countdown the cooldown widget draws
-- itself. Anything else - Blizzard drawing the duration as its own font string,
-- or a timer addon that ignores noCooldownCount - is a font string on the aura
-- icon or on the cooldown, and gets hidden here instead.
--
-- The text itself is never read: it is secret on modern clients, and reading it
-- is not needed. Which font string is which is decided from the key Blizzard
-- stored it under.
-- ---------------------------------------------------------------------------

local function LooksLikeCount(key)
	key = strlower(key)
	return (strfind(key, "count", 1, true) or strfind(key, "stack", 1, true)
		or strfind(key, "charge", 1, true) or strfind(key, "application", 1, true)) ~= nil
end

-- Regions the icon keeps under a stack-count style key, which must stay visible.
local function _collectCountRegions(icon, skip)
	for key, value in pairs(icon) do
		if type(key) == "string" and LooksLikeCount(key) then
			skip[value] = true
		end
	end
end

local function _hideRegion(region, hide)
	if hide then
		if not hiddenText[region] then
			-- keep only plain values: a secret alpha would make restoring throw
			hiddenText[region] = { alpha = AlphaOf(region), shown = Shown(region) }
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

local function HideRegion(region, hide)
	if hide or hiddenText[region] then
		Try(_hideRegion, region, hide)
	end
end

-- Font strings on the cooldown itself, and in any small child frame of it.
local function SuppressCooldownText(frame, hide, depth)
	for _, region in ipairs(Regions(frame)) do
		if not Forbidden(region) and IsObjectType(region, "FontString") then
			HideRegion(region, hide)
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
	local skip = {}
	pcall(_collectCountRegions, icon, skip)

	for _, region in ipairs(Regions(icon)) do
		if not skip[region] and not Forbidden(region) and IsObjectType(region, "FontString") then
			HideRegion(region, hide)
		end
	end

	-- Blizzard parks the stack count in its own child frame (CountFrame.Count),
	-- so a child frame stored under a count-ish key is skipped whole.
	for _, child in ipairs(Children(icon)) do
		if not skip[child] and not Forbidden(child) then
			for _, region in ipairs(Regions(child)) do
				if IsObjectType(region, "FontString") then
					HideRegion(region, hide)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------------

-- GetParent is forbidden on 12.x nameplate aura cooldowns, so the icon is
-- normally learned on the way down and only asked for as a last resort - once,
-- so a refusal is not repeated on every update.
local function IconOf(cd)
	local icon = iconOf[cd]
	if icon ~= nil then return icon or nil end

	local ok, parent = pcall(_parentOf, cd)
	iconOf[cd] = (ok and parent) or false
	return iconOf[cd] or nil
end

local function _setHideNumbers(cd, hide) cd:SetHideCountdownNumbers(hide) end
local function _setDrawSwipe(cd, draw) cd:SetDrawSwipe(draw) end

-- Timer addons only re-read noCooldownCount when a cooldown starts, so restart
-- the running one to make a settings change visible immediately. The times can
-- be secret, in which case this simply does not happen.
local function _restart(cd)
	local start, duration = cd:GetCooldownTimes()
	if start and duration and duration > 0 then
		cd:SetCooldown(start / 1000, duration / 1000)
	end
end

local function DoApply(cd, hide)
	local db = ns.db

	if cd.nnnHidden ~= hide then
		if Try(_setHideNumbers, cd, hide) then
			cd.nnnHidden = hide
		end
	end

	-- The flag OmniCC, ElvUI and most other timer addons honour.
	local optOut = (hide and db.suppressThirdParty) or nil
	if cd.noCooldownCount ~= optOut then
		cd.noCooldownCount = optOut
		Try(_restart, cd)
	end

	if db.forceHideText or cd.nnnTextHidden then
		local hideText = (hide and db.forceHideText) or false
		Try(SuppressCooldownText, cd, hideText, 0)
		local icon = IconOf(cd)
		if icon and not Forbidden(icon) then
			Try(SuppressIconText, icon, hideText)
		end
		cd.nnnTextHidden = hideText or nil
	end

	local drawSwipe = not (hide and db.hideSwipe)
	if cd.nnnSwipe ~= drawSwipe then
		if Try(_setDrawSwipe, cd, drawSwipe) then
			cd.nnnSwipe = drawSwipe
		end
	end
end

-- Whatever happens in there, the guard has to come back down: leaving it up
-- would silently switch the whole addon off for the rest of the session.
local function ApplyToCooldown(cd, hide)
	if applying then return end
	applying = true
	local ok, err = pcall(DoApply, cd, hide)
	applying = false
	if not ok then Note(err) end
end

local function ApplyToPlate(plate, unit)
	local set = plateCooldowns[plate]
	if not set then return end
	local hide = ShouldHide(unit or UnitOf(plate))
	for cd in pairs(set) do
		ApplyToCooldown(cd, hide)
	end
end

-- Walking down from the nameplate is the only discovery that works for aura
-- cooldowns whose parent we are not allowed to ask about. On the way it notes
-- the icon each cooldown sits on, and the frame that icon lives in, so new
-- auras can be picked up later without walking the whole plate again.
local function Discover(plate, frame, depth, parent)
	for _, child in ipairs(Children(frame)) do
		if not Forbidden(child) then
			if IsObjectType(child, "Cooldown") then
				if tracked[child] ~= plate then
					Track(child, plate)
				end
				iconOf[child] = frame
				if parent then
					local containers = plateContainers[plate]
					if not containers then
						containers = setmetatable({}, { __mode = "k" })
						plateContainers[plate] = containers
					end
					containers[parent] = true
				end
			elseif depth < 6 then
				Discover(plate, child, depth + 1, frame)
			end
		end
	end
end

local function ScanPlate(plate, unit)
	Try(Discover, plate, plate, 0, nil)
	ApplyToPlate(plate, unit)
end

-- The cheap version: only the frames aura icons are known to appear in.
local function ReScan(plate, unit, allowFull)
	local containers = plateContainers[plate]
	if not containers or not next(containers) then
		if allowFull == false then return end
		return ScanPlate(plate, unit)
	end
	for container in pairs(containers) do
		Try(Discover, plate, container, 4, nil)
	end
	ApplyToPlate(plate, unit)
end

function ns.RefreshAll()
	if GetNamePlates then
		local ok, plates = pcall(GetNamePlates)
		if ok and plates then
			for _, plate in ipairs(plates) do
				ScanPlate(plate)
			end
		end
	end
	-- also cover plates that are no longer shown but keep their cooldowns
	for cd, plate in pairs(tracked) do
		if plate then
			ApplyToCooldown(cd, ShouldHide(UnitOf(plate)))
		end
	end

	if ns.UpdateSweep then ns.UpdateSweep() end
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
			if applying then return end
			-- Blizzard passes a secret boolean here for nameplate auras, so the
			-- argument can only be inspected through IsTrue. When it cannot be
			-- read at all, re-apply: asking for hidden twice costs nothing.
			if IsTrue(value) == true then return end
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

local function _isNameplateUnit(unit)
	return type(unit) == "string" and strsub(unit, 1, 9) == "nameplate"
end
local function IsNameplateUnit(unit)
	local ok, res = pcall(_isNameplateUnit, unit)
	return ok and res == true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("UNIT_AURA")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "UNIT_AURA" then
		if ns.db and IsNameplateUnit(arg1) then
			local plate = GetNamePlateForUnit and GetNamePlateForUnit(arg1)
			if plate then
				ReScan(plate, arg1)
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
-- Safety net
--
-- An aura icon can appear without any event we are able to see, so the frames
-- aura icons are known to live in get re-checked a few times a second. That is
-- a couple of table lookups per nameplate, not a walk of the whole plate, and
-- the whole thing is switched off while the addon is not hiding anything.
-- ---------------------------------------------------------------------------

local SWEEP_INTERVAL = 0.25
local FULL_EVERY = 4 -- ticks, so a plate we know nothing about is walked once a second

local sinceSweep, tick = 0, 0

local function Sweep(self, elapsed)
	sinceSweep = sinceSweep + elapsed
	if sinceSweep < SWEEP_INTERVAL then return end
	sinceSweep = 0

	tick = tick + 1
	local allowFull = (tick % FULL_EVERY) == 0

	if not GetNamePlates then return end
	local ok, plates = pcall(GetNamePlates)
	if not ok or not plates then return end

	for _, plate in ipairs(plates) do
		ReScan(plate, nil, allowFull)
	end
end

function ns.UpdateSweep()
	if ns.db and ns.db.enabled then
		frame:SetScript("OnUpdate", Sweep)
	else
		frame:SetScript("OnUpdate", nil)
	end
end

-- ---------------------------------------------------------------------------
-- Diagnostics - /nnn debug
-- ---------------------------------------------------------------------------

local function Say(text)
	print("|cff33ff99" .. ns.TITLE .. "|r " .. text)
end
ns.Say = Say

-- Frame names are secret too on 12.x nameplate aura frames, so the check for a
-- usable name happens inside the pcall.
local function _usableName(name)
	if type(name) == "string" and name ~= "" then return name end
	return nil
end
local function _debugName(obj)
	return _usableName(obj.GetDebugName and obj:GetDebugName())
end
local function _plainName(obj)
	return _usableName(obj.GetName and obj:GetName())
end

local function NameOf(obj)
	local ok, name = pcall(_debugName, obj)
	if ok and name then return name end
	local secret = not ok

	local plainOk, plain = pcall(_plainName, obj)
	if plainOk and plain then return plain end

	return (secret or not plainOk) and "<secret name>" or "<unnamed>"
end

-- Aura text is secret on modern clients: it can be held but not read or
-- compared. Report what we can without ever looking at the value.
local function _describeText(value)
	if value == nil then return "<none>" end
	if value == "" then return "<empty>" end
	return "\"" .. value .. "\""
end

local function TextOf(region)
	local ok, value = pcall(region.GetText, region)
	if not ok then return "<unreadable>" end
	local described, text = pcall(_describeText, value)
	if not described then return "<secret>" end
	return text
end

-- Everything the walk finds under a nameplate, for the report.
local function Survey(frame, depth, found)
	for _, region in ipairs(Regions(frame)) do
		if Forbidden(region) then
			found.forbidden = found.forbidden + 1
		elseif IsObjectType(region, "FontString") then
			found.texts[#found.texts + 1] = {
				text = TextOf(region),
				name = NameOf(region),
				shown = Shown(region),
				mine = hiddenText[region] ~= nil,
			}
		end
	end

	for _, child in ipairs(Children(frame)) do
		if Forbidden(child) then
			found.forbidden = found.forbidden + 1
		else
			if IsObjectType(child, "Cooldown") then
				found.cooldowns[#found.cooldowns + 1] = child
			end
			if depth < 8 then
				Survey(child, depth + 1, found)
			end
		end
	end
	return found
end

local function _runningFor(cd)
	local _, duration = cd:GetCooldownTimes()
	if duration and duration > 0 then
		return ("%.1fs"):format(duration / 1000)
	end
	return "no"
end

local function RunningFor(cd)
	local ok, text = pcall(_runningFor, cd)
	return ok and text or "<secret>"
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
	local friendOk, friend = pcall(UnitIsFriend, "player", unit)
	Say(("target plate: %s unit=%s friend=%s -> should hide = %s"):format(
		NameOf(plate), Str(unit), friendOk and Str(friend) or "<secret>",
		tostring(ShouldHide(unit))))

	local ok, found = pcall(Survey, plate, 0, { texts = {}, cooldowns = {}, forbidden = 0 })
	if not ok then
		Say("scan failed: " .. Str(found))
		return
	end

	Say(("found on that plate: %d cooldowns, %d font strings, %d forbidden frames skipped")
		:format(#found.cooldowns, #found.texts, found.forbidden))

	for i, cd in ipairs(found.cooldowns) do
		if i > 6 then break end
		Say(("  cooldown %s tracked=%s icon=%s hidden=%s noCooldownCount=%s running=%s"):format(
			NameOf(cd), tostring(tracked[cd] ~= nil and tracked[cd] ~= false),
			tostring(iconOf[cd] ~= nil and iconOf[cd] ~= false),
			tostring(cd.nnnHidden), tostring(cd.noCooldownCount), RunningFor(cd)))
	end

	for i, entry in ipairs(found.texts) do
		if i > 14 then
			Say(("  ... and %d more font strings"):format(#found.texts - 14))
			break
		end
		Say(("  text %s shown=%s hiddenByUs=%s on %s"):format(
			entry.text, tostring(entry.shown), tostring(entry.mine), entry.name))
	end

	if #errorLog > 0 then
		Say("errors seen so far:")
		for _, err in ipairs(errorLog) do
			Say("  " .. err)
		end
	end
end
