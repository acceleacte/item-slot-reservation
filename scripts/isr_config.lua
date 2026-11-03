ISR = ISR or {}

ISR.Config =
{
    icon_opacity = ISR.ToNumber(GetModConfigData("icon_opacity")) or 0.35,
    -- 木框透明度：0 完全透明（等于不画框），1 不透明。默认 1，保持加这个选项之前的观感。
    border_opacity = ISR.ToNumber(GetModConfigData("border_opacity")) or 1,
    debug_log = GetModConfigData("debug_log") == true,
    pin_key = ISR.NormalizeConfigValue(GetModConfigData("pin_key"), ISR.ValidPinKeyOptions, "MIDDLE"),
    -- 修饰键：NONE / SHIFT / CTRL / ALT。和 pin_key 组合使用。
    pin_modifier = ISR.NormalizeConfigValue(GetModConfigData("pin_modifier"), ISR.ValidPinModifierOptions, "SHIFT"),
    -- 拾取后是否放回世界里的容器（切斯特、基地箱子）。默认关闭，modinfo 的 default 说了算；
    -- 玩家身上的容器（背包、袋子、背包里的桶）不受这个开关影响，始终接收。
    pickup_to_container = GetModConfigData("pickup_to_container") == true,
    -- 容器作用距离：近 / 中 / 远。只限制世界里的容器，随身携带的容器不受影响。
    container_range = ISR.NormalizeConfigValue(GetModConfigData("container_range"), ISR.ValidContainerRangeOptions, "medium"),
}

if ISR.Config.icon_opacity < 0 then
    ISR.Config.icon_opacity = 0
elseif ISR.Config.icon_opacity > 1 then
    ISR.Config.icon_opacity = 1
end

if ISR.Config.border_opacity < 0 then
    ISR.Config.border_opacity = 0
elseif ISR.Config.border_opacity > 1 then
    ISR.Config.border_opacity = 1
end

ISR.Log(
    "Config",
    "pin_key", tostring(ISR.Config.pin_key),
    "pin_modifier", tostring(ISR.Config.pin_modifier),
    "icon_opacity", tostring(ISR.Config.icon_opacity),
    "border_opacity", tostring(ISR.Config.border_opacity),
    "debug_log", tostring(ISR.Config.debug_log),
    "pickup_to_container", tostring(ISR.Config.pickup_to_container),
    "container_range", tostring(ISR.Config.container_range)
)
