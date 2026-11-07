local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local function assert_true(value, message)
    assert_equal(value, true, message)
end

local function assert_false(value, message)
    assert_equal(value, false, message)
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

local RoundBiasedUp = function(value) return math.floor(value + 0.5) end

local recipes =
{
    boards = { name = "boards", ingredients = { { type = "log", amount = 4 } } },
    tent = { name = "tent", ingredients = { { type = "log", amount = 6 }, { type = "twigs", amount = 4 } } },
}

local builder_postinit = nil
local builder_replica_postinit = nil
local client_rpc_handlers = {}

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
    RoundBiasedUp = RoundBiasedUp,
    GetValidRecipe = function(name) return recipes[name] end,
    TheWorld = { ismastersim = true },
    Prefabs = { log = true, twigs = true, cutstone = true, charcoal = true, silk = true },
    Ents = {},
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
    AddComponentPostInit = function(name, fn)
        if name == "builder" then
            builder_postinit = fn
        end
    end,
    AddPlayerPostInit = function() end,
    AddClassPostConstruct = function(package, fn)
        if package == "components/builder_replica" then
            builder_replica_postinit = fn
        end
    end,
    AddModRPCHandler = function() end,
    AddClientModRPCHandler = function(_, name, fn) client_rpc_handlers[name] = fn end,
    GetModRPC = function() return {} end,
    GetClientModRPC = function() return {} end,
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
load_module("scripts/isr_crafting.lua")

ISR = env.ISR
local MarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")

ISR.Config = { craft_from_container = true, container_range = "near" }

-- 实体桩 ----------------------------------------------------------------------

local player = { GUID = 1, userid = "KU_player", components = {} }
player.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
player.IsInLimbo = function() return false end

local chester = { GUID = 2, components = {} }
chester.Transform = { GetWorldPosition = function() return 5, 0, 0 end }
chester.IsInLimbo = function() return false end
chester.components.isr_slotmarkstore = MarkStore(chester)

-- 世界里的普通箱子，挨着玩家
local chest = { GUID = 3, components = {} }
chest.Transform = { GetWorldPosition = function() return 4, 0, 0 end }
chest.IsInLimbo = function() return false end
chest.components.isr_slotmarkstore = MarkStore(chest)

local function NewStackItem(prefab, owner, count)
    local item
    item =
    {
        prefab = prefab,
        IsValid = function() return true end,
        Remove = function() item.removed = (item.removed or 0) + 1 end,
        components =
        {
            inventoryitem = { GetOwner = function() return owner end },
            stackable =
            {
                size = count,
                StackSize = function() return item.components.stackable.size end,
                IsStack = function() return item.components.stackable.size > 1 end,
                SetStackSize = function(_, sz) item.components.stackable.size = sz end,
            },
        },
    }

    return item
end

-- 容器组件桩：够实现 Container:RemoveItem 的部分扣减 / 整格清空两条路径
local function NewContainerComp(inst)
    local comp
    comp =
    {
        inst = inst,
        slots = {},
        excludefromcrafting = nil,
        readonlycontainer = nil,
        GetItemInSlot = function(_, slot) return comp.slots[slot] end,
        IsOpenedBy = function() return false end,
        RemoveItem = function(_, item, wholestack)
            for slot, held in pairs(comp.slots) do
                if held == item then
                    local stackable = item.components.stackable
                    if stackable ~= nil and stackable:IsStack() and not wholestack then
                        local dec = NewStackItem(item.prefab, nil, 1)
                        stackable.size = stackable.size - 1
                        dec.removed = 0
                        return dec
                    end

                    comp.slots[slot] = nil
                    return item
                end
            end

            return item
        end,
    }

    return comp
end

chester.components.container = NewContainerComp(chester)
chest.components.container = NewContainerComp(chest)

local log_stack = NewStackItem("log", chester, 6)
chester.components.container.slots[3] = log_stack

local twig_stack = NewStackItem("twigs", chest, 2)
chest.components.container.slots[1] = twig_stack

-- 标记：切斯特第 3 格固定 log，箱子第 1 格固定 twigs
chester.components.isr_slotmarkstore:SetMark(3, "log")
chest.components.isr_slotmarkstore:SetMark(1, "twigs")

-- GUID 到实体的解析走 Ents 表
runtime_global.Ents[chester.GUID] = chester
runtime_global.Ents[chest.GUID] = chest

-- 物品栏桩：GetCraftingIngredient 返回原版找得到的（这里默认全空，代表包里没有）
player.components.inventory =
{
    GetCraftingIngredient = function() return {} end,
}

