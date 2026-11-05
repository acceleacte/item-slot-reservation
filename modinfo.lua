name = "Item Slot Reservation[beta]"
description = [[
按Shift + 鼠标中键 把储物格固定给指定物品
基本能放进物品栏的都能固定：如材料、武器、工具、帽子、护符等

固定之后：
- 该物品被拾取、制作完成、或从装备栏卸下时，自动回到固定的格子
- 其它物品不会占用这一格；格子被手动塞进别的东西时，预留会自动解除
- 只能放物品栏的物品（以太余烬、沃拓克斯灵魂）在物品栏满时不受预留限制
- 快速转移只落进未预留的格、或该物品自己的预留格；物品栏没有可落点时直接进背包
- 世界容器（基地箱子、切斯特）的固定格多人共用：谁能打开就能固定/改/清，别人的标记同样可见、拾取时同样回位

测试内容(默认关闭）：
- 支持世界容器（如：基地箱子、跟随中的切斯特）和随身容器
- 世界里的容器只有在身边时才接收物品
- 合成借料：开启后合成会自动借用箱子里固定格里的材料参与合成，作用距离同上

历史更新日志请前往创意工坊页面查看；如果遇到问题请及时留言反馈
并且可以在模组设置中关闭测试版内容以(尝试)解决问题
]]
author = "acceleacte"
version = "0.1.82"
api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

all_clients_require_mod = true
client_only_mod = false

icon_atlas = "images/modicon.xml"
icon = "modicon.tex"

-- 悬停说明的显示区只有两行（modconfigurationscreen：585×50，字号 22），
-- 每段控制在两行内、并用 \n 手动断行，否则后半句会被截掉
-- 分组标题的做法与原版一致：一个只有单选项、且选项文案为空的条目，
-- screen 里 is_header 会把下拉框和底图隐藏、只放大标题文字
local function Section(name, label)
    return
    {
        name = name,
        label = label,
        hover = "",
        options = { { description = "", data = "header" } },
        default = "header",
    }
end

configuration_options =
{
    Section("section_general", "常规设置"),
    {
        name = "language",
        label = "语言/Language",
        options =
        {
            { description = "中文", data = "zh" },
            { description = "English", data = "en" },
        },
        default = "zh",
    },
    {
        name = "pin_modifier",
        label = "修饰键",
        hover = "仅当固定键是鼠标键时生效；\n选「无」表示不用修饰键",
        options =
        {
            { description = "Shift", data = "SHIFT", hover = "Shift + 固定键切换标记" },
            { description = "Ctrl", data = "CTRL", hover = "Ctrl + 固定键切换标记" },
            { description = "Alt", data = "ALT", hover = "Alt + 固定键切换标记" },
            { description = "无", data = "NONE", hover = "固定键单独按下即切换" },
        },
        default = "SHIFT",
    },
    {
        name = "pin_key",
        label = "固定键",
        hover = "键盘键：按住后左键固定、右键清除\n中键 / 右键：需与修饰键一起按",
        options =
        {
            { description = "中键", data = "MIDDLE", hover = "与修饰键使用" },
            { description = "右键", data = "RIGHT", hover = "与修饰键使用" },
            { description = "V", data = "V" },
            { description = "B", data = "B" },
            { description = "N", data = "N" },
            { description = "G", data = "G" },
            { description = "F", data = "F" },
            { description = "C", data = "C" },
            { description = "X", data = "X" },
            { description = "Z", data = "Z" },
            { description = "R", data = "R" },
            { description = "T", data = "T" },
            { description = "H", data = "H" },
            { description = "J", data = "J" },
            { description = "K", data = "K" },
            { description = "L", data = "L" },
            { description = "无", data = "NONE", hover = "关闭固定手势" },
        },
        default = "MIDDLE",
    },
    Section("section_look", "外观配置"),
    {
        name = "icon_opacity",
        label = "图标透明度",
        hover = "空预留格中物品图标的透明度",
        options =
        {
            { description = "15%", data = 0.15 },
            { description = "25%", data = 0.25 },
            { description = "35%", data = 0.35 },
            { description = "50%", data = 0.50 },
            { description = "70%", data = 0.70 },
            { description = "100%", data = 1.00 },
        },
        default = 0.35,
    },
    {
        name = "border_opacity",
        label = "边框透明度",
        hover = "预留格木框的透明度",
        options =
        {
            { description = "20%", data = 0.20 },
            { description = "40%", data = 0.40 },
            { description = "60%", data = 0.60 },
            { description = "80%", data = 0.80 },
            { description = "100%", data = 1.00 },
        },
        default = 1.00,
    },
    Section("section_container", "测试内容"),
    {
        name = "container_sharing",
        label = "世界容器固定格",
        hover = "箱子、切斯特的固定格由谁使用\n共享：看到就能改 / 独占：只有标记者",
        options =
        {
            { description = "共享(推荐)", data = "shared", hover = "谁能打开谁就能固定、改、清" },
            { description = "独占", data = "exclusive", hover = "只有第一个标记的人能用" },
        },
        default = "shared",
    },
    {
        name = "pickup_to_container",
        label = "拾取后放回容器",
        hover = "开启：拾取物直接进箱子等世界容器的固定格\n关闭：只有物品栏和随身容器的固定格接收",
        options =
        {
            { description = "开启", data = true, hover = "世界容器的固定格也接收拾取物" },
            { description = "关闭", data = false, hover = "只有物品栏和随身容器的固定格接收" },
        },
        default = false,
    },
    {
        name = "container_range",
        label = "容器作用距离",
        hover = "世界容器离你多远能接收物品\n近 2.5 格 / 默认 6 格 / 远 12 格",
        options =
        {
            { description = "近", data = "near", hover = "约为切斯特的跟随范围" },
            { description = "默认", data = "medium", hover = "基本覆盖大部分基地范围" },
            { description = "远", data = "far", hover = "大型基地范围" },
        },
        default = "medium",
    },
    {
        name = "craft_from_container",
        label = "合成借料",
        hover = "固定后无需打开箱子可使用内部材料参与合成\n可能与部分模组冲突，异常时优先关闭排查",
        options =
        {
            { description = "关闭", data = false, hover = "只用物品栏和已打开的容器合成" },
            { description = "开启", data = true, hover = "借用容器里已固定的材料合成" },
        },
        default = false,
    },
    {
        name = "craft_ping",
        label = "合成提示音",
        hover = "借料点亮配方时原版会响一声",
        options =
        {
            { description = "借料时静音(推荐)", data = "borrow", hover = "在借料点亮配方时静音" },
            { description = "原版", data = "original", hover = "会很吵" },
            { description = "全部静音", data = "silent", hover = "彻底关掉" },
        },
        default = "borrow",
    },
    Section("section_advanced", "高级"),
    {
        name = "debug_log",
        label = "调试日志",
        hover = "向日志输出标记诊断信息，排查问题时打开",
        options =
        {
            { description = "关闭", data = false },
            { description = "开启", data = true },
        },
        default = false,
    },
}
