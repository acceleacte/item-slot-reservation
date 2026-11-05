# 五格装备栏下「背包 / 护符消失」排查报告

日期：2026-11-02
排查对象：Item Slot Reservation 0.1.52 + 玩家报告的两个装备栏类模组
结论置信度标注：**高** = 代码可证；**中** = 代码可证但未在现场复现；**低** = 推测

---

## 0. 结论（先行）

1. **ISR 不删除物品（高）**。整个发布目录没有一处 `item:Remove()`，不 hook `Inventory:Equip/Unequip/DropItem`，也不接管装备槽 widget。它能做的只有"搬运"，而每次搬运都在 `GiveItem` 里留日志（§4.3）
2. **能造成"真丢"的代码路径只有两条，都在装备栏模组侧（高）**：
   - **P1 孤儿装备槽**：物品仍在 `inventory.equipslots[旧键]`，但该键已不在 `EQUIPSLOTS` 的值集合里 → HUD 不再绘制该槽 → 玩家看到"装备空了"。此时存档仍带着它（不是真丢），但背包容器同时从 `GetOverflowContainer()` 消失，包里的东西一起"不见"
   - **P2 顶替装备时掉落**：`Inventory:Equip` 顶掉同槽旧装备，旧装备是背包时走 `DropItem`（原版 `components/inventory.lua:1352-1354`，因为 `cangoincontainer=false` 走不了 `GiveItem`）。读档瞬间玩家坐标未就绪，掉落点是 `(0,0)` 或未加载区域 → 真丢
3. **这两个装备栏模组不会"互相打架"，而是互相踢掉（高）**：`workshop-3173431824` 的 `scripts/modconfig.lua:43` 检测到 `EQUIPSLOTS.BACK/NECK` 已存在就 `return nil` 整体退出；`workshop-375850593` 的 `priority = 10` 高于它的 `0`，而引擎按 priority **降序**加载（`scripts/mods.lua:518` 的 `return apriority > bpriority`）。所以同时订阅时 **375850593 先加载、把 3173431824 顶掉**。玩家以为在用「四五六格」，实际跑的是「五格」
4. **玩家点名的「EquipAutoRepair」不存在（高）**。本机 `mods/` 与工坊缓存 47 个模组的 `modinfo.lua` 里没有任何叫这个名字的；`repair` 字样只出现在 3173431824 的 `compat.lua` 注释里。玩家实际指的就是 §1 表中这两/三个

---

## 1. 现场核对

| 玩家说法 | 实际模组 | ID | 关键声明 |
|---|---|---|---|
| 五格（包 + 护符） | Extra Equip Slots | `workshop-375850593` | 5 槽：hands/head/body/**back**/**neck**；`priority=10`；`all_clients_require_mod=true` |
| 《四五六格装备栏（自用超强版）》 | 同名 | `workshop-3173431824` | 3 个可选扩展槽，键名 `extra_slots_back/neck/belly`；`priority` 未设（0）；带防冲突自退 |
| （玩家可能同时装的）死亡不掉落 | Don't Drop Everything | `workshop-661253977` | 覆写 `Inventory:DropEverything`；无 priority（0） |
| 本模组 | Item Slot Reservation | `workshop-3830575143` | 无 `priority`（0）；`all_clients_require_mod=true` |

加载顺序（同 priority 按模组名字典序，`mods.lua:503-518`）：`375850593` → `3173431824` / `3830575143` / `661253977`

**推论（高）**：只要玩家同时勾了 375850593 与 3173431824，后者一定不生效。不需要再花时间查"两个装备栏模组同时改槽"的冲突——那条路被模组自己的守卫堵死了

---

## 2. 先分清三类现象（30 秒，决定后面查什么）

| 现象 | 判定 | 怎么查 |
|---|---|---|
| 装备栏里看不到包/护符，但背包还能正常打开 | **隐形**（槽键失效） | 存档 `Cluster_N/Master/save/session/<id>/<player_id>` 文件里的 `equip` 表：键名是不是 `back`/`neck`/`extra_slots_back` 之类；有键就是没丢 |
| 装备栏空、背包也打不开、地上也没有 | **真丢** | 同上看 `equip` 表；同时 `c_findnext("backpack")` / `c_findnext("amulet")` 找世界上有没有 |
| 装备上了，HUD 只画了 3 个槽 | **UI 漏画** | 看 §3.1 的 `addextraslots` 共用字段问题 |

