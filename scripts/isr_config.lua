ISR = ISR or {}

ISR.Config =
{
    -- 语言：zh / en。只管游戏内提示文字，设置项文案固定中文（modinfo 由引擎渲染，改不了）。
    language = ISR.NormalizeConfigValue(GetModConfigData("language"), ISR.ValidLanguageOptions, "zh"),
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
    -- 合成借料（测试版）：合成时自动使用已固定且在作用距离内的世界容器里的材料。
    -- 默认关闭：这一项会改动合成判定，且可能和别的合成类模组打架，要玩家自己开。
    craft_from_container = GetModConfigData("craft_from_container") == true,
    -- 合成提示音的处置：original（原版）/ borrow（只在借料点亮配方时静音）/ silent（全部静音）
    craft_ping = ISR.NormalizeConfigValue(GetModConfigData("craft_ping"), ISR.ValidCraftPingOptions, "borrow"),
    -- 世界容器（基地箱子、无主切斯特）的固定格由谁使用：
    -- shared（默认）不记名，谁能打开就能固定 / 改 / 清，所有人看得见；
    -- exclusive 第一个在这只容器落标记的人独占，别人看不到也动不了。
    container_sharing = ISR.NormalizeConfigValue(GetModConfigData("container_sharing"), ISR.ValidContainerSharingOptions, "shared"),
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
    "language", tostring(ISR.Config.language),
    "pin_key", tostring(ISR.Config.pin_key),
    "pin_modifier", tostring(ISR.Config.pin_modifier),
    "icon_opacity", tostring(ISR.Config.icon_opacity),
    "border_opacity", tostring(ISR.Config.border_opacity),
    "debug_log", tostring(ISR.Config.debug_log),
    "pickup_to_container", tostring(ISR.Config.pickup_to_container),
    "container_range", tostring(ISR.Config.container_range),
    "craft_from_container", tostring(ISR.Config.craft_from_container),
    "craft_ping", tostring(ISR.Config.craft_ping),
    "container_sharing", tostring(ISR.Config.container_sharing)
)
