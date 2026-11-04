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

local player = { GUID = 1, _item_slot_reservation_client_marks = {} }
local sent_rpcs = {}

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
    Prefabs = { grass = true, twigs = true },
    ThePlayer = player,
    TheWorld = { ismastersim = false },
}

local env =
{
    GLOBAL = runtime_global,
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
    SendModRPCToServer = function(_, container_inst, slotnum, prefab)
        sent_rpcs[#sent_rpcs + 1] = { container = container_inst, slot = slotnum, prefab = prefab }
    end,
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
ISR.Config = { pin_key = "V" }
ISR.ApplyRuntimeIconToSlot = function() return true end
ISR.QueueRefreshVisibleSlotIcons = function() end
ISR.GetContainerInstForSlot = function(slot) return slot.container.inst end
ISR.GetClientContainerGUID = function(inst) return inst ~= nil and inst.GUID or nil end
ISR.GetSlotContainerGUID = function(slot) return slot ~= nil and slot.container ~= nil and slot.container.inst ~= nil and slot.container.inst.GUID or nil end

-- 槽位桩：container 里放一个物品，模拟「已经有草的格子」
local slot_item = { prefab = "grass" }
local container = { inst = { GUID = 1 } }
container.GetItemInSlot = function(_, num) return num == 3 and slot_item or nil end

local slot = { num = 3, container = container, focus = true }
local function ClientMark() return player._item_slot_reservation_client_marks["1:3"] end

-- 固定：客户端只发请求，不预写本地标记 -----------------------------------------
-- 预写就是「闪一下」的来源：没权限时先画框再被服务端擦掉。这里锁死这个行为。
assert_equal(ISR.PinClientSlotMark(slot), true, "pinning an occupied slot sends a request")
assert_equal(ClientMark(), nil, "the client does not paint before the server confirms")
assert_equal(#sent_rpcs, 1, "one request is sent")
assert_equal(sent_rpcs[1].slot, 3, "the request carries the slot number")
assert_equal(sent_rpcs[1].prefab, "grass", "the request pins the slot's current item")

-- 服务端确认后才落库、才画框
ISR.ApplySyncedClientSlotMark(container.inst, 3, "grass")
assert_equal(ClientMark(), "grass", "the mark lands after the server confirms")

-- 被拒绝时服务端推 nil（或什么都不推）：屏幕上没有变化，不闪
ISR.ApplySyncedClientSlotMark(container.inst, 3, nil)
assert_equal(ClientMark(), nil, "a rejection clears nothing because nothing was painted")

-- 再次固定同一格 -> 取消（客户端此刻已知道这一格有标记）
ISR.ApplySyncedClientSlotMark(container.inst, 3, "grass")
assert_equal(ISR.PinClientSlotMark(slot), true, "pinning the same slot again toggles the mark off")
assert_equal(ClientMark(), "grass", "toggling off waits for the server too")
assert_equal(sent_rpcs[#sent_rpcs].prefab, "", "the toggle-off request sends an empty prefab")
ISR.ApplySyncedClientSlotMark(container.inst, 3, nil)
assert_equal(ClientMark(), nil, "the mark is gone after the server confirms the clear")

-- 换成树枝后固定 -> 覆盖
slot_item = { prefab = "twigs" }
assert_equal(ISR.PinClientSlotMark(slot), true, "pinning after swapping the item succeeds")
assert_equal(sent_rpcs[#sent_rpcs].prefab, "twigs", "pin follows the current item in the slot")
ISR.ApplySyncedClientSlotMark(container.inst, 3, "twigs")
assert_equal(ClientMark(), "twigs", "the new prefab lands after confirmation")

-- 空格不能固定
local empty_slot = { num = 4, container = container, focus = false }
assert_equal(ISR.PinClientSlotMark(empty_slot), false, "empty slot cannot be pinned")

-- prefab 带后缀也能归一化
slot_item = { prefab = "Grass.TEX" }
assert_equal(ISR.PinClientSlotMark(slot), true, "prefab with suffix is pinned")
assert_equal(sent_rpcs[#sent_rpcs].prefab, "grass", "pinned key is normalized")

-- 按键意图：只有按住固定键才接管 -----------------------------------------------
local pin_pressed = false
runtime_global.TheInput =
{
    IsControlPressed = function() return false end,
    IsKeyDown = function(_, keycode) return pin_pressed and keycode == 118 end,
}

assert_equal(ISR.GetSlotMouseIntent(1000), nil, "no pin key means no intent")
assert_equal(ISR.GetSlotMouseIntent(1001), nil, "no pin key means no clear intent")

pin_pressed = true
assert_equal(ISR.GetSlotMouseIntent(1000), ISR.SLOT_INTENT_PIN, "pin key plus left click pins the slot")
assert_equal(ISR.GetSlotMouseIntent(1001), ISR.SLOT_INTENT_CLEAR, "pin key plus right click clears the slot")
assert_equal(ISR.GetSlotMouseIntent(29), ISR.SLOT_INTENT_PIN, "control accept is normalized to a left click")
assert_equal(ISR.GetSlotMouseIntent(1), ISR.SLOT_INTENT_CLEAR, "control secondary is normalized to a right click")

ISR.Config.pin_key = "NONE"
assert_equal(ISR.GetSlotMouseIntent(1000), nil, "disabling the pin key stops all interception")