判定为「隐形」时，物品 100% 还在存档里，可以用控制台救回来：

```lua
-- 客户端/主机控制台，隐形槽里的东西脱出来
local inv = ThePlayer.components.inventory
for k, v in pairs(inv.equipslots) do
    print(k, v and v.prefab)
end
```

---

## 3. 三个模组的实际改写面（代码级）

### 3.1 `workshop-375850593` Extra Equip Slots 1.8.0（玩家口中的"五格"）

| 行为 | 位置 | 后果 |
|---|---|---|
| **整表替换** `GLOBAL.EQUIPSLOTS`（不是逐键赋值） | `modmain.lua:16-22` | 其它模组先注册的槽位键被整体抹掉；已有装备的槽位键变成孤儿 |
| 用 `pairs` 重建 `EQUIPSLOT_IDS` | `modmain.lua:24-29` | 与引擎 `equipslotutil.lua` 的 `orderedPairs` + 反向排序规则不一致；引擎那份在模组加载后初始化，两者可能给出不同编号 |
| 背包 → BACK、护符 → NECK | `modmain.lua:390-404` | 存档里 `equip` 表的键从 `body` 变成 `back`/`neck` |
| `GetOverflowContainer()` 改指 BACK 槽容器 | `modmain.lua:86-97`（服务端）、`264-271`（客户端 classified） | 溢出落点从"身上穿的容器"变成"背上的背包"；ISR 的兜底落点跟着变（§4.2） |
| 包装 `Inventory:Equip` | `modmain.lua:110-124` | 只补发 `setoverflow`，且丢掉 `no_animation`/`force_ui_anim` 两个参数 |
| `AddComponentPostInit("resurrectable", ...)` | `modmain.lua:32-70` | **死代码**：原版 `scripts.zip` 里没有 `resurrectable` 组件（已解包核对），这段永远不执行 |
| `amulet_rebirth` 的 `onexit` 才消费 NECK 护符 | `modmain.lua:355-368` | 原版在 `onenter` 就消费 BODY 护符（`SGwilson.lua:15231`）。EES 改到 `onexit`，效果等价；但 `item:Remove()` 之后再写 `item.persists = false` 是无效语句 |
| **无** `DropItem` / `isloading` 保护 | 全文无 `DropItem` | 顶替装备时旧背包直接落地上（P2） |
| **无** 复活后恢复扩展槽装备 | 全文无 `respawnfromghost` | 扩展槽里的装备依赖原版掉落流程 |

### 3.2 `workshop-3173431824` 四五六格装备栏 2.4.0

它自己就把 P1/P2 治了，正好是这次要的证据：

| 行为 | 位置 |
|---|---|
| 槽键固定为 `extra_slots_back/neck/belly` | `scripts/slots.lua:23-30` |
| **防冲突自退**：`EQUIPSLOTS` 里已有 BELLY/NECK/BACK 就 `return nil` | `scripts/modconfig.lua:43` |
| 读档期 `DropItem` 保护：先塞物品栏 → 再塞溢出容器 → 都放不下才延迟一帧落在脚下 | `scripts/compat.lua:473-515` |
| `respawnfromghost` 后把 BACK/NECK 的装备脱下来再穿回去 | `scripts/compat.lua:518-560` |

`compat.lua:473` 的原始注释直接描述了玩家这次的现象：

> 模组更新改变了某些装备的匹配槽位、或从别的装备栏模组切换过来时，读档瞬间可能出现"两个装备争同一个槽位"，原版会把被挤出的装备直接 DropItem——此时玩家坐标还没加载好，掉落会落在地图原点(0,0)甚至看起来像消失

**这就是 P2 的官方确认版**。375850593 没有这段

### 3.3 `workshop-661253977` Don't Drop Everything

| 行为 | 位置 | 后果 |
|---|---|---|
| 整体替换 `Inventory:DropEverything` | `modmain.lua:94-101` | 只有"玩家且 health<=0"才走自定义，其余回原版 |
| `DropSuiji` 第二个循环用了上一循环的 `v`（越界，实际是全局 nil） | `modmain.lua:56-63` | 物品栏**一件都不掉**；`return false` 还可能提前结束 |
| 第三个循环 `if v == nil` 恒真 | `modmain.lua:65-69` | `nillots` 恒加 `maxslots` → 后面"保底丢一格"永不执行 |
| 装备循环按 `HasTag("backpack")` 保留背包，其余装备 `DropItem` | `modmain.lua:78-93` | 死亡时护符/护甲/工具掉在地上，背包保留 |

