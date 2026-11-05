-- 固定手势：修饰键 + 动作键的组合判定
-- 键盘动作键保持旧语义（左键固定 / 右键清除），鼠标动作键走切换语义，
-- 且鼠标模式下左右键必须放行给原版（Shift+左键是快速转移）

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

GLOBAL =
{
    CONTROL_ACCEPT = 29,
    CONTROL_SECONDARY = 1,
    CONTROL_PRIMARY = 0,
    MOUSEBUTTON_LEFT = 1000,
    MOUSEBUTTON_RIGHT = 1001,
    MOUSEBUTTON_MIDDLE = 1002,
    KEY_V = 118,
    KEY_B = 98,
    KEY_N = 110,
    KEY_G = 103,
    KEY_F = 102,
    KEY_C = 99,
    KEY_X = 120,
    KEY_Z = 122,
    KEY_R = 114,
    KEY_T = 116,
    KEY_H = 104,
    KEY_J = 106,
    KEY_K = 107,
    KEY_L = 108,
    KEY_SHIFT = 402,
    KEY_CTRL = 401,
    KEY_ALT = 400,
    tonumber = tonumber,
}

local down = {}
local function reset() for key in pairs(down) do down[key] = nil end end

TheInput =
{
    IsKeyDown = function(_, keycode) return down[keycode] == true end,
}
GLOBAL.TheInput = TheInput

dofile(ISR_TEST_ROOT.."/scripts/isr_env.lua")

-- 默认配置：Shift + 中键 = 切换 ------------------------------------------------
ISR.Config = { pin_key = "MIDDLE", pin_modifier = "SHIFT" }
assert_equal(ISR.IsTogglePinKey(), true, "mouse pin keys toggle instead of taking left/right clicks")

reset()
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_MIDDLE), nil, "modifier not held means no interception")

down[GLOBAL.KEY_SHIFT] = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_MIDDLE), ISR.SLOT_INTENT_PIN, "shift + middle click toggles the mark")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), nil, "left click must pass through in mouse mode")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_RIGHT), nil, "right click must pass through in mouse mode")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.CONTROL_ACCEPT), nil, "control events must pass through in mouse mode")

-- 中键不需要修饰键 -------------------------------------------------------------
ISR.Config = { pin_key = "MIDDLE", pin_modifier = "NONE" }
reset()
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_MIDDLE), ISR.SLOT_INTENT_PIN, "middle click alone works without a modifier")

-- 键盘动作键：修饰键不参与 ------------------------------------------------------
-- 老配置（pin_key=V）升级后没有 pin_modifier 记录，会落到默认值 SHIFT；
-- 如果键盘键也要求修饰键，老玩家按 V 就没反应了所以键盘键只看它自己
ISR.Config = { pin_key = "V", pin_modifier = "CTRL" }
assert_equal(ISR.IsTogglePinKey(), false, "keyboard pin keys keep the left/right click semantics")

reset()
down[GLOBAL.KEY_V] = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), ISR.SLOT_INTENT_PIN, "keyboard key works without the modifier")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_RIGHT), ISR.SLOT_INTENT_CLEAR, "keyboard key clears without the modifier")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.CONTROL_SECONDARY), ISR.SLOT_INTENT_CLEAR, "control secondary clears as well")

down[GLOBAL.KEY_CTRL] = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), ISR.SLOT_INTENT_PIN, "holding the modifier changes nothing in keyboard mode")

-- 无修饰键的键盘模式 -----------------------------------------------------------
ISR.Config = { pin_key = "F", pin_modifier = "NONE" }
reset()
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), nil, "unpressed key means no interception")
down[GLOBAL.KEY_F] = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), ISR.SLOT_INTENT_PIN, "F + left click pins")

-- 旧配置值 SHIFT_MIDDLE 向后兼容 ------------------------------------------------
ISR.Config = { pin_key = "SHIFT_MIDDLE" }
assert_equal(ISR.IsTogglePinKey(), true, "legacy SHIFT_MIDDLE still resolves to the toggle mode")
reset()
down[GLOBAL.KEY_SHIFT] = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_MIDDLE), ISR.SLOT_INTENT_PIN, "legacy SHIFT_MIDDLE still pins")

-- NONE 关闭接管 ----------------------------------------------------------------
ISR.Config = { pin_key = "NONE", pin_modifier = "NONE" }
reset()
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), nil, "NONE disables interception")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_MIDDLE), nil, "NONE disables the mouse pin key")

-- 提示文案 ---------------------------------------------------------------------
ISR.Config = { pin_key = "MIDDLE", pin_modifier = "SHIFT" }
assert_equal(ISR.GetPinChordLabel(ISR.SLOT_INTENT_PIN), "Shift + Middle click", "tooltip shows the mouse chord")
assert_equal(ISR.GetPinChordLabel(ISR.SLOT_INTENT_CLEAR), "Shift + Middle click", "mouse mode has a single gesture")

ISR.Config = { pin_key = "V", pin_modifier = "CTRL" }
assert_equal(ISR.GetPinChordLabel(ISR.SLOT_INTENT_PIN), "V + Left Mouse", "keyboard tooltip ignores the modifier")
assert_equal(ISR.GetPinChordLabel(ISR.SLOT_INTENT_CLEAR), "V + Right Mouse", "tooltip names the clear button")
