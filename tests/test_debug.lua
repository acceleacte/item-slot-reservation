local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

GLOBAL = {}
Prefabs = { grass = true, twigs = true, log = true }
GLOBAL.Prefabs = Prefabs

dofile(ISR_TEST_ROOT.."/scripts/isr_env.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_debug.lua")

local ok, failures = ISR.RunSelfTests()
assert_equal(ok, true, "in-game self tests pass")
assert_equal(#failures, 0, "in-game self tests report no failures")

-- 控制台入口：DebugSetPrefabMark 必须把 prefab 名原样交给客户端缓存
local applied = nil
ISR.SetClientSlotMark = function(slot, prefab)
    applied = { num = slot.num, prefab = prefab }
    return true
end
ISR.ApplyRuntimeIconToSlot = function() return true end
ISR.QueueRefreshVisibleSlotIcons = function() end
ISR.GetLocalPlayer = function()
    return
    {
        HUD =
        {
            controls =
            {
                inv =
                {
                    inv = { { num = 1 }, { num = 2 }, { num = 3 } },
                    backpackinv = { { num = 1 } },
                },
            },
        },
    }
end

assert_equal(ISR.DebugSetPrefabMark(2, "Twigs.TEX"), true, "debug mark applies")
assert_equal(applied.num, 2, "debug mark targets the requested slot")
assert_equal(applied.prefab, "twigs", "debug mark normalizes the prefab key")

assert_equal(ISR.DebugSetPrefabMark(9, "grass"), false, "missing slot is reported")
assert_equal(ISR.DebugSetPrefabMark(1, ""), false, "empty prefab is rejected")

applied = nil
assert_equal(ISR.DebugClearSlotMark(3), true, "debug clear works on a valid slot")
assert_equal(applied.num, 3, "debug clear targets the requested slot")
assert_equal(applied.prefab, nil, "debug clear writes no prefab")
