ISR = ISR or {}

-- 合成借料（0.1.7）：合成时自动补足材料缺口，来源是「已固定且在作用距离内」的世界容器
-- （切斯特、基地箱子等）原版只扫玩家物品栏 + 当前打开的容器（inventory.opencontainers），
-- 关着的容器不参与；本文件把缺口部分从容器内固定格里补上
--
-- 三个 hook 点（scripts/components/builder.lua）：
--   HasIngredients     合成入口判定，原版查不到关着的容器，补上容器供应后再判一次
--   GetIngredients     产出 materials（实体 → 数量），把缺口记到容器内实体上
--   RemoveIngredients  原版 RemoveItem 只认物品栏/打开的容器，容器条目在这里自己消费
--
-- 消费安全性：堆叠的部分扣减走 stackable:Get（对实体本身操作，不看容器开闭）；
-- 整堆/单件走 Container:RemoveItem 清槽位表后 Remove两种都不留幽灵引用

local GetValidRecipe = ISR.GetGlobalValue("GetValidRecipe", nil)
local RoundBiasedUp = ISR.GetGlobalValue("RoundBiasedUp", nil)
-- mod 沙箱里 pcall 是 nil（AGENTS §4.3），统一从 Runtime 取
local protected_call = ISR.Runtime ~= nil and ISR.Runtime.pcall or nil

local function NormalizePrefab(prefab)
    if ISR.NormalizePrefabKey ~= nil then
        return ISR.NormalizePrefabKey(prefab)
    end

    return prefab ~= nil and string.lower(tostring(prefab)) or nil
end

local function IsServer()
    local world = ISR.GetGlobalValue("TheWorld", nil)
    return world == nil or world.ismastersim == true
end

local function CanCraftWithItem(item)
    return item ~= nil
        and item:IsValid()
        and item.components ~= nil
        and item.components.inventoryitem ~= nil
        and (item.HasTag == nil or not item:HasTag("nocrafting"))
end

-- 容器内当前堆叠数量快照只在同一次合成的调用栈里用，中途没有别的游戏逻辑插进来
local function GetStackCount(item)
    local stackable = item ~= nil and item.components ~= nil and item.components.stackable or nil
    return stackable ~= nil and stackable:StackSize() or 1
end

-- 收集本玩家「可借料」的容器内固定格供应：prefab -> { {item=实体, count=堆叠数}, ... }
-- 排除三类，避免与原版统计重叠导致重复扣料：
--   1. 玩家自己的物品栏标记（原版本就算）
--   2. 随身容器（背包、背包里的桶；背包是原版 overflow，本就参与合成）
--   3. 此刻被该玩家打开的容器（原版 opencontainers 已算）
-- 另排除 excludefromcrafting / readonlycontainer，与原版对打开容器的排除规则一致
function ISR.GetCraftingSupply(player)
    local supply = {}
    if player == nil or player.components == nil or player.components.inventory == nil then
        return supply
    end

    local limit = ISR.GetContainerRangeLimit()
    for _, mark in pairs(ISR.GetServerMarks(player)) do
        if type(mark) == "table" and supply[mark.prefab] == nil then
            supply[mark.prefab] = {}
        end

        local container = ISR.GetContainerInstFromGUID(mark.container_guid)
        if container ~= nil
            and container ~= player
            and container.components ~= nil
            and container.components.container ~= nil
            and not ISR.IsStorageCarriedByPlayer(player, container)
        then
            local comp = container.components.container
            local openable_ok = not comp.excludefromcrafting and not comp.readonlycontainer
                and not (comp.IsOpenedBy ~= nil and comp:IsOpenedBy(player))
            if openable_ok and ISR.IsStorageWithinRange(player, container, limit) then
                local item = comp.GetItemInSlot ~= nil and comp:GetItemInSlot(mark.slot) or nil
                if item ~= nil
                    and CanCraftWithItem(item)
                    and NormalizePrefab(item.prefab) == mark.prefab
                then
                    table.insert(supply[mark.prefab], { item = item, count = GetStackCount(item) })
                end
            end
        end
    end

    return supply
end

local function SumMaterials(ents)
    local total = 0
    if ents ~= nil then
        for _, count in pairs(ents) do
            total = total + count
        end
    end

    return total
end

-- 供应列表是 { {item=实体, count=堆叠数}, ... }，和 materials（实体 → 数量）结构不同
local function SumSupply(list)
    local total = 0
    for i = 1, #(list or {}) do
        total = total + list[i].count
    end

    return total
end

