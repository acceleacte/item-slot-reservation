# 更新日志 / Changelog

Item Slot Reservation（物品格预留）· 工坊 ID `3830575143`

版本号按字符串比较决定工坊是否提示更新，`0.1.82` 高于 `0.1.81`

未发布期间所有改动合并进同一个待发布号；一次发布只递增一位，不跳号（`0.1.7` → `0.1.8`）

---

## 0.1.83 — 2026-11-05

**修复：切斯特没眼骨跟随时标记能写进去、客户端却收不到（点了没反应）**

- 现象：眼骨放在地上时给切斯特的格子打标记，木框不出现、物品也不自动回位；把眼骨捡起来（切斯特恢复跟随）后同一步操作立刻正常
- 日志证据：服务端每次点击都记录 `Server mark set container <guid> slot 4 prefab flint order 85→88`，客户端同期的 `Client mark synced` 里查不到这只容器（其它容器照常收到快照）
- 根因：`set_slot_mark` 的 RPC 入口有「容器正被这名玩家打开就放行」这条例外，但 `ISR.IsMarkContainerVisibleTo` 与 `ISR.GetServerMarks` 只看归属判据。切斯特不跟随任何人时 `follower:GetLeader()` 为 nil / 指向旧实体，两条判据同时为假 → 变更被拦在服务端
- 修法：抽出 `IsContainerOpenedByPlayer`，在可见性判定、标记枚举、以及 `set_slot_mark` 成功/清除后的回推都用同一判据；发起点无条件先收到自己的那份同步
- 测试：`tests/test_shared_container.lua` 增加「跟随别人的切斯特被打开」用例，覆盖可见性、枚举与路由

**修复：WX-78 拓展储物箱（以及其他随身容器）不能借料合成**

- 现象：机器人的拓展储物箱里固定的材料不参与借料合成
- 根因：借料供应把「随身容器」整类排掉了（`IsStorageCarriedByPlayer`），理由是「原版 overflow 已算」。实际上原版 `Inventory:Has` 的 overflow 只认**装备栏 BODY 背包**（`GetOverflowContainer()`），物品栏里锁着的 `wx78_inventorycontainer`、背包里的桶都不在原版统计范围内
- 修法：排除条件改为与原版三处精确对齐 —— 玩家自己、`GetOverflowContainer()` 返回的那只、玩家正打开的容器；其余随身容器进供应。另加 `canbeopened == false` 排除（打不开就取不出来）
- 测试：`tests/test_crafting.lua` 补「物品栏里的容器算供应」「BODY 背包不重复计入」两条

**修复：切斯特升级成暗影切斯特后借料合成失效**

- 现象：喂 9 个噩梦燃料把切斯特变成暗影切斯特后，固定格里的材料不再参与借料合成；标记框也可能对不上
- 根因：原版 `chester.lua` 的 `SwitchToShadowContainerProxy` 会把切斯特的 `container` 组件整个 `RemoveComponent` 掉，物品搬进 `TheWorld:GetPocketDimensionContainer("shadow")`，实体上只剩 `container_proxy`（读档时 `OnLoadPostPass` 还会再切一次）。ISR 到处只认 `components.container`，于是借料、自动归位、共享容器判定全部拿不到容器；标记本身还留在切斯特实体上（存档已验证：`isr_slotmarkstore` 里有 `nightmarefuel` 固定在 9 格）
- 修法：新增 `ISR.GetContainerComponent`，`container_proxy` 顺着 `GetMaster()` 解引用到真容器；存储适配器按外层实体还原 GUID；距离改用代理所有者（切斯特）而不是口袋维度实体；同一物理格被两套标记指向时按真容器 GUID + 格号去重，避免材料算两遍；清除一侧时连带清另一侧同格，避免「框擦了还在借料」
- 雪切斯特（9 个蓝宝石）走 `SwitchToContainer`，实体上就是普通 `container` 组件，无需额外适配，本版一并加了回归用例
- 测试：新增 `tests/test_proxy_chester.lua`（36 个用例）

**修复：打开暗影切斯特时配方整片变灰，关掉才亮**

