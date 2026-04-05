from .base import (
    BaseAction,
    BooleanField,
    ChoiceField,
    Field,
    FloatField,
    GroupIDField,
    IntegerField,
)


class NothingAction(BaseAction):
    '''Nothing'''

    itype = 'is.workflow.actions.nothing'
    keyword = 'nothing'


class SetItemNameAction(BaseAction):
    '''Set item name'''

    # todo: advanced
    # <dict>
    #   <key>WFWorkflowActionIdentifier</key>
    #   <string>is.workflow.actions.setitemname</string>
    #   <key>WFWorkflowActionParameters</key>
    #   <dict>
    #       <key>Advanced</key>
    #       <true/>
    #       <key>WFDontIncludeFileExtension</key>
    #       <true/>
    #   </dict>
    # </dict>

    itype = 'is.workflow.actions.setitemname'
    keyword = 'set_item_name'


class ViewContentGraphAction(BaseAction):
    '''View content graph'''

    itype = 'is.workflow.actions.viewresult'
    keyword = 'view_content_graph'


class ContinueInShortcutAppAction(BaseAction):
    '''Continue in shortcut app'''

    itype = 'is.workflow.actions.handoff'
    keyword = 'continue_in_shortcut_app'


class ChooseFromListAction(BaseAction):
    '''Choose from list'''

    itype = 'is.workflow.actions.choosefromlist'
    keyword = 'choose_from_list'
    prompt = Field('WFChooseFromListActionPrompt', required=False)
    select_multiple = BooleanField(
        'WFChooseFromListActionSelectMultiple', required=False
    )
    select_all_initially = BooleanField(
        'WFChooseFromListActionSelectAll', required=False
    )


class DelayAction(BaseAction):
    '''Delay'''

    itype = 'is.workflow.actions.delay'
    keyword = 'delay'

    time = FloatField('WFDelayTime')


class WaitToReturnAction(BaseAction):
    '''Wait to return'''

    itype = 'is.workflow.actions.waittoreturn'
    keyword = 'wait_to_return'


class RepeatStartAction(BaseAction):
    '''Repeat'''

    itype = 'is.workflow.actions.repeat.count'
    keyword = 'repeat_start'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')
    count = IntegerField('WFRepeatCount')

    default_fields = {
        'WFControlFlowMode': 0,
    }


class RepeatEndAction(BaseAction):
    '''Repeat'''

    itype = 'is.workflow.actions.repeat.count'
    keyword = 'repeat_end'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')

    default_fields = {
        'WFControlFlowMode': 2,
    }


class RepeatEachStartAction(BaseAction):
    '''Repeat with each start'''

    itype = 'is.workflow.actions.repeat.each'
    keyword = 'repeat_with_each_start'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')

    default_fields = {
        'WFControlFlowMode': 0,
    }


class RepeatEachEndAction(BaseAction):
    '''Repeat with each end'''

    itype = 'is.workflow.actions.repeat.each'
    keyword = 'repeat_with_each_end'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')

    default_fields = {
        'WFControlFlowMode': 2,
    }


HASH_CHOICES = (
    'MD5',
    'SHA1',
    'SHA256',
    'SHA512',
)


class HashAction(BaseAction):
    '''Hash action'''

    itype = 'is.workflow.actions.hash'
    keyword = 'hash'

    hash_type = ChoiceField('WFHashType', choices=HASH_CHOICES, default=HASH_CHOICES[0])


class GetMyShortcutsAction(BaseAction):
    '''Get my shortcuts'''

    itype = 'is.workflow.actions.getmyworkflows'
    keyword = 'get_my_shortcuts'


class RunShortcutAction(BaseAction):
    '''Run shortcut'''

    itype = 'is.workflow.actions.runworkflow'
    keyword = 'run_shortcut'

    show = BooleanField('WFShowWorkflow', default=False)
    shortcut_name = Field('WFWorkflowName')


class OpenAppAction(BaseAction):
    '''Opens the specified app.'''

    itype = 'is.workflow.actions.openapp'
    keyword = 'open_app'

    app = Field('WFAppIdentifier')


