local path = "/var/log/komi.log"
local filesystem = require("filesystem")
local parent = filesystem.path(path)
if not filesystem.isDirectory(parent) then
  filesystem.makeDirectory(parent)
end

local klog = {}
klog.file = io.open(path, "w")
function klog.print(msg)
  klog.file:write(msg .. "\n")
end

return setmetatable(klog, { __call = klog.print })
