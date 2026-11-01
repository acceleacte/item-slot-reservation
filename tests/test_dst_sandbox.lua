local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local failures = {}
local function expect_ok(name, fn)
    local ok, result = pcall(fn)
    if not ok then
        table.insert(failures, name..": "..tostring(result))
    end
end

local slot_ids = { "head", "hands", "body", "beard" }
local runtime_global =
{
    debug = debug,
    error = error,
    next = next,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    unpack = table.unpack,
    xpcall = xpcall,
    EQUIPSLOTS =
    {
        HEAD = "head",
        HANDS = "hands",
        BODY = "body",
        BEARD = "beard",
    },
}

local sandbox_table =
{
    concat = table.concat,
    insert = table.insert,
    remove = table.remove,
    sort = table.sort,
}

local env =
{
    GLOBAL = runtime_global,
    Class = function() end,
    ipairs = ipairs,
    math = math,
    pairs = pairs,
    print = print,
    require = function(name)
        assert(name == "equipslotutil", "unexpected module "..tostring(name))
        return
        {
            Count = function() return #slot_ids end,
            FromID = function(id) return slot_ids[id] end,
        }
    end,
    string = string,
    table = sandbox_table,
    tostring = tostring,
    type = type,
}
env.env = env

local function load_module(relative_path)
    local path = ISR_TEST_ROOT.."/"..relative_path
    local chunk, err = load(read_file(path), "@"..path, "t", env)
    assert(chunk ~= nil, err)
    chunk()
end

load_module("scripts/isr_env.lua")
load_module("scripts/isr_placement.lua")

expect_ok("prefab key normalization inside the mod sandbox", function()
    assert(env.ISR.NormalizePrefabKey("CutGrass.TEX") == "cutgrass", "prefab keys are normalized")
    assert(env.ISR.NormalizePrefabKey("") == nil, "empty prefab keys are rejected")
end)

env.ISR.GetServerMarks = function() return {} end
expect_ok("empty server-mark scan", function()
    assert(env.ISR.HasAnyServerMarks({}) == false, "empty marks should be false")
end)

expect_ok("transfer context cleanup", function()
    local result = env.ISR.WithTransferContext({ source_guid = 1 }, function(value)
        return value + 1
    end, 4)
    assert(result == 5, "transfer result mismatch")
    assert(env.ISR.GetTransferContext() == nil, "transfer context leaked")
end)

expect_ok("transfer error cleanup", function()
    local ok = pcall(function()
        env.ISR.WithTransferContext({ source_guid = 2 }, function()
            error("expected transfer failure")
        end)
    end)
    assert(ok == false, "transfer error should propagate")
    assert(env.ISR.GetTransferContext() == nil, "failed transfer context leaked")
end)

assert(#failures == 0, table.concat(failures, "\n"))
