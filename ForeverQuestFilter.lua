local DB
local defaults = { enabled = true, includeCurrentZone = false, categories = {}, alwaysTrack = {}, tagTracker = true }

local function Print(msg) print("|cff33ff99ForeverQuestFilter:|r " .. tostring(msg)) end

-- Builds an ordered list of { name=, quests={ {id=,index=}, ... } } from the quest log (L window) headers.
local function ScanLog()
    local cats, byName, cur = {}, {}, nil
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                cur = byName[info.title]
                if not cur then
                    cur = { name = info.title, quests = {} }
                    byName[info.title] = cur
                    cats[#cats + 1] = cur
                end
            elseif cur and not info.isHidden and info.questID and info.questID > 0 then
                cur.quests[#cur.quests + 1] = { id = info.questID, index = i }
            end
        end
    end
    return cats
end

local function IsWatched(id)
    if C_QuestLog.GetQuestWatchType then
        return C_QuestLog.GetQuestWatchType(id) ~= nil
    end
    if C_QuestLog.IsQuestWatched then return C_QuestLog.IsQuestWatched(id) end
    return false
end

local function Watch(q)
    if C_QuestLog.AddQuestWatch then
        C_QuestLog.AddQuestWatch(q.id)
    elseif AddQuestWatch then
        AddQuestWatch(q.index)
    end
end

local function Unwatch(q)
    if C_QuestLog.RemoveQuestWatch then
        C_QuestLog.RemoveQuestWatch(q.id)
    elseif RemoveQuestWatch then
        RemoveQuestWatch(q.index)
    end
end

-- Set of names that count as "current zone": the map the player is on plus all parent maps up to
-- (excluding) the continent, e.g. Darnassus -> Teldrassil. Quest log headers use the parent zone name.
local function CurrentZoneNames()
    local names = {}
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local depth = 0
    while mapID and mapID > 0 and depth < 10 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then break end
        if info.mapType and Enum and Enum.UIMapType and info.mapType <= Enum.UIMapType.Continent then break end
        if info.name then names[info.name] = true end
        mapID = info.parentMapID
        depth = depth + 1
    end
    for _, fn in ipairs({ GetRealZoneText, GetZoneText }) do
        local z = fn and fn()
        if z and z ~= "" then names[z] = true end
    end
    return names
end

local function IsCategorySelected(name, zones)
    if DB.categories[name] then return true end
    return DB.includeCurrentZone and zones and zones[name] or false
end

-- ---------------------------------------------------------------- tracker tags
local RAID_TAG_ID, DUNGEON_TAG_ID = 62, 81

-- Returns the tag letter(s) for a quest: R raid, D dungeon, E elite, otherwise first letter of the tag name (P, G, H, L ...)
local function GetTagLetter(questID)
    local tagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
    if tagInfo then
        if tagInfo.tagID == RAID_TAG_ID then return "R" end
        if tagInfo.tagID == DUNGEON_TAG_ID then return "D" end
    end
    if (C_QuestLog.IsEliteQuest and C_QuestLog.IsEliteQuest(questID)) or (tagInfo and tagInfo.isElite) then
        return "E"
    end
    if tagInfo and tagInfo.tagName and tagInfo.tagName ~= "" then
        return (tagInfo.tagName:sub(1, 1)):upper()
    end
    return ""
end

local function GetQuestLevel(questID)
    local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if not idx or idx <= 0 then return nil end
    local info = C_QuestLog.GetInfo(idx)
    return info and (info.difficultyLevel or info.level)
end

local function TagPrefix(questID)
    local letter = GetTagLetter(questID)
    local level = GetQuestLevel(questID)
    if level and level > 0 then return ("[%d%s] "):format(level, letter) end
    if letter ~= "" then return ("[%s] "):format(letter) end
    return nil
end

local originals = setmetatable({}, { __mode = "k" }) -- block -> { orig=, tagged= }

local function TagBlock(block)
    local fs = block.HeaderText
    local questID = block.id
    if not fs or not questID or not fs.GetText then return end
    local text = fs:GetText()
    if not text or text == "" then return end
    local letter = GetTagLetter(questID)
    local showLevel = true

    -- removes the redundant "(Dungeon)" / "(Elite)" suffix Blizzard appends
    local function StripSuffix(s)
        local tagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
        for _, name in ipairs({ tagInfo and tagInfo.tagName or "", ELITE or "" }) do
            if name ~= "" then
                local escaped = name:gsub("(%p)", "%%%1")
                s = s:gsub("%s*%(" .. escaped .. "%)(|?r?)$", "%1")
            end
        end
        return s
    end

    local new
    -- bracket with level (and maybe letter): "[16]", "[16+]", "[16D]"
    local lvl, oldLetter = text:match("%[(%d+)%+?(%a*)%]")
    if lvl then
        local bracket = showLevel and ("[" .. lvl .. letter .. "]") or (letter ~= "" and ("[" .. letter .. "]") or "")
        new = text:gsub("%[%d+%+?%a*%]%s?", bracket ~= "" and (bracket:gsub("%%", "%%%%") .. " ") or "", 1)
    elseif text:find("%[%a+%]") then
        -- letter-only bracket from us ("[D] Title")
        if showLevel then
            local level = GetQuestLevel(questID)
            if not level or level <= 0 then return end
            new = text:gsub("%[%a+%]", "[" .. level .. letter .. "]", 1)
        else
            return
        end
    else
        local prefix = TagPrefix(questID)
        if not prefix then return end
        new = text:gsub("^(|c%x%x%x%x%x%x%x%x)", "%1" .. prefix, 1)
        if new == text then new = prefix .. text end
    end
    if not new then return end
    if letter ~= "" then new = StripSuffix(new) end
    if new ~= text then
        originals[block] = { orig = text, tagged = new }
        fs:SetText(new)
    end
end

-- Never call Blizzard tracker functions from here (that would run Blizzard's layout tainted); only read the
-- block tables and set header texts. Our own state lives in the weak table above.
local function ForEachBlock(fn)
    local mod = QuestObjectiveTracker
    if not mod or type(mod.usedBlocks) ~= "table" then return end
    for _, blocks in pairs(mod.usedBlocks) do
        if type(blocks) == "table" then
            for _, block in pairs(blocks) do
                if type(block) == "table" then fn(block) end
            end
        end
    end
end

local function TagTracker()
    if not DB or not DB.tagTracker then return end
    ForEachBlock(TagBlock)
end

-- Puts the original header texts back (used when tagging is switched off)
local function RefreshTracker()
    ForEachBlock(function(block)
        local o = originals[block]
        local fs = block.HeaderText
        if o and fs and fs:GetText() == o.tagged then fs:SetText(o.orig) end
        originals[block] = nil
    end)
end

local trackerHooked
local function HookTracker()
    if trackerHooked or not QuestObjectiveTracker then return end
    for _, fn in ipairs({ "Update", "EndLayout" }) do
        if type(QuestObjectiveTracker[fn]) == "function" then
            hooksecurefunc(QuestObjectiveTracker, fn, TagTracker)
        end
    end
    trackerHooked = true
end

-- Small window with selectable text for copy & paste (Ctrl+A, Ctrl+C)
local copyFrame
local function ShowCopyWindow(text)
    if not copyFrame then
        local f = CreateFrame("Frame", "FQF_CopyFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(620, 320)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true); f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if f.TitleText then f.TitleText:SetText("ForeverQuestFilter - Ctrl+A, Ctrl+C") end
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -30)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(570)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.edit = eb
        tinsert(UISpecialFrames, "FQF_CopyFrame")
        copyFrame = f
    end
    copyFrame.edit:SetText(text)
    copyFrame:Show()
    copyFrame.edit:SetFocus()
    copyFrame.edit:HighlightText()
end

local obj
local function UpdateText()
    if not obj then return end
    local tracked = C_QuestLog.GetNumQuestWatches and C_QuestLog.GetNumQuestWatches() or 0
    local n = 0
    for _ in pairs(DB.categories) do n = n + 1 end
    obj.text = ("%s%d tracked|r (%d cat.)"):format(DB.enabled and "|cff00ff00" or "|cff888888", tracked, n)
end

local applying, pending = false, false
local function Apply()
    pending = false
    if not DB or not DB.enabled or applying then return end
    applying = true
    local zone = CurrentZoneNames()
    for _, cat in ipairs(ScanLog()) do
        local want = IsCategorySelected(cat.name, zone)
        for _, q in ipairs(cat.quests) do
            local watched = IsWatched(q.id)
            local qWant = want or DB.alwaysTrack[GetTagLetter(q.id)]
            if qWant and not watched then Watch(q)
            elseif not qWant and watched then Unwatch(q) end
        end
    end
    applying = false
    UpdateText()
    TagTracker()
end

local function QueueApply()
    if pending then return end
    pending = true
    C_Timer.After(0.3, Apply)
end

local function ToggleCategory(name)
    DB.categories[name] = (not DB.categories[name]) or nil
    Apply()
end

local function ShowMenu(anchor)
    local cats = ScanLog()
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchor, function(_, root)
            root:CreateTitle("ForeverQuestFilter")
            root:CreateCheckbox("Enabled", function() return DB.enabled end, function()
                DB.enabled = not DB.enabled; Apply(); UpdateText()
            end)
            root:CreateCheckbox("Always include current zone", function() return DB.includeCurrentZone end, function()
                DB.includeCurrentZone = not DB.includeCurrentZone; Apply()
            end)
            root:CreateCheckbox("Tag quests in tracker (E / D / R ...)", function() return DB.tagTracker end, function()
                DB.tagTracker = not DB.tagTracker
                if DB.tagTracker then TagTracker() else RefreshTracker() end
            end)
            local always = root:CreateButton("Always track (any category)")
            for _, t in ipairs({ { "E", "Elite quests" }, { "D", "Dungeon quests" }, { "R", "Raid quests" } }) do
                always:CreateCheckbox(t[2], function() return DB.alwaysTrack[t[1]] and true or false end, function()
                    DB.alwaysTrack[t[1]] = (not DB.alwaysTrack[t[1]]) or nil
                    Apply()
                end)
            end
            root:CreateDivider()
            root:CreateTitle("Categories")
            if #cats == 0 then root:CreateTitle("|cff888888(quest log empty)|r") end
            for _, cat in ipairs(cats) do
                root:CreateCheckbox(("%s |cff888888(%d)|r"):format(cat.name, #cat.quests),
                    function() return DB.categories[cat.name] and true or false end,
                    function() ToggleCategory(cat.name) end)
            end
            root:CreateDivider()
            root:CreateButton("Select all", function()
                for _, c in ipairs(cats) do DB.categories[c.name] = true end; Apply()
            end)
            root:CreateButton("Select none", function()
                wipe(DB.categories); Apply()
            end)
        end)
    elseif EasyMenu then
        local dd = _G.FQF_DropDown or CreateFrame("Frame", "FQF_DropDown", UIParent, "UIDropDownMenuTemplate")
        local menu = {
            { text = "ForeverQuestFilter", isTitle = true, notCheckable = true },
            { text = "Enabled", isNotRadio = true, keepShownOnClick = true,
              checked = DB.enabled, func = function() DB.enabled = not DB.enabled; Apply() end },
            { text = "Always include current zone", isNotRadio = true, keepShownOnClick = true,
              checked = DB.includeCurrentZone, func = function() DB.includeCurrentZone = not DB.includeCurrentZone; Apply() end },
        }
        for _, cat in ipairs(cats) do
            menu[#menu + 1] = { text = cat.name, isNotRadio = true, keepShownOnClick = true,
                checked = DB.categories[cat.name] and true or false,
                func = function() ToggleCategory(cat.name) end }
        end
        EasyMenu(menu, dd, "cursor", 0, 0, "MENU")
    else
        Print("No dropdown API found; use /fqf list and /fqf toggle <name>.")
    end
end

local function SetupLDB()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    if not ldb then Print("LibDataBroker not found (is Bazooka loaded?). Slash commands only: /fqf"); return end
    obj = ldb:NewDataObject("ForeverQuestFilter", {
        type = "data source",
        label = "Quests",
        text = "...",
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        OnClick = function(self, button)
            if button == "RightButton" then
                DB.enabled = not DB.enabled; Apply()
            else
                ShowMenu(self)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("ForeverQuestFilter")
            tt:AddLine(DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r")
            local any
            for name in pairs(DB.categories) do
                tt:AddLine("  " .. name, 1, 1, 1); any = true
            end
            if not any then tt:AddLine("  (no categories selected)", .6, .6, .6) end
            tt:AddLine(" ")
            tt:AddLine("Left-click: choose categories", .8, .8, .8)
            tt:AddLine("Right-click: enable/disable", .8, .8, .8)
        end,
    })
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ForeverQuestFilterDB = ForeverQuestFilterDB or {}
        DB = ForeverQuestFilterDB
        for k, v in pairs(defaults) do if DB[k] == nil then DB[k] = v end end
        DB.alwaysTrack = DB.alwaysTrack or {}
        SetupLDB()
        HookTracker()
        for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED",
                             "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "QUEST_REMOVED" }) do
            self:RegisterEvent(e)
        end
        C_Timer.After(3, Apply)
        UpdateText()
    elseif not applying then
        QueueApply()
    end
end)

SLASH_FOREVERQUESTFILTER1 = "/fqf"
SlashCmdList.FOREVERQUESTFILTER = function(msg)
    msg = (msg or ""):lower()
    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    if cmd == "on" or cmd == "off" then
        DB.enabled = (cmd == "on"); Apply(); Print(cmd)
    elseif cmd == "list" then
        for _, c in ipairs(ScanLog()) do
            Print(("%s %s (%d)"):format(DB.categories[c.name] and "[x]" or "[ ]", c.name, #c.quests))
        end
    elseif cmd == "debug" then
        local mod = QuestObjectiveTracker
        local lines = {
            "tracker=" .. tostring(mod ~= nil) .. " hooked=" .. tostring(trackerHooked) .. " tagTracker=" .. tostring(DB.tagTracker),
        }
        if mod and mod.EnumerateActiveBlocks then
            mod:EnumerateActiveBlocks(function(block)
                local fs = block and block.HeaderText
                local txt = fs and fs:GetText() or "nil"
                lines[#lines + 1] = ("id=%s tag=%q text=%s"):format(tostring(block and block.id),
                    block and block.id and GetTagLetter(block.id) or "?", (txt:gsub("|", "||")))
            end)
        end
        ShowCopyWindow(table.concat(lines, "\n"))
    elseif cmd == "toggle" and arg ~= "" then
        for _, c in ipairs(ScanLog()) do
            if c.name:lower() == arg then ToggleCategory(c.name); Print("toggled " .. c.name); return end
        end
        Print("category not found")
    else
        Print("/fqf on|off|list|toggle <category>  - or left-click the Bazooka plugin")
    end
end
