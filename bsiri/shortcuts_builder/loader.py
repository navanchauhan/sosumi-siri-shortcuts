import collections
import copy
import plistlib
from typing import TYPE_CHECKING, Any, BinaryIO, Dict, List, Type, Union

import toml

from . import exceptions
from .actions import actions_registry
from .actions.base import SYSTEM_VARIABLES_TYPE_TO_VAR


if TYPE_CHECKING:
    from .shortcut import Shortcut  # noqa
    from .actions.base import BaseAction  # noqa


class BaseLoader:
    '''Base class for all classes which load shortcuts from files or strings'''

    @classmethod
    def load(cls, file_obj: BinaryIO) -> 'Shortcut':
        content = file_obj.read()

        return cls.loads(content)  # type: ignore

    @classmethod
    def loads(cls, string: str) -> 'Shortcut':
        raise NotImplementedError()


class TomlLoader(BaseLoader):
    @classmethod
    def loads(cls, string: str) -> 'Shortcut':
        from .shortcut import Shortcut  # noqa

        if isinstance(string, (bytearray, bytes)):
            string = string.decode('utf-8')

        shortcut_dict = toml.loads(string)
        shortcut = Shortcut(name=shortcut_dict.get('name', 'python-shortcuts'))

        if not isinstance(shortcut_dict.get('action'), list):
            raise ValueError('toml file must contain "action" array with actions')

        for params in shortcut_dict['action']:
            action_params = copy.deepcopy(params)
            del action_params['type']

            action_class = actions_registry.get_by_keyword(params['type'])
            action = action_class(data=action_params)
            shortcut.actions.append(action)

        return shortcut


class PListLoader(BaseLoader):
    @classmethod
    def loads(cls, string: Union[str, bytes]) -> 'Shortcut':
        from .shortcut import Shortcut  # noqa

        if isinstance(string, str):
            string = string.encode('utf-8')

        shortcut_dict: Dict = plistlib.loads(string)
        shortcut = Shortcut(
            name=shortcut_dict.get('name', 'python-shortcuts'),
            client_release=shortcut_dict['WFWorkflowClientRelease'],
            client_version=shortcut_dict['WFWorkflowClientVersion'],
        )

        for action in shortcut_dict['WFWorkflowActions']:
            shortcut.actions.append(cls._action_from_dict(action))

        return shortcut

    @classmethod
    def _action_from_dict(cls, action_dict: Dict) -> 'BaseAction':
        '''Returns action instance from the dictionary with all necessary parameters'''
        from .actions.appintent import AppIntentAction
        from .actions.base import RawAction

        identifier = action_dict['WFWorkflowActionIdentifier']
        params = action_dict.get('WFWorkflowActionParameters', {})

        # Check if this is an App Intent action (has AppIntentDescriptor)
        descriptor = params.get('AppIntentDescriptor')
        if descriptor and isinstance(descriptor, dict):
            data = {
                'action_identifier': identifier,
                'bundle_identifier': descriptor.get('BundleIdentifier', ''),
                'app_intent_identifier': descriptor.get('AppIntentIdentifier', ''),
                'name': descriptor.get('Name'),
                'team_identifier': descriptor.get('TeamIdentifier'),
                'uuid': params.get('UUID'),
            }
            # Collect remaining params (exclude internal keys)
            skip = {'AppIntentDescriptor', 'UUID'}
            extra_params = {}
            for k, v in params.items():
                if k in skip:
                    continue
                extra_params[k] = cls._deserialize_value(v)
            if extra_params:
                data['parameters'] = extra_params
            return AppIntentAction(data=data)

        # Try registered action types
        try:
            action_class = actions_registry.get_by_itype(
                itype=identifier, action_params=action_dict,
            )
        except exceptions.UnknownActionError:
            # Fallback to RawAction for unrecognized types
            return RawAction(data={'_raw_plist': action_dict})

        shortcut_name_to_field_name = {f.name: f._attr for f in action_class().fields}
        action_params = {}
        for p, v in params.items():
            if p in shortcut_name_to_field_name:
                try:
                    action_params[shortcut_name_to_field_name[p]] = WFDeserializer(v).deserialized_data
                except (exceptions.UnknownVariableError, exceptions.UnknownWFTextTokenAttachment,
                        exceptions.UnknownSerializationType, KeyError):
                    # Preserve raw value if deserialization fails
                    action_params[shortcut_name_to_field_name[p]] = v

        return action_class(data=action_params)

    @classmethod
    def _deserialize_value(cls, v):
        """Best-effort deserialization of a plist parameter value."""
        try:
            return WFDeserializer(v).deserialized_data
        except Exception:
            return v


class WFDeserializer:
    """
    Deserializer for WF fields (from shortcuts plist)
    which converts their data to a format acceptable by Actions
    """

    def __init__(self, data) -> None:
        self._data = data

    @property
    def deserialized_data(self) -> Union[str, List, Dict]:
        if not isinstance(self._data, dict):
            # todo: check if there are other types

            return self._data

        # based on 'WFSerializationType' from the self._data
        # we need to choose a proper class to deserialize it
        serialization_to_field_map: Dict[str, Type[WFDeserializer]] = {
            'WFTextTokenString': WFVariableStringField,
            'WFDictionaryFieldValue': WFDictionaryField,
            'WFTextTokenAttachment': WFTextTokenAttachmentField,
            'WFTokenAttachmentParameterState': WFTokenAttachmentParameterStateField,
        }

        ser_type = self._data.get('WFSerializationType')
        deserializer = serialization_to_field_map.get(ser_type)

        if deserializer:
            return deserializer(self._data).deserialized_data

        # Fallback: return raw dict for unknown serialization types
        return self._data


