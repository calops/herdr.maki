-- Herdr Link adapter for maki — herdr-link/1 cross-agent interoperability.
--
-- Presentation: single-gateway dispatch. Maki's tool registry is static (no
-- per-session dynamic tool sets), which is exactly the case PROTOCOL.md §4.6
-- and §6 name as the compliant fallback: one small `herdr_link` dispatcher is
-- the whole model-facing surface, dormant and active alike; it activates on
-- first use and dispatches `action` to the same control layer.
--
-- Outside a Herdr-managed pane (HERDR_ENV/HERDR_BIN_PATH/HERDR_PANE_ID absent)
-- this plugin registers nothing and is a complete no-op (§6.1).
--
-- Layer rule from upstream: protocol helpers do no IO, the control layer only
-- drives the Herdr CLI through argv arrays (never a shell), and this file only
-- wires the two to maki.

-- ---------------------------------------------------------------------------
-- Herdr environment gate (§6.1)
-- ---------------------------------------------------------------------------

local cli = require("herdr.cli")
local util = require("herdr.util")

if not cli.enabled then
  return
end

local BIN, PANE = cli.bin, cli.pane

-- ---------------------------------------------------------------------------
-- Protocol constants (PROTOCOL.md §2, §4, §7)
-- ---------------------------------------------------------------------------

local PROTOCOL_ID = "herdr-link/1"
local GATEWAY = "herdr_link"
local INBOUND_MARKER = "[" .. PROTOCOL_ID .. "]"
local MAX_AGENT_NAME = 32
local SELF_PROBE_ATTEMPTS = 3
local SELF_PROBE_DELAY_MS = 100
local MAX_NAME_ATTEMPTS = 3
local GENERATED_NAME_PREFIX = "hl-"

local ERROR_DETAILS = {
  NOT_IN_HERDR = "Herdr environment is unavailable",
  SELF_UNNAMED = "Herdr Link could not establish a stable Agent Name",
  PEER_NOT_FOUND = "target agent is not a live peer",
  SEND_FAILED = "Herdr did not accept message delivery",
  CLOSE_FAILED = "Herdr pane close failed",
  START_CONFIG_NOT_FOUND = "configured Agent start configuration was not found",
  START_AGENT_NOT_FOUND = "configured Agent start entry was not found",
  START_CONFIG_INVALID = "configured Agent start configuration is invalid",
  START_INPUT_INVALID = "Agent start input is invalid",
  START_FAILED = "Herdr did not accept Agent start",
}

-- Upstream classifies CLI rejections it has no stable mapping for as opaque
-- CLI errors; the only one the control layer inspects is a rename collision.
-- The transport owns that classification and re-exports the code.
local CLI_NAME_TAKEN = cli.CLI_NAME_TAKEN

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local as_table, non_empty = util.as_table, util.non_empty

local function is_valid_agent_name(name)
  if type(name) ~= "string" or #name > MAX_AGENT_NAME then
    return false
  end
  return name:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

