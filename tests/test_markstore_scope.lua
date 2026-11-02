local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local component_callbacks = {}
AddComponentPostInit = function(name, callback)
    component_callbacks[name] = callback
end
AddPlayerPostInit = function() end
TheWorld = { ismastersim = true }

local attached = {}
ISR =
{
    GetGlobalValue = function(name, fallback)
        return name == "TheWorld" and TheWorld or fallback
    end,
}

dofile(ISR_TEST_ROOT.."/scripts/isr_markstores.lua")

local function NewContainerEntity(components)
    return
    {
        components = components,
        AddComponent = function(self, name)
            table.insert(attached, self)
            self.components[name] = {}
        end,
    }
end

-- 所有容器实体都要在构造期挂上组件，不看 inventoryitem。
-- 组件构造期不在，存档数据就只能靠 add_component_if_missing 让引擎补建，
-- 而那个标记会让关掉模组的玩家再也进不了档。
local world_container = NewContainerEntity({})
component_callbacks.container({ inst = world_container })
assert_equal(#attached, 1, "world container receives the mark store too (keeps saves loadable after uninstall)")
assert_equal(attached[1], world_container, "mark store attaches to the world container entity")

-- 跟随型容器（切斯特、哈奇、Woby）只有 container，没有 inventoryitem
local follower_container = NewContainerEntity({})
component_callbacks.container({ inst = follower_container })
assert_equal(#attached, 2, "follower container without inventoryitem receives the mark store")

-- 可携带容器（背包、桶）照旧
local portable_container = NewContainerEntity({ inventoryitem = {} })
component_callbacks.container({ inst = portable_container })
assert_equal(#attached, 3, "portable container receives mark store")

-- 客户端不挂组件：标记以服务端为准
TheWorld.ismastersim = false
component_callbacks.container({ inst = NewContainerEntity({}) })
assert_equal(#attached, 3, "client side does not attach the mark store")
