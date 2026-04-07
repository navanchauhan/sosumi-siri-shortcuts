import os
import json
import plistlib
from dataclasses import dataclass, asdict
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple


@dataclass
class ActionParam:
    name: str
    type: Optional[str] = None
    display_name: Optional[str] = None


@dataclass
class ActionInfo:
    app_name: str
    bundle_id: Optional[str]
    app_path: str
    source_path: str
    identifier: Optional[str]
    title: Optional[str]
    description: Optional[str]
    parameters: List[ActionParam]

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["parameters"] = [asdict(p) for p in self.parameters]
        return d


DEFAULT_SEARCH_DIRS = [
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices",
    os.path.expanduser("~/Applications"),
]

# Additional directories that contain App Intents in .appex extensions
EXTENSION_SEARCH_DIRS = [
    "/System/Library/ExtensionKit/Extensions",
]


def _find_apps(search_dirs: Iterable[str]) -> Iterator[str]:
    for base in search_dirs:
        if not os.path.isdir(base):
            continue
        for root, dirs, files in os.walk(base):
            # Skip heavy developer directories unless explicitly requested upstream
            yield from (os.path.join(root, d) for d in dirs if d.endswith(".app"))


def _find_extensions(search_dirs: Iterable[str] = EXTENSION_SEARCH_DIRS) -> Iterator[str]:
    """Find .appex extension bundles that may contain App Intents."""
    for base in search_dirs:
        if not os.path.isdir(base):
            continue
        for entry in os.listdir(base):
            if entry.endswith(".appex"):
                yield os.path.join(base, entry)


def _bundle_info(app_path: str) -> Tuple[str, Optional[str]]:
    info_plist = os.path.join(app_path, "Contents", "Info.plist")
    basename = os.path.basename(app_path)
    # Strip .app or .appex suffix for default name
    for suffix in (".app", ".appex"):
        if basename.endswith(suffix):
            basename = basename[: -len(suffix)]
            break
    app_name = basename
    bundle_id = None
    try:
        with open(info_plist, "rb") as f:
            info = plistlib.load(f)
        app_name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or app_name
        bundle_id = info.get("CFBundleIdentifier")
    except Exception:
        pass
    return app_name, bundle_id


def get_team_identifier(app_path: str) -> Optional[str]:
    """Extract the TeamIdentifier from an app's code signature."""
    import subprocess
    try:
        result = subprocess.run(
            ["codesign", "-dv", app_path],
            capture_output=True, text=True, timeout=5,
        )
        for line in result.stderr.splitlines():
            if line.startswith("TeamIdentifier="):
                tid = line.split("=", 1)[1].strip()
                if tid and tid != "not set":
                    return tid
    except Exception:
        pass
    return None


def _list_intentdefinition_files(app_path: str) -> List[str]:
    results: List[str] = []
    res_dir = os.path.join(app_path, "Contents", "Resources")
    if not os.path.isdir(res_dir):
        return results
    for root, _dirs, files in os.walk(res_dir):
        for fn in files:
            if fn.endswith(".intentdefinition"):
                results.append(os.path.join(root, fn))
    return results


def _list_actionsdata_files(app_path: str) -> List[str]:
    results: List[str] = []
    contents_dir = os.path.join(app_path, "Contents")
    if not os.path.isdir(contents_dir):
        return results
    for root, dirs, files in os.walk(contents_dir):
        # If a Metadata.appintents directory is found, add any *actionsdata inside
        if os.path.basename(root) == "Metadata.appintents":
            for fn in files:
                if fn.endswith("actionsdata"):
                    results.append(os.path.join(root, fn))
    return results


def _parse_intents_from_file(path: str) -> List[Dict[str, Any]]:
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        return []
    # Common key is 'INIntents'
    intents = data.get("INIntents")
    if isinstance(intents, list):
        return [i for i in intents if isinstance(i, dict)]
    # Fallbacks seen in some dev resources
    for key in ("Intents", "INIntentDefinitions", "InIntents"):
        intents = data.get(key)
        if isinstance(intents, list):
            return [i for i in intents if isinstance(i, dict)]
    return []


