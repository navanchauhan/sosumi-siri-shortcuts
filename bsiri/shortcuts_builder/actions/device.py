from .base import BaseAction, BooleanField, ChoiceField, Field, FloatField


class GetBatteryLevelAction(BaseAction):
    '''Get battery level'''

    itype = 'is.workflow.actions.getbatterylevel'
    keyword = 'get_battery_level'


class GetIPAddressAction(BaseAction):
    '''Get current IP address'''

    itype = 'is.workflow.actions.getipaddress'
    keyword = 'get_ip_address'

    source = ChoiceField('WFIPAddressSourceOption', choices=('Local', 'Global'))
    address_type = ChoiceField('WFIPAddressTypeOption', choices=('IPv4', 'IPv6'))


DEVICE_DETAIL_CHOICES = (
    'Device Name',
    'Device Model',
    'System Version',
    'Screen Width',
    'Screen Height',
    'Current Volume',
    'Current Brightness',
)


class GetDeviceDetailsAction(BaseAction):
    '''Get device details'''

    itype = 'is.workflow.actions.getdevicedetails'
    keyword = 'get_device_details'

    detail = ChoiceField('WFDeviceDetail', choices=DEVICE_DETAIL_CHOICES)


class SetAirplaneModeAction(BaseAction):
    '''Set airplane mode'''

    itype = 'is.workflow.actions.airplanemode.set'
    keyword = 'set_airplane_mode'

    on = BooleanField('OnValue')


class SetBluetoothAction(BaseAction):
    '''Set bluetooth'''

    itype = 'is.workflow.actions.bluetooth.set'
    keyword = 'set_bluetooth'

    on = BooleanField('OnValue')


class SetBrightnessAction(BaseAction):
    '''Set brightness'''

    itype = 'is.workflow.actions.setbrightness'
    keyword = 'set_brightness'

    level = FloatField('WFBrightness')


class SetMobileDataAction(BaseAction):
    '''Set mobile data'''

    itype = 'is.workflow.actions.cellulardata.set'
    keyword = 'set_mobile_data'

    on = BooleanField('OnValue')


class SetDoNotDisturbAction(BaseAction):
    '''Set Do Not Disturb'''

    itype = 'is.workflow.actions.dnd.set'
    keyword = 'set_do_not_disturb'

    default_fields = {
        'AssertionType': 'Turned Off',  # todo: support more "until"
    }

    enabled = BooleanField('Enabled')


class SetTorchAction(BaseAction):
    '''Set Torch'''

    itype = 'is.workflow.actions.flashlight'
    keyword = 'set_torch'

    mode = ChoiceField('WFFlashlightSetting', choices=('Off', 'On', 'Toggle'))


class SetLowPowerModeAction(BaseAction):
    '''Set Low Power mode'''

    itype = 'is.workflow.actions.lowpowermode.set'
    keyword = 'set_low_power_mode'

    on = BooleanField('OnValue', default=True)


class SetVolumeAction(BaseAction):
    '''Set volume'''

    itype = 'is.workflow.actions.setvolume'
    keyword = 'set_volume'

    level = FloatField('WFVolume')


class SetWiFiAction(BaseAction):
    '''Set WiFi'''

    itype = 'is.workflow.actions.wifi.set'
    keyword = 'set_wifi'

    on = BooleanField('OnValue')


class SetAppearanceAction(BaseAction):
    '''Set light/dark mode'''

    itype = 'is.workflow.actions.appearance'
    keyword = 'set_appearance'

    style = Field('WFAppearance', required=False)  # Light, Dark, Toggle


class SetNightShiftAction(BaseAction):
    '''Toggle Night Shift'''

    itype = 'is.workflow.actions.nightshift'
    keyword = 'set_night_shift'

    enabled = BooleanField('WFNightShiftEnabled', required=False)


class SetStageManagerAction(BaseAction):
    '''Toggle Stage Manager'''

    itype = 'is.workflow.actions.stagemanager'
    keyword = 'set_stage_manager'

    enabled = BooleanField('WFStageManagerEnabled', required=False)


class LockScreenAction(BaseAction):
    '''Lock the screen'''

    itype = 'is.workflow.actions.lockscreen'
    keyword = 'lock_screen'


class LogOutAction(BaseAction):
    '''Log out the current user'''

    itype = 'is.workflow.actions.logout'
    keyword = 'log_out'


class SleepAction(BaseAction):
    '''Put the computer to sleep'''

    itype = 'is.workflow.actions.sleep'
    keyword = 'sleep_computer'


class RestartAction(BaseAction):
    '''Restart the computer'''

    itype = 'is.workflow.actions.restart'
    keyword = 'restart'


class ShutDownAction(BaseAction):
    '''Shut down the computer'''

    itype = 'is.workflow.actions.shutdown'
    keyword = 'shut_down'


class SetSoundOutputAction(BaseAction):
    '''Set the sound output device'''

    itype = 'is.workflow.actions.setsoundoutput'
    keyword = 'set_sound_output'