**判定（高）**：DDE 不会让物品凭空消失。它的实际效果是"物品栏全留下 + 装备全掉地上 + 背包内容随机掉一部分"。护符掉在地上没人捡 → 玩家视角就是"护符不见了"。这属于**误导性现象**，不是删除

---

## 4. ISR 与装备槽的交叉点

### 4.1 钩子清单（全部）

| 钩子 | 位置 |
|---|---|
| `inventory.GiveItem` / `GetNextAvailableSlot` | `scripts/isr_inventoryhooks.lua:67` 起（`74`、`137`、`281`） |
| `container.GiveItem` / `MoveItemFrom*` | `scripts/isr_inventoryhooks.lua:213`、`314` |
| `container.OnLoad` 包装 + 挂 `isr_slotmarkstore` 组件 | `scripts/isr_markstores.lua:111-134` |
| `inventory.OnLoad`（标记备份恢复） | `scripts/isr_persistence.lua:123-138` |
| `inventory_classified.ReceiveItem`（客户端预测） | `scripts/isr_clientpredict.lua:265` |

**没有** `Equip`、`Unequip`、`DropItem`、`equipslots` 写入、装备槽 widget 接管。`ISR.IsClientMarkableSlot` 对装备槽恒返回假（`isr_storage.lua:294-298`：装备槽 widget 的 `container` 为 nil）

### 4.2 三处真实交叉

1. **溢出落点语义被 EES 改写（中）**。ISR 多处把 `inventory:GetOverflowContainer()` 当"最后兜底落点"（`isr_inventoryhooks.lua:154`、`isr_candidates.lua:242`、`276`）。EES 把它的返回值从"身上穿的容器"改成"BACK 槽的背包"。结果：ISR 认为的兜底和原版认为的兜底是同一个容器，**但客户端 EES 只改了 classified 版**（`modmain.lua:264-271`，仅 `not IsServer`）。主机 сам 开服时两端行为不一致的概率低，但专用服务器 + 客户端两侧若加载顺序不同，会出现"预测进背包、服务端进物品栏"的一帧错位——只影响落点，不影响存亡
2. **`TryGiveItemToContainer` 会 `Unequip` 且丢弃返回值（中）**。`isr_inventoryhooks.lua:15-20`：物品若要被放进容器而它当前在装备栏里，先 `inventory:Unequip(slot)`；随后 `OnPickup` → `container:GiveItem(..., false)`；**两步都失败时函数返回 false，物品停留在"已摘下、无任何容器归属"的状态**（`:26-31`）。调用方 `TryPlaceByMarks` 只会记一条 skip 继续找下一个标记格；全部失败后：
   - 从 `Inventory:GiveItem` 进来 → `return false` 给原版，原版多数路径会回滚；
   - 从 `Container:MoveItemFromAllOfSlot` 进来 → 原版有回滚（`container.lua:1377-1379`）
   
   这是**唯一一条能把物品留在 limbo 的 ISR 路径**，触发条件苛刻（背包类物品进不了容器，`CanUseContainerSlot` 会先挡掉；只有护符/工具这类 `cangoincontainer=true` 的装备可能命中）
3. **容器 `GiveItem` 在"预留树满"时 `return false`（中）**。`isr_inventoryhooks.lua:235-254`：目标容器有预留格、但没有未标记空位时直接拒绝。带 `drop_on_fail=false` 的调用方（例如 `Container:MoveItemFromAllOfSlot`）不会把物品掉地上，而是塞回源容器——**不会丢，但会让玩家觉得"操作被吞"**

### 4.3 一条可直接用的证伪判据（高）

`ISR` 的 `Inventory:GiveItem` 包装**每条都无条件调用** `ISR.Log("Inv give", ...)`（`isr_inventoryhooks.lua:147-158`）

→ 打开 modinfo 里的「调试日志」，在丢失时间点前后抓 `master_server_log.txt`：

