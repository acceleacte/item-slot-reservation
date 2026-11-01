ISR = ISR or {}

local transfer_context_stack = {}
local runtime = ISR.Runtime or {}
local debug_lib = runtime.debug or debug
local raise_error = runtime.error or error
local select_values = runtime.select or select
local unpack_values = runtime.unpack or unpack or table.unpack
local protected_call = runtime.xpcall or xpcall

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
    local function Traceback(message)
        return debug_lib ~= nil and debug_lib.traceback ~= nil and debug_lib.traceback(message, 2) or message
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

-- 只有「这个物品有预留格」才改写放置路由，其余一律交给原版逻辑。
function ISR.ShouldRoutePlacementByMarks(context)
    return context ~= nil
        and context.slot == nil
        and context.owner ~= nil
        and context.item ~= nil
        and context.item.components ~= nil
        and context.item.components.inventoryitem ~= nil
        and context.item:IsValid()
        and ISR.HasServerMarksForItem(context.owner, context.item)
end

function ISR.ShouldReserveMarkedSlotsForItem(owner, item)
    return owner ~= nil
        and item ~= nil
        and item.components ~= nil
        and item.components.inventoryitem ~= nil
        and ISR.HasAnyServerMarks(owner)
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

    for _, mark in ipairs(ISR.GetSortedServerMarksForPrefab(context.owner, context.item.prefab)) do
        local matches_target = target_guid == nil or mark.container_guid == target_guid
        if matches_target and mark.container_guid ~= context.source_guid then
            local storage = context.target_storage or ISR.GetStorageForMark(context.owner, mark)
            local adapter = ISR.GetStorageAdapter(storage, context.target_kind)
            if adapter ~= nil and adapter:GetGUID(storage) == mark.container_guid
                and adapter:CanUseEmptySlot(storage, context.item, mark.slot, context)
            then
                local result, result_slot = adapter:PlaceInSlot(storage, context.item, mark.slot, context)
                if result then
                    ISR.Log("Marked placement hit", tostring(context.item.prefab), "container", tostring(mark.container_guid), "slot", tostring(mark.slot), "reason", tostring(context.reason))
                    return result, result_slot or mark.slot
                end
            end
        end
    end

    ISR.Log("Marked placement no hit", tostring(context.item.prefab), "reason", tostring(context.reason))
    return false
end
