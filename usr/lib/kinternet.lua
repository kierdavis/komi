local kinternet = {}

function kinternet.openLocal(req)
  local body = require("internet").request(req.url, nil, req.headers)
  local resp = getmetatable(body).__index
  require("klog")("[kinternet.openLocal] finishConnect=" .. tostring(resp:finishConnect()))
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
      require("klog")("[kinternet.openRemote] closed")
    end
  end

  local localPort = knet.listenEphemeral(function(localPort, message)
    require("klog")("[kinternet.openRemote] recved " .. tostring(message.seqNum))
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
  knet.send("broadcast", 10, req)
  require("klog")("[kinternet.openRemote] sent")

  local function waitForFragment()
    if err ~= nil then
      error(err)
    end
    event.pullFiltered(nil, function(eventName, eventLocalPort)
      return eventName == "kinternet_remote_fragment" and eventLocalPort == localPort
    end)
    require("klog")("[kinternet.openRemote] pulled")
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