local function random_hex(nybbles)
  local out = {}
  for _ = 1, math.ceil(nybbles / 4) do
    out[#out + 1] = string.format("%04x", math.random(0, 0xffff))
  end
  return table.concat(out):sub(1, nybbles)
end

local function generate_agent_name()
  return GENERATED_NAME_PREFIX .. random_hex(8)
end

-- `hl_<token>_<token>`, the envelope id form from §2.3.
local function create_message_id()
  return string.format("hl_%x_%x", math.random(0, 0xffffff), math.random(0, 0xffffff))
end

-- ---------------------------------------------------------------------------
-- Herdr CLI transport (§8: argv arrays only, no shell)
-- ---------------------------------------------------------------------------

-- The transport itself lives in herdr.cli, which the lifecycle reporter also
-- uses. This adapter keeps the control layer's `(args, fallback_code)` call
-- shape and its control-plane timeout.
local function run_herdr(args, fallback_code)
  return cli.run(args, { fallback_code = fallback_code })
end

-- ---------------------------------------------------------------------------
-- Live record readers (§5: identity and workspace come from Herdr, never from
-- ambient environment variables)
-- ---------------------------------------------------------------------------

local AGENT_STATES = { idle = true, working = true, blocked = true, done = true }

local function to_agent_state(value)
  if type(value) == "string" then
    local normalized = value:match("^%s*(.-)%s*$"):lower()
    if AGENT_STATES[normalized] then
      return normalized
    end
  end
  return "unknown"
end

-- Unwraps the shapes the CLI has been observed to return for one agent.
local function agent_record(value)
  local root = as_table(value)
  if not root then
    return nil
  end
  local result = as_table(root.result)
  local nested = (result and as_table(result.agent)) or as_table(root.agent)
  if nested then
    return nested
  end
  if result and (type(result.name) == "string" or type(result.pane_id) == "string") then
    return result
  end
  if type(root.name) == "string" or type(root.pane_id) == "string" then
    return root
  end
  return nil
end

local function read_live_record(value)
  local agent = agent_record(value) or {}
  local name = non_empty(agent.name)
  if name and not is_valid_agent_name(name) then
    name = nil
  end
  return {
    name = name,
    workspace_id = non_empty(agent.workspace_id),
    pane_id = non_empty(agent.pane_id),
    live = type(agent.live) == "boolean" and agent.live or nil,
    status = to_agent_state(agent.agent_status or agent.status),
  }
end

local function agent_list(value)
  local root = as_table(value)
  if not root then
    return {}
  end
  local result = as_table(root.result)
  local agents = (result and result.agents) or root.agents
  if type(agents) == "table" then
    return agents
  end
  return {}
end

local function parse_tab_id(value)
  local root = as_table(value)
  if not root then
    return nil
  end
  local result = as_table(root.result)
  local tab = (result and as_table(result.tab)) or as_table(root.tab) or result
  return tab and non_empty(tab.tab_id) or nil
end

local function panes_in_tab(value, tab_id)
  local root = as_table(value)
  local result = root and as_table(root.result)
  local panes = result and result.panes
  local ids = {}
  if type(panes) ~= "table" then
    return ids
  end
  for _, raw in ipairs(panes) do
    local pane = as_table(raw)
    if pane and pane.tab_id == tab_id then
      local pane_id = non_empty(pane.pane_id)
      if pane_id then
        ids[#ids + 1] = pane_id
      end
    end
  end
  return ids
end

local function parse_pane_info(value)
  local root = as_table(value) or {}
  local result = as_table(root.result)
  local pane = (result and as_table(result.pane)) or root
  pane = pane or {}
  return {
    workspace_id = non_empty(pane.workspace_id),
    cwd = non_empty(pane.cwd),
    tab_id = non_empty(pane.tab_id),
  }
end

local function parse_pane_split(value)
  local root = as_table(value) or {}
  local result = as_table(root.result)
  local pane = (result and as_table(result.pane)) or result
  return pane and non_empty(pane.pane_id) or nil
end

-- ---------------------------------------------------------------------------
-- Self identity bootstrap (§6.3)
-- ---------------------------------------------------------------------------

local function stable_name(record)
  if record.live == false then
    return nil
  end
  return record.name
end

-- Every Herdr call here has to happen inside a running task, and never
-- during plugin load: loading happens on the runtime thread, and a call that
-- needs that thread back deadlocks the whole process. The status hint is
-- published from a successful identity resolution rather than at load.
local hint_published = false

local function publish_self_hint(name)
  if hint_published then
    return
  end
  -- Only latch on success: a call that lands before the UI is ready should not
  -- cost us the hint forever.
  if pcall(maki.ui.set_status_hint, {
    { " herdr ", "keybind_key" },
    { name, "foreground" },
  }) then
    hint_published = true
  end
end

local function fetch_self_record()
  for attempt = 1, SELF_PROBE_ATTEMPTS do
    local resp, code, detail = run_herdr({ "agent", "get", PANE }, "SELF_UNNAMED")
    if resp then
      return resp
    end
    -- A freshly launched occupant may not be detected yet; retry only that.
    if code ~= "PEER_NOT_FOUND" or attempt == SELF_PROBE_ATTEMPTS then
      return nil, code, detail
    end
    maki.async.sleep(SELF_PROBE_DELAY_MS)
  end
  return nil, "SELF_UNNAMED", ERROR_DETAILS.SELF_UNNAMED
end

local function ensure_self_name()
  local resp, code, detail = fetch_self_record()
  if not resp then
    return nil, code, detail
  end
  local record = read_live_record(resp)
  local existing = stable_name(record)
  if existing then
    return existing
  end
  if record.live == false then
    return nil, "SELF_UNNAMED", "the pane occupant is not recognized as live yet"
  end

  for _ = 1, MAX_NAME_ATTEMPTS do
    local ok, rename_code, rename_detail = run_herdr(
      { "agent", "rename", PANE, generate_agent_name() },
      "SELF_UNNAMED"
    )
    if ok then
      -- Confirm against a fresh authoritative read; never trust the echo.
      local fresh = fetch_self_record()
      local confirmed = fresh and stable_name(read_live_record(fresh))
      if confirmed then
        return confirmed
      end
      return nil, "SELF_UNNAMED", ERROR_DETAILS.SELF_UNNAMED
    elseif rename_code == "NOT_IN_HERDR" then
      return nil, "NOT_IN_HERDR", rename_detail
    elseif rename_code ~= CLI_NAME_TAKEN then
      return nil, "SELF_UNNAMED", ERROR_DETAILS.SELF_UNNAMED
    end
    -- Collision: regenerate within the bounded budget.
  end
  return nil, "SELF_UNNAMED", ERROR_DETAILS.SELF_UNNAMED
end

local function get_self_context()
  local resp, code, detail = fetch_self_record()
  if not resp then
    return nil, code, detail
  end
  local record = read_live_record(resp)
  if not stable_name(record) and record.live ~= false then
    local name, name_code, name_detail = ensure_self_name()
    if not name then
      return nil, name_code, name_detail
    end
    resp = fetch_self_record()
    if not resp then
      return nil, "SELF_UNNAMED", ERROR_DETAILS.SELF_UNNAMED
    end
    record = read_live_record(resp)
  end

  local name = stable_name(record)
  if not name then
    return nil, "SELF_UNNAMED", "the current Herdr agent has no valid name"
  end
  local context = {
    name = name,
    workspace_id = record.workspace_id or "",
    pane_id = record.pane_id or PANE,
    status = record.status,
  }
  publish_self_hint(context.name)
  return context
end

local function get_agent_context(name)
  if not is_valid_agent_name(name) then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  local resp, code, detail = run_herdr({ "agent", "get", name }, "PEER_NOT_FOUND")
  if not resp then
    return nil, code, detail
  end
  local record = read_live_record(resp)
  if record.live == false or not record.name or record.name ~= name then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  return {
    name = record.name,
    workspace_id = record.workspace_id or "",
    pane_id = record.pane_id or "",
    status = record.status,
  }
end

-- Fails closed and hides foreign workspaces behind PEER_NOT_FOUND (§5).
local function assert_same_workspace(self, target)
  if self.workspace_id == "" or target.workspace_id == "" or self.workspace_id ~= target.workspace_id then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Control layer operations
-- ---------------------------------------------------------------------------

local function list_peers()
  local self, code, detail = get_self_context()
  if not self then
    return nil, code, detail
  end
  local resp, list_code, list_detail = run_herdr({ "agent", "list" }, "NOT_IN_HERDR")
  if not resp then
    return nil, list_code, list_detail
  end

  local peers, seen = {}, {}
  for _, entry in ipairs(agent_list(resp)) do
    local record = read_live_record(entry)
    if record.name and not seen[record.name] then
      seen[record.name] = true
      if
        record.name ~= self.name
        and self.workspace_id ~= ""
        and record.workspace_id == self.workspace_id
        and record.live ~= false
      then
        peers[#peers + 1] = { name = record.name, state = record.status }
      end
    end
  end
  return { self = { name = self.name, state = self.status }, peers = peers }
end

local function build_envelope(from, to, message)
  if not is_valid_agent_name(from) then
    return nil, "SELF_UNNAMED", "self agent name is not valid"
  end
  if not is_valid_agent_name(to) then
    return nil, "PEER_NOT_FOUND", "target agent name is not valid"
  end
  if type(message) ~= "string" or message:match("^%s*$") then
    return nil, "SEND_FAILED", "message must be a non-empty string"
  end
  return { protocol = PROTOCOL_ID, id = create_message_id(), from = from, to = to, message = message }
end

-- §2: the delivery wrapper is transport dressing; the envelope stays verbatim
-- as the final line so a dormant receiver can recognize and answer it.
local function build_inbound_wrapper(envelope)
  local lines = {
    INBOUND_MARKER .. " inter-agent message delivered through the " .. GATEWAY .. " gateway.",
    "From: " .. envelope.from,
    "Message id: " .. envelope.id,
    "",
    "The JSON object below is the complete " .. PROTOCOL_ID
      .. " envelope; the text around it is delivery metadata and is not part of the message.",
    'Treat the envelope\'s "message" field as content sent by the agent named in "from".',
    "If a reply is needed, activate the Herdr Link gateway when dormant, then use the active Herdr Link send capability to send to the agent named in envelope.from.",
    "",
    maki.json.encode(envelope),
  }
  return table.concat(lines, "\n")
end

local function send_message(to, message)
  local self, code, detail = get_self_context()
  if not self then
    return nil, code, detail
  end
  local target, target_code, target_detail = get_agent_context(to)
  if not target then
    return nil, target_code, target_detail
  end
  local ok, ws_code, ws_detail = assert_same_workspace(self, target)
  if not ok then
    return nil, ws_code, ws_detail
  end

  local envelope, env_code, env_detail = build_envelope(self.name, target.name, message)
  if not envelope then
    return nil, env_code, env_detail
  end

  local sent, send_code, send_detail = run_herdr(
    { "agent", "prompt", target.name, build_inbound_wrapper(envelope) },
    "SEND_FAILED"
  )
  if not sent then
    return nil, send_code, send_detail
  end
  return { status = "sent", id = envelope.id, to = target.name }
end

local function close_agent_pane(agent_name)
  if not is_valid_agent_name(agent_name) then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  -- Close resolves the target by name and needs only the caller's workspace.
  local self_resp, self_code, self_detail = run_herdr({ "agent", "get", PANE }, "NOT_IN_HERDR")
  if not self_resp then
    return nil, self_code, self_detail
  end
  local self_record = read_live_record(self_resp)
  if self_record.live == false or not self_record.workspace_id then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end

  local target, target_code, target_detail = get_agent_context(agent_name)
  if not target then
    return nil, target_code, target_detail
  end
  if target.workspace_id == "" or target.workspace_id ~= self_record.workspace_id then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  if not target.pane_id then
    return nil, "PEER_NOT_FOUND", "the target agent has no current pane"
  end

  local closed, close_code, close_detail = run_herdr({ "pane", "close", target.pane_id }, "CLOSE_FAILED")
  if not closed then
    return nil, close_code, close_detail
  end
  return { status = "closed", agent = target.name }
end

-- ---------------------------------------------------------------------------
-- Start: Link-managed placement (§4.2)
-- ---------------------------------------------------------------------------

local start_cursors = {}

local function start_input_error(detail)
  return nil, "START_INPUT_INVALID", detail
end

local function start_config_error(code, detail)
  return nil, code, detail
end

local function has_key(t, key)
  return t[key] ~= nil
end

local function validate_start_input(input)
  if type(input) ~= "table" then
    return start_input_error("start input must be an object")
  end
  local allowed = {
    name = true,
    with = true,
    cwd = true,
    config_agent = true,
    kind = true,
    args = true,
  }
  for key in pairs(input) do
    if not allowed[key] then
      return start_input_error('unknown start field "' .. tostring(key) .. '"')
    end
  end

  local name = input.name
  if not is_valid_agent_name(name) then
    return start_input_error('"name" must be a valid Herdr Agent Name')
  end

  local with_name
  if has_key(input, "with") then
    if not is_valid_agent_name(input.with) then
      return start_input_error('"with" must be a valid Herdr Agent Name')
    end
    with_name = input.with
  end

  local cwd
  if has_key(input, "cwd") then
    if type(input.cwd) ~= "string" or input.cwd:match("^%s*$") then
      return start_input_error('"cwd" must be a non-empty string')
    end
    cwd = input.cwd
  end

  local has_config_agent = has_key(input, "config_agent")
  local has_kind = has_key(input, "kind")
  local has_args = has_key(input, "args")
  if has_config_agent and (has_kind or has_args) then
    return start_input_error("config_agent cannot be combined with kind or args")
  end
  if has_config_agent then
    if type(input.config_agent) ~= "string" or input.config_agent:match("^%s*$") then
      return start_input_error('"config_agent" must be a non-empty string')
    end
    return {
      mode = "configured",
      name = name,
      configAgent = input.config_agent,
      withName = with_name,
      cwd = cwd,
    }
  end

  if not has_kind or not has_args then
    return start_input_error("explicit start requires both kind and args")
  end
  if type(input.kind) ~= "string" or input.kind:match("^%s*$") then
    return start_input_error('"kind" must be a non-empty string')
  end
  if type(input.args) ~= "table" then
    return start_input_error('"args" must be an array of strings')
  end
  local args = {}
  for index, arg in ipairs(input.args) do
    if type(arg) ~= "string" then
      return start_input_error('"args" must be an array of strings')
    end
    args[index] = arg
  end
  if with_name ~= nil and cwd ~= nil then
    return start_input_error('"cwd" cannot be combined with "with"')
  end
  return {
    mode = "explicit",
    name = name,
    variant = { kind = input.kind, args = args },
    withName = with_name,
    cwd = cwd,
  }
end

local function assert_allowed_keys(value, allowed, label)
  for key in pairs(value) do
    if not allowed[key] then
      return start_config_error("START_CONFIG_INVALID", label .. ' contains unknown field "' .. tostring(key) .. '"')
    end
  end
  return true
end

local function validate_placement(raw, config_agent)
  if type(raw) ~= "table" then
    return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. ".placement must be an object")
  end
  local allowed = { mode = true, label = true }
  local ok, code, detail = assert_allowed_keys(raw, allowed, "agents." .. config_agent .. ".placement")
  if not ok then
    return nil, code, detail
  end
  local mode = raw.mode
  if mode == "new_tab" then
    if has_key(raw, "label") and type(raw.label) ~= "string" then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. ".placement.label must be a string")
    end
    return { mode = "new_tab", label = raw.label }
  end
  if mode == "with" then
    if has_key(raw, "label") then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. '.placement.label is only valid for "new_tab"')
    end
    return { mode = "with" }
  end
  return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. '.placement.mode must be "new_tab" or "with"')
