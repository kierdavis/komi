local kdirectory = {}

if require("filesystem").exists("/etc/rc.d/kdirectorysrv.lua") then
  -- Local

  kdirectory.data = {}

  function kdirectory.register(name, id, timeout)
    checkArg(1, name, "string")
    checkArg(2, id, "string")
    kdirectory.data[name] = id
  end

  function kdirectory.resolve(name, timeout)
    checkArg(1, name, "string")
    return kdirectory.data[name]
  end

else
  -- Remote

  kdirectory.serverAddr = "broadcast"

  local function doRequest(req, timeout)
    checkArg(1, req, "table")
    checkArg(2, timeout, "number", "nil")
    local resp = knet.request(kdirectory.serverAddr, 11, timeout, req)
    if resp.serverAddr then
      kdirectory.serverAddr = resp.serverAddr
    end
    return resp
  end

  function kdirectory.register(name, id, timeout)
    checkArg(1, name, "string")
    checkArg(2, id, "string")
    checkArg(3, timeout, "number", "nil")
    doRequest({ name = name, id = id }, timeout)
  end

  function kdirectory.resolve(name, timeout)
    checkArg(1, name, "string")
    checkArg(2, timeout, "number", "nil")
    return doRequest({ name = name }, timeout).id
  end
end

function kdirectory.registerSelf(timeout)
  local name = kos.getHostname()
  if not name then return end
  local id = require("component").modem.address
  kdirectory.register(name, id, timeout)
end

function kdirectory.mustResolve(name, timeout)
  checkArg(1, name, "string")
  checkArg(2, timeout, "number", "nil")
  local id = kdirectory.resolve(name, timeout)
  if not id then
    error("failed to resolve: " .. name)
  end
  return id
end

return kdirectory
