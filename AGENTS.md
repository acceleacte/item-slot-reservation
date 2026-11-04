# AGENTS.md — item-slot-reservation

> 给接手这个目录的人（或 agent）看的内部说明。用户向的使用说明在 `README.md`。

## 1. 这是什么

**Item Slot Reservation（ISR，物品格预留）**：把储物格固定给指定物品（prefab）。物品被拾取、制作完成、从装备栏卸下时自动回到该格，其它物品避开它。

| 项 | 值 |
|---|---|
| 模组名（显示名） | 物品格预留（`modinfo.name`，工坊标题仍为 Item Slot Reservation；目录名/存档引用是 `workshop-3830575143`，与显示名无关） |
| 版本 | 0.1.8（`modinfo.lua`） |
| 类型 | 服务器模组，`all_clients_require_mod = true`（2026-10-31 由 false 改来，见 §9.5），`client_only_mod = false` |
| `api_version` | 10 |
| 全局表 | `ISR`（同时挂到 `GLOBAL.ISR`） |
| RPC 命名空间 | `item_slot_reservation` |
| 组件名 | `isr_slotmarkstore` |
| 作者 | 留空（`author = ""`） |

自建模组：代码从零编写，不 require、不引用任何第三方模组的文件、资源或命名空间；模块之间只通过全局 `ISR` 表交互。标记模型只有「prefab ↔ 格子」一种，不要引入按装备部位、按物品分类之类的第二套键。

---

## 2. 文件结构（4300 行 Lua，31 个测试）

