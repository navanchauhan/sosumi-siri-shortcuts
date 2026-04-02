import logging
import os
import plistlib
import uuid
from typing import Any, BinaryIO, Dict, List, Optional, Type

from . import exceptions
from .actions import MenuEndAction, MenuItemAction, MenuStartAction
from .actions.base import GroupIDField
from .dump import BaseDumper, PListDumper, TomlDumper
from .loader import BaseLoader, PListLoader, TomlLoader


logger = logging.getLogger(__name__)

FMT_TOML = 'toml'
FMT_SHORTCUT = 'shortcut'


class Shortcut:
    def __init__(
        self,
        name: str = '',
        client_release: str = '2.0',
        client_version: str = '900',
        minimal_client_version: int = 900,
        actions: List = None,
    ) -> None:
        self.name = name
        self.client_release = client_release
        self.client_version = client_version
        self.minimal_client_version = minimal_client_version
        self.actions = actions if actions else []

    @classmethod
    def load(cls, file_object: BinaryIO, file_format: str = FMT_TOML) -> 'Shortcut':
        '''
        Returns a Shortcut instance from given file_object

        Params:
            file_object (BinaryIO)
            file_format: format of the string, FMT_TOML by default
        '''
        return cls._get_loader_class(file_format).load(file_object)

    @classmethod
    def loads(cls, string: str, file_format: str = FMT_TOML) -> 'Shortcut':
        '''
        Returns a Shortcut instance from given string

        Params:
            string: representation of a shortcut in string
            file_format: format of the string, FMT_TOML by default
        '''
        return cls._get_loader_class(file_format).loads(string)

    @classmethod
    def _get_loader_class(self, file_format: str) -> Type[BaseLoader]:
        """Based on file_format returns loader class for the format"""
        supported_formats = {
            FMT_SHORTCUT: PListLoader,
            FMT_TOML: TomlLoader,
        }
        if file_format in supported_formats:
            logger.debug(f'Loading shortcut from file format: {file_format}')
            return supported_formats[file_format]

        raise RuntimeError(f'Unknown file_format: {file_format}')

    def dump(self, file_object: BinaryIO, file_format: str = FMT_TOML) -> None:
        '''
        Dumps the shortcut instance to file_object

        Params:
            file_object (BinaryIO)
            file_format: format of the string, FMT_TOML by default
        '''
        self._get_dumper_class(file_format)(shortcut=self).dump(file_object)

    def dumps(self, file_format: str = FMT_TOML) -> str:
        '''
        Dumps the shortcut instance and returns a string representation

        Params:
            file_format: format of the string, FMT_TOML by default
        '''
        return self._get_dumper_class(file_format)(shortcut=self).dumps()

    def _get_dumper_class(self, file_format: str) -> Type[BaseDumper]:
        """Based on file_format returns dumper class"""
        supported_formats = {
            FMT_SHORTCUT: PListDumper,
            FMT_TOML: TomlDumper,
        }
        if file_format in supported_formats:
            logger.debug(f'Dumping shortcut to file format: {file_format}')
            return supported_formats[file_format]

        raise RuntimeError(f'Unknown file_format: {file_format}')

    def _get_actions(self) -> List[str]:
        """returns list of all actions"""
        self._resolve_team_identifiers()
        self._auto_insert_detect_text()
        self._assign_uuids()
        self._rewrite_named_vars_to_magic()
        self._set_group_ids()
        self._set_menu_items()
        return [a.dump() for a in self.actions]

    # Cache for bundle_id → app_path lookups
    _app_path_cache: Dict[str, Optional[str]] = {}

    @classmethod
    def _find_app_path(cls, bundle_id: str) -> Optional[str]:
        """Find the .app path for a given bundle identifier.

        Searches /Applications, /System/Applications, and ~/Applications.
        Results are cached across calls.
        """
        if bundle_id in cls._app_path_cache:
            return cls._app_path_cache[bundle_id]

        search_dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices",
            os.path.expanduser("~/Applications"),
        ]

        for base in search_dirs:
            if not os.path.isdir(base):
                continue
            for root, dirs, _files in os.walk(base):
                for d in dirs:
                    if not d.endswith(".app"):
                        continue
                    app_path = os.path.join(root, d)
                    info_plist = os.path.join(app_path, "Contents", "Info.plist")
                    try:
                        with open(info_plist, "rb") as f:
                            info = plistlib.load(f)
                        if info.get("CFBundleIdentifier") == bundle_id:
                            cls._app_path_cache[bundle_id] = app_path
                            return app_path
                    except Exception:
                        continue

        cls._app_path_cache[bundle_id] = None
        return None

    def _resolve_team_identifiers(self):
        """Auto-populate team_identifier for AppIntentActions that lack one.

        Uses codesign to extract the TeamIdentifier from the app binary.
        System apps (e.g. com.apple.Notes) may not have one — that is fine,
        only set it when available.
        """
        from .actions.appintent import AppIntentAction

        try:
            from ..actions import get_team_identifier
        except ImportError:
            # If the top-level actions module isn't available, skip
            logger.debug("Could not import get_team_identifier, skipping auto team_id resolution")
            return

        for action in self.actions:
            if not isinstance(action, AppIntentAction):
                continue
            if action.data.get('team_identifier'):
                continue
            bundle_id = action.data.get('bundle_identifier')
            if not bundle_id:
                continue
            app_path = self._find_app_path(bundle_id)
            if not app_path:
                continue
            tid = get_team_identifier(app_path)
            if tid:
                action.data['team_identifier'] = tid
                logger.debug(f"Auto-resolved team_identifier={tid} for {bundle_id}")

    def _auto_insert_detect_text(self):
        """Auto-insert ``detect_text`` after App Intent actions when the
        next action needs text input (another App Intent, set_variable, text, etc.).

        This handles the type coercion that the plist runner requires:
        App Intent outputs (Bool, Entity, etc.) must be coerced to text
        before being consumed as string parameters.

        Skips insertion if a ``detect_text`` already follows the App Intent.
        """
        from .actions.appintent import AppIntentAction
        from .actions.scripting import DetectTextAction
        from .actions.text import TextAction
        from .actions.variables import SetVariableAction, GetVariableAction

        # Actions that don't need detect_text before them:
        # - DetectTextAction: already handles coercion
        # - SetVariableAction/GetVariableAction: just stores/retrieves, no coercion
        # - TextAction: handles magic vars with aggrandizements directly (needed for entities)
        # - AppIntentAction: will get its own detect_text if needed
        no_coerce_needed = (DetectTextAction, GetVariableAction, SetVariableAction, TextAction, AppIntentAction)

        new_actions = []
        for i, action in enumerate(self.actions):
            new_actions.append(action)
            if not isinstance(action, AppIntentAction):
                continue
            # Don't insert after the very last action
            if i + 1 >= len(self.actions):
                continue
            # Check if next action already handles coercion
            nxt = self.actions[i + 1]
            if isinstance(nxt, no_coerce_needed):
                continue
            # Auto-insert detect_text to coerce the output
            new_actions.append(DetectTextAction(data={}))
        self.actions = new_actions

    def _assign_uuids(self):
        """Ensure every action has a UUID so magic variable references work.

        For actions that have a ``uuid`` Field (AppIntentAction, DetectTextAction),
        this sets ``data['uuid']`` which their ``dump()`` includes as ``UUID``.

        For all other actions, we monkey-patch their ``dump()`` to inject
        ``UUID`` into ``WFWorkflowActionParameters`` after the fact.
        """
        for action in self.actions:
            if not action.data.get('uuid'):
                action.data['uuid'] = str(uuid.uuid4()).upper()

        # Wrap dump() for actions that don't natively emit UUID in params
        for action in self.actions:
            action_uuid = action.data['uuid']
            original_dump = action.dump

            def _patched_dump(orig=original_dump, uid=action_uuid):
                result = orig()
                result.setdefault('WFWorkflowActionParameters', {})
                result['WFWorkflowActionParameters'].setdefault('UUID', uid)
                return result

            action.dump = _patched_dump

    def _rewrite_named_vars_to_magic(self):
        """Rewrite ``set_variable`` + ``{{name}}`` patterns to magic variable
        references so they work through the plist runner.

        The plist runner (``WFShortcutsAppRunnerClient``) doesn't resolve
        named variables between actions.  Magic variables (OutputUUID
        references) *do* work.  This method:

        1. Scans for ``set_variable`` actions and maps each variable name
           to the UUID of the preceding action (whose output set_variable
           captures).
        2. Replaces ``{{name}}`` references in subsequent action parameters
           with ``<<UUID:name>>`` magic variable syntax.
        3. Removes the now-redundant ``set_variable`` and ``get_variable``
           actions from the action list.
        """
        from .actions.variables import SetVariableAction, GetVariableAction

        # Pass 1: build variable_name → source_action_uuid mapping
        var_to_uuid: Dict[str, str] = {}
        for i, action in enumerate(self.actions):
            if isinstance(action, SetVariableAction):
                var_name = action.data.get('name', '')
                if var_name and i > 0:
                    prev = self.actions[i - 1]
                    var_to_uuid[var_name] = prev.data.get('uuid', '')

        if not var_to_uuid:
            return

        # Pass 2: rewrite {{name}} → <<UUID:name>> in action parameters
        import re
        var_pattern = re.compile(r'{{([A-Za-z0-9_-]+)}}')

        def _rewrite_str(s: str) -> str:
            def _replace(m):
                name = m.group(1)
                if name in var_to_uuid and var_to_uuid[name]:
                    return f'<<{var_to_uuid[name]}:{name}>>'
                return m.group(0)  # leave unchanged if not a known variable
            return var_pattern.sub(_replace, s)

        def _rewrite_value(v):
            if isinstance(v, str):
                return _rewrite_str(v)
            if isinstance(v, dict):
                return {k: _rewrite_value(val) for k, val in v.items()}
            if isinstance(v, list):
                return [_rewrite_value(item) for item in v]
            return v

        for action in self.actions:
            if isinstance(action, (SetVariableAction, GetVariableAction)):
                continue
            action.data = _rewrite_value(action.data)

        # Pass 3: remove set_variable and get_variable actions
        self.actions = [
            a for a in self.actions
            if not isinstance(a, (SetVariableAction, GetVariableAction))
        ]

    def _set_group_ids(self):
        """
        Automatically sets group_id based on WFControlFlowMode param
        Uses list as a stack to hold generated group_ids

        Each cycle or condition (if-else, repeat) in Shortcuts app must have group id.
        Start and end of the cycle must have the same group_id. To do this,
        we use stack to save generated or readed group_id to save it to all actions of the cycle
        """
        ids = []
        for action in self.actions:
            # if action has GroupIDField, we may need to generate it's value automatically
            if not isinstance(getattr(action, 'group_id', None), GroupIDField):
                continue

            control_mode = action.default_fields['WFControlFlowMode']
            if control_mode == 0:
                # 0 means beginning of the group
                group_id = action.data.get('group_id', str(uuid.uuid4()))
                action.data['group_id'] = group_id  # if wasn't defined
                ids.append(group_id)
            elif control_mode == 1:
                # 1 - else, so we don't need to remove group_id from the stack
                # we need to just use the latest one
                action.data['group_id'] = ids[-1]
            elif control_mode == 2:
                # end of the group, we must remove group_id
                try:
                    action.data['group_id'] = ids.pop()
                except IndexError:
                    # if actions are correct, all groups must be compelted
                    # (group complete if it has start and end actions)
                    raise exceptions.IncompleteCycleError('Incomplete cycle')

    def _set_menu_items(self):
        '''
        Menu consists of many items:
            start menu
            menu item 1
            menu item2
            end menu
        And start menu must know all items (titles).
        So this function iterates over all actions, finds menu items and saves information
        about them to a corresponding "start menu" action.

        # todo: move to menu item logic
        '''
        menus = []
        for action in self.actions:
            if isinstance(action, MenuStartAction):
                action.data['menu_items'] = []
                menus.append(action)
            elif isinstance(action, MenuItemAction):
                menus[-1].data['menu_items'].append(action.data['title'])
            elif isinstance(action, MenuEndAction):
                try:
                    menus.pop()
                except IndexError:
                    raise exceptions.IncompleteCycleError('Incomplete menu cycle')

    def _get_import_questions(self) -> List:
        # todo: change me
        return []

    def _get_icon(self) -> Dict[str, Any]:
        # todo: change me
        return {
            'WFWorkflowIconGlyphNumber': 59511,
            'WFWorkflowIconImageData': bytes(b''),
            'WFWorkflowIconStartColor': 431817727,
        }

    def _get_input_content_item_classes(self) -> List[str]:
        # todo: change me
        return [
            'WFAppStoreAppContentItem',
            'WFArticleContentItem',
            'WFContactContentItem',
            'WFDateContentItem',
            'WFEmailAddressContentItem',
            'WFGenericFileContentItem',
            'WFImageContentItem',
            'WFiTunesProductContentItem',
            'WFLocationContentItem',
            'WFDCMapsLinkContentItem',
            'WFAVAssetContentItem',
            'WFPDFContentItem',
            'WFPhoneNumberContentItem',
            'WFRichTextContentItem',
            'WFSafariWebPageContentItem',
            'WFStringContentItem',
            'WFURLContentItem',
        ]
