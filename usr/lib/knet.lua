local knet = {}

local component = require("component")
local event = require("event")
local serialization = require("serialization")

-------------------------------------------------------------------------------
---------------------------- Basic send/receive API ---------------------------
-------------------------------------------------------------------------------

function knet.send(addr, port, message)
  checkArg(1, addr, "string")
  checkArg(2, port, "number")
  checkArg(3, message, "table")
  if addr == "broadcast" then
    component.modem.broadcast(port, serialization.serialize(message))
  else
    component.modem.send(addr, port, serialization.serialize(message))
  end
end

knet.handlers = {}
function knet.unlisten(port)
  checkArg(1, port, "number")
  for componentAddr, componentType in component.list() do
    if componentType == "modem" then
      component.invoke(componentAddr, "close", port)
    end
  end
  knet.handlers[port] = nil
end
function knet.listen(port, handler)
  checkArg(1, port, "number")
  checkArg(2, handler, "function")
  if knet.handlers[port] ~= nil then
    knet.unlisten(port)
  end
  knet.handlers[port] = handler
  for componentAddr, componentType in component.list() do
    if componentType == "modem" then
      component.invoke(componentAddr, "open", port)
    end
  end
end
function knet.isListening(port)
  checkArg(1, port, "number")
  return knet.handlers[port] ~= nil
end

local function onModemMessage(eventName, localAddr, relayAddr, port, distance, blob)
  local handler = knet.handlers[port]
  if not handler then
    return
  end
  local ok, message = pcall(serialization.unserialize, blob)
  if not ok then
    io.stderr:write("received malformed message from " .. relayAddr .. ": " .. message .. "\n")
    return
  end
  if type(message) ~= "table" then
    io.stderr:write("received malformed message from " .. relayAddr .. ": not a table\n")
    return
  end
  message.relayAddr = relayAddr
  handler(message)
end
for handlerId, handler in pairs(event.handlers) do
  if handler.key == "modem_message" then
    event.handlers[handlerId] = nil
  end
end
event.listen("modem_message", onModemMessage)

-------------------------------------------------------------------------------
------------------------------- Ephemeral ports -------------------------------
-------------------------------------------------------------------------------

knet.firstEphemeralPort = 32768

local nextEphemeralPort = knet.firstEphemeralPort
function knet.listenEphemeral(handler)
  checkArg(1, handler, "function")
  local port
  repeat
    port = nextEphemeralPort
    nextEphemeralPort = nextEphemeralPort + 1
    if nextEphemeralPort > 65535 then
      nextEphemeralPort = knet.firstEphemeralPort
    end
  until not knet.isListening(port)
  knet.listen(port, function(msg) handler(port, msg) end)
  return port
end

-------------------------------------------------------------------------------
----------------------------- Request/response API ----------------------------
-------------------------------------------------------------------------------
--
function knet.request(remoteAddr, remotePort, timeout, reqMessage)
  checkArg(1, remoteAddr, "string")
  checkArg(2, remotePort, "number")
  checkArg(3, timeout, "number", "nil")
  checkArg(4, reqMessage, "table")
  local localPort = knet.listenEphemeral(function(localPort, respMessage)
    io.stderr:write("[D] ", require("serialization").serialize(respMessage), "\n")
    event.push("knet_response", localPort, respMessage)
  end)
  reqMessage.replyAddr = component.modem.address
  reqMessage.replyPort = localPort
  knet.send(remoteAddr, remotePort, reqMessage)
  local a, b, respMessage = event.pullFiltered(timeout, function(eventName, eventLocalPort)
    return eventName == "knet_response" and eventLocalPort == localPort
  end)
  io.stderr:write("[D] ", tostring(a), " ", tostring(b), " ", tostring(respMessage), "\n")
  knet.unlisten(localPort)
  if not respMessage then
    error("request timed out")
  end
  if respMessage.error then
    error(respMessage.error)
  end
  return respMessage
end

function knet.serve(port, handler)
  checkArg(1, port, "number")
  checkArg(2, handler, "function")
  knet.listen(port, function(reqMessage)
    if type(reqMessage.replyAddr) ~= "string" then
      io.stderr:write("received malformed message from " .. reqMessage.relayAddr .. ": bad replyAddr\n")
    end
    if type(reqMessage.replyPort) ~= "number" then
      io.stderr:write("received malformed message from " .. reqMessage.relayAddr .. ": bad replyPort\n")
    end
    ok, respMessage = pcall(handler, reqMessage)
    if not ok then
      respMessage = { error = respMessage }
    end
    knet.send(reqMessage.replyAddr, reqMessage.replyPort, respMessage)
  end)
end

return knet
