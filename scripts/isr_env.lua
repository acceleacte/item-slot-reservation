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
    -- 中键：原版脚本除 constants.lua 的定义外零引用，没有默认绑定，可安全接管。
    MIDDLE = ISR.GetGlobalValue("MOUSEBUTTON_MIDDLE", 1002),
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
    elseif value == ISR.SlotMouseButtons.MIDDLE then
        return ISR.SlotMouseButtons.MIDDLE
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

-- 固定动作键。两类语义：
--   键盘键 → 按住（可叠加修饰键）点左键=固定、右键=清除，老打法不变
--   鼠标键 → 按住修饰键单击=切换（有标记则清除），左右键完全不参与
ISR.PinKeys =
{
    V = ISR.GetGlobalValue("KEY_V", 118),
    B = ISR.GetGlobalValue("KEY_B", 98),
    N = ISR.GetGlobalValue("KEY_N", 110),
    G = ISR.GetGlobalValue("KEY_G", 103),
    F = ISR.GetGlobalValue("KEY_F", 102),
    C = ISR.GetGlobalValue("KEY_C", 99),
    X = ISR.GetGlobalValue("KEY_X", 120),
    Z = ISR.GetGlobalValue("KEY_Z", 122),
    R = ISR.GetGlobalValue("KEY_R", 114),
    T = ISR.GetGlobalValue("KEY_T", 116),
    H = ISR.GetGlobalValue("KEY_H", 104),
    J = ISR.GetGlobalValue("KEY_J", 106),
    K = ISR.GetGlobalValue("KEY_K", 107),
    L = ISR.GetGlobalValue("KEY_L", 108),
    MIDDLE = ISR.GetGlobalValue("MOUSEBUTTON_MIDDLE", 1002),
    RIGHT = ISR.GetGlobalValue("MOUSEBUTTON_RIGHT", 1001),
}

-- 鼠标动作键：单击即切换，不要求再点左/右键
ISR.PinMouseKeys =
{
    MIDDLE = true,
    RIGHT = true,
}

-- 修饰键用合成键码（KEY_SHIFT = 402，不是左右物理键）。
-- 原版调试键也是这么判的：scripts/debugkeys.lua:431 `TheInput:IsKeyDown(KEY_SHIFT)`。
ISR.PinModifierKeys =
{
    SHIFT = ISR.GetGlobalValue("KEY_SHIFT", 402),
    CTRL = ISR.GetGlobalValue("KEY_CTRL", 401),
    ALT = ISR.GetGlobalValue("KEY_ALT", 400),
}

ISR.PinKeyLabels =
{
    V = "V", B = "B", N = "N", G = "G", F = "F", C = "C", X = "X", Z = "Z",
    R = "R", T = "T", H = "H", J = "J", K = "K", L = "L",
    MIDDLE = { en = "Middle click", zh = "中键" },
    RIGHT = { en = "Right click", zh = "右键" },
}

ISR.PinModifierLabels =
{
    SHIFT = "Shift",
    CTRL = "Ctrl",
    ALT = "Alt",
}

ISR.ValidPinKeyOptions =
{
    V = true, B = true, N = true, G = true, F = true, C = true, X = true, Z = true,
    R = true, T = true, H = true, J = true, K = true, L = true,
    MIDDLE = true,
    RIGHT = true,
    NONE = true,
}

ISR.ValidPinModifierOptions =
{
    NONE = true,
    SHIFT = true,
    CTRL = true,
    ALT = true,
}

-- 早期版本用过单选的 "SHIFT_MIDDLE"，归一化成「修饰键 SHIFT + 动作键中键」。
function ISR.GetPinChord()
    local config = ISR.Config or {}
    local key = config.pin_key
    local modifier = config.pin_modifier or "NONE"

    if key == "SHIFT_MIDDLE" then
        return "MIDDLE", "SHIFT"
    end

    return key, modifier
end

-- 鼠标动作键走「切换」语义：同一个键既固定又清除。
function ISR.IsTogglePinKey()
    local key = ISR.GetPinChord()
    return ISR.PinMouseKeys[key] == true
end

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

function ISR.IsPinModifierDown()
    local _, modifier = ISR.GetPinChord()
    if modifier == nil or modifier == "NONE" then
        return true
    end

    local modifier_code = ISR.PinModifierKeys[modifier]
    local input = ISR.GetInput()
    return modifier_code ~= nil
        and input ~= nil
        and input.IsKeyDown ~= nil
        and input:IsKeyDown(modifier_code)
end

-- 键盘动作键是否按住。鼠标动作键不看这个：它在点击事件里用 button 判。
function ISR.IsPinKeyDown()
    local key = ISR.GetPinChord()
    if key == nil or key == "NONE" or ISR.PinMouseKeys[key] then
        return false
    end

    local keycode = ISR.PinKeys[key]
    local input = ISR.GetInput()
    return keycode ~= nil
        and input ~= nil
        and input.IsKeyDown ~= nil
        and input:IsKeyDown(keycode)
end

-- 「现在是否按住了固定手势」：悬停提示与拦截共用。
-- 鼠标动作键看修饰键；键盘动作键只看它自己。
function ISR.IsPinKeyPressed()
    local key = ISR.GetPinChord()
    if key == nil or key == "NONE" then
        return false
    end

    if ISR.PinMouseKeys[key] then
        return ISR.IsPinModifierDown()
    end

    return ISR.IsPinKeyDown()
end

-- 唯一的接管条件：按住固定手势并点击格子。
-- 鼠标动作键（中键/右键）：必须叠加修饰键（默认 Shift），单击即切换；
--   左/右键一律放行给原版 —— Shift+左键是原版快速转移，不能吞。
-- 键盘动作键（V…L）：本身已足够明确，不再要求修饰键。
--   这条是为了老配置（pin_key=V、升级后没有 pin_modifier 记录）升级后按 V 仍然可用。
function ISR.GetSlotMouseIntent(button)
    local normalized = ISR.NormalizeSlotButton(button)
    if normalized == nil then
        return nil
    end

    local key = ISR.GetPinChord()
    if key == nil or key == "NONE" then
        return nil
    end

    if ISR.PinMouseKeys[key] then
        if not ISR.IsPinModifierDown() then
            return nil
        end

        return normalized == ISR.PinKeys[key] and ISR.SLOT_INTENT_PIN or nil
    end

    if not ISR.IsPinKeyDown() then
        return nil
    end

    return normalized == ISR.SlotMouseButtons.LEFT and ISR.SLOT_INTENT_PIN or ISR.SLOT_INTENT_CLEAR
end

-- 悬停提示里的手势文案：「Shift + 中键」「V + Left Mouse」。
function ISR.GetPinChordLabel(kind)
    local key, modifier = ISR.GetPinChord()
    if key == nil or key == "NONE" then
        return nil
    end

    local parts = {}
    if ISR.PinMouseKeys[key] and modifier ~= nil and modifier ~= "NONE" then
        parts[#parts + 1] = ISR.PinModifierLabels[modifier] or tostring(modifier)
    end

    local entry = ISR.PinKeyLabels[key] or key
    parts[#parts + 1] = type(entry) == "table"
        and (ISR.IsChineseLocale() and entry.zh or entry.en)
        or tostring(entry)

    if not ISR.PinMouseKeys[key] then
        parts[#parts + 1] = kind == ISR.SLOT_INTENT_CLEAR
            and ISR.GetLocalizedControl(ISR.SlotDisplayControls.CLEAR, "Right Mouse")
            or ISR.GetLocalizedControl(ISR.SlotDisplayControls.PIN, "Left Mouse")
    end

    return table.concat(parts, " + ")
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
