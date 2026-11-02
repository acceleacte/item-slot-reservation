# AGENTS.md — item-slot-reservation

> 给接手这个目录的人（或 agent）看的内部说明。用户向的使用说明在 `README.md`。

## 1. 这是什么

**Item Slot Reservation（ISR，物品格预留）**：把储物格固定给指定物品（prefab）。物品被拾取、制作完成、从装备栏卸下时自动回到该格，其它物品避开它。

| 项 | 值 |
|---|---|
| 模组名 | Item Slot Reservation |
| 版本 | 0.1.41（`modinfo.lua`） |
| 类型 | 服务器模组，`all_clients_require_mod = true`（2026-10-31 由 false 改来，见 §9.5），`client_only_mod = false` |
| `api_version` | 10 |
| 全局表 | `ISR`（同时挂到 `GLOBAL.ISR`） |
| RPC 命名空间 | `item_slot_reservation` |
| 组件名 | `isr_slotmarkstore` |
| 作者 | 留空（`author = ""`） |

自建模组：代码从零编写，不 require、不引用任何第三方模组的文件、资源或命名空间；模块之间只通过全局 `ISR` 表交互。标记模型只有「prefab ↔ 格子」一种，不要引入按装备部位、按物品分类之类的第二套键。

---

## 2. 文件结构（4000 行 Lua，29 个测试）

```
modmain.lua                 19 行，13 个 modimport，顺序有依赖（env → config → icons → storage → markstores → slotmarks → placement → candidates → debug → persistence → inventoryhooks → clientpredict → uihooks）
modinfo.lua                117 行，配置项 + 双语文案
scripts/
  isr_env.lua              244  GLOBAL 取值兜底、按键码归一化、点击意图、prefab 键工具、距离档位、i18n
  isr_config.lua            27  读 GetModConfigData（pin_key / icon_opacity / debug_log / pickup_to_container / container_range）
  isr_icons.lua            202  空格物品图标 + 木框渲染
  isr_storage.lua          483  存储适配器注册表 + 内置适配器 + 容器归属判定 + 作用距离
  isr_markstores.lua       153  组件挂载、按 GUID 找 store、标记容器注册表、随身实例递归枚举
  isr_slotmarks.lua        490  服务端标记 CRUD、匹配判定、客户端缓存、拾取音效、5 个 RPC handler
  isr_placement.lua        205  放置路由决策、标记优先级（容器 / 物品栏）、距离过滤、transfer 上下文栈
  isr_candidates.lua       521  候选格搜索（堆叠/溢出/专用容器优先）
  isr_debug.lua            106  自检 + 控制台标记入口
  isr_persistence.lua      390  客户端能力白名单、全量同步、旧开发版存档迁移、玩家级标记备份（含嵌套路径）
  isr_inventoryhooks.lua   346  GiveItem / GetNextAvailableSlot / Shift 转移 hook
  isr_clientpredict.lua    326  客户端落点预测（标记先行判落点 → 背包预测 / 守卫窗口）
  isr_uihooks.lua          348  invslot / inventorybar / containerwidget 的 UI hook
  components/isr_slotmarkstore.lua  159  标记存储组件（OnSave/OnLoad、add_component_if_missing、owner、注册表登记）
tests/                      29 个 lua 测试 + run_lua_tests.py
images/                     modicon + wood_frame_128_ARGB（木框贴图）
```

---

## 3. 核心设计

### 3.1 标记只有一种：prefab

- 服务端组件里存 `{ slot, prefab, order }`。
- 客户端缓存 `marks[<container_guid>:<slot>] = prefab`（字符串）。
- RPC：`set_slot_mark(container_inst, slot, prefab)`、`sync_slot_mark(container_inst, slot, prefab, play_clear_sound)`；空串表示清除。
- 匹配只有一条规则：`ISR.MarkMatchesItem(mark, item)` → 双方 prefab 归一化后比较。

**没有 `kind` 字段、没有 `eslot` 字段、没有装备部位枚举、没有 `equipslotutil` 依赖。**
读到 0.1.0 之前开发版的 `{ eslot = ..., kind = ... }` 旧记录时按 prefab 兼容读取；`kind == "eslot"` 的直接丢弃（`isr_slotmarkstore.lua:OnLoad`、`isr_slotmarks.lua:GetMarkPrefab`）。这是唯一的向后兼容代码，不要在此基础上恢复装备部位功能。

### 3.2 「自动回位」没有搬运代码

`Inventory:Unequip(eslot)` 只清空装备槽并推 `unequip` 事件，物品不落背包。真正放回背包的是调用方：
`inventory:GiveItem(inventory:Unequip(eslot))`（游戏脚本 `scripts/actions.lua:942`、`scripts/standardcomponents.lua:1856/2083`）。

