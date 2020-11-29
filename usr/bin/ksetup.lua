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
