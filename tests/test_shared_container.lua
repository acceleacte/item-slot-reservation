-- 共享世界容器（0.1.8，标记不记名）
--
-- 用户指定（2026-11-04）：
--   * 容器独立且不记名 —— 谁打开谁都能固定、改、清
--   * B 要看到 A 的框
--   * B 拾取物品要回到箱子里固定的格，即使是 A 固定的
--
-- 这里用真实的 isr_storage + isr_slotmarks 跑，只桩掉环境依赖

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
    error = error,
    next = next,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    unpack = table.unpack,
    xpcall = xpcall,
    Prefabs = { log = true, twigs = true, grass = true },
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
    AddComponentPostInit = function() end,
    AddPlayerPostInit = function() end,
    AddPrefabPostInit = function() end,
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
load_module("scripts/isr_storage.lua")
load_module("scripts/isr_markstores.lua")
load_module("scripts/isr_slotmarks.lua")

local ISR = env.ISR
local MarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

local alice = { GUID = 11, userid = "KU_alice", components = {} }
local bob = { GUID = 12, userid = "KU_bob", components = {} }

-- 基地箱子：没有 inventoryitem（拿不起来）⇒ 共享世界容器
local chest = { GUID = 900, components = { container = {} } }
chest.components.isr_slotmarkstore = MarkStore(chest)
chest.components.isr_slotmarkstore:SetMark(2, "log", 5)

-- Alice 的背包：有 inventoryitem 主人链 ⇒ 不共享
local backpack = { GUID = 901, components = { container = {} } }
backpack.components.inventoryitem = { GetGrandOwner = function() return alice end }
backpack.components.isr_slotmarkstore = MarkStore(backpack)
backpack.components.isr_slotmarkstore:SetMark(1, "twigs", 6)

-- 跟着 Alice 跑的切斯特：跟随型容器，别人用不到
local chester = { GUID = 902, components = { container = {} } }
chester.components.follower = { GetLeader = function() return alice end }
chester.components.isr_slotmarkstore = MarkStore(chester)
chester.components.isr_slotmarkstore:SetMark(1, "grass", 7)

-- 组件侧 TouchRegistry 写的是真实 _G.ISR（测试里 ISR 在 env 里），手动登记
ISR._mark_containers =
{
    [chest.GUID] = chest,
    [backpack.GUID] = backpack,
    [chester.GUID] = chester,
}

runtime_global.Ents =
{
    [chest.GUID] = chest,
    [backpack.GUID] = backpack,
    [chester.GUID] = chester,
}

-- 范围 / 归属判定 --------------------------------------------------------------
assert_equal(ISR.IsSharedMarkContainer(bob, chest), true, "a世界容器 base chest is shared")
assert_equal(ISR.IsSharedMarkContainer(alice, chest), true, "the chest is shared for every player")
assert_equal(ISR.IsSharedMarkContainer(bob, backpack), false, "another player's backpack is not shared")
assert_equal(ISR.IsSharedMarkContainer(bob, chester), false, "a follower container belongs to its leader")
assert_equal(ISR.IsSharedMarkContainer(alice, chester), true, "the leader can use his own follower container")
assert_equal(ISR.IsSharedMarkContainer(bob, bob), false, "a player is never a shared container")

assert_equal(ISR.IsMarkableContainerForPlayer(bob, chest.GUID), true, "any player may mark a shared chest")
assert_equal(ISR.IsMarkableContainerForPlayer(bob, backpack.GUID), false, "a stranger cannot mark someone's backpack")

-- B 能看到 A 的框：共享容器的标记全部进 GetServerMarks -------------------------
local marks_for_bob = ISR.GetServerMarks(bob)
assert_equal(marks_for_bob[ISR.GetSlotKey(chest.GUID, 2)].prefab, "log",
    "bob sees the mark alice put on the shared chest")
assert_equal(marks_for_bob[ISR.GetSlotKey(backpack.GUID, 1)], nil,
    "bob does not see anything inside alice's backpack")
assert_equal(marks_for_bob[ISR.GetSlotKey(chester.GUID, 1)], nil,
    "bob does not see anything inside alice's chester")

local marks_for_alice = ISR.GetServerMarks(alice)
assert_equal(marks_for_alice[ISR.GetSlotKey(chest.GUID, 2)].prefab, "log", "the chest mark shows for alice too")
assert_equal(marks_for_alice[ISR.GetSlotKey(backpack.GUID, 1)].prefab, "twigs", "alice keeps her own backpack marks")