所以卸下、拾取、制作完成全部经由 `GiveItem`，而 `GiveItem` 已在 `isr_inventoryhooks.lua` 里包装成「按标记直投」。
**不要**再 hook `Unequip` 或监听 `unequip` 事件搬东西——会和 `GiveItem` 路由打架，表现为物品被移动两次。

### 3.3 客户端能力白名单

`all_clients_require_mod = false`，收端可能根本没装模组，往未知命名空间丢 RPC 属于噪声。

- `isr_persistence.lua` 的 `ISR._capable_clients`；只有发过 ISR RPC 的玩家才算能力客户端（`ISR.MarkClientCapable`）。
- 两个登记入口：`set_slot_mark`、`request_marks_sync`。
- `ISR.SyncMarkToClient` / `ISR.SyncAllMarksToClient` 首行检查 `ISR.IsClientCapable`。
- 冷启动顺序：服务端早期推送会被跳过，靠客户端 `RequestMarkSnapshot()`（0.25s 防抖）补齐 —— 这是设计内的自愈路径，不是 bug。

### 3.4 点击接管只有一条路径

`ISR.GetSlotMouseIntent(button)`：按住 `pin_key`（默认 V）才返回意图，否则 `nil`，原版逻辑照常执行。

- 左键 → `SLOT_INTENT_PIN`；右键 → `SLOT_INTENT_CLEAR`。
- 按钮码经 `ISR.NormalizeSlotButton` 归一化（`MOUSEBUTTON_*` ↔ `CONTROL_PRIMARY/ACCEPT/SECONDARY`）。
- `invslot` 上 **`OnMouseButton` 和 `OnControl` 都要包**：拾取物品走 `OnControl(CONTROL_ACCEPT)`，只包鼠标挡不住点击。
- 两路会对同一次点击各触发一次，用 `slot._isr_intent_stamp` 做 200ms 去重，否则连标两次 = 直接取消。

### 3.5 悬停提示必须覆写 `GetTooltip`

`Widget:GetTooltip()` 是**先遍历子 widget、再读 `self.tooltip`**：

```lua
function Widget:GetTooltip()
    if self.focus then
        for k, v in pairs(self.children) do
            local str = k:GetTooltip()
            if str ~= nil then return str end
        end
        return self.tooltip
    end
end
```

格子里有物品时，物品图 `self.tile` 是子 widget 且自带提示，**只调 `slot:SetTooltip(...)` 会被它盖掉** —— 表现就是「有物品的格子按住 V 看不到提示，空格反而正常」（0.1.0 首版的 bug，已修）。

所以 `isr_uihooks.lua` 在 `AddClassPostConstruct("widgets/invslot")` 里额外覆写实例方法 `GetTooltip`：有接管串时直接返回 `_isr_tooltip_override`，否则回落原实现。新增提示逻辑照此办理，别再退回「只 SetTooltip」。

提示内容（`BuildSlotTooltip`）：

| 格子状态 | 提示 |
|---|---|
| 有物品、未固定 | `左键: 固定此格` |
| 有物品、已固定 | `右键: 清除` |
| 空格、已固定 | `右键: 清除` |
| 空格、未固定 | 不接管，交回原版 |

两条硬规则（用户明确要求，别再改回去）：

1. **不带物品名、不带括号**。格子里已经画出物品，重复名字没有信息量。
2. **已固定的格子不提示左键**。此时左键是取消固定，写「取消固定」是噪音；只保留右键清除。

取 prefab 只为判断「格子里有没有东西」：`GetSlotItemPrefab` 依次尝试 `container:GetItemInSlot` → `container.itemslots` → `container.slots`。

### 3.6 Shift 转移的落点顺序

Shift + 左键转移走 `MoveItemFromAllOfSlot` / `Half` / `Count`，包装只压一个 `shift_transfer` 转移上下文（`source_guid` = 源容器，`target_guid` = 目标容器），真正选格仍在 `inventory:GiveItem` / `container:GiveItem` 里做。

物品栏方向的落点顺序（`isr_inventoryhooks.lua`，用户指定，别再调换 2 和 3）：

| 顺序 | 规则 | 实现 |
|---|---|---|
| 1 | 该物品有预留格且为空 → 直投 | `TryPlaceByMarks` → `CanUseEmptySlot` |
| 2 | 物品栏里同类未满的堆 → 堆进去 | `CanStackIntoInventorySlot` |
| 3 | 原版给的格未被别人预留 → 采用 | `GetNextAvailableSlot` 包装的第二段判断 |
| 4 | 物品栏里未被别人预留的空格 | `CanUseEmptyInventorySlot` |
| 5 | 都没有 → **交回原版，落背包/随身容器** | `old_GiveItem(self, inst, nil, src_pos)` |

