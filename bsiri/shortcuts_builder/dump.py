import plistlib
from typing import TYPE_CHECKING, Any, BinaryIO, Dict, Type

import toml


if TYPE_CHECKING:
    from .shortcut import Shortcut  # noqa
    from .actions.base import BaseAction  # noqa


class BaseDumper:
    '''
    Base class to dump shortcuts
    '''

    def __init__(self, shortcut: 'Shortcut') -> None:
        self.shortcut = shortcut

    def dump(self, file_obj: BinaryIO) -> None:
        data = self.dumps()

        if isinstance(data, str):
            data = data.encode('utf-8')  # type: ignore
        file_obj.write(data)  # type: ignore

    def dumps(self) -> str:
        raise NotImplementedError()


class PListDumper(BaseDumper):
    '''
    PListDumper is a class which dumps shortcuts to
    binary plist files supported by Apple Shortcuts app
    '''

    def dump(self, file_obj: BinaryIO) -> None:  # type: ignore
        binary = plistlib.dumps(  # todo: change dumps to binary and remove this
            plistlib.loads(self.dumps().encode('utf-8')),  # type: ignore
            fmt=plistlib.FMT_BINARY,
        )
        file_obj.write(binary)

    def dumps(self) -> str:
        data = {
            'WFWorkflowActions': self.shortcut._get_actions(),
            'WFWorkflowImportQuestions': self.shortcut._get_import_questions(),
            'WFWorkflowClientRelease': self.shortcut.client_release,
            'WFWorkflowClientVersion': self.shortcut.client_version,
            'WFWorkflowMinimumClientVersion': self.shortcut.minimal_client_version,
            'WFWorkflowMinimumClientVersionString': str(self.shortcut.minimal_client_version),
            'WFWorkflowTypes': ['NCWidget', 'WatchKit'],
            'WFWorkflowIcon': self.shortcut._get_icon(),
            'WFWorkflowInputContentItemClasses': self.shortcut._get_input_content_item_classes(),
            'WFWorkflowOutputContentItemClasses': [],
            'WFWorkflowHasShortcutInputVariables': False,
            'WFWorkflowHasOutputFallback': False,
        }

        return plistlib.dumps(data).decode('utf-8')


class TomlDumper(BaseDumper):
    '''TomlDumper is a class which dumps shortcuts to toml files'''

    def dumps(self) -> str:
        data = {
            'action': [self._process_action(a) for a in self.shortcut.actions],
        }

        return toml.dumps(data)

    def _process_action(self, action: Type['BaseAction']) -> Dict[str, Any]:
        from .actions.appintent import AppIntentAction
        from .actions.base import RawAction

        if isinstance(action, RawAction):
            raw = action.data.get('_raw_plist', {})
            data = {
                'type': 'raw_action',
                'identifier': raw.get('WFWorkflowActionIdentifier', 'unknown'),
            }
            params = raw.get('WFWorkflowActionParameters', {})
            if params:
                data['parameters'] = params
            return data

        if isinstance(action, AppIntentAction):
            data = {'type': 'app_intent'}
            for key in ('bundle_identifier', 'app_intent_identifier', 'name',
                        'team_identifier', 'uuid', 'action_identifier'):
                val = action.data.get(key)
                if val:
                    data[key] = val
            params = action.data.get('parameters')
            if params:
                data['parameters'] = params
            return data

        data = {
            f._attr: action.data[f._attr]
            for f in action.fields  # type: ignore
            if f._attr in action.data
        }
        data['type'] = action.keyword

        return data
