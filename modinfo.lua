name = "Item Slot Reservation"
description = [[
版本 0.1.5

物品格预留（Item Slot Reservation）把储物格固定给指定物品。
基本能放进物品栏的都能固定：草、树枝、木头、石头等材料，武器、工具、帽子等装备。

固定之后：
- 该物品被拾取、制作完成、或从装备栏卸下时，自动回到固定的格子。
- 容器里还留着固定格时，拾取到的物品会直接进那个容器并播放拾取音效。玩家身上的背包（袋子、背包里的桶）永远如此，不受设置影响；「拾取后放回容器」开关（默认关闭）只控制世界里的容器（切斯特、基地箱子）。
- 世界里的容器（基地箱子、跟随中的切斯特）只有在你身边时才接收，距离阈值在设置里选「近 / 中 / 远」；随身携带的容器不受限制。
- 其它物品不会占用这一格；格子被手动塞进别的东西时，预留会自动解除。
- 只能放物品栏的物品（以太余烬、沃拓克斯灵魂）不受预留限制，照常进物品栏。
- 快速转移（Shift + 左键）只落进未预留的格、或该物品自己的预留格；物品栏没有可落点时直接进背包，不会先闪进别人的预留格。

支持玩家物品栏、背包、随身容器和已装备容器；背包里的容器（比如桶）内部同样可以固定；切斯特、哈奇这类跟着你走的容器也算，没带眼骨时打开它一样能固定。
按 V 键后鼠标左键点击已有物品的格子即可固定；同格再按一次取消。
预留跟随容器保存：读档、下地穴（跨 shard）后自动恢复。

--------------------------------

Version 0.1.5

Item Slot Reservation fixes storage slots to specific items.
Anything that fits in the inventory can be fixed: grass, twigs, logs, stone and other materials; weapons, tools, hats and other equipment.

Once fixed:
- The item returns to its fixed slot when picked up, crafted, or unequipped.
- When a fixed slot for it still exists inside a container, the picked-up item goes straight into that container and plays the pickup sound. A container carried on your body (backpack, sack, a tackle box inside it) always does this regardless of the option; the "Pickup into containers" option (off by default) only governs containers standing in the world, such as Chester or a base chest.
- Containers in the world (a base chest, a following Chester) only receive items while you are close enough; pick Near / Medium / Far in the mod options. Containers you carry are not limited.
- Other items do not occupy the slot; forcing another item in clears the reservation.
- Pocket-only items (Ethereal Embers, Wortox Souls) ignore reservations and always go to the inventory.
- Quick transfer (Shift + left-click) only targets unreserved slots or the item's own reserved slot; when the inventory has no room for it the item goes straight to the backpack instead of briefly flickering into someone else's slot.

Supports the player inventory, backpacks, carried containers and equipped containers; containers carried inside them (a tackle box in a backpack, for example) can be fixed too, and so can follower containers like Chester or Hutch.
Hold V and left-click a slot that holds an item to fix it; click again to clear.
Reservations are saved with the container and survive save/load and shard travel.
]]
author = "acceleacte"
version = "0.1.5"
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
    {
        name = "pickup_to_container",
        label = "Pickup into containers / 拾取后放回容器",
        hover = "On: an item picked up goes straight into its fixed slot inside Chester, a tackle box and so on. Off (default): only slots on the player receive the item — the inventory plus any container carried on the body (backpack, sack, a tackle box inside it); containers standing in the world, such as Chester, just stay reserved.\n开启：拾取到的物品直接回到切斯特、桶等世界容器里固定的那一格。关闭（默认）：只有玩家身上的固定格会接收物品（物品栏 + 随身容器：背包、袋子、背包里的桶）；世界里的容器（切斯特、基地箱子）内的固定格仅保留占位。",
        options =
        {
            { description = "On / 开启", data = true },
            { description = "Off / 关闭", data = false },
        },
        default = false,
    },
    {
        name = "container_range",
        label = "Container range / 容器作用距离",
        hover = "How far a fixed slot inside a container still receives picked-up items. Near = 2.5 tiles, Medium = 6 tiles, Far = 12 tiles. Containers you carry (backpack, tackle box in it) are not limited.\n固定格离玩家多远还能自动接收捡到的东西。近 = 约 2.5 格地皮，中 = 6 格，远 = 12 格。随身携带的容器（背包及里面的桶）不受限制。",
        options =
        {
            { description = "Near / 近", data = "near" },
            { description = "Medium / 中", data = "medium" },
            { description = "Far / 远", data = "far" },
        },
        default = "medium",
    },
}