- 现象：打开暗影切斯特，合成栏里用到固定格材料的配方全部变灰；把容器关掉，同一批配方立刻亮
- 日志证据：`client_log.txt` 里容器的 cutgrass 从 supply 消失的同一秒出现 `Craft supply short cutgrass have 0 supply 0 need 1`，两秒后 supply 恢复 `cutgrass:99`；服务端 `Craft supply synced` 在开关之间来回跳
- 根因：给客户端的供应与服务端共用一份口径，两边都把「正被玩家打开的容器」排除了，理由是原版 `opencontainers` 已经算过。服务端确实算得到，客户端不算 —— 口袋维度容器是 `entity:Hide()` 的 CLASSIFIED 实体，客户端 `GetOpenContainers()` 用 `entity:IsVisible()` 过滤，永远拿不到，`inventory:Has(..., true)` 给 0
- 修法：供应拆两个口径。服务端扣料维持「排除所有打开容器」（原版已把它们填进 materials，再填一次就是重复扣料）；推给客户端的 `ComputeCraftSupply(player, true)` 把打开容器全收进来，再由客户端 `HasIngredientsWithClientSupply` 扣掉「自己已经数到的打开容器部分」（`CountCountedOpenContainerItems`，遍历与过滤条件照抄原版 `inventory_classified:Has`）。服务端猜不出哪台客户端数得到（口袋维度实体 `entity:Hide()`、WX 储物箱锁在物品栏格、多人共开时 `SetClassifiedTarget(nil)`），不在服务端做减法
- 测试：`tests/test_proxy_chester.lua` 补三条（服务端口径排除、客户端口径保留、普通容器不补）

**修复：暗影切斯特的标记全部判成 :range，物品进不了格子**

- 现象：往暗影切斯特的固定格扔东西一律进不去（`Marked placement no hit ... skipped <guid>@<slot>:range`），借料同时为空；同一批标记时而命中时而 `:target`
- 根因两条：
  1. `GetProxyOwner`（口袋维度实体 → 切斯特）只在「带标记的容器注册表」里反查。容器没标记时不在注册表，反查失败 → 距离按口袋维度实体的坐标（0,0,0）算 → 永远超距
  2. `GetGUID` 依赖 `container._isr_owner_inst`，谁最后访问谁改写：从切斯特取是切斯特 GUID、从口袋实体取又变回口袋 GUID → `Marked placement` 的目标匹配随机失败
- 修法：`container_proxy:SetMaster` 时建立宿主映射（`ISR._proxy_hosts`），`GetProxyOwner` 先查映射再扫注册表；`GetGUID` 恒返回宿主 GUID；`GetSlotMarkStoreForGUID` 查不到 store 时回退 twin；新增 `ISR.IsSameStorage`，放置路由把两副面孔当同一个目标
- 测试：`test_proxy_chester.lua` 补宿主映射、store 回退、同容器等价三条

**修复：暗影切斯特的标记只写一侧，开关容器状态对不上**

- 现象：打开暗影切斯特设的标记，关掉后借料拿不到；反过来关着时看到的标记，打开后不进供应
- 根因：切斯特实体（带 `container_proxy`）与口袋维度实体（真容器）是同一个物理容器的两副面孔。UI 打开时槽位绑口袋实体，标记按它的 GUID 落库；关掉后枚举走切斯特实体。清除早已双向（`ClearProxyTwinMark`），设置却只写一侧
- 修法：抽出 `GetProxyTwin`，设置与清除都双写同一份标记（共用同一个 `order`，拾取优先级一致）。twin 那条只推给「正打开它的人」—— 口袋实体是 CLASSIFIED 的，别人没有副本，广播会打到空目标
- 测试：`tests/test_proxy_chester.lua` 补「set 双写」用例

**外观默认值调整：边框透明度默认 100% → 60%**

- 只改 `modinfo.lua` 的 `default`，档位仍是 20 / 40 / 60 / 80 / 100%
- 新订阅的玩家默认看到 60% 的木框
- 已订阅的玩家**不强制**：存档里已固化自己存下的值（含旧默认 100%），本次不做迁移，想改去设置里选
- 图标透明度（`icon_opacity`，默认 35%）不动

---

## 0.1.82 — 2026-11-05

**发布包精简：只装代码与运行资源**

- 包体从 590 KB 降到 247 KB（21 个文件），订阅下载更快
- 移出 `AGENTS.md`（54 KB 开发文档），移出根目录 `modicon.png`（289 KB 缩略图源图，只用于上传时选封面）
- 运行内容不变：`modinfo.lua`、`modmain.lua`、`scripts/` 13 个 lua、`images/` 4 个 tex/xml 与新版本一致
- `0.1.81` 的缩略图黑边修复随本版一并生效

