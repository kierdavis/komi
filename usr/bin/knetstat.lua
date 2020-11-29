local knet = require("knet")

for port, _ in pairs(knet.handlers) do
  if port < knet.firstEphemeralPort then
    io.write(tostring(port) .. "\n")
  end
end
