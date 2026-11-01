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
-- 组件在实体上不存在时，只有数据自己带 add_component_if_missing 才会被补建。
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

-- 存档的数据必须能让引擎自己补回组件（原版 beargerrfur_sack 是先 container、
-- 后 inventoryitem，构造时判不到 inventoryitem，组件不会被预先挂上）。
local sack = NewEntity(100, true)
sack.components.isr_slotmarkstore:SetMark(3, "twigs", 1)
local saved = GetPersistData(sack)
assert_equal(saved.isr_slotmarkstore ~= nil, true, "mark data is written to the save record")
assert_equal(saved.add_component_if_missing, true, "save record asks the engine to restore the component")

-- 读档：构造时没有组件，数据仍然要被应用
local restored = NewEntity(101, false)
assert_equal(restored.components.isr_slotmarkstore, nil, "prefab without inventoryitem has no mark store at spawn")
SetPersistData(restored, saved)
assert_equal(restored.components.isr_slotmarkstore ~= nil, true, "missing component is created on load")
assert_equal(restored.components.isr_slotmarkstore:GetMark(3).prefab, "twigs", "mark survives the reload")

-- 组件本来就在的实体不受影响（正常背包、箱子）
local plain = NewEntity(102, true)
SetPersistData(plain, saved)
assert_equal(plain.components.isr_slotmarkstore:GetMark(3).prefab, "twigs", "existing component still loads")

-- 空存档不写数据，也不带 add_component_if_missing
local empty = NewEntity(103, true)
local empty_saved = GetPersistData(empty)
assert_equal(empty_saved.isr_slotmarkstore, nil, "empty store writes nothing")
assert_equal(empty_saved.add_component_if_missing, nil, "empty store sets no recovery flag")

-- 没有存档数据时 OnLoad 不得清空内存里的标记
local keep = NewEntity(104, true)
keep.components.isr_slotmarkstore:SetMark(2, "grass", 1)
keep.components.isr_slotmarkstore:OnLoad(nil)
assert_equal(keep.components.isr_slotmarkstore:GetMark(2).prefab, "grass", "OnLoad(nil) keeps in-memory marks")
