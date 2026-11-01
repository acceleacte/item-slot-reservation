local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

unpack = table.unpack

local pickup_sounds = {}
local owner_guid = 100

ISR =
{
    Config = { pickup_to_container = true },
    GetSortedServerMarksForPrefab = function(owner, prefab)
        return owner.marks ~= nil and owner.marks[prefab] or {}
    end,
    GetServerMarks = function(owner) return owner.marks or {} end,
    GetStorageForMark = function(owner, mark)
        return owner.storages[mark.container_guid]
    end,
    GetStorageAdapter = function(storage)
        return storage ~= nil and storage.adapter or nil
    end,
    PlayPickupSound = function(owner, item)
        table.insert(pickup_sounds, item.prefab)
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_placement.lua")

local function NewStorage(guid, kind)
    local storage = { guid = guid, placed = nil }
    storage.adapter =
    {
        GetGUID = function(_, value) return value.guid end,
        CanUseEmptySlot = function() return true end,
        PlaceInSlot = function(_, value, item, slot)
            if kind == "inventory" then
                return "inventory", slot
            end
            value.placed = { item = item, slot = slot }
            return true
        end,
    }
    return storage
end

local function NewItem(prefab)
    return { prefab = prefab, components = { inventoryitem = {} }, IsValid = function() return true end }
end

-- 玩家身上一格（order 更早）和切斯特一格（order 更晚）固定了同一种物品
local owner = { GUID = owner_guid, storages = {} }
owner.storages[owner_guid] = NewStorage(owner_guid, "inventory")
owner.storages[900] = NewStorage(900, "container")

local chesterslot = { container_guid = 900, slot = 6, prefab = "beargerfur_sack", order = 1 }
local inventoryslot = { container_guid = owner_guid, slot = 8, prefab = "beargerfur_sack", order = 2 }
owner.marks = { beargerfur_sack = { inventoryslot, chesterslot } }

local sack = NewItem("beargerfur_sack")
local inventory = { inst = owner }

-- 默认开启：容器里的固定格优先，即使它的 order 更晚
local context = ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = sack })
local result, slot = ISR.TryPlaceByMarks(context)
assert_equal(result, true, "container mark wins when pickup_to_container is on")
assert_equal(owner.storages[900].placed.slot, 6, "item lands in the container slot")
assert_equal(owner.storages[900].placed.item, sack, "the picked up item is the one moved")
assert_equal(#pickup_sounds, 1, "placing into a container plays the pickup sound")
assert_equal(pickup_sounds[1], "beargerfur_sack", "the sound follows the item prefab")

-- 关掉开关：容器标记不参与，物品回玩家物品栏的固定格
ISR.Config.pickup_to_container = false
owner.storages[900].placed = nil
pickup_sounds = {}
local off_context = ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = sack })
local off_result, off_slot = ISR.TryPlaceByMarks(off_context)
assert_equal(off_result, "inventory", "inventory mark is used when the option is off")
assert_equal(off_slot, 8, "the player's own fixed slot is chosen")
assert_equal(owner.storages[900].placed, nil, "the container is left alone")
assert_equal(#pickup_sounds, 0, "the inventory adapter does not play a pickup sound")

-- 只有容器标记时，关掉开关就不再自动吸进容器
owner.marks.beargerfur_sack = { chesterslot }
ISR.Config.pickup_to_container = false
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = sack })), false,
    "container-only marks are ignored while the option is off")

-- 重新打开后回到容器
ISR.Config.pickup_to_container = true
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = sack })), true,
    "container marks apply again once the option is back on")

-- 容器自己给物品（STORE / 掉落）不是拾取，不能响
owner.marks.beargerfur_sack = { inventoryslot, chesterslot }
owner.storages[900].placed = nil
pickup_sounds = {}
local container_side = ISR.MakePlacementContext({
    owner = owner,
    item = sack,
    target_container = owner.storages[900],
    target_kind = "container",
    target_guid = 900,
})
assert_equal(ISR.TryPlaceByMarks(container_side), true, "container-side give still places by marks")
assert_equal(#pickup_sounds, 0, "container-side give does not fake a pickup sound")

-- 固定格里已经有同类未满堆时（采草、砍树枝最常见的场景），
-- 适配器的 CanUseSlot 优先于 CanUseEmptySlot，资源要并进那一堆
local stacking_storage = { guid = 901 }
stacking_storage.adapter =
{
    GetGUID = function(_, value) return value.guid end,
    CanUseEmptySlot = function() return false end,
    CanUseSlot = function(_, _, item, slot) return item.prefab == "cutgrass" and slot == 2 end,
    PlaceInSlot = function(_, value, item, slot)
        value.placed = { item = item, slot = slot }
        return true
    end,
}
owner.storages[901] = stacking_storage
owner.marks.cutgrass = { { container_guid = 901, slot = 2, prefab = "cutgrass", order = 3 } }
pickup_sounds = {}
local grass = NewItem("cutgrass")
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = grass })), true,
    "a slot holding the same partial stack is used even though it is not empty")
assert_equal(stacking_storage.placed.slot, 2, "grass merges into the fixed container slot")
assert_equal(#pickup_sounds, 1, "merging into a container still plays the pickup sound")

-- 距离不够时容器固定格不参与（否则站在地图另一头也能把东西送进基地箱子）
ISR.GetContainerRangeLimit = function() return 10 end
ISR.IsStorageWithinRange = function() return false end
owner.marks.cutgrass = { { container_guid = 901, slot = 2, prefab = "cutgrass", order = 4 } }
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = grass })), false,
    "an out-of-range container is skipped")

ISR.IsStorageWithinRange = function() return true end
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, inventory = inventory, item = grass })), true,
    "the same container is used once the player is close enough")