第 5 步以前是「临时置 `ignoreoverflow`/`ignorespoverflow` 后调原版」，效果是把背包一起屏蔽、整单失败。0.1.3 起不再屏蔽：物品栏满就把东西放进背包，背包也满或来源本身就是背包（原版会给 `ignoreoverflow` 置真）时才留在原处。`GiveItemWithOverflowBlocked` 已删除，不要复活。

**踩过的坑（0.1.2）**：物品栏 15 格全被预留时，任何「没有预留格」的物品（日志实测 `meat`）在 `GetFallbackUnmarkedEmptySlot` 拿不到格 → 打 `Reserved inventory full` → 回弹到源容器。同期客户端预测 `inventory_classified:ReceiveItem` 不认预留，会先把物品画进固定格再被服务端回滚，看起来像「短暂进格又弹回」。

### 3.7 客户端预测

服务端把物品放进背包之后，画面还会闪一下：物品先被画进别人的预留格，一个 RTT 后才跳进背包。原因在原版的**预测**路径，`prefabs/inventory_classified.lua` 的 `ReceiveItem` 只按「第一个能放的格」挑位置，完全不认预留标记。那段时间里被预测占用的格会挡住真正属于它的物品。

`isr_clientpredict.lua` 分两层，**顺序不能换**：

| 层 | 实现 | 作用 |
|---|---|---|
| 1. 判落点 | `ISR.CanPredictLandInInventory(inventory, item)` 按客户端标记算：自己的空预留格 → 同类未满堆（该格没被别人预留）→ 未预留空格 → 装备栏堆叠 | 算出来「物品栏没有落点」时，服务端必定走 GiveItem 的背包兜底，预测就**直接画进背包**（`PredictIntoOverflow`） |
| 2. 守卫窗口 | `AddPrefabPostInit("inventory_classified")` 包住 `inst.ReceiveItem`，窗口内把 `player.replica.inventory.CanTakeItemInSlot` 换成守卫版：别人的预留格 → 假 | 还有落点时才用得上：原版搜索跳过被预留的格，落在该落的那一格 |

关键：第 1 层解决「物品栏没位置」，第 2 层解决「物品栏有位置但顺序不对」。只有第 2 层时，全预留会逼死预测，原版那时**连 RPC 都不发**（`container_classified:MoveItemFromAllOfSlot` 只在 `remainder ~= nil` 时 `SendRPCToServer`），玩家看到的是「按了没反应」；改用「失败就退回原版预测」的兜底，又会退回原版预测、照样闪进预留格。两条弯路都走过，别回头。

`PredictIntoOverflow` 的失败原因决定下一步（别合并成一个 nil）：

| 原因 | 处理 |
|---|---|
| 预测成功 | 返回背包的 remainder；Shift 转移拿到 0 就照常发 RPC、清源格 |
| `busy`（背包正在刷新） | 退回原版预测保住这次点击，这一帧可能闪一下 |
| `none` / `full`（没背包、来源就是背包、背包满） | **返回 nil**：服务端同样放不下，既不预测（否则先闪进预留格再弹回），也不发 RPC |

`CanPredictLandInInventory` 的入参是**物品栏 replica**，不是 classified 实体 —— 在 `ReceiveItem` 包装里要传 `self._parent.replica.inventory`（第一版就错在这里，判断恒为真）。

注意：`CanTakeItemInSlot` 是**实例级**替换（`replica._isr_prediction_guard` 防重复），不碰类；只有窗口打开的那一瞬生效，所以拖拽判定、UI 校验都不受影响。别改成全局替换。

日志（`debug_log=true`）：`Client predict overflow` / `Client predict overflow busy` / `Client predict dropped` / `Client predict blocked ... allowed ... rejected ...` / `Client predict end ... remainder ...`。

### 3.8 可标记容器的范围（组件语义判定，不枚举 prefab）

能标记的只有「属于这名玩家的容器」。判定**只看组件语义**，不维护 prefab 名单 —— 新的容器、别的模组的容器、跟随型容器都不用逐个登记：

| 归属 | 判定 |
|---|---|
| **容器上记过的 owner**（最先判） | `SlotMarkStore:GetOwner()` 存 userid，随存档走。切斯特没眼骨时不跟随任何人，组件语义判不出来，就靠这个字段。有 owner 时**直接以它为准**，不再看后面的规则 —— 眼骨转手给朋友，标记仍归原主 |
| 玩家自己 | `inst == player` |
| 物品类容器（背包、桶、箱子） | `inventoryitem:GetGrandOwner()` 沿 owner 链找终点，终点再按下一行判归属。背包丢地上时链断在 nil，自动排除 |
| 跟随型容器（切斯特、哈奇、Woby） | `follower:GetLeader() == player` |
| 骑乘中的载具 | `rideable.rider == player` |

