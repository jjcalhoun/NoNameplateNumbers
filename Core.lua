-- NoNameplateNumbers
-- Hides the aura timer text on the default nameplates, and leaves cooldown
-- numbers everywhere else in the game untouched.
--
-- Three things shape how this works:
--
--  * Blizzard renames nameplate frame keys between expansions, so aura
--    cooldowns are found by walking down from the nameplate rather than by
--    looking for UnitFrame.BuffFrame and friends.
--  * Since 12.0 much of the aura data is a "secret value": addon code may hold
--    it but not read, compare or even type() it, and trying throws. So no value
--    that came out of a Blizzard frame is ever compared outside the pcall that
--    produced it, and nothing is left half-applied when one does throw.
--  * A new aura icon can appear with no event we are able to see, so the walk
--    has to be repeatable. It is written to allocate nothing, because a walk
--    that runs several times a second and allocates is how an addon this small
--    ends up at the top of the memory list.

local ADDON_NAME, ns = ...

local UnitIsUnit, UnitIsFriend = UnitIsUnit, UnitIsFriend
local GetNamePlates = C_NamePlate and C_NamePlate.GetNamePlates
local GetNamePlateForUnit = C_NamePlate and C_NamePlate.GetNamePlateForUnit
local ipairs, pairs, type, pcall, select = ipairs, pairs, type, pcall, select
local tostring = tostring
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

-- cooldowns we have classified: cooldown -> nameplate frame, or false
local tracked = setmetatable({}, { __mode = "k" })
-- nameplate frame -> set of its cooldowns
local plateCooldowns = setmetatable({}, { __mode = "k" })
-- cooldown -> the aura icon it sits on, learned on the way down
local iconOf = setmetatable({}, { __mode = "k" })
-- font strings we hid ourselves: region -> { alpha, shown }
local hiddenText = setmetatable({}, { __mode = "k" })
-- regions the client refuses to let us touch, so we stop asking
local refused = setmetatable({}, { __mode = "k" })

local WEAK_KEYS = { __mode = "k" }

local applying = false -- re-entrancy guard for our own widget calls
local dirty = false    -- something turned up that we should go and look for
local dirtyAll = false -- ...and we do not know which nameplate it was on

-- ---------------------------------------------------------------------------
-- Talking to frames without dying, and without allocating
--
-- Every comparison of a value that came out of a Blizzard frame happens inside
-- the pcall'd helper, never on the value it hands back: a secret value may be
-- held but not read, and type() of a secret is itself secret.
--
-- The list helpers fill a scratch table owned by the caller's depth instead of
-- building a new one, so a walk of every nameplate costs no garbage at all.
-- ---------------------------------------------------------------------------

local errorLog = {}
ns.errorLog = errorLog

