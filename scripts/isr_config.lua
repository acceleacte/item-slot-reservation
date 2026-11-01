ISR = ISR or {}

ISR.Config =
{
    icon_opacity = ISR.ToNumber(GetModConfigData("icon_opacity")) or 0.35,
    debug_log = GetModConfigData("debug_log") == true,
    pin_key = ISR.NormalizeConfigValue(GetModConfigData("pin_key"), ISR.ValidPinKeyOptions, "V"),
    -- 拾取后是否直接放回容器（切斯特、背包里的桶……）。没配过（旧存档）按开启处理。
    pickup_to_container = GetModConfigData("pickup_to_container") ~= false,
    -- 容器作用距离：近 / 中 / 远。只限制世界里的容器，随身携带的容器不受影响。
    container_range = ISR.NormalizeConfigValue(GetModConfigData("container_range"), ISR.ValidContainerRangeOptions, "medium"),
}

if ISR.Config.icon_opacity < 0 then
    ISR.Config.icon_opacity = 0
elseif ISR.Config.icon_opacity > 1 then
    ISR.Config.icon_opacity = 1
end

ISR.Log(
    "Config",
    "pin_key", tostring(ISR.Config.pin_key),
    "icon_opacity", tostring(ISR.Config.icon_opacity),
    "debug_log", tostring(ISR.Config.debug_log),
    "pickup_to_container", tostring(ISR.Config.pickup_to_container),
    "container_range", tostring(ISR.Config.container_range)
)
