local kos = {}

function kos.getHostname()
  local file = io.open("/etc/hostname")
  if file then
    local hostname = file:read("*l")
    file:close()
    return hostname
  end
  return nil
end

return kos