def _parse_actionsdata(path: str) -> List[Dict[str, Any]]:
    try:
        with open(path, "rb") as f:
            data = json.load(f)
    except Exception:
        return []
    actions = data.get("actions")
    if isinstance(actions, dict):
        # Normalize to list of dicts with identifier
        out = []
        for ident, meta in actions.items():
            if isinstance(meta, dict):
                m = dict(meta)
                m.setdefault("identifier", ident)
                out.append(m)
        return out
    return []


def _extract_params(intent: Dict[str, Any]) -> List[ActionParam]:
    params: List[ActionParam] = []
    raw = intent.get("INIntentParameters")
    if not isinstance(raw, list):
        return params
    for p in raw:
        if not isinstance(p, dict):
            continue
        ptype = p.get("INIntentParameterType")
        if ptype == "Object" and p.get("INIntentParameterObjectType"):
            ptype = f"Object({p.get('INIntentParameterObjectType')})"
        params.append(
            ActionParam(
                name=str(p.get("INIntentParameterName") or "").strip() or None,
                type=ptype,
                display_name=p.get("INIntentParameterDisplayName"),
            )
        )
    return params


def list_all_actions(
    *,
    search_dirs: Optional[List[str]] = None,
    include_dev: bool = False,
) -> List[ActionInfo]:
    """Enumerate app-provided Shortcuts actions by scanning .intentdefinition files.

    Note: This lists app-intents (SiriKit / App Intents). It does not include the
    built-in Shortcuts library actions.
    """
    dirs = list(search_dirs or DEFAULT_SEARCH_DIRS)
    actions: List[ActionInfo] = []
    for app in _find_apps(dirs):
        # Skip Xcode and related developer bundles unless include_dev
        if not include_dev:
            base = os.path.basename(app)
            if base.startswith("Xcode"):
                continue
        app_name, bundle_id = _bundle_info(app)
        # From .intentdefinition files
        for idef in _list_intentdefinition_files(app):
            intents = _parse_intents_from_file(idef)
            for intent in intents:
                actions.append(
                    ActionInfo(
                        app_name=app_name,
                        bundle_id=bundle_id,
                        app_path=app,
                        source_path=idef,
                        identifier=intent.get("INIntentName"),
                        title=intent.get("INIntentTitle"),
                        description=intent.get("INIntentDescription"),
                        parameters=_extract_params(intent),
                    )
                )
        # From AppIntents metadata JSON
        for js in _list_actionsdata_files(app):
            intents = _parse_actionsdata(js)
            for intent in intents:
                params: List[ActionParam] = []
                for p in intent.get("parameters", []) or []:
                    # try detect scalar/entity
                    ptype = None
                    vt = p.get("valueType") or {}
                    if isinstance(vt, dict):
                        if "entity" in vt:
                            ent = vt["entity"]
                            if isinstance(ent, dict):
                                wrapper = ent.get("wrapper") or {}
                                ptype = wrapper.get("typeName") or "Entity"
                        elif "scalar" in vt:
                            ptype = vt["scalar"].get("type")
                        elif "string" in vt:
                            ptype = "String"
                    params.append(
                        ActionParam(
                            name=p.get("name"),
                            type=ptype,
                            display_name=(p.get("title") or {}).get("key") if isinstance(p.get("title"), dict) else None,
                        )
                    )
                title_meta = intent.get("title") or {}
                title = title_meta.get("key") if isinstance(title_meta, dict) else None
                desc_meta = intent.get("descriptionMetadata") or {}
                desc_text = desc_meta.get("descriptionText") or {} if isinstance(desc_meta, dict) else {}
                description = desc_text.get("key") if isinstance(desc_text, dict) else None
                actions.append(
                    ActionInfo(
                        app_name=app_name,
                        bundle_id=bundle_id,
                        app_path=app,
                        source_path=js,
                        identifier=intent.get("identifier"),
                        title=title,
                        description=description,
                        parameters=params,
                    )
                )

    # Also scan ExtensionKit .appex bundles (Apple Intelligence, etc.)
    for ext in _find_extensions():
        app_name, bundle_id = _bundle_info(ext)
        for js in _list_actionsdata_files(ext):
            intents = _parse_actionsdata(js)
            for intent in intents:
                params_list: List[ActionParam] = []
                for p in intent.get("parameters", []) or []:
                    ptype = None
                    vt = p.get("valueType") or {}
                    if isinstance(vt, dict):
                        if "entity" in vt:
                            ent = vt["entity"]
                            if isinstance(ent, dict):
                                wrapper = ent.get("wrapper") or {}
                                ptype = wrapper.get("typeName") or "Entity"
                        elif "scalar" in vt:
                            ptype = vt["scalar"].get("type")
                        elif "string" in vt:
                            ptype = "String"
                    params_list.append(
                        ActionParam(
                            name=p.get("name"),
                            type=ptype,
                            display_name=(p.get("title") or {}).get("key") if isinstance(p.get("title"), dict) else None,
                        )
                    )
                title_meta = intent.get("title") or {}
                title = title_meta.get("key") if isinstance(title_meta, dict) else None
                desc_meta = intent.get("descriptionMetadata") or {}
                desc_text = desc_meta.get("descriptionText") or {} if isinstance(desc_meta, dict) else {}
                description = desc_text.get("key") if isinstance(desc_text, dict) else None
                actions.append(
                    ActionInfo(
                        app_name=app_name,
                        bundle_id=bundle_id,
                        app_path=ext,
                        source_path=js,
                        identifier=intent.get("identifier"),
                        title=title,
                        description=description,
                        parameters=params_list,
                    )
                )

    return actions