local function Note(err)
	if #errorLog >= 5 then return end
	local ok, text = pcall(tostring, err)
	if not ok then text = "<unreadable error>" end
	for _, seen in ipairs(errorLog) do
		if seen == text then return end
	end
	errorLog[#errorLog + 1] = text
end

local function Try(fn, a, b, c, d)
	local ok, err = pcall(fn, a, b, c, d)
	if not ok then Note(err) end
	return ok
end
ns.Try = Try

local scratch = {}
local function Scratch(slot)
	local list = scratch[slot]
	if not list then
		list = {}
		scratch[slot] = list
	end
	return list
end

-- Entries past the returned count are stale, and never read. They only ever
-- hold frames, which live for the whole session anyway.
local function _gather(list, ...)
	local count = select("#", ...)
	for i = 1, count do
		list[i] = (select(i, ...))
	end
	return count
end

local function _childrenInto(frame, list) return _gather(list, frame:GetChildren()) end
local function ChildrenInto(frame, list)
	local ok, count = pcall(_childrenInto, frame, list)
	return ok and count or 0
end

local function _regionsInto(frame, list) return _gather(list, frame:GetRegions()) end
local function RegionsInto(frame, list)
	local ok, count = pcall(_regionsInto, frame, list)
	return ok and count or 0
end

local function _forbidden(obj) return (obj.IsForbidden and obj:IsForbidden()) == true end
local function Forbidden(obj)
	if not obj then return true end
	local ok, res = pcall(_forbidden, obj)
	return (not ok) or res == true
end

local function _isObjectType(obj, kind) return obj:GetObjectType() == kind end
local function IsObjectType(obj, kind)
	local ok, res = pcall(_isObjectType, obj, kind)
	return ok and res == true
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
		set = setmetatable({}, WEAK_KEYS)
		plateCooldowns[plate] = set
	end
	set[cd] = true
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
-- itself. On 12.x the duration is a font string inside the cooldown, and timer
-- addons that ignore noCooldownCount add their own. The text is never read - it
-- is secret, and reading it is not needed - so which font string is which is
-- decided from the key Blizzard stored it under.
-- ---------------------------------------------------------------------------

local function LooksLikeCount(key)
	key = strlower(key)
	return (strfind(key, "count", 1, true) or strfind(key, "stack", 1, true)
		or strfind(key, "charge", 1, true) or strfind(key, "application", 1, true)) ~= nil
end

local skipSet = {}
local function _collectCountKeys(icon, skip)
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
		-- No "is it already hidden?" question first: asking is a call that can
		-- throw, and throwing builds a string, while hiding something already
		-- hidden costs nothing. Alpha as well as Hide, so an OnUpdate that only
		-- calls SetText and Show cannot bring the text back.
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

-- A region that throws will throw every time, and every throw builds an error
-- string. Ask once, then leave it alone until the settings change.
local function HideRegion(region, hide)
	if refused[region] then return end
	if hide or hiddenText[region] then
		if not Try(_hideRegion, region, hide) then
			refused[region] = true
		end
	end
end

-- Font strings on the cooldown itself, and in any small child frame of it.
local function SuppressCooldownText(frame, hide, depth)
	local regions = Scratch(20 + depth)
	for i = 1, RegionsInto(frame, regions) do
		local region = regions[i]
		if not Forbidden(region) and IsObjectType(region, "FontString") then
			HideRegion(region, hide)
		end
	end

	if depth < 2 then
		local children = Scratch(30 + depth)
		for i = 1, ChildrenInto(frame, children) do
			local child = children[i]
			if not Forbidden(child) then
				SuppressCooldownText(child, hide, depth + 1)
			end
		end
	end
end

-- Font strings on the aura icon that owns the cooldown - the duration text -
-- while leaving the stack count alone.
local function SuppressIconText(icon, hide)
	for key in pairs(skipSet) do skipSet[key] = nil end
	pcall(_collectCountKeys, icon, skipSet)

	local regions = Scratch(40)
	for i = 1, RegionsInto(icon, regions) do
		local region = regions[i]
		if not skipSet[region] and not Forbidden(region) and IsObjectType(region, "FontString") then
			HideRegion(region, hide)
		end
	end

	-- Blizzard parks the stack count in its own child frame (CountFrame.Count),
	-- so a child frame stored under a count-ish key is skipped whole.
	local children = Scratch(41)
	local childCount = ChildrenInto(icon, children)
	for i = 1, childCount do
		local child = children[i]
		if not skipSet[child] and not Forbidden(child) then
			local childRegions = Scratch(42)
			for j = 1, RegionsInto(child, childRegions) do
				local region = childRegions[j]
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

-- GetParent is refused on some 12.x nameplate aura cooldowns, so the icon is
-- normally learned on the way down and only asked for as a last resort - once,
-- so a refusal is not repeated on every update.
local function IconOf(cd)
	local icon = iconOf[cd]
	if icon ~= nil then return icon or nil end

	local ok, parent = pcall(_parentOf, cd)
	iconOf[cd] = (ok and parent) or false
	return iconOf[cd] or nil
end

-- Blizzard can add its timer font string after the cooldown has already
-- started, so this cannot be a one-shot. It is cheap to repeat: a region we
-- have already hidden costs one IsShown call and nothing else.
local function ApplyText(cd, hideText)
	Try(SuppressCooldownText, cd, hideText, 0)
	local icon = IconOf(cd)
	if icon and not Forbidden(icon) then
		Try(SuppressIconText, icon, hideText)
	end
	cd.nnnTextHidden = hideText or nil
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

	ApplyText(cd, (hide and db.forceHideText) or false)

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

local function ApplyToPlate(plate, hide)
	local set = plateCooldowns[plate]
	if not set then return end
	for cd in pairs(set) do
		ApplyToCooldown(cd, hide)
	end
end

-- ---------------------------------------------------------------------------
-- Discovery
--
-- Walking down from the nameplate is the only thing that finds aura cooldowns
-- whose parent we are not allowed to ask about. On the way it notes the icon
-- each cooldown sits on, so GetParent is never needed afterwards.
-- ---------------------------------------------------------------------------

-- Cooldowns are dealt with as they are found, so a sweep that finds nothing
-- new does nothing at all.
local function Discover(plate, frame, depth, hide)
	local children = Scratch(depth)
	for i = 1, ChildrenInto(frame, children) do
		local child = children[i]
		if not Forbidden(child) then
			if IsObjectType(child, "Cooldown") then
				iconOf[child] = frame
				if tracked[child] ~= plate then
					Track(child, plate)
					ApplyToCooldown(child, hide)
				end
			elseif depth < 6 then
				Discover(plate, child, depth + 1, hide)
			end
		end
	end
end

local function RecheckText(plate, hide)
	local set = plateCooldowns[plate]
	local db = ns.db
	if not set or not db then return end
	local hideText = (hide and db.forceHideText) or false
	for cd in pairs(set) do
		ApplyText(cd, hideText)
	end
end

-- applyAll is for when the answer itself may have changed - a nameplate taken
-- over by a new unit, or a settings change - rather than just the frames.
local function ScanPlate(plate, unit, applyAll)
	local hide = ShouldHide(unit or UnitOf(plate))
	Try(Discover, plate, plate, 0, hide)
	if applyAll then
		ApplyToPlate(plate, hide)
	else
		RecheckText(plate, hide)
	end
end

-- Our own list of what is on screen. C_NamePlate.GetNamePlates builds a fresh
-- table on every call, which is not something to do a few times a second.
local activePlates = setmetatable({}, WEAK_KEYS)
-- nameplates something has just happened on
local dirtyPlates = setmetatable({}, WEAK_KEYS)

local function MarkDirty(plate)
	if plate then
		dirtyPlates[plate] = true
	else
		dirtyAll = true
	end
	dirty = true
end

local function ScanAll(applyAll)
	for plate, unit in pairs(activePlates) do
		ScanPlate(plate, unit, applyAll)
	end
end

function ns.RefreshAll()
	-- a settings change is worth re-trying anything that refused us before
	for region in pairs(refused) do
		refused[region] = nil
	end

	-- one allocating call, at login and when settings change
	if GetNamePlates then
		local ok, plates = pcall(GetNamePlates)
		if ok and plates then
			for _, plate in ipairs(plates) do
				if activePlates[plate] == nil then
					activePlates[plate] = UnitOf(plate) or false
				end
			end
		end
	end
	ScanAll(true)
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

-- Every cooldown in the game runs through these two widget methods. The first
-- call per cooldown decides whether it lives on a nameplate; after that it is a
-- single table lookup, so ordinary cooldowns cost next to nothing.
--
-- A cooldown we cannot trace up to its nameplate is not written off silently:
-- it means something new appeared somewhere, and the walk gets to look for it
-- on the very next frame.
local function Classify(cd)
	local plate = tracked[cd]
	if plate ~= nil then
		return plate or nil
	end

	plate = FindNamePlate(cd)
	if plate then
		Track(cd, plate)
	else
		-- Something new started somewhere and we could not trace it back to a
		-- nameplate. It may be an aura icon that has just been built, so every
		-- plate is worth another look - but only this once.
		tracked[cd] = false
		MarkDirty(nil)
	end
	return plate
end

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
		local plate = Classify(self)
		if plate then
			-- a cooldown starting is the one moment Blizzard may have put its
			-- own timer text back, so let the icon be looked at again
			self.nnnTextHidden = nil
			ApplyToCooldown(self, ShouldHide(UnitOf(plate)))
		end
	end)

	-- Blizzard turns the numbers back on for some aura frames after setting the
	-- cooldown, so put our answer back when that happens on a nameplate.
	if type(index.SetHideCountdownNumbers) == "function" then
		hooksecurefunc(index, "SetHideCountdownNumbers", function(self, value)
			if applying then return end
			-- Blizzard passes a secret boolean here for nameplate auras, and
			-- every attempt to read one throws - which builds an error string
			-- each time. The argument is simply never looked at: re-applying
			-- our own answer is cheaper than finding out we did not need to.
			local plate = Classify(self)
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
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
frame:RegisterEvent("UNIT_AURA")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "UNIT_AURA" then
		-- only the nameplate this happened on needs looking at
		if ns.db and IsNameplateUnit(arg1) then
			MarkDirty(GetNamePlateForUnit and GetNamePlateForUnit(arg1))
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" then
		local plate = GetNamePlateForUnit and GetNamePlateForUnit(arg1)
		if plate then
			activePlates[plate] = arg1
			-- the unit is new, so the answer may be too
			ScanPlate(plate, arg1, true)
			MarkDirty(plate)
		end

	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		local plate = GetNamePlateForUnit and GetNamePlateForUnit(arg1)
		if plate then
			activePlates[plate] = nil
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
-- Keeping up with new aura icons
--
-- An icon can appear with no event we can see, so there is a sweep - but it is
-- driven rather than polled. Anything that means "something new turned up"
-- (an aura change, a nameplate appearing, a cooldown we have never classified
-- starting anywhere in the UI) raises a flag, and the walk runs on the very
-- next frame instead of up to a second later. The timed sweep is only a
-- backstop for the case where none of those reach us, and the whole thing is
-- unhooked while the addon is not hiding anything.
-- ---------------------------------------------------------------------------

local BACKSTOP = 5    -- seconds, when nothing has announced itself
local MIN_GAP = 0.05  -- seconds, the most often a flag can start a scan

local since = 0

local function Sweep(self, elapsed)
	since = since + elapsed

	if dirty then
		-- Aura events can arrive many times a second in a fight; one scan per
		-- 20th of a second is still far faster than anyone can see.
		if since < MIN_GAP then return end
		since = 0

		if dirtyAll then
			ScanAll(false)
		else
			-- just the nameplates something happened on
			for plate in pairs(dirtyPlates) do
				if activePlates[plate] ~= nil then
					ScanPlate(plate, activePlates[plate], false)
				end
				dirtyPlates[plate] = nil
			end
		end

		dirty, dirtyAll = false, false
		for plate in pairs(dirtyPlates) do
			dirtyPlates[plate] = nil
		end
		return
	end

	if since < BACKSTOP then return end
	since = 0
	ScanAll(false)
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

-- Frame names are secret on 12.x nameplate aura frames, so the check for a
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

-- The report walks with its own tables: it runs once, by hand, and clarity
-- matters more than garbage there.
local function Survey(frame, depth, found)
	for _, region in ipairs({ frame:GetRegions() }) do
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

	for _, child in ipairs({ frame:GetChildren() }) do
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

	local trackedHere, trackedAll = 0, 0
	for cd, owner in pairs(tracked) do
		if owner then
			trackedAll = trackedAll + 1
			if owner == plate then trackedHere = trackedHere + 1 end
		end
	end
	local memory = 0
	if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
		pcall(UpdateAddOnMemoryUsage)
		local memOk, used = pcall(GetAddOnMemoryUsage, ADDON_NAME)
		if memOk and type(used) == "number" then memory = used end
	end
	Say(("sweep: %s, tracked here: %d, tracked everywhere: %d, memory: %.0f KB"):format(
		frame:GetScript("OnUpdate") and "running" or "OFF", trackedHere, trackedAll, memory))

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
