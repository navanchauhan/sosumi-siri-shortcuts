#!/usr/bin/env python3
"""sosumi: Natural language → Siri Shortcut → execute.

Uses Cerebras API (qwen-3-235b-a22b-instruct-2507) to generate TOML
shortcut specs from plain English prompts, then builds and runs them.

Usage:
    sosumi "get my tailscale status and save it to a note"
    sosumi "ask chatgpt to write a haiku about monday and save it to notes"
    sosumi --dry-run "check my battery level"
"""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

from openai import OpenAI

from .actions import list_all_actions, list_system_framework_actions, get_team_identifier
from .cli import _build_and_sign, _run_shortcut_file_native, _get_injector_path


CEREBRAS_BASE_URL = "https://api.cerebras.ai/v1"
MODEL = "qwen-3-235b-a22b-instruct-2507"


def _discover_intents_summary() -> str:
    """Build a concise summary of available App Intents for the LLM context."""
    app_actions = list_all_actions()
    fw_actions = list_system_framework_actions()
    all_actions = app_actions + fw_actions

    # Deduplicate
    seen = {}
    for a in all_actions:
        key = (a.bundle_id, a.identifier)
        if key not in seen or (a.title and not seen[key].title):
            seen[key] = a

    # Group by app, keep it concise
    apps: Dict[str, List] = {}
    for a in seen.values():
        app_key = a.app_name or a.bundle_id or "Unknown"
        apps.setdefault(app_key, []).append(a)

    lines = []
    for app_name in sorted(apps.keys()):
        actions = apps[app_name]
        bundle_id = actions[0].bundle_id or ""
        app_path = actions[0].app_path or ""

        # Get team identifier
        tid = get_team_identifier(app_path) if app_path else None
        tid_str = f'  team_identifier = "{tid}"' if tid else ""

        lines.append(f"\n## {app_name} ({bundle_id})")
        if tid:
            lines.append(f"  TeamIdentifier: {tid}")
        for a in actions:
            params = ", ".join(
                f"{p.name}: {p.type or 'Any'}" for p in a.parameters if p.name
            )
            title = a.title or a.identifier or "?"
            lines.append(f"  - {title} (id: {a.identifier}){f' — params: {params}' if params else ''}")
            if a.description:
                lines.append(f"    {a.description[:100]}")

    # Add entity property info for apps that have actionsdata
    for app_name in sorted(apps.keys()):
        actions = apps[app_name]
        for a in actions:
            if not a.source_path or not a.source_path.endswith("actionsdata"):
                continue
            try:
                import json as _json
                with open(a.source_path) as f:
                    adata = _json.load(f)
                for eid, edef in adata.get("entities", {}).items():
                    props = edef.get("properties", [])
                    if props:
                        lines.append(f"\n  Entity {eid} properties:")
                        for p in props:
                            pid = p.get("identifier", "?")
                            ptitle = (p.get("title", {}) or {}).get("key", pid)
                            lines.append(f"    - {pid} ({ptitle})")
                break  # Only need entities once per app
            except Exception:
                pass

    return "\n".join(lines)


SYSTEM_PROMPT = """\
You are a Siri Shortcut generator. Given a user request, output a valid TOML shortcut spec.

IMPORTANT RULES:
1. Output ONLY the TOML content. No markdown fences, no explanation, no preamble. Do not wrap in ```toml fences.
2. Every action that returns an entity (not Bool/String/void) needs its output extracted via a `text` action with property aggrandizements using `<<UUID:Name.PropertyName>>` syntax.
3. For entity-returning App Intents, assign an explicit `uuid` field.
4. Use `set_variable` + `{{name}}` (DOUBLE curly braces, not single!) for passing data between actions — the builder handles the magic variable rewriting. NEVER use single braces {name}.
5. For non-string outputs (Bool, Number), add a `detect_text` action before `set_variable`.
6. Include `team_identifier` for third-party apps (provided in the available intents list).
7. Use `type = "text"` actions to compose multi-variable strings.
8. The `contents` parameter for Notes `CreateNoteLinkAction` is text — pipe through detect_text or text action first.

AVAILABLE TOML ACTION TYPES:
- type = "app_intent" — any App Intent (bundle_identifier, app_intent_identifier, name, team_identifier, uuid, [action.parameters])
- type = "text" — compose text with variables: text = "Hello {{var}}" or text = "<<UUID:Name.Property>>"
- type = "detect_text" — coerce previous action's output to text (Bool/Number → String). DO NOT use after entity-returning intents.
- type = "set_variable" — capture previous action output: name = "var_name"
- type = "url" — set a URL: url = "https://..."
- type = "get_url" — fetch the URL from previous action (HTTP GET)
- type = "get_battery_level" — returns battery percentage
- type = "date" — returns current date
- type = "if" / type = "else" / type = "endif" — conditional (condition = "Equals"/"Contains"/etc, compare_with = "value")
- type = "show_result" — display text to user
- type = "set_clipboard" — copy to clipboard

MAGIC VARIABLE SYNTAX FOR ENTITY PROPERTIES:
When an App Intent returns an entity, extract properties like this:
```
[[action]]
type = "text"
text = "Connected: <<INTENT-UUID:Status.connected>>\\nAccount: <<INTENT-UUID:Status.profileName>>"
```

EXAMPLE — Get Tailscale status and save to Notes:
```
name = "Tailscale Status"

[[action]]
type = "app_intent"
bundle_identifier = "io.tailscale.ipn.macsys"
app_intent_identifier = "GetStatusIntent"
name = "Tailscale"
team_identifier = "W5364U7YZB"
uuid = "TS-STATUS-0001"

[[action]]
type = "text"
text = "Connected: <<TS-STATUS-0001:Status.connected>>\\nAccount: <<TS-STATUS-0001:Status.profileName>>"

[[action]]
type = "set_variable"
name = "status_text"

[[action]]
type = "app_intent"
bundle_identifier = "com.apple.Notes"
app_intent_identifier = "CreateNoteLinkAction"
name = "Notes"

[action.parameters]
name = "Tailscale Status"
contents = "{{status_text}}"
```

EXAMPLE — Ask ChatGPT and save response:
```
name = "ChatGPT Question"

[[action]]
type = "app_intent"
bundle_identifier = "com.openai.chat"
app_intent_identifier = "AskIntent"
name = "ChatGPT"
team_identifier = "KQ8EV22B8N"

[action.parameters]
prompt = "What is the meaning of life?"
newChat = true
continuous = false

[[action]]
type = "set_variable"
name = "response"

[[action]]
type = "app_intent"
bundle_identifier = "com.apple.Notes"
app_intent_identifier = "CreateNoteLinkAction"
name = "Notes"

[action.parameters]
name = "ChatGPT Response"
contents = "{{response}}"
```

AVAILABLE APP INTENTS ON THIS SYSTEM:
$INTENTS$
"""