-- B 拾取物品要回 A 固定的格：路由查的是同一份标记表 ----------------------------
local sorted = ISR.GetSortedServerMarksForPrefab(bob, "log")
assert_equal(#sorted, 1, "bob routes logs into the chest slot alice pinned")
assert_equal(sorted[1].slot, 2, "the routed slot is the one alice pinned")
assert_equal(sorted[1].container_guid, chest.GUID, "the routed container is the shared chest")

-- 不记名：标记本身不带 owner，存档也不写 owner
assert_equal(chest.components.isr_slotmarkstore:GetMark(2).owner, nil, "the mark carries no owner")
assert_equal(chest.components.isr_slotmarkstore:OnSave().owner, nil, "the container carries no owner")

-- 谁能收到推送：共享容器广播，随身容器只推给主人
assert_equal(ISR.IsMarkContainerVisibleTo(bob, chest.GUID), true, "bob is a viewer of the shared chest")
assert_equal(ISR.IsMarkContainerVisibleTo(bob, backpack.GUID), false, "bob is not a viewer of alice's backpack")

-- 独占模式（container_sharing = exclusive，0.1.8 新增开关）-------------------------
-- 共享是默认值；关掉共享之后，世界容器退回「第一个落标记的人独占」
ISR.Config = { container_sharing = "exclusive" }
chest.components.isr_slotmarkstore:SetOwner("KU_alice")

assert_equal(ISR.IsSharedMarkContainer(bob, chest), false, "exclusive mode leaves no shared container")
assert_equal(ISR.IsStorageOwnedByPlayer(alice, chest), true, "the recorded owner owns the chest")
assert_equal(ISR.IsStorageOwnedByPlayer(bob, chest), false, "another player does not own it")

assert_equal(ISR.GetServerMarks(bob)[ISR.GetSlotKey(chest.GUID, 2)], nil,
    "bob does not see the chest marks in exclusive mode")
assert_equal(ISR.GetServerMarks(alice)[ISR.GetSlotKey(chest.GUID, 2)].prefab, "log",
    "alice still sees the marks she pinned")
assert_equal(#ISR.GetSortedServerMarksForPrefab(bob, "log"), 0,
    "bob does not route pickups into a chest he does not own")
assert_equal(ISR.IsMarkContainerVisibleTo(bob, chest.GUID), false,
    "bob gets no pushes for that chest")
assert_equal(ISR.IsMarkContainerVisibleTo(alice, chest.GUID), true,
    "the owner still gets pushes")

-- 路由主人：独占模式下按记下的 owner 找人，不看谁正打开着箱子
runtime_global.AllPlayers = { alice, bob }
assert_equal(ISR.GetMarkOwnerPlayer(chest), alice, "the routing owner is the recorded owner")

-- 切回共享：同一份数据立刻恢复成「谁都能用」，不需要迁移
ISR.Config = nil
assert_equal(ISR.IsSharedMarkContainer(bob, chest), true, "shared is the default again")
assert_equal(ISR.GetServerMarks(bob)[ISR.GetSlotKey(chest.GUID, 2)].prefab, "log",
    "bob sees the chest marks again")

-- 「打开即可」在同步与枚举路径上同样成立（2026-11-05 实测）
-- 切斯特跟随别人（或没眼骨跟进、leader 指不到当前玩家）时归属判据全假，
-- set_slot_mark 的 RPC 入口有 IsOpenedBy 例外能写进去，但同步路径没有 ——
-- 结果是标记落在服务端、客户端一帧都收不到，表现为「点了没反应」
chester.components.container.IsOpenedBy = function(_, who) return who == bob end
assert_equal(ISR.IsSharedMarkContainer(bob, chester), false, "a chester following alice is not shared with bob")
assert_equal(ISR.IsMarkContainerVisibleTo(bob, chester.GUID), true,
    "the player opening it must receive the push")
assert_equal(ISR.GetServerMarks(bob)[ISR.GetSlotKey(chester.GUID, 1)].prefab, "grass",
    "the opener's pickups route into that chester")
assert_equal(ISR.IsMarkContainerVisibleTo(alice, chester.GUID), true, "the leader still owns it")

print("test_shared_container ok")