实现在 `isr_storage.lua`：`ISR.IsEntityOwnedByPlayer`（实体归属）、`ISR.IsStorageOwnedByPlayer`（容器归属，owner 字段优先，其次 owner 链，最后实体本身）、`ISR.IsMarkableContainerForPlayer`（RPC 入口）。

**第一次落标记的放行条件比归属宽**：`set_slot_mark` 的 RPC 里，除了归属判定，**容器此刻正被这名玩家打开**（`container:IsOpenedBy(player)`）也直接放行（`isr_slotmarks.lua`）。切斯特没眼骨时 `follower:GetLeader()` 是 nil，只有这条能让它可标记。放行之后写入 owner，之后别人再打开也改不了（`reason = "owner"` 拒绝）。

**枚举走注册表，不走「玩家身上有什么」**：`isr_markstores.lua` 的 `ISR._mark_containers`（GUID → 实体）。`SlotMarkStore:SetMark` 与 `OnLoad` 时登记，`ClearMark` 清空后与 `OnRemoveFromEntity` 时注销，`GetMarkContainerInstances` 顺手清理失效实体。`ISR.GetServerMarks` 遍历注册表 + 归属过滤 —— 这样切斯特这类**不在玩家物品栏里**的容器也能算进同步、自动回位与匹配判定。

客户端判定（`ISR.IsClientMarkableContainerInst`）分三段，任一段通过即放行：

1. `replica.follower:GetLeader() == player`（跟随容器）；
2. 物品栏/装备栏一层 + `replica.container:GetItemInSlot` 往下扫一层（容器树，靠 classified，只有打开过的容器有数据）；
3. **兜底**：`replica.container:GetNumSlots() > 0` 就放行，交给服务端裁决 —— `inventoryitem` 的 replica 不带 owner，客户端拼不出完整归属链（切斯特身上的背包就是这种情况），服务端拒绝时会 `SyncAuthoritativeSlotMark` 回推真实状态。

深度上限 `ISR.PERSONAL_STORAGE_DEPTH = 3`：玩家(1) → 物品栏容器(2) → 容器里的容器(3)。`GetPersonalStorageInstances`（备份路径用）按这个上限递归，带 `seen` 防环。

备份路径支持嵌套：`equip:back/3` = 装备栏背包第 3 格的容器；`ISR.ResolveStoragePath` 按 `/` 分段还原。跟随型容器没有稳定路径（不在物品栏里），备份跳过它，靠组件本身持久化恢复（见 §4.1 第 1 层）。

别把客户端判定改成「有 `replica.container` 就认」：没打开过的容器也有 `replica.container` 壳子，`GetNumSlots()` 返回 0，那样谁都能点。

### 3.9 拾取落点优先级与音效（0.1.4 起）

同一种物品可能同时有「玩家物品栏固定格」和「容器内固定格」（切斯特第 6 格 + 物品栏第 8 格就出现过）。`TryPlaceByMarks` 按 `ISR.Config.pickup_to_container` 决定顺序：

| 配置 | 行为 |
|---|---|
| 开启 | 世界容器与随身容器的标记都参与：容器内标记排前面（同类内部仍按 `order`），玩家物品栏标记排后面。拾取到的东西直接进容器 |
| 关闭（默认） | **世界里的容器**（切斯特、哈奇、基地箱子）标记不参与；玩家身上的容器（背包、克朗普斯袋子、背包里的桶）标记照常参与，顺序同「开启」；都没有可用固定格就交回原版落点 |

**随身容器不受开关控制**（2026-11-02 用户指定）：背包是玩家的延伸，关了开关也得自动回位。判定在 `isr_placement.lua` 的 `IsCarriedContainerMark` → `ISR.IsStorageCarriedByPlayer`（`isr_storage.lua`，只认 owner 链：`inst == player` 或 `inventoryitem:GetGrandOwner() == player`）。切斯特、哈奇是 follower 不是 carried，仍归开关管 —— 别把这条判定换成 `IsStorageOwnedByPlayer`，那个对切斯特也返回真。

排序在 `isr_placement.lua` 的 `OrderMarksForConfig`，`IsOwnInventoryMark` 判 `mark.container_guid == owner.GUID`。