-- 供应收集 ----------------------------------------------------------------------

local function SupplyTotal(supply, prefab)
    local total = 0
    for _, entry in ipairs(supply[prefab] or {}) do
        total = total + entry.count
    end

    return total
end

local supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "log"), 6, "the marked log stack inside Chester is supply")
assert_equal(SupplyTotal(supply, "twigs"), 2, "the marked twig stack inside the chest is supply")

-- 距离挡住远处的箱子
chest.Transform = { GetWorldPosition = function() return 60, 0, 0 end }
supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "twigs"), 0, "an out-of-range chest is not supply")
chest.Transform = { GetWorldPosition = function() return 4, 0, 0 end }

-- 玩家打开着的容器交给原版，不进供应集合
chester.components.container.IsOpenedBy = function() return true end
supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "log"), 0, "an opened container is left to the vanilla path")
chester.components.container.IsOpenedBy = function() return false end

-- 格子里的物品和标记不符：不算
local foreign_item = NewStackItem("cutstone", chester, 3)
chester.components.container.slots[3] = foreign_item
supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "log"), 0, "a slot holding a foreign item is not supply")
assert_equal(SupplyTotal(supply, "cutstone"), 0, "unmarked items are not supply")
chester.components.container.slots[3] = log_stack

-- 材料补足 ----------------------------------------------------------------------

local function NewBuilderStub()
    return { inst = player, ingredientmod = 1, freebuildmode = false }
end

local materials = {}
ISR.FillIngredientsFromSupply(player, NewBuilderStub(), recipes.boards, materials)
assert_equal(materials.log[log_stack], 4, "the shortfall is filled from the container stack")

-- 物品栏里已有的部分不再重复要
local own_log = NewStackItem("log", player, 2)
materials = { log = { [own_log] = 2 } }
ISR.FillIngredientsFromSupply(player, NewBuilderStub(), recipes.boards, materials)
assert_equal(materials.log[log_stack], 2, "only the missing half is borrowed")
assert_equal(materials.log[own_log], 2, "inventory entries stay untouched")

-- 需求超过单堆：能借多少借多少
materials = {}
ISR.FillIngredientsFromSupply(player, NewBuilderStub(), recipes.tent, materials)
assert_equal(materials.log[log_stack], 6, "the whole marked stack is borrowed when needed")
assert_equal(materials.twigs[twig_stack], 2, "a short stack lends what it has")

-- 供应为空（箱子超出距离）的材料不动 materials
chest.Transform = { GetWorldPosition = function() return 60, 0, 0 end }
materials = {}
ISR.FillIngredientsFromSupply(player, NewBuilderStub(), recipes.tent, materials)
assert_equal(materials.twigs, nil, "no supply means no borrowed entries")
assert_equal(materials.log[log_stack], 6, "the Chester supply is unaffected by the distant chest")
chest.Transform = { GetWorldPosition = function() return 4, 0, 0 end }

-- 够不够的判定 ----------------------------------------------------------------------

assert_true(ISR.HasIngredientsWithSupply(player, NewBuilderStub(), recipes.boards),
    "4 logs craft from the closed Chester stack")
assert_false(ISR.HasIngredientsWithSupply(player, NewBuilderStub(), recipes.tent),
    "tent needs 6 logs + 4 twigs; supply has 6 + 2, so it cannot craft")
local half_inventory = { GetCraftingIngredient = function() return {} end }
player.components.inventory = half_inventory

materials = { log = { [own_log] = 2 } }
assert_false(ISR.HasIngredientsWithSupply(player, NewBuilderStub(), { name = "x", ingredients = { { type = "log", amount = 9 } } }),
    "2 in inventory + 6 supply is not enough for 9 logs")

-- 消费 ----------------------------------------------------------------------

-- 部分扣减：从切斯特那堆里扣 4，剩 2 且堆还在原格
materials = { log = { [log_stack] = 4 } }
ISR.ConsumeIngredientsFromContainers(player, materials)
assert_equal(log_stack.components.stackable.size, 2, "partial consumption leaves the stack in place")
assert_equal(chester.components.container.slots[3], log_stack, "the slot still holds the stack")
assert_equal(materials.log, nil, "container entries are removed from the map")

-- 整堆扣完：槽位清空，实体移除
materials = { log = { [log_stack] = 5 } }
ISR.ConsumeIngredientsFromContainers(player, materials)
assert_equal(chester.components.container.slots[3], nil, "an exhausted stack clears its slot")
assert_equal(log_stack.removed, 1, "the exhausted entity is removed once")

