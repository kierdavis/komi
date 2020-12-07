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

  local sharedState = {
    chunkQueue = {},
    chunkQueueHead = 1,
    chunkQueueTail = 1,
    nextSeqNum = 1,
  }

  local function close()
    if sharedState.localPort ~= nil then
      knet.unlisten(sharedState.localPort)
      sharedState.localPort = nil
      --require("klog")("[kinternet.openRemote] closed")
    end
  end

  sharedState.localPort = knet.listenEphemeral(function(_localPort, message)
    --require("klog")("[kinternet.openRemote] recved " .. tostring(message.seqNum))
    if closed then
      return
    end
    if message.seqNum ~= sharedState.nextSeqNum then
      sharedState.error = "bad seqNum (expected " .. tostring(sharedState.nextSeqNum) .. ", got " .. tostring(message.seqNum) .. ")"
      close()
    else
      sharedState.nextSeqNum = sharedState.nextSeqNum + 1
      if message.status then
        sharedState.status = message.status
        sharedState.reason = message.reason
      elseif message.chunk then
        sharedState.chunkQueue[sharedState.chunkQueueTail] = message.chunk
        sharedState.chunkQueueTail = sharedState.chunkQueueTail + 1
      elseif message.finished then
        close()
      elseif message.error then
        sharedState.error = message.error
      end
    end
    event.push("kinternet_remote_fragment", sharedState.localPort)
  end)

  req.replyAddr = require("component").modem.address
  req.replyPort = sharedState.localPort
  knet.send("broadcast", 10, req)
  --require("klog")("[kinternet.openRemote] sent")

  local function waitForEvent()
    if sharedState.error ~= nil then
      error(sharedState.error)
    end
    event.pullFiltered(nil, function(eventName, eventLocalPort)
      return eventName == "kinternet_remote_fragment" and eventLocalPort == sharedState.localPort
    end)
    --require("klog")("[kinternet.openRemote] pulled")
    if sharedState.error ~= nil then
      error(sharedState.error)
    end
  end

  return {
    getStatus = function()
      while not sharedState.status and sharedState.localPort do
        waitForEvent()
      end
      if not sharedState.status then
        error("connection closed before receiving status")
      end
      return sharedState.status, sharedState.reason
    end,
    body = function()
      while not (sharedState.chunkQueueHead < sharedState.chunkQueueTail) and sharedState.localPort do
        waitForEvent()
      end
      if sharedState.chunkQueueHead < sharedState.chunkQueueTail then
        local chunk = chunkQueue[chunkQueueHead]
        chunkQueue[chunkQueueHead] = nil
        chunkQueueHead = chunkQueueHead + 1
        if not chunk then
          error("didn't expect chunk to be nil")
        end
        return chunk
      else
        return nil
      end
    end,
    close = close,
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
