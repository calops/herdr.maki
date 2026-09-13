# herdr.maki

[Herdr](https://herdr.dev) integration for [maki](https://maki.sh), packaged as
a maki Lua package.

Two things, one per module:

- **Lifecycle state reporting.** Herdr shows every pane's agent as `idle`,
  `working`, or `blocked`. Instead of letting Herdr scrape maki's status bar,
  this reports the real thing from maki's own event stream.
- **herdr-link/1 gateway.** Cross-agent messaging, peer discovery, and agent
  start/close, driven from inside a Herdr pane, plus a `/herdr` command.

## Install

```lua
maki.pack.add({
  { src = "https://github.com/calops/herdr.maki", version = "v1.0.0" },
})
```

Maki shows the install prompt before the UI starts, then records the resolved
commit in `pack-lock.json`. Commit that file to pin the revision on other
machines. Permission requests in `plugin.toml` are approved separately.

## Layout

```
plugin/herdr.lua         entry file; requires the modules below
lua/herdr/cli.lua        environment gate + herdr CLI transport (shared)
lua/herdr/lifecycle.lua  lifecycle state reporting
lua/herdr/link.lua       herdr-link/1 gateway: `herdr_link` tool, /herdr
lua/herdr/util.lua       two tiny helpers
plugin.toml              permission requests
```

## Permissions

| Permission | Used for |
| --- | --- |
| `env` | reading `HERDR_ENV`, `HERDR_BIN_PATH`, `HERDR_PANE_ID` |
| `run` | driving the `herdr` CLI |
| `fs_read` | reading `<cwd>/.agents/agent_config.json` for a configured `herdr_link_start` |

No file writes and no network. Outside a Herdr-managed pane every module
returns early, so the package registers nothing and does nothing.

## Lifecycle reporting

| maki `SessionStatusChanged` | Herdr state |
| --- | --- |
| `working` | `working` |
| `needs_input` | `blocked` |
| `idle` | `idle` |

Sent as `herdr pane report-agent --source custom:maki --agent maki`. A
reporting source is authoritative: while it is live, Herdr does not also apply
its screen manifest for that pane, so detection stops depending on the layout
of the status bar, the permission dialog, or the plan-complete form.

Notes on the design:

- **One pane, one state.** A maki process can host several sessions and Herdr
  tracks one agent per pane, so the reporter publishes the most demanding state
  across live sessions: `blocked` beats `working` beats `idle`. A background
  session waiting on input still marks the pane as blocked. When blocked, the
  session's title travels along as `--message`.
- **No `--seq`, deliberately.** Reports go through `herdr.cli.run`, which waits
  for the CLI to exit, so one reporter cannot deliver its own reports out of
  order. That also means no counter to persist across `/reload`.
- **Coalesced.** Transitions are debounced by 250 ms, because a turn produces
  several in a row.
- **Release on teardown.** `SessionEnd` reasons `shutdown`, `reload`, `replaced`,
  and `completed` mean the reporter is going away, so it releases the source's
  authority. `reset`, `load`, and `delete` only end one session inside a maki
  that keeps running, so the session is dropped and the state recomputed. The
  release is best effort: a maki that exits is cleared by Herdr when the pane
  occupant goes away, and a `/reload` republishes from the rebuilt host.
- **Seeded at load.** Plugins only run at load, so the reporter seeds from
  `maki.session.live()`. That is also what lets a `/reload` reclaim authority.

### Verify it

From inside the pane:

```bash
herdr agent list
herdr agent explain --verbose
```

`agent explain` reports whether a live source took over or the screen manifest
is still the authority (`fallback_reason`). Transitions are logged to `maki.log`
in `maki.env.logs_dir()`.

## herdr-link/1

`lua/herdr/link.lua` is the cross-agent gateway. It registers one model-facing
tool, `herdr_link`, which activates on first use and then dispatches by
`action`:

| Action | Effect |
| --- | --- |
| *(none)* | activate for this session and list capabilities |
| `start` | start a Herdr agent with Link-managed placement |
| `peers` | list live agents in the same workspace |
| `send` | deliver an inter-agent message or an ordinary reply |
| `close` | close a named agent's pane |

`/herdr` shows the same view to a human: the agent's own name and its live
workspace peers.

## Not included

Session restore. Herdr resumes panes by relaunching an agent with its native
session id, and the launch/resume knowledge for that is per-agent code inside
Herdr rather than something a reporter can supply. The `agent_session`
reference can be reported with `pane report-agent-session`; this package does
not report one.

## Development

`/reload` rebuilds the plugin host in place, so an edit is live immediately:

```bash
maki                 # restart once to install a new package revision
# then inside maki:
/reload
```
