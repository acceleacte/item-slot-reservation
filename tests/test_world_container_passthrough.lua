local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { inventory = {}, container = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end

local policy_calls = 0
ISR =
{
    ResolvePlayerStorageOwner = function() return nil end,
    MakePlacementContext = function()
        policy_calls = policy_calls + 1
        return {}
    end,
    TryPlaceByMarks = function()
        policy_calls = policy_calls + 1
        return false
    end,
    ShouldReserveMarkedSlotsForItem = function()
        policy_calls = policy_calls + 1
        return false
    end,
    ClearServerSlotMarkIfItemMismatches = function()
        policy_calls = policy_calls + 1
    end,
    WithTransferContext = function(_, fn, ...)
        return fn(...)
    end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

local player =
{
    components = { inventory = {} },
    HasTag = function(_, tag) return tag == "player" end,
}
local received = nil
local container =
{
    inst = { GUID = 88, components = {} },
    openlist = { [player] = true },
    GiveItem = function(_, item, slot, src_pos, drop_on_fail)
        received = { item, slot, src_pos, drop_on_fail }
        return true
    end,
}

for _, callback in ipairs(callbacks.container) do
    callback(container)
end

local item = { prefab = "task_item" }
assert_equal(container:GiveItem(item, 1, "task", false), true, "world container preserves GiveItem result")
assert_equal(received[1], item, "world container preserves item")
assert_equal(received[2], 1, "world container preserves slot")
assert_equal(received[3], "task", "world container preserves source position")
assert_equal(received[4], false, "world container preserves drop behavior")
assert_equal(policy_calls, 0, "opened world container does not run ISR placement policy")
