local function main(name)
  package.loaded[name] = nil
end
main(...)
