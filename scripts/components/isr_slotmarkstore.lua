local function ToNumber(value)
    local convert = tonumber or (GLOBAL ~= nil and GLOBAL.tonumber or nil)
    return convert ~= nil and convert(value) or value
end

-- 有标记的容器要进 ISR 的注册表，否则「玩家身上有什么」枚举不到跟随型容器
-- （切斯特、哈奇）和别的模组容器。组件被 require 时 ISR 已在全局（isr_env 里挂到 GLOBAL）。
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

-- 标记只有一种：把某一格固定给某个 prefab。
local SlotMarkStore = Class(function(self, inst)
    self.inst = inst
    self.marks = {}
    self.next_order = 0
    self.owner = nil
end)

function SlotMarkStore:GetMark(slot)
    return slot ~= nil and self.marks[slot] or nil
end

-- 归属：第一个在这个容器上落标记的玩家 userid。
-- 切斯特没眼骨的时候不跟随任何人，组件语义判不出归属，就靠这个字段记住是谁的。
function SlotMarkStore:GetOwner()
    return self.owner
end

function SlotMarkStore:SetOwner(userid)
    if userid ~= nil and userid ~= "" then
        self.owner = tostring(userid)
    end

    return self.owner
end

function SlotMarkStore:GetMarks()
    return self.marks
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

    return
    {
        marks = records,
        next_order = self.next_order,
        owner = self.owner,
        -- 容器 prefab 不一定在 AddComponent("container") 时就带 inventoryitem
        -- （原版 beargerrfur_sack 是先 container、后 inventoryitem），这种实体构造时
        -- 没有本组件，存档数据会被 EntityScript:SetPersistData 直接丢掉。
        -- 带上这个标记，引擎会在读到数据时自动补建组件再 OnLoad。
        add_component_if_missing = true,
    }
end

function SlotMarkStore:OnLoad(data)
    if data == nil then
        -- 没有存档数据（新建实体）：保留内存中的标记，不要清空。
        return
    end

    self.marks = {}
    self.owner = data.owner ~= nil and tostring(data.owner) or nil
    self.next_order = ToNumber(data ~= nil and data.next_order) or 0

    for _, saved in ipairs(data ~= nil and data.marks or {}) do
        local slot = ToNumber(saved.slot)
        -- 兼容 0.1.0 存档：那时字段叫 eslot，另外还有 kind="eslot" 的装备部位标记（本版本已取消，直接丢弃）
        local prefab = saved.prefab
        if prefab == nil and saved.kind ~= "eslot" then
            prefab = saved.eslot
        end

        if slot ~= nil and slot >= 1 and prefab ~= nil then
            self:SetMark(slot, prefab, saved.order)
        end
    end
end

return SlotMarkStore
