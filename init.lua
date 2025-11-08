local Server = require "wtk.server"
local json = require "wtk.json"
local proc = require "wtk.proc"
local loop = Server.Loop.new()

local function merge(a,b) local t = {} for k,v in pairs(a) do t[k] = v end for k,v in pairs(b) do t[k] = v end return t end
local function filter(l, func) local t = {} for _, v in ipairs(l) do if func(v) then table.insert(t, v) end end return t end
local function split(str, delim) local t = {} for match in str:gmatch("([^" .. delim .. "]+)") do table.insert(t, match) end return t end
local function concat(...) local t = {} for _, a in ipairs({ ... }) do if type(a) == 'table' then for _,v in ipairs(a) do table.insert(t, v) end else table.insert(t, a) end end return t end


local initial = not server
local request_index
if initial then
  local args = Server.pargs({ ... }, { host = "string", port = "string", verbose = "flag", timeout = "integer", debug = "flag" })
  server = Server.new(merge({ index = 0, port = 9090 }, args)):add(loop)
  if args.debug then
    server:hot_reload(loop, "init.lua")
    loop:add(0, function() server:console() end)
  end
end

function server:handler(request)
  self.index = self.index + 1
  request.index = self.index
  local handled, res = self.default_handler(self, request)
  if res and type(res) == 'table' and res.json then 
    return request:respond(200, { ["content-type"] = "application/json; charset=UTF-8" }, json.encode(res.json))
  end
end

local old_error_handler = server.error_handler
function server:error_handler(request, err, client)
  if not request.path:find("/api") then return old_error_handler(self, request, err, client) end
  if type(err) == 'table' and err.code and type(err.code) == "number" then
    local msg = string.format("%d Error", err.code)
    if err.message then msg = msg .. ": " .. err.message end
    if self.verbose or not err.verbose then self.log:error(self.verbose and debug.traceback(msg, 3) or msg) end
    if request and not request.responded then request:respond(err.code, { ["Content-Type"] = "application/json; charset=UTF-8" }, json.encode({ error = (err.message or self.codes[err.code]:lower()) })) end
  else
    local msg = string.format("Unhandled Error: %s", err) 
    if self.verbose then self.log:error(debug.traceback(msg, 3)) else self.log:error(msg) end
    if request and not request.responded then request:respond(500, { ["Content-Type"] = "application/json; charset=UTF-8" }, json.encode({ error = "internal server error" })) end
  end
  if not request then client:close() end
end


local function strip(t) 
  for _, v in ipairs({ "local_path", "binary_path", "is_installed", "path", "files", "stub", "url", "repo_path" }) do t[v] = nil end
  for k,v in pairs(t) do
    if type(t[k]) == 'table' then
      strip(v)
    end
  end
  return t
end

function server:lpm(command)
  local cmd = concat("./lpm", command, "--json", "--assume-yes", "--quiet", "--cachedir", ".", "--userdir", ".", "--bottledir", ".")
  self.log:info(table.concat(cmd, " "))
  local proc = proc.new(cmd)
  local results = proc.stdout:read("*all")
  local err = proc.stderr:read("*all")
  if #err > 0 then self.log:error(err) end
  assert(proc:join() == 0, { code = 400, message = #err > 0 and json.decode(err).error })
  return #results > 0 and strip(json.decode(results))
end

local function detect_arch(request)
  if not request.headers['user-agent'] then return nil end
  local ua = request.headers['user-agent']:lower()
  local platform, arch
  if     ua:find("android") then platform = "android"
  elseif ua:find("linux") then platform = "linux"
  elseif ua:find("windows") then platform = "windows" 
  elseif ua:find("macintosh") then platform = "darwin"
  else 
    return nil 
  end
  if ua:find("x86_64") or ua:find("x64") then arch = "x86_64"
  elseif platform == "darwin" or ua:find("aarch64") or ua:find("amd64") then
    arch = "aarch64"
  else
    return nil
  end
  return arch .. "-" .. platform
end

server:get("/", function(request) return request:file("root/index.html") end)
server:get("/static/([^/]+)", function(request, path) return request:file("root/" .. path) end)
server:get("/api/system", function(request) return { json = { version = server:lpm("--version")['version'], arch = detect_arch(request) } } end)
server:get("/api/lite%-xl", function(request) return { json = server:lpm({ "lite-xl", "list" }) } end)
server:get("/api/addons", function(request) return  { json = server:lpm({ "list" }) } end)
server:get("/api/lite%-xl/([%w%.%-]+)", function(request, version) 
  local path = (os.getenv("TMPDIR") or "/tmp") .. "/lite-xl-" .. request.index
  local arch = assert(request.params.arch or detect_arch(request), { code = 400, message = "cannot determine architecture, requires explicit arch" })
  local extension = arch:find("windows") and ".zip" or ".tar.gz"
  proc.new(string.format("rm -rf %s%s %s", path, extension, path)):join()
  request.params.addons = request.params.addons and split(request.params.addons, "%s*,%s*")
  -- disallow all flags
  for k,v in pairs(request.params) do 
    if type(v) == 'table' then for i, p in ipairs(v) do v[i] = p:gsub("^%-%-", "") end else request.params[k] = v:gsub("^%-%-", "") end
  end
  server:lpm(concat("dump", path .. "/lite-xl", version, request.params.addons, "--config", request.params.config or "system", "--arch", arch))
  assert(proc.new(arch:find("windows") and 
    string.format("cd %s/.. && zip %s.zip %s/lite-xl && cd -", path, path, path) or
    string.format("tar -C %s -zcvf %s.tar.gz lite-xl", path, path) 
  ):join() == 0, "can't create archive")
  local f = assert(io.open(path .. extension, "rb"), "can't open file: " .. path .. extension)
  request:respond(200, { ["content-type"] = "application/" .. (arch:find("windows") and "zip" or "tar+gzip"), ["content-disposition"] = string.format('attachment; filename="lite-xl-v%s%s"', version, extension) }, function()
    return f:read(16*1024)
  end)
  f:close()
  proc.new(string.format("rm -rf %s%s %s", path, extension, path)):join()
end)

if initial then 
  assert(io.open("lpm", "rb") or proc.new("wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.`uname -m | sed 's/arm64/aarch64/'`-`uname | tr '[:upper:]' '[:lower:]'` -O lpm && chmod +x lpm"):join() == 0, "can't download lpm")
  loop:add(server.countdown.new(1*60*60, 1*60*60), function() 
    server.log:info('Performing an lpm self-upgrade and update.')
    server:lpm("update") 
    server:lpm("self-upgrade") 
    server.log:info('Done.')
  end) -- every hour self-upgrade lpm
  loop:run() 
end
