local core = require "core"
local common = require "core.common"
local Object = require "core.object"
local FontInfo = require "plugins.fontseek.fontinfo"

---@class FontCache : core.object
---@field private fontinfo FontInfo
---@field private building boolean
---@field private searching_monospaced boolean
---@field public fontdirs table<integer, string>
---@field public fonts FontInfo.data[]
local FontCache = Object:extend()

---Constructor
function FontCache:new()
  self.fontinfo = FontInfo()
  self.fontdirs = {}
  self.fonts = {}
  self.loaded_fonts = {}
  self.building = false
  self.searching_monospaced = false
  self.monospaced = false

  table.insert(self.fontdirs, USERDIR .. "/fonts")
  table.insert(self.fontdirs, DATADIR .. "/fonts")

  if PLATFORM == "Windows" then
    table.insert(self.fontdirs, HOME .. PATHSEP .. "AppData\\Local\\Microsoft\\Windows\\Fonts" )
    table.insert(self.fontdirs, os.getenv("SYSTEMROOT") .. PATHSEP .. "Fonts" )
  elseif PLATFORM == "Mac OS X" then
    table.insert(self.fontdirs, HOME .. "/Library/Fonts")
    table.insert(self.fontdirs, "/Library/Fonts")
  else
    table.insert(self.fontdirs, HOME .. "/.local/share/fonts")
    table.insert(self.fontdirs, HOME .. "/.fonts")
    table.insert(self.fontdirs, "/usr/local/share/fonts")
    table.insert(self.fontdirs, "/usr/share/fonts")
  end

  if not self:load_cache() then
    self:build()
  elseif not self.monospaced then
    self:verify_monospaced()
  end
end

---Build the font cache and save it.
function FontCache:build()
  if self.building or self.searching_monospaced then
    core.log_quiet("The font cache is already been generated, please wait.")
    return
  end

  self.building = true
  self.monospaced = false
  self.loaded_fonts = {}

  core.log_quiet("Generating font cache...")
  local start_time = system.get_time()

  local this = self
  core.add_thread(function()
    for _, dir in ipairs(this.fontdirs) do
      this:scan_dir(dir)
    end
    this:save_cache()
    this.building = false
    this.loaded_fonts = {}
    core.log_quiet(
      "Font cache generated in %.1fs for %s fonts!",
      system.get_time() - start_time, tostring(#self.fonts)
    )
    this:verify_monospaced()
  end)
end

---Scan a directory for valid font files and load them into the cache.
---@param path string
---@param run_count? integer
function FontCache:scan_dir(path, run_count)
  run_count = run_count or 1
  local can_yield = coroutine.running()
  local list = system.list_dir(path)
  if list then
    for _, name in pairs(list) do
      if name:match("%.[to]t[fc]$") and not self.loaded_fonts[name] then
        -- prevent loading of duplicate files
        self.loaded_fonts[name] = true
        local font_path = path .. PATHSEP .. name
        local read, errmsg = self.fontinfo:read(font_path)
        if read then
          local font_data, errmsg = self.fontinfo:get_data()
          if font_data then
            table.insert(self.fonts, font_data)
          else
            io.stderr:write(
              "Error: " .. path .. PATHSEP .. name .. "\n"
              .. "  " .. errmsg .. "\n"
            )
          end
        else
          io.stderr:write(
            "Error: " .. path .. PATHSEP .. name .. "\n"
            .. "  " .. errmsg .. "\n"
          )
        end
        if can_yield and run_count % 100 == 0 then
          coroutine.yield()
        end
      else
        self:scan_dir(path .. PATHSEP .. name, run_count)
      end
      run_count = run_count + 1
    end
  end
end

---Search and mark monospaced fonts on currently loaded cache and save it.
function FontCache:verify_monospaced()
  if self.building or self.searching_monospaced then
    core.log_quiet("The monospaced verification is already running, please wait.")
    return
  end

  self.searching_monospaced = true
  self.monospaced = false

  core.log_quiet("Finding monospaced fonts...")
  local start_time = system.get_time()

  local this = self
  core.add_thread(function()
    local found = 0
    for i, font in ipairs(this.fonts) do
      FontInfo.check_is_monospace(font)
      if font.monospace then
        found = found + 1
      end
      if i % 1 == 0 then
        coroutine.yield()
      end
    end
    this.monospaced = true
    this:save_cache()
    this.searching_monospaced = false
    core.log_quiet(
      "Found %s monospaced fonts in %.1fs!",
      tostring(found), system.get_time() - start_time
    )
  end)
end

---Load font cache from persistent file for faster startup time.
function FontCache:load_cache()
  local ok, t = pcall(dofile, USERDIR .. "/font_cache.lua")
  if ok then
    self.fonts = t.fonts
    self.monospaced = t.monospaced
    return true
  end
  return false
end

---Store current font cache to persistent file.
function FontCache:save_cache()
  local fp = io.open(USERDIR .. "/font_cache.lua", "w")
  if fp then
    local output = "{\n"
      .. "monospaced = "..tostring(self.monospaced)..",\n"
      .. "[\"fonts\"] = "
      .. common.serialize(
        self.fonts,
        { pretty = true, escape = true, sort = true, initial_indent = 1 }
      ):gsub("^%s+", "")
      .. "\n}\n"
    fp:write("return ", output)
    fp:close()
  end
end

---Search for a font and return the best match.
---@param name string
---@param style? FontInfo.style
---@param monospaced? boolean
---@return FontInfo.data? font_data
---@return string? errmsg
function FontCache:search(name, style, monospaced)
  if #self.fonts == 0 then
    return nil, "the font cache needs to be rebuilt"
  end

  style = style or "regular"
  name = name:ulower()
  style = style:ulower()

  if name == "monospace" then
    name = "mono"
    monospaced = true
  end

  if not self.monospaced then monospaced = false end

  ---@type FontInfo.data
  local fontdata = nil
  local prev_score = 0

  for _, font in ipairs(self.fonts) do
    if not monospaced or (monospaced and font.monospace) then
      local score = system.fuzzy_match(
        font.fullname:ulower(),
        name .. " " .. style,
        false
      )
      if score ~= nil and (score > prev_score or prev_score == 0) then
        fontdata = font
        prev_score = score
      end
    end
  end

  if fontdata then
    local fontfile = io.open(fontdata.path, "r")
    if not fontfile then
      return nil, "found font file does not exists, cache is outdated"
    else
      fontfile:close()
    end
  else
    return nil, "no matching font found"
  end

  return fontdata
end


return FontCache
