import json
import os
import plistlib
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional


@dataclass
class NativeParam:
    name: str
    type: Optional[str] = None
    display_name: Optional[str] = None


@dataclass
class NativeAction:
    title: str
    identifier: Optional[str]
    parameters: List[NativeParam]
    source: str  # e.g., ActionKit.intentdefinition, ActionKit.actionsdata, WorkflowKit.loctable

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["parameters"] = [asdict(p) for p in self.parameters]
        return d


ACTIONKIT_INTENTDEFINITION = \
    "/System/Library/PrivateFrameworks/ActionKit.framework/Versions/Current/Resources/Base.lproj/Actions.intentdefinition"
ACTIONKIT_ACTIONSDATA = \
    "/System/Library/PrivateFrameworks/ActionKit.framework/Versions/Current/Resources/Metadata.appintents/extract.actionsdata"
WORKFLOWKIT_LOCTABLE = \
    "/System/Library/PrivateFrameworks/WorkflowKit.framework/Versions/Current/Resources/Localizable.loctable"


def _parse_actionkit_intentdefinition(path: str) -> List[NativeAction]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        return []
    results: List[NativeAction] = []
    for intent in data.get("INIntents", []) or []:
        title = intent.get("INIntentTitle")
        if not title:
            continue
        params = []
        for p in intent.get("INIntentParameters", []) or []:
            ptype = p.get("INIntentParameterType")
            if ptype == "Object" and p.get("INIntentParameterObjectType"):
                ptype = f"Object({p.get('INIntentParameterObjectType')})"
            params.append(
                NativeParam(
                    name=p.get("INIntentParameterName"),
                    type=ptype,
                    display_name=p.get("INIntentParameterDisplayName"),
                )
            )
        results.append(
            NativeAction(
                title=title,
                identifier=intent.get("INIntentName"),
                parameters=params,
                source="ActionKit.intentdefinition",
            )
        )
    return results


def _parse_actionkit_actionsdata(path: str) -> List[NativeAction]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "rb") as f:
            data = json.load(f)
    except Exception:
        return []
    results: List[NativeAction] = []
    actions = data.get("actions", {}) or {}
    for ident, meta in actions.items():
        t = meta.get("title") or {}
        title = t.get("key") if isinstance(t, dict) else None
        if not title:
            continue
        params = []
        for p in meta.get("parameters", []) or []:
            vt = p.get("valueType") or {}
            # Best-effort type name
            ptype = None
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
                NativeParam(
                    name=p.get("name"),
                    type=ptype,
                    display_name=(p.get("title") or {}).get("key") if isinstance(p.get("title"), dict) else None,
                )
            )
        results.append(
            NativeAction(
                title=title,
                identifier=ident,
                parameters=params,
                source="ActionKit.actionsdata",
            )
        )
    return results


KNOWN_SCRIPTING_TITLES = {
    # Common Shortcuts scripting actions not exposed via App Intents metadata
    "Add to Variable",
    "Set Variable",
    "Get Variable",
    "Choose from List",
    "Choose from Menu",
    "Create List",
    "List",
    "Repeat",
    "Repeat with Each",
    "If",
    "Dictionary",
    "Get Dictionary Value",
}


def _harvest_workflowkit_titles(path: str, locale: str = "en") -> List[NativeAction]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        return []
    loc = data.get(locale) or data.get("en_GB") or data.get("en_AU") or {}
    values = set(v for v in loc.values() if isinstance(v, str))
    results: List[NativeAction] = []
    for title in sorted(KNOWN_SCRIPTING_TITLES):
        if title in values:
            results.append(NativeAction(title=title, identifier=None, parameters=[], source="WorkflowKit.loctable"))
    return results


def list_native_actions() -> List[NativeAction]:
    results: List[NativeAction] = []
    # ActionKit intent definitions (structured)
    results.extend(_parse_actionkit_intentdefinition(ACTIONKIT_INTENTDEFINITION))
    # ActionKit actionsdata (structured)
    results.extend(_parse_actionkit_actionsdata(ACTIONKIT_ACTIONSDATA))
    # WorkflowKit loctable (titles only for scripting staples)
    results.extend(_harvest_workflowkit_titles(WORKFLOWKIT_LOCTABLE))

    # Deduplicate by (title, identifier)
    seen = set()
    deduped: List[NativeAction] = []
    for a in results:
        key = (a.title, a.identifier or a.source)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(a)
    return deduped

