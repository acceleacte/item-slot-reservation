local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
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

local SlotMarkStore = dofile(ISR_TEST_ROOT.."/scripts/components/isr_slotmarkstore.lua")
local store = SlotMarkStore({ GUID = 10 })

assert_equal(store:OnSave(), nil, "empty store writes no save data")

local first_order = store:NextOrder()
store:SetMark(2, "grass", first_order)
assert_equal(store:GetMark(2).prefab, "grass", "mark is stored by slot")
assert_equal(store:GetMark(2).order, 1, "mark order is retained")

local data = store:OnSave()
assert_equal(#data.marks, 1, "non-empty store serializes marks")
assert_equal(data.marks[1].slot, 2, "serialized slot")
assert_equal(data.marks[1].prefab, "grass", "serialized prefab")

local restored = SlotMarkStore({ GUID = 11 })
restored:OnLoad(data)
assert_equal(restored:GetMark(2).prefab, "grass", "saved mark restores")
assert_equal(restored:NextOrder(), 2, "order sequence resumes after load")
restored:ReserveOrder(8)
assert_equal(restored:NextOrder(), 9, "reserved legacy order advances sequence")

-- 0.1.0 存档：字段叫 eslot；kind="eslot" 的装备部位标记已取消，读取时丢弃
local legacy = SlotMarkStore({ GUID = 12 })
legacy:OnLoad(
{
    marks =
    {
        { slot = 1, eslot = "cutgrass", kind = "prefab", order = 1 },
        { slot = 2, eslot = "head", kind = "eslot", order = 2 },
    },
})
assert_equal(legacy:GetMark(1).prefab, "cutgrass", "legacy prefab mark migrates")
assert_equal(legacy:GetMark(2), nil, "legacy equipment-slot mark is dropped")

assert_equal(restored:ClearMark(2), true, "existing mark clears")
assert_equal(restored:ClearMark(2), false, "missing mark does not report a clear")
assert_equal(restored:OnSave(), nil, "cleared store writes no save data")

-- 容器 owner 会随存档走（独占模式用它断归属）；每条标记本身仍不带 owner
local anonymous = SlotMarkStore({ GUID = 13 })
anonymous:SetMark(1, "twigs", 1)
anonymous:SetOwner("KU_first")
local anonymous_data = anonymous:OnSave()
assert_equal(anonymous_data.owner, "KU_first", "the container owner is serialized")
assert_equal(anonymous_data.marks[1].owner, nil, "marks carry no owner")

local anonymous_reloaded = SlotMarkStore({ GUID = 14 })
anonymous_reloaded:OnLoad(anonymous_data)
assert_equal(anonymous_reloaded:GetMark(1).prefab, "twigs", "marks load back")
assert_equal(anonymous_reloaded:GetOwner(), "KU_first", "the container owner loads back")

-- 老存档里的每格 owner（0.1.8 开发期间的中间格式）读进来丢弃，容器 owner 保留
local legacy_owner = SlotMarkStore({ GUID = 15 })
legacy_owner:OnLoad({ marks = { { slot = 2, prefab = "log", order = 1, owner = "KU_old" } }, next_order = 1, owner = "KU_old" })
assert_equal(legacy_owner:GetMark(2).prefab, "log", "legacy marks still load")
assert_equal(legacy_owner:GetMark(2).owner, nil, "per-slot owner is dropped")
assert_equal(legacy_owner:GetOwner(), "KU_old", "the legacy container owner is kept for exclusive mode")