---

## 0.1.81 — 2026-11-05

**修复：工坊缩略图四周一圈黑边**

- 现象：工坊列表与游戏内模组列表里，封面四周各约 192px 纯黑，图只占中间 1/4
- 根因：Steam 的缩略图容器固定 512x512，只做 letterbox、**不做 upscale**。上传时的 `modicon.png` 是 128x128，被原尺寸居中放进 512 画布，其余补黑（Lite 首次上传也踩了同一条）
- 修法：新增 `tools/make_cover.py`，以 `cover/isr-base-128.png`（无字原封面）为底图生成 512x512 的根 `modicon.png`：上半暗区两行字「物品格预留」/「ITEM SLOT RESERVATION」，左右边界等宽，版式与 Lite 封面同一套；物品栏区域不改动
- 游戏内 Mods 图标不受影响：`images/modicon.tex` 仍是 128 的 DXT5，与工坊缩略图是两个文件

---

## 0.1.8 — 2026-11-04

**新增：世界容器固定格的「共享 / 独占」开关（默认共享）**

- 设置项 `container_sharing`（设置界面「测试内容 → 世界容器固定格」）：
  - **共享（默认）**：箱子、无主切斯特这类世界容器上的固定格，谁能打开谁就能固定 / 改 / 清，所有人看得见，B 拾取时也回 A 固定的格；
  - **独占**：第一个在这只容器落标记的人独占，别人看不到木框、也改不动（服务端拒绝后不下发任何东西）
- 容器上重新保留 `owner` 字段（第一个落标记的人的 userid），随存档走。共享模式下它**不参与任何判定**；切到独占模式直接沿用，来回切换不需要迁移存档，也不需要重设标记
- 别人的背包、跟着别人跑的切斯特/哈奇始终不共享（那是主人的随身容器）—— 不过滤的话 B 拾取会被路由进 A 的背包

**修复一：多人服里第二个人固定基地箱子，木框闪一下就消失**

- 现象：A 打开共享箱子固定了任意一格之后，B 再固定同一只箱子的任何格，框闪一下就没了；单人、换只箱子都正常
- 根因：归属记在容器上（`isr_slotmarkstore.owner` = 第一个落标记的人），`set_slot_mark` 的 RPC 有一条容器级拦截：`owner ~= player.userid` 直接拒绝并回推 `nil`。客户端是**乐观写入**（先画框再发 RPC），所以表现为闪一下。一只箱子被一个人开过头，对其他人就整只锁死
- 修法一（默认行为）：共享模式下不再有任何按 userid 的拦截，只看「他能不能打开这只容器」
- 修法二（反馈方式，用户 2026-11-04 指定）：**没权限时不能闪，要无响应**。客户端改成「只发请求，不预写本地标记」——服务端的 `sync_mark` 回来才落库、才画框、才响固定音。被拒绝时服务端不推有效值，屏幕上完全没反应。同时清除也走同一条路，避免「先擦框再回来」的反向闪烁。代价是固定成功时框出现有一个 RPC 往返的延迟（本机/局域网无感）
- 路由：`ISR.GetServerMarks` 返回「自己的随身容器 + 可见的世界容器」上的标记。共享模式下 B 拾取回 A 固定的格；独占模式下只回主人自己的
- 推送：`ISR.SyncMarkChangeToViewers`（固定 / 清除 / 被别的东西占格解除）按可见性分流 —— 共享容器广播给所有装了这个模组的玩家，独占容器与随身容器只推给可用的人
- `ISR.GetMarkOwnerPlayer`：独占模式取容器上记的 owner，共享模式取当前打开这只容器的玩家（没人打开返回 nil，容器钩子此时只做解标记、不做路由）
- 存档兼容：0.1.7 及更早的数据带 `owner` / 每格 `owner`，读档时忽略每格 owner，容器 owner 只保留下来备用
- 回归测试：新增 `tests/test_shared_container.lua`（共享判定、跨玩家可见、跨玩家路由、独占模式的可见性与路由、两种模式来回切换）；`test_slotmarks.lua` 补独占模式的服务端拦截与「第一个人成为 owner」；`test_pin_marks.lua` 改为断言「确认前不画框」（这条就是防闪的回归）；全量 35 个测试文件通过

**修复二：借料合成时材料行不显示可借数量**

