ISR = ISR or {}

ISR.Config =
{
    icon_opacity = ISR.ToNumber(GetModConfigData("icon_opacity")) or 0.35,
    debug_log = GetModConfigData("debug_log") == true,
    pin_key = ISR.NormalizeConfigValue(GetModConfigData("pin_key"), ISR.ValidPinKeyOptions, "V"),
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
    "debug_log", tostring(ISR.Config.debug_log)
)