class GetCurrentWeatherAction(BaseAction):
    '''Get current weather conditions. Supports custom location via location parameter.
    Output can be coerced to text via detect_text (gives "77F and Cloudy" etc).'''

    itype = 'is.workflow.actions.weather.currentconditions'
    keyword = 'get_current_weather'

    uuid = Field('UUID', required=False)
    location = Field('WFWeatherCustomLocation', required=False)

    def dump(self):
        result = super().dump()
        loc = self.data.get('location')
        if loc and isinstance(loc, dict):
            # Build the full placemark structure from simple lat/lng/name
            placemark = loc.get('placemark')
            if not placemark:
                name = loc.get('name', loc.get('city', 'Location'))
                placemark = {
                    'addressDictionary': {
                        'Name': name,
                        'City': loc.get('city', ''),
                        'State': loc.get('state', ''),
                        'Country': loc.get('country', ''),
                        'CountryCode': loc.get('country_code', 'US'),
                        'FormattedAddressLines': [name],
                    },
                    'location': {
                        'latitude': loc.get('latitude', 0),
                        'longitude': loc.get('longitude', 0),
                        'altitude': 0, 'course': -1, 'speed': -1,
                        'horizontalAccuracy': 0, 'verticalAccuracy': -1,
                        'timestamp': __import__('datetime').datetime.now(),
                    },
                    'region': {
                        'center': {
                            'latitude': loc.get('latitude', 0),
                            'longitude': loc.get('longitude', 0),
                        },
                        'radius': 5000.0,
                        'identifier': f"<+{loc.get('latitude', 0)},{loc.get('longitude', 0)}> radius 5000.00",
                    },
                }
            result['WFWorkflowActionParameters']['WFWeatherCustomLocation'] = {'placemark': placemark}
        return result


class GetWeatherForecastAction(BaseAction):
    '''Get weather forecast. Supports custom location via location parameter.'''

    itype = 'is.workflow.actions.weather.forecast'
    keyword = 'get_weather_forecast'

    uuid = Field('UUID', required=False)
    location = Field('WFWeatherCustomLocation', required=False)

    def dump(self):
        result = super().dump()
        loc = self.data.get('location')
        if loc and isinstance(loc, dict):
            placemark = loc.get('placemark')
            if not placemark:
                name = loc.get('name', loc.get('city', 'Location'))
                placemark = {
                    'addressDictionary': {
                        'Name': name,
                        'City': loc.get('city', ''),
                        'State': loc.get('state', ''),
                        'Country': loc.get('country', ''),
                        'CountryCode': loc.get('country_code', 'US'),
                        'FormattedAddressLines': [name],
                    },
                    'location': {
                        'latitude': loc.get('latitude', 0),
                        'longitude': loc.get('longitude', 0),
                        'altitude': 0, 'course': -1, 'speed': -1,
                        'horizontalAccuracy': 0, 'verticalAccuracy': -1,
                        'timestamp': __import__('datetime').datetime.now(),
                    },
                    'region': {
                        'center': {
                            'latitude': loc.get('latitude', 0),
                            'longitude': loc.get('longitude', 0),
                        },
                        'radius': 5000.0,
                        'identifier': f"<+{loc.get('latitude', 0)},{loc.get('longitude', 0)}> radius 5000.00",
                    },
                }
            result['WFWorkflowActionParameters']['WFWeatherCustomLocation'] = {'placemark': placemark}
        return result


class DetectTextAction(BaseAction):
    '''Extract text from the previous action's output (coerces any type to string).'''

    itype = 'is.workflow.actions.detect.text'
    keyword = 'detect_text'

    uuid = Field('UUID', required=False)
    input = Field('WFInput', required=False)

    def dump(self):
        # Process magic var syntax in the input field before dumping
        if self.data.get('input') and isinstance(self.data['input'], str):
            from .appintent import AppIntentAction
            self.data['input'] = AppIntentAction._serialize_param_value(self.data['input'])
        return super().dump()


class RunShellScriptAction(BaseAction):
    '''Run a shell script.'''

    itype = 'is.workflow.actions.runshellscript'
    keyword = 'run_shell_script'

    script = Field('WFScript')
    shell = Field('WFShell', default='/bin/zsh', required=False)
    input_mode = Field('WFShellScriptInputMode', default='to_stdin', required=False)


class GetItemFromListAction(BaseAction):
    '''Get item from list by index'''

    itype = 'is.workflow.actions.getitemfromlist'
    keyword = 'get_item_from_list'

    index = IntegerField('WFItemIndex', required=False)
    uuid = Field('UUID', required=False)


class ListAction(BaseAction):
    '''Create a list'''

    itype = 'is.workflow.actions.list'
    keyword = 'list'

    items = Field('WFItems', required=False)
    uuid = Field('UUID', required=False)


class GetNameAction(BaseAction):
    '''Get the name of an item'''

    itype = 'is.workflow.actions.getitemname'
    keyword = 'get_name'

    uuid = Field('UUID', required=False)


class GetTypeAction(BaseAction):
    '''Get the type of an item'''

    itype = 'is.workflow.actions.getitemtype'
    keyword = 'get_type'

    uuid = Field('UUID', required=False)


class RunJavaScriptAction(BaseAction):
    '''Run JavaScript on a web page'''

    itype = 'is.workflow.actions.runjavascriptonwebpage'
    keyword = 'run_javascript'

    script = Field('WFJavaScript')


class OutputAction(BaseAction):
    '''Stop and output (return value from shortcut)'''

    itype = 'is.workflow.actions.output'
    keyword = 'output'

    uuid = Field('UUID', required=False)