**判断「这一格能不能放」用 `adapter:CanUseSlot`，不是 `CanUseEmptySlot`**：固定格里已经有同种物品的**未满堆叠**时要认这一格（草、树枝采完就是并进那一堆），只判空会把资源推回物品栏——容器没打开时最明显（0.1.4 的日志：`Marked placement no hit cutgrass` 紧跟着 `Inv give result cutgrass slot 1`，就是槽里那堆草挡着）。`CanUseEmptySlot` 仍留给「找空格」的候选搜索用，两者语义别混。适配器没实现 `CanUseSlot` 时回落到 `CanUseEmptySlot`。

**音效**：物品直接进容器时，玩家物品栏不会走 `Inventory:GiveItem` 的 `gotnewitem`（`inventory.lua:1100` 那里才播拾取音），所以原版一点声音都没有。补法是 `ISR.PlayPickupSound(owner, item)`（`isr_slotmarks.lua`）：照原版 `player_common.lua` 的 `OnGotNewItem` 查 `PICKUPSOUNDS[item.pickupsound or "DEFAULT_FALLBACK"]`，**直接挂在玩家实体的 SoundEmitter 上**——这段代码只在服务端跑，服务端实体上的声音会同步给附近客户端（和原版 drop 音一个路子）。物品把 `pickupsound` 设成 `"NONE"` 时不响，和原版一致；owner 没有 SoundEmitter 就直接跳过，不报错。

只在 `context.inventory ~= nil`（玩家物品栏发起的 GiveItem）且目标不是玩家自己时播 —— 容器侧的 STORE / 掉落不该有拾取音。

**作用距离**（`container_range`）：世界里的容器不设限就是「站在地图另一头也能把东西送进基地箱子」，破坏平衡。判定在 `ISR.IsStorageWithinRange`（`isr_storage.lua`）：

| 容器 | 规则 |
|---|---|
| 玩家自己的物品栏 | 不设限 |
| 随身携带（owner 链终点是玩家：背包、背包里的桶） | 不设限，永远算在手边 |
| 世界里的容器（基地箱子、切斯特、哈奇） | 量玩家到它的水平距离，超过档位就不送 |
| 装在别的容器里的（limbo，无世界坐标） | 用宿主容器的位置算：在近处的切斯特里 → 通过；在远处的箱子里 → 拒绝 |

档位 `ISR.ContainerRangeLimits`：`near = 10`、`medium = 24`、`far = 48`（世界单位，4 = 一格地皮）。切斯特的唤醒跟随距离是 14，所以 near 够它跟随用。拿不到 `Transform` 的实体一律放行：宁可送不进去，也别把物品卡在半路。跳过时日志 `Marked placement no hit ... skipped <guid>@<slot>:range`。

---

## 4. 数据流

```
客户端按住 V 点格
  → PinClientSlotMark：读格中物品 prefab，写本地缓存（乐观显示图标）
  → set_slot_mark RPC
  → 服务端校验（prefab 合法 / 容器可标记 / 槽位在范围 / 格子为空或格中物品与标记匹配）
  → 存进容器实体的 isr_slotmarkstore
  → 回推 sync_slot_mark 覆盖客户端缓存（客户端以服务端为准）

物品要进包
  → GiveItem 包装 → MakePlacementContext
  → ShouldRoutePlacementByMarks：这个物品有预留格吗？
  → 有：按 order 依次尝试 GetSortedServerMarksForPrefab 的格子，落位成功即 return true
  → 没有 / 落位失败：走原版逻辑
  → 原版 GetNextAvailableSlot 也包了一层，跳过别人的预留格
```

标记存在**容器实体**上（玩家 = 玩家实体，背包 = 背包实体），不存玩家身上。背包丢地上被捡走，标记跟着背包走 —— 设计选择。

### 4.1 持久化与读档恢复（0.1.4）

三层，缺任何一层都会出现「读档 / 下地穴后标记消失」：

| 层 | 位置 | 作用 |
|---|---|---|
| 1 构造期挂载 | `isr_markstores.lua` 的 `AddComponentPostInit("container")`，**无条件**给容器实体挂 store | 所有 `container` 实体（背包、桶、切斯特、哈奇、箱子、锅）在 prefab 构造期就带 `isr_slotmarkstore`，读档时 `EntityScript:SetPersistData` 里组件天然存在，数据直接 `OnLoad`。顺带覆盖两类顺序颠倒的 prefab：`beargerfur_sack`（第 190 行 container、第 201 行才 inventoryitem）、`tacklecontainer`（103 / 112）。空 store `OnSave` 返回 nil，不产生存档数据。 |
| 2 玩家级备份 | `isr_persistence.lua` 的 `ISR.MARK_BACKUP_KEY`（`isr_slot_marks`） | `player:OnSave` 把随身容器的标记按「在身上的位置」写成快照：`inv` = 玩家自身、`inv:<N>` = 物品栏第 N 格、`equip:<槽>` = 装备栏某槽，嵌套用 `/` 接（`equip:back/3` = 装备栏背包第 3 格的容器）。`OnLoad` 之后按位置补回**空缺**的格，已有标记优先、不覆盖。兜住跨 shard 时引擎没搬过来的数据。跟随型容器（切斯特、哈奇）没有稳定路径，备份跳过，靠第 1 层。 |
| 3 加载期不清除 | `isr_inventoryhooks.lua` 的 `IsStorageLoading` | 原版 `Inventory:OnLoad` / `Container:OnLoad` 会用存档槽位号调 `GiveItem`，包装里「物品与标记不符就清标记」在加载中是误伤。`Container:OnLoad` 期间置 `_isr_loading`，`Inventory` 用原版已有字段 `isloading`，两者都跳过清除。 |

