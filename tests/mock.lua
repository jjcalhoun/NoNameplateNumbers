-- Test harness for NoNameplateNumbers.
--
-- Runs Core.lua and Options.lua against a mock of the WoW API: frames,
-- cooldown widgets, regions, events, forbidden frames and secret values.
-- The nameplate shapes here are modelled on real /nnn debug dumps.
--
-- Run it from the addon folder with any Lua 5.1+ interpreter:
--     lua tests/mock.lua        (it loads Core.lua/Options.lua from the cwd)
--
-- Minimal WoW API mock to smoke test NoNameplateNumbers
local W = {}
W.__index = W
ALL_FRAMES = {}
local function New(objType, name, parent, template)
  local w = setmetatable({ objType = objType, name_ = name, parent = parent,
    children = {}, regions = {}, scripts = {}, events = {}, shown = true }, W)
  if parent and parent.children then table.insert(parent.children, w) end
  if template and template:find("UICheckButtonTemplate") then w.Text = New("FontString") end
  ALL_FRAMES[#ALL_FRAMES + 1] = w
  return w
end
function W:SetPoint() end
function W:SetSize() end
function W:SetText(t) self.text_ = t end
function W:GetText() return self.text_ end
function W:SetJustifyH() end
function W:SetJustifyV() end
function W:SetFontObject(f) self.font_ = f end
function W:SetColorTexture() end
function W:SetScript(k, fn) self.scripts[k] = fn end
function W:GetScript(k) return self.scripts[k] end
function W:RegisterEvent(e) self.events[e] = true end
function W:GetName() return self.name_ end
function W:GetParent() return self.parent end
function W:GetObjectType() return self.objType end
function W:CreateFontString(_, _, _)
  local fs = New("FontString", nil, nil); table.insert(self.regions, fs); return fs
end
function W:CreateTexture()
  local t = New("Texture", nil, nil); table.insert(self.regions, t); return t
end
function W:GetChildren() return table.unpack(self.children) end
function W:GetRegions() return table.unpack(self.regions) end
function W:SetChecked(v) self.checked = v end
function W:GetChecked() return self.checked end
function W:SetEnabled(v) self.enabled_ = v end
function W:IsShown() return self.shown end
function W:GetAlpha() return self.alpha or 1 end
function W:SetAlpha(a) self.alpha = a end
function W:Show() self.shown = true end
function W:Hide() self.shown = false end
function W:SetOwner() end
function W:AddLine() end
function W:SetHideCountdownNumbers(v) self.hideNumbers = v end
function W:SetDrawSwipe(v) self.drawSwipe = v end
function W:GetCooldownTimes() return self.cdStart or 0, self.cdDuration or 0 end
function W:SetCooldown(s, d)
  self.cdStart = s * 1000; self.cdDuration = d * 1000
  self.setCooldownCalls = (self.setCooldownCalls or 0) + 1
end

function CreateFrame(t, name, parent, template) return New(t, name, parent, template) end
function hooksecurefunc(tbl, name, post)
  if type(tbl) == "string" then tbl, name, post = _G, tbl, name end
  local orig = tbl[name]
  tbl[name] = function(...) local r = orig(...) post(...) return r end
end
UIParent = New("Frame", "UIParent")
GameTooltip = New("GameTooltip")
InterfaceOptions_AddCategory = function() end
InterfaceOptionsFrame_OpenToCategory = function() end
SlashCmdList = {}
C_AddOns = { IsAddOnLoaded = function(n) return n == "OmniCC" end }

local unitFriendly, plates, plateCount = {}, {}, 0
UnitIsUnit = function(a, b) return (plates[a] and plates[a].isPlayer and b == "player") or false end
UnitIsFriend = function(_, unit) return unitFriendly[unit] end
UnitExists = function() return true end
C_NamePlate = {
  GetNamePlates = function() local t = {} for _, p in pairs(plates) do t[#t + 1] = p end return t end,
  GetNamePlateForUnit = function(u) return plates[u] end,
}

-- A nameplate whose frame keys deliberately do NOT match Blizzard's, to prove
-- the addon no longer depends on them.
local FORBIDDEN = {}
FORBIDDEN.__index = function(_, k)
  if k == "IsForbidden" then return function() return true end end
  error("Attempt to access forbidden object from code tainted by an AddOn")
end
local function NewForbidden(parent)
  local f = setmetatable({}, FORBIDDEN)
  table.insert(parent.children, f)
  return f
end

local function NewAuraButton(container, dormant)
  local b = New("Frame", nil, container)
  b.WhateverIcon = New("Texture", nil, nil)
  local cd = New("Cooldown", nil, b)
  if not dormant then cd:SetCooldown(100, 12) end
  b.SomeOtherKeyForCooldown = cd
  -- Blizzard style duration text drawn as a plain font string, plus a stack count
  b.Duration = b:CreateFontString(); b.Duration:SetText("10")
  b.Count = b:CreateFontString(); b.Count:SetText("3")
  return b
end
local function NewNamePlate(unit, friendly, isPlayer, auras)
  plateCount = plateCount + 1
  local p = New("Frame", "NamePlate" .. plateCount)
  p.namePlateUnitToken = unit
  p.isPlayer = isPlayer
  local uf = New("Frame", nil, p)
  p.UnitFrame = uf
  local wrapper = New("Frame", nil, uf)          -- extra nesting level
  local container = New("Frame", nil, wrapper)
  p.auraContainer = container
  NewForbidden(container)  -- nameplates can hold frames we must not touch
  for _ = 1, (auras or 2) do NewAuraButton(container) end
  plates[unit] = p
  unitFriendly[unit] = friendly
  return p
end

local ns = {}
for _, file in ipairs({ "Core.lua", "Options.lua" }) do
  assert(loadfile(file))("NoNameplateNumbers", ns)
end

local eventFrame
for _, f in ipairs(ALL_FRAMES) do if f.scripts.OnEvent then eventFrame = f end end
assert(eventFrame, "no event frame created")
local function fire(event, arg1) eventFrame.scripts.OnEvent(eventFrame, event, arg1) end

local ok = true
local function check(label, cond)
  print((cond and "  ok   " or "  FAIL ") .. label)
  if not cond then ok = false end
end
local function getKey(t, k) return t[k] end
local function cooldowns(plate)
  local t = {}
  for _, b in ipairs(plate.auraContainer.children) do
    local ok, cd = pcall(getKey, b, "SomeOtherKeyForCooldown")
    if ok and cd then t[#t + 1] = cd end
  end
  return t
end

fire("ADDON_LOADED", "NoNameplateNumbers")
check("db initialised with defaults", ns.db and ns.db.enabled == true and ns.db.forceHideText == true)
fire("PLAYER_LOGIN")
check("cooldown widget hook installed", ns.hooked == true)

local enemy = NewNamePlate("nameplate1", false, false, 2)
local friend = NewNamePlate("nameplate2", true, false, 2)
local me = NewNamePlate("nameplate3", true, true, 1)

fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
fire("NAME_PLATE_UNIT_ADDED", "nameplate3")

for _, cd in ipairs(cooldowns(enemy)) do check("enemy numbers hidden (unknown frame keys)", cd.hideNumbers == true) end
for _, cd in ipairs(cooldowns(friend)) do check("friendly numbers hidden", cd.hideNumbers == true) end
for _, cd in ipairs(cooldowns(me)) do check("personal numbers hidden", cd.hideNumbers == true) end
check("third party flag set", cooldowns(enemy)[1].noCooldownCount == true)

-- forbidden frames must be skipped, not fatal
check("forbidden frame did not break discovery", #enemy.auraContainer.children == 3)

-- plain font string duration text on the aura icon
local icon = enemy.auraContainer.children[2]
check("plain duration text hidden", icon.Duration.shown == false and icon.Duration.alpha == 0)
check("stack count left alone", icon.Count.shown == true)

-- a brand new aura with no events at all: the widget hook must catch it
local fresh = NewAuraButton(enemy.auraContainer, true)
check("fresh aura untouched before it starts", fresh.SomeOtherKeyForCooldown.hideNumbers == nil)
fresh.SomeOtherKeyForCooldown:SetCooldown(200, 8)
check("fresh aura hidden by the SetCooldown hook", fresh.SomeOtherKeyForCooldown.hideNumbers == true)

-- Blizzard turning numbers back on must be undone
local victim = cooldowns(enemy)[1]
victim:SetHideCountdownNumbers(false)
check("numbers put back on are re-hidden", victim.hideNumbers == true)

-- cooldowns outside nameplates must never be touched
local actionCD = New("Cooldown", nil, UIParent)
actionCD:SetCooldown(100, 30)
check("action bar cooldown untouched", actionCD.hideNumbers == nil and actionCD.noCooldownCount == nil)
local deep = New("Cooldown", nil, New("Frame", nil, New("Frame", "SomeAddonBar", UIParent)))
deep:SetCooldown(100, 30)
check("other addon's cooldown untouched", deep.hideNumbers == nil)

-- leftover timer text drawn on the cooldown by a timer addon
local omni = New("Frame", nil, victim)
local omniText = omni:CreateFontString()
omniText:SetText("10")
victim:SetCooldown(300, 10)
check("timer addon text hidden", omniText.shown == false)
ns.db.forceHideText = false
ns.RefreshAll()
check("timer addon text restored when option is off", omniText.shown == true)
ns.db.forceHideText = true
ns.RefreshAll()
check("timer addon text hidden again", omniText.shown == false)

-- secret values: anything the client refuses to hand over must not stop the
-- addon, and must not leave the re-entrancy guard stuck
local secretButton = NewAuraButton(enemy.auraContainer, true)
local secretCD = secretButton.SomeOtherKeyForCooldown
secretCD.GetCooldownTimes = function() error("attempt to compare a secret value") end
secretButton.Duration.GetText = function() error("attempt to compare a secret value") end
secretCD:SetCooldown(500, 9)
check("secret cooldown times did not stop the hide", secretCD.hideNumbers == true)
check("secret aura duration text still hidden", secretButton.Duration.shown == false)

local afterSecret = NewAuraButton(enemy.auraContainer, true)
afterSecret.SomeOtherKeyForCooldown:SetCooldown(600, 4)
check("addon still alive after a secret value error",
  afterSecret.SomeOtherKeyForCooldown.hideNumbers == true)

-- a font string that refuses to be hidden must not stop its siblings
local stubborn = NewAuraButton(enemy.auraContainer, true)
stubborn.Duration.Hide = function() error("action blocked") end
stubborn.Extra = stubborn:CreateFontString(); stubborn.Extra:SetText("7")
stubborn.SomeOtherKeyForCooldown:SetCooldown(700, 5)
check("sibling text still hidden when one throws", stubborn.Extra.shown == false)
check("cooldown still processed when a region throws",
  stubborn.SomeOtherKeyForCooldown.hideNumbers == true)

-- values the client refuses to hand over: names, alpha, shown state
local opaque = NewAuraButton(enemy.auraContainer, true)
local opaqueCD = opaque.SomeOtherKeyForCooldown
opaqueCD.GetDebugName = function() error("a secret string value") end
opaqueCD.GetName = function() error("a secret string value") end
opaque.Duration.GetAlpha = function() error("a secret number value") end
opaque.Duration.IsShown = function() error("a secret boolean value") end
opaqueCD:SetCooldown(800, 11)
check("secret name did not stop the hide", opaqueCD.hideNumbers == true)
check("secret alpha and shown state did not stop the hide", opaque.Duration.alpha == 0)

-- Blizzard turning numbers back on with a value we cannot read
local reapplied = NewAuraButton(enemy.auraContainer, true)
local reappliedCD = reapplied.SomeOtherKeyForCooldown
reappliedCD:SetCooldown(900, 7)
reappliedCD.hideNumbers = false
reappliedCD:SetHideCountdownNumbers(nil)  -- unreadable argument
check("unreadable hide argument makes us re-apply", reappliedCD.hideNumbers == true)

-- duration text comes back when the addon stops hiding it
ns.db.forceHideText = false
ns.RefreshAll()
check("duration text restored when option is off", icon.Duration.shown == true and icon.Duration.alpha == 1)
ns.db.forceHideText = true
ns.RefreshAll()
check("duration text hidden again", icon.Duration.shown == false)

-- per unit type
ns.db.friendly = false
ns.RefreshAll()
check("friendly off -> friendly restored", cooldowns(friend)[1].hideNumbers == false)
check("friendly off -> personal unaffected", cooldowns(me)[1].hideNumbers == true)
check("friendly off -> enemy still hidden", cooldowns(enemy)[1].hideNumbers == true)
ns.db.personal = false
ns.RefreshAll()
check("personal off -> personal restored", cooldowns(me)[1].hideNumbers == false)
ns.db.friendly, ns.db.personal = true, true

-- swipe extra
ns.db.hideSwipe = true
ns.RefreshAll()
check("swipe hidden when asked", cooldowns(enemy)[1].drawSwipe == false)
ns.db.hideSwipe = false
ns.RefreshAll()
check("swipe restored", cooldowns(enemy)[1].drawSwipe == true)

-- master switch
SlashCmdList.NONAMEPLATENUMBERS("off")
check("slash off disables", ns.db.enabled == false)
check("everything restored when disabled",
  cooldowns(enemy)[1].hideNumbers == false and omniText.shown == true
  and icon.Duration.shown == true and icon.Duration.alpha == 1)
cooldowns(enemy)[1]:SetCooldown(400, 6)
check("disabled addon leaves new cooldowns alone", cooldowns(enemy)[1].hideNumbers == false)
SlashCmdList.NONAMEPLATENUMBERS("on")
check("slash on re-enables", ns.db.enabled == true and cooldowns(enemy)[1].hideNumbers == true)

-- options panel
local panel, master, forceBox
for _, f in ipairs(ALL_FRAMES) do
  if f.name_ == "NoNameplateNumbers_enabled" then master = f end
  if f.name_ == "NoNameplateNumbers_forceHideText" then forceBox = f end
  if f.scripts.OnShow then panel = f end
end
check("options panel built", panel ~= nil and master ~= nil and forceBox ~= nil)
panel.scripts.OnShow(panel)
check("checkbox reflects saved state", master.checked == true and forceBox.checked == true)
master:SetChecked(false); master.scripts.OnClick(master)
check("clicking master restores numbers", ns.db.enabled == false and cooldowns(enemy)[1].hideNumbers == false)
local sub
for _, f in ipairs(ALL_FRAMES) do if f.name_ == "NoNameplateNumbers_enemy" then sub = f end end
check("sub options greyed while master off", sub.enabled_ == false)
master:SetChecked(true); master.scripts.OnClick(master)
check("clicking master back on re-hides", cooldowns(enemy)[1].hideNumbers == true and sub.enabled_ == true)

-- ---------------------------------------------------------------------------
-- The real 12.1 shape, from a /nnn debug dump:
--   NamePlate5.UnitFrame.AurasFrame.DebuffListFrame.<icon>.Cooldown.<duration>
--   NamePlate5.UnitFrame.AurasFrame.DebuffListFrame.<icon>.CountFrame.Count
-- with GetParent forbidden on the cooldown.
-- ---------------------------------------------------------------------------
plateCount = plateCount + 1
local real = New("Frame", "NamePlate" .. plateCount)
real.namePlateUnitToken = "nameplate9"
plates["nameplate9"] = real
unitFriendly["nameplate9"] = false
local realUF = New("Frame", nil, real); real.UnitFrame = realUF
local aurasFrame = New("Frame", nil, realUF); realUF.AurasFrame = aurasFrame
local debuffList = New("Frame", nil, aurasFrame); aurasFrame.DebuffListFrame = debuffList

local function AddRealDebuff()
  local icon = New("Frame", nil, debuffList)
  local cd = New("Cooldown", nil, icon)
  cd.GetParent = function() error("Attempt to access forbidden object from code tainted by an AddOn") end
  cd.durationText = cd:CreateFontString()      -- region of the cooldown itself
  cd.durationText:SetText("10")
  local countFrame = New("Frame", nil, icon)
  icon.CountFrame = countFrame
  countFrame.Count = countFrame:CreateFontString()
  countFrame.Count:SetText("2")
  cd:SetCooldown(100, 10)
  return icon, cd
end

local icon1, cd1 = AddRealDebuff()
local icon2, cd2 = AddRealDebuff()
fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
check("12.1 shape: first debuff duration hidden", cd1.durationText.shown == false)
check("12.1 shape: second debuff duration hidden", cd2.durationText.shown == false)
check("12.1 shape: stack counts kept", icon1.CountFrame.Count.shown == true
  and icon2.CountFrame.Count.shown == true)
check("12.1 shape: forbidden GetParent did not stop anything",
  cd1.hideNumbers == true and cd2.hideNumbers == true)

-- the third debuff, applied after the nameplate appeared
local icon3, cd3 = AddRealDebuff()
check("third debuff starts visible", cd3.durationText.shown == true)
fire("UNIT_AURA", "nameplate9")
check("third debuff hidden after UNIT_AURA", cd3.durationText.shown == false
  and cd3.hideNumbers == true)

-- and one that appears with no event at all: the sweep has to catch it
local icon4, cd4 = AddRealDebuff()
check("fourth debuff starts visible", cd4.durationText.shown == true)
eventFrame.scripts.OnUpdate(eventFrame, 0.3)
check("fourth debuff hidden by the sweep", cd4.durationText.shown == false
  and cd4.hideNumbers == true)

-- turning the addon off must stop the sweep entirely
SlashCmdList.NONAMEPLATENUMBERS("off")
check("sweep switched off with the addon", eventFrame.scripts.OnUpdate == nil)
check("12.1 shape restored when disabled", cd1.durationText.shown == true
  and cd4.durationText.shown == true)
SlashCmdList.NONAMEPLATENUMBERS("on")
check("sweep back on with the addon", eventFrame.scripts.OnUpdate ~= nil)
check("12.1 shape hidden again", cd1.durationText.shown == false)

-- The trap from a real 12.1 dump: LossOfControlFrame.AuraItemFrame exists on
-- every plate from the start, so the first walk records LossOfControlFrame as
-- a known container. DebuffListFrame fills up only later, and must not be
-- written off just because some other container is already known.
plateCount = plateCount + 1
local trap = New("Frame", "NamePlate" .. plateCount)
trap.namePlateUnitToken = "nameplate10"
plates["nameplate10"] = trap
unitFriendly["nameplate10"] = false
local trapUF = New("Frame", nil, trap); trap.UnitFrame = trapUF
local trapAuras = New("Frame", nil, trapUF); trapUF.AurasFrame = trapAuras
local locFrame = New("Frame", nil, trapAuras); trapAuras.LossOfControlFrame = locFrame
local locItem = New("Frame", nil, locFrame); locFrame.AuraItemFrame = locItem
local locCD = New("Cooldown", nil, locItem); locItem.Cooldown = locCD
local trapList = New("Frame", nil, trapAuras); trapAuras.DebuffListFrame = trapList

fire("NAME_PLATE_UNIT_ADDED", "nameplate10")
check("permanent loss-of-control cooldown tracked at plate add", locCD.hideNumbers == true)

local function AddTrapDebuff()
  local icon = New("Frame", nil, trapList)
  local cd = New("Cooldown", nil, icon)
  cd.GetParent = function() error("Attempt to access forbidden object") end
  cd.durationText = cd:CreateFontString(); cd.durationText:SetText("10")
  cd:SetCooldown(100, 10)
  return cd
end

local trapCD = AddTrapDebuff()
for _ = 1, 8 do eventFrame.scripts.OnUpdate(eventFrame, 0.3) end
check("debuff in a container found later is still hidden",
  trapCD.durationText.shown == false and trapCD.hideNumbers == true)

-- diagnostics must not blow up
UnitIsUnit = function(a, b) return (plates[a] and plates[a].isPlayer and b == "player") or false end
plates["target"] = enemy
print("--- /nnn debug output ---")
local okDebug, err = pcall(SlashCmdList.NONAMEPLATENUMBERS, "debug")
print("--- end debug output ---")
check("/nnn debug runs: " .. tostring(err), okDebug)

print(ok and "ALL PASS" or "FAILURES")
os.exit(ok and 0 or 1)
