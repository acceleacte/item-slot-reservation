# 暗影切斯特 / 打开容器「借料与放置失效」排查报告

日期：2026-11-08
排查对象：Item Slot Reservation 0.1.83（工坊在 0.1.82 基础上待发布）
结论置信度标注：**高** = 代码或日志可证；**中** = 代码可证但未在全部环境复现；**低** = 推测

---

## 0. 结论（先行）

1. **这是三个独立缺陷叠在一起，不是一处写错（高）**：
   - **A. 宿主解析断链**：暗影切斯特的容器被移到口袋维度实体上，ISR 靠「扫有标记的容器」反查回路，容器没标记时反查失败 → 距离按口袋实体坐标 `(0,0,0)` 算 → 所有放置判 `:range`
   - **B. 客户端统计口径**：服务端和客户端对「打开的容器」的统计范围不一样，ISR 却用同一份供应补两边 → 打开容器时配方整片灰
   - **C. GUID 漂移**：`GetGUID` 依赖一个会被反复改写的缓存字段，同一个容器两次查询返回两个 GUID → 目标匹配随机失败（`:target`）
2. **症状与缺陷不是一一对应（高）**：「打开不能合成」和「关掉能合成」是 B；「物品进不了格子」是 A + C；「开着/关着都不行」是 A 覆盖了 B 的修复效果
3. **一条通用教训（高）**：凡是用「注册表反查」代替「显式映射」、用「缓存字段」参与身份计算的地方，都会出现这种时好时坏。代理容器的映射必须在组件 `SetMaster` 时建立，懒查必然断
4. **改动不影响存档（高）**：没有改存档结构，只改标记落库位置与判定路径；已写好的标记两个方向都能读到（store 回退），不需要迁移

---

## 1. 现象与日志对照

四条症状，各自对应不同的日志关键字：

| 玩家描述 | 日志关键字 | 含义 | 对应缺陷 |
|---|---|---|---|
| 打开暗影切斯特，合成栏整片灰；关掉立刻亮 | `Craft supply short <prefab> have 0 supply 0 need N` 紧跟在 `Craft supply received` 里该材料消失之后 | 客户端原版统计给 0，ISR 供应也为 0 | B |
| 往暗影切斯特的固定格扔东西，物品掉地上 | `Marked placement no hit <prefab> reason auto_place skipped <guid>@<slot>:range` | 距离判定失败，不是标记没写 | A |
| 同一批标记时而命中时而跳过 | `skipped <guid>@<slot>:target` | 目标 GUID 与标记 GUID 对不上 | C |
| WX 拓展格只有关着能借料 | `Craft supply synced` 在开关之间来回跳 | 打开时该容器被排除出供应 | B |

**关键取证**（2026-11-08 会话，`Documents\Klei\DoNotStarveTogether`）：

```
[00:01:34] Marked placement no hit  cutgrass  reason auto_place  skipped 102080@2:range
[00:02:49] Marked placement no hit  cutgrass  reason container_give  skipped 102080@2:target
[00:04:22] Server mark set container 121694 slot 1 prefab cutgrass order 5
[00:04:23] Craft supply synced cutgrass:100
[00:04:26] Craft supply synced            ← 3 秒后变空
```

```
[02:39:06] Craft supply received  ...;cutgrass:99;...     关着 → 能借
[02:40:22] Craft supply received  ...（cutgrass 消失）
[02:40:22] Craft supply short  cutgrass  have 0  supply 0  need 1
[02:40:24] Craft supply received  ...;cutgrass:99;...     关上 → 恢复
```

日志的读法：`skipped` 后面是 `<容器GUID>@<格号>:<跳过原因>`，原因只有五种 —— `target`（不是本次目标）、`source`（来自这个容器）、`adapter`（没有适配器）、`guid`（适配器回报的 GUID 不一致）、`range`（超距）、`slot`（该格放不下）、`place`（放置动作失败）。**先看原因，再改代码**，不要看到 `no hit` 就以为标记没写进去。

---

## 2. 缺陷 A：口袋维度容器的宿主解析断链（高）

### 2.1 原版怎么藏容器

`scripts/prefabs/chester.lua` 的 `SwitchToShadowContainerProxy`：

```lua
inst:RemoveComponent("container")
inst:AddComponent("container_proxy")
inst.components.container_proxy:SetMaster(TheWorld:GetPocketDimensionContainer("shadow"))
```

物品搬进 `pocketdimension_container`（`scripts/prefabs/pocketdimensioncontainers.lua`），那个实体：

```lua
inst.entity:AddNetwork()
inst.entity:Hide()
inst:AddTag("CLASSIFIED")
```

