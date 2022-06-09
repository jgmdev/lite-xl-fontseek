--- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Object = require "core.object"
local FontCache = require "plugins.fontseek.cache"

---@class plugins.fontseek
---@fields public cache FontCache
local fontseek = {}

---@type FontCache
local fontcache = FontCache()

-- search testing
-- local font = fontcache:search("open sans", "regular")
-- if font then
--   for name, value in pairs(font) do
--     print (name .. ": " .. tostring(value))
--   end
-- end

local fonts = {}

---Generate the list of fonts displayed on the CommandView.
---@param monospaced? boolean Only display fonts detected as monospaced.
local function generate_fonts(monospaced)
  if not fontcache.monospaced then monospaced = false end
  fonts = {}
  for idx, f in ipairs(fontcache.fonts) do
    if not monospaced or (monospaced and f.monospace) then
      table.insert(fonts, f.fullname .. "||" .. idx)
    end
  end
end

---Helper function to split a string by a given delimeter.
local function split(s, delimeter, delimeter_pattern)
  if not delimeter_pattern then
    delimeter_pattern = delimeter
  end

  local result = {};
  for match in (s..delimeter):gmatch("(.-)"..delimeter_pattern) do
    table.insert(result, match);
  end
  return result;
end

---Launch the commandview and let the user select a font.
---@param name string The label displayed on the command view.
---@param font_type '"font"' | '"code_font"'
---@param monospaced boolean
local function ask_font(name, font_type, monospaced)
  if fontcache.building or fontcache.searching_monospaced then
    monospaced = false
  end

  if not fontcache.building then
    generate_fonts(monospaced)
  end

  core.command_view:enter(name, {
    submit = function(text, item)
      local path = item.info
      core.command_view:enter("Set Fonts", {
        text = tostring(math.ceil(style[font_type]:get_size() / SCALE)),
        submit = function(size)
          size = tonumber(size)
          if size then
            style[font_type] = renderer.font.load(path, size * SCALE, {})
          else
            core.error("Invalid font size provided")
          end
        end
      })
    end,
    suggest = function(text)
      if fontcache.building then
        generate_fonts(monospaced)
      end
      local res = common.fuzzy_match(fonts, text)
      for i, name in ipairs(res) do
        local font_info = split(name, "||")
        local id = tonumber(font_info[2])
        local font_data = fontcache.fonts[id]
        res[i] = {
          text = font_data.fullname,
          info = font_data.path,
          id = id
        }
      end
      return res
    end
  })
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
command.add(nil, {
  ["font-seek:set-code-font"] = function()
    core.command_view:enter("List only monospace?", {
      submit = function(text, item)
        ask_font("Code Font", "code_font", item.mono)
      end,
      suggest = function(text)
        local res = common.fuzzy_match({"Yes", "No"}, text)
        for i, name in ipairs(res) do
          res[i] = {
            text = name,
            mono = text == "Yes" and true or false
          }
        end
        return res
      end
    })
  end,

  ["font-seek:set-text-font"] = function()
    ask_font("Text Font", "font", false)
  end,

  ["font-seek:rebuild-cache"] = function()
    fontcache:build()
  end,
})

---@class plugins.fontseek.font
---@field public name string
---@field public style FontInfo.style
---@field public monospaced boolean
---@field public options renderer.fontoptions

---Search for fonts and loads them it into the given table field.
---@param t table A table where the font resides
---@param field string Name or idx where the font is stored
---@param fonts_list plugins.fontseek.font[] List of fonts to search and load
---@param size number Desired overall font size without SCALE applied
local function load_fonts(t, field, fonts_list, size)
  if fontcache.building or fontcache.searching_monospaced then
    core.add_thread(function()
      while fontcache.building or fontcache.searching_monospaced do
        coroutine.yield(2)
      end
      load_fonts(t, field, fonts_list, size)
    end)
  else
    core.add_thread(function()
      ---@type plugins.fontseek.font[]
      local found_fonts = {}

      for i, font in pairs(fonts_list) do
        local fontdata, errmsg = fontcache:search(
          font.name, font.style, font.monospaced
        )

        if fontdata then
          core.log("Loaded in %s: %s", field, fontdata.path)
          table.insert(found_fonts, renderer.font.load(
            fontdata.path, size * SCALE, font.options or {}
          ))
        else
          core.error(
            "Could not find a font matching: %s, %s",
            font.name, font.style
          )
        end
        coroutine.yield()
      end

      if #found_fonts > 0 then
        t[field] = renderer.font.group(found_fonts)
      end
    end)
  end
end

fontseek.cache = fontcache
fontseek.load = load_fonts


return fontseek