def list_system_framework_actions() -> List[ActionInfo]:
    """Scan system PrivateFrameworks for AppIntents metadata and surface them as actions.

    The app_name/bundle_id refer to the framework bundle, e.g., HomeAppIntents.
    """
    base = "/System/Library/PrivateFrameworks"
    actions: List[ActionInfo] = []
    if not os.path.isdir(base):
        return actions
    for entry in os.listdir(base):
        if not entry.endswith(".framework"):
            continue
        fw_path = os.path.join(base, entry)
        md_dir = os.path.join(fw_path, "Versions", "Current", "Resources", "Metadata.appintents")
        if not os.path.isdir(md_dir):
            continue
        info_plist = os.path.join(fw_path, "Versions", "Current", "Resources", "Info.plist")
        app_name = entry.rsplit(".framework", 1)[0]
        bundle_id = None
        try:
            with open(info_plist, "rb") as f:
                info = plistlib.load(f)
            app_name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or app_name
            bundle_id = info.get("CFBundleIdentifier")
        except Exception:
            pass
        for fn in os.listdir(md_dir):
            if not fn.endswith("actionsdata"):
                continue
            path = os.path.join(md_dir, fn)
            for intent in _parse_actionsdata(path):
                params: List[ActionParam] = []
                for p in intent.get("parameters", []) or []:
                    ptype = None
                    vt = p.get("valueType") or {}
                    if isinstance(vt, dict):
                        if "entity" in vt:
                            ent = vt["entity"]
                            if isinstance(ent, dict):
                                wrapper = ent.get("wrapper") or {}
                                ptype = wrapper.get("typeName") or "Entity"
                        elif "scalar" in vt:
                            ptype = vt["scalar"].get("type")
                        elif "string" in vt:
                            ptype = "String"
                    params.append(ActionParam(name=p.get("name"), type=ptype, display_name=(p.get("title") or {}).get("key") if isinstance(p.get("title"), dict) else None))
                title_meta = intent.get("title") or {}
                title = title_meta.get("key") if isinstance(title_meta, dict) else None
                desc_meta = intent.get("descriptionMetadata") or {}
                desc_text = desc_meta.get("descriptionText") or {} if isinstance(desc_meta, dict) else {}
                description = desc_text.get("key") if isinstance(desc_text, dict) else None
                actions.append(
                    ActionInfo(
                        app_name=app_name,
                        bundle_id=bundle_id,
                        app_path=fw_path,
                        source_path=path,
                        identifier=intent.get("identifier"),
                        title=title,
                        description=description,
                        parameters=params,
                    )
                )
    return actions
