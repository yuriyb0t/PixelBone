-- Minimal JSON encode/decode. Enough for rig data (numbers, strings,
-- booleans, arrays, objects). Empty tables encode as [].

local M = {}

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function esc(s)
  return (s:gsub('[%c"\\]', function(c)
    return ESC[c] or string.format("\\u%04x", c:byte())
  end))
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local function enc(v, out)
  local tv = type(v)
  if tv == "nil" then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    out[#out + 1] = string.format("%.10g", v)
  elseif tv == "string" then
    out[#out + 1] = '"' .. esc(v) .. '"'
  elseif tv == "table" then
    if isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        enc(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = '"' .. esc(k) .. '":'
        enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode " .. tv)
  end
end

function M.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

local UNESC = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or (#s + 1)
end

local function decStr(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("json: unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local n = s:sub(j + 1, j + 1)
      if n == "u" then
        out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16))
        j = j + 6
      else
        out[#out + 1] = UNESC[n] or n
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local dec

dec = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      i = skip(s, i)
      if s:sub(i, i) ~= '"' then error("json: expected string key at " .. i) end
      local k
      k, i = decStr(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("json: expected ':' at " .. i) end
      local v
      v, i = dec(s, i + 1)
      t[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then error("json: expected ',' or '}' at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      local v
      v, i = dec(s, i)
      t[#t + 1] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then error("json: expected ',' or ']' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decStr(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num or num == "" then error("json: unexpected character at " .. i) end
    return tonumber(num), i + #num
  end
end

function M.decode(s)
  local v = dec(s, 1)
  return v
end

return M
