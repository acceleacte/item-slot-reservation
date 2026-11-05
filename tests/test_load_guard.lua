local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local callbacks = { container = {}, inventory = {} }
AddComponentPostInit = function(name, callback)
    table.insert(callbacks[name], callback)
end
AddPlayerPostInit = function() end
TheWorld = { ismastersim = true }

local cleared = 0
ISR =
{
    GetGlobalValue = function(name, fallback)
        return name == "TheWorld" and TheWorld or fallback
    end,
    EnsureSlotMarkStore = function(inst)
        inst.components.isr_slotmarkstore = inst.components.isr_slotmarkstore or {}
        return inst.components.isr_slotmarkstore
    end,
    SyncAllMarksToClient = function() end,
    IsPlayerInventoryComponent = function() return false end,
    MakePlacementContext = function() return {} end,
    TryPlaceByMarks = function() return false end,
    ResolvePlayerStorageOwner = function()
        return { GUID = 1, HasTag = function(_, tag) return tag == "player" end, components = {} }
    end,
    ShouldReserveMarkedSlotsForItem = function() return false end,
    ClearServerSlotMarkIfItemMismatches = function() cleared = cleared + 1 end,
    ClearContainerSlotMarkOnMismatch = function() cleared = cleared + 1 end,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_markstores.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_inventoryhooks.lua")

-- 一个可携带容器原版 Container:OnLoad 会用存档槽位号调 GiveItem
local container =
{
    inst = { GUID = 500, components = { inventoryitem = {} } },
    slots = {},
    loading_give = false,
    GiveItem = function() return 1 end,
    OnLoad = function(self)
        self.loading_give = true
        self:GiveItem({ prefab = "goldnugget" }, 1)
        self.loading_give = nil
    end,
}

for _, callback in ipairs(callbacks.container) do
    callback(container)
end

-- 读档过程（在 OnLoad 里面）不能清标记
container:OnLoad({ items = {} })
assert_equal(cleared, 0, "loading a container does not clear marks")

-- 加载结束之后，正常放进别的物品才算玩家操作
container:GiveItem({ prefab = "goldnugget" }, 1)
assert_equal(cleared, 1, "a normal GiveItem after load still clears mismatched marks")