-- 把容器供应填进 materials（实体 → 数量）只补原版没找够的缺口；
-- 同一实体已在 materials 里的跳过（原版统计过的和供应集合不相交，这里只作保险）
function ISR.FillIngredientsFromSupply(player, builder, recipe, materials)
    if recipe == nil or recipe.ingredients == nil or materials == nil then
        return
    end

    local supply = nil
    for _, v in ipairs(recipe.ingredients) do
        if v.amount > 0 then
            local amt = math.max(1, RoundBiasedUp(v.amount * builder.ingredientmod))
            local need = amt - SumMaterials(materials[v.type])
            if need > 0 then
                if supply == nil then
                    supply = ISR.GetCraftingSupply(player)
                end

                local list = supply[v.type]
                for i = 1, #(list or {}) do
                    if need <= 0 then
                        break
                    end

                    local entry = list[i]
                    local item = entry.item
                    if CanCraftWithItem(item) and (materials[v.type] == nil or materials[v.type][item] == nil) then
                        local take = math.min(need, math.min(entry.count, GetStackCount(item)))
                        if take > 0 then
                            materials[v.type] = materials[v.type] or {}
                            materials[v.type][item] = take
                            need = need - take
                        end
                    end
                end
            end
        end
    end
end

-- 只判够不够，不构造 materials供应集合与原版统计（物品栏 + 打开的容器）不相交，
-- 所以「缺口 ≤ 供应总量」是必要且充分的判定
function ISR.HasIngredientsWithSupply(player, builder, recipe)
    if recipe == nil or recipe.ingredients == nil then
        return false
    end

    local inventory = player.components ~= nil and player.components.inventory or nil
    if inventory == nil then
        return false
    end

    local supply = nil
    for _, v in ipairs(recipe.ingredients) do
        if v.amount > 0 then
            local amt = math.max(1, RoundBiasedUp(v.amount * builder.ingredientmod))
            local found = 0
            if inventory.GetCraftingIngredient ~= nil then
                found = SumMaterials(inventory:GetCraftingIngredient(v.type, amt))
            end
            if found < amt then
                if supply == nil then
                    supply = ISR.GetCraftingSupply(player)
                end
                if SumSupply(supply[v.type]) < amt - found then
                    return false
                end
            end
        end
    end

    return true
end