def generate_toml(prompt: str, api_key: str, intents_summary: str) -> str:
    """Generate TOML shortcut spec from a natural language prompt."""
    client = OpenAI(
        api_key=api_key,
        base_url=CEREBRAS_BASE_URL,
    )

    response = client.chat.completions.create(
        model=MODEL,
        messages=[
            {
                "role": "system",
                "content": SYSTEM_PROMPT.replace("$INTENTS$", intents_summary),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        temperature=0.3,
        max_tokens=4096,
    )

    content = response.choices[0].message.content.strip()

    # Strip markdown fences if present
    if content.startswith("```"):
        lines = content.split("\n")
        # Remove first and last fence lines
        if lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        content = "\n".join(lines)

    return content


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="sosumi",
        description="Natural language → Siri Shortcut → execute",
    )
    parser.add_argument("prompt", help="What you want the shortcut to do")
    parser.add_argument("--dry-run", action="store_true", help="Generate TOML but don't execute")
    parser.add_argument("--show-toml", action="store_true", help="Print the generated TOML")
    parser.add_argument("--timeout", type=float, default=45.0, help="Execution timeout")
    parser.add_argument("--api-key", default=os.environ.get("CEREBRAS_API_KEY"), help="Cerebras API key")
    parser.add_argument("--save", help="Save generated TOML to file")

    args = parser.parse_args(argv)

    if not args.api_key:
        print("Error: Set CEREBRAS_API_KEY env var or pass --api-key", file=sys.stderr)
        return 1

    # Discover available intents
    print("Scanning available App Intents...", file=sys.stderr)
    intents_summary = _discover_intents_summary()

    # Generate TOML
    print(f"Generating shortcut for: {args.prompt}", file=sys.stderr)
    toml_text = generate_toml(args.prompt, args.api_key, intents_summary)

    if args.show_toml or args.dry_run:
        print(toml_text)

    if args.save:
        with open(args.save, "w") as f:
            f.write(toml_text)
        print(f"Saved to {args.save}", file=sys.stderr)

    if args.dry_run:
        return 0

    # Write to temp file and execute
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False, prefix="sosumi_") as f:
        f.write(toml_text)
        toml_path = f.name

    try:
        from .shortcuts_builder.shortcut import Shortcut

        # Build
        print("Building shortcut...", file=sys.stderr)
        with open(toml_path, "rb") as f:
            shortcut = Shortcut.load(f, file_format="toml")

        with tempfile.NamedTemporaryFile(suffix=".shortcut", delete=False, prefix="sosumi_") as f:
            shortcut.dump(f, file_format="shortcut")
            shortcut_path = f.name

        # Execute
        injector = _get_injector_path()
        if not injector:
            print("Error: bsiri_injector.dylib not found. Build with 'make' in cli/", file=sys.stderr)
            return 1

        exit_code, output = _run_shortcut_file_native(shortcut_path, timeout=args.timeout)
        if output:
            print(output)
        return exit_code

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        if args.show_toml:
            return 1
        # Show the TOML so user can debug
        print("\nGenerated TOML:", file=sys.stderr)
        print(toml_text, file=sys.stderr)
        return 1
    finally:
        try:
            os.unlink(toml_path)
        except OSError:
            pass
        try:
            os.unlink(shortcut_path)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