**存档数据里禁止写 `add_component_if_missing`**（0.1.5 起）。这个 flag 会让引擎在缺组件时强制 `AddComponent`（`entityscript.lua:1980`），而组件由本模组提供：玩家一关模组，`require` 抛错打断 `SpawnSaveRecord` → `PopulateWorld`，**存档永久进不去**（2026-11-02 实测切斯特必崩，`master_server_log.txt` 报 `module 'components/isr_slotmarkstore' not found`）。不带 flag 时模组关闭只会让这份数据被静默跳过，世界照常加载。

**旧版（≤0.1.41）存档的迁移**：旧数据带 flag。0.1.5 进档时组件已在（第 1 层），`components[k] == nil` 不成立，引擎不会补建，所以不崩；保存一次后数据被重写成无 flag 格式，迁移完成。迁移前不能关模组。README「注意」一节对玩家写了同样的话。

**曾经试过、后来否掉**：组件只在「container 且已有 inventoryitem」时挂，靠 flag 自愈补建 —— 这就是不可卸载的来源。也不要给 `MakeInventoryPhysics` 之后补 hook，它只加物理、不加 inventoryitem（`standardcomponents.lua`）。

诊断（`debug_log=true`）：读档后打 `Mark backup restored restored=N kept=M missing_container=K`。

---

## 5. 操作与配置

| 操作 | 默认键位 |
|---|---|
| 固定 / 取消固定（点已有物品的格子） | `V` + 左键 |
| 清除标记（不要求格子为空） | `V` + 右键 |
| 控制台预留 | `ISR.DebugSetPrefabMark(3, "cutgrass")`，背包 `(2, "twigs", true)` |
| 控制台清除 | `ISR.DebugClearSlotMark(3)` |

配置项（`isr_config.lua` 读）：`pin_key`（V/B/N/G/NONE）、`icon_opacity`（0~1，默认 0.35）、`debug_log`、`pickup_to_container`（默认 false；只管世界容器，随身容器永远接收）、`container_range`（near / medium / far，默认 medium）。

**不要**再加 `mark_modifier` / `prefab_mark` 这类选项：早期开发版曾用组合键循环标记、并用开关控制物品标记，0.1.0 已把它们删掉，只剩「按住固定键点格子」一条路径。

---

## 6. 本地环境

- 仓库：本目录即 git 仓库根，模组文件就在根目录（不含 `dist/`、`.workbuddy/`、`.lua-test-runtime/`）
- 游戏加载路径：**创意工坊 `workshop-3830575143`**（2026-10-31 上传并订阅）。`ForceEnableMod` 已移除，存档 `modoverrides` 已改为 `["workshop-3830575143"]`
- **发布源是工作区根的 `Item-slot-reservation\` 文件夹**，不在本仓库内。更新版本时改那里的 `modinfo.lua` 与脚本，再由维护者在游戏内 Upload。
- **不要把发布目录复制进 `mods\item-slot-reservation\`**。工坊订阅版已加载，多一份本地副本会让模组列表出现两个同名条目。上传后 Steam 自动拉取到 `workshop\content\322330\3830575143\`，无需手动同步缓存。
- 工坊不接受同版本覆盖：每次 Upload 前必须升 `modinfo.lua` 的 `version`。
- 启用方式：各存档 `modoverrides.lua` 勾选工坊 id；不再用 `ForceEnableMod`（会与工坊版本重复加载）
- **本地测试副本**（按需临时建）：`mods\item-slot-reservation-test\`，从发布目录拷入，脚本与仓库逐字节一致，只有 `modinfo.lua` 不同 —— `name` 带 `[TEST]` 前缀、`version` 带 `-test` 后缀、描述首行写「本地测试版」，好和工坊版区分。只为 `Cluster_4`（存档名「测试」）启用，该存档把 `workshop-3830575143` **整条移除**（不是 `enabled=false`，否则两份 hook 叠加）。测完把目录**移入** `backup\item-slot-reservation-test-<版本>-<日期>\`（不要留在 `mods\` 里），再用 `backup\modoverrides.Cluster_4_{Master,Caves}.bak-testmod-<日期>` 覆盖回原位置。2026-11-01 反复用过（0.1.4 全程），当前仍留在 `mods\` 等工坊上传后清理。
- 改完代码必须**同时重启客户端和两个 dedicated server 进程**：服务端是独立进程，只重启客户端加载不到服务端改动
- 日志：`Documents\Klei\DoNotStarveTogether\client_log.txt` / `master_server_log.txt`，标签 `[ItemSlotReservation]`，需在设置里开「调试日志」

---

## 7. 跑测试

```bash
# 在仓库根直接跑（路径全是 ASCII，不必复制）
export ISR_LUPA_PATH="C:/Users/Administrator/DeskBox/work/WorkBuddy/Don't Starve-mod/.lua-test-runtime"
python tests/run_lua_tests.py
```

两个坑：

1. lupa 不在仓库里（避免把二进制依赖提交进 git）；`run_lua_tests.py` 依次找 `ISR_LUPA_PATH` 环境变量、`tests/../.lua-test-runtime`、工作区级的 `../../.lua-test-runtime`。实际装在工作区根的 `.lua-test-runtime`（`Don't Starve-mod\.lua-test-runtime`）。
2. lupa 2.8（Lua 5.5）的 `io.open` 读不了中文路径 → 仓库路径本身是 ASCII，可以原地跑；要换成含中文的目录就得先 `cp -r` 到纯 ASCII 目录。