- 有该物品的 `Inv give` 记录且后续没有对应 `itemget`/落点日志 ⇒ 物品经 ISR 改道，按 §4.2 查；
- **完全没有** `Inv give` 记录 ⇒ 物品没走物品栏 `GiveItem` 链路，ISR 不可能是搬运者，问题在装备栏模组的 `Equip`/`DropItem` 路径

---

## 5. 复现矩阵（给玩家跑，4 组就够）

每组重复三个动作：① 穿着背包+护符死亡并复活；② 退出重进两次；③ 下地穴再上来

| # | 启用 | 预期（本报告的预测） |
|---|---|---|
| A | 仅 ISR | 不丢（空白对照） |
| B | ISR + 375850593 | 若丢 ⇒ 锁定 EES；查 §2 是隐形还是真丢 |
| C | ISR + 3173431824 | 不丢（它自带 P1/P2 补丁） |
| D | ISR + 375850593 + 3173431824 | 与 B 完全一致（3173431824 被顶掉，日志里会看到它没加载） |

判读要点：

- D 组行为 == B 组 ⇒ 证实 §0-3「互相踢掉」，不必再查双装备栏冲突
- B 组丢、且存档 `equip` 表里**有** `back`/`neck` 键 ⇒ §0-2 P1 隐形，按 §6.1 迁回
- B 组丢、存档 `equip` 表里**没有**键、地上也没有 ⇒ §0-2 P2 真丢，需要玩家回忆是否在"读档瞬间"顶替过同槽装备（换背包、换护符、装/卸装备栏模组的那一次读档）

---

## 6. 修复建议

### 6.1 玩家侧（立刻可做，高）

1. **两个装备栏模组二选一**，且优先保留 `3173431824`（它自带 P1/P2 两个保护 + 复活恢复）。若玩家更想要 EES 的五槽布局，就必须接受"顶替同槽装备会掉地上"这个原版行为
2. **切换/启用装备栏模组前**，先把背包和护符脱下来放进箱子，再装模组、再读档。这一步能规避 P2 的绝大多数场景（读档瞬间没有"两件装备争同槽"）
3. 已经丢过的档：按 §2 的控制台代码把 `equipslots` 里非标准键的物品脱出来；真丢的按 `equip` 表缺失判断，只能回档

### 6.2 EES 侧补丁思路（不建议直接改工坊模组，仅列方案）

两个补丁，缺一不可：

```lua
-- 1) 孤儿槽迁移：读档完成后，把键不在 EQUIPSLOTS 值集合里的装备迁回合法槽
AddPlayerPostInit(function(inst)
    inst:DoTaskInTime(0, function(p)
        local inv = p.components.inventory
        if inv == nil then return end
        local valid = {}
        for _, v in pairs(GLOBAL.EQUIPSLOTS) do valid[v] = true end
        for k, item in pairs(inv.equipslots) do
            if not valid[k] and item:IsValid() then
                inv:Unequip(k, nil, true)
                if not inv:Equip(item) then inv:GiveItem(item) end
            end
        end
    end)
end)

-- 2) 读档期掉落保护（照抄 3173431824 compat.lua:473-515 的思路）
--    isloading 时 DropItem 先 GiveItem，其次溢出容器，最后延迟一帧落脚下
```

### 6.3 ISR 侧加固（建议，低风险）

**(a) `TryGiveItemToContainer` 失败必须回滚**（`isr_inventoryhooks.lua:10-34`）。现在失败时物品已 `Unequip`/`RemoveFromOwner` + `OnPickup`，却无处落地：

```lua
    if container:GiveItem(item, slot, src_pos, false) then
        if item.components.equippable ~= nil then
            item.components.equippable:ToPocket()
        end
        return true
    end

    -- 失败：物品已被摘下且不在任何容器里。塞回物品栏，塞不下才掉在脚下
    ISR.Log("Container place failed, rollback", tostring(item.prefab))
    if not inventory:GiveItem(item, nil, src_pos) then
        inventory:DropItem(item, true, true)
    end
    return false
```

**(b) 容器预留满时不要静默 `return false`**（`isr_inventoryhooks.lua:241-249`）。改成"先尝试本容器未标记空位 → 没有就走原版"，避免吞掉调用方的操作：