**它没有世界坐标意义**（服务端 `AddTransform` 只为存档，位置是 `(0,0,0)`），读档时 `OnLoadPostPass` 会再切一次。

### 2.2 ISR 断在哪

`ISR.GetProxyOwner(master)` 原先只在 `ISR._mark_containers` 里反查「哪个实体的 `container_proxy:GetMaster()` 等于它」。而那张注册表由 `isr_slotmarkstore:SetMark` 填充 —— **没写过标记的容器根本不在里面**。

失配链条：

1. 打开暗影切斯特 → UI 槽位绑口袋维度实体 → 标记按口袋实体的 GUID 落库
2. 切斯特实体自己没有标记 → 不注册 → `GetProxyOwner(口袋)` 返回 nil
3. `IsStorageWithinRange` 的 anchor 退化成口袋实体 → 坐标 `(0,0,0)`
4. 玩家不在地图原点 → 距离超限 → 所有放置 `:range` 跳过
5. 同一个 nil 让 `SetProxyTwinMark` 也失效 → 双写从未发生 → 开关容器看到两套不同状态

### 2.3 修法

在组件初始化时建立显式映射，不懒查：

```lua
-- scripts/isr_storage.lua
AddComponentPostInit("container_proxy", function(self)
    local old_SetMaster = self.SetMaster
    function self:SetMaster(ent)
        local prev = self.master
        old_SetMaster(self, ent)
        -- 清旧、记新：ISR._proxy_hosts[真容器GUID] = 宿主实体
    end
end)
```

`GetProxyOwner` 先查 `_proxy_hosts`，再退回扫注册表（兼容 postinit 未覆盖到的老实体）。`IsStorageWithinRange` 的 anchor 顺序也改成「宿主 → `_isr_owner_inst` → 容器持有者 → 自身」，不让缓存字段抢在映射前面。

---

## 3. 缺陷 B：客户端统计口径与服务端不一致（高）

### 3.1 两端的统计范围

| 端 | 函数 | 统计范围 |
|---|---|---|
| 服务端 | `Inventory:Has(item, amount, true)`（`components/inventory.lua`） | 物品栏格 + 手持 + `GetOverflowContainer()`（BODY 背包）+ `opencontainers` |
| 客户端 | `inventory_classified:Has`（`prefabs/inventory_classified.lua`） | 同上，但 `opencontainers` 来自 `inventory_replica:GetOpenContainers()` |

客户端的 `GetOpenContainers()` 有一层服务端没有的过滤：

```lua
for k, v in pairs(self.inst.HUD.controls.containers) do
    if v ~= nil and v.inst.entity:IsVisible() and k:IsValid() then ...
```

于是三类容器在客户端**数不到**：

| 容器 | 原因 |
|---|---|
| 口袋维度容器（暗影切斯特） | `entity:Hide()` → `IsVisible()` 为假，永远进不了名单 |
| 物品栏里的 WX 储物箱 | 锁在物品栏格，实体不在 HUD 的可见容器集合里 |
| 多人同时打开 | `opencount > 1` 时 `SetClassifiedTarget(nil)`，所有客户端都收不到 classified 数据 |

### 3.2 为什么「猜类型」必错

第一版修复按容器类型判断（`pocketdimension_container` 标签或 `opencount > 1` 才补）。WX 储物箱两者都不占，于是「关着能借、打开不能」—— **服务端猜不出某台客户端能不能数到某个容器**，这是 replica 同步状态，不是容器属性。

### 3.3 修法：客户端全收 + 自己扣

供应拆两个口径：

```lua
ISR.GetCraftingSupply(player)          -- 服务端：排除所有打开容器
ISR.GetCraftingSupply(player, true)    -- 客户端：全收
```

服务端口径不能收：原版 `GetIngredients` 已经把打开容器填进 `materials`，再填一次就是重复扣料（合成少付钱）。

客户端口径不能只收一部分：猜不准。所以全收，然后由客户端把「原版 count 里已经数到的打开容器部分」减掉：

```lua
local counted = CountCountedOpenContainerItems(inventory, v.type, true)  -- 照抄 inventory_classified:Has 的遍历与过滤
local visible = math.max(0, (count or 0) - counted)
if visible + supply < amt then return false end
```

数学上恒等：`count` 与 `counted` 用同一套判定，能数到的部分被减掉，数不到的部分为 0，两种极端都不会重复或遗漏。

**症状对照**：打开容器配方全灰 → 客户端口径没收打开容器；按钮亮着但点了没反应 → 扣减漏了（同一批货算两遍，客户端高估、服务端拒绝）。

---

