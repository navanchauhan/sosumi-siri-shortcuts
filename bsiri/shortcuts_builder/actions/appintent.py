from __future__ import annotations

"""Custom actions for invoking third-party App Intents."""

import re as _re
import uuid as _uuid
from typing import Dict, Optional

from .base import BaseAction, Field, VariablesField

# Reuse the same regex that VariablesField uses to detect {{var}} references.
_VAR_RE = _re.compile(r'({{[A-Za-z0-9_-]+}})')
# Magic variable with optional aggrandizements:
#   <<UUID:Name>>                     — raw action output
#   <<UUID:Name.PropertyName>>        — property access
#   <<UUID:Name['key']>>              — dictionary key access
#   <<UUID:Name as Type>>             — type coercion
#   <<UUID:Name.Prop as Type>>        — combined
_MAGIC_VAR_RE = _re.compile(
    r'^<<([A-Za-z0-9_-]+)'           # UUID (hex or user-defined identifiers)
    r'(?::([^.>\[]+?))?'             # :OutputName (optional, non-greedy)
    r"(?:\.([A-Za-z0-9_]+))?"        # .PropertyName (optional)
    r"(?:\['([^']+)'\])?"            # ['DictKey'] (optional)
    r'(?:\s+as\s+([A-Za-z]+))?'      # as CoercionType (optional)
    r'>>\Z'
)

# Map friendly coercion names to WFContentItemClass identifiers
_COERCION_MAP = {
    "text": "WFStringContentItem",
    "string": "WFStringContentItem",
    "number": "WFNumberContentItem",
    "url": "WFURLContentItem",
    "date": "WFDateContentItem",
    "dictionary": "WFDictionaryContentItem",
    "image": "WFImageContentItem",
    "bool": "WFBooleanContentItem",
    "file": "WFGenericFileContentItem",
    "richtext": "WFRichTextContentItem",
    "pdf": "WFPDFContentItem",
    "contact": "WFContactContentItem",
    "location": "WFLocationContentItem",
    "phonenumber": "WFPhoneNumberContentItem",
    "email": "WFEmailAddressContentItem",
}

_variables_field = VariablesField("_tmp")


