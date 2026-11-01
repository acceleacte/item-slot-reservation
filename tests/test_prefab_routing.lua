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

local server_handlers = {}

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
    Prefabs = { grass = true, twigs = true, log = true, spear = true },
    TheWorld = { ismastersim = true },
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
    AddComponentPostInit = function() end,
    AddPlayerPostInit = function() end,
    AddClassPostConstruct = function() end,
    AddModRPCHandler = function(_, name, handler) server_handlers[name] = handler end,
    AddClientModRPCHandler = function() end,
    GetModRPC = function(namespace, name) return { namespace = namespace, name = name } end,
    GetClientModRPC = function(namespace, name) return { namespace = namespace, name = name } end,
    SendModRPCToServer = function() end,
    SendModRPCToClient = function() end,
}
env.env = env

local function load_module(relative_path)
    local path = ISR_TEST_ROOT.."/"..relative_path
    local chunk, err = load(read_file(path), "@"..path, "t", env)
    assert(chunk ~= nil, err)
    chunk()
end

load_module("scripts/isr_env.lua")
load_module("scripts/isr_storage.lua")
load_module("scripts/isr_markstores.lua")
load_module("scripts/isr_slotmarks.lua")
load_module("scripts/isr_persistence.lua")
load_module("scripts/isr_placement.lua")
load_module("scripts/isr_candidates.lua")

local ISR = env.ISR
local MarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

local player =
{
    GUID = 1,
    components =
    {
        inventory =
        {
            itemslots = {},
            equipslots = {},
            GetNumSlots = function() return 15 end,
            GetItemInSlot = function() return nil end,
        },
    },
}
player.components.isr_slotmarkstore = MarkStore(player)

-- 服务端 RPC：只接受合法 prefab -------------------------------------------------
server_handlers[ISR.RPC_SET_MARK](player, player, 3, "twigs")
local written = player.components.isr_slotmarkstore:GetMark(3)
assert_equal(written.prefab, "twigs", "prefab mark is stored by rpc")

server_handlers[ISR.RPC_SET_MARK](player, player, 4, "no_such_thing")
assert_equal(player.components.isr_slotmarkstore:GetMark(4), nil, "unknown prefab is rejected")

-- 旧的「装备部位」键不再有意义：既不是 prefab 就会被拒
server_handlers[ISR.RPC_SET_MARK](player, player, 5, "head")
assert_equal(player.components.isr_slotmarkstore:GetMark(5), nil, "equipment-slot style key is rejected")

-- 标记读取与匹配 ---------------------------------------------------------------
local mark = ISR.GetServerSlotMark(player, 1, 3)
assert_equal(mark.prefab, "twigs", "server mark exposes prefab key")

assert_equal(ISR.MarkMatchesItem(mark, { prefab = "twigs" }), true, "prefab mark matches its own item")
assert_equal(ISR.MarkMatchesItem(mark, { prefab = "grass" }), false, "prefab mark rejects a foreign item")
assert_equal(ISR.MarkMatchesItem(mark, { prefab = "log" }), false, "prefab mark rejects an unrelated item")

assert_equal(#ISR.GetSortedServerMarksForPrefab(player, "twigs"), 1, "prefab marks are looked up by prefab")

-- 候选格判定：同一格对匹配物品开放，对其它物品关闭 -----------------------------
assert_equal(ISR.CanItemUseMarkedSlot(player, 1, 3, { prefab = "twigs" }), true, "reserved slot accepts its item")
assert_equal(ISR.CanItemUseMarkedSlot(player, 1, 3, { prefab = "grass" }), false, "reserved slot rejects other items")
assert_equal(ISR.CanItemUseMarkedSlot(player, 1, 9, { prefab = "grass" }), true, "unmarked slot accepts anything")

-- 放置路由：只有被预留的物品才进入标记路径 -------------------------------------
local grass = { prefab = "grass", components = { inventoryitem = {} }, IsValid = function() return true end }
local twigs = { prefab = "twigs", components = { inventoryitem = {} }, IsValid = function() return true end }

assert_equal(
    ISR.ShouldRoutePlacementByMarks({ owner = player, item = twigs, slot = nil }),
    true,
    "item mark unlocks placement routing"
)
assert_equal(
    ISR.ShouldRoutePlacementByMarks({ owner = player, item = grass, slot = nil }),
    false,
    "item without marks does not enter placement routing"
)

local placed = nil
local storage = { guid = player.GUID }
ISR.GetStorageForMark = function() return storage end
ISR.GetStorageAdapter = function()
    return
    {
        GetSlotCount = function() return 15 end,
        GetItemInSlot = function() return nil end,
        GetGUID = function(_, value) return value.guid end,
        CanUseEmptySlot = function() return true end,
        PlaceInSlot = function(_, _, item, slot)
            placed = { item = item, slot = slot }
            return true
        end,
    }
end

local routed = ISR.TryPlaceByMarks({ owner = player, item = twigs, slot = nil })
assert_equal(routed, true, "prefab mark routes the item into the reserved slot")
assert_equal(placed.slot, 3, "prefab mark routes to the reserved slot number")
assert_equal(ISR.TryPlaceByMarks({ owner = player, item = grass, slot = nil }), false, "unmarked item falls through to vanilla placement")

-- 清空标记后路由立即失效 -------------------------------------------------------
server_handlers[ISR.RPC_SET_MARK](player, player, 3, "")
assert_equal(ISR.GetServerSlotMark(player, 1, 3), nil, "clearing rpc removes the mark")
assert_equal(
    ISR.ShouldRoutePlacementByMarks({ owner = player, item = twigs, slot = nil }),
    false,
    "cleared mark stops routing"
)
