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
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

from openai import OpenAI

from .actions import list_all_actions, list_system_framework_actions, get_team_identifier
from .cli import _build_and_sign, _run_shortcut_file_native, _get_injector_path


CEREBRAS_BASE_URL = "https://api.cerebras.ai/v1"
MODEL = "qwen-3-235b-a22b-instruct-2507"

CACHE_DIR = Path(os.environ.get("SOSUMI_CACHE_DIR", os.path.expanduser("~/.cache/sosumi")))
CACHE_FILE = CACHE_DIR / "intents_cache.json"
DEFAULT_CACHE_TTL = 3600  # 1 hour


def _load_cached_intents(ttl: int = DEFAULT_CACHE_TTL) -> Optional[str]:
    """Load cached intent summary if fresh enough."""
    if not CACHE_FILE.exists():
        return None
    try:
        data = json.loads(CACHE_FILE.read_text())
        if time.time() - data.get("timestamp", 0) < ttl:
            return data["summary"]
    except Exception:
        pass
    return None


def _save_intents_cache(summary: str) -> None:
    """Save intent summary to disk cache."""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps({
            "timestamp": time.time(),
            "summary": summary,
        }))
    except Exception:
        pass


def _get_intents_summary(use_cache: bool = True, ttl: int = DEFAULT_CACHE_TTL) -> str:
    """Get intent summary, using disk cache if available and fresh."""
    if use_cache:
        cached = _load_cached_intents(ttl)
        if cached:
            return cached

    summary = _discover_intents_summary()

    if use_cache:
        _save_intents_cache(summary)

    return summary


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
9. ONLY use App Intents that appear in the AVAILABLE APP INTENTS list below. Do NOT invent or guess intent identifiers, parameters, or entity properties. If you cannot find a suitable intent, say so in a comment at the top of the TOML: `# NOTE: No App Intent available for <what the user asked>`. Then use built-in actions (url + get_url for web APIs, text, etc.) as a fallback, or output a minimal TOML with a show_result explaining what's not possible.
10. Use simple UUIDs like "STEP-0001", "STEP-0002" etc. for readability.
11. Intents whose name starts with "Open" (like OpenWeatherAirQualityIntent, OpenSunriseSunsetIntent) are UI-only: they open the app to a view. They do NOT return data. Do not use them to fetch information.
12. Do NOT hallucinate entity properties. Only use properties that appear in the "Entity properties" section of the available intents list. If no properties are listed for an entity, you cannot extract data from it.
13. NEVER use bundle identifiers com.apple.weather or com.apple.weathercore for data-fetching. Their App Intents only open the Weather app UI. Use the built-in get_current_weather/get_weather_forecast actions instead.
14. get_current_weather and get_weather_forecast accept NO parameters other than location. No forecast_type, no start_date, no end_date. The location field is a TOP-LEVEL field on the action (NOT inside [action.parameters]).

