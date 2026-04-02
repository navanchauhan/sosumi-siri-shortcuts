import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable, List, Optional, Tuple


class ShortcutsError(RuntimeError):
    pass


def _check_shortcuts_cli() -> str:
    path = shutil.which("shortcuts")
    if not path:
        raise ShortcutsError(
            "The macOS 'shortcuts' CLI is not available. Install macOS Monterey+ and enable Shortcuts."
        )
    return path


@dataclass
class ShortcutInfo:
    name: str
    identifier: Optional[str] = None


class ShortcutsCLI:
    """Thin wrapper around the macOS `shortcuts` command-line tool.

    Docs: run `shortcuts --help` on macOS for full options.
    """

    def __init__(self) -> None:
        self._bin = _check_shortcuts_cli()

    def list(self, show_identifiers: bool = True) -> List[ShortcutInfo]:
        args = [self._bin, "list"]
        if show_identifiers:
            args.append("--show-identifiers")
        out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
        results: List[ShortcutInfo] = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            # Expected format when --show-identifiers is provided:
            #   <Name> — <Identifier>
            # Fallback to whole line as name if split fails.
            name, ident = _parse_name_identifier(line)
            results.append(ShortcutInfo(name=name, identifier=ident))
        return results

    def run(
        self,
        name_or_identifier: str,
        *,
        input: Optional[Any] = None,
        input_is_text: bool = False,
        output_type: Optional[str] = None,
        timeout: Optional[float] = None,
    ) -> Tuple[Optional[Any], str]:
        """Run a shortcut and return (parsed_output, raw_output).

        - input: a Python object to pass as input. If `input_is_text` is True,
          input is written as UTF-8 text; otherwise it's serialized to JSON.
        - output_type: Universal Type Identifier for the expected output.
          Examples: 'public.json', 'public.plain-text'. If None, attempts to read
          text; if JSON parse fails, returns raw text.
        - timeout: seconds to wait for the `shortcuts` process.
        """
        _ = self._bin  # ensure present

        # Prepare temp files for input and output
        input_path = None
        rm_paths: list[str] = []
        try:
            if input is not None:
                fd, input_path = tempfile.mkstemp(prefix="bsiri_in_", suffix=".txt")
                os.close(fd)
                rm_paths.append(input_path)
                if input_is_text:
                    data = input if isinstance(input, str) else str(input)
                    with open(input_path, "w", encoding="utf-8") as f:
                        f.write(data)
                else:
                    with open(input_path, "w", encoding="utf-8") as f:
                        json.dump(input, f)

            fd, output_path = tempfile.mkstemp(prefix="bsiri_out_", suffix=".txt")
            os.close(fd)
            rm_paths.append(output_path)

            cmd: List[str] = [self._bin, "run", name_or_identifier, "--output-path", output_path]
            if input_path:
                cmd.extend(["--input-path", input_path])
            if output_type:
                cmd.extend(["--output-type", output_type])

            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            if proc.returncode != 0:
                raise ShortcutsError(
                    f"shortcuts run failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}"
                )

            # Read output
            if not os.path.exists(output_path) or os.stat(output_path).st_size == 0:
                return None, ""

            with open(output_path, "r", encoding="utf-8") as f:
                raw = f.read()

            parsed: Optional[Any] = None
            if output_type == "public.json":
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError:
                    parsed = None
            elif output_type in (None, "public.plain-text", "public.text"):
                parsed = raw
            else:
                # Unknown type: return raw string without parsing
                parsed = raw
            return parsed, raw
        finally:
            for p in rm_paths:
                try:
                    os.remove(p)
                except Exception:
                    pass


def _parse_name_identifier(line: str) -> Tuple[str, Optional[str]]:
    # Apple prints a long dash U+2014 or U+2013 depending on locale. Try both and hyphen.
    for sep in (" — ", " – ", " - "):
        if sep in line:
            parts = line.split(sep, 1)
            name = parts[0].strip()
            ident = parts[1].strip() or None
            return name, ident
    return line.strip(), None


SIGN_METHOD_LOCAL = "local"
SIGN_METHOD_HUBSIGN = "hubsign"

HUBSIGN_URL = "https://hubsign.routinehub.services/sign"

# Magic bytes for Apple Encrypted Archive (signed shortcut).
_AEA1_MAGIC = b"AEA1"


