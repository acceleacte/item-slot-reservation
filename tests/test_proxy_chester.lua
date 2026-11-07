-- 代理容器（暗影切斯特）与雪切斯特的存储适配
--
-- 原版 chester.lua 的三种形态：
--   NORMAL / SNOW —— SwitchToContainer：实体上有 container 组件（WidgetSetup "chester"）
--   SHADOW        —— SwitchToShadowContainerProxy：RemoveComponent("container")，
--                    物品搬进 TheWorld:GetPocketDimensionContainer("shadow")，
--                    实体上只剩 container_proxy（读档时 OnLoadPostPass 也会再切一次）
--
-- 后果：标记仍然挂在切斯特实体的 isr_slotmarkstore 上，但 components.container 为 nil，
-- 借料、自动归位、共享容器判定全部拿不到容器（2026-11-07 实测：升级暗影切斯特后借料失效）

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

local rpc_handlers = {}

local runtime_global =
{
    error = error,
    next = next,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    unpack = table.unpack,
    xpcall = xpcall,
    Prefabs = { nightmarefuel = true, ice = true },
    RoundBiasedUp = function(n) return math.ceil(n) end,
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
    AddModRPCHandler = function(namespace, name, fn) rpc_handlers[name] = fn end,
    AddClientModRPCHandler = function() end,
    AddClassPostConstruct = function() end,
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
load_module("scripts/isr_crafting.lua")

local ISR = env.ISR

-- isr_persistence 没在本测试里加载，标记同步给它一个空实现
ISR.SyncMarkToClient = ISR.SyncMarkToClient or function() end
local MarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

local function MakeContainer(slot_count)
    return
    {
        slots = {},
        GetNumSlots = function() return slot_count end,
        GetItemInSlot = function(self, slot) return self.slots[slot] end,
        CanTakeItemInSlot = function() return true end,
        RemoveItem = function() return nil end,
        GiveItem = function() return true end,
    }
end

local player = { GUID = 11, userid = "KU_player", components = { inventory = {} } }

-- 口袋维度容器：真身，位置无意义
local pocket_container = MakeContainer(12)
local pocket = { GUID = 950, components = { container = pocket_container } }
pocket_container.inst = pocket

-- 暗影切斯特：只有 container_proxy，没有 container 组件
local shadow_chester =
{
    GUID = 902,
    components =
    {
        container_proxy = { GetMaster = function() return pocket end },
        follower = { GetLeader = function() return player end },
    },
}
shadow_chester.components.isr_slotmarkstore = MarkStore(shadow_chester)
shadow_chester.components.isr_slotmarkstore:SetMark(9, "nightmarefuel", 110)

-- 雪切斯特：普通 container 组件，WidgetSetup 换掉而已
local snow_chester = { GUID = 903, components = {} }
snow_chester.components.container = MakeContainer(9)
snow_chester.components.container.inst = snow_chester
snow_chester.components.follower = { GetLeader = function() return player end }
snow_chester.components.isr_slotmarkstore = MarkStore(snow_chester)
snow_chester.components.isr_slotmarkstore:SetMark(2, "ice", 120)

ISR._mark_containers =
{
    [shadow_chester.GUID] = shadow_chester,
    [snow_chester.GUID] = snow_chester,
}

runtime_global.Ents =
{
    [shadow_chester.GUID] = shadow_chester,
    [snow_chester.GUID] = snow_chester,
    [pocket.GUID] = pocket,
}

-- 容器组件解引用 ---------------------------------------------------------------
assert_equal(ISR.GetContainerComponent(shadow_chester), pocket_container, "the shadow chester resolves to the pocket container")
assert_equal(ISR.GetContainerComponent(snow_chester), snow_chester.components.container, "the snow chester keeps its own container")
assert_equal(ISR.GetContainerComponent(player), nil, "the player has no container component")

-- 存储适配：GUID 仍按外层实体算，物品操作走真容器
local shadow_storage, shadow_adapter = ISR.GetStorageFromEntity(shadow_chester)
assert_equal(shadow_storage, pocket_container, "the shadow chester exposes the pocket container")
assert_equal(shadow_adapter:GetGUID(shadow_storage), shadow_chester.GUID, "the storage guid is the chester's, not the pocket entity's")
assert_equal(shadow_adapter:GetSlotCount(shadow_storage), 12, "the shadow container keeps its slot count")

local snow_storage, snow_adapter = ISR.GetStorageFromEntity(snow_chester)
assert_equal(snow_storage, snow_chester.components.container, "the snow chester exposes its own container")
assert_equal(snow_adapter:GetGUID(snow_storage), snow_chester.GUID, "the snow storage guid is its own")

-- 共享容器判定：暗影切斯特有 follower，跟随别人时对第三者不算共享
assert_equal(ISR.IsSharedMarkContainer(player, shadow_chester), true, "the leader can use his shadow chester")
assert_equal(ISR.IsSharedMarkContainer({ GUID = 12, userid = "KU_other", components = {} }, shadow_chester), false,
    "another player does not get the shadow chester")

-- 标记枚举：标记在外层实体上，物品在真容器里，两条都要成立
local marks = ISR.GetServerMarks(player)
assert_equal(marks[ISR.GetSlotKey(shadow_chester.GUID, 9)].prefab, "nightmarefuel",
    "the shadow chester mark stays on the chester guid")

-- 借料：标记格里真有货时必须算进供应
local fuel =
{
    prefab = "nightmarefuel",
    IsValid = function() return true end,
    components =
    {
        inventoryitem = {},
        stackable = { StackSize = function() return 40 end },
    },
}
pocket_container.slots[9] = fuel

local supply = ISR.GetCraftingSupply(player)
assert_equal(#(supply.nightmarefuel or {}), 1, "the shadow chester supplies its pinned slot")
assert_equal(supply.nightmarefuel[1].count, 40, "the supply carries the whole stack")

local snow_supply_item =
{
    prefab = "ice",
    IsValid = function() return true end,
    components =
    {
        inventoryitem = {},
        stackable = { StackSize = function() return 20 end },
    },
}
snow_chester.components.container.slots[2] = snow_supply_item
snow_chester.components.container.GetItemInSlot = function(self, slot) return self.slots[slot] end

supply = ISR.GetCraftingSupply(player)
assert_equal(#(supply.ice or {}), 1, "the snow chester supplies its pinned slot too")
assert_equal(supply.ice[1].count, 20, "the snow supply carries the whole stack")

-- 客户端打开暗影切斯特时，容器 UI 绑在口袋维度实体上，标记会按它的 GUID 落库
pocket.components.isr_slotmarkstore = MarkStore(pocket)
pocket.components.isr_slotmarkstore:SetMark(3, "nightmarefuel", 130)
ISR._mark_containers[pocket.GUID] = pocket
pocket_container.slots[3] = fuel

pocket.Transform = { GetWorldPosition = function() return 5000, 0, 5000 end }
shadow_chester.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
player.Transform = { GetWorldPosition = function() return 0, 0, 0 end }

supply = ISR.GetCraftingSupply(player)
assert_equal(#(supply.nightmarefuel or {}), 2, "both pinned slots count, the pocket mark included")

-- 同一个物理格被两套标记指向时只算一次
pocket.components.isr_slotmarkstore:SetMark(9, "nightmarefuel", 131)
supply = ISR.GetCraftingSupply(player)
assert_equal(#(supply.nightmarefuel or {}), 2, "the same physical slot is counted once")

-- 距离按外层实体算：口袋维度实体没有有用的世界坐标，不能拿它当锚点
local far_position = { Transform = { GetWorldPosition = function() return 1000, 0, 1000 end } }
shadow_chester.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
player.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
assert_equal(ISR.IsStorageWithinRange(player, shadow_storage, 24), true,
    "the range is measured from the chester, not the pocket entity")

player.Transform = far_position.Transform
assert_equal(ISR.IsStorageWithinRange(player, shadow_storage, 24), false,
    "a far away chester is out of range")

-- 清除时连带清另一侧同格：否则界面上框没了，借料还在按旧标记供料
pocket.components.isr_slotmarkstore:SetMark(5, "nightmarefuel", 140)
shadow_chester.components.isr_slotmarkstore:SetMark(5, "nightmarefuel", 141)
ISR.ClearContainerSlotMarkOnMismatch(pocket, 5, { prefab = "log" })
assert_equal(pocket.components.isr_slotmarkstore:GetMark(5), nil, "the opened side loses its mark")
assert_equal(shadow_chester.components.isr_slotmarkstore:GetMark(5), nil, "the proxy twin loses it too")

-- 打开口径 ---------------------------------------------------------------
-- 口袋维度容器是 CLASSIFIED + entity:Hide()，客户端 GetOpenContainers 用
-- entity:IsVisible() 过滤，永远拿不到 → 客户端原版统计给 0
-- 服务端口径必须排除（原版已把物品填进 materials，再填一次是重复扣料）
-- 客户端口径必须保留（否则打开暗影切斯特时配方整片灰，关掉才亮）
player.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
pocket.tags = { pocketdimension_container = true }
pocket.HasTag = function(self, tag) return self.tags ~= nil and self.tags[tag] == true end
pocket_container.IsOpenedBy = function(_, doer) return doer == player end

local server_supply = ISR.GetCraftingSupply(player)
assert_equal(#(server_supply.nightmarefuel or {}), 0, "服务端口径排除打开中的口袋容器")

local client_supply = ISR.GetCraftingSupply(player, true)
assert_equal(#(client_supply.nightmarefuel or {}), 2, "客户端口径保留客户端数不到的口袋容器")

-- 普通容器打开时客户端口径也全收，由客户端自己扣掉「已经数到的那部分」
-- 服务端不知道哪台客户端数得到、哪台数不到（WX 储物箱锁在物品栏格、多人共开时
-- classified 不发给任何人），猜类型必然错一个，所以不在服务端这一步做减法
snow_chester.components.container.IsOpenedBy = function(_, doer) return doer == player end
client_supply = ISR.GetCraftingSupply(player, true)
assert_equal(#(client_supply.ice or {}), 1, "客户端口径全收，普通容器也收")

-- 设置时双写：只写一侧会出现「开着看有框、关掉借不到料」
assert(rpc_handlers[ISR.RPC_SET_MARK] ~= nil, "set mark rpc handler is registered")
rpc_handlers[ISR.RPC_SET_MARK](player, pocket, 4, "nightmarefuel")
assert_equal(pocket.components.isr_slotmarkstore:GetMark(4).prefab, "nightmarefuel",
    "打开的口袋实体拿到标记")
assert_equal(shadow_chester.components.isr_slotmarkstore:GetMark(4).prefab, "nightmarefuel",
    "切斯特实体同步写入同一条标记")

-- 宿主映射不能只靠「有标记的容器」反查：容器没标记就不在注册表里，
-- 距离判定会退化成口袋维度实体的坐标（0,0,0），标记全部 :range 失败
ISR._mark_containers = { [pocket.GUID] = pocket }
ISR._proxy_owners[pocket.GUID] = nil
ISR._proxy_hosts[pocket.GUID] = shadow_chester
assert_equal(ISR.GetProxyOwner(pocket), shadow_chester, "宿主映射直接命中，不依赖标记注册表")
assert_equal(ISR.IsStorageWithinRange(player, pocket_container, 24), true, "距离按切斯特算，不是口袋实体")

-- 客户端判定：原版 count 里已经数到的打开容器部分必须扣掉，
-- 否则 count + supply 会把同一批货算两遍，客户端高估、点了被服务端拒
local open_inst = { replica = { container = { Has = function() return false, 6 end } } }
local client_inventory =
{
    Has = function() return false, 6 end,
    GetOpenContainers = function() return { [open_inst] = true } end,
    GetOverflowContainer = function() return nil end,
}
local client_player = { GUID = 31, replica = { inventory = client_inventory } }
local fake_builder = { IngredientMod = function() return 1 end }
ISR._craft_supply = { ice = 20 }

-- 需要 25：真实可用只有 6（打开容器里客户端已数到的）+ (20-6)（supply 扣掉重复）= 20
assert_equal(
    ISR.HasIngredientsWithClientSupply(client_player, fake_builder, { ingredients = { { type = "ice", amount = 25 } } }),
    false,
    "同一批货算两遍会让客户端高估")

-- 需要 18：20 ≥ 18，应判可合成
assert_equal(
    ISR.HasIngredientsWithClientSupply(client_player, fake_builder, { ingredients = { { type = "ice", amount = 18 } } }),
    true,
    "扣掉重复之后仍然够")

-- store 回退：标记只落在一侧时，按另一侧的 GUID 查也要读到
shadow_chester.components.isr_slotmarkstore:SetMark(7, "nightmarefuel", 150)
local saved_pocket_store = pocket.components.isr_slotmarkstore
pocket.components.isr_slotmarkstore = nil
assert_equal(
    ISR.GetSlotMarkStoreForGUID(player, pocket.GUID, false),
    shadow_chester.components.isr_slotmarkstore,
    "按口袋实体查标记时回退到切斯特的 store")
pocket.components.isr_slotmarkstore = saved_pocket_store

-- 同一个物理容器的两副面孔算同一个目标
assert_equal(ISR.IsSameStorage(pocket.GUID, shadow_chester.GUID), true,
    "口袋实体与切斯特是同一个容器")
assert_equal(ISR.IsSameStorage(pocket.GUID, snow_chester.GUID), false,
    "不同容器不算同一个")

print("test_proxy_chester ok")
