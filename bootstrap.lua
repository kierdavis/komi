local function _klog()
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
end  -- local function _klog
package.loaded.klog = _klog()

local function _knet()
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
    --component.modem.send(addr, port, serialization.serialize(message))
    component.modem.broadcast(port, serialization.serialize(message))
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
end  -- local function _knet
package.loaded.knet = _knet()

local function _kinternet()
  local kinternet = {}
  
  function kinternet.openLocal(req)
    local body = require("internet").request(req.url, nil, req.headers)
    local resp = getmetatable(body).__index
    resp:finishConnect()
    local status, reason, _ = resp:response()
    return {
      getStatus = function()
        return status, reason
      end,
      body = body,
      close = resp.close,
    }
  end
  
  function kinternet.openRemote(req)
    local event = require("event")
    local knet = require("knet")
  
    local status, reason, err, closed
    local chunkQueue = {}
    local chunkQueueHead = 1
    local chunkQueueTail = 1
    local nextSeqNum = 1
  
    local function close(localPort)
      if not closed then
        knet.unlisten(localPort)
        closed = true
      end
    end
  
    local localPort = knet.listenEphemeral(function(localPort, message)
      if closed then
        return
      end
      if message.seqNum ~= nextSeqNum then
        err = "bad seqNum (expected " .. tostring(nextSeqNum) .. ", got " .. tostring(message.seqNum) .. ")"
        close(localPort)
      else
        nextSeqNum = nextSeqNum + 1
        if message.status then
          status = message.status
          reason = message.reason
        elseif message.chunk then
          chunkQueue[chunkQueueTail] = message.chunk
          chunkQueueTail = chunkQueueTail + 1
        elseif message.finished then
          close(localPort)
        elseif message.error then
          err = message.error
        end
      end
      event.push("kinternet_remote_fragment", localPort)
    end)
  
    req.replyAddr = require("component").modem.address
    req.replyPort = localPort
    knet.send("1dad", 10, req)
  
    local function waitForFragment()
      if err ~= nil then
        error(err)
      end
      event.pullFiltered(nil, function(eventName, eventLocalPort)
        return eventName == "kinternet_remote_fragment" and eventLocalPort == localPort
      end)
      if err ~= nil then
        error(err)
      end
    end
    
    return {
      getStatus = function()
        while not (status or closed) do
          waitForFragment()
        end
        if closed then
          error("connection closed before receiving status")
        end
        return status, reason
      end,
      body = function()
        while not (chunkQueueHead < chunkQueueTail or closed) do
          waitForFragment()
        end
        if closed then
          return nil
        else
          local chunk = chunkQueue[chunkQueueHead]
          chunkQueue[chunkQueueHead] = nil
          chunkQueueHead = chunkQueueHead + 1
          if not chunk then
            error("didn't expect chunk to be nil")
          end
          return chunk
        end
      end,
      close = function() close(localPort) end,
    }
  end
  
  function kinternet.open(req)
    if type(req.url) ~= "string" then
      error("kinternet.request: bad url")
    end
    if type(req.headers) ~= "table" and type(req.headers) ~= "nil" then
      error("kinternet.request: bad headers")
    end
    local ok, result = pcall(kinternet.openLocal, req)
    if ok then
      return result
    elseif string.find(result, "no primary internet card found") then
      return kinternet.openRemote(req)
    else
      error(result)
    end
  end
  
  function kinternet.request(req)
    local conn = kinternet.open(req)
    local body = ""
    for chunk in conn.body do
      body = body .. chunk
    end
    conn.close()
    return {
      status = conn.status,
      reason = conn.reason,
      headers = conn.headers,
      body = body,
    }
  end
  
  return kinternet
end  -- local function _kinternet
package.loaded.kinternet = _kinternet()

