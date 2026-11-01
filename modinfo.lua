name = "Item Slot Reservation"
description = [[
版本 0.1.2

物品格预留（Item Slot Reservation）把储物格固定给指定物品。
基本能放进物品栏的都能固定：草、树枝、木头、石头等材料，武器、工具、帽子等装备。

固定之后：
- 该物品被拾取、制作完成、或从装备栏卸下时，自动回到固定的格子。
- 其它物品不会占用这一格；格子被手动塞进别的东西时，预留会自动解除。

支持玩家物品栏、背包、随身容器和已装备容器。
按 V 键后鼠标左键点击已有物品的格子即可固定；同格再按一次取消。
预留跟随储物实体保存，读档自动恢复。

--------------------------------

Version 0.1.2

Item Slot Reservation fixes storage slots to specific items.
Anything that fits in the inventory can be fixed: grass, twigs, logs, stone and other materials; weapons, tools, hats and other equipment.

Once fixed:
- The item returns to its fixed slot when picked up, crafted, or unequipped.
- Other items do not occupy the slot; forcing another item in clears the reservation.

Supports the player inventory, backpacks, carried containers and equipped containers.
Hold V and left-click a slot that holds an item to fix it; click again to clear.
Reservations persist with the container entity and survive save/load.
]]
author = "acceleacte"
version = "0.1.2"
api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

all_clients_require_mod = true
client_only_mod = false

icon_atlas = "images/modicon.xml"
icon = "modicon.tex"

configuration_options =
{
    {
        name = "pin_key",
        label = "Pin key / 固定键",
        hover = "Hold this key and click a slot that already holds an item to fix that slot for it. Works for grass, twigs and every other resource.\n按住此键 + 左键点击已有物品的格子，即可把该格固定给这种物品。草、树枝等资源同样适用。",
        options =
        {
            { description = "V", data = "V" },
            { description = "B", data = "B" },
            { description = "N", data = "N" },
            { description = "G", data = "G" },
            { description = "None / 无", data = "NONE" },
        },
        default = "V",
    },
    {
        name = "icon_opacity",
        label = "Icon opacity / 图标透明度",
        hover = "Opacity of the item icon shown on empty reserved slots.\n空预留格中物品图标的透明度。",
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
        name = "debug_log",
        label = "Debug log / 调试日志",
        hover = "Print slot-mark diagnostics to client_log/server_log.\n向 client_log/server_log 输出标记诊断信息。",
        options =
        {
            { description = "Disabled / 关闭", data = false },
            { description = "Enabled / 开启", data = true },
        },
        default = false,
    },
}
