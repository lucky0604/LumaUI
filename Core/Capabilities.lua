local _, app = ...
local caps = {}
app.Capabilities = caps

function caps.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

function caps.Plain(value, expected)
    if caps.IsSecret(value) then return nil end
    if expected and type(value) ~= expected then return nil end
    return value
end

function caps.IsRetail()
    return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and WOW_PROJECT_MAINLINE ~= nil
end

function caps.Snapshot()
    local version, build, _, interface = GetBuildInfo()
    return {
        version = version, build = build, interface = interface, retail = caps.IsRetail(),
        secrets = type(issecretvalue) == "function",
        containers = type(C_Container) == "table" and type(C_Container.GetContainerItemInfo) == "function",
        containerActions = type(C_Container) == "table" and type(C_Container.UseContainerItem) == "function"
            and type(C_Container.PickupContainerItem) == "function",
        containerSort = type(C_Container) == "table" and type(C_Container.SortBags) == "function",
        units = type(UnitHealth) == "function" and type(RegisterUnitWatch) == "function",
        settings = type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function",
        privateAuras = type(C_UnitAuras) == "table" and type(C_UnitAuras.AddPrivateAuraAnchor) == "function",
        -- Parts a replacement needs to keep what the native frame showed. These
        -- are reported separately from "units" so a degraded client keeps the
        -- native cast bars and auras instead of losing them silently.
        cast = type(UnitCastingInfo) == "function" and type(UnitChannelInfo) == "function",
        auras = type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function",
        raidTargets = type(GetRaidTargetIndex) == "function",
        namePlates = type(C_NamePlate) == "table" and type(C_NamePlate.GetNamePlateForUnit) == "function",
        -- World-quest time has a dedicated API; GetQuestInfoByQuestID does not
        -- carry it (documented shape: title, factionID, capped,
        -- displayAsObjective).
        taskTime = type(C_TaskQuest) == "table"
            and (type(C_TaskQuest.GetQuestTimeLeftSeconds) == "function"
                or type(C_TaskQuest.GetQuestTimeLeftMinutes) == "function"),
        questItems = type(C_QuestLog) == "table"
            and type(C_QuestLog.GetLogIndexForQuestID) == "function"
            and type(_G.GetQuestLogSpecialItemInfo) == "function",
        itemIcon = (type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function")
            or type(_G.GetItemInfoInstant) == "function",
    }
end
