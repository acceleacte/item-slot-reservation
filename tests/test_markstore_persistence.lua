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

-- 复刻 scripts/entityscript.lua 的 GetPersistData / SetPersistData 关键分支。
-- 组件在实体上不存在时，只有数据自己带 add_component_if_missing 才会被补建；
-- 补建走 require("components/<name>")，组件由本模组提供，模组关掉就抛错。
local function GetPersistData(inst)
    local data = {}
    for name, comp in pairs(inst.components) do
        if comp.OnSave ~= nil then
            local saved = comp:OnSave()
            if type(saved) == "table" and next(saved) ~= nil then
                data[name] = saved
                if saved.add_component_if_missing then
                    data.add_component_if_missing = true
                end
            end
        end
    end
    return data
end

local function SetPersistData(inst, data)
    if data ~= nil and data.add_component_if_missing then
        for k, v in pairs(data) do
            if inst.components[k] == nil and type(v) == "table" and v.add_component_if_missing then
                inst:AddComponent(k)
            end
        end
    end

    for k, v in pairs(data or {}) do
        local comp = inst.components[k]
        if comp ~= nil and comp.OnLoad ~= nil then
            comp:OnLoad(v)
        end
    end
end

local function NewEntity(guid, with_store)
    local inst = { GUID = guid, components = {} }
    inst.AddComponent = function(self, name)
        if name == "isr_slotmarkstore" then
            self.components[name] = SlotMarkStore(self)
        else
            self.components[name] = {}
        end
    end
    if with_store then
        inst:AddComponent("isr_slotmarkstore")
    end
    return inst
end

-- 1. 存档数据不得带 add_component_if_missing。
-- 带上去 = 引擎读档时强制 AddComponent → 玩家关掉模组后 require 失败 → 读档中断。
local sack = NewEntity(100, true)
sack.components.isr_slotmarkstore:SetMark(3, "twigs", 1)
local saved = GetPersistData(sack)
assert_equal(saved.isr_slotmarkstore ~= nil, true, "mark data is written to the save record")
assert_equal(saved.isr_slotmarkstore.add_component_if_missing, nil, "component data must not carry add_component_if_missing")
assert_equal(saved.add_component_if_missing, nil, "save record must not ask the engine to rebuild components")

-- 2. 模组启用中：组件由 isr_markstores 在构造期挂上，数据正常加载。
local enabled = NewEntity(101, true)
SetPersistData(enabled, saved)
assert_equal(enabled.components.isr_slotmarkstore:GetMark(3).prefab, "twigs", "mark survives the reload while the mod is enabled")

-- 3. 模组被关掉：实体没有组件，数据里也没有重建标记 → 引擎静默跳过，不抛错。
local uninstalled = NewEntity(102, false)
local ok, err = pcall(SetPersistData, uninstalled, saved)
assert_equal(ok, true, "loading the save without the mod must not raise"..tostring(err))
assert_equal(uninstalled.components.isr_slotmarkstore, nil, "no component is rebuilt when the mod is disabled")

-- 4. 旧存档（0.1.3 及以前写的数据带 flag）：组件已存在时不重复补建，数据照常加载。
--    进一次世界并保存，旧 flag 就被洗掉，迁移完成。
local legacy_data =
{
    isr_slotmarkstore =
    {
        marks = { { slot = 2, prefab = "grass", order = 1 } },
        next_order = 1,
        add_component_if_missing = true,
    },
    add_component_if_missing = true,
}
local legacy = NewEntity(103, true)
SetPersistData(legacy, legacy_data)
assert_equal(legacy.components.isr_slotmarkstore:GetMark(2).prefab, "grass", "legacy record still loads when the component exists")
local legacy_resaved = GetPersistData(legacy)
assert_equal(legacy_resaved.add_component_if_missing, nil, "re-saving a legacy record drops the rebuild flag")

-- 5. 空存档不写数据，也不带 add_component_if_missing。
local empty = NewEntity(104, true)
local empty_saved = GetPersistData(empty)
assert_equal(empty_saved.isr_slotmarkstore, nil, "empty store writes nothing")
assert_equal(empty_saved.add_component_if_missing, nil, "empty store sets no recovery flag")

-- 6. 没有存档数据时 OnLoad 不得清空内存里的标记。
local keep = NewEntity(105, true)
keep.components.isr_slotmarkstore:SetMark(2, "grass", 1)
keep.components.isr_slotmarkstore:OnLoad(nil)
assert_equal(keep.components.isr_slotmarkstore:GetMark(2).prefab, "grass", "OnLoad(nil) keeps in-memory marks")

-- 7. 标记不记名：存档里既不写容器 owner，也不写每格 owner。
local shared = NewEntity(106, true)
shared.components.isr_slotmarkstore:SetMark(1, "log", 1)
shared.components.isr_slotmarkstore:SetMark(2, "twigs", 2)
local shared_saved = GetPersistData(shared)
assert_equal(shared_saved.isr_slotmarkstore.owner, nil, "container owner is not written")
assert_equal(shared_saved.isr_slotmarkstore.marks[1].owner, nil, "per-slot owner is not written")
local reloaded = NewEntity(107, true)
SetPersistData(reloaded, shared_saved)
assert_equal(reloaded.components.isr_slotmarkstore:GetMark(2).prefab, "twigs", "marks survive an anonymous reload")

-- 8. 0.1.7 及更早的存档带 owner 字段：读档时忽略，标记照常可用。
local old_marks =
{
    isr_slotmarkstore =
    {
        marks = { { slot = 2, prefab = "grass", order = 1, owner = "KU_legacy" } },
        next_order = 1,
        owner = "KU_legacy",
    },
}
local migrated = NewEntity(108, true)
SetPersistData(migrated, old_marks)
assert_equal(migrated.components.isr_slotmarkstore:GetMark(2).prefab, "grass", "legacy marks still load")
assert_equal(migrated.components.isr_slotmarkstore:GetMark(2).owner, nil, "legacy owner is dropped")
