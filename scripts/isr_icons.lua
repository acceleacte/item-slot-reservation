ISR = ISR or {}

local Image = nil

ISR.SLOT_BORDER_ATLAS = "images/wood_frame_128_ARGB.xml"
ISR.SLOT_BORDER_IMAGE = "wood_frame_128_ARGB.tex"
ISR.SLOT_BORDER_TEX = "images/wood_frame_128_ARGB.tex"
ISR.SLOT_BORDER_FALLBACK_SIZE = 64
ISR.SLOT_BORDER_SCALE = 1.26
ISR.SLOT_ICON_SCALE = 0.82

local function ResolveAtlas(path)
    local resolve = softresolvefilepath or ISR.GetGlobalValue("softresolvefilepath", nil)
    return resolve ~= nil and resolve(path) ~= nil and path or nil
end

local function GetImageWidget()
    if Image == nil then
        Image = require "widgets/image"
    end
    return Image
end

local function ReadWidgetSize(widget)
    if widget == nil then
        return nil, nil
    elseif widget.GetSize ~= nil then
        local w, h = widget:GetSize()
        if w ~= nil and h ~= nil and w > 0 and h > 0 then
            return w, h
        end
    end

    local transform = widget.UITransform or widget.inst ~= nil and widget.inst.UITransform or nil
    if transform ~= nil and transform.GetSize ~= nil then
        local w, h = transform:GetSize()
        if w ~= nil and h ~= nil and w > 0 and h > 0 then
            return w, h
        end
    end

    return nil, nil
end

local function GetSlotBaseSize(slot)
    local size_sources =
    {
        slot ~= nil and slot.bg or nil,
        slot ~= nil and slot.bgimage or nil,
        slot ~= nil and slot.image or nil,
        slot,
    }

    for _, source in ipairs(size_sources) do
        local w, h = ReadWidgetSize(source)
        if w ~= nil then
            return math.min(w, h)
        end
    end

    return ISR.SLOT_BORDER_FALLBACK_SIZE
end

local function SyncSlotBorderSize(slot)
    if slot == nil or slot._isr_slot_border == nil or slot._isr_slot_border.SetSize == nil then
        return
    end

    local size = GetSlotBaseSize(slot) * ISR.SLOT_BORDER_SCALE
    slot._isr_slot_border:SetSize(size, size)
end

local function SyncSlotIconSize(slot)
    if slot == nil or slot._isr_slot_icon == nil or slot._isr_slot_icon.SetSize == nil then
        return
    end

    local size = GetSlotBaseSize(slot) * ISR.SLOT_ICON_SCALE
    slot._isr_slot_icon:SetSize(size, size)
end

-- 预留格的图标就是该物品自己的物品栏贴图；取不到就只画木框。
function ISR.GetPrefabIcon(prefab)
    local key = prefab ~= nil and ISR.NormalizePrefabKey(prefab) or nil
    if key == nil then
        return nil
    end

    local image = key..".tex"
    local get_atlas = ISR.GetGlobalValue("GetInventoryItemAtlas", nil)
    local atlas = get_atlas ~= nil and get_atlas(image, true) or nil
    if atlas == nil then
        return nil
    end

    return { atlas = atlas, image = image }
end

local function ApplyIconWidget(slot, icon)
    if slot == nil or icon == nil then
        return false
    end

    local alpha = ISR.Config ~= nil and ISR.Config.icon_opacity or 0.35
    if slot._isr_slot_icon == nil then
        local ImageWidget = GetImageWidget()
        slot._isr_slot_icon = slot:AddChild(ImageWidget(icon.atlas, icon.image))
        slot._isr_slot_icon:SetClickable(false)
    else
        slot._isr_slot_icon:SetTexture(icon.atlas, icon.image)
    end

    slot._isr_slot_icon:SetTint(1, 1, 1, alpha)
    SyncSlotIconSize(slot)
    slot._isr_slot_icon:Show()
    if slot.tile ~= nil then
        slot.tile:MoveToFront()
    end

    return true
end

function ISR.ApplyMarkIconToSlot(slot, prefab)
    if slot == nil then
        return false
    end

    local icon = ISR.GetPrefabIcon(prefab)
    if icon == nil then
        ISR.ClearSlotIcon(slot)
        return false
    end

    return ApplyIconWidget(slot, icon)
end

function ISR.ClearSlotIcon(slot)
    if slot ~= nil and slot._isr_slot_icon ~= nil then
        slot._isr_slot_icon:Hide()
    end
end

local function MoveSlotLabelsToFront(slot)
    if slot == nil then
        return
    end

    if slot.label ~= nil then
        slot.label:MoveToFront()
    end
    if slot.readonlyvisual ~= nil then
        slot.readonlyvisual:MoveToFront()
    end
end

function ISR.ApplySlotBorder(slot)
    if slot == nil then
        return
    end
    if ResolveAtlas(ISR.SLOT_BORDER_ATLAS) == nil or ResolveAtlas(ISR.SLOT_BORDER_TEX) == nil then
        ISR.ClearSlotBorder(slot)
        return
    end

    if slot._isr_slot_border == nil then
        local ImageWidget = GetImageWidget()
        slot._isr_slot_border = slot:AddChild(ImageWidget(ISR.SLOT_BORDER_ATLAS, ISR.SLOT_BORDER_IMAGE))
        slot._isr_slot_border:SetClickable(false)
        slot._isr_slot_border_atlas = ISR.SLOT_BORDER_ATLAS
        slot._isr_slot_border_image = ISR.SLOT_BORDER_IMAGE
    elseif slot._isr_slot_border_atlas ~= ISR.SLOT_BORDER_ATLAS
        or slot._isr_slot_border_image ~= ISR.SLOT_BORDER_IMAGE
    then
        slot._isr_slot_border:SetTexture(ISR.SLOT_BORDER_ATLAS, ISR.SLOT_BORDER_IMAGE)
        slot._isr_slot_border_atlas = ISR.SLOT_BORDER_ATLAS
        slot._isr_slot_border_image = ISR.SLOT_BORDER_IMAGE
    end

    SyncSlotBorderSize(slot)
    slot._isr_slot_border:Show()
    slot._isr_slot_border:MoveToFront()
    MoveSlotLabelsToFront(slot)
end

function ISR.RefreshSlotBorderLayout(slot)
    if slot == nil then
        return
    end

    SyncSlotIconSize(slot)
    if slot._isr_slot_border ~= nil then
        SyncSlotBorderSize(slot)
        slot._isr_slot_border:MoveToFront()
        MoveSlotLabelsToFront(slot)
    end
end

function ISR.ClearSlotBorder(slot)
    if slot ~= nil and slot._isr_slot_border ~= nil then
        slot._isr_slot_border:Hide()
    end
end
