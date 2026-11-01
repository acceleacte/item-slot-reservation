ISR = ISR or {}

local open_container_widgets = {}

local function IsSlotUpdating(slot)
    local frontend = ISR.GetGlobalValue("TheFrontEnd", nil)
    return frontend ~= nil
        and frontend.updating_widgets ~= nil
        and frontend.updating_widgets[slot] == true
end

local function UpdateSlotRefreshState(slot)
    if slot == nil then
        return
    end

    local should_update = slot.focus or ISR.GetClientSlotMark(slot) ~= nil
    if should_update and not IsSlotUpdating(slot) then
        slot._isr_update_owned = true
        slot:StartUpdating()
    elseif not should_update and slot._isr_update_owned then
        slot._isr_update_owned = nil
        slot:StopUpdating()
    end
end

local function ApplySlotIconSoon(slot)
    if slot == nil then
        return
    end

    ISR.ApplyRuntimeIconToSlot(slot)
    UpdateSlotRefreshState(slot)

    local player = ISR.GetLocalPlayer()
    if player ~= nil and player.DoTaskInTime ~= nil then
        player:DoTaskInTime(0, function()
            if slot ~= nil and slot.inst ~= nil then
                ISR.ApplyRuntimeIconToSlot(slot)
                UpdateSlotRefreshState(slot)
            end
        end)
    end
end

local function GetSlotItemPrefab(slot)
    if slot == nil or slot.container == nil or slot.num == nil then
        return nil
    end

    local container = slot.container
    local item = nil
    if container.GetItemInSlot ~= nil then
        item = container:GetItemInSlot(slot.num)
    elseif container.itemslots ~= nil then
        -- 兜底：replica/容器组件都缺 GetItemInSlot 时直接读槽位表
        item = container.itemslots[slot.num]
    elseif container.slots ~= nil then
        item = container.slots[slot.num]
    end

    return item ~= nil and item.prefab or nil
end

-- 只在按住固定键悬停时接管 tooltip，其余时刻原样还给游戏。
-- 文案只要动作，不带物品名和括号：格子本身已经显示物品，重复没有信息量。
local function BuildSlotTooltip(slot)
    if slot == nil or not slot.focus then
        return nil
    end

    if not ISR.IsClientMarkableSlot(slot) or not ISR.IsPinKeyPressed() then
        return nil
    end

    local mark = ISR.GetClientSlotMark(slot)
    local lines = {}

    -- 已固定的格子不再提示左键（左键在此是取消），只留清除
    if mark == nil and GetSlotItemPrefab(slot) ~= nil then
        table.insert(lines, ISR.GetLocalizedControl(ISR.SlotDisplayControls.PIN, "Left Mouse")
            ..": "..ISR.GetText("PIN_MARK"))
    end

    if mark ~= nil then
        table.insert(lines, ISR.GetLocalizedControl(ISR.SlotDisplayControls.CLEAR, "Right Mouse")
            ..": "..ISR.GetText("CLEAR_MARK"))
    end

    if #lines == 0 then
        return nil
    end

    return table.concat(lines, "\n")
end

local function UpdateSlotTooltip(slot)
    local tooltip = BuildSlotTooltip(slot)

    if tooltip == nil then
        slot._isr_tooltip_override = nil
        if slot._isr_tooltip_owned then
            if slot.tooltip == slot._isr_tooltip_value then
                slot:SetTooltip(slot._isr_previous_tooltip)
            end
            slot._isr_tooltip_owned = nil
            slot._isr_tooltip_value = nil
            slot._isr_previous_tooltip = nil
        end
        return
    end

    if not slot._isr_tooltip_owned then
        slot._isr_previous_tooltip = slot.tooltip
    end
    slot._isr_tooltip_owned = true
    slot._isr_tooltip_value = tooltip
    slot._isr_tooltip_override = tooltip
    if slot.tooltip ~= tooltip then
        slot:SetTooltip(tooltip)
    end
end