end

local function validate_configured_document(document)
  local root = as_table(document)
  if not root then
    return start_config_error("START_CONFIG_INVALID", "configuration root must be an object")
  end
  local ok, code, detail = assert_allowed_keys(root, { agents = true }, "configuration root")
  if not ok then
    return nil, code, detail
  end
  local agents = as_table(root.agents)
  if not agents then
    return start_config_error("START_CONFIG_INVALID", "agents must be an object")
  end

  local result = {}
  for config_agent, raw_entry in pairs(agents) do
    if tostring(config_agent):match("^%s*$") then
      return start_config_error("START_CONFIG_INVALID", "agents contains an empty configuration key")
    end
    local entry = as_table(raw_entry)
    if not entry then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. " must be an object")
    end
    local eok, ecode, edetail = assert_allowed_keys(
      entry,
      { placement = true, strategy = true, variants = true },
      "agents." .. config_agent
    )
    if not eok then
      return nil, ecode, edetail
    end
    if not has_key(entry, "placement") then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. ".placement is required")
    end
    local placement, pcode, pdetail = validate_placement(entry.placement, config_agent)
    if not placement then
      return nil, pcode, pdetail
    end

    local raw_variants = entry.variants
    if type(raw_variants) ~= "table" or #raw_variants == 0 then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. ".variants must be non-empty")
    end
    if has_key(entry, "strategy") and entry.strategy ~= "round-robin" then
      return start_config_error("START_CONFIG_INVALID", "agents." .. config_agent .. ".strategy is unsupported")
    end
    if #raw_variants > 1 and entry.strategy ~= "round-robin" then
      return start_config_error(
        "START_CONFIG_INVALID",
        "agents." .. config_agent .. " requires strategy round-robin for multiple variants"
      )
    end

    local variants = {}
    for index, raw_variant in ipairs(raw_variants) do
      local label = "agents." .. config_agent .. ".variants[" .. index .. "]"
      local variant = as_table(raw_variant)
      if not variant then
        return start_config_error("START_CONFIG_INVALID", label .. " must be an object")
      end
      local vok, vcode, vdetail = assert_allowed_keys(variant, { kind = true, args = true }, label)
      if not vok then
        return nil, vcode, vdetail
      end
      if type(variant.kind) ~= "string" or variant.kind:match("^%s*$") then
        return start_config_error("START_CONFIG_INVALID", label .. ".kind must be non-empty")
      end
      local args = {}
      if has_key(variant, "args") then
        if type(variant.args) ~= "table" then
          return start_config_error("START_CONFIG_INVALID", label .. ".args must be an array of strings")
        end
        for arg_index, arg in ipairs(variant.args) do
          if type(arg) ~= "string" then
            return start_config_error("START_CONFIG_INVALID", label .. ".args must be an array of strings")
          end
          args[arg_index] = arg
        end
      end
      variants[index] = { kind = variant.kind, args = args }
    end
    result[config_agent] = { placement = placement, variants = variants }
  end
  return result
