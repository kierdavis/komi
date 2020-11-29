local kinternet = require("kinternet")
local knet = require("knet")

local function handleRequestInner(req)
  require("klog")("[kinternetgw.handleRequestInner] begin")
  local resp = kinternet.openLocal(req)
  local status, reason = resp.getStatus()
  local seqNum = 1
  knet.send(req.replyAddr, req.replyPort, {
    seqNum = seqNum,
    status = status,
    reason = reason,
  })
  seqNum = seqNum + 1
  for chunk in resp.body do
    repeat
      local subChunk = string.sub(chunk, 1, 1024)
      chunk = string.sub(chunk, 1 + #subChunk)
      knet.send(req.replyAddr, req.replyPort, { seqNum = seqNum, chunk = subChunk })
      seqNum = seqNum + 1
    until chunk == nil or chunk == ""
  end
  knet.send(req.replyAddr, req.replyPort, { seqNum = seqNum, finished = true })
  require("klog")("[kinternetgw.handleRequestInner] end")
end

local function handleRequest(req)
  if type(req.replyAddr) ~= "string" then
    require("klog")("[kinternet.handleRequest] received malformed message from " .. req.relayAddr .. ": bad replyAddr")
    return
  end
  if type(req.replyPort) ~= "number" then
    require("klog")("[kinternet.handleRequest] received malformed message from " .. req.relayAddr .. ": bad replyPort")
    return
  end
  local ok, err = pcall(handleRequestInner, req)
  if not ok then
    knet.send(req.replyAddr, req.replyPort, { error = err })
  end
end

function start()
  knet.listen(args.listenPort, handleRequest)
end

function stop()
  knet.unlisten(args.listenPort)
end