-- 玩家物品栏的条目留给原版
own_log = NewStackItem("log", player, 4)
materials = { log = { [own_log] = 4 } }
ISR.ConsumeIngredientsFromContainers(player, materials)
assert_equal(materials.log[own_log], 4, "inventory-owned entries pass through to the vanilla path")
assert_equal(own_log.removed, nil, "the vanilla path decides what happens to it")

-- 材料本身是容器：整件消耗前先倒空，别把里面的东西一起带走
local bag_item =
{
    prefab = "backpack",
    IsValid = function() return true end,
    components =
    {
        inventoryitem = { GetOwner = function() return chest end },
        container = { dropped = 0, DropEverything = function(self) self.dropped = self.dropped + 1 end },
    },
    Remove = function(self) self.removed = (self.removed or 0) + 1 end,
}
chest.components.container.slots[5] = bag_item
materials = { backpack = { [bag_item] = 1 } }
ISR.ConsumeIngredientsFromContainers(player, materials)
assert_equal(bag_item.components.container.dropped, 1, "container materials drop their contents first")
assert_equal(bag_item.removed, 1, "the container item itself is removed")
assert_equal(chest.components.container.slots[5], nil, "the slot is cleared")

-- builder 组件包装 ----------------------------------------------------------------------

-- 上面的消费测试把切斯特那堆扣光了，恢复夹具
chester.components.container.slots[3] = log_stack
log_stack.components.stackable.size = 6

local builder = NewBuilderStub()
local vanilla_saw = { has = nil, get = nil, remove = nil }

builder.HasIngredients = function(_, recipe)
    vanilla_saw.has = recipe.name
    return false
end
builder.GetIngredients = function(_, recname)
    vanilla_saw.get = recname
    return { log = {} }, false
end
builder.RemoveIngredients = function(_, ingredients)
    vanilla_saw.remove = {}
    for type_key, ents in pairs(ingredients) do
        vanilla_saw.remove[type_key] = ents
    end
end

assert_true(builder_postinit ~= nil, "the builder postinit was registered")
builder_postinit(builder)

-- HasIngredients：原版 false，供应补上后 true
assert_true(builder:HasIngredients(recipes.boards), "the wrapper fills the vanilla negative with supply")
assert_equal(vanilla_saw.has, "boards", "the vanilla check still ran first")

-- GetIngredients：materials 里出现容器实体
local filled, discounted = builder:GetIngredients("boards")
assert_equal(vanilla_saw.get, "boards", "the vanilla gather still ran first")
assert_equal(filled.log[log_stack], 4, "the container stack lands in the materials map")
assert_equal(discounted, false, "discounted flag passes through")

-- RemoveIngredients：容器条目被消费，原版收到空表
log_stack.components.stackable.size = 6
builder:RemoveIngredients({ log = { [log_stack] = 4 } })
assert_equal(vanilla_saw.remove.log, nil, "the vanilla path no longer sees the container entry")
assert_equal(log_stack.components.stackable.size, 2, "the container stack paid 4 logs")

-- 关掉开关后一切回落原版 ----------------------------------------------------------------------

ISR.Config.craft_from_container = false
log_stack.components.stackable.size = 6
assert_false(builder:HasIngredients(recipes.boards), "disabled config keeps the vanilla negative")
filled = builder:GetIngredients("boards")
assert_equal(filled.log[log_stack], nil, "disabled config does not borrow")
builder:RemoveIngredients({ log = { [log_stack] = 4 } })
assert_equal(log_stack.components.stackable.size, 6, "disabled config does not consume")
assert_equal(vanilla_saw.remove.log[log_stack], 4, "disabled config passes entries straight through")
ISR.Config.craft_from_container = true

-- 供应量同步（服务端推 → 客户端判定） ------------------------------------------------------

