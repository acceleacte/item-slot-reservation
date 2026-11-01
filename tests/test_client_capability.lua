local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

-- 本模组 all_clients_require_mod = false，没装的玩家不该收到任何标记同步
local server_handlers = {}
AddModRPCHandler = function(_, name, fn) server_handlers[name] = fn end
AddClientModRPCHandler = function() end
AddComponentPostInit = function() end
AddPlayerPostInit = function() end

local sent = 0
SendModRPCToClient = function() sent = sent + 1 end
GetClientModRPC = function(namespace, name) return { namespace = namespace, name = name } end

ISR =
{
    RPC_NAMESPACE = "test_namespace",
    RPC_SET_MARK = "set",
    RPC_SYNC_MARK = "sync",
    RPC_SYNC_BEGIN = "begin",
    RPC_SYNC_END = "end",
    RPC_REQUEST_SYNC = "request",
    GetServerMarks = function() return {} end,
    ToNumber = tonumber,
    Log = function() end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_persistence.lua")

local player = { GUID = 1, userid = "KU_capable" }
local guest = { GUID = 2, userid = "KU_guest" }

assert_equal(ISR.IsClientCapable(player), false, "a fresh player is not capable yet")
assert_equal(sent, 0, "no RPC is sent at load time")

ISR.SyncAllMarksToClient(player)
assert_equal(sent, 0, "sync is skipped while the client is unproven")

ISR.SyncMarkToClient(guest, guest.GUID, 3, "cutgrass")
assert_equal(sent, 0, "players without the mod never receive mark sync")

ISR.MarkClientCapable(player)
assert_equal(ISR.IsClientCapable(player), true, "marking the player makes it capable")
assert_equal(ISR.IsClientCapable(guest), false, "other players stay uncapable")

ISR.SyncAllMarksToClient(player)
assert_equal(sent, 2, "begin and end are sent once the client is capable")

sent = 0
ISR.SyncMarkToClient(player, player.GUID, 3, "cutgrass")
assert_equal(sent, 1, "a single mark reaches a capable client")

-- request_marks_sync 是客户端证明自己装了模组的入口
sent = 0
assert(server_handlers.request ~= nil, "request_marks_sync handler was not registered")
server_handlers.request(guest)
assert_equal(ISR.IsClientCapable(guest), true, "requesting a snapshot registers the client")
assert_equal(sent, 2, "the requesting client receives the snapshot")
