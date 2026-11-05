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

ISR.GetMarkContainerInstances = function() return { player } end
ISR.IsStorageOwnedByPlayer = function(_, inst) return inst == player end
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

-- 标记不记名：容器上的每一格对能用这只容器的人都可见、可用（0.1.8）
player.userid = "KU_me"
player.components.isr_slotmarkstore:SetMark(5, "log", 20)
local shared_marks = ISR.GetServerMarks(player)
assert_equal(shared_marks[ISR.GetSlotKey(player.GUID, 5)].prefab, "log", "every mark on a usable container is visible")
assert_equal(shared_marks[ISR.GetSlotKey(player.GUID, 3)].prefab, "cutgrass", "older marks are visible too")
assert_equal(shared_marks[ISR.GetSlotKey(player.GUID, 5)].owner, nil, "marks carry no owner")
player.components.isr_slotmarkstore:ClearMark(5)

-- 不匹配的物品被放进预留格时清标记；匹配时保留 --------------------------------
assert_equal(ISR.ClearServerSlotMarkIfItemMismatches(player, player.GUID, 3, { prefab = "cutgrass" }), false, "matching item keeps the mark")
assert_equal(ISR.GetServerSlotMark(player, player.GUID, 3).prefab, "cutgrass", "mark survives a matching item")
assert_equal(ISR.ClearServerSlotMarkIfItemMismatches(player, player.GUID, 3, { prefab = "twigs" }), true, "mismatched item clears the mark")
assert_equal(ISR.GetServerSlotMark(player, player.GUID, 3), nil, "mismatched mark is gone")

-- 容器路径：格子被别的东西占了就解除预留（不要求容器有在线主人） ----------------
local chest = { GUID = 900, components = {} }
chest.components.isr_slotmarkstore = MarkStore(chest)
chest.components.isr_slotmarkstore:SetMark(2, "log", 9)

-- 箱子不是谁的随身物品 ⇒ 共享容器；标记变化广播给所有装了这个模组的玩家
ISR.IsSharedMarkContainer = function(_, inst) return inst == chest end
ISR.IsMarkContainerVisibleTo = function() return true end
ISR.IsClientCapable = function() return true end

local synced = {}
ISR.SyncMarkToClient = function(target, guid, slot, prefab, play_sound)
    synced[#synced + 1] = { player = target, guid = guid, slot = slot, prefab = prefab, sound = play_sound }
end

assert_equal(ISR.ClearContainerSlotMarkOnMismatch(chest, 2, { prefab = "log" }), false, "a matching item keeps the container mark")
assert_equal(chest.components.isr_slotmarkstore:GetMark(2) ~= nil, true, "container mark survives a matching item")
assert_equal(#synced, 0, "keeping the mark syncs nothing")

assert_equal(ISR.ClearContainerSlotMarkOnMismatch(chest, 2, { prefab = "boards" }), true, "a foreign item clears the container mark")
assert_equal(chest.components.isr_slotmarkstore:GetMark(2), nil, "container mark is gone")
assert_equal(#synced, 0, "no online owner means no client sync")

-- owner 在线时补一次清标记推送
local owner_player = { GUID = 2, userid = "KU_player", components = {} }
runtime_global.AllPlayers = { [owner_player.GUID] = owner_player }
chest.components.isr_slotmarkstore:SetMark(3, "boards", 10)
assert_equal(ISR.ClearContainerSlotMarkOnMismatch(chest, 3, { prefab = "log" }), true, "mismatch clears with an online owner")
assert_equal(#synced, 1, "the owner gets one clear sync")
assert_equal(synced[1].guid, 900, "sync carries the container guid")
assert_equal(synced[1].slot, 3, "sync carries the slot")
assert_equal(synced[1].sound, true, "the clear sync plays the sound")
assert_equal(ISR.ClearContainerSlotMarkOnMismatch(chest, 99, { prefab = "log" }), false, "an unmarked slot has nothing to clear")

-- 容器不记名：谁打开着箱子就用谁来按标记路由；没人打开就没有路由主人
chest.components.container = { IsOpenedBy = function(_, doer) return doer == owner_player end }
assert_equal(ISR.GetMarkOwnerPlayer(chest), owner_player, "the opened container resolves to the player using it")
chest.components.container.IsOpenedBy = function() return false end
assert_equal(ISR.GetMarkOwnerPlayer(chest), nil, "nobody opens it means no routing owner")