class AppIntentAction(BaseAction):
    """Represent a Shortcuts action that invokes an App Intent.

    Apple stores App Intent invocations using the app's bundle identifier
    as the workflow action identifier and an AppIntentDescriptor payload
    describing the intent metadata. The stock python-shortcuts project
    doesn't ship a helper for this, so we provide one here.
    """

    keyword = "app_intent"

    action_identifier = Field("action_identifier", required=False)
    app_intent_identifier = Field("app_intent_identifier")
    bundle_identifier = Field("bundle_identifier")
    team_identifier = Field("team_identifier", required=False)
    name = Field("name", required=False)
    uuid = Field("uuid", required=False)
    parameters = Field("parameters", required=False, default=None)
    descriptor_extras = Field("descriptor_extras", required=False, default=None)

    @staticmethod
    def _build_magic_attachment(match):
        """Build a WFTextTokenAttachment Value dict from a regex match."""
        output_uuid = match.group(1)
        output_name = match.group(2) or "Output"
        prop_name = match.group(3)
        dict_key = match.group(4)
        coerce_type = match.group(5)

        val = {
            "OutputUUID": output_uuid,
            "Type": "ActionOutput",
            "OutputName": output_name,
        }

        aggrandizements = []
        if prop_name:
            aggrandizements.append({
                "Type": "WFPropertyVariableAggrandizement",
                "PropertyName": prop_name,
            })
        if dict_key:
            aggrandizements.append({
                "Type": "WFDictionaryValueVariableAggrandizement",
                "DictionaryKey": dict_key,
            })
        if coerce_type:
            item_class = _COERCION_MAP.get(coerce_type.lower(), f"WF{coerce_type}ContentItem")
            aggrandizements.append({
                "Type": "WFCoercionVariableAggrandizement",
                "CoercionItemClass": item_class,
            })
        if aggrandizements:
            val["Aggrandizements"] = aggrandizements

        return val

    @staticmethod
    def _serialize_param_value(value):
        """Serialize a parameter value, converting variable references into
        the proper WF serialization dicts.

        Supported syntaxes:
            ``{{var_name}}``                         — named variable (WFTextTokenString)
            ``<<UUID:Name>>``                        — magic variable (ActionOutput)
            ``<<UUID:Name.Property>>``               — with property access
            ``<<UUID:Name['key']>>``                 — with dictionary key access
            ``<<UUID:Name as text>>``                — with type coercion
            ``<<UUID:Name.Property as text>>``       — combined property + coercion

        Magic variables can appear standalone or embedded in text:
            ``"<<UUID:Name>>"``                      — standalone → WFTextTokenAttachment
            ``"prefix <<UUID:A>> mid <<UUID:B>>"``   — mixed → WFTextTokenString
        """
        if not isinstance(value, str):
            return value

        # Standalone magic variable (entire string is one reference)
        magic_match = _MAGIC_VAR_RE.match(value)
        if magic_match:
            return {
                "Value": AppIntentAction._build_magic_attachment(magic_match),
                "WFSerializationType": "WFTextTokenAttachment",
            }

        # Mixed string with embedded magic variables: build WFTextTokenString
        # Pattern for inline magic vars (non-anchored version)
        inline_magic = _re.compile(
            r'<<([A-Za-z0-9_-]+)'
            r'(?::([^.>\[]+?))?'
            r"(?:\.([A-Za-z0-9_]+))?"
            r"(?:\['([^']+)'\])?"
            r'(?:\s+as\s+([A-Za-z]+))?'
            r'>>'
        )

        if inline_magic.search(value):
            attachments_by_range = {}
            result_chars = []
            last_end = 0
            offset = 0

            for m in inline_magic.finditer(value):
                # Add literal text before this match
                result_chars.append(value[last_end:m.start()])
                # Position in the output string (after removing previous matches)
                pos = m.start() - offset
                attachment = AppIntentAction._build_magic_attachment(m)
                variable_range = f'{{{pos}, {1}}}'
                attachments_by_range[variable_range] = attachment
                result_chars.append('\ufffc')  # object replacement character
                offset += len(m.group()) - 1  # -1 for the replacement char
                last_end = m.end()

            result_chars.append(value[last_end:])
            result_string = ''.join(result_chars)

            return {
                "Value": {
                    "attachmentsByRange": attachments_by_range,
                    "string": result_string,
                },
                "WFSerializationType": "WFTextTokenString",
            }

        # Named variable: {{variable_name}}
        if _VAR_RE.search(value):
            return _variables_field.process_value(value)

        return value

    def dump(self) -> Dict:
        identifier = (
            self.data.get("action_identifier")
            or f"{self.data['bundle_identifier']}.{self.data['app_intent_identifier']}"
        )
        raw_params = dict(self.data.get("parameters") or {})

        # Process parameter values so that {{variable}} references are
        # serialized into the WFTextTokenString format that WorkflowKit
        # understands, rather than being passed as literal strings.
        params = {
            k: self._serialize_param_value(v) for k, v in raw_params.items()
        }

        descriptor: Dict[str, Optional[str]] = {
            "BundleIdentifier": self.data["bundle_identifier"],
            "AppIntentIdentifier": self.data["app_intent_identifier"],
        }
        team_id = self.data.get("team_identifier")
        if team_id:
            descriptor["TeamIdentifier"] = team_id
        if self.data.get("name"):
            descriptor["Name"] = self.data["name"]
        extras = self.data.get("descriptor_extras") or {}
        descriptor.update(extras)
        params.setdefault("AppIntentDescriptor", descriptor)
        params.setdefault("UUID", (self.data.get("uuid") or str(_uuid.uuid4()).upper()))
        params.setdefault("ShowWhenRun", False)
        return {
            "WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": params,
        }
