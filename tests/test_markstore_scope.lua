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

local world_container = NewContainerEntity({})
component_callbacks.container({ inst = world_container })
assert_equal(#attached, 0, "world container does not receive mark store")

local portable_container = NewContainerEntity({ inventoryitem = {} })
component_callbacks.container({ inst = portable_container })
assert_equal(#attached, 1, "portable container receives mark store")
assert_equal(attached[1], portable_container, "mark store attaches to portable entity")