- 现象：开着「合成借料」时，配方明明能点（格子是亮的），但悬停/详情里那行材料仍显示 `1/2` 红字，玩家以为材料不够，也容易怀疑模组出错
- 根因：`widgets/redux/craftingmenu_ingredients.lua` 只按 `inventory:Has(type, amount, true)` 的返回值画「有/需」。借料的材料在**关着的**箱子里，客户端 inventory 数不到 —— 之前只修了「配方能不能点」，没修「材料显示几个」
- 修法：包 `CraftingMenuIngredients:SetRecipe`，执行期间把 `owner.replica.inventory.Has` 换成「原值 + 服务端同步的可借数量」（`ISR.WithSupplyAwareInventory`），借料够了就显示白色、数字也变成真实可用量（如 `4/4`）。结束后无论成败都还原，不覆盖别的模组对 `Has` 的包装
- 覆盖面：配方详情面板、固定栏悬停、材料图标里的子配方弹窗都构造 `CraftingMenuIngredients`，一处覆盖三处
- 沙箱里 `pcall` 为 nil，用 `ISR.Runtime.pcall`；取不到就不包装、直接调原函数，宁可少一层保护也不崩界面
- 回归测试：`test_crafting.lua` 新增四组断言（借料补足后显示够、不够时显示真实可用量、已够的不动、报错时还原 `Has`）

## 0.1.7 — 2026-11-03

**新增：合成借料**

- 合成时自动借用「已固定且在作用距离内」的世界容器里的材料：切斯特、基地箱子里固定的木头做木板，不用打开容器、不用取出
- 只认固定给该材料的格子（标记 prefab 与材料一致），空标记格不参与
- 与原版规则对齐：随身容器（背包、背包里的桶）和玩家**当前打开**的容器本来就能当材料，这些照走原版路径，不重复扣料；`excludefromcrafting` / `readonlycontainer` 容器、带 `nocrafting` 标签的物品排除
- 服务端实现三个 hook（`scripts/isr_crafting.lua`）：`Builder:HasIngredients`（合成按钮判定）、`Builder:GetIngredients`（缺口记到容器实体上）、`Builder:RemoveIngredients`（容器条目自消费：部分扣减走 `stackable:Get`，整堆/单件走 `Container:RemoveItem` 清槽位）。`RemoveIngredients` 的 materials 是**两层结构** `{[材料类型] = {[实体] = 数量}}`，不是一层
- 配置 `craft_from_container`：**测试版，默认关闭**（这一项改动合成判定，可能和别的合成类模组冲突，让玩家自己开）；作用距离复用 `container_range`。新增 `craft_ping`（合成提示音：original / borrow 默认 / silent）
- 客户端也亮：配方格子能不能点是客户端 `builder_replica:HasIngredients` 判的，它只数物品栏 + **当前打开**的容器（`inventory_classified` 的 `GetOpenContainers`），关着的容器内容不同步到客户端。所以服务端每 0.5 秒把「本玩家可借的固定格数量」按 prefab 汇总成串（`log:6;twigs:2`），只在有变化时用 RPC `sync_craft_supply` 推给该玩家，口径与 `GetCraftingSupply` 完全一致（排除随身容器、玩家打开的容器、`excludefromcrafting`、超距离），避免客户端亮着而服务端拒绝。客户端判负后用这份数字补足缺口再判一次，收到新数据即 `PushEvent("refreshcrafting")`，菜单开着也实时变色；角色/技术材料仍按原版
- 房主/本地服务器实体上有真 `builder` 组件，客户端侧直接放行给服务端 hook，不做二次判定
- 容器材料（背包、袋子）被整件消耗前先 `DropEverything`，同原版 `RemoveIngredients` 的做法，否则容器里的东西随实体一起消失
- 容器里的预留格和物品栏一致：被别的东西占进去（手动拖入、换位、Shift 转移、自动放入）就自动解除预留，不留死格。之前容器钩子在「没有在线主人」时整段早退，基地箱子和没带眼骨的切斯特根本走不到解标记那一步
- 物品进容器时优先避开预留格：先找同类未满堆、再找未预留空格；非预留位全满才回落原版（原版会用上预留格），不会因为避开而拒收
- 合成菜单的 `Craft supply short` 调试日志改成每种材料每次进游戏只记一次（一次菜单重算会逐条刷出几千行）
- 客户端判定加快速通道：配方里没有任何一种材料在同步表里时直接判负，不再逐个调 `inventory:Has`。菜单一次重算几百个配方，要算的只剩「含固定格材料」的那几个
- 借料点亮配方时静音 `dontstarve/HUD/recipe_ready`：原版在「某个分类的可合成数量比上次多」时就播这一声，借料让「拿进一件物品就凑够配方」变成常态，响得莫名其妙。只在借料刚点亮的 0.35s 窗口内掐掉，纯靠物品栏凑齐的仍照原版响
- 模组信息全中文：`modinfo` 的说明、设置项标签、悬停说明不再中英并列；新增置顶的「语言」设置项（中文 / English，默认中文），只切换游戏内提示文字（悬停提示、手势文案），设置项文案受引擎限制只能是单一语言
- 设置界面按「常规设置 / 外观配置 / 容器与合成 / 高级」分组（原版 `is_header` 玩法），`容器作用距离` 移到「拾取后放回容器」正下方；所有悬停说明压到两行内并手动断行 —— 说明区只有 585×50，长句会被截断；每项另外补了「这个值是什么意思」的一行值说明
- 回归测试：新增 `tests/test_crafting.lua`（供应收集、缺口补足、部分扣减、整堆清槽、开关回落、供应量序列化、只推变化、客户端解析、客户端缺口判定、房主放行、容器材料倒空）；全量 34 个测试文件通过

