local hostname
local hostnameFile = io.open("/etc/hostname")
if hostnameFile then
  hostname = hostnameFile:read("*l")
  hostnameFile:close()
end

local function reloadLib(name)
  package.loaded[name] = nil
  io.write(name, " cleared from library cache.\n")
end
local function reloadService(name, isEnabled)
  require("shell").execute("rc " .. name .. " stop")
  require("rc").unload(name)
  io.write(name, " stopped.\n")
  if isEnabled then
    require("shell").execute("rc " .. name .. " start")
    io.write(name, " started.\n")
  end
end

local services = {
  kinternetgw = {
    enabled = hostname == "infra1",
    config = {
      listenPort = 10,
    },
    watch = {"/usr/lib/kinternet.lua", "/usr/lib/klog.lua", "/usr/lib/knet.lua"},
  },
  kdirectorysrv = {
    enabled = hostname == "infra1",
    config = {},
    watch = {"/usr/lib/kdirectory.lua", "/usr/lib/knet.lua"},
  },
}

local manifest = {
  -- Common logging library.
  {
    path = "/usr/lib/klog.lua",
    onChange = function() reloadLib("klog") end,
  },

  -- Operating system utility library
  {
    path = "/usr/lib/kos.lua",
    onChange = function() reloadLib("kos") end,
  },
  
  -- Higher-level networking library
  {
    path = "/usr/lib/knet.lua",
    onChange = function() reloadLib("knet") end,
  },

  -- Higher-level internet library
  {
    path = "/usr/lib/kinternet.lua",
    onChange = function() reloadLib("kinternet") end,
    watch = {"/usr/lib/klog.lua", "/usr/lib/knet.lua"},
  },

  -- Directory client library
  {
    path = "/usr/lib/kdirectory.lua",
    onChange = function() reloadLib("kdirectory") end,
    watch = {"/usr/lib/knet.lua", "/usr/lib/kos.lua"},
  },

  -- Configuration management script
  { path = "/usr/bin/ksetup.lua" },

  -- Script to generate message-of-the-day
  { path = "/etc/motd" },

  -- Util script to stop+unload+start an rc service
  { path = "/usr/bin/rcrestart.lua" },

  -- Util script to reload a require'd library
  { path = "/usr/bin/reloadlib.lua" },

  -- Util script to display which knet ports are being listened on
  { path = "/usr/bin/knetstat.lua" },
}

local rcCfg = { enabled = {} }
local serviceEntries = {}
for serviceName, serviceInfo in pairs(services) do
  local watch = serviceInfo.watch or {}
  table.insert(watch, "/etc/rc.cfg")
  table.insert(serviceEntries, {
    path = "/etc/rc.d/" .. serviceName .. ".lua",
    present = serviceInfo.enabled,
    onChange = function() reloadService(serviceName, serviceInfo.enabled) end,
    watch = watch,
  })
  if serviceInfo.enabled then
    table.insert(rcCfg.enabled, serviceName)
    rcCfg[serviceName] = serviceInfo.config
  end
end
table.insert(manifest, {
  path = "/etc/rc.cfg",
  contents = function()
    local serialization = require("serialization")
    local contents = ""
    for key, value in pairs(rcCfg) do
      contents = contents .. key .. " = " .. serialization.serialize(value) .. "\n"
    end
    return contents
  end
})
for _, entry in ipairs(serviceEntries) do
  table.insert(manifest, entry)
end

return manifest
