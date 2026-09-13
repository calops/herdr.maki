-- Lifecycle state reporting for Herdr.
--
-- Herdr shows each pane's agent as idle, working, or blocked, and only falls
-- back to scraping the screen when nothing reports state directly. This module
-- is that reporter: it maps maki's own session status onto Herdr's vocabulary
-- and pushes it with `herdr pane report-agent`, so detection stops depending
-- on how the status bar happens to be drawn.
--
--   maki             Herdr
--   working     ->   working
--   needs_input ->   blocked   (permission prompt, plan-complete form)
--   idle        ->   idle
--
-- The report carries `--source custom:maki`. A reporting source is
-- authoritative, and Herdr does not also apply its screen manifest for the
-- pane while it is live.

local cli = require("herdr.cli")
local util = require("herdr.util")

if not cli.enabled then
  return
end

local SOURCE = "custom:maki"
local AGENT = "maki"

-- A report is a CLI round trip on the maki Lua thread, so keep it short: a
-- wedged Herdr must not park the UI for the control plane's 20 seconds.
local REPORT_TIMEOUT_MS = 1500

-- A teardown release shares one grace period with every other SessionEnd
-- handler, so it gets an even tighter budget.
local RELEASE_TIMEOUT_MS = 750

-- A turn produces several transitions in a row; publish the settled one.
local COALESCE_MS = 250

local TO_HERDR = {
  working = "working",
  needs_input = "blocked",
  idle = "idle",
}

-- Higher wins when the live sessions disagree.
local RANK = { idle = 1, working = 2, blocked = 3 }

-- SessionEnd reasons that mean this pane is losing its reporter. Anything else
-- (reset, load, delete) ends one session inside a maki that keeps running.
local TEARDOWN = {
  shutdown = true,
  reload = true,
  replaced = true,
  completed = true,
}

local sessions = {}
local published_state
local published_message
local pending

-- One pane, one state: a maki process can host several sessions, so report the
-- most demanding state across them. A background session waiting on input
-- still means the pane needs its human.
local function aggregate()
  local state, message = "idle", nil
  for _, session in pairs(sessions) do
    local mapped = TO_HERDR[session.status]
    if mapped and RANK[mapped] > RANK[state] then
      state = mapped
      message = nil
    end
    if mapped == state and state == "blocked" then
      message = util.non_empty(session.title) or message
    end
  end
  return state, message
end

local function publish(force)
  local state, message = aggregate()
  if not force and state == published_state and message == published_message then
    return
  end

  local args = { "pane", "report-agent", cli.pane, "--source", SOURCE, "--agent", AGENT, "--state", state }
  if message then
    args[#args + 1] = "--message"
    args[#args + 1] = message
  end

  local _, code, detail = cli.notify(args, {
    timeout_ms = REPORT_TIMEOUT_MS,
    fallback_code = "REPORT_FAILED",
  })
  if code then
    -- Do not latch: the next transition retries, and Herdr keeps whatever it
    -- already had rather than being told something wrong.
    maki.log.warn("herdr lifecycle: report failed: " .. tostring(detail or code))
    return
  end
  published_state, published_message = state, message
end

local function schedule()
  if pending then
    pending:stop()
  end
  pending = maki.defer_fn(function()
    pending = nil
    publish(false)
  end, COALESCE_MS)
end

-- Best effort by design. A maki that exits is cleared by Herdr when the pane
-- occupant goes away, and a `/reload` republishes from the rebuilt host, so a
-- release that cannot be delivered costs nothing.
local function release()
  published_state, published_message = nil, nil
  local _, code, detail = cli.notify(
    { "pane", "release-agent", cli.pane, "--source", SOURCE, "--agent", AGENT },
    { timeout_ms = RELEASE_TIMEOUT_MS, fallback_code = "RELEASE_FAILED" }
  )
  if code then
    maki.log.info("herdr lifecycle: release skipped: " .. tostring(detail or code))
  end
end

maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    local data = ev.data or {}
    if not data.session_id then
      return
    end
    local session = sessions[data.session_id] or {}
    session.status = data.status
    session.title = data.title
    sessions[data.session_id] = session
    schedule()
  end,
})

maki.api.create_autocmd({ "SessionEnd", "SessionReset" }, {
  callback = function(ev)
    local data = ev.data or {}
    if TEARDOWN[data.reason] then
      release()
      return
    end
    if data.session_id then
      sessions[data.session_id] = nil
    end
    schedule()
  end,
})

-- Plugins only run at load, so seed from the sessions that are already live.
-- That is also what lets a `/reload` reclaim authority for the pane.
maki.defer_fn(function()
  local live, err = maki.session.live()
  if not live then
    maki.log.warn("herdr lifecycle: cannot read live sessions: " .. tostring(err))
    return
  end
  local seeded = {}
  for _, session in ipairs(live) do
    seeded[session.id] = { status = session.status, title = session.title }
  end
  sessions = seeded
  publish(true)
end, 0)

maki.log.info("herdr lifecycle: reporting pane " .. cli.pane .. " as " .. SOURCE)
