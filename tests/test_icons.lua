local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")..": expected "..tostring(expected)..", got "..tostring(actual), 2)
    end
end

local function NewImage(atlas, image)
    return
    {
        atlas = atlas,
        image = image,
        shown = true,
        size_calls = 0,
        SetClickable = function() end,
        SetSize = function(self, width, height)
            self.size_calls = self.size_calls + 1
            self.width = width
            self.height = height
        end,
        SetTexture = function(self, new_atlas, new_image)
            self.atlas = new_atlas
            self.image = new_image
        end,
        SetTint = function(self, r, g, b, a)
            self.tint = { r, g, b, a }
        end,
        Show = function(self)
            self.shown = true
        end,
        Hide = function(self)
            self.shown = false
        end,
        MoveToFront = function() end,
    }
end

ISR =
{
    Config = { icon_opacity = 0.35, border_opacity = 1 },
    NormalizePrefabKey = function(value)
        if value == nil then
            return nil
        end
        local key = string.lower(tostring(value))
        if #key > 4 and string.sub(key, -4) == ".tex" then
            key = string.sub(key, 1, #key - 4)
        end
        return key ~= "" and key or nil
    end,
    GetGlobalValue = function(name, fallback)
        return _G[name] or fallback
    end,
}

GetInventoryItemAtlas = function(image, try_harder)
    if image == "grass.tex" or image == "twigs.tex" then
        return "images/inventoryimages.xml"
    end
    return nil
end

softresolvefilepath = function(path)
    return path ~= "images/missing.xml" and path or nil
end

package.preload["widgets/image"] = function()
    return NewImage
end

dofile(ISR_TEST_ROOT.."/scripts/isr_icons.lua")

local slot =
{
    bg = { GetSize = function() return 64, 64 end },
    AddChild = function(_, child)
        return child
    end,
    SetBGImage2 = function()
        error("ISR must not use the game's bgimage2 layer")
    end,
}

-- 物品图标：直接取该 prefab 的物品栏贴图
local icon = ISR.GetPrefabIcon("grass")
assert_equal(icon.atlas, "images/inventoryimages.xml", "prefab icon resolves the inventory atlas")
assert_equal(icon.image, "grass.tex", "prefab icon uses the prefab texture name")
assert_equal(ISR.GetPrefabIcon("Grass.TEX").image, "grass.tex", "prefab icon normalizes the key")
assert_equal(ISR.GetPrefabIcon("no_such_thing"), nil, "unknown prefab has no icon")

assert_equal(ISR.ApplyMarkIconToSlot(slot, "grass"), true, "prefab icon is applied")
assert_equal(slot._isr_slot_icon ~= nil, true, "ISR owns its icon widget")
assert_equal(slot._isr_slot_icon.shown, true, "owned icon is visible")
assert_equal(slot._isr_slot_icon.tint[4], 0.35, "owned icon uses configured opacity")

assert_equal(ISR.ApplyMarkIconToSlot(slot, "twigs"), true, "icon texture is swapped for another prefab")
assert_equal(slot._isr_slot_icon.image, "twigs.tex", "icon texture follows the new prefab")

ISR.ClearSlotIcon(slot)
assert_equal(slot._isr_slot_icon.shown, false, "clear hides only the owned icon")

-- 取不到图标时不报错，只把图标隐藏
assert_equal(ISR.ApplyMarkIconToSlot(slot, "no_such_thing"), false, "missing icon is reported")
assert_equal(slot._isr_slot_icon.shown, false, "missing icon leaves the slot without an icon")

-- 木框
ISR.ApplySlotBorder(slot)
assert_equal(slot._isr_slot_border ~= nil, true, "border widget is created")
assert_equal(slot._isr_slot_border.atlas, "images/wood_frame_128_ARGB.xml", "border uses the mod atlas")
assert_equal(slot._isr_slot_border.shown, true, "border is visible")
assert_equal(slot._isr_slot_border.tint[4], 1, "border is fully opaque by default")

-- 木框透明度跟随配置项 border_opacity
ISR.Config.border_opacity = 0.4
ISR.ApplySlotBorder(slot)
assert_equal(slot._isr_slot_border.tint[4], 0.4, "border uses the configured opacity")

ISR.Config.border_opacity = nil
ISR.ApplySlotBorder(slot)
assert_equal(slot._isr_slot_border.tint[4], 1, "missing config falls back to opaque")

ISR.ClearSlotBorder(slot)
assert_equal(slot._isr_slot_border.shown, false, "border is hidden on clear")

-- 尺寸没变就不重复 SetSize：OnUpdate 每帧都会走 RefreshSlotBorderLayout，
-- 每次都设一遍等于每帧触发一次 UI 布局重算
ISR.ApplySlotBorder(slot)
local border_size_calls = slot._isr_slot_border.size_calls
local icon_size_calls = slot._isr_slot_icon.size_calls
ISR.RefreshSlotBorderLayout(slot)
assert_equal(slot._isr_slot_border.size_calls, border_size_calls, "unchanged border size is not re-applied")
assert_equal(slot._isr_slot_icon.size_calls, icon_size_calls, "unchanged icon size is not re-applied")

-- 槽位尺寸变了才重新设
slot.bg = { GetSize = function() return 96, 96 end }
ISR.RefreshSlotBorderLayout(slot)
assert_equal(slot._isr_slot_border.size_calls, border_size_calls + 1, "changed size is applied once")
assert_equal(slot._isr_slot_border.width, 96 * ISR.SLOT_BORDER_SCALE, "border follows the new slot size")
