-- Tiny shared helpers. No IO, no Herdr knowledge, no side effects.

local M = {}

-- Return {v} when it is a table, else nil. Used on decoded JSON, where a
-- missing or non-object field must not raise.
function M.as_table(v)
  if type(v) == "table" then
    return v
  end
  return nil
end

-- Return {v} when it is a non-empty string, else nil.
function M.non_empty(v)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

return M