```
modmain.lua                 20 行，14 个 modimport，顺序有依赖（env → config → icons → storage → markstores → slotmarks → placement → candidates → crafting → debug → persistence → inventoryhooks → clientpredict → uihooks）
modinfo.lua                ~170 行，配置项 + 双语文案
scripts/
  isr_env.lua              396  GLOBAL 取值兜底、按键码归一化、点击意图、prefab 键工具、距离档位、i18n
  isr_config.lua            43  读 GetModConfigData（pin_key / pin_modifier / icon_opacity / border_opacity / debug_log / pickup_to_container / container_range / craft_from_container）
  isr_icons.lua            237  空格物品图标 + 木框渲染（透明度取自 `border_opacity`）
  isr_storage.lua          485  存储适配器注册表 + 内置适配器 + 容器归属判定 + 作用距离
  isr_markstores.lua       152  组件挂载、按 GUID 找 store、标记容器注册表、随身实例递归枚举
  isr_slotmarks.lua        505  服务端标记 CRUD、匹配判定、客户端缓存、拾取音效、5 个 RPC handler
  isr_placement.lua        230  放置路由决策、标记优先级（容器 / 物品栏）、距离过滤、transfer 上下文栈
  isr_candidates.lua       521  候选格搜索（堆叠/溢出/专用容器优先）
  isr_crafting.lua         ~430  合成借料：builder 三 hook + 供应量下发 + builder_replica 客户端判定
  isr_debug.lua            106  自检 + 控制台标记入口
  isr_persistence.lua      400  客户端能力白名单、全量同步、旧开发版存档迁移、玩家级标记备份（含嵌套路径）
  isr_inventoryhooks.lua   348  GiveItem / GetNextAvailableSlot / Shift 转移 hook
  isr_clientpredict.lua    330  客户端落点预测（标记先行判落点 → 背包预测 / 守卫窗口）
  isr_uihooks.lua          368  invslot / inventorybar / containerwidget 的 UI hook
  components/isr_slotmarkstore.lua  164  标记存储组件（OnSave/OnLoad、容器 owner、add_component_if_missing、注册表登记）
tests/                      33 个 lua 测试 + run_lua_tests.py
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

`ISR.GetSlotMouseIntent(button)`：按住「修饰键 + 动作键」组成的固定手势才返回意图，否则 `nil`，原版逻辑照常执行。

手势拆成两个配置项（0.1.51 起）：

| 配置 | 取值 | 说明 |
|---|---|---|
| `pin_modifier` | SHIFT（默认）/ CTRL / ALT / NONE | 合成键码 `KEY_SHIFT = 402`、`KEY_CTRL = 401`、`KEY_ALT = 400`，原版调试键也这么判（`scripts/debugkeys.lua:431`） |
| `pin_key` | MIDDLE（默认）/ RIGHT / V B N G F C X Z R T H J K L / NONE | 动作键 |

两类动作键的语义不同，别混：

| 动作键 | 判定 | 语义 |
|---|---|---|
| 键盘键（V…L） | `IsKeyDown(keycode)` 必须为真，**修饰键不参与** | 左键 → `SLOT_INTENT_PIN`，右键 → `SLOT_INTENT_CLEAR`（老打法） |
| 鼠标键（MIDDLE / RIGHT） | 修饰键必须按下，且只比 `button` | **只认它自己** → `SLOT_INTENT_PIN`，语义是切换（`ISR.IsTogglePinKey()`），左右键一律返回 `nil` |

鼠标模式下左右键必须放行：`Shift + 左键` 是原版快速转移，吞掉等于把搬运功能废掉。这一条不要为了「少一次判断」合并掉。

键盘模式反过来要求「不用修饰键」：老存档里 `pin_key` 有记录、`pin_modifier` 没有（新增项），会落到默认 SHIFT —— 若键盘键也要求修饰键，老玩家升级后按 V 直接失效。所以修饰键只对鼠标动作键生效。

其余规则：

- 按钮码经 `ISR.NormalizeSlotButton` 归一化（`MOUSEBUTTON_*` ↔ `CONTROL_PRIMARY/ACCEPT/SECONDARY`），中键原样透传 `MOUSEBUTTON_MIDDLE = 1002`。中键在原版脚本里除 `constants.lua` 的定义外零引用，无默认绑定。
- 中键只走 `OnMouseButton` 一路，不产生 `OnControl`，但仍保留 200ms 去重（`slot._isr_intent_stamp`），键盘模式靠它挡住双路重复触发。
- `invslot` 上 **`OnMouseButton` 和 `OnControl` 都要包**：拾取物品走 `OnControl(CONTROL_ACCEPT)`，只包鼠标挡不住点击。
- 切换模式下「已标记的格子」中键直接清除（`InvSlot toggle clear`），不看格中物品是否还是同一种 —— 中键只有一个动作，玩家没法再分左右键。
- 0.1.51 之前的旧配置值 `SHIFT_MIDDLE` 由 `ISR.GetPinChord()` 归一化成 `MIDDLE + SHIFT`，老存档不炸。

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

格子里有物品时，物品图 `self.tile` 是子 widget 且自带提示，**只调 `slot:SetTooltip(...)` 会被它盖掉** —— 表现就是「有物品的格子按住固定键看不到提示，空格反而正常」（0.1.0 首版的 bug，已修）。

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

**世界容器的归属由设置项 `container_sharing` 决定（0.1.8 起，用户 2026-11-04 指定）**：

| 模式 | 语义 | 判定入口 |
|---|---|---|
| `shared`（默认） | 容器不记名，谁能打开谁就能固定 / 改 / 清，所有人可见 | `ISR.IsSharedMarkContainer` 放行；RPC 里**没有任何按 userid 的拦截** |
| `exclusive` | 第一个在这只容器落标记的人独占，别人看不到也动不了 | `SlotMarkStore.owner`；`ISR.IsStorageOwnedByPlayer` 先按它判，RPC 里 `reason = "container_owner"` 拒绝 |

`owner` 字段只按容器记、不按格记，两种模式共用同一份存档：共享模式下它**完全不参与判定**，切到独占直接沿用，来回切不需要迁移、不需要重设标记。每格带 owner 的中间方案已经被用户否掉过，别再加回来。

硬性：**拒绝时必须是「无响应」，不能是「闪一下」**（用户 2026-11-04 明确）。客户端不做乐观写入（见本节末尾），服务端拒绝时不推有效值。

容器分两类，判定**只看组件语义**，不维护 prefab 名单：

| 类别 | 判定 | 标记可见性 |
|---|---|---|
| **共享世界容器**（仅 `shared` 模式） | 有 `container` 组件、没有 `inventoryitem`（拿不起来的箱子、无主切斯特/哈奇）；跟着别人跑的跟随型容器不算 | 所有人可见、可用、可改 |
| 自己的随身容器 | `inst == player`，或 `inventoryitem:GetGrandOwner()` 沿 owner 链到这名玩家（背包、背包里的桶） | 只有自己可见 |

实现在 `isr_storage.lua`：
- `ISR.IsEntityOwnedByPlayer`（实体归属：玩家自己 / `follower:GetLeader()` / `rideable.rider`）
- `ISR.AreContainerMarksShared`（读 `container_sharing`，缺配置按共享；定义在 `isr_env.lua`，因为部分测试桩只加载 env + 单模块）
- `ISR.IsStorageOwnedByPlayer`（随身容器；独占模式下先看容器上记的 `owner`）
- `ISR.IsSharedMarkContainer`（共享世界容器：**先判 `AreContainerMarksShared`**，独占模式恒 false；其余条件为非玩家、有 container、无 inventoryitem、不跟着别人；`player == nil` 时只问「是不是世界容器」，广播用）
- `ISR.IsMarkableContainerForPlayer` = 上面两者之一（RPC 入口）

**打开即可标记**：`set_slot_mark` 的 RPC 里，`container:IsOpenedBy(player)` 为真就直接放行（`isr_slotmarks.lua`）。切斯特没眼骨时 `follower:GetLeader()` 是 nil，只有这条能让它可标记。

**推送要按可见性分流**（`ISR.SyncMarkChangeToViewers`）：共享容器的变化广播给所有装了这个模组的玩家（`ISR.BroadcastMarkChange` → `ISR.IsMarkContainerVisibleTo` 过滤），随身容器只推给主人。B 改完箱子，A 开着箱子时界面立刻同步。

**路由主人按模式取**：`ISR.GetMarkOwnerPlayer` —— 独占模式返回容器上记的 `owner` 对应的在线玩家（`FindPlayerByUserid`）；共享模式返回**当前打开这只容器的玩家**（`container:IsOpenedBy` 扫 `AllPlayers`），没人打开返回 nil，此时容器钩子只做解标记、不做路由。

**枚举走注册表，不走「玩家身上有什么」**：`isr_markstores.lua` 的 `ISR._mark_containers`（GUID → 实体）。`SlotMarkStore:SetMark` 与 `OnLoad` 时登记，`ClearMark` 清空后与 `OnRemoveFromEntity` 时注销，`GetMarkContainerInstances` 顺手清理失效实体。`ISR.GetServerMarks` 遍历注册表 + 归属过滤 —— 这样切斯特这类**不在玩家物品栏里**的容器也能算进同步、自动回位与匹配判定。

客户端判定（`ISR.IsClientMarkableContainerInst`）分三段，任一段通过即放行：

1. `replica.follower:GetLeader() == player`（跟随容器）；
2. 物品栏/装备栏一层 + `replica.container:GetItemInSlot` 往下扫一层（容器树，靠 classified，只有打开过的容器有数据）；
3. **兜底**：`replica.container:GetNumSlots() > 0` 就放行，交给服务端裁决 —— `inventoryitem` 的 replica 不带 owner，客户端拼不出完整归属链（切斯特身上的背包就是这种情况）。客户端不知道 `container_sharing` 也不该知道：**能不能用由服务端说了算**。

**客户端不做乐观写入（0.1.8，硬性）**：`ISR.SetClientSlotMark` 只发 RPC，**不写**本地 `_item_slot_reservation_client_marks`。本地表只由 `ApplySyncedClientSlotMark`（服务端 `sync_mark`）和快照写入，画框与「固定成功」音效也在那里播。原因：乐观写入会让被拒绝的操作先画框再擦掉 —— 就是「闪一下」。曾经在 `PinClientSlotMark` 里即时 `ApplyRuntimeIconToSlot` + `click_object`，已全部移除；`_client_requested_clear_key` 那套抑制重复清除音的机制也随之删掉（现在清除音只在确认后响一次）。

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

### 3.10 高频查询的成本控制（0.1.52）

`GiveItem` 是每次拾取都会走的路径，下面几处专门压成本。改动这些地方之前先看清「为什么省这一次」。

| 热点 | 原来 | 现在 |
|---|---|---|
| 一次 GiveItem 里算几遍标记 | `ShouldRoutePlacementByMarks` → `TryPlaceByMarks` 内部再判一次 → `GetSortedServerMarksForPrefab` 每个路径各算一遍，合计 4 次全量枚举 | 第一次算完挂 `context.marks`（`ISR.GetContextMarks`），同一次 GiveItem 内全部命中，合计 1 次 |
| 判断「这格对本物品开放吗」 | `CanItemUseMarkedSlot` → `GetServerSlotMark` 每次构造一个 `{container_guid, slot, prefab, order}` 表 | `ISR.CanItemUseStoredMark` 直接读 store 比对 prefab，不建表（候选格搜索按格调用，一次拾取几十次） |
| 「这格有预留吗」 | `IsServerSlotMarked` = `GetServerSlotMark(...) ~= nil`，同样建表 | 直接 `IsValidStoredMark(store:GetMark(slot))` |
| 边框/图标尺寸 | `OnUpdate` 每帧走 `RefreshSlotBorderLayout`，`GetSlotBaseSize` 调两次、`SetSize` 每帧调 | 一次 `GetSlotBaseSize` 供两个 widget 用；尺寸与上次相同就不调 `SetSize`（它触发 UI 布局重算） |
| `GetSlotBaseSize` | 每次调用建一张 4 元素候选表 | 顺序 `nil` 检查，不分配 |

**故意不做跨调用缓存**（按玩家缓存 `GetServerMarks`）：缓存的失效点散在 `SetMark` / `ClearMark` / `OnLoad` / `RestoreMarkBackup` / 容器注销五处，漏一处就是「物品进错格」这类难查的问题。实际规模是个位数容器（玩家物品栏 + 背包 + 几个箱子），枚举成本远低于一次缓存不一致的代价。要加就得先有能证明这一层是瓶颈的 profiler 数据。

`GetContextMarks` 的缓存只活在单个 `context` 里（每次 GiveItem 由 `MakePlacementContext` 新建），不存在跨帧陈旧。

### 3.11 合成借料（0.1.7，isr_crafting.lua）

合成时自动借用「已固定且在作用距离内」的世界容器里的材料。原版只扫物品栏 + **当前打开**的容器（`inventory.opencontainers`），关着的容器不参与。

| hook（builder 组件） | 作用 |
|---|---|
| `HasIngredients` | 原版判负后，用容器供应再判一次（决定合成按钮/入口） |
| `GetIngredients` | 原版 materials 之外，把缺口记到容器内实体上（materials 是**两层**结构 `{[类型] = {[实体] = 数量}}`） |
| `RemoveIngredients` | 容器条目自消费：部分扣减 `stackable:Get`（对实体操作，不看容器开闭）；整堆/单件 `Container:RemoveItem` 清槽位再 Remove。物品栏条目留给原版 |

**不重复扣料的排除规则**（供应集合必须与原版统计不相交）：玩家物品栏标记、随身容器（背包/背包里的桶，原版 overflow 已覆盖）、玩家**正打开**的容器（原版 opencontainers 已覆盖）一律不进供应；另排除 `excludefromcrafting` / `readonlycontainer` 与 `nocrafting` 物品。少排会重复扣料（合成少付钱），这是本文件最要紧的约束。

- 只认标记：格子必须固定给该 prefab 且格中有该物品，空标记格不算。
- 作用距离复用 `container_range`（`ISR.IsStorageWithinRange`）；开关 `craft_from_container` 默认开（老存档缺该项按 nil → 开）。
- 消费空掉的类型表要摘掉；mod 沙箱里 `next` 为 nil，空表判定用 `pairs` 走一遍。
- 测试 `tests/test_crafting.lua`（夹具：切斯特 log 堆 + 近处箱子 twigs 堆；注意消费用例会扣光夹具，包装用例前要恢复）。

**客户端判定（同属 0.1.7）**：配方格子是不是灰的由**客户端** `builder_replica:HasIngredients` 决定，它走 `inventory_classified:Has` → 只数物品栏 + `GetOpenContainers()`（HUD 里可见的容器）。关着的切斯特/箱子内容**根本不同步到客户端**，服务端 hook 改不了 UI。

- 服务端 `PushCraftingSupply` 每 0.5s 按玩家算一次「可借的固定格数量」汇总（`ComputeCraftSupply` 复用 `GetCraftingSupply`，口径天然一致），序列化成 `log:6;twigs:2`（`table.sort` 保序），与上次 payload 不同才发 `sync_craft_supply` RPC；`IsClientCapable` 拦掉没装模组的客户端。
- 客户端 `builder_replica` 在原版判负后用这份数字补缺口（`HasIngredientsWithClientSupply`），角色/技术材料仍按原版判；收到新 payload 即 `ThePlayer:PushEvent("refreshcrafting")`，菜单开着也实时变色。
- **replica 组件不走 `EntityScript:AddComponent`**（`entityreplica.lua` 里直接 `cmp(self)`），`AddComponentPostInit("builder_replica")` 永远不触发，必须用 `AddClassPostConstruct("components/builder_replica")` 包构造器。
- 实体上有真 `builder` 组件（房主/本地服务器）时客户端侧直接放行给服务端 hook，避免双重判定。
- 客户端缓存的只是「数量」，不含归属/距离：范围、开关容器、`excludefromcrafting` 全在服务端算，客户端不重复实现这套规则。
- **材料行也要显示借料（0.1.8）**：`craftingmenu_ingredients.lua` 用 `inventory:Has(type, amount, true)` 的 `num_found` 画「有/需」，不够就染红（`ingredientui.lua`）。借料材料在**关着的**箱子里，客户端数不到 ⇒ 明明能合成却显示「1/2」红字，玩家以为材料不够。修法：包 `CraftingMenuIngredients:SetRecipe`，执行期间把 `owner.replica.inventory.Has` 换成「原值 + 同步供应」（`ISR.WithSupplyAwareInventory`），结束后（**含报错路径**）必须还原，否则别的模组对 Has 的包装会被吃掉。详情面板、固定栏悬停、材料图标里的子配方弹窗都构造同一个类，一处覆盖三处。沙箱里 `pcall` 为 nil，用 `ISR.Runtime.pcall`，取不到就不包装、直接调原函数。
- 设置界面排版（0.1.7 起）：`modinfo` 用 `Section(name, label)` 造分组标题 —— 一个只有单选项且 `description` 为空的条目，`modconfigurationscreen` 里 `is_header` 会隐藏下拉框和底图、只放大标题。悬停说明区只有 585×50（字号 22，约两行），**每段必须 ≤2 行且用 `\n` 手动断行**，单行不超过约 26 个汉字；否则后半句直接看不到。每个选项的 `hover` 会显示在下方的金色值说明行（`value_description`，一行），适合放「这个值的含义」。
- 语言：`modinfo.lua` 的 `label` / `hover` 由引擎（`GetModConfigurationOptions_Internal`）取回后直接 `SetString`，**不支持按语言取表**，所以设置项文案只能是单一语言（当前固定中文）。`language` 只影响运行时字符串：`ISR.GetLanguageMode()` 优先取配置，缺项/非法值回落 `ISR.IsChineseLocale()`；`ISR.GetText` 与 `ISR.GetPinChordLabel` 都走它。`isr_env` 早于 `isr_config` 加载，取值时必须容忍 `ISR.Config == nil`。
- 提示音：`craftingmenu_widget` 用「分类内可合成数量比上次多」置 `new_recipe_available`，pinbar 的 `SetCraftingState` 据此播 `dontstarve/HUD/recipe_ready`。借料让这个计数频繁变多，所以在 `isr_uihooks.lua` 里包了 pinbar 的 `SetCraftingState`，只在 `ISR.ShouldMuteRecipeReady()`（借料刚点亮的 0.35s 内）把 `new_recipe_available` 置 false。别去压刷新频率：刷新挂的是原版物品事件，压了会让格子状态过期。
- 性能：`HasIngredientsWithClientSupply` 先用 `RecipeUsesSupply` 过一遍配方的 `ingredients`，没有一种在同步表里就直接返回 false，**不进 `inventory:Has`**（每次 Has 都要扫物品栏 + overflow + 打开的容器）。菜单一次重算几百个配方，真正走完整判定的只剩含固定格材料的那几个，通常是个位数。
  不做「按配方缓存结果」：剩下这点开销已经小于原版自己那次 `HasIngredients`，而缓存的失效点要覆盖物品栏事件（`itemget`/`itemlose`/`stacksizechange`/`newactiveitem`/`refreshcrafting`）与供应量变化，漏一个就是格子状态不刷新，不划算。

### 3.12 物品直接进容器（0.1.7，`Container:GiveItem` 包装）

物品进容器有三条真实路径：手动拖入/换位（`PutAllOfActiveItemInSlot` → `GiveItem(item, slot)`）、Shift 转移（`MoveItemFromAllOfSlot` → `GiveItem(item, nil)`）、自动放入（`GiveItem(item, nil)`）。原版在 `slot == nil` 时自己挑格（`GetSpecificSlotForItem`），**落点只有事后 `GetItemSlot(item)` 才知道**。

- 「避开预留格」：`slot == nil` 且容器树里有空的预留格时，走 `GetNextUnmarkedContainerAvailableSlot`（先找同类未满堆、再找未预留空格），落点交给它；没有非预留位就**回落原版**，不要 `return false`（那会让物品直接退回来源）。
- 「占进预留格就解除预留」：落点确定后调 `ClearContainerSlotMarkOnMismatch`（`isr_slotmarks.lua`）。它直接按格查 mark store，不要求容器有在线主人 —— 基地箱子、没带眼骨的切斯特 `ResolvePlayerStorageOwner` 给 nil，早期版本在这里整段 early return，于是这两类容器的预留永远不解除，格子被别的东西占住就成了死格。清完走 `ISR.SyncMarkChangeToViewers`：共享容器广播，随身容器只推主人。
- 容器钩子里的 owner 解析顺序：`ResolvePlayerStorageOwner`（随身容器、跟随者）→ `GetMarkOwnerPlayer`（独占模式取容器 owner，共享模式取当前打开这只容器的玩家）→ 都没有则只做解标记、不做路由。
- 读档期间（`storage.isloading` 或 `storage._isr_loading`）一律不解标记，见 `IsStorageLoading`。


---

## 4. 数据流

```
客户端按住固定手势点格
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
| 固定 / 取消固定（点已有物品的格子） | `Shift` + 中键 |
| 清除标记（不要求格子为空） | 鼠标模式：再按一次中键；键盘模式：固定键 + 右键 |
| 控制台预留 | `ISR.DebugSetPrefabMark(3, "cutgrass")`，背包 `(2, "twigs", true)` |
| 控制台清除 | `ISR.DebugClearSlotMark(3)` |