-- 消费 materials 里住在容器里的条目，结构照原版两层：{[材料类型] = {[实体] = 数量}}
-- 物品栏条目留给原版（保持角色消耗、事件等原逻辑）
-- 部分扣减：stackable:Get 拆出一个新实体并扣原堆数量，原堆留在容器里；
-- 整堆/单件：Container:RemoveItem 清槽位表后再 Remove，不留幽灵引用
function ISR.ConsumeIngredientsFromContainers(player, ingredients)
    if ingredients == nil then
        return
    end

    local consumed = {}
    for type_key, ents in pairs(ingredients) do
        if type(ents) == "table" then
            for item, count in pairs(ents) do
                local inventoryitem = item.components ~= nil and item.components.inventoryitem or nil
                local owner = inventoryitem ~= nil and inventoryitem.GetOwner ~= nil and inventoryitem:GetOwner() or nil
                if owner ~= nil and owner ~= player and owner.components ~= nil then
                    local holder = owner.components.container ~= nil and owner.components.container
                        or owner.components.inventory or nil
                    if holder ~= nil and holder.RemoveItem ~= nil then
                        consumed[#consumed + 1] =
                            { item = item, count = count, holder = holder, ents = ents, type_key = type_key }
                        ents[item] = nil
                    end
                end
            end
        end
    end

    for _, entry in ipairs(consumed) do
        local item = entry.item
        for _ = 1, entry.count do
            if not item:IsValid() then
                break
            end

            local stackable = item.components.stackable
            if stackable ~= nil and stackable:IsStack() then
                local dec = entry.holder:RemoveItem(item, false, nil, true)
                if dec ~= nil then
                    dec:Remove()
                end
            else
                -- 材料本身是容器（背包、袋子之类）：原版 RemoveIngredients 会先 DropEverything，
                -- 这里整件消耗前照做，否则容器里的东西跟着实体一起消失
                local carried = item.components.container
                if carried ~= nil and carried.DropEverything ~= nil then
                    carried:DropEverything(player ~= nil and player.GetPosition ~= nil and player:GetPosition() or nil)
                end

                local removed = entry.holder:RemoveItem(item, true, nil, true)
                if removed ~= nil then
                    removed:Remove()
                end
                -- 槽位已清空，多算的数量没有实体可扣
                break
            end
        end

        -- 空掉的类型表顺手摘掉，原版循环看到的就是干净的 materials
        -- mod 沙箱里 next 为 nil（AGENTS §4.3），空表判定用 pairs 走一遍
        local is_empty = true
        for _ in pairs(entry.ents) do
            is_empty = false
            break
        end
        if is_empty then
            ingredients[entry.type_key] = nil
        end

        ISR.Log(
            "Craft consumed from container",
            tostring(item.prefab),
            "container", tostring(entry.holder.inst ~= nil and entry.holder.inst.GUID or nil)
        )
    end
end

function ISR.IsCraftBorrowEnabled()
    return ISR.Config ~= nil and ISR.Config.craft_from_container == true
end

AddComponentPostInit("builder", function(self)
    if not IsServer() then
        return
    end

    local old_HasIngredients = self.HasIngredients
    function self:HasIngredients(recipe, ...)
        local result = old_HasIngredients(self, recipe, ...)
        if result or not ISR.IsCraftBorrowEnabled() or self.freebuildmode then
            return result
        end

        if GetValidRecipe == nil or RoundBiasedUp == nil then
            return result
        end

        if type(recipe) == "string" then
            recipe = GetValidRecipe(recipe)
        end

        return ISR.HasIngredientsWithSupply(self.inst, self, recipe)
    end

    local old_GetIngredients = self.GetIngredients
    function self:GetIngredients(recname, ...)
        local materials, discounted = old_GetIngredients(self, recname, ...)
        if ISR.IsCraftBorrowEnabled() and not self.freebuildmode and materials ~= nil and GetValidRecipe ~= nil then
            ISR.FillIngredientsFromSupply(self.inst, self, GetValidRecipe(recname), materials)
        end

        return materials, discounted
    end

    local old_RemoveIngredients = self.RemoveIngredients
    function self:RemoveIngredients(ingredients, recname, discounted)
        if ISR.IsCraftBorrowEnabled() and not self.freebuildmode then
            ISR.ConsumeIngredientsFromContainers(self.inst, ingredients)
        end

        return old_RemoveIngredients(self, ingredients, recname, discounted)
    end
end)

-- ---------------------------------------------------------------------------
-- 供应量同步（客户端配方可用性用）
--
-- 配方格子是灰是亮由客户端 builder_replica:HasIngredients 决定，它只数物品栏
-- 和「当前打开的容器」（inventory_classified 的 GetOpenContainers）关着的切斯特、
-- 基地箱子里有多少东西客户端根本不知道，光靠服务端 hook 改不了格子状态
-- 所以服务端把「本玩家可借的固定格数量」按 prefab 汇总成串推过去，客户端判定时
-- 加上这份数字，就能和服务端 HasIngredients 的结论保持一致
--
-- 口径必须和服务端 GetCraftingSupply 完全一致（排除随身容器 / 玩家打开的容器 /
-- excludefromcrafting / 超距离），否则客户端亮着、服务端拒绝
-- ---------------------------------------------------------------------------
local function SerializeSupply(counts)
    local parts = {}
    for prefab, total in pairs(counts) do
        parts[#parts + 1] = tostring(prefab)..":"..tostring(total)
    end

    table.sort(parts)
    return table.concat(parts, ";")
end

function ISR.ComputeCraftSupply(player)
    local counts = {}
    local supply = ISR.GetCraftingSupply(player)
    for prefab, list in pairs(supply) do
        local total = SumSupply(list)
        if total > 0 then
            counts[prefab] = total
        end
    end

    return counts
end

function ISR.PushCraftingSupply(player)
    if player == nil or player.userid == nil or player.userid == "" then
        return
    end

    if ISR.MarkClientCapable ~= nil and ISR.IsClientCapable ~= nil and not ISR.IsClientCapable(player) then
        return
    end

    local payload = ISR.IsCraftBorrowEnabled() and SerializeSupply(ISR.ComputeCraftSupply(player)) or ""
    if player._isr_craft_supply_payload == payload then
        return
    end

    player._isr_craft_supply_payload = payload
    SendModRPCToClient(GetClientModRPC(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_SUPPLY), player.userid, payload)
    ISR.Log("Craft supply synced", tostring(payload))
end

-- 0.5s 一轮：标记变化、容器内容变化、走进走出作用距离、开关容器，都会在这一拍里
-- 落到 payload 差异上没变化不发 RPC
local CRAFT_SUPPLY_SYNC_PERIOD = 0.5

AddPlayerPostInit(function(inst)
    if not IsServer() or inst.DoPeriodicTask == nil then
        return
    end

    inst:DoPeriodicTask(CRAFT_SUPPLY_SYNC_PERIOD, function(player)
        if player ~= nil and player:IsValid() then
            ISR.PushCraftingSupply(player)
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- 客户端：配方可用性判定
-- 原版 builder_replica:HasIngredients 只认物品栏 + 打开的容器；这里在它判负后，
-- 用服务端推来的固定格数量补足缺口，再判一次
-- ---------------------------------------------------------------------------
function ISR.GetSyncedCraftSupply(prefab)
    local supply = ISR._craft_supply
    return supply ~= nil and prefab ~= nil and supply[prefab] or 0
end

-- 返回 true 表示「缺口全部由固定格补上，且角色/技术材料齐」
-- 合成菜单一次重算会把每个配方缺的每种材料都过一遍，逐条打日志能刷出几千行
-- 同一种材料每次进游戏只记一次，够定位问题，也不把日志淹掉
local supply_short_logged = {}

-- 同步表里一条材料都没有的配方，结论必然和原版一样（都是不够），
-- 不用调任何 inventory:Has菜单一次重算是几百个配方，绝大多数属于这一类
local function RecipeUsesSupply(recipe)
    local supply = ISR._craft_supply
    if supply == nil then
        return false
    end

    for _, v in ipairs(recipe.ingredients) do
        if v.amount > 0 and (supply[v.type] or 0) > 0 then
            return true
        end
    end

    return false
end

-- 借料点亮配方的时刻pinbar 的「新配方」提示音（dontstarve/HUD/recipe_ready）只在
-- 借料刚动过手的那一瞬间静音：拿进一件物品就凑够配方是个噪音源，但「真的捡够了材料」
-- 属于原版正当提示，不能一起吞掉
local RECIPE_READY_MUTE_WINDOW = 0.35
local supply_flipped_at = nil

local function Now()
    local get_time = ISR.GetGlobalValue("GetTime", nil)
    return get_time ~= nil and get_time() or 0
end

function ISR.MarkSupplyFlipped(now)
    supply_flipped_at = now or Now()
end

function ISR.ShouldMuteRecipeReady(now)
    local mode = ISR.Config ~= nil and ISR.Config.craft_ping or "borrow"
    if mode == "silent" then
        return true
    elseif mode == "original" then
        return false
    end

    if supply_flipped_at == nil then
        return false
    end

    return (now or Now()) - supply_flipped_at <= RECIPE_READY_MUTE_WINDOW
end

function ISR.HasIngredientsWithClientSupply(player, builder, recipe)
    if player == nil or builder == nil or recipe == nil or recipe.ingredients == nil then
        return false
    end

    if not RecipeUsesSupply(recipe) then
        return false
    end

    local inventory = player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil then
        return false
    end

    if recipe.getlimitedrecipecount ~= nil and recipe:getlimitedrecipecount(player) <= 0 then
        return false
    end

    local mod = builder.IngredientMod ~= nil and builder:IngredientMod() or 1
    for _, v in ipairs(recipe.ingredients) do
        if v.amount > 0 then
            local amt = math.max(1, RoundBiasedUp(v.amount * mod))
            local has, count = inventory:Has(v.type, amt, true)
            if not has and (count or 0) + ISR.GetSyncedCraftSupply(v.type) < amt then
                if not supply_short_logged[v.type] then
                    supply_short_logged[v.type] = true
                    ISR.Log(
                        "Craft supply short",
                        tostring(v.type),
                        "have", tostring(count or 0),
                        "supply", tostring(ISR.GetSyncedCraftSupply(v.type)),
                        "need", tostring(amt)
                    )
                end
                return false
            end
        end
    end

    for _, v in ipairs(recipe.character_ingredients or {}) do
        if builder.HasCharacterIngredient ~= nil and not builder:HasCharacterIngredient(v) then
            return false
        end
    end

    for _, v in ipairs(recipe.tech_ingredients or {}) do
        if builder.HasTechIngredient ~= nil and not builder:HasTechIngredient(v) then
            return false
        end
    end

    -- 到这儿说明这个配方是靠借料才变可合成的：记时间戳，让 pinbar 那一声静音
    ISR.MarkSupplyFlipped()
    return true
end

-- replica 组件不走 EntityScript:AddComponent（entityreplica.lua 里直接 cmp(self) 构造），
-- AddComponentPostInit 对它不触发，只能用 AddClassPostConstruct 包构造器
AddClassPostConstruct("components/builder_replica", function(self)
    local old_HasIngredients = self.HasIngredients
    function self:HasIngredients(recipe)
        local result = old_HasIngredients(self, recipe)
        if result or not ISR.IsCraftBorrowEnabled() then
            return result
        end

        -- 房主/本地服务器：实体上有真 builder 组件，服务端 hook 已经算过，别重复判
        local inst = self.inst
        if inst == nil or (inst.components ~= nil and inst.components.builder ~= nil) then
            return result
        end

        if self.classified == nil or GetValidRecipe == nil or RoundBiasedUp == nil then
            return result
        end

        if type(recipe) == "string" then
            recipe = GetValidRecipe(recipe)
        end

        return ISR.HasIngredientsWithClientSupply(inst, self, recipe)
    end
end)

AddClientModRPCHandler(ISR.RPC_NAMESPACE, ISR.RPC_SYNC_SUPPLY, function(payload)
    local supply = {}
    if type(payload) == "string" and payload ~= "" then
        for prefab, count in string.gmatch(payload, "([^:;]+):(%d+)") do
            supply[prefab] = ISR.ToNumber(count) or 0
        end
    end

    ISR._craft_supply = supply
    ISR.Log("Craft supply received", tostring(payload))

    -- 菜单开着的时候也要重算格子状态，不然得关掉再开才变
    local player = ISR.GetLocalPlayer()
    if player ~= nil and player.PushEvent ~= nil then
        player:PushEvent("refreshcrafting")
    end
end)

-- ---------------------------------------------------------------------------
-- 配方里的材料行（0.1.8）
--
-- 原版 widgets/redux/craftingmenu_ingredients.lua 用
--     local has, num_found = inventory:Has(type, amount, true)
-- 取「身上有几个」，再画成 `num_found/amount`，不够就染红（ingredientui.lua）
-- 借料的材料在**关着的**箱子里，客户端 inventory 数不到 ⇒ 明明能合成，界面却显示
-- 「1/2」红字，玩家以为材料不够这里在原版 SetRecipe 执行期间给 inventory:Has
-- 打一层临时补丁，把服务端推来的可借数量加进 num_found，显示的就是真正可用的量
--
-- 只包这一个方法，不改原版逻辑；退出时无论成败都还原，别的模组对 Has 的包装不受影响
-- ---------------------------------------------------------------------------
local function SupplyForPrefab(prefab)
    if prefab == nil or ISR.GetSyncedCraftSupply == nil then
        return 0
    end

    local key = ISR.NormalizePrefabKey ~= nil and ISR.NormalizePrefabKey(prefab) or prefab
    return key ~= nil and ISR.GetSyncedCraftSupply(key) or 0
end

function ISR.WithSupplyAwareInventory(inventory, fn, ...)
    if inventory == nil or inventory.Has == nil or fn == nil then
        return fn ~= nil and fn(...) or nil
    end

    -- 沙箱里拿不到 pcall 时退化成直接调用：宁可少一层保护，也不能把界面搞崩
    if protected_call == nil then
        return fn(...)
    end

    -- 嵌套调用（材料图标的子配方弹窗）不重复叠加供应量：外层已经加过了
    if inventory._isr_supply_patch then
        return fn(...)
    end

    local base_Has = inventory.Has
    inventory._isr_supply_patch = true
    inventory.Has = function(inv, prefab, amount, checkall, ...)
        local has, count = base_Has(inv, prefab, amount, checkall, ...)
        if has then
            return has, count
        end

        local supply = SupplyForPrefab(prefab)
        if supply <= 0 then
            return has, count
        end

        local total = (count or 0) + supply
        return total >= (amount or 1), total
    end

    local ok, a, b, c = protected_call(fn, ...)
    inventory.Has = base_Has
    inventory._isr_supply_patch = nil
    if not ok then
        error(a, 0)
    end

    return a, b, c
end

AddClassPostConstruct("widgets/redux/craftingmenu_ingredients", function(self)
    local old_SetRecipe = self.SetRecipe
    if old_SetRecipe == nil then
        return
    end

    -- 详情面板、固定栏悬停、材料图标里的子配方弹窗都构造这个类，一处覆盖三处
    function self:SetRecipe(recipe, ...)
        if not ISR.IsCraftBorrowEnabled() or ISR._craft_supply == nil then
            return old_SetRecipe(self, recipe, ...)
        end

        local owner = self.owner
        local inventory = owner ~= nil
            and owner.replica ~= nil
            and owner.replica.inventory
            or nil
        if inventory == nil then
            return old_SetRecipe(self, recipe, ...)
        end

        return ISR.WithSupplyAwareInventory(inventory, old_SetRecipe, self, recipe, ...)
    end
end)
