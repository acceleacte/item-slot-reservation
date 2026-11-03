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
    KEY_SHIFT = 402,
    KEY_CTRL = 401,
    KEY_ALT = 400,
    tonumber = tonumber,
}

local pin_pressed = false
TheInput =
{
    IsKeyDown = function(_, keycode) return pin_pressed and keycode == GLOBAL.KEY_V end,
}
GLOBAL.TheInput = TheInput

GetModConfigData = function(name)
    local values =
    {
        pin_key = "V",
        pin_modifier = "NONE",
        icon_opacity = 0.35,
        border_opacity = 0.6,
        debug_log = false,
    }
    return values[name]
end

dofile(ISR_TEST_ROOT.."/scripts/isr_env.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_config.lua")

assert_equal(ISR.Config.border_opacity, 0.6, "border opacity is read from the config")

assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), nil, "no pin key means no interception")
pin_pressed = true
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_LEFT), ISR.SLOT_INTENT_PIN, "pin key plus left click pins")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.CONTROL_ACCEPT), ISR.SLOT_INTENT_PIN, "control accept maps to pin")
assert_equal(ISR.GetSlotMouseIntent(GLOBAL.MOUSEBUTTON_RIGHT), ISR.SLOT_INTENT_CLEAR, "pin key plus right click clears")
pin_pressed = false

local invslot_postconstruct = nil
AddClassPostConstruct = function(name, fn)
    if name == "widgets/invslot" then
        invslot_postconstruct = fn
    end
end

local original_on_control = function()
    return false
end
local original_mouse_calls = 0
local original_on_mouse_button = function()
    original_mouse_calls = original_mouse_calls + 1
    return false
end

local slot =
{
    num = 3,
    OnControl = original_on_control,
    OnMouseButton = original_on_mouse_button,
}

local current_mark = nil
local pin_calls = 0
local clear_calls = 0
local slot_empty = false
ISR.IsSlotEmpty = function() return slot_empty end
ISR.IsClientMarkableSlot = function() return true end
ISR.GetClientSlotMark = function() return current_mark end
ISR.PinClientSlotMark = function()
    pin_calls = pin_calls + 1
    current_mark = "grass"
    return true
end
ISR.ClearClientSlotMark = function()
    clear_calls = clear_calls + 1
    current_mark = nil
    return true
end
ISR.Log = function() end

dofile(ISR_TEST_ROOT.."/scripts/isr_uihooks.lua")
assert(invslot_postconstruct ~= nil, "inventory-slot postconstruct was not registered")
invslot_postconstruct(slot)

-- 同一次点击可能同时触发鼠标事件与控制事件，测试里用可推进的时钟模拟两次分派
local fake_now = 0
GLOBAL.GetTime = function() return fake_now end
local function advance()
    fake_now = fake_now + 1
end

assert(slot.OnControl ~= original_on_control, "ISR must intercept semantic control dispatch to swallow the click")

-- 不按固定键：一律放行
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_LEFT, true, 0, 0), false, "click without pin key is not consumed")
assert_equal(pin_calls, 0, "click without pin key does not pin")
assert_equal(original_mouse_calls, 1, "click without pin key reaches the original handler")

-- 按住固定键点有物品的格子：吞掉点击并固定
pin_pressed = true
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_LEFT, true, 0, 0), true, "pin click is consumed")
assert_equal(pin_calls, 1, "pin click pins exactly once")
assert_equal(original_mouse_calls, 1, "consumed pin click never reaches the original handler")

-- 控制事件要能被吞掉，否则物品会被拿起来
advance()
assert_equal(slot:OnControl(GLOBAL.CONTROL_ACCEPT, true), true, "control accept is consumed while pinning")
assert_equal(pin_calls, 2, "control accept pins exactly once")

-- 同一次点击：鼠标事件先处理，控制事件在 200ms 内必须被去重
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_LEFT, true, 0, 0), true, "second pin click is consumed")
assert_equal(pin_calls, 3, "second pin click pins once")
assert_equal(slot:OnControl(GLOBAL.CONTROL_ACCEPT, true), true, "duplicate control event is consumed")
assert_equal(pin_calls, 3, "duplicate control event must not pin twice")

-- 空格：固定无意义，放行给原版（这样才能正常拿起放下的逻辑）
slot_empty = true
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_LEFT, true, 0, 0), false, "empty slot falls through")
assert_equal(pin_calls, 3, "empty slot does not pin")
slot_empty = false

-- 右键：仅清除已标记的格子
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_RIGHT, true, 0, 0), true, "marked slot clear is consumed")
assert_equal(clear_calls, 1, "marked slot clears once")

advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_RIGHT, true, 0, 0), false, "unmarked slot clear falls through")
assert_equal(clear_calls, 1, "unmarked slot does not clear again")

-- 松键事件不应该再处理一次
advance()
assert_equal(slot:OnMouseButton(GLOBAL.MOUSEBUTTON_LEFT, false, 0, 0), false, "key release is ignored")
assert_equal(pin_calls, 3, "key release does not pin")

-- tooltip：按住固定键悬停时必须给出提示，且不被格子里物品自身的提示盖掉
local function contains(text, needle)
    return text ~= nil and string.find(text, needle, 1, true) ~= nil
end

slot.SetTooltip = function(self, str) self.tooltip = str end
slot.StartUpdating = function() end
slot.StopUpdating = function() end
slot.focus = true
slot.tooltip = "grass"
-- 格子的物品取自容器：和 slot_empty 保持一致
slot.container =
{
    GetItemInSlot = function(_, num)
        if slot_empty then
            return nil
        end
        return { prefab = "grass", slotnum = num }
    end,
}
-- 模拟格子里有物品：物品图是子 widget，自己带 focus 和 tooltip
slot.tile = { focus = true, tooltip = "grass" }
ISR.RefreshSlotBorderLayout = function() end

slot_empty = false
current_mark = nil
pin_pressed = true
slot:OnUpdate(0)
assert_equal(slot:GetTooltip(), slot.tooltip, "slot tooltip must win over the item image tooltip")
assert(contains(slot:GetTooltip(), ISR.GetText("PIN_MARK")), "hovering a slot with an item must offer pinning, got: "..tostring(slot:GetTooltip()))
assert(not contains(slot:GetTooltip(), "("), "tooltip must not carry parenthesised item names")

-- 已固定同种物品：不再提示左键（这时左键是取消），只留「清除」
current_mark = "grass"
slot:OnUpdate(0)
assert(contains(slot:GetTooltip(), ISR.GetText("CLEAR_MARK")), "pinned slot must offer clearing")
assert(not contains(slot:GetTooltip(), ISR.GetText("PIN_MARK")), "pinned slot must not offer pinning again")
assert(not contains(slot:GetTooltip(), "("), "tooltip must not carry parenthesised item names")

-- 已固定的空格：同样只给「清除」
slot_empty = true
current_mark = "grass"
slot:OnUpdate(0)
assert(contains(slot:GetTooltip(), ISR.GetText("CLEAR_MARK")), "pinned empty slot must offer clearing")
assert(not contains(slot:GetTooltip(), "("), "tooltip must not carry parenthesised item names")

-- 空格未固定：什么都不提示，交回原版
slot_empty = true
current_mark = nil
slot:OnUpdate(0)
assert_equal(slot.tooltip, "grass", "unmarked empty slot keeps the game tooltip")

-- 松开固定键：接管立即撤销
slot_empty = false
current_mark = "grass"
pin_pressed = false
slot:OnUpdate(0)
assert_equal(slot.tooltip, "grass", "releasing the pin key restores the game tooltip")
