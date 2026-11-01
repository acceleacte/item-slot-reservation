local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

Class = function(constructor)
    local class = {}
    class.__index = class
    return setmetatable(class,
    {
        __call = function(_, ...)
            local instance = setmetatable({}, class)
            constructor(instance, ...)
            return instance
        end,
    })
end

local runtime_global =
{
    debug = debug,
    error = error,
    next = next,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    unpack = table.unpack,
    xpcall = xpcall,
    Prefabs = { grass = true, twigs = true, log = true, spear = true, cutgrass = true },
}

local env =
{
    GLOBAL = runtime_global,
    Class = Class,
    ipairs = ipairs,
    math = math,
    pairs = pairs,
    print = print,
    string = string,
    table = { concat = table.concat, insert = table.insert, remove = table.remove, sort = table.sort },
    tostring = tostring,
    type = type,
    AddModRPCHandler = function() end,
    AddClientModRPCHandler = function() end,
    SendModRPCToServer = function() end,
    SendModRPCToClient = function() end,
    GetModRPC = function(namespace, name) return { namespace = namespace, name = name } end,
    GetClientModRPC = function(namespace, name) return { namespace = namespace, name = name } end,
}
env.env = env

local function load_module(relative_path)
    local path = ISR_TEST_ROOT.."/"..relative_path
    local chunk, err = load(read_file(path), "@"..path, "t", env)
    assert(chunk ~= nil, err)
    chunk()
end

load_module("scripts/isr_env.lua")
load_module("scripts/isr_slotmarks.lua")

local ISR = env.ISR
local MarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

-- prefab 键归一化 --------------------------------------------------------------
assert_equal(ISR.NormalizePrefabKey("Grass.TEX"), "grass", "prefab key is lowercased and stripped of .tex")
assert_equal(ISR.NormalizePrefabKey("CutGrass"), "cutgrass", "prefab key is lowercased")
assert_equal(ISR.NormalizePrefabKey(""), nil, "empty prefab key is rejected")
assert_equal(ISR.NormalizePrefabKey(nil), nil, "nil prefab key is rejected")
assert_equal(ISR.IsValidPrefabKey("grass"), true, "known prefab is accepted")
assert_equal(ISR.IsValidPrefabKey("no_such_thing"), false, "unknown prefab is rejected")

-- 标记匹配：字符串、表、0.1.0 旧表格式 --------------------------------------
assert_equal(ISR.MarkMatchesItem("grass", { prefab = "grass" }), true, "string mark matches its own item")
assert_equal(ISR.MarkMatchesItem("grass", { prefab = "twigs" }), false, "string mark rejects a foreign item")
assert_equal(ISR.MarkMatchesItem("grass", nil), false, "string mark rejects a missing item")
assert_equal(ISR.MarkMatchesItem({ prefab = "twigs" }, { prefab = "twigs" }), true, "table mark matches its own item")
assert_equal(ISR.MarkMatchesItem({ eslot = "log" }, { prefab = "log" }), true, "legacy table mark is still readable")
assert_equal(ISR.MarkMatchesItem(nil, { prefab = "log" }), false, "missing mark matches nothing")

-- 服务端标记读取：容器组件 → {container_guid, slot, prefab, order} ------------
local player = { GUID = 1, components = {} }
player.components.isr_slotmarkstore = MarkStore(player)
player.components.isr_slotmarkstore:SetMark(3, "cutgrass", 5)
player.components.isr_slotmarkstore:SetMark(4, "twigs", 2)

ISR.GetPersonalStorageInstances = function() return { player } end
ISR.GetSlotMarkStoreForGUID = function(_, guid)
    return guid == player.GUID and player.components.isr_slotmarkstore or nil
end
ISR.SyncMarkToClient = function() end

local marks = ISR.GetServerMarks(player)
local mark = marks[ISR.GetSlotKey(player.GUID, 3)]
assert_equal(mark.prefab, "cutgrass", "server mark exposes the prefab")
assert_equal(mark.container_guid, player.GUID, "server mark exposes its container")
assert_equal(ISR.GetServerSlotMark(player, player.GUID, 4).prefab, "twigs", "single mark lookup works")

local sorted = ISR.GetSortedServerMarksForPrefab(player, "Twigs.TEX")
assert_equal(#sorted, 1, "prefab lookup normalizes the query")
assert_equal(sorted[1].slot, 4, "prefab lookup returns the reserved slot")
assert_equal(#ISR.GetSortedServerMarksForPrefab(player, "log"), 0, "unreserved prefab has no slots")

-- 不匹配的物品被放进预留格时清标记；匹配时保留 --------------------------------
assert_equal(ISR.ClearServerSlotMarkIfItemMismatches(player, player.GUID, 3, { prefab = "cutgrass" }), false, "matching item keeps the mark")
assert_equal(ISR.GetServerSlotMark(player, player.GUID, 3).prefab, "cutgrass", "mark survives a matching item")
assert_equal(ISR.ClearServerSlotMarkIfItemMismatches(player, player.GUID, 3, { prefab = "twigs" }), true, "mismatched item clears the mark")
assert_equal(ISR.GetServerSlotMark(player, player.GUID, 3), nil, "mismatched mark is gone")
