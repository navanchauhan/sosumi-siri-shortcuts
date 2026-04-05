#!/usr/bin/env python3
"""
bsiri CLI - Proof of concept for discovering and executing App Intents via WorkflowKit/ActionKit.

Commands:
  discover              List all available App Intents from installed apps
  discover <bundle_id>  List intents for a specific app
  run <shortcut_name>   Run an existing shortcut by name
  exec <toml_file>      Build and execute a shortcut from TOML spec
  intent <bundle_id> <intent_id> [params...]  Execute a specific App Intent
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .actions import ActionInfo, list_all_actions, list_system_framework_actions, get_team_identifier
from .native_actions import list_native_actions
from .shortcuts import ShortcutsCLI, ShortcutsError, sign_shortcut, SIGN_METHOD_LOCAL, SIGN_METHOD_HUBSIGN
from .shortcuts_builder.shortcut import Shortcut


def get_native_cli_path() -> Optional[str]:
    """Find the native bsiri CLI binary."""
    # Check relative to this file
    here = Path(__file__).parent.parent / "cli" / "bsiri"
    if here.exists():
        return str(here)
    # Check in PATH
    import shutil
    return shutil.which("bsiri-native")


def cmd_discover(args: argparse.Namespace) -> int:
    """Discover available App Intents from installed apps."""
    bundle_filter = args.bundle_id if hasattr(args, 'bundle_id') else None

    print("Scanning for App Intents...\n")

    # Get app actions
    app_actions = list_all_actions(include_dev=args.include_dev)
    fw_actions = list_system_framework_actions()
    native_actions = list_native_actions()

    all_actions = app_actions + fw_actions

    # Filter by bundle if specified
    if bundle_filter:
        all_actions = [a for a in all_actions if a.bundle_id and bundle_filter.lower() in a.bundle_id.lower()]

    # Deduplicate by (bundle_id, identifier), preferring actions with titles
    seen: Dict[tuple, ActionInfo] = {}
    for a in all_actions:
        key = (a.bundle_id, a.identifier)
        if key not in seen or (a.title and not seen[key].title):
            seen[key] = a
    all_actions = list(seen.values())

    if args.json:
        payload = {
            "app_intents": [a.to_dict() for a in all_actions],
            "native_actions": [a.to_dict() for a in native_actions] if not bundle_filter else [],
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    # Group by app
    apps: Dict[str, List[ActionInfo]] = {}
    for a in all_actions:
        key = f"{a.app_name} ({a.bundle_id})" if a.bundle_id else a.app_name
        apps.setdefault(key, []).append(a)

    for app_key in sorted(apps.keys()):
        actions = apps[app_key]
        print(f"\n{app_key}")
        print("-" * len(app_key))
        for a in actions:
            params = ", ".join(
                f"{p.name}: {p.type or 'Any'}" for p in a.parameters if p.name
            )
            param_str = f"({params})" if params else "()"
            # Show friendly title first, then identifier in parentheses
            friendly_name = a.title or a.identifier or "Unknown"
            intent_id = a.identifier or ""
            if a.title and a.identifier and a.title != a.identifier:
                print(f"  {friendly_name}")
                print(f"    id: {intent_id} {param_str}")
            else:
                print(f"  {friendly_name} {param_str}")
            if a.description:
                print(f"    {a.description[:70]}{'...' if len(a.description) > 70 else ''}")

    if not bundle_filter:
        print(f"\n--- Native Shortcuts Actions ({len(native_actions)}) ---")
        for a in native_actions[:10]:  # Show first 10
            print(f"  {a.title} ({a.source})")
        if len(native_actions) > 10:
            print(f"  ... and {len(native_actions) - 10} more")

    print(f"\nTotal: {len(all_actions)} app intents, {len(native_actions)} native actions")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    """Run an existing shortcut by name."""
    cli = ShortcutsCLI()

    input_data = None
    input_is_text = False

    if args.input_json:
        input_data = json.loads(args.input_json)
    elif args.input_text:
        input_data = args.input_text
        input_is_text = True

    try:
        parsed, raw = cli.run(
            args.name,
            input=input_data,
            input_is_text=input_is_text,
            output_type=args.output_type,
            timeout=args.timeout,
        )
        if args.output_type == "public.json" and parsed:
            print(json.dumps(parsed, indent=2))
        else:
            print(raw or "")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def _build_and_sign(spec_path: Path, output_path: Optional[str] = None, sign: bool = True, sign_mode: str = "people-who-know-me", sign_method: str = SIGN_METHOD_LOCAL) -> Tuple[str, str]:
    """Shared helper: TOML → unsigned .shortcut → signed .shortcut.

    Returns (signed_path_or_unsigned_path, shortcut_name).
    Caller is responsible for cleaning up temp files when *output_path* is None.
    """
    with open(spec_path, "rb") as f:
        shortcut = Shortcut.load(f, file_format="toml")

    sc_name = shortcut.name or spec_path.stem

    if output_path:
        unsigned_path = output_path if not sign else output_path + ".unsigned"
    else:
        fd, unsigned_path = tempfile.mkstemp(prefix="bsiri_", suffix=".shortcut")
        os.close(fd)

    with open(unsigned_path, "wb") as f:
        shortcut.dump(f, file_format="shortcut")

    if not sign:
        return unsigned_path, sc_name

    signed_path = output_path or unsigned_path.replace(".shortcut", ".signed.shortcut")
    try:
        sign_shortcut(unsigned_path, signed_path, mode=sign_mode, method=sign_method)
    except ShortcutsError as e:
        print(f"Warning: signing failed ({e}), falling back to unsigned", file=sys.stderr)
        if output_path and unsigned_path != output_path:
            os.rename(unsigned_path, output_path)
            return output_path, sc_name
        return unsigned_path, sc_name

    # Clean up the unsigned temp if we created it
    if unsigned_path != signed_path:
        try:
            os.unlink(unsigned_path)
        except OSError:
            pass
    return signed_path, sc_name


def cmd_build(args: argparse.Namespace) -> int:
    """Build (and optionally sign) a .shortcut from a TOML spec."""
    spec_path = Path(args.spec)
    if not spec_path.exists():
        print(f"Error: {spec_path} not found", file=sys.stderr)
        return 1

    output = args.output or str(spec_path.with_suffix(".shortcut"))
    do_sign = not args.no_sign

    result_path, sc_name = _build_and_sign(spec_path, output_path=output, sign=do_sign, sign_mode=args.sign_mode, sign_method=args.sign_method)
    status = "signed" if do_sign else "unsigned"
    print(f"Built {status} shortcut: {result_path}  (name: {sc_name})")
    return 0


def _get_injector_path() -> Optional[str]:
    """Find the bsiri injector dylib."""
    here = Path(__file__).parent.parent / "cli" / "bsiri_injector.dylib"
    if here.exists():
        return str(here)
    return None


def _run_shortcut_file_native(shortcut_path: str, timeout: float = 30.0) -> Tuple[int, Optional[str]]:
    """Run a .shortcut plist by injecting into /usr/bin/shortcuts.

    Passes the entire plist file to the injector via ``BSIRI_WORKFLOW_PLIST``.
    The injector loads it and runs it as a single workflow through
    ``WFShortcutsAppRunnerClient`` inside the entitled shortcuts process.
    This preserves action ordering, control flow (if/else, repeat), and
    magic variable resolution.

    Returns (exit_code, captured_output) where captured_output is the
    stdout content from the injector (may contain JSON or text output),
    or None if empty.
    """
    injector = _get_injector_path()
    if not injector:
        print("Error: bsiri_injector.dylib not found. Build it with 'make' in cli/", file=sys.stderr)
        return 1, None

    env = os.environ.copy()
    env["DYLD_INSERT_LIBRARIES"] = injector
    env["BSIRI_WORKFLOW_PLIST"] = os.path.abspath(shortcut_path)
    env["BSIRI_TIMEOUT"] = str(int(timeout))
    env["BSIRI_OUTPUT_BEHAVIOR"] = "3"  # All Action Outputs

    print(f"Running shortcut via injected shortcuts process...")

    result = subprocess.run(
        ["/usr/bin/shortcuts", "list"],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout + 10,
    )

    # Parse stderr for BSIRI log lines and output descriptions
    output_lines: List[str] = []
    if result.stderr.strip():
        in_output_block = False
        for line in result.stderr.strip().splitlines():
            if "[BSIRI]" in line:
                msg = line.split('[BSIRI] ', 1)[-1]
                if msg.startswith("Output "):
                    output_lines.append(msg)
                    in_output_block = True
                    continue
                if in_output_block:
                    if line.strip() == ')':
                        in_output_block = False
                    else:
                        output_lines.append(line.strip())
                    continue
                if not msg.startswith(("Injector loaded", "Skipping")):
                    print(f"  {msg}")
            elif in_output_block:
                output_lines.append(line.strip())
                if line.strip() == ')':
                    in_output_block = False

    # Combine stdout and parsed output
    captured = result.stdout.strip() if result.stdout.strip() else None
    if output_lines and not captured:
        captured = "\n".join(output_lines)

    return result.returncode, captured


def cmd_exec(args: argparse.Namespace) -> int:
    """Build and execute a shortcut from TOML spec."""
    spec_path = Path(args.spec)
    if not spec_path.exists():
        print(f"Error: {spec_path} not found", file=sys.stderr)
        return 1

    # Build the .shortcut plist (signing only needed for import path)
    do_sign = not args.no_sign
    built_path, sc_name = _build_and_sign(spec_path, sign=do_sign, sign_mode=args.sign_mode, sign_method=args.sign_method)

    try:
        # Try native WorkflowKit execution first (no import needed)
        injector = _get_injector_path()
        if injector and not args.force_import:
            exit_code, output = _run_shortcut_file_native(built_path, timeout=args.timeout)
            if output:
                print(output)
            return exit_code

        # Fallback: import into Shortcuts.app and run by name
        result = subprocess.run(
            ["shortcuts", "import", built_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # Try opening with Shortcuts.app as last resort
            print(f"Import failed ({result.stderr.strip()}), trying open...", file=sys.stderr)
            subprocess.run(["open", built_path], capture_output=True)
            print(f"Opened '{sc_name}' in Shortcuts.app — accept the import and run manually.")
            return 0

        print(f"Imported '{sc_name}', running...")
        cli = ShortcutsCLI()
        parsed, raw = cli.run(sc_name, timeout=args.timeout)
        print(raw or "")
        return 0
    finally:
        try:
            os.unlink(built_path)
        except OSError:
            pass


def cmd_generate(args: argparse.Namespace) -> int:
    """Generate a TOML shortcut spec from discovered App Intents."""
    bundle_filter = args.bundle_id

    app_actions = list_all_actions()
    fw_actions = list_system_framework_actions()
    all_actions = app_actions + fw_actions

    matches = [a for a in all_actions if a.bundle_id and bundle_filter.lower() in a.bundle_id.lower()]
    if not matches:
        print(f"No App Intents found for '{bundle_filter}'", file=sys.stderr)
        return 1

    # Deduplicate
    seen: Dict[tuple, ActionInfo] = {}
    for a in matches:
        key = (a.bundle_id, a.identifier)
        if key not in seen or (a.title and not seen[key].title):
            seen[key] = a
    matches = list(seen.values())

    # If a specific intent was requested, filter further
    if args.intent:
        matches = [a for a in matches if a.identifier and args.intent.lower() in a.identifier.lower()]
        if not matches:
            print(f"No intent matching '{args.intent}' in '{bundle_filter}'", file=sys.stderr)
            return 1

    if args.json:
        print(json.dumps([a.to_dict() for a in matches], indent=2, ensure_ascii=False))
        return 0

    # Generate TOML — include team_identifier for correct intent routing
    team_ids: Dict[str, Optional[str]] = {}
    for a in matches:
        if a.app_path and a.app_path not in team_ids:
            team_ids[a.app_path] = get_team_identifier(a.app_path)

    lines = [f'name = "{matches[0].app_name} Shortcut"', ""]
    for a in matches:
        lines.append("[[action]]")
        lines.append('type = "app_intent"')
        lines.append(f'bundle_identifier = "{a.bundle_id}"')
        lines.append(f'app_intent_identifier = "{a.identifier}"')
        friendly = a.title or a.app_name or ""
        lines.append(f'name = "{friendly}"')
        tid = team_ids.get(a.app_path)
        if tid:
            lines.append(f'team_identifier = "{tid}"')
        if a.parameters:
            lines.append("")
            lines.append("[action.parameters]")
            for p in a.parameters:
                if not p.name:
                    continue
                ptype = p.type or "String"
                if "int" in ptype.lower():
                    placeholder = "0"
                elif "bool" in ptype.lower():
                    placeholder = "false"
                else:
                    placeholder = f'"TODO"'
                lines.append(f'{p.name} = {placeholder}  # {ptype}')
        lines.append("")

    toml_text = "\n".join(lines)

    if args.output:
        with open(args.output, "w") as f:
            f.write(toml_text)
        print(f"Generated: {args.output} ({len(matches)} action(s))")
    else:
        print(toml_text)
    return 0


def cmd_decompile(args: argparse.Namespace) -> int:
    """Decompile a .shortcut file to TOML."""
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: {input_path} not found", file=sys.stderr)
        return 1

    with open(input_path, "rb") as f:
        shortcut = Shortcut.load(f, file_format="shortcut")

    toml_text = shortcut.dumps(file_format="toml")

    if args.output:
        with open(args.output, "w") as f:
            f.write(toml_text)
        print(f"Decompiled: {input_path} → {args.output} ({len(shortcut.actions)} actions)")
    else:
        print(toml_text)
    return 0


def cmd_intent(args: argparse.Namespace) -> int:
    """Execute a specific App Intent via the native CLI."""
    native_cli = get_native_cli_path()

    if not native_cli:
        print("Error: Native bsiri CLI not found. Build it with 'make' in cli/", file=sys.stderr)
        return 1

    # Build parameters dict from key=value pairs
    params = {}
    for p in args.params:
        if "=" in p:
            k, v = p.split("=", 1)
            # Try to parse as JSON for complex types
            try:
                params[k] = json.loads(v)
            except json.JSONDecodeError:
                params[k] = v

    # Set parameters as environment variables for the native CLI
    env = os.environ.copy()
    for k, v in params.items():
        env_key = f"BSIRI_{k.upper()}"
        env[env_key] = json.dumps(v) if not isinstance(v, str) else v

    # Run via native CLI
    cmd = [native_cli, "wk-run-appintent", args.bundle_id, args.intent_id]

    print(f"Executing: {args.bundle_id}.{args.intent_id}")
    if params:
        print(f"Parameters: {params}")

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)

    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)

    return result.returncode


def cmd_list_shortcuts(args: argparse.Namespace) -> int:
    """List all installed shortcuts."""
    cli = ShortcutsCLI()
    shortcuts = cli.list(show_identifiers=True)

    if args.json:
        print(json.dumps([{"name": s.name, "id": s.identifier} for s in shortcuts], indent=2))
        return 0

    for s in shortcuts:
        id_str = f" ({s.identifier})" if s.identifier else ""
        print(f"{s.name}{id_str}")

    print(f"\nTotal: {len(shortcuts)} shortcuts")
    return 0


def cmd_demo(args: argparse.Namespace) -> int:
    """Run demonstration workflows."""
    native_cli = get_native_cli_path()

    demos = {
        "notes": ("Create a note in Apple Notes", ["create-note", "Hello from bsiri", "This note was created programmatically via bsiri!"]),
        "open-safari": ("Open Safari via native engine", ["open-app", "Safari"]),
    }

    if args.demo_name == "list":
        print("Available demos:")
        for name, (desc, _) in demos.items():
            print(f"  {name}: {desc}")
        return 0

    if args.demo_name not in demos:
        print(f"Unknown demo: {args.demo_name}")
        print("Use 'demo list' to see available demos")
        return 1

    desc, cmd_args = demos[args.demo_name]
    print(f"Running demo: {desc}")

    if native_cli:
        result = subprocess.run([native_cli] + cmd_args, capture_output=True, text=True)
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return result.returncode
    else:
        print("Native CLI not built. Run 'make' in cli/ directory first.", file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="bsiri: Discover and execute macOS App Intents via WorkflowKit/ActionKit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s discover                     # List all available App Intents
  %(prog)s discover com.apple.Notes     # List intents for Notes app
  %(prog)s generate com.openai.chat     # Generate TOML for ChatGPT intents
  %(prog)s generate io.tailscale --intent GetStatus -o ts.toml
  %(prog)s build workflow.toml          # Build and sign (local) a .shortcut file
  %(prog)s build workflow.toml --sign-method hubsign  # Sign via RoutineHub (no iCloud needed)
  %(prog)s build workflow.toml --no-sign  # Build without signing
  %(prog)s exec workflow.toml           # Build, sign, import, and run
  %(prog)s shortcuts                    # List installed shortcuts
  %(prog)s run "My Shortcut"            # Run an existing shortcut
  %(prog)s intent com.apple.Notes CreateNoteIntent title="Hello" body="World"
  %(prog)s demo notes                   # Create a demo note via WorkflowKit
        """,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    # discover
    p_discover = sub.add_parser("discover", help="Discover available App Intents")
    p_discover.add_argument("bundle_id", nargs="?", help="Filter by bundle ID (partial match)")
    p_discover.add_argument("--json", action="store_true", help="Output as JSON")
    p_discover.add_argument("--include-dev", action="store_true", help="Include developer tools like Xcode")
    p_discover.set_defaults(func=cmd_discover)

    # shortcuts (list installed)
    p_shortcuts = sub.add_parser("shortcuts", help="List installed shortcuts")
    p_shortcuts.add_argument("--json", action="store_true", help="Output as JSON")
    p_shortcuts.set_defaults(func=cmd_list_shortcuts)

    # run
    p_run = sub.add_parser("run", help="Run an existing shortcut by name")
    p_run.add_argument("name", help="Shortcut name or identifier")
    p_run.add_argument("--input-json", help="JSON input to pass to the shortcut")
    p_run.add_argument("--input-text", help="Plain text input")
    p_run.add_argument("--output-type", help="Expected output UTI (e.g., public.json)")
    p_run.add_argument("--timeout", type=float, default=30.0, help="Timeout in seconds")
    p_run.set_defaults(func=cmd_run)

    # build
    p_build = sub.add_parser("build", help="Build (and sign) a .shortcut from TOML spec")
    p_build.add_argument("spec", help="Path to TOML workflow spec")
    p_build.add_argument("-o", "--output", help="Output .shortcut path (default: <spec>.shortcut)")
    p_build.add_argument("--no-sign", action="store_true", help="Skip signing")
    p_build.add_argument("--sign-mode", default="people-who-know-me", choices=["people-who-know-me", "anyone"], help="Signing mode (local only)")
    p_build.add_argument("--sign-method", default="local", choices=["local", "hubsign"], help="Signing method: local (macOS CLI, needs iCloud) or hubsign (RoutineHub remote)")
    p_build.set_defaults(func=cmd_build)

    # exec
    p_exec = sub.add_parser("exec", help="Build, sign, import, and run a shortcut from TOML spec")
    p_exec.add_argument("spec", help="Path to TOML workflow spec")
    p_exec.add_argument("--no-sign", action="store_true", help="Skip signing")
    p_exec.add_argument("--sign-mode", default="people-who-know-me", choices=["people-who-know-me", "anyone"], help="Signing mode (local only)")
    p_exec.add_argument("--sign-method", default="local", choices=["local", "hubsign"], help="Signing method: local or hubsign (remote)")
    p_exec.add_argument("--timeout", type=float, default=30.0, help="Run timeout in seconds")
    p_exec.add_argument("--force-import", action="store_true", help="Force import into Shortcuts.app instead of running via native CLI")
    p_exec.set_defaults(func=cmd_exec)

    # generate
    p_gen = sub.add_parser("generate", help="Generate TOML spec from discovered App Intents")
    p_gen.add_argument("bundle_id", help="Bundle ID to generate for (partial match)")
    p_gen.add_argument("--intent", help="Filter to a specific intent (partial match)")
    p_gen.add_argument("-o", "--output", help="Write TOML to file instead of stdout")
    p_gen.add_argument("--json", action="store_true", help="Output raw intent info as JSON instead of TOML")
    p_gen.set_defaults(func=cmd_generate)

    # decompile
    p_decompile = sub.add_parser("decompile", help="Decompile a .shortcut file to TOML")
    p_decompile.add_argument("input", help="Path to .shortcut file")
    p_decompile.add_argument("-o", "--output", help="Output .toml path (default: stdout)")
    p_decompile.set_defaults(func=cmd_decompile)

    # intent
    p_intent = sub.add_parser("intent", help="Execute a specific App Intent")
    p_intent.add_argument("bundle_id", help="Bundle ID (e.g., com.apple.Notes)")
    p_intent.add_argument("intent_id", help="Intent identifier (e.g., CreateNoteIntent)")
    p_intent.add_argument("params", nargs="*", help="Parameters as key=value pairs")
    p_intent.set_defaults(func=cmd_intent)

    # demo
    p_demo = sub.add_parser("demo", help="Run demonstration workflows")
    p_demo.add_argument("demo_name", help="Demo name (or 'list' to show available)")
    p_demo.set_defaults(func=cmd_demo)

    return p


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
