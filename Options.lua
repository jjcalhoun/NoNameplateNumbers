-- NoNameplateNumbers - options panel

local ADDON_NAME, ns = ...

local panel, checkboxes

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local function SetTooltip(widget, title, text)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		GameTooltip:AddLine(text, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateCheckbox(key, label, tooltip, indented, anchorTo, gap)
	local check = CreateFrame("CheckButton", "NoNameplateNumbers_" .. key, panel, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	check:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", indented and 16 or 0, -(gap or 8))

	local text = check.Text or check.text or _G[check:GetName() .. "Text"]
	text:SetFontObject("GameFontHighlight")
	text:SetText(label)

	check.key = key
	check.indented = indented
	check:SetScript("OnClick", function(self)
		ns.db[self.key] = self:GetChecked() and true or false
		ns.RefreshAll()
		ns.UpdateOptions()
	end)
	SetTooltip(check, label, tooltip)

	checkboxes[#checkboxes + 1] = check
	return check
end

local function CreateHeader(label, anchorTo, gap)
	local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -(gap or 18))
	header:SetText(label)

	local line = panel:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(0.6, 0.6, 0.6, 0.4)
	line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	line:SetSize(420, 1)

	return header
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

function ns.UpdateOptions()
	if not checkboxes then return end
	local db = ns.db
	for _, check in ipairs(checkboxes) do
		check:SetChecked(db[check.key] and true or false)

		-- Everything below the master switch is dead while it is off.
		local usable = db.enabled or check.key == "enabled"
		check:SetEnabled(usable)
		local text = check.Text or check.text or _G[check:GetName() .. "Text"]
		text:SetFontObject(usable and "GameFontHighlight" or "GameFontDisable")
	end
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function BuildPanel()
	panel = CreateFrame("Frame")
	panel.name = ns.TITLE
	checkboxes = {}

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(ns.TITLE)

	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	subtitle:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
	subtitle:SetJustifyH("LEFT")
	subtitle:SetJustifyV("TOP")
	subtitle:SetText("Hides the countdown numbers on auras shown by the default nameplates. Cooldown numbers everywhere else in the game are left exactly as they are.")

	local master = CreateCheckbox(
		"enabled",
		"Hide cooldown numbers on nameplate auras",
		"Master switch. When unchecked the addon does nothing at all and nameplate auras get their numbers back.",
		false, subtitle, 16
	)

	local whereHeader = CreateHeader("Apply to", master, 18)

	local enemy = CreateCheckbox(
		"enemy",
		"Enemy nameplates",
		"Auras on hostile and neutral nameplates.",
		true, whereHeader, 10
	)
	local friendly = CreateCheckbox(
		"friendly",
		"Friendly nameplates",
		"Auras on friendly nameplates.",
		true, enemy, 4
	)
	local personal = CreateCheckbox(
		"personal",
		"Personal resource display",
		"Auras on your own nameplate under your character.",
		true, friendly, 4
	)

	local extrasHeader = CreateHeader("Extras", personal, 18)

	local thirdParty = CreateCheckbox(
		"suppressThirdParty",
		"Also suppress timer addons (OmniCC, ElvUI, ...)",
		"Marks nameplate aura cooldowns as opted out of third party cooldown text. Timer addons that honour the standard flag will skip them too, everywhere else they keep working.",
		true, extrasHeader, 10
	)
	local forceText = CreateCheckbox(
		"forceHideText",
		"Also hide timer text drawn as plain text",
		"Some patches and some timer addons draw the aura duration as ordinary text rather than as the cooldown's own countdown. This hides that too. Only text on a nameplate aura icon is touched, and stack counts are left alone.",
		true, thirdParty, 4
	)
	local swipe = CreateCheckbox(
		"hideSwipe",
		"Also hide the cooldown swipe",
		"Removes the dark sweeping shade from nameplate aura icons as well, leaving a plain icon.",
		true, forceText, 4
	)

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(150, 22)
	reset:SetPoint("TOPLEFT", swipe, "BOTTOMLEFT", -16, -20)
	reset:SetText("Reset to defaults")
	reset:SetScript("OnClick", function()
		for key, value in pairs(ns.defaults) do
			ns.db[key] = value
		end
		ns.RefreshAll()
		ns.UpdateOptions()
	end)

	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -12)
	hint:SetText("Slash commands: /nnn, /nnn toggle, /nnn debug (prints what the addon sees on your target's nameplate)")

	panel:SetScript("OnShow", ns.UpdateOptions)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

local function RegisterPanel()
	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		ns.OpenOptions = function()
			Settings.OpenToCategory(category:GetID())
		end
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
		ns.OpenOptions = function()
			-- Twice on purpose: the old panel needs it to land on the right page.
			InterfaceOptionsFrame_OpenToCategory(panel)
			InterfaceOptionsFrame_OpenToCategory(panel)
		end
	else
		ns.OpenOptions = function()
			print("|cff33ff99" .. ns.TITLE .. "|r: no options panel available on this client.")
		end
	end
end

function ns.InitOptions()
	if panel then return end
	BuildPanel()
	RegisterPanel()
	ns.UpdateOptions()
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_NONAMEPLATENUMBERS1 = "/nnn"
SLASH_NONAMEPLATENUMBERS2 = "/nonameplatenumbers"
SlashCmdList.NONAMEPLATENUMBERS = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")

	if msg == "debug" then
		ns.Debug()
		return

	elseif msg == "toggle" or msg == "on" or msg == "off" then
		if msg == "toggle" then
			ns.db.enabled = not ns.db.enabled
		else
			ns.db.enabled = (msg == "on")
		end
		ns.RefreshAll()
		ns.UpdateOptions()
		print("|cff33ff99" .. ns.TITLE .. "|r: " ..
			(ns.db.enabled and "hiding cooldown numbers on nameplate auras." or "nameplate aura cooldown numbers restored."))
	else
		ns.OpenOptions()
	end
end