AVAILABLE TOML ACTION TYPES:
- type = "app_intent" — any App Intent (bundle_identifier, app_intent_identifier, name, team_identifier, uuid, [action.parameters])
- type = "text" — compose text with variables: text = "Hello {{var}}" or text = "<<UUID:Name.Property>>"
- type = "detect_text" — coerce previous action's output to text (Bool/Number → String). DO NOT use after entity-returning intents.
- type = "set_variable" — capture previous action output: name = "var_name"
- type = "url" — set a URL: url = "https://..."
- type = "get_url" — fetch the URL from previous action (HTTP GET)
- type = "get_battery_level" — returns battery percentage
- type = "date" — returns current date
- type = "get_current_weather" — returns current weather. Use detect_text after it to get "77°F and Cloudy". Supports [action.location] with latitude/longitude/name/city/state/country.
- type = "get_weather_forecast" — returns weather forecast. Same location support as get_current_weather.
- type = "if" / type = "else" / type = "endif" — conditional. Valid conditions: "Equals", "Contains", "Is Greater Than", "Is Less Than", "Begins With", "Ends With", "Is".
- type = "output" — return a value from the shortcut. This is the ONLY way to return results in headless mode.
- NEVER use type = "show_result" or type = "show_alert" — they HANG FOREVER in headless mode because they need a GUI to present to. If you want to output something, save it to Notes with CreateNoteLinkAction or use the "output" action.
- type = "set_clipboard" / type = "get_clipboard"
- type = "notification" — send a notification (text, title)
- type = "speak_text" — speak text aloud
- type = "calculate" — math (operation = "+"/"-"/"×"/"÷"/"Modulus"/"^", operand = number)
- type = "round_number" — round a number (mode, decimal_places)
- type = "random_number" — generate random number (minimum, maximum)
- type = "calculate_statistics" — stats on a list (operation = "Average"/"Sum"/"Minimum"/"Maximum"/"Median")
- type = "number" — create a number value
- type = "get_current_location" — get device GPS location
- type = "get_directions" — get directions to a location
- type = "get_distance" — distance between locations
- type = "get_travel_time" — travel time estimate
- type = "search_maps" — search Maps (query = "...")
- type = "get_address" — detect street address from text
- type = "play_music" — play music. type = "pause_music" — pause/resume (behavior = "Play"/"Pause"/"Toggle")
- type = "get_current_song" — get now playing. type = "skip_forward" / type = "skip_back"
- type = "create_event" — create calendar event (title, start_date, end_date, location, notes, all_day). Dates accept natural language like "tomorrow at 5:00 PM", "next Monday at 9am", "April 10 at 2:30 PM". Use this built-in action, NOT the Calendar App Intent (which requires entity parameters).
- type = "get_upcoming_events" / type = "find_events" — query calendar
- type = "create_reminder" — create reminder (title, notes). type = "find_reminders"
- type = "get_contacts" / type = "find_contacts" / type = "select_contact"
- type = "phone_number" (number = "...") / type = "email_address" (address = "...")
- type = "send_email" — send email (to, subject, body)
- type = "send_message" — send iMessage
- type = "create_pdf" — convert input to PDF
- type = "rich_text_from_html" / type = "rich_text_from_markdown" / type = "html_from_rich_text" / type = "markdown_from_rich_text"
- type = "get_file" — get a file (path = "...", show_picker = true/false)
- type = "transcribe_audio" — transcribe audio to text
- type = "share" / type = "airdrop"
- type = "match_text" — regex match (pattern = "..."). type = "replace_text" (find, replace_with, regex)
- type = "combine_text" — join list to text (separator). type = "split_text" — split text
- type = "get_item_from_list" — get item by index. type = "list" — create a list
- type = "get_name" / type = "get_type" — get name/type of an item
- type = "run_shortcut" — run another installed shortcut (shortcut_name = "...")
- type = "run_shell_script" — run shell command (script = "..."). Requires Shortcuts security setting.
- type = "run_javascript" — run JS on webpage (script = "...")
- type = "output" — stop and return output from shortcut
- type = "open_app" — open an app (app = "bundle.id"). type = "open_url" — open a URL
- type = "set_appearance" — light/dark mode (style = "Light"/"Dark"/"Toggle")
- type = "lock_screen" / type = "sleep_computer" / type = "restart" / type = "shut_down"
- type = "set_volume" / type = "set_brightness" / type = "set_wifi" / type = "set_bluetooth"
- type = "dictionary" / type = "get_value_for_key" — create/query dictionaries
- type = "base64_encode" / type = "base64_decode"
- type = "hash" — hash text (hash_type = "MD5"/"SHA1"/"SHA256"/"SHA512")
- type = "delay" — wait (time = seconds)
- type = "repeat_start" / type = "repeat_end" — loop (count = N)
- type = "comment" — just a comment (text = "...")

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

EXAMPLE — Weather at a specific location:
```
name = "Weather at Muir Woods"

[[action]]
type = "get_current_weather"

[action.location]
name = "Muir Woods National Monument"
city = "Mill Valley"
state = "California"
country = "United States"
latitude = 37.8912
longitude = -122.5714

[[action]]
type = "detect_text"

[[action]]
type = "set_variable"
name = "weather"

[[action]]
type = "show_result"
text = "Weather at Muir Woods: {{weather}}"
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
    parser.add_argument("--cache", action="store_true", help="Cache discovered intents to disk (skips ~2s scan on repeat runs)")
    parser.add_argument("--refresh-cache", action="store_true", help="Force refresh the intent cache")
    parser.add_argument("--cache-ttl", type=int, default=DEFAULT_CACHE_TTL, help=f"Cache TTL in seconds (default: {DEFAULT_CACHE_TTL})")

    args = parser.parse_args(argv)

    if not args.api_key:
        print("Error: Set CEREBRAS_API_KEY env var or pass --api-key", file=sys.stderr)
        return 1

    # Discover available intents (with optional caching)
    use_cache = args.cache and not args.refresh_cache
    if args.refresh_cache:
        # Force a fresh scan but save to cache
        print("Refreshing intent cache...", file=sys.stderr)
        intents_summary = _get_intents_summary(use_cache=False)
        _save_intents_cache(intents_summary)
    elif args.cache:
        cached = _load_cached_intents(args.cache_ttl)
        if cached:
            print("Using cached App Intents.", file=sys.stderr)
            intents_summary = cached
        else:
            print("Scanning available App Intents (caching for next time)...", file=sys.stderr)
            intents_summary = _get_intents_summary(use_cache=True, ttl=args.cache_ttl)
    else:
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
        print(f"\nError: {e}", file=sys.stderr)
        # Always show the TOML on error so user can debug
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