配置项（`isr_config.lua` 读）：`language`（zh / en，默认 zh；只管游戏内提示文字，设置项文案固定中文）、`pin_modifier`（SHIFT / CTRL / ALT / NONE，默认 SHIFT）、`pin_key`（MIDDLE / RIGHT / V B N G F C X Z R T H J K L / NONE，默认 MIDDLE）、`icon_opacity`（0~1，默认 0.35）、`border_opacity`（0~1，默认 1）、`debug_log`、`pickup_to_container`（默认 false；只管世界容器，随身容器永远接收）、`container_range`（near / medium / far，默认 medium）、`craft_from_container`（**默认 false，测试版**；合成借料开关，作用距离用 `container_range`）、`craft_ping`（original / borrow / silent，默认 borrow；合成提示音处置）。

两个透明度都画在同一个格子上，改其中一个不影响另一个：

| 配置 | 作用对象 | 默认 | 实现 |
|---|---|---|---|
| `icon_opacity` | 空预留格里那件物品的图标 | 0.35 | `ApplyIconWidget` 的 `SetTint(1,1,1,alpha)` |
| `border_opacity` | 木框贴图 `wood_frame_128_ARGB` | 1（不透明） | `isr_icons.lua` 的 `SyncSlotBorderTint`，在 `ApplySlotBorder` 里跟着 `SetSize` 一起刷 |

