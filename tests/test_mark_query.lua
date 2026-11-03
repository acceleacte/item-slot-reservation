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
    Prefabs = { grass = true, twigs = true, log = true },
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

ISR = env.ISR
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

server_handlers[ISR.RPC_SET_MARK](player, player, 3, "twigs")

-- 快捷判定不构造标记表，语义与 GetServerSlotMark 一致 -------------------------
assert_equal(ISR.CanItemUseStoredMark(player, 1, 3, { prefab = "twigs" }), true, "matching item may use the reserved slot")
assert_equal(ISR.CanItemUseStoredMark(player, 1, 3, { prefab = "grass" }), false, "foreign item is kept out of the reserved slot")
assert_equal(ISR.CanItemUseStoredMark(player, 1, 9, { prefab = "grass" }), true, "unmarked slot accepts anything")

for slot = 1, 6 do
    assert_equal(
        ISR.IsServerSlotMarked(player, 1, slot),
        ISR.GetServerSlotMark(player, 1, slot) ~= nil,
        "IsServerSlotMarked agrees with GetServerSlotMark at slot "..tostring(slot)
    )
end

-- 同一次 GiveItem 里只枚举一遍标记容器 -----------------------------------------
local sort_calls = 0
local real_sorted = ISR.GetSortedServerMarksForPrefab
ISR.GetSortedServerMarksForPrefab = function(owner, prefab)
    sort_calls = sort_calls + 1
    return real_sorted(owner, prefab)
end

local reserved_item = { prefab = "twigs", components = { inventoryitem = {} }, IsValid = function() return true end }
local reserved_context = { owner = player, item = reserved_item }

assert_equal(ISR.ShouldRoutePlacementByMarks(reserved_context), true, "reserved item routes by marks")
assert_equal(sort_calls, 1, "the mark list is built once")
assert_equal(ISR.ShouldRoutePlacementByMarks(reserved_context), true, "second look still routes")
assert_equal(sort_calls, 1, "the cached mark list is reused inside one placement context")

local other_item = { prefab = "grass", components = { inventoryitem = {} }, IsValid = function() return true end }
local other_context = { owner = player, item = other_item }
sort_calls = 0

assert_equal(ISR.ShouldRoutePlacementByMarks(other_context), false, "unreserved item keeps the vanilla route")
assert_equal(ISR.ShouldRoutePlacementByMarks(other_context), false, "still unrouted on the second look")
assert_equal(sort_calls, 1, "a negative answer is cached too")

-- 显式给了落点就不该进标记路由（原版已经决定了放哪） ---------------------------
local explicit_context = { owner = player, item = reserved_item, slot = 5 }
sort_calls = 0
assert_equal(ISR.ShouldRoutePlacementByMarks(explicit_context), false, "explicit slot skips mark routing")
assert_equal(sort_calls, 0, "no mark lookup when the slot is already decided")
