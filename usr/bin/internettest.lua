local kinternet = require("kinternet")
local resp = kinternet.openRemote({url = "http://localhost:9090/test.txt"})
local status, reason = resp.getStatus()
io.write("Status: " .. tostring(status) .. "\n")
io.write("Reason: " .. tostring(reason) .. "\n")
for chunk in resp.body do
  io.write("---\n")
  io.write(chunk, "\n")
end
resp.close()