local function main()
  local component = require("component")
  local filesystem = require("filesystem")
  local kinternet = require("kinternet")

  -- with trailing slash
  local repoUrl = "http://localhost:9090/"

  local ignoreMtimes = false

  local function ensureParentDir(path)
    path = filesystem.path(path)
    if not filesystem.isDirectory(path) then
      filesystem.makeDirectory(path)
    end
  end

  local function ensureDownloaded(url, path)
    local requestHeaders = {}
    local lastModified = filesystem.lastModified(path) / 1000.  -- returns 0 if nonexistent
    if lastModified and not ignoreMtimes then
      requestHeaders["If-Modified-Since"] = os.date("!%a, %d %b %Y %H:%M:%S GMT", lastModified)
    end
    local response = kinternet.open({
      url = url,
      headers = requestHeaders,
    })
    local status, reason = response.getStatus()
    if status == 200 then
      ensureParentDir(path)
      local file, err = io.open(path, "w")
      if not file then
        error("open " .. path .. ": " .. err)
      end
      for chunk in response.body do
        file:write(chunk)
      end
      file:close()
      response.close()
      io.write(path .. " updated.\n")
      return true
    elseif status == 304 then
      response.close()
      return false
    else
      response.close()
      error("GET " .. url .. ": " .. (status or "?") .. " " .. (reason or "?"))
    end
  end

  local function ensureHasContents(path, contentsFn)
    local oldContents
    local file, err = io.open(path)
    if file then
      oldContents = file:read("*a")
      file:close()
    end
    local newContents = contentsFn()
    if newContents ~= oldContents then
      ensureParentDir(path)
      local file, err = io.open(path, "w")
      if not file then
        error("open " .. path .. ": " .. err)
      end
      file:write(newContents)
      file:close()
      io.write(path .. " updated.\n")
      return true
    else
      return false
    end
  end

  local function ensureAbsent(path)
    if filesystem.exists(path) then
      filesystem.remove(path)
      io.write(path .. " removed.\n")
      return true
    else
      return false
    end
  end

  local function findFsWithLabel(label)
    local choices = {}
    for component, mountPath in filesystem.mounts() do
      if component.getLabel() == label then
        table.insert(choices, { component = component, mountPath = mountPath })
      end
    end
    local choice
    if #choices == 0 then
      error("no filesystem with label '" .. label .. "' found")
    end
    choice = choices[1]
    for _, potentialChoice in ipairs(choices) do
      if potentialChoice.mountPath == "/" then
        choice = potentialChoice
      end
    end
    return choice.mountPath, choice.component
  end

  -- Look for the desired root filesystem.
  local rootFsPath, rootFsComponent = findFsWithLabel("KOMI OS")
  io.write("Using " .. rootFsPath .. " as install root.\n")

  -- Ensure OpenOS is installed.
  if not filesystem.exists(filesystem.concat(rootFsPath, "bin/ls.lua")) then
    io.write("Installing OpenOS.\n")
    local _, installerFsComponent = findFsWithLabel("openos")
    require("shell").execute("yes | install --from=" .. installerFsComponent.address .. " --to=" .. rootFsComponent.address .. " --nosetlabel --nosetboot --noreboot")
    if not filesystem.exists(filesystem.concat(rootFsPath, "bin/ls.lua")) then
      error("installation appears to have failed")
    end
    ignoreMtimes = true
  end

  -- Fetch and evaluate the manifest.
  local manifestPath = filesystem.concat(rootFsPath, "etc/manifest.lua")
  ensureDownloaded(repoUrl .. "etc/manifest.lua", manifestPath)
  local manifest = dofile(manifestPath)

  -- Manage all files declared in the manifest. This might overwrite the currently running ksetup, so take a copy of it first.
  filesystem.copy(os.getenv("_"), "/tmp/ksetup.running.lua")
  local changedPaths = {}
  for _, entry in ipairs(manifest) do
    if not entry.path then
      error("missing path in manifest entry: " .. require("serialization").serialize(entry, true))
    end
    local path = filesystem.concat(rootFsPath, entry.path)
    local changed = false
    if entry.present == false then
      changed = ensureAbsent(path)
    else
      if entry.contents then
        changed = ensureHasContents(path, entry.contents)
      else
        changed = ensureDownloaded(repoUrl .. entry.path, path)
      end
    end
    if entry.watch then
      for _, watchedPath in ipairs(entry.watch) do
        for _, changedPath in ipairs(changedPaths) do
          if changedPath == watchedPath then
            changed = true
            break
          end
        end
      end
    end
    if changed then
      table.insert(changedPaths, entry.path)
      if entry.onChange then
        entry.onChange()
      end
    end
  end

  -- If we got to this point, the currently running version of ksetup is safe to use since it can self-update.
  filesystem.rename("/tmp/ksetup.running.lua", filesystem.concat(rootFsPath, "/usr/bin/ksetup.bak.lua"))

  -- -- Ensure the EEPROM is correctly configured.
  -- component.eeprom.setLabel("KOMI Bootloader")
  -- local bootloaderFile, reason = io.open(filesystem.concat(rootFsPath, "/bootloader.lua"))
  -- if not bootloaderFile then
  --   error("open /bootloader.lua: " .. reason)
  -- end
  -- local bootloaderText, reason = bootloaderFile:read(4096)
  -- if not bootloaderText then
  --   error("read /bootloader.lua: " .. reason)
  -- end
  -- bootloaderFile:close()
  -- component.eeprom.set(bootloaderText)

  -- If the filesystem we were configuring isn't the one we're currently running, reboot into it.
  if rootFsPath ~= "/" then
    io.write("Rebooting into installed OS.\n")
    require("computer").setBootAddress(rootFsComponent.address)
    require("computer").shutdown(true)
  end
end

local result, message = pcall(main)
if not result then
  io.stderr:write("[E] ", message, "\n")
end
