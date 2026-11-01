ISR = ISR or {}

ISR.RPC_NAMESPACE = "item_slot_reservation"
ISR.RPC_SET_MARK = "set_slot_mark"
ISR.RPC_SYNC_MARK = "sync_slot_mark"
ISR.RPC_SYNC_BEGIN = "sync_marks_begin"
ISR.RPC_SYNC_END = "sync_marks_end"
ISR.RPC_REQUEST_SYNC = "request_marks_sync"

if GLOBAL ~= nil then
    GLOBAL.ISR = ISR
end

function ISR.GetGlobalValue(name, fallback)
    return (GLOBAL ~= nil and GLOBAL[name] or nil) or fallback
end

ISR.Runtime =
{
    debug = ISR.GetGlobalValue("debug", nil),
    error = ISR.GetGlobalValue("error", nil),
    pcall = ISR.GetGlobalValue("pcall", nil),
    select = ISR.GetGlobalValue("select", nil),
    unpack = ISR.GetGlobalValue("unpack", nil),
    xpcall = ISR.GetGlobalValue("xpcall", nil),
}

ISR.SlotMouseButtons =
{
    LEFT = ISR.GetGlobalValue("MOUSEBUTTON_LEFT", 1000),
    CLEAR = ISR.GetGlobalValue("MOUSEBUTTON_RIGHT", 1001),
}

-- 同一次点击可能同时走鼠标事件(OnMouseButton)和控制事件(OnControl)，两边的编码不同：
-- 鼠标给 MOUSEBUTTON_*，控制给 CONTROL_PRIMARY / CONTROL_ACCEPT / CONTROL_SECONDARY。
ISR.SlotControlButtons =
{
    PRIMARY = ISR.GetGlobalValue("CONTROL_PRIMARY", 0),
    SECONDARY = ISR.GetGlobalValue("CONTROL_SECONDARY", 1),
    ACCEPT = ISR.GetGlobalValue("CONTROL_ACCEPT", 29),
}

function ISR.NormalizeSlotButton(value)
    if value == nil then
        return nil
    elseif value == ISR.SlotMouseButtons.LEFT then
        return ISR.SlotMouseButtons.LEFT
    elseif value == ISR.SlotMouseButtons.CLEAR then
        return ISR.SlotMouseButtons.CLEAR
    elseif value == ISR.SlotControlButtons.SECONDARY then
        return ISR.SlotMouseButtons.CLEAR
    elseif value == ISR.SlotControlButtons.PRIMARY or value == ISR.SlotControlButtons.ACCEPT then
        return ISR.SlotMouseButtons.LEFT
    end

    return nil
end

ISR.SlotDisplayControls =
{
    PIN = ISR.GetGlobalValue("CONTROL_PRIMARY", 0),
    CLEAR = ISR.GetGlobalValue("CONTROL_SECONDARY", 1),
}

ISR.SLOT_INTENT_PIN = "pin_mark"
ISR.SLOT_INTENT_CLEAR = "clear_mark"

-- 固定物品用的独立按键。只有按住它点格子才会触发本模组，不占用任何修饰键。
ISR.PinKeys =
{
    V = ISR.GetGlobalValue("KEY_V", 118),
    B = ISR.GetGlobalValue("KEY_B", 98),
    N = ISR.GetGlobalValue("KEY_N", 110),
    G = ISR.GetGlobalValue("KEY_G", 103),
}

ISR.ValidPinKeyOptions =
{
    V = true,
    B = true,
    N = true,
    G = true,
    NONE = true,
}

-- 自动落进容器的距离上限（世界单位，4 = 一格地皮）。
-- 玩家身上的容器不受限制；世界里的容器按这个距离算，免得站在地图另一头
-- 也能把东西直接送进基地箱子。
ISR.ContainerRangeLimits =
{
    near = 10,
    medium = 24,
    far = 48,
}

ISR.ValidContainerRangeOptions =
{
    near = true,
    medium = true,
    far = true,
}

function ISR.NormalizeConfigValue(value, valid_choices, default)
    if valid_choices[value] then
        return value
    end

    local lower_value = string.lower(tostring(value))
    for key in pairs(valid_choices) do
        if string.lower(tostring(key)) == lower_value then
            return key
        end
    end

    return default