class WFTokenAttachmentParameterStateField(WFDeserializer):
    def __init__(self, data) -> None:
        self._data = data['Value']


class WFTextTokenAttachmentField(WFDeserializer):
    @property
    def deserialized_data(self) -> str:
        value = self._data.get('Value', {})
        field_type = value.get('Type')

        if field_type in SYSTEM_VARIABLES_TYPE_TO_VAR:
            return '{{%s}}' % SYSTEM_VARIABLES_TYPE_TO_VAR[field_type]

        if field_type == 'Variable':
            return value.get('VariableName')  # todo: #2

        if field_type == 'ActionOutput':
            output_uuid = value.get('OutputUUID', '')
            output_name = value.get('OutputName', 'Output')
            suffix = ''
            for aggr in value.get('Aggrandizements', []):
                aggr_type = aggr.get('Type', '')
                if aggr_type == 'WFPropertyVariableAggrandizement':
                    suffix += f".{aggr.get('PropertyName', '')}"
                elif aggr_type == 'WFDictionaryValueVariableAggrandizement':
                    suffix += f"['{aggr.get('DictionaryKey', '')}']"
                elif aggr_type == 'WFCoercionVariableAggrandizement':
                    # Reverse-map the content item class to a friendly name
                    cls_name = aggr.get('CoercionItemClass', '')
                    friendly = cls_name.replace('WF', '').replace('ContentItem', '').lower()
                    suffix += f" as {friendly}"
            return f'<<{output_uuid}:{output_name}{suffix}>>'

        raise exceptions.UnknownWFTextTokenAttachment(
            f'Unknown token attachment type: {field_type}',
        )


class WFDictionaryField(WFDeserializer):
    @property
    def deserialized_data(self) -> List[Dict[str, Any]]:
        result = []

        for item in self._data['Value']['WFDictionaryFieldValueItems']:
            key = WFDeserializer(item['WFKey']).deserialized_data
            value = WFDeserializer(item['WFValue']).deserialized_data
            result.append({'key': key, 'value': value})

        return result


class WFVariableStringField(WFDeserializer):
    """
    Converts wf variable string (dictionary)
        <dict>
            <key>Value</key>
            <dict>
                <key>attachmentsByRange</key>
                <dict>
                    <key>{7, 1}</key>
                    <dict>
                        <key>Type</key>
                        <string>Variable</string>
                        <key>VariableName</key>
                        <string>name</string>
                    </dict>
                </dict>
                <key>string</key>
                <string>Hello, ￼!</string>
            </dict>
            <key>WFSerializationType</key>
            <string>WFTextTokenString</string>
        </dict>

    to a shortcuts-string:
        "Hello, {{var}}!"
    """

    @property
    def deserialized_data(self) -> str:
        '''
        Raises:
            shortcuts.exceptions.UnknownVariableError: if variable's type is not supported
        '''
        # if this field is a string with variables,
        # we need to convert it into our representation
        value = self._data['Value']
        value_string = value['string']

        positions = {}

        # sometimes variables are system (read more near SYSTEM_VARIABLES_TYPE_TO_VAR definition)
        # and we need to detect this by checking variable's type
        # if it is not supported - raise an exception
        supported_types = list(SYSTEM_VARIABLES_TYPE_TO_VAR.keys()) + ['Variable']

        for variable_range, variable_data in value['attachmentsByRange'].items():
            variable_type = variable_data['Type']

            if variable_type == 'ActionOutput':
                # Magic variable — render as <<UUID:Name>>
                output_uuid = variable_data.get('OutputUUID', '')
                output_name = variable_data.get('OutputName', 'Output')
                variable_name = f'<<{output_uuid}:{output_name}>>'
                # We'll handle the replacement below with proper positioning
                position = self._get_position(variable_range)
                positions[position] = variable_name
                continue

            if variable_type not in supported_types:
                raise exceptions.UnknownVariableError(
                    f'Unknown variable type: {variable_type}',
                )

            if variable_type == 'Variable':
                variable_name = variable_data['VariableName']
            elif variable_type in SYSTEM_VARIABLES_TYPE_TO_VAR:
                variable_name = SYSTEM_VARIABLES_TYPE_TO_VAR[variable_type]

            # let's find positions of all variables in the string
            position = self._get_position(variable_range)
            positions[position] = '{{%s}}' % variable_name

        # and then replace them with '{{variable_name}}'
        offset = 0

        for pos, variable in collections.OrderedDict(sorted(positions.items())).items():
            value_string = (
                value_string[: pos + offset]
                + variable
                + value_string[pos + offset :]  # noqa
            )
            offset += len(variable)

        return value_string

    def _get_position(self, range_str: str) -> int:
        ranges = list(map(lambda x: int(x.strip()), range_str.strip('{} ').split(',')))

        return ranges[0]