## 0.1.6 — 2026-11-03

**修复：装了本模组之后，装备栏模组新增的护符栏 / 背包栏整栏消失**

- 根因：四五六格装备栏（`3173431824`）、Extra Equip Slots（`375850593`）加装备槽的做法是替换**类方法** `inventorybar.Rebuild` / `Refresh`；本模组旧版在 widget 构造期包 `self.Rebuild`（实例字段），把当时的类方法引用冻住，后加载的模组换掉的类方法被绕过，`AddEquipSlot` 不执行
- 修法：HUD 钩子改到类上，在模组加载期挂一次（`scripts/isr_uihooks.lua`），后加载的模组可正常链在外部
- 现象澄清：护符栏消失时装备没有丢，仍在 `equipslots[back|neck]`，只是 HUD 没画那个槽
- 回归测试：新增 `tests/test_inventorybar_hook.lua`；全量 32 个测试文件通过

同版本一并带上原 0.1.52（未上传工坊）的全部改动：

- 找「第一个可用堆叠格」从 `pairs` 改用数字索引，服务端与客户端挑格结果一致
- 同一次 `GiveItem` 内复用标记查询结果，减少重复枚举容器
- 删除死参数 `preferred_container`；`Traceback` 提到模块级；快照请求超时提为常量
- 边框尺寸加缓存，`invslot.OnUpdate` 不再每帧实测尺寸
- `containerwidget` 补 `Kill` 清理，避免失效 widget 滞留
- 存档路径解析的正则放宽，能识别更多容器槽名

## 0.1.51

- 固定手势拆成两个配置项：修饰键（Shift / Ctrl / Alt / 无）+ 动作键（中键 / 右键 / 键盘键）。旧值 `SHIFT_MIDDLE` 自动归一化，老存档不失效

## 0.1.5

- 存档数据不再写 `add_component_if_missing`。旧写法会让引擎在缺组件时强制补建，玩家一关模组就 `require` 失败、存档永久进不去
- 卸载变安全：直接关模组或删目录即可，残留标记数据无人读取
- ≤0.1.41 存过的档需先装 0.1.5 进一次游戏并保存，之后才能安全关闭模组

## 0.1.3

- Shift 快速转移不再回弹：物品栏没有合法落点时直接进背包，不再先闪进别人的预留格
- 落点顺序修正：同类未满堆叠优先于原版给的合法格，能堆叠时不再占新格
- 只能放物品栏的物品（以太余烬、沃拓克斯灵魂）绕过预留，不再掉地上捡不起来
- 客户端预测不占别人的预留格，消除「短暂进格又弹回」
- 预留跟随容器存档，读档与跨 shard 自动恢复

## 0.1.2

- 作者署名修正（`author = "acceleacte"`）。工坊不接受同版本覆盖，因此升版本上传

## 0.1.0 – 0.1.1

- 首版发布：把储物格固定给指定物品，拾取 / 制作 / 卸装备时自动回到该格；背包、随身容器、切斯特 / 哈奇等跟随容器均支持