```lua
            if next_slot == nil then
                ISR.Log("Reserved container full", tostring(item.prefab),
                    "container", tostring(container_guid), "drop_on_fail", tostring(drop_on_fail))
                return old_GiveItem(self, item, nil, src_pos, drop_on_fail)  -- 交回原版裁决
            end
```

**(c) modinfo 描述里加一句兼容说明**：与改写 `EQUIPSLOTS` / 新增装备槽的模组同用时，若出现装备消失请先看本报告 §2 的隐形/真丢判定

---

## 7. 未决项 / 需要现场数据

本机无法复现：玩家存档不在本机，且本地三个存档（Cluster_1~3）只启用了 `375850593` + `661253977` + ISR，没有任何一次带扩展装备槽的实测记录。要把「中」置信度的 P1/P2 提到「高」，需要玩家提供：

1. 丢失前后 5 分钟的 `client_log.txt` + `master_server_log.txt`（含 `[ItemSlotReservation]` 调试日志）；
2. `Cluster_N/Master/save/session/<id>/<player_id>` 里的 `equip` 段；
3. 当时的模组列表截图（确认 3173431824 是否真的在勾选状态）；
4. 丢失前 5 分钟内是否做过"换背包 / 换护符 / 装或卸装备栏模组后第一次读档"

拿不到 1-4 也能结论：按 §5 的 B/D 两组对照，就能在玩家端把责任锁到具体模组

---

## 8. 追加（2026-11-03）：「护符栏整栏消失」是另一件事，已定位并修复

现场数据：`client_log.txt` 00:05:15 那次会话，加载顺序是
`item-slot-reservation-test` → `workshop-3173431824`（两者 `priority` 都是 0，按 `modinfo.name` 排）

### 8.1 机制

- 装备栏类模组加槽靠**替换类方法**（`3173431824/scripts/slots.lua:53-68` 加槽、`:120-137` 包 `Rebuild`/`Refresh`）：
  ```lua
  local Inv_Rebuild_base = Inv.Rebuild
  function Inv:Rebuild()
      Inv_Rebuild_base(self)
      Inv:RebuildExtraSlots(self)   -- 这里才 AddEquipSlot(护符栏)
  end
  ```
- ISR 0.1.52 及更早用 `AddClassPostConstruct("widgets/inventorybar", ...)` 在**构造期**包 `self.Rebuild`
  `function self:Rebuild` 写的是**实例字段**，把当刻的类方法引用冻住了（`modutil.lua:153-158`：`_ctor` 尾部回调）
- 于是：ISR 先加载 → 冻结的是原版方法 → 四五六格随后换掉**类**方法 → 实例字段仍指向旧方法 →
  `RebuildExtraSlots` 永远不执行 → 护符栏画不出来。`Refresh` 同理
- Extra Equip Slots（`375850593`）`priority = 10`，先于 ISR 加载，所以「只装它 + ISR」不出问题
  这就是为什么只有一部分玩家中招 —— 取决于装备栏模组的 `priority` 与 `modinfo.name`

### 8.2 修复（0.1.6，发布号由 0.1.53 回落）

`scripts/isr_uihooks.lua`（0.1.6）不再在构造期包实例方法，改为**加载期取类、包类方法**：

```lua
local InventoryBarClass = GetInventoryBarClass()   -- require("widgets/inventorybar")，pcall 保护
if InventoryBarClass ~= nil and not InventoryBarClass._isr_class_hooked then
    InventoryBarClass._isr_class_hooked = true
    local base_Rebuild, base_Refresh = InventoryBarClass.Rebuild, InventoryBarClass.Refresh
    function InventoryBarClass:Rebuild(...) ... end
    function InventoryBarClass:Refresh(...) ... end
end
```

回归测试 `tests/test_inventorybar_hook.lua`：模拟「ISR 先加载 → 装备栏模组后包类方法」，断言两条链路都执行、重复加载不重复包装。全量 32 个测试文件通过

### 8.3 对前文的修正

- 「护符栏 / 背包栏整栏消失」发生时，**装备根本没丢**：它还在 `inventory.equipslots[back|neck]`，只是 HUD 没画那个槽。属于 §0-2 的 P1 前身，且比 P1 更早、更常见
- §0-2 的 P2（顶替装备走 `DropItem`）与 §3.3 的 DDE 结论不变，仍是「真丢」的唯一来源