AddClassPostConstruct("widgets/invslot", function(self)
    local old_ConvertToConstructionSlot = self.ConvertToConstructionSlot
    if old_ConvertToConstructionSlot ~= nil then
        function self:ConvertToConstructionSlot(ingredient, ...)
            self._isr_is_construction_slot = ingredient ~= nil
            local result = old_ConvertToConstructionSlot(self, ingredient, ...)
            ApplySlotIconSoon(self)
            return result
        end
    end

    local old_SetTile = self.SetTile
    if old_SetTile ~= nil then
        function self:SetTile(...)
            old_SetTile(self, ...)
            ApplySlotIconSoon(self)
        end
    end

    local function TryHandleSlotIntent(slot, intent, down)
        if not down or intent == nil then
            return false
        end

        if not ISR.IsClientMarkableSlot(slot) then
            ISR.Log("InvSlot block", "reason", "not_markable", "slot", tostring(slot.num), "intent", tostring(intent))
            return false
        end

        -- 固定：点已有物品的格子，把该格固定给这种物品
        if intent == ISR.SLOT_INTENT_PIN then
            if ISR.IsSlotEmpty(slot) then
                return false
            end

            ISR.Log("InvSlot pin mouse", "slot", tostring(slot.num))
            return ISR.PinClientSlotMark(slot)
        end

        -- 清除：已标记的格子随时可清，不要求格子为空
        if ISR.GetClientSlotMark(slot) == nil then
            return false
        end

        ISR.Log("InvSlot clear mouse", "slot", tostring(slot.num))
        return ISR.ClearClientSlotMark(slot)
    end

    -- 同一次点击可能先走 OnMouseButton，再走 OnControl；200ms 内相同意图只处理一次
    local function HandleSlotIntent(slot, intent, down)
        if not down or intent == nil then
            return false
        end

        local get_time = ISR.GetGlobalValue("GetTime", nil)
        local now = get_time ~= nil and get_time() or nil
        local stamp = slot._isr_intent_stamp
        if now ~= nil and stamp ~= nil and stamp.intent == intent and now - stamp.time < 0.2 then
            return stamp.handled
        end

        local handled = TryHandleSlotIntent(slot, intent, down)
        slot._isr_intent_stamp =
        {
            intent = intent,
            time = now,
            handled = handled,
        }
        return handled
    end

    local old_OnMouseButton = self.OnMouseButton
    function self:OnMouseButton(button, down, x, y)
        if HandleSlotIntent(self, ISR.GetSlotMouseIntent(button), down) then
            return true
        end

        return old_OnMouseButton ~= nil and old_OnMouseButton(self, button, down, x, y) or false
    end

    -- 拾取/放下物品走的是 OnControl(CONTROL_ACCEPT / CONTROL_PRIMARY)，
    -- 只拦 OnMouseButton 挡不住，必须同时拦控制事件。
    local old_OnControl = self.OnControl
    function self:OnControl(control, down)
        if HandleSlotIntent(self, ISR.GetSlotMouseIntent(control), down) then
            return true
        end

        return old_OnControl ~= nil and old_OnControl(self, control, down) or false
    end

    local old_OnGainFocus = self.OnGainFocus
    function self:OnGainFocus()
        if old_OnGainFocus ~= nil then
            old_OnGainFocus(self)
        end
        UpdateSlotRefreshState(self)
        UpdateSlotTooltip(self)
    end

    local old_OnLoseFocus = self.OnLoseFocus
    function self:OnLoseFocus()
        if old_OnLoseFocus ~= nil then
            old_OnLoseFocus(self)
        end
        UpdateSlotTooltip(self)
        UpdateSlotRefreshState(self)
    end

    local old_OnUpdate = self.OnUpdate
    function self:OnUpdate(dt)
        if old_OnUpdate ~= nil then
            old_OnUpdate(self, dt)
        end
        if ISR.GetClientSlotMark(self) ~= nil then
            ISR.RefreshSlotBorderLayout(self)
        end
        UpdateSlotTooltip(self)
    end

    -- 格子里有物品时，物品图（self.tile）是 self 的子 widget：Widget:GetTooltip
    -- 先遍历子 widget 再取 self.tooltip，物品自己的提示会盖掉我们写的串。
    -- 按住固定键期间直接接管返回值，让提示稳定显示在按住的全过程。
    local old_GetTooltip = self.GetTooltip
    function self:GetTooltip()
        if self._isr_tooltip_override ~= nil then
            return self._isr_tooltip_override
        end

        return old_GetTooltip ~= nil and old_GetTooltip(self) or nil
    end
end)

local function ApplyInventoryBarIcons(invbar)
    if invbar == nil then
        return
    end

    for _, slot in pairs(invbar.inv or {}) do
        ApplySlotIconSoon(slot)
    end
    for _, slot in pairs(invbar.backpackinv or {}) do
        ApplySlotIconSoon(slot)
    end
end

local function ApplyContainerWidgetIcons(widget)
    if widget.inv ~= nil then
        for _, slot in pairs(widget.inv) do
            ApplySlotIconSoon(slot)
        end
    end
end

function ISR.RefreshVisibleSlotIcons()
    local player = ISR.GetLocalPlayer()
    local invbar = player ~= nil
        and player.HUD ~= nil
        and player.HUD.controls ~= nil
        and player.HUD.controls.inv
        or nil

    ApplyInventoryBarIcons(invbar)
    for widget in pairs(open_container_widgets) do
        if widget.isopen then
            ApplyContainerWidgetIcons(widget)
        end
    end
end

function ISR.QueueRefreshVisibleSlotIcons()
    if ISR.RefreshVisibleSlotIcons ~= nil then
        ISR.RefreshVisibleSlotIcons()
    end

    local player = ISR.GetLocalPlayer()
    if player ~= nil and player.DoTaskInTime ~= nil then
        player:DoTaskInTime(0, function()
            if ISR.RefreshVisibleSlotIcons ~= nil then
                ISR.RefreshVisibleSlotIcons()
            end
        end)
    end
end

AddClassPostConstruct("widgets/inventorybar", function(self)
    local old_Rebuild = self.Rebuild
    function self:Rebuild(...)
        old_Rebuild(self, ...)
        ApplyInventoryBarIcons(self)
        if ISR.RequestMarkSnapshot ~= nil then
            ISR.RequestMarkSnapshot()
        end
    end

    local old_Refresh = self.Refresh
    function self:Refresh(...)
        old_Refresh(self, ...)
        ApplyInventoryBarIcons(self)
    end
end)

AddClassPostConstruct("widgets/containerwidget", function(self)
    local old_Open = self.Open
    function self:Open(...)
        old_Open(self, ...)
        open_container_widgets[self] = true
        ApplyContainerWidgetIcons(self)
        if ISR.IsClientMarkableContainerInst(self.container) and ISR.RequestMarkSnapshot ~= nil then
            ISR.RequestMarkSnapshot()
        end
    end

    local old_Refresh = self.Refresh
    function self:Refresh(...)
        old_Refresh(self, ...)
        ApplyContainerWidgetIcons(self)
    end

    local old_Close = self.Close
    function self:Close(...)
        open_container_widgets[self] = nil
        return old_Close(self, ...)
    end
end)
