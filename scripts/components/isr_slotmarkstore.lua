local function ToNumber(value)
    local convert = tonumber or (GLOBAL ~= nil and GLOBAL.tonumber or nil)
    return convert ~= nil and convert(value) or value
end

-- 标记只有一种：把某一格固定给某个 prefab。
local SlotMarkStore = Class(function(self, inst)
    self.inst = inst
    self.marks = {}
    self.next_order = 0
end)

function SlotMarkStore:GetMark(slot)
    return slot ~= nil and self.marks[slot] or nil
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
    return mark
end

function SlotMarkStore:ClearMark(slot)
    if slot == nil or self.marks[slot] == nil then
        return false
    end

    self.marks[slot] = nil
    return true
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
    }
end

function SlotMarkStore:OnLoad(data)
    self.marks = {}
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