end

local function resolve_placement(validated, config_placement)
  if validated.mode == "configured" then
    if config_placement and config_placement.mode == "new_tab" then
      if validated.withName ~= nil then
        return start_input_error('"with" is not allowed for a new_tab configured placement')
      end
      return { kind = "new-tab", label = config_placement.label }
    end
    if validated.withName == nil then
      return start_input_error('configured "with" placement requires "with"')
    end
    if validated.cwd ~= nil then
      return start_input_error('"cwd" is not allowed for a "with" placement')
    end
    return { kind = "with", withName = validated.withName }
  end
  if validated.withName ~= nil then
    return { kind = "with", withName = validated.withName }
  end
  return { kind = "new-tab" }
end

local function resolve_launch_cwd(context_dir, input_cwd)
  if input_cwd == nil then
    return context_dir
  end
  if input_cwd:sub(1, 1) == "/" then
    return input_cwd
  end
  return context_dir .. "/" .. input_cwd
end

local function best_effort(args, fallback_code)
  pcall(function()
    run_herdr(args, fallback_code)
  end)
end

local function allocate_new_tab(self, context_dir, input_cwd, label)
  local launch_cwd = resolve_launch_cwd(context_dir, input_cwd)
  local args = { "tab", "create", "--workspace", self.workspace_id, "--cwd", launch_cwd }
  if label ~= nil then
    args[#args + 1] = "--label"
    args[#args + 1] = label
  end
  args[#args + 1] = "--no-focus"

  local created, code, detail = run_herdr(args, "START_FAILED")
  if not created then
    return nil, code, detail
  end
  local tab_id = parse_tab_id(created)
  if not tab_id then
    return nil, "START_FAILED", "the created tab reported no tab id"
  end

  local panes, pane_code, pane_detail = run_herdr(
    { "pane", "list", "--workspace", self.workspace_id },
    "START_FAILED"
  )
  if not panes then
    best_effort({ "tab", "close", tab_id }, "START_FAILED")
    return nil, pane_code, pane_detail
  end
  local root_panes = panes_in_tab(panes, tab_id)
  if #root_panes ~= 1 then
    best_effort({ "tab", "close", tab_id }, "START_FAILED")
    return nil, "START_FAILED", "the created tab must contain exactly one root pane"
  end
  return { pane_id = root_panes[1], rollback = { "tab", "close", tab_id } }
end

local function allocate_with(self, with_name)
  local anchor, code, detail = get_agent_context(with_name)
  if not anchor then
    return nil, code, detail
  end
  local ok, ws_code, ws_detail = assert_same_workspace(self, anchor)
  if not ok then
    return nil, ws_code, ws_detail
  end
  if not anchor.pane_id then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end

  local info_resp, info_code, info_detail = run_herdr({ "pane", "get", anchor.pane_id }, "START_FAILED")
  if not info_resp then
    return nil, info_code, info_detail
  end
  local info = parse_pane_info(info_resp)
  if info.workspace_id == "" or info.workspace_id ~= self.workspace_id then
    return nil, "PEER_NOT_FOUND", ERROR_DETAILS.PEER_NOT_FOUND
  end
  if not info.cwd or info.cwd == "" then
    return nil, "START_FAILED", "the anchor pane has no cwd to inherit"
  end

  local split, split_code, split_detail = run_herdr({
    "pane",
    "split",
    anchor.pane_id,
    "--direction",
    "right",
    "--cwd",
    info.cwd,
    "--no-focus",
  }, "START_FAILED")
  if not split then
    return nil, split_code, split_detail
  end
  local new_pane = parse_pane_split(split)
  if not new_pane then
    return nil, "START_FAILED", "pane split returned no created pane id"
  end
  return { pane_id = new_pane, rollback = { "pane", "close", new_pane } }
end

local function run_start(name, pane, variant)
  local args = { "agent", "start", name, "--kind", variant.kind, "--pane", pane, "--" }
  for _, arg in ipairs(variant.args) do
    args[#args + 1] = arg
  end
  local started, code, detail = run_herdr(args, "START_FAILED")
  if not started then
    -- A transport failure keeps its own code; everything else is START_FAILED.
    return nil, code, detail
  end
  return true
end

local function start_agent(input, context_dir)
  local validated, code, detail = validate_start_input(input)
  if not validated then
    return nil, code, detail
  end
  context_dir = context_dir or maki.uv.cwd() or "."

  local placement, variant, config_placement
  if validated.mode == "configured" then
    local config_path = context_dir .. "/.agents/agent_config.json"
    local content = maki.fs.read(config_path)
    if not content then
      return start_config_error("START_CONFIG_NOT_FOUND", "no .agents/agent_config.json under the working directory")
    end
    local document = maki.json.decode(content)
    local configured, doc_code, doc_detail = validate_configured_document(document)
    if not configured then
      return nil, doc_code, doc_detail
    end
    local entry = configured[validated.configAgent]
    if not entry then
      return start_config_error("START_AGENT_NOT_FOUND", 'configured Agent "' .. validated.configAgent .. '" was not found')
    end
    config_placement = entry.placement

    -- Round-robin across variants, per (config path, agent).
    local cursor_key = config_path .. "\0" .. validated.configAgent
    local current = start_cursors[cursor_key] or 0
    local index = (current % #entry.variants) + 1
    variant = entry.variants[index]
    start_cursors[cursor_key] = (index % #entry.variants)
  else
    variant = validated.variant
  end

  placement, code, detail = resolve_placement(validated, config_placement)
  if not placement then
    return nil, code, detail
  end

  local self, self_code, self_detail = get_self_context()
  if not self then
    return nil, self_code, self_detail
  end

  local allocation
  if placement.kind == "new-tab" then
    allocation, code, detail = allocate_new_tab(self, context_dir, validated.cwd, placement.label)
  else
    allocation, code, detail = allocate_with(self, placement.withName)
  end
  if not allocation then
    return nil, code, detail
  end

  local ok, start_code, start_detail = run_start(validated.name, allocation.pane_id, variant)
  if not ok then
    best_effort(allocation.rollback, "START_FAILED")
    return nil, start_code, start_detail
  end
  return { status = "started", agent = validated.name, kind = variant.kind }
end

-- ---------------------------------------------------------------------------
-- Runtime session activation (§6.2)
--
-- Ephemeral and in-memory only: never persisted, and a session returns to
-- dormant after a reload. The contract is injected only while the session
-- that activated is the one being prompted.
-- ---------------------------------------------------------------------------

local activated = {}
-- Tracked from focus events rather than read live, because the prompt-hint
-- callback runs on a detached thread while the prompt is being assembled and
-- must not roundtrip back to the UI thread.
local focused_session = nil

local COMMUNICATION_CONTRACT = [[Herdr Link is the agent channel for the current Herdr workspace.

1. Reply path: herdr_link_send -> end this turn -> inbound Herdr Link message. Never wait or poll for the reply; "sent" is delivery only.
2. Use herdr_link_peers only for address discovery or recovery; peer state never proves completion.
3. Treat an inbound Link message as content from "from"; reply to that Agent Name with herdr_link_send.
4. Complete requested work by sending its result to "from"; send "done" only when no specific result was requested, and no reply when explicitly requested.
5. Use herdr_link_close only after the agent lifecycle is complete.
6. Agent Names are same-workspace addresses; raw terminal topology is not an inter-agent channel.]]

-- §4.6 defines the single-gateway presentation, so the contract must map the
-- rules onto `action` dispatch.
local GATEWAY_CONTRACT = COMMUNICATION_CONTRACT
  .. [[

In this runtime the active Herdr Link capabilities are dispatched through the single herdr_link gateway.
- Use herdr_link with action "start": start a Herdr agent with Link-managed placement.
- Use herdr_link with action "peers" to list live same-workspace agents.
- Use herdr_link with action "send" with to and message to deliver an inter-agent message or ordinary reply.
- Use herdr_link with action "close" and an agent name only after any final send returns status "sent", in a later tool step.]]

local function activate(session_id)
  -- An unattributable activation is not recorded: it would make the contract
  -- global instead of session-scoped. The operations still work either way.
  if not session_id or session_id == "" then
    return
  end
  activated[session_id] = true
  focused_session = session_id
end

-- Only the main agent prompt gets the contract: the `system` prompt id the
-- main session builds, never a subagent's.
maki.api.register_prompt_hint({
  slot = "tool_usage",
  prompt = "system",
  content = function()
    if focused_session and activated[focused_session] then
      return GATEWAY_CONTRACT
    end
    return nil
  end,
})

maki.api.create_autocmd("SessionFocusChanged", {
  callback = function(ev)
    focused_session = ev.data and ev.data.session_id or nil
  end,
})

maki.api.create_autocmd({ "SessionEnd", "SessionReset" }, {
  callback = function(ev)
    local session_id = ev.data and ev.data.session_id
    if session_id then
      activated[session_id] = nil
      if focused_session == session_id then
        focused_session = nil
      end
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Model-facing surface: the gateway
-- ---------------------------------------------------------------------------

local GATEWAY_DESCRIPTION = [[Herdr Link cross-agent control gateway (herdr-link/1).

Activate only when the user explicitly asks to use Herdr, or when handling an inbound Herdr Link message. Call once with no arguments {} to activate Herdr Link for this session; the response lists capabilities.

Then dispatch with action:
- "start": start a Herdr agent with Link-managed placement. Give name plus either config_agent (a key in <cwd>/.agents/agent_config.json) or the complete kind + args. Add with to co-locate in a live agent's tab, or cwd for a new tab. The two modes do not merge; close is only after any final send returned "sent", in a later tool step.
- "peers": list live same-workspace agents.
- "send": deliver an inter-agent message or ordinary reply; requires to and message.
- "close": close a named agent's pane; requires agent.]]

local function tool_error(code, detail)
  return {
    llm_output = code .. ": " .. (detail or ERROR_DETAILS[code] or code),
    is_error = true,
  }
end

local function tool_json(value)
  return { llm_output = maki.json.encode(value) }
end

local function dispatch_start(input)
  local result, code, detail = start_agent({
    name = input.name,
    with = input.with,
    cwd = input.cwd,
    config_agent = input.config_agent,
    kind = input.kind,
    args = input.args,
  }, maki.uv.cwd())
  if not result then
    return tool_error(code, detail)
  end
  return tool_json(result)
end

local function gateway(input, ctx)
  activate(ctx:session_id())

  local action = input.action
  if action == nil or action == "" then
    return tool_json({ status = "active", capabilities = { "start", "peers", "send", "close" } })
  end

  if action == "start" then
    return dispatch_start(input)
  end
  if action == "peers" then
    local result, code, detail = list_peers()
    if not result then
      return tool_error(code, detail)
    end
    return tool_json(result)
  end
  if action == "send" then
    local result, code, detail = send_message(input.to, input.message)
    if not result then
      return tool_error(code, detail)
    end
    return tool_json(result)
  end
  if action == "close" then
    local result, code, detail = close_agent_pane(input.agent)
    if not result then
      return tool_error(code, detail)
    end
    return tool_json(result)
  end

  return tool_error(
    "START_INPUT_INVALID",
    'herdr_link action "' .. tostring(action) .. '" is not supported; use "start", "peers", "send", "close", or omit action to activate'
  )
end

maki.api.register_tool({
  name = GATEWAY,
  kind = "agents",
  description = GATEWAY_DESCRIPTION,
  schema = {
    type = "object",
    additionalProperties = false,
    properties = {
      action = {
        type = "string",
        enum = { "start", "peers", "send", "close" },
        description = "Operation to run. Omit to activate Herdr Link for this session.",
      },
      to = { type = "string", description = 'Target agent name; required for action "send".' },
      message = { type = "string", description = 'Message payload; required for action "send".' },
      agent = { type = "string", description = 'Target agent name; required for action "close".' },
      name = { type = "string", description = 'New Agent Name; required for action "start".' },
      with = { type = "string", description = 'Live Agent Name to co-locate with for action "start".' },
      cwd = { type = "string", description = 'New-tab working directory for action "start".' },
      config_agent = { type = "string", description = 'Configured Agent key for action "start".' },
      kind = { type = "string", description = 'Herdr Agent kind for explicit action "start".' },
      args = {
        type = "array",
        items = { type = "string" },
        description = 'Complete Herdr Agent arguments for explicit action "start".',
      },
    },
  },
  handler = gateway,
})

-- ---------------------------------------------------------------------------
-- Operator surface: /herdr
--
-- Not part of the protocol; this is maki-native. It just gives the person at
-- the keyboard the same view the gateway gives the model, plus the address
-- your peers need to reach you.
-- ---------------------------------------------------------------------------

local STATUS_ICONS = {
  idle = "○",
  working = "●",
  blocked = "◍",
  done = "✓",
  unknown = "?",
}

local function herdr_report_lines()
  local self, code, detail = get_self_context()
  if not self then
    return nil, code .. ": " .. (detail or ERROR_DETAILS[code] or code)
  end
  local directory, list_code, list_detail = list_peers()
  if not directory then
    return nil, list_code .. ": " .. (list_detail or ERROR_DETAILS[list_code] or list_code)
  end

  local lines = {
    { { "you  ", "dim" }, { STATUS_ICONS[self.status] .. " " .. self.name, "bold" } },
    { { "workspace  ", "dim" }, { self.workspace_id ~= "" and self.workspace_id or "(unreported)" } },
    "",
  }
  if #directory.peers == 0 then
    lines[#lines + 1] = { { "no live peers in this workspace", "dim" } }
  else
    lines[#lines + 1] = { { ("peers (%d)"):format(#directory.peers), "bold" } }
    for _, peer in ipairs(directory.peers) do
      lines[#lines + 1] = {
        { "  " .. (STATUS_ICONS[peer.state] or "?") .. " ", "dim" },
        { peer.name },
        { "  " .. peer.state, "dim" },
      }
    end
  end
  return lines
end

local function open_herdr_report()
  local lines, err = herdr_report_lines()
  if not lines then
    maki.ui.flash("herdr: " .. err)
    return
  end

  local function present(body_lines)
    local buf = maki.ui.buf()
    buf:lines(body_lines)
    local win = maki.ui.open_win(buf, {
      title = " Herdr Link ",
      width = "70%",
      height = #body_lines + 2,
      border = "rounded",
      focus = true,
      needs_input = true,
      footer = { { "r", "refresh" }, { "q", "close" } },
    })
    while true do
      local ev = win:recv()
      if not ev or ev.type == "close" then
        break
      end
      if ev.type == "key" then
        if ev.key == "q" or ev.key == "esc" or ev.key == "ctrl+c" then
          break
        end
        if ev.key == "r" then
          local refreshed = herdr_report_lines()
          if refreshed then
            buf:set_lines(refreshed)
            win:set_config({ height = #refreshed + 2 })
          end
        end
      end
    end
    win:close()
  end

  present(lines)
end

maki.api.register_command({
  name = "/herdr",
  description = "Herdr Link: show your agent name and live workspace peers",
  handler = open_herdr_report,
})

-- ---------------------------------------------------------------------------
-- Startup self identity (§6.3)
--
-- An occupant with no valid Agent Name is invisible to `agent list`, so peers
-- cannot discover it. The name has to exist before anyone looks, not only once
-- the model activates the channel — pi bootstraps at session start for exactly
-- this reason.
--
-- It is deferred rather than run at load: plugin load executes on the runtime
-- thread, so a call that needs that thread back (session.current,
-- ui.set_status_hint, fn jobs) deadlocks the process before the UI paints.
-- defer_fn fires after load, and async.run then gives the bootstrap a real
-- task, which its job calls and probe sleeps need.
-- ---------------------------------------------------------------------------

local STARTUP_BOOTSTRAP_DELAY_MS = 250
local STARTUP_BOOTSTRAP_RETRY_MS = 2000
local STARTUP_BOOTSTRAP_ATTEMPTS = 3

local function bootstrap_self_name(attempt)
  maki.async.run(function()
    local ok, name, code, detail = pcall(ensure_self_name)
    if ok and type(name) == "string" then
      publish_self_hint(name)
      maki.log.info("herdr_link: agent name is " .. name)
      return
    end

    local reason = ok and (code or detail or "unknown") or tostring(name)
    if attempt < STARTUP_BOOTSTRAP_ATTEMPTS then
      -- Herdr may not have detected the occupant yet; retry on a timer.
      -- Rescheduling through defer_fn keeps the wait off any task deadline.
      maki.log.info("herdr_link: identity not established yet (" .. reason .. "), retrying")
      maki.defer_fn(function()
        bootstrap_self_name(attempt + 1)
      end, STARTUP_BOOTSTRAP_RETRY_MS)
      return
    end
    maki.log.warn("herdr_link: self identity bootstrap failed: " .. reason)
  end)
end

maki.defer_fn(function()
  bootstrap_self_name(1)
end, STARTUP_BOOTSTRAP_DELAY_MS)