local rpc_sent = {}
env.SendModRPCToClient = function(_, userid, payload)
    rpc_sent[#rpc_sent + 1] = { userid = userid, payload = payload }
end

chester.components.container.slots[3] = log_stack
log_stack.components.stackable.size = 6
chest.components.container.slots[1] = twig_stack
twig_stack.components.stackable.size = 2

player._isr_craft_supply_payload = nil
ISR.PushCraftingSupply(player)
assert_equal(#rpc_sent, 1, "the first push sends the payload")
assert_equal(rpc_sent[1].userid, "KU_player", "the payload goes to the mark owner")
assert_equal(rpc_sent[1].payload, "log:6;twigs:2", "payload is sorted prefab:count pairs")

ISR.PushCraftingSupply(player)
assert_equal(#rpc_sent, 1, "an unchanged supply is not resent")

log_stack.components.stackable.size = 2
ISR.PushCraftingSupply(player)
assert_equal(#rpc_sent, 2, "a changed stack size is resent")
assert_equal(rpc_sent[2].payload, "log:2;twigs:2", "the new count is pushed")

-- 客户端收包：解析成 prefab -> 数量
assert_true(client_rpc_handlers[ISR.RPC_SYNC_SUPPLY] ~= nil, "the client supply handler is registered")
client_rpc_handlers[ISR.RPC_SYNC_SUPPLY]("log:6;twigs:2")
assert_equal(ISR._craft_supply.log, 6, "log count parsed")
assert_equal(ISR._craft_supply.twigs, 2, "twigs count parsed")
client_rpc_handlers[ISR.RPC_SYNC_SUPPLY]("")
assert_equal(ISR._craft_supply.log, nil, "an empty payload clears the cache")

-- 客户端配方判定：物品栏不够时用同步来的数量补
local client_builder =
{
    IngredientMod = function() return 1 end,
    HasCharacterIngredient = function() return true end,
    HasTechIngredient = function() return true end,
}

local function NewClientPlayer(counts)
    counts = counts or {}
    return { replica = { inventory = { Has = function(_, prefab, amount)
        local have = counts[prefab] or 0
        return have >= amount, have
    end } } }
end

ISR._craft_supply = { log = 4 }
assert_true(ISR.HasIngredientsWithClientSupply(NewClientPlayer(), client_builder, recipes.boards),
    "the synced supply covers the whole recipe")

ISR._craft_supply = { log = 3 }
assert_false(ISR.HasIngredientsWithClientSupply(NewClientPlayer(), client_builder, recipes.boards),
    "three borrowed logs cannot cover four")

ISR._craft_supply = { log = 3 }
assert_true(ISR.HasIngredientsWithClientSupply(NewClientPlayer({ log = 1 }), client_builder, recipes.boards),
    "inventory and supply add up")

ISR._craft_supply = {}
assert_false(ISR.HasIngredientsWithClientSupply(NewClientPlayer({ log = 5 }), client_builder, recipes.tent),
    "plenty of logs without twigs still fails")

-- 配方里一条同步材料都没有时走快速判负：连 inventory:Has 都不该调
local has_calls = 0
local counting_player =
{
    replica = { inventory = { Has = function() has_calls = has_calls + 1 return false, 0 end } },
}
ISR._craft_supply = { cutstone = 2 }
assert_false(ISR.HasIngredientsWithClientSupply(counting_player, client_builder, recipes.boards),
    "a recipe with no supplied ingredient is a fast negative")
assert_equal(has_calls, 0, "the fast path never touches inventory:Has")

-- builder_replica 包装：原版判负后由同步数量补
assert_true(builder_replica_postinit ~= nil, "the builder_replica postinit was registered")

local replica_inst = NewClientPlayer({})
local replica_builder =
{
    inst = replica_inst,
    classified = {},
    IngredientMod = client_builder.IngredientMod,
    HasCharacterIngredient = client_builder.HasCharacterIngredient,
    HasTechIngredient = client_builder.HasTechIngredient,
    HasIngredients = function() return false end,
}
builder_replica_postinit(replica_builder)

ISR._craft_supply = { log = 4 }
assert_true(replica_builder:HasIngredients(recipes.boards), "the client tile lights up from the synced supply")

ISR._craft_supply = {}
assert_false(replica_builder:HasIngredients(recipes.boards), "no supply keeps the vanilla negative")

-- 房主实体上有真 builder 组件，交给服务端 hook，客户端不重复判
ISR._craft_supply = { log = 4 }
replica_inst.components = { builder = {} }
assert_false(replica_builder:HasIngredients(recipes.boards), "host entities defer to the server-side hook")

-- 借料点亮配方时静音 pinbar 的 recipe_ready；窗口过了照常响
local fake_now = 100
runtime_global.GetTime = function() return fake_now end
ISR._craft_supply = { log = 4 }
assert_false(ISR.ShouldMuteRecipeReady(), "nothing borrowed yet means no mute")
assert_true(ISR.HasIngredientsWithClientSupply(NewClientPlayer(), client_builder, recipes.boards),
    "supply covers the recipe again")
assert_true(ISR.ShouldMuteRecipeReady(), "a fresh supply flip mutes the recipe ping")
fake_now = 101
assert_false(ISR.ShouldMuteRecipeReady(), "the mute window expires")

-- 提示音配置：silent 永远静音，original 永远不静音
ISR.Config.craft_ping = "silent"
assert_true(ISR.ShouldMuteRecipeReady(), "silent mode mutes regardless of timing")
ISR.Config.craft_ping = "original"
assert_false(ISR.ShouldMuteRecipeReady(), "original mode never mutes")
ISR.Config.craft_ping = "borrow"

-- 材料行显示（0.1.8）：原版用 inventory:Has 的 num_found 画「有/需」，
-- 借料的材料要算进去，否则界面显示「1/2」红字，玩家以为做不了
ISR._craft_supply = { log = 3 }
local base_Has = function(_, prefab, amount)
    if prefab == "log" then
        return false, 1
    end
    return true, amount
end
local fake_inventory = { Has = base_Has }

local observed
local fake_SetRecipe = function()
    observed = { fake_inventory:Has("log", 4, true) }
end
ISR.WithSupplyAwareInventory(fake_inventory, fake_SetRecipe, {}, {})

assert_true(observed[1], "borrowed supply makes the ingredient show as enough")
assert_equal(observed[2], 4, "the shown count includes the borrowable supply")
assert_equal(fake_inventory.Has, base_Has, "Has is restored after the recipe is built")

-- 供应不够时仍然判负，但数字要显示真实可用量（1 + 2 = 3 / 4）
ISR._craft_supply = { log = 2 }
ISR.WithSupplyAwareInventory(fake_inventory, fake_SetRecipe, {}, {})
assert_false(observed[1], "not enough supply still reports short")
assert_equal(observed[2], 3, "short case shows what is actually available")

-- 已经够的材料不受影响
ISR._craft_supply = { log = 3 }
local enough
ISR.WithSupplyAwareInventory(fake_inventory, function()
    enough = { fake_inventory:Has("twigs", 5, true) }
end, {}, {})
assert_true(enough[1], "already satisfied ingredients stay satisfied")
assert_equal(enough[2], 5, "already satisfied count is untouched")

-- 原版 SetRecipe 抛错时也要还原 Has，别把坏掉的包装留在实例上
local ok = pcall(ISR.WithSupplyAwareInventory, fake_inventory, function() error("boom") end, {}, {})
assert_false(ok, "errors from the wrapped call are re-raised")
assert_equal(fake_inventory.Has, base_Has, "Has is restored even when the recipe build fails")

ISR._craft_supply = nil
ISR.Config.craft_from_container = true

-- WX-78 的拓展储物箱：inventoryitem + container，锁在物品栏格，不是 BODY 背包
-- 原版 Inventory:Has 只扫物品栏物品本身和 overflow（BODY 背包），箱子里面的货它看不到
local wxbox = { GUID = 4, components = {} }
wxbox.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
wxbox.IsInLimbo = function() return false end
wxbox.components.inventoryitem = { GetGrandOwner = function() return player end, GetOwner = function() return player end }
wxbox.components.container = NewContainerComp(wxbox)
wxbox.components.isr_slotmarkstore = MarkStore(wxbox)
local coal_stack = NewStackItem("charcoal", wxbox, 5)
wxbox.components.container.slots[2] = coal_stack
wxbox.components.isr_slotmarkstore:SetMark(2, "charcoal")
runtime_global.Ents[wxbox.GUID] = wxbox

supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "charcoal"), 5, "a container carried in the inventory slot is supply")

-- BODY 背包是原版 overflow，原版已经算进 materials，这里必须排除
local backpack = { GUID = 5, components = {} }
backpack.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
backpack.IsInLimbo = function() return false end
backpack.components.inventoryitem = { GetGrandOwner = function() return player end, GetOwner = function() return player end }
backpack.components.container = NewContainerComp(backpack)
backpack.components.isr_slotmarkstore = MarkStore(backpack)
backpack.components.container.slots[1] = NewStackItem("silk", backpack, 4)
backpack.components.isr_slotmarkstore:SetMark(1, "silk")
runtime_global.Ents[backpack.GUID] = backpack

local base_overflow = player.components.inventory.GetOverflowContainer
player.components.inventory.GetOverflowContainer = function() return backpack.components.container end
supply = ISR.GetCraftingSupply(player)
assert_equal(SupplyTotal(supply, "silk"), 0, "the body backpack is left to the vanilla path")
player.components.inventory.GetOverflowContainer = base_overflow

print("PASS test_crafting")
