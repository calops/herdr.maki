-- Herdr environment gate and CLI transport.
--
-- Every module in this package requires this one. Outside a Herdr-managed pane
-- `enabled` is false, the caller returns early, and the package is a complete
-- no-op.
--
-- Transport is argv arrays only, never a shell: nothing in an argument can be
-- read as a redirect, a pipe, or a substitution. The child inherits maki's
-- environment, which is what gives the Herdr binary the socket path it needs
-- to reach the running server.

local util = require("herdr.util")

local M = {}

M.bin = maki.uv.os_getenv("HERDR_BIN_PATH")
M.pane = maki.uv.os_getenv("HERDR_PANE_ID")
M.enabled = maki.uv.os_getenv("HERDR_ENV") == "1"
  and util.non_empty(M.bin) ~= nil
  and util.non_empty(M.pane) ~= nil

-- Control-plane calls (start, rename, peers) are allowed to take a while.
-- Hot callers pass a shorter timeout.
M.DEFAULT_TIMEOUT_MS = 20000

-- Upstream classifies CLI rejections it has no stable mapping for as opaque
-- CLI errors; the only one the callers branch on is a rename collision.
M.CLI_NAME_TAKEN = "agent_name_taken"

local CLI_CODE_MAP = {
  agent_not_found = "PEER_NOT_FOUND",
  not_in_herdr = "NOT_IN_HERDR",
}

-- Map a structured CLI rejection onto one of our own error codes. Anything
-- that is not a structured rejection returns nil, leaving the caller to decide
-- what a transport failure means for its own operation.
local function classify_cli_error(stdout, stderr, fallback_code)
  for _, out in ipairs({ stdout, stderr }) do
    if util.non_empty(out) then
      local payload = maki.json.decode(out)
      local err = util.as_table(payload) and util.as_table(payload.error)
      local cli_code = err and util.non_empty(err.code)
      if cli_code then
        local detail = util.non_empty(err.message) and (cli_code .. ": " .. err.message) or cli_code
        if cli_code == M.CLI_NAME_TAKEN then
          return M.CLI_NAME_TAKEN, detail
        end
        return CLI_CODE_MAP[cli_code] or fallback_code, detail
      end
    end
  end
  return nil
end

-- Run one Herdr command and wait for it. Returns the job result on success, or
-- `nil, code, detail`; transport failures that are not a structured CLI
-- rejection are NOT_IN_HERDR, never relabelled as an operation failure.
--
-- Waiting is deliberate. These calls are made from autocmd callbacks, where a
-- job handed to the task scope is killed when the dispatch ends, and a job
-- handed to `scope = "plugin"` is killed when the plugin host is rebuilt. It
-- is also what lets the lifecycle reporter drop `--seq`: a serialized caller
-- cannot deliver its own reports out of order.
local function invoke(args, opts)
  opts = opts or {}
  local argv = { M.bin }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end

  local job = maki.fn.jobstart(argv)
  if not job then
    return nil, "NOT_IN_HERDR", "cannot spawn the Herdr binary"
  end
  local res = maki.fn.jobwait(job, opts.timeout_ms or M.DEFAULT_TIMEOUT_MS)
  if not res then
    maki.fn.jobstop(job)
    return nil, "NOT_IN_HERDR", "Herdr did not respond"
  end

  local code, detail = classify_cli_error(res.stdout, res.stderr, opts.fallback_code)
  if code then
    return nil, code, detail
  end
  if res.exit_code ~= 0 then
    return nil, "NOT_IN_HERDR", "the Herdr command failed"
  end
  return res
end

-- Run a command and decode its JSON response.
function M.run(args, opts)
  local res, code, detail = invoke(args, opts)
  if not res then
    return nil, code, detail
  end
  local parsed = maki.json.decode(res.stdout or "")
  if parsed == nil then
    return nil, "NOT_IN_HERDR", "Herdr returned invalid JSON"
  end
  return parsed
end

-- Run a command whose response we do not consume, where success is a zero exit
-- status and no structured rejection. `report-agent` prints its own JSON, and
-- a future version that prints nothing must not read as a failure.
function M.notify(args, opts)
  local res, code, detail = invoke(args, opts)
  if not res then
    return nil, code, detail
  end
  return true
end

return M