2026-11-01 实测：`PASS 29 test files`。新增/改动功能时同步补 `tests/test_*.lua`，跑了再交付。

---

## 8. 风险

- **Hook 面很宽**：`GiveItem`、`GetNextAvailableSlot`、`MoveItemFrom*`、`invslot.OnMouseButton`、`invslot.OnControl`、`containerwidget` / `inventorybar`。与容器扩容、自动整理、Shift 增强类模组冲突概率高，表现是「物品进错格」而不是崩溃。
- **未装客户端的玩家看不到预留**：体验不对称。要对称就把 `all_clients_require_mod` 改回 `true`。
- **物品栏全被预留时等于「对其它物品满格」**：这不是 bug，是预留语义的直接结果。0.1.3 起改用「落背包」兜底；但背包也满、或来源就是背包时物品仍留在原处（原版行为）。
- **口袋专用物品（余烬/灵魂）必须绕过预留**：`canonlygoinpocket`（以太余烬、查理玫、灵魂罐）与 `canonlygoinpocketorpocketcontainers`（沃拓克斯灵魂）没有背包退路，被预留拦住就会掉地上；余烬还 `canbepickedup=false`，一掉就等于丢了。它们由 `ISR.IsPocketOnlyItem` 识别，`ShouldReserveMarkedSlotsForItem` 直接返回假；落进预留格时顺手清掉那格的预留。加新的「只能放物品栏」物品时先查它在 prefab 里用的是哪个字段。
- ~~客户端预测不认预留~~：原版 `inventory_classified:ReceiveItem` 先把物品画进固定格、服务端选定别的落点后回滚，只闪一帧不影响归属。已在 `isr_clientpredict.lua` 里处理（§3.7）；改动预测相关代码时别把这两层拆掉。
- 沙箱限制：mod 环境里 `setmetatable/pcall/tonumber/next` 等为 nil，走 `GLOBAL`；禁止 `io.open` 写盘（引擎 2025-01 起只读）。
- **`GLOBAL["名字"]` 写错就把服务器打崩**：服务端开着 `scripts/strict.lua`，读 `_G` 上没声明过的名字会直接抛 `variable 'Xxx' is not declared`。0.1.4 第一次装就是这么崩的（`GLOBAL["IsMasterSimulation"]`——它其实是 `isr_markstores.lua` 里自己定义的局部函数，不是全局）。规则：`ISR.GetGlobalValue` 只传确实是游戏常驻全局的名字；要判服务端就用 `TheWorld.ismastersim`。`tests/test_modmain_load.lua` 里有一个「严格 GLOBAL」替身，加新名字会让测试先炸。
- **客户端兜底会多发 RPC**：`replica.inventoryitem` 不联网 `owner`，客户端拼不出「切斯特身上的背包」这类归属链，所以 `IsClientMarkableContainerInst` 最后一段是「`GetNumSlots() > 0` 就放行，交给服务端裁决」。代价：对着地上的普通箱子按 V + 左键也会发请求，服务端 `reason = "not_markable"` 拒绝并回推，表现为闪一下清除音。这是换取「任何没见过的容器都能试」必须付的账，不要为了消掉这个音效把兜底删掉。
- **作用距离之外的固定格会静默失效**：`container_range` 挡住时物品走原版落点回物品栏，玩家看到的就是「固定了但不进容器」。排查先看日志 `skipped <guid>@<slot>:range`，再问玩家档位选的是哪个。
- 许可证：MIT（见 `LICENSE`）。

