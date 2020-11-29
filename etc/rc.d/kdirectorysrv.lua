local component = require("component")
local kdirectory = require("kdirectory")
local knet = require("knet")

local function print(msg)
  io.stderr:write("[kdirectorysrv] ", msg, "\n")
end

if not kdirectory.data then
  print("auto-reloading kdirectory")
  package.loaded.kdirectory = nil
  kdirectory = require("kdirectory")
end

local function handleRequestInner(req)
  if req.name and req.id then
    kdirectory.register(req.name, req.id, nil)
    return {}
  elseif req.name then
    return { id = kdirectory.resolve(req.name, nil) }
  else
    return {}
  end
end

local function handleRequest(req)
  local resp = handleRequestInner(req)
  resp.serverAddr = component.modem.address
  return resp
end

function start()
  knet.serve(args.listenPort, handleRequest)
end

function stop()
  knet.unlisten(args.listenPort)
end

function dump()
  for name, id in pairs(kdirectory.data) do
    io.write(name, ": ", id, "\n")
  end
end
