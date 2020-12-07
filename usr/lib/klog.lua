local path = "/var/log/komi.log"
local filesystem = require("filesystem")
local parent = filesystem.path(path)
if not filesystem.isDirectory(parent) then
  filesystem.makeDirectory(parent)
end

return function(msg)
  local f, err = io.open(path, "a")
  if not f then
    error(err)
  end
  f:write(tostring(msg) .. "\n")
  f:close()
end