## 4. 缺陷 C：GUID 漂移（高）

容器适配器的 `GetGUID` 原先优先读 `storage._isr_owner_inst`：

```lua
-- isr_storage.lua 的 container 适配器
GetStorageFromEntity = function(_, inst)
    local container = ISR.GetContainerComponent(inst)
    if inst.components.container == nil then
        container._isr_owner_inst = inst        -- 从切斯特取 → 设成切斯特
    elseif container._isr_owner_inst ~= nil then
        container._isr_owner_inst = nil          -- 从口袋实体取 → 清掉
    end
    return container
end
```

同一个真容器组件，两次取值可能带回两个不同 GUID。`Marked placement` 里 `mark.container_guid == target_guid` 因此时真时假 —— 这就是 `:target` 与命中交替出现的原因。

修法：

```lua
GetGUID = function(_, storage)
    local inst = storage.inst
    local host = inst ~= nil and ISR.GetProxyOwner(inst) or nil
    if host ~= nil then
        return host.GUID            -- 恒返回宿主，身份不随访问顺序变
    end
    ...
end
```

同时新增 `ISR.IsSameStorage(a, b)`：判断两个 GUID 是否指向同一个物理容器（比较解引用后的容器组件）。放置路由的「目标 / 来源 / 适配器回报」三处比较全部换成它，不再直接 `==`。

---

## 5. 修复清单

| 文件 | 改动 |
|---|---|
| `scripts/isr_storage.lua` | `container_proxy:SetMaster` 建宿主映射；`GetProxyOwner` 先查映射；`GetProxyTwinEntity` 双向；`IsSameStorage`；`GetGUID` 恒返回宿主；`IsStorageWithinRange` anchor 顺序 |
| `scripts/isr_crafting.lua` | 供应双口径；`CountCountedOpenContainerItems`；`Craft supply short` 日志增加 `open` 字段 |
| `scripts/isr_slotmarks.lua` | `SetProxyTwinMark` / `ClearProxyTwinMark` 双向；twin 同步只推给正打开它的人（CLASSIFIED 实体别人没副本） |
| `scripts/isr_markstores.lua` | `GetSlotMarkStoreForGUID` 查不到 store 时回退 twin |
| `scripts/isr_placement.lua` | 目标/来源/存储三处 GUID 比较改为 `IsSameStorage` |
| `tests/test_proxy_chester.lua` | 宿主映射、store 回退、同容器等价、客户端扣减四类用例 |

前置的两个修复（同一版本内）：

- 切斯特没眼骨跟随时标记能写进服务端却推不回客户端 → 可见性与枚举补「容器正被这名玩家打开」
- WX-78 拓展储物箱不能借料 → 排除规则与原版三处精确对齐

---

## 6. 验证方法

进游戏后按日志关键字判断，不用猜：

| 日志 | 说明 | 是否正确 |
|---|---|---|
| `Marked placement hit <prefab> container <guid> slot N` | 物品按标记进了容器 | ✅ |
| `Marked placement no hit ... :range` | 距离超限（`container_range` = near 时约 20） | 走近再看；仍报则是缺陷 A |
| `Marked placement no hit ... :target` | 目标与标记不是同一容器 | 仍报则是缺陷 C |
| `Proxy twin mark set container <guid>` | 双写生效 | ✅ |
| `Craft supply synced cutgrass:N` | 供应里含该材料 | ✅ |
| `Craft supply short <p> have A open B supply C need N` | `open` 是客户端自己数到的打开容器量 | `A + C >= N` 时不该报 |

命令位置：

- 服务端：`Documents\Klei\DoNotStarveTogether\master_server_log.txt`
- 客户端：同目录 `client_log.txt`
- 存档是明文 lua，`grep -a "ents_chester_fn"` 能直接看实体数据，比读日志快

---

## 7. 经验

1. **代理容器（proxy）必须有显式双向映射**，在 `SetMaster` 时建，不要懒查。任何「扫一遍有标记的实体」的方案，都会在「还没标记」的窗口里断链
2. **不要让缓存字段参与身份计算**。`_isr_owner_inst` 这种「谁最后访问谁改写」的字段，拿来做 GUID 就是顺序依赖型 bug，表现为随机失败
3. **两端统计口径必须分别验证**。服务端能算到 ≠ 客户端能算到；差一层 `IsVisible()` 就是一个完整功能的盲区
4. **不要在服务端猜客户端能力**。replica 的可达性属于客户端运行时状态，按容器类型猜必然漏一个
5. **日志里带枚举原因**（`:range` / `:target` / `:slot`）比只打 `no hit` 省掉几小时的猜测。新增分支时顺手把原因加上