def sign_shortcut(
    input_path: str,
    output_path: str,
    *,
    mode: str = "people-who-know-me",
    method: str = SIGN_METHOD_LOCAL,
    timeout: Optional[float] = 30.0,
) -> str:
    """Sign a .shortcut file.

    Args:
        input_path: Path to the unsigned .shortcut plist.
        output_path: Where to write the signed shortcut.
        mode: Signing mode — ``"people-who-know-me"`` or ``"anyone"``
              (only meaningful for local signing).
        method: ``"local"`` to use the macOS ``shortcuts sign`` CLI, or
                ``"hubsign"`` to use RoutineHub's remote signing service.
        timeout: Seconds to wait.

    Returns:
        The *output_path* on success.

    Raises:
        ShortcutsError: If signing fails.
    """
    if method == SIGN_METHOD_HUBSIGN:
        return _sign_remote_hubsign(input_path, output_path, timeout=timeout)
    return _sign_local(input_path, output_path, mode=mode, timeout=timeout)


def _sign_local(
    input_path: str,
    output_path: str,
    *,
    mode: str = "people-who-know-me",
    timeout: Optional[float] = 30.0,
) -> str:
    bin_path = _check_shortcuts_cli()
    proc = subprocess.run(
        [bin_path, "sign", "-i", input_path, "-o", output_path, "-m", mode],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        if "iCloud" in stderr:
            raise ShortcutsError(
                "Local signing requires iCloud sign-in. Sign into iCloud in System Settings, "
                "use --sign-method hubsign for remote signing, "
                "or use --no-sign to skip signing."
            )
        raise ShortcutsError(
            f"shortcuts sign failed ({proc.returncode}): {stderr or proc.stdout.strip()}"
        )
    return output_path


def _sign_remote_hubsign(
    input_path: str,
    output_path: str,
    *,
    timeout: Optional[float] = 30.0,
) -> str:
    import json as _json
    import plistlib as _plistlib

    try:
        import urllib.request
        import urllib.error
    except ImportError as exc:
        raise ShortcutsError(f"urllib not available: {exc}") from exc

    with open(input_path, "rb") as f:
        binary_plist = f.read()

    # HubSign expects {"shortcutName": "...", "shortcut": "<xml plist string>"}
    # Convert binary plist → XML plist for the payload.
    plist_obj = _plistlib.loads(binary_plist)
    xml_plist = _plistlib.dumps(plist_obj, fmt=_plistlib.FMT_XML).decode("utf-8")

    shortcut_name = os.path.splitext(os.path.basename(input_path))[0]
    payload = _json.dumps({
        "shortcutName": shortcut_name,
        "shortcut": xml_plist,
    }).encode("utf-8")

    req = urllib.request.Request(
        HUBSIGN_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "bsiri/1.0",
        },
        method="POST",
    )

    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        raise ShortcutsError(
            f"HubSign returned HTTP {exc.code}: {exc.read().decode('utf-8', errors='replace')[:200]}"
        ) from exc
    except urllib.error.URLError as exc:
        raise ShortcutsError(f"HubSign request failed: {exc.reason}") from exc

    content_type = resp.headers.get("Content-Type", "")
    allowed = ("application/octet-stream", "application/x-plist", "application/x-apple-shortcut")
    if not any(ct in content_type for ct in allowed):
        raise ShortcutsError(f"HubSign returned unexpected Content-Type: {content_type}")

    signed_bytes = resp.read()

    if len(signed_bytes) < 4 or signed_bytes[:4] != _AEA1_MAGIC:
        raise ShortcutsError(
            "HubSign response does not look like a signed shortcut (missing AEA1 header)"
        )

    with open(output_path, "wb") as f:
        f.write(signed_bytes)

    return output_path


def run_shortcut(
    name_or_identifier: str,
    *,
    input: Optional[Any] = None,
    input_is_text: bool = False,
    output_type: Optional[str] = None,
    timeout: Optional[float] = None,
) -> Any:
    """Convenience wrapper to run a shortcut and return parsed output only."""
    cli = ShortcutsCLI()
    parsed, _ = cli.run(
        name_or_identifier,
        input=input,
        input_is_text=input_is_text,
        output_type=output_type,
        timeout=timeout,
    )
    return parsed
