local function main(name)
  require("shell").execute("rc " .. name .. " stop")
  require("rc").unload(name)
  require("shell").execute("rc " .. name .. " start")
end
main(...)