---

## 9. 回滚

```bash
# 停用：mods\modsettings.lua 里注释掉 ForceEnableMod("item-slot-reservation")，或 Mods 菜单取消勾选
# 删除：删掉 mods\item-slot-reservation\ 目录即可；存档残留的标记数据无人读取，不会报错
```

---

## 9.5 多人环境：客户端必须加载模组才能用（重要）

**结论：`all_clients_require_mod = true`（2026-10-31 由 false 改来）。** 朋友订阅后进服，游戏会自动临时启用本模组，无需手动操作。

为什么要改（引擎限制，不是实现问题）：

| 事实 | 依据 |
|---|---|
| 订阅 ≠ 启用。`GetModsToLoad()` 只加载本地 `enabled` / `forceenabled` / `temp_enabled` 的模组 | `scripts/modindex.lua` |
| 主菜单 Mods 界面的「服务器模组」页签是**只读**，条目 `SetModReadOnly(true)`，点不动 | `screens/redux/modsscreen.lua` 的 `are_servermods_readonly = true` |
| 只有「创建世界 → Mods」界面把该标志设为 false，才能勾选服务器模组 | `screens/redux/servercreationscreen.lua` 的 `are_servermods_readonly = false` |
| `all_clients_require_mod = true` 时，客户端进服会按服务器下发的模组表自动 `temp_enable` 并提示重启一次 | `mods.lua` 的 `GetEnabledModsModInfoDetails` |

所以 `false` 的实际效果不是「谁都能用」，而是「除房主外谁都**用不了**」——客户端的 UI 接管、按 V 判定、RPC 发送全在客户端代码里，没加载就只有服务端半截在跑。

改为 `true` 的代价：没订阅的玩家进不了房间（游戏弹订阅提示，点一下自动订阅下载）。

排查朋友端：他的 `client_log.txt` 里必须出现 `Loading mod: workshop-3830575143`。没有这行就是客户端没加载。

## 10. 贴图（KTEX）怎么生成

本机没有 ktools，改封面/图标不用装工具，Python + Pillow 直接写 `.tex`。

格式（未压缩 RGBA，PC 平台），以 `images/modicon.tex` 为例：

```
88 字节头    magic "KTEX" + platform 0xFFFD0240 + 宽高 + 8 级 mipmap 描述表
            （128x128 连续 mip 链时头长恰为 88）
87380 字节   RGBA8 像素：128² + 64² + 32² + 16² + 8² + 4² + 2² + 1² 各 4 字节
总计 87468
```

生成办法：拿同尺寸的旧 tex 取前 88 字节当模板头，后面整段替换成新像素 + mip 链。

验证：读回 `.tex` 的 `data[88:88+128*128*4]` 按 RGBA 解成图，与原 PNG 做 `ImageChops.difference`，`bbox == None` 即结构正确。

配套 `images/<名>.xml`：`<Element name="modicon.tex" u1="0.00390625" u2="0.99609375" v1=... v2=... />`，
半像素内缩（1/256）避免边缘渗色。`0 1 0 1` 也能显示，但贴边会露相邻像素。

参考提交 `3cdb125`（封面替换）：截图裁 201x201 正方 → 128x128 → 顶部压暗 → 写 tex。

**游戏会自己把未压缩 tex 压成 DXT5。** 手写的 87468 字节 RGBA 版放进 `mods\` 后，游戏启动时把它重编码成同尺寸的 DXT5（BC3）：

| 项 | 手写未压缩版 | 游戏压缩后 |
|---|---|---|
| 文件大小 | 87468 | 21960（-74.9%） |
| 像素段 | 87380（RGBA8 全 mip） | 21872（DXT5 全 mip，正好 1/4） |
| platform 字段 | `0xFFFD0240` | `0xFFFD0220` |
| 头长度 / mip 级数 / 分辨率 | 88 / 8 / 128² | 完全相同 |

压缩是有损的：解码 mip0 与原 PNG 比 PSNR **35.4 dB**，最大单通道误差 55（出现在物品栏的高对比边缘），肉眼基本无差分。`wood_frame_128_ARGB.tex` 本来就是这种 DXT5 格式，两者现在同构。

**发布时直接用游戏压缩后的 tex**（体积 1/4，工坊下载更快），仓库里 `images/modicon.png` 保留无损源图，改封面时按上面的办法从 png 重新生成即可。
