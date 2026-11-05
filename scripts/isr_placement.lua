ISR = ISR or {}

local transfer_context_stack = {}
local runtime = ISR.Runtime or {}
local debug_lib = runtime.debug or debug
local raise_error = runtime.error or error
local select_values = runtime.select or select
local unpack_values = runtime.unpack or unpack or table.unpack
local protected_call = runtime.xpcall or xpcall

-- 提到模块级：每次 Shift 转移不必再新建一个闭包
local function Traceback(message)
    return debug_lib ~= nil and debug_lib.traceback ~= nil and debug_lib.traceback(message, 2) or message
end

local function Pack(...)
    return { n = select_values("#", ...), ... }
end

function ISR.PushTransferContext(context)
    context = context or {}
    table.insert(transfer_context_stack, context)
    return context
end

function ISR.PopTransferContext()
    return table.remove(transfer_context_stack)
end

function ISR.GetTransferContext()
    return transfer_context_stack[#transfer_context_stack]
end

function ISR.WithTransferContext(context, fn, ...)
    local args = Pack(...)
    local function Invoke()
        return fn(unpack_values(args, 1, args.n))
    end

    ISR.PushTransferContext(context)
    local results = Pack(protected_call(Invoke, Traceback))
    ISR.PopTransferContext()
    if not results[1] then
        raise_error(results[2], 0)
    end
    return unpack_values(results, 2, results.n)
end

function ISR.MakePlacementContext(data)
    data = data or {}
    local transfer = ISR.GetTransferContext()
    data.owner = data.owner or (data.inventory ~= nil and data.inventory.inst or nil)
    data.source_guid = data.source_guid or (transfer ~= nil and transfer.source_guid or nil)
    data.target_guid = data.target_guid or (transfer ~= nil and transfer.target_guid or nil)
    data.reason = data.reason
        or (transfer ~= nil and transfer.reason or nil)
        or (data.target_kind == "container" and "container_give" or "auto_place")
    return data
end

function ISR.HasAnyServerMarks(owner)
    if owner ~= nil then
        for _ in pairs(ISR.GetServerMarks(owner)) do
            return true
        end
    end
    return false
end

function ISR.HasServerMarksForItem(owner, item)
    return owner ~= nil
        and item ~= nil
        and item.prefab ~= nil
        and #ISR.GetSortedServerMarksForPrefab(owner, item.prefab) > 0
end

-- 同一次 GiveItem 里，「这个物品有没有预留格」会被问两三遍
-- （ShouldRoutePlacementByMarks → TryPlaceByMarks，容器路径还要再问一次）
-- 每次问都要枚举全部带标记的容器、建表、排序标记只在这条链路之外变化，
-- 所以第一次算完挂在 context 上，后续直接读context 是每次 GiveItem 新建的，
-- 不存在跨帧陈旧的问题
function ISR.GetContextMarks(context)
    if context == nil then
        return nil
    end

    if context.marks == nil
        and context.owner ~= nil
        and context.item ~= nil
        and context.item.prefab ~= nil
    then
        context.marks = ISR.GetSortedServerMarksForPrefab(context.owner, context.item.prefab)
    end

    return context.marks
end

-- 只有「这个物品有预留格」才改写放置路由，其余一律交给原版逻辑
function ISR.ShouldRoutePlacementByMarks(context)
    return context ~= nil
        and context.slot == nil
        and context.owner ~= nil
        and context.item ~= nil
        and context.item.components ~= nil
        and context.item.components.inventoryitem ~= nil
        and context.item:IsValid()
        and #(ISR.GetContextMarks(context) or {}) > 0
end

-- 只能放物品栏的物品（余烬 / 灵魂）不参与预留：它们没有背包这个退路，
-- 拦住只会让物品无处可去
function ISR.ShouldReserveMarkedSlotsForItem(owner, item)
    return owner ~= nil
        and item ~= nil
        and item.components ~= nil
        and item.components.inventoryitem ~= nil
        and not (ISR.IsPocketOnlyItem ~= nil and ISR.IsPocketOnlyItem(item))
        and ISR.HasAnyServerMarks(owner)
end

-- 玩家自己身上的标记（物品栏 / 装备栏）与容器里的标记（切斯特、背包里的桶）分两类
local function IsOwnInventoryMark(owner, mark)
    return owner ~= nil and mark.container_guid == owner.GUID
end

-- 玩家身上的容器（背包、克朗普斯袋子、背包里的桶）：里面的固定格永远参与自动回位，
-- 不受 pickup_to_container 影响开关只决定「世界里的容器」（切斯特、基地箱子）算不算
local function IsCarriedContainerMark(owner, mark)
    return ISR.IsStorageCarriedByPlayer ~= nil
        and ISR.IsStorageCarriedByPlayer(owner, ISR.GetStorageForMark(owner, mark))
end

-- 「拾取后直接放回容器」开着时，容器里的标记优先；关掉时只留玩家身上的容器，
-- 世界里的容器（切斯特、箱子）不参与，物品照常回玩家物品栏的固定格
local function OrderMarksForConfig(owner, marks)
    local wants_container = ISR.Config == nil or ISR.Config.pickup_to_container ~= false
    local container_marks = {}
    local inventory_marks = {}
    for _, mark in ipairs(marks) do
        if IsOwnInventoryMark(owner, mark) then
            table.insert(inventory_marks, mark)
        elseif wants_container or IsCarriedContainerMark(owner, mark) then
            table.insert(container_marks, mark)
        end
    end

    local ordered = {}
    for _, mark in ipairs(container_marks) do
        table.insert(ordered, mark)
    end
    for _, mark in ipairs(inventory_marks) do
        table.insert(ordered, mark)
    end
    return ordered
end

-- 固定格里已经有同种物品的未满堆叠时也要认：草、树枝这类资源采集后应当并进去，
-- 只判「空不空」会把它推回物品栏（容器没打开时尤其明显）
local function CanPlaceIntoMarkedSlot(adapter, storage, item, slot, context)
    if adapter.CanUseSlot ~= nil then
        return adapter:CanUseSlot(storage, item, slot, context)
    end
    return adapter:CanUseEmptySlot(storage, item, slot, context)
end

-- 没中的时候把每个候选为什么被跳过记下来，日志里只出现 no hit 太难查
local function NoteSkip(skipped, mark, reason)
    if skipped == nil then
        return
    end
    skipped[#skipped + 1] = tostring(mark.container_guid).."@"..tostring(mark.slot)..":"..reason
end

function ISR.TryPlaceByMarks(context)
    if not ISR.ShouldRoutePlacementByMarks(context) then
        return false
    end

    local target_guid = context.target_guid
    if context.target_storage ~= nil then
        local target_adapter = ISR.GetStorageAdapter(context.target_storage, context.target_kind)
        target_guid = target_guid or (target_adapter ~= nil and target_adapter:GetGUID(context.target_storage) or nil)
    end

    local skipped = {}
    local range_limit = ISR.GetContainerRangeLimit ~= nil and ISR.GetContainerRangeLimit() or nil
    local marks = ISR.GetContextMarks(context)
        or ISR.GetSortedServerMarksForPrefab(context.owner, context.item.prefab)
    for _, mark in ipairs(OrderMarksForConfig(context.owner, marks)) do
        local matches_target = target_guid == nil or mark.container_guid == target_guid
        if not matches_target then
            NoteSkip(skipped, mark, "target")
        elseif mark.container_guid == context.source_guid then
            NoteSkip(skipped, mark, "source")
        else
            local storage = context.target_storage or ISR.GetStorageForMark(context.owner, mark)
            local adapter = ISR.GetStorageAdapter(storage, context.target_kind)
            if adapter == nil then
                NoteSkip(skipped, mark, "adapter")
            elseif adapter:GetGUID(storage) ~= mark.container_guid then
                NoteSkip(skipped, mark, "guid")
            elseif ISR.IsStorageWithinRange ~= nil
                and not ISR.IsStorageWithinRange(context.owner, storage, range_limit)
            then
                -- 距离太远不送进去，不然满地捡的东西都能直接飞回基地箱子
                NoteSkip(skipped, mark, "range")
            elseif not CanPlaceIntoMarkedSlot(adapter, storage, context.item, mark.slot, context) then
                NoteSkip(skipped, mark, "slot")
            else
                local result, result_slot = adapter:PlaceInSlot(storage, context.item, mark.slot, context)
                if result then
                    ISR.Log("Marked placement hit", tostring(context.item.prefab), "container", tostring(mark.container_guid), "slot", tostring(mark.slot), "reason", tostring(context.reason))
                    -- 物品直接被容器吃了，物品栏不会收到 gotnewitem，拾取音效得自己补
                    if result ~= "inventory"
                        and context.inventory ~= nil
                        and not IsOwnInventoryMark(context.owner, mark)
                        and ISR.PlayPickupSound ~= nil
                    then
                        ISR.PlayPickupSound(context.owner, context.item)
                    end
                    return result, result_slot or mark.slot
                end
                NoteSkip(skipped, mark, "place")
            end
        end
    end

    ISR.Log("Marked placement no hit", tostring(context.item.prefab), "reason", tostring(context.reason), "skipped", #skipped > 0 and table.concat(skipped, ",") or "none")
    return false
end