end

function ISR.Log(...)
    if ISR.Config ~= nil and ISR.Config.debug_log then
        print("[ItemSlotReservation]", ...)
    end
end

function ISR.GetLocalPlayer()
    return ThePlayer or (GLOBAL ~= nil and GLOBAL.ThePlayer or nil)
end

function ISR.GetFocalPoint()
    return TheFocalPoint or (GLOBAL ~= nil and GLOBAL.TheFocalPoint or nil)
end

function ISR.GetInput()
    return TheInput or (GLOBAL ~= nil and GLOBAL.TheInput or nil)
end

function ISR.GetEntitiesTable()
    return Ents or (GLOBAL ~= nil and GLOBAL.Ents or nil)
end

function ISR.ToNumber(value)
    local convert = tonumber or (GLOBAL ~= nil and GLOBAL.tonumber or nil)
    return convert ~= nil and convert(value) or value
end

function ISR.GetSlotKey(container_guid, slot)
    return tostring(container_guid)..":"..tostring(slot)
end

function ISR.GetStringsTable()
    return STRINGS or (GLOBAL ~= nil and GLOBAL.STRINGS or nil)
end

function ISR.GetLocaleCode()
    local loc = ISR.GetGlobalValue("LOC", nil)
    if loc ~= nil and loc.GetLocaleCode ~= nil then
        return loc.GetLocaleCode()
    end

    return nil
end

function ISR.IsChineseLocale()
    local code = string.lower(tostring(ISR.GetLocaleCode() or ""))
    return code == "zh"
        or code == "zhr"
        or code == "schinese"
        or code == "tchinese"
        or string.find(code, "zh", 1, true) ~= nil
        or string.find(code, "chinese", 1, true) ~= nil
end

ISR.Text =
{
    PIN_MARK = { en = "Pin this slot", zh = "固定此格" },
    CLEAR_MARK = { en = "Clear", zh = "清除" },
}

function ISR.GetText(key)
    local entry = ISR.Text[key]
    if entry == nil then
        return tostring(key)
    end

    return ISR.IsChineseLocale() and entry.zh or entry.en
end

function ISR.GetLocalizedControl(control, fallback)
    local input = ISR.GetInput()
    if input ~= nil and input.GetLocalizedControl ~= nil and control ~= nil then
        local controller_id = input.GetControllerID ~= nil and input:GetControllerID() or 0
        return input:GetLocalizedControl(controller_id, control) or fallback
    end

    return fallback
end

function ISR.IsPinKeyPressed()
    local pin_key = ISR.Config ~= nil and ISR.Config.pin_key or nil
    if pin_key == nil or pin_key == "NONE" then
        return false
    end

    local keycode = ISR.PinKeys[pin_key]
    local input = ISR.GetInput()
    return keycode ~= nil
        and input ~= nil
        and input.IsKeyDown ~= nil
        and input:IsKeyDown(keycode)
end

-- 唯一的接管条件：按住固定键（默认 V）并点击格子。
-- 左键 = 固定/取消，右键 = 清除。其余任何情况一律放行给原版逻辑。
function ISR.GetSlotMouseIntent(button)
    local normalized = ISR.NormalizeSlotButton(button)
    if normalized == nil or not ISR.IsPinKeyPressed() then
        return nil
    end

    return normalized == ISR.SlotMouseButtons.LEFT and ISR.SLOT_INTENT_PIN or ISR.SLOT_INTENT_CLEAR
end

-- 标记键就是物品 prefab：小写、去掉 .tex 后缀。
function ISR.NormalizePrefabKey(value)
    if value == nil then
        return nil
    end

    local key = string.lower(tostring(value))
    if #key > 4 and string.sub(key, -4) == ".tex" then
        key = string.sub(key, 1, #key - 4)
    end

    return key ~= "" and key or nil
end

function ISR.IsValidPrefabKey(prefab)
    local key = ISR.NormalizePrefabKey(prefab)
    if key == nil then
        return false
    end

    local prefabs = ISR.GetGlobalValue("Prefabs", nil)
    return prefabs ~= nil and prefabs[key] ~= nil
end
