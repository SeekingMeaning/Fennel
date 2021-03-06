-- Ensure we're getting the Fennel we expect, not luarocks or anything
package.loaded.fennel = dofile("fennel.lua")
table.insert(package.loaders or package.searchers, package.loaded.fennel.searcher)
package.loaded.fennelview = package.loaded.fennel.dofile("fennelview.fnl")
package.loaded.fennelfriend = package.loaded.fennel.dofile("src/fennel/friend.fnl")

local runner = require("test.luaunit").LuaUnit:new()
runner:setOutputType(os.getenv('FNL_TEST_OUTPUT') or 'tap')

-- We have to load the tests with the old version of Fennel; otherwise
-- bugs in the current implementation will prevent the tests from loading!
local oldfennel = dofile("old/fennel.lua")

local function testall(suites)
    local instances = {}
    for _, test in ipairs(suites) do
        -- attach test modules (which export k/v tables of test fns) as alists
        local suite = oldfennel.dofile("test/" .. test .. ".fnl")
        for name, testfn in pairs(suite) do
            table.insert(instances, {name,testfn})
        end
    end
    return runner:runSuiteByInstances(instances)
end

testall({'core', 'mangling', 'quoting', 'misc', 'docstring', 'fennelview',
         'failures', 'repl', 'cli',})

os.exit(runner.result.notSuccessCount == 0 and 0 or 1)