`GetBorderAlpha` 在 `ISR.Config.border_opacity` 为 nil 时回落 1：老档的 `modsettings` 里没有这一项，缺值不能让木框变透明。0 等于不画框（widget 仍在，`SetClickable(false)`，不挡点击）。运行时改配置不生效，游戏要重启。

**不要**再加 `mark_modifier` / `prefab_mark` 这类选项：早期开发版曾用组合键循环标记、并用开关控制物品标记，0.1.0 已把它们删掉，只剩「按住固定手势点格子」一条路径。

---

## 6. 本地环境

- 仓库：本目录即 git 仓库根，模组文件就在根目录（不含 `dist/`、`.workbuddy/`、`.lua-test-runtime/`）
- 游戏加载路径：**创意工坊 `workshop-3830575143`**（2026-10-31 上传并订阅）。`ForceEnableMod` 已移除，存档 `modoverrides` 已改为 `["workshop-3830575143"]`
- **发布源是工作区根的 `Item-slot-reservation\` 文件夹**，不在本仓库内。更新版本时改那里的 `modinfo.lua` 与脚本，再由维护者在游戏内 Upload。
- **不要把发布目录复制进 `mods\item-slot-reservation\`**。工坊订阅版已加载，多一份本地副本会让模组列表出现两个同名条目。上传后 Steam 自动拉取到 `workshop\content\322330\3830575143\`，无需手动同步缓存。
- 工坊不接受同版本覆盖：每次 Upload 前必须升 `modinfo.lua` 的 `version`。
- **版本号规则（硬性，用户 2026-11-03 指定）**：未上传工坊期间，所有改动都合并到**同一个待发布号**上，一次只递增一位（工坊上是 `0.1.7` → 待发布 `0.1.8`；中途再改多少次仍是 `0.1.8`），**不跳号**、不因为「修了个 bug」单独占一个新号。判断依据是工坊上实际存在的号，不是本地改了几轮。发布完成后再动代码才允许 +1。
- 同一个号内的改动全部写进 `CHANGELOG.md` 里**同一节**，不拆成两条（这条规则的由来：早期未发布时又改了一轮，误开成新号，后来并回待发布号）。
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

2026-11-02 实测：`PASS 31 test files`（`test_pin_chord.lua` 覆盖修饰键 + 动作键组合，`test_mark_query.lua` 覆盖标记查询的缓存与「不建表」判定）。新增/改动功能时同步补 `tests/test_*.lua`，跑了再交付。

---

## 8. 风险

- **Hook 面很宽**：`GiveItem`、`GetNextAvailableSlot`、`MoveItemFrom*`、`invslot.OnMouseButton`、`invslot.OnControl`、`containerwidget` / `inventorybar`。与容器扩容、自动整理、Shift 增强类模组冲突概率高，表现是「物品进错格」而不是崩溃。
- **HUD 类钩子必须挂在类上，不能只包实例**（0.1.53 修）：装备栏类模组（四五六格 `workshop-3173431824`、Extra Equip Slots `workshop-375850593`）加装备槽的写法都是 `local base = Inv.Rebuild; function Inv:Rebuild() base(self); ... self:AddEquipSlot(...) end`。本模组若用 `AddClassPostConstruct` 在**构造期**包 `self.Rebuild`，就把当时的类方法引用冻在实例字段上；后加载的模组再换掉类方法，这次调用永远绕过它 —— 现象正是「装了本模组之后，新增的护符栏 / 背包栏不见了」。四五六格 `priority` 默认 0、按 `modinfo.name` 排在本模组之后，必中；Extra Equip Slots `priority = 10` 先于本模组加载，所以只有它时不出问题。现在改为加载期 `require("widgets/inventorybar")` 取类、包**类方法**（`isr_uihooks.lua` 的 `GetInventoryBarClass` + `_isr_class_hooked` 防重包），回归测试 `tests/test_inventorybar_hook.lua`。以后加 HUD / Widget 钩子一律照此办理；`containerwidget` 那组仍是实例包法，改之前先确认没有模组按类方法加控件。
- **未装客户端的玩家看不到预留**：体验不对称。要对称就把 `all_clients_require_mod` 改回 `true`。
- **物品栏全被预留时等于「对其它物品满格」**：这不是 bug，是预留语义的直接结果。0.1.3 起改用「落背包」兜底；但背包也满、或来源就是背包时物品仍留在原处（原版行为）。
- **口袋专用物品（余烬/灵魂）必须绕过预留**：`canonlygoinpocket`（以太余烬、查理玫、灵魂罐）与 `canonlygoinpocketorpocketcontainers`（沃拓克斯灵魂）没有背包退路，被预留拦住就会掉地上；余烬还 `canbepickedup=false`，一掉就等于丢了。它们由 `ISR.IsPocketOnlyItem` 识别，`ShouldReserveMarkedSlotsForItem` 直接返回假；落进预留格时顺手清掉那格的预留。加新的「只能放物品栏」物品时先查它在 prefab 里用的是哪个字段。
- ~~客户端预测不认预留~~：原版 `inventory_classified:ReceiveItem` 先把物品画进固定格、服务端选定别的落点后回滚，只闪一帧不影响归属。已在 `isr_clientpredict.lua` 里处理（§3.7）；改动预测相关代码时别把这两层拆掉。
- 沙箱限制：mod 环境里 `setmetatable/pcall/tonumber/next` 等为 nil，走 `GLOBAL`；禁止 `io.open` 写盘（引擎 2025-01 起只读）。
- **`GLOBAL["名字"]` 写错就把服务器打崩**：服务端开着 `scripts/strict.lua`，读 `_G` 上没声明过的名字会直接抛 `variable 'Xxx' is not declared`。0.1.4 第一次装就是这么崩的（`GLOBAL["IsMasterSimulation"]`——它其实是 `isr_markstores.lua` 里自己定义的局部函数，不是全局）。规则：`ISR.GetGlobalValue` 只传确实是游戏常驻全局的名字；要判服务端就用 `TheWorld.ismastersim`。`tests/test_modmain_load.lua` 里有一个「严格 GLOBAL」替身，加新名字会让测试先炸。
- **客户端兜底会多发 RPC**：`replica.inventoryitem` 不联网 `owner`，客户端拼不出「切斯特身上的背包」这类归属链，所以 `IsClientMarkableContainerInst` 最后一段是「`GetNumSlots() > 0` 就放行，交给服务端裁决」。代价：对着别人的背包、别人的跟随容器按固定手势也会发一次没人听的请求 —— 0.1.8 起客户端不预写标记，被拒时**屏幕上没有任何反应**，正是想要的效果。不要为了省这一次 RPC 把兜底删掉（删了就试不了没见过的容器）。（世界箱子在共享模式下会正常放行；独占模式且不属于你时走无响应。）
- **作用距离之外的固定格会静默失效**：`container_range` 挡住时物品走原版落点回物品栏，玩家看到的就是「固定了但不进容器」。排查先看日志 `skipped <guid>@<slot>:range`，再问玩家档位选的是哪个。
- **中键手势在部分鼠标/驱动上不灵**：中键被驱动绑成宏或切 DPI 时，游戏收不到 `MOUSEBUTTON_MIDDLE`。这类玩家改回键盘动作键即可，选项一直留着。
- **改默认手势不会迁移老存档的设置**：`modsettings` 里存过 `pin_key` 的玩家仍按旧值走（`PIN key = V`），要自己改一次。README 里写明了这一点。
- 许可证：MIT（见 `LICENSE`）。

### 8.5 外部 review 的处置（2026-11-02，0.1.52）

一份逐行 review 提了 16 条。采纳 8 条、误报 3 条、判断为不划算 5 条。记在这里，免得下次再被同样的建议带偏。

| # | 建议 | 结论 |
|---|---|---|
| 1 | `GetAvailableStackRoomInContainer` 的 `acceptsstacks` 判断有 bug | **误报**。`not (a or (b and c))`，两边都为假时括号内是 `false`，`not false = true` → 会提前 `return 0`。原版 `Container:AcceptsStacks()` 就是 `return self.acceptsstacks`（`components/container.lua:322`），两种写法等价。不动 |
| 2 | `GetFirstUnmarkedStackSlotIn*` 的 `pairs` 改成数字索引 | **采纳**。Lua 5.1 的 `next` 对数组部分确实递增，但这是实现细节不是语言保证；改成 `1..GetContainerSlotCount`，服务端/客户端挑堆叠格的结果确定化 |
| 3 | `GetNextUnmarkedEmptySlot` 的 `preferred_container` 是死参数 | **采纳**，删除。两处调用都传 `nil`，两个分支永远不进 |
| 4 | 按玩家缓存 `GetServerMarks` | **不采纳**（跨调用缓存）。只做「同一次 GiveItem 内复用」，见 §3.10 |
| 5 | `GetSpecializedContainersForItem` 空表早退 | **不采纳**。原版 `Inventory:GetSpecializedContainers()`（`components/inventory.lua:1481`）只返回 `nil` 或非空表，空表不会出现 |
| 6 | `OnUpdate` 移除 `RefreshSlotBorderLayout` | **部分采纳**。不移除（怕别的模组动态改槽位尺寸），改为尺寸缓存 + 只查一次尺寸，见 §3.10 |
| 7 | 循环内重复查 store | **部分采纳**。没抽 store 局部变量，改的是更贵的那一半：`CanItemUseStoredMark` 不建表 |
| 8 | `Traceback` 闭包提到模块级 | **采纳** |
| 9 | 两个预测函数加同步维护说明 | **采纳**（注释） |
| 10 | 合并两处 `AddComponentPostInit("inventory")` | **不采纳**。省的是加载期两次注册，收益接近零，改动面反而大 |
| 11 | 统一用 `ISR.GetContainerSlotCount` | **部分采纳**。找「第一个」的两处统一了；`GetAvailableStackRoomInInventory` 保持 `pairs`（求和与顺序无关，换成槽数上限反而多一层对 `GetNumSlots` 的依赖） |
| 12 | `0.25` 魔数提成常量 | **采纳**，并写清取值依据（`ISR.SNAPSHOT_REQUEST_TIMEOUT`） |
| 13 | `open_container_widgets` 补销毁清理 | **采纳**。包 `Kill`（`widgets/widget.lua:325`，`KillAllChildren` 也走它）；Widget 类没有 `OnDestroy` |
| 14 | `GetSlotBaseSize` 别每次建表 | **采纳** |
| 15 | `IsStorageWithinRange` 不缓存 | **采纳**（注释写明理由） |
| 16 | `ResolveStoragePath` 的正则放宽到 `%w+` | **采纳**，并补了路径格式注释 |

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
