local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

unpack = table.unpack
ISR =
{
    GetSortedServerMarksForPrefab = function(owner, prefab)
        return owner.marks ~= nil and owner.marks[prefab] or {}
    end,
    GetServerMarks = function(owner) return owner.marks or {} end,
    GetStorageForMark = function(owner, mark)
        return owner.storages[mark.container_guid]
    end,
    GetStorageAdapter = function(storage)
        return storage.adapter
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_placement.lua")

local first = ISR.PushTransferContext({ source_guid = 1, target_guid = 2, reason = "shift_transfer" })
assert_equal(ISR.GetTransferContext(), first, "top transfer context")
ISR.PushTransferContext({ source_guid = 3, target_guid = 4, reason = "shift_transfer" })
assert_equal(ISR.GetTransferContext().source_guid, 3, "nested context shadows outer context")
ISR.PopTransferContext()
assert_equal(ISR.GetTransferContext().source_guid, 1, "pop restores outer context")
ISR.PopTransferContext()
assert_equal(ISR.GetTransferContext(), nil, "stack empties")

local ok = pcall(function()
    ISR.WithTransferContext({ source_guid = 5 }, function()
        error("expected test error")
    end)
end)
assert_equal(ok, false, "wrapped error is propagated")
assert_equal(ISR.GetTransferContext(), nil, "wrapped error still clears context")

local made = ISR.MakePlacementContext({ owner = {}, item = { prefab = "grass" } })
assert_equal(made.reason, "auto_place", "context has default reason")
local container_context = ISR.MakePlacementContext({ owner = {}, item = made.item, target_kind = "container" })
assert_equal(container_context.reason, "container_give", "container context has container reason")

local owner =
{
    marks =
    {
        grass =
        {
            { container_guid = 10, slot = 1, prefab = "grass", order = 1 },
            { container_guid = 20, slot = 2, prefab = "grass", order = 2 },
        },
    },
    storages = {},
}

local function NewStorage(guid)
    local storage = { guid = guid, placed = nil }
    storage.adapter =
    {
        GetGUID = function(_, value) return value.guid end,
        CanUseEmptySlot = function() return true end,
        PlaceInSlot = function(_, value, item, slot)
            value.placed = { item = item, slot = slot }
            return true
        end,
    }
    return storage
end

owner.storages[10] = NewStorage(10)
owner.storages[20] = NewStorage(20)
local item = { prefab = "grass", components = { inventoryitem = {} }, IsValid = function() return true end }
local placed = ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, item = item, source_guid = 10 }))
assert_equal(placed, true, "matching mark is placed")
assert_equal(owner.storages[10].placed, nil, "source storage is excluded")
assert_equal(owner.storages[20].placed.slot, 2, "next matching storage is used")

owner.marks.grass = {}
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, item = item })), false, "no marks passes through")

-- 装备类物品走的是同一条路：有没有标记只看 prefab
local spear = { prefab = "spear", components = { inventoryitem = {}, equippable = { equipslot = "hand" } }, IsValid = function() return true end }
owner.marks.spear = { { container_guid = 20, slot = 4, prefab = "spear", order = 1 } }
owner.storages[20].placed = nil
assert_equal(ISR.TryPlaceByMarks(ISR.MakePlacementContext({ owner = owner, item = spear })), true, "equippable item routes by prefab too")
assert_equal(owner.storages[20].placed.slot, 4, "equippable item lands in its reserved slot")
