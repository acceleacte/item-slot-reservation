-- 刷新类钩子必须挂在 inventorybar 的**类**上，不能只包实例方法。
--
-- 复现的现场：四五六格装备栏（workshop-3173431824）用
--     local base = Inv.Rebuild
--     function Inv:Rebuild() base(self); ... self:AddEquipSlot(...) end
-- 往 HUD 里加护符栏。它 priority 默认 0、名字排在本模组之后，加载比本模组晚。
-- 本模组过去只包实例方法，构造那一刻把类方法引用冻住，四五六格后来换掉的类方法
-- 就被绕过 —— 护符栏根本画不出来。
--
-- 这个测试钉住三件事：
--   1. 加载后 Inv.Rebuild / Inv.Refresh 被替换（钩子在类上）
--   2. 之后加载的模组再包一层类方法时，两条链路都会执行
--   3. 重复加载不会重复包装

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local calls = {}
local Inv =
{
    Rebuild = function() table.insert(calls, "vanilla_rebuild") end,
    Refresh = function() table.insert(calls, "vanilla_refresh") end,
}

GLOBAL =
{
    tonumber = tonumber,
    -- 游戏里 GLOBAL 一定有这些，isr_env 用它们填 ISR.Runtime
    pcall = pcall,
    xpcall = xpcall,
    error = error,
    select = select,
    unpack = table.unpack,
    debug = debug,
    require = function(package)
        assert_equal(package, "widgets/inventorybar", "only the inventory bar class is required")
        return Inv
    end,
}

-- 这些钩子在加载期只登记，不执行
AddClassPostConstruct = function() end
AddPrefabPostInit = function() end

dofile(ISR_TEST_ROOT.."/scripts/isr_env.lua")
dofile(ISR_TEST_ROOT.."/scripts/isr_uihooks.lua")

assert(Inv._isr_class_hooked == true, "the inventory bar class must be marked as hooked")
assert(Inv.Rebuild ~= nil and Inv.Refresh ~= nil, "class methods must survive the hook")

-- 模拟排在后面的装备栏模组：照它们的写法，包住当时的类方法
local base_Rebuild = Inv.Rebuild
function Inv:Rebuild(...)
    base_Rebuild(self, ...)
    table.insert(calls, "equipmod_rebuild")
end

local bar = setmetatable({}, { __index = Inv })

calls = {}
bar:Rebuild()
assert_equal(#calls, 2, "both the vanilla rebuild and the equip-slot mod rebuild must run")
assert_equal(calls[1], "vanilla_rebuild", "the wrapped method runs first")
assert_equal(calls[2], "equipmod_rebuild", "the equip-slot mod's extra slots are added after it")

calls = {}
bar:Refresh()
assert_equal(#calls, 1, "refresh goes through the hooked class method")
assert_equal(calls[1], "vanilla_refresh", "refresh still reaches the original implementation")

-- 重复加载不能重复包装（否则每次刷新都会多跑一遍图标应用）
local rebuild_after_first_load = Inv.Rebuild
dofile(ISR_TEST_ROOT.."/scripts/isr_uihooks.lua")
assert_equal(Inv.Rebuild, rebuild_after_first_load, "reloading must not wrap the class twice")

calls = {}
bar:Rebuild()
assert_equal(#calls, 2, "the chain stays at vanilla plus the equip-slot mod after a reload")

print("test_inventorybar_hook OK")
