# siri-shortcuts

Programmatically create and run Siri Shortcuts with arbitrary third-party App Intents. No Shortcuts.app, no iCloud, no GUI.

```
$ sosumi "check my tailscale vpn status and ask chatgpt to roast it, save to a note"
```

## What this does

- **Discovers** every App Intent from every installed app at runtime
- **Builds** `.shortcut` plists from TOML specs (or natural language via `sosumi`)
- **Executes** workflows by injecting into `/usr/bin/shortcuts` for proper entitlements
- **Chains** arbitrary apps together — Tailscale → ChatGPT → Notes, all in one workflow

## Quick start

```bash
# Install
uv sync

# Build the native injector (required for execution)
cd cli && make && cd ..

# Discover what apps can do
bsiri discover com.openai.chat
bsiri discover io.tailscale

# Generate a TOML spec for an app's intents
bsiri generate io.tailscale --intent GetStatus

# Run a TOML shortcut
bsiri exec examples/tailscale_chatgpt_notes.toml --no-sign

# Or just say what you want (requires CEREBRAS_API_KEY)
export CEREBRAS_API_KEY=your_key_here
sosumi "get my battery level and save it to a note"
```

## Requirements

- macOS Sequoia (15.0+)
- Python 3.12+
- Xcode Command Line Tools (for building the native injector)
- `CEREBRAS_API_KEY` env var (for `sosumi` only)

## Architecture

**Python** handles everything that doesn't need entitlements: intent discovery, TOML compilation, variable rewriting, team identifier resolution, LLM integration.

**Objective-C** handles execution: a dylib injected into `/usr/bin/shortcuts` via `DYLD_INSERT_LIBRARIES` runs workflows through `WFShortcutsAppRunnerClient` inside Apple's entitled process.

```
English prompt → sosumi (LLM generates TOML)
                         ↓
TOML spec → bsiri build (compile to .shortcut plist)
                         ↓
.shortcut → bsiri exec (inject into /usr/bin/shortcuts → WorkflowKit → execute)
                         ↓
                    Output captured
```

## CLI Reference

### bsiri

| Command | Description |
|---------|-------------|
| `bsiri discover [bundle_id]` | List available App Intents |
| `bsiri generate <bundle_id>` | Generate TOML spec from discovered intents |
| `bsiri build <spec.toml>` | Compile TOML to `.shortcut` plist |
| `bsiri exec <spec.toml>` | Build and execute a shortcut |
| `bsiri decompile <file.shortcut>` | Convert `.shortcut` back to TOML |
| `bsiri shortcuts` | List installed shortcuts |

### sosumi

```bash
sosumi "your request in plain English"
sosumi --dry-run "preview the generated TOML"
sosumi --save output.toml --dry-run "save for editing"
```

## TOML Spec Format

```toml
name = "My Shortcut"

# App Intent action
[[action]]
type = "app_intent"
bundle_identifier = "io.tailscale.ipn.macsys"
app_intent_identifier = "GetStatusIntent"
name = "Tailscale"
uuid = "TS-0001"

# Extract entity properties via text action
[[action]]
type = "text"
text = "Connected: <<TS-0001:Status.connected>>\nAccount: <<TS-0001:Status.profileName>>"

# Variables
[[action]]
type = "set_variable"
name = "status"

# Use variables in parameters
[[action]]
type = "app_intent"
bundle_identifier = "com.apple.Notes"
app_intent_identifier = "CreateNoteLinkAction"
name = "Notes"

[action.parameters]
name = "Status Report"
contents = "{{status}}"
```

### Variable syntax

| Syntax | Type | Description |
|--------|------|-------------|
| `{{name}}` | Named variable | References a `set_variable` (rewritten to magic var at build time) |
| `<<UUID:Name>>` | Magic variable | Direct reference to an action's output by UUID |
| `<<UUID:Name.Property>>` | Property access | Extract a property from an entity output |
| `<<UUID:Name['key']>>` | Dictionary access | Get a value from a dictionary output |

### Available action types

`app_intent`, `text`, `detect_text`, `set_variable`, `url`, `get_url`, `get_battery_level`, `date`, `if`/`else`/`endif`, `show_result`, `set_clipboard`, `notification`, `open_app`, `run_shortcut`, `delay`, `repeat_start`/`repeat_end`, `number`, `hash`, `base64_encode`/`base64_decode`, `dictionary`, `get_dictionary_value`, `read_file`, `save_file`, and more.

## Key Discoveries

Things we figured out that aren't documented anywhere:

1. **`WFShortcutsAppRunnerClient` silently no-ops** without entitlements — returns `error=nil` but doesn't execute
2. **Injection into `/usr/bin/shortcuts`** provides the required entitlements for execution
3. **`WFWorkflowRunRequest` must be attached** or the runner treats it as a metadata query
4. **`TeamIdentifier` in `AppIntentDescriptor`** is required for entity-returning intents (hangs forever without it)
5. **`ShowWhenRun: false`** is required for headless execution of entity intents
6. **Entity properties must be extracted via `WFPropertyVariableAggrandizement`** in a text action — `detect_text` hangs on entities
7. **Named variables don't work in the plist runner** — must use magic variables (OutputUUID references)

## License

MIT
