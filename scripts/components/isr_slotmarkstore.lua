local function ToNumber(value)
    local convert = tonumber or (GLOBAL ~= nil and GLOBAL.tonumber or nil)
    return convert ~= nil and convert(value) or value
end

-- 有标记的容器要进 ISR 的注册表，否则「玩家身上有什么」枚举不到跟随型容器
-- （切斯特、哈奇）和别的模组容器组件被 require 时 ISR 已在全局（isr_env 里挂到 GLOBAL）
local function TouchRegistry(inst)
    if ISR ~= nil and ISR.RegisterMarkContainer ~= nil then
        ISR.RegisterMarkContainer(inst)
    end
end

local function DropRegistryIfEmpty(store)
    if ISR ~= nil and ISR.UnregisterMarkContainer ~= nil and store:OnSave() == nil then
        ISR.UnregisterMarkContainer(store.inst)
    end
end

-- 标记只有一种：把某一格固定给某个 prefab
-- 每条标记不记名（不记谁设的）容器上另有一个 owner 字段：第一个在这只容器落标记的
-- 玩家共享模式（container_sharing = shared，默认）下它不参与任何判定；
-- 切到独占模式时它决定这只容器归谁两种模式共用同一份存档，切换不需要迁移
local SlotMarkStore = Class(function(self, inst)
    self.inst = inst
    self.marks = {}
    self.next_order = 0
    self.owner = nil
end)

function SlotMarkStore:GetMark(slot)
    return slot ~= nil and self.marks[slot] or nil
end

function SlotMarkStore:GetMarks()
    return self.marks
end

-- 容器 owner：第一个在这只容器落标记的玩家 userid只在独占模式下参与判定
function SlotMarkStore:GetOwner()
    return self.owner
end

function SlotMarkStore:SetOwner(userid)
    if userid ~= nil and userid ~= "" then
        self.owner = tostring(userid)
    end

    return self.owner
end

function SlotMarkStore:SetMark(slot, prefab, order)
    if slot == nil or prefab == nil then
        return nil
    end

    order = ToNumber(order) or self:NextOrder()
    if order > self.next_order then
        self.next_order = order
    end

    local mark =
    {
        slot = slot,
        prefab = prefab,
        order = order,
    }
    self.marks[slot] = mark
    TouchRegistry(self.inst)
    return mark
end

function SlotMarkStore:ClearMark(slot)
    if slot == nil or self.marks[slot] == nil then
        return false
    end

    self.marks[slot] = nil
    DropRegistryIfEmpty(self)
    return true
end

function SlotMarkStore:OnRemoveFromEntity()
    if ISR ~= nil and ISR.UnregisterMarkContainer ~= nil then
        ISR.UnregisterMarkContainer(self.inst)
    end
end

function SlotMarkStore:NextOrder()
    self.next_order = self.next_order + 1
    return self.next_order
end

function SlotMarkStore:ReserveOrder(order)
    order = ToNumber(order)
    if order ~= nil and order > self.next_order then
        self.next_order = order
    end
    return self.next_order
end

function SlotMarkStore:OnSave()
    local records = {}
    for _, mark in pairs(self.marks) do
        table.insert(records,
        {
            slot = mark.slot,
            prefab = mark.prefab,
            order = mark.order,
        })
    end

    if #records == 0 then
        return nil
    end

    table.sort(records, function(a, b)
        if a.order ~= b.order then
            return (a.order or 0) < (b.order or 0)
        end
        return a.slot < b.slot
    end)

    -- 不要写 add_component_if_missing
    -- 引擎（entityscript.lua:1980）读到这个标记会对存档里缺组件的实体强制
    -- AddComponent，组件由本模组提供：玩家一关模组，require 抛错，异常直接打断
    -- SpawnSaveRecord → PopulateWorld，存档再也进不去（2026-11-02 实测切斯特必崩）
    -- 现在改由 isr_markstores 在所有 container 实体构造时挂组件，读档时组件天然存在，
    -- 不需要引擎补建；模组关闭时引擎找不到组件就静默跳过这份数据
    return
    {
        marks = records,
        next_order = self.next_order,
        owner = self.owner,
    }
end

function SlotMarkStore:OnLoad(data)
    if data == nil then
        -- 没有存档数据（新建实体）：保留内存中的标记，不要清空
        return
    end

    self.marks = {}
    self.next_order = ToNumber(data ~= nil and data.next_order) or 0
    -- 容器 owner：独占模式用它断归属。共享模式下读进来也不参与判定，留着是为了切模式时不丢
    self.owner = data.owner ~= nil and tostring(data.owner) or nil

    for _, saved in ipairs(data ~= nil and data.marks or {}) do
        local slot = ToNumber(saved.slot)
        -- 兼容 0.1.0 存档：那时字段叫 eslot，另外还有 kind="eslot" 的装备部位标记（本版本已取消，直接丢弃）
        local prefab = saved.prefab
        if prefab == nil and saved.kind ~= "eslot" then
            prefab = saved.eslot
        end

        -- 老存档里可能还带每格 owner（0.1.8 开发期间的中间格式），一律忽略：归属只按容器记
        if slot ~= nil and slot >= 1 and prefab ~= nil then
            self:SetMark(slot, prefab, saved.order)
        end
    end
end

return SlotMarkStore
