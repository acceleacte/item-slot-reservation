local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local ents = {}
local component_callbacks = {}
AddComponentPostInit = function(name, callback) component_callbacks[name] = callback end
AddPlayerPostInit = function() end
TheWorld = { ismastersim = true }

ISR =
{
    GetGlobalValue = function(name, fallback)
        return name == "TheWorld" and TheWorld or fallback
    end,
    GetEntitiesTable = function() return ents end,
    GetLocalPlayer = function() return nil end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_storage.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_markstores.lua")

local function LinkOwner(item, owner)
    local inventoryitem = item.components.inventoryitem
    inventoryitem.owner = owner
    inventoryitem.GetGrandOwner = function(self)
        return self.owner
            and self.owner.components
            and self.owner.components.inventoryitem
            and self.owner.components.inventoryitem:GetGrandOwner()
            or self.owner
    end
end

local function NewItem(guid, capacity)
    local inst =
    {
        GUID = guid,
        components = { inventoryitem = {}, container = { slots = {} } },
    }
    inst.components.container.GetNumSlots = function() return capacity or 6 end
    inst.components.container.GetItemInSlot = function(_, slot)
        return inst.components.container.slots[slot]
    end
    ents[guid] = inst
    return inst
end

local player = { GUID = 1, components = {} }
player.components.inventory = { inst = player, itemslots = {}, equipslots = {} }

local backpack = NewItem(10, 6)
local sack = NewItem(11, 9)
local ground_sack = NewItem(12, 9)
local foreign_sack = NewItem(13, 9)

LinkOwner(backpack, player)
LinkOwner(sack, backpack)
LinkOwner(foreign_sack, { GUID = 99, components = {} })

player.components.inventory.equipslots.back = backpack
backpack.components.container.slots[3] = sack
ents[11] = sack

-- 服务端：背包里的桶算随身容器，地上的不算
assert_equal(ISR.IsMarkableContainerForPlayer(player, player.GUID), true, "player itself is markable")
assert_equal(ISR.IsMarkableContainerForPlayer(player, 10), true, "equipped backpack is markable")
assert_equal(ISR.IsMarkableContainerForPlayer(player, 11), true, "sack inside the backpack is markable")
assert_equal(ISR.IsMarkableContainerForPlayer(player, 12), false, "sack on the ground is not markable")
assert_equal(ISR.IsMarkableContainerForPlayer(player, 13), false, "sack owned by someone else is not markable")

-- 随身实例枚举要递归进背包
local names = {}
for _, inst in ipairs(ISR.GetPersonalStorageInstances(player)) do
    names[inst.GUID] = true
end
assert_equal(names[1], true, "player is listed")
assert_equal(names[10], true, "backpack is listed")
assert_equal(names[11], true, "sack inside the backpack is listed")
assert_equal(names[12], nil, "ground sack is not listed")

-- 客户端：按 replica 容器树判定，打开过的桶才在树里
local client_player =
{
    GUID = 100,
    replica = { inventory = {} },
}
local client_backpack = { GUID = 200, replica = {} }
local client_sack = { GUID = 201, replica = {} }
local client_foreign = { GUID = 202, replica = {} }

client_player.replica.inventory.GetItems = function() return { [1] = client_backpack } end
client_player.replica.inventory.GetEquips = function() return {} end
client_backpack.replica.container =
{
    GetNumSlots = function() return 6 end,
    GetItemInSlot = function(_, slot) return slot == 3 and client_sack or nil end,
}
client_sack.replica.container =
{
    GetNumSlots = function() return 9 end,
    GetItemInSlot = function() return nil end,
}
client_sack.inst = client_sack
client_backpack.inst = client_backpack

ISR.GetLocalPlayer = function() return client_player end

assert_equal(ISR.IsClientMarkableContainerInst(client_player), true, "client: player itself is markable")
assert_equal(ISR.IsClientMarkableContainerInst(client_backpack), true, "client: backpack is markable")
assert_equal(ISR.IsClientMarkableContainerInst(client_sack), true, "client: sack inside the backpack is markable")
assert_equal(ISR.IsClientMarkableContainerInst(client_foreign), false, "client: unrelated container is not markable")
assert_equal(ISR.IsClientMarkableSlot({ num = 1, container = client_sack }), true,
    "client: a slot inside the nested sack is markable")

-- 跟随型容器（切斯特、哈奇）：跟谁就算谁的，不看 prefab 名单
local chester =
{
    GUID = 20,
    components =
    {
        follower = { GetLeader = function() return player end },
        container = { slots = {} },
    },
}
ents[20] = chester
assert_equal(ISR.IsMarkableContainerForPlayer(player, 20), true, "follower container of this player is markable")

local other_player = { GUID = 2, components = {} }
other_player.components.inventory = { inst = other_player, itemslots = {}, equipslots = {} }
assert_equal(ISR.IsMarkableContainerForPlayer(other_player, 20), false,
    "follower container of another player is not markable")

-- 切斯特身上的背包：owner 链终点是切斯特，而切斯特跟随玩家
local chester_bag = NewItem(21, 6)
LinkOwner(chester_bag, chester)
ents[21] = chester_bag
assert_equal(ISR.IsMarkableContainerForPlayer(player, 21), true,
    "bag carried by the player's follower is markable")
assert_equal(ISR.IsMarkableContainerForPlayer(other_player, 21), false,
    "bag carried by another player's follower is not markable")

-- 客户端：follower replica 直接给出 leader
local client_chester =
{
    GUID = 210,
    replica = { follower = { GetLeader = function() return client_player end } },
}
assert_equal(ISR.IsClientMarkableContainerInst(client_chester), true,
    "client: follower container of this player is markable")

-- 客户端兜底：inventoryitem replica 不带 owner，只要容器开着就先放行，服务端裁决
local opened_unknown = { GUID = 220, replica = { container = { GetNumSlots = function() return 9 end } } }
assert_equal(ISR.IsClientMarkableContainerInst(opened_unknown), true,
    "client: an open container is passed through to the server")
local closed_unknown = { GUID = 221, replica = { container = { GetNumSlots = function() return 0 end } } }
assert_equal(ISR.IsClientMarkableContainerInst(closed_unknown), false,
    "client: a container with no data is rejected locally")
