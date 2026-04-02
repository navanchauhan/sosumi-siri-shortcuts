import logging

from .appintent import AppIntentAction, NotesCreateNoteAction, TailscaleGetStatusAction
from .b64 import Base64DecodeAction, Base64EncodeAction
from .base import BaseAction, RawAction
from .calculation import CountAction
from .conditions import ElseAction, EndIfAction, IfAction
from .date import (
    DateAction,
    DetectDateAction,
    FormatDateAction,
    GetTimeBetweenDates,
)
from .device import (
    GetBatteryLevelAction,
    GetDeviceDetailsAction,
    GetIPAddressAction,
    SetAirplaneModeAction,
    SetBluetoothAction,
    SetBrightnessAction,
    SetDoNotDisturbAction,
    SetLowPowerModeAction,
    SetMobileDataAction,
    SetTorchAction,
    SetVolumeAction,
    SetWiFiAction,
)
from .dictionary import (
    DictionaryAction,
    GetDictionaryFromInputAction,
    GetDictionaryValueAction,
    SetDictionaryValueAction,
)
from .files import (
    AppendFileAction,
    CreateFolderAction,
    PreviewDocumentAction,
    ReadFileAction,
    SaveFileAction,
)
from .input import AskAction, GetClipboardAction
from .menu import MenuEndAction, MenuItemAction, MenuStartAction
from .messages import SendMessageAction
from .numbers import NumberAction
from .out import (
    ExitAction,
    NotificationAction,
    SetClipboardAction,
    ShowAlertAction,
    ShowResultAction,
    SpeakTextAction,
    VibrateAction,
)
from .photo import (
    CameraAction,
    GetLastPhotoAction,
    ImageConvertAction,
    SelectPhotoAction,
)
from .registry import ActionsRegistry
from .scripting import (
    ChooseFromListAction,
    ContinueInShortcutAppAction,
    DelayAction,
    DetectTextAction,
    GetMyShortcutsAction,
    HashAction,
    NothingAction,
    OpenAppAction,
    RepeatEachEndAction,
    RepeatEachStartAction,
    RepeatEndAction,
    RepeatStartAction,
    RunShellScriptAction,
    RunShortcutAction,
    SetItemNameAction,
    ViewContentGraphAction,
    WaitToReturnAction,
)
from .text import (
    ChangeCaseAction,
    CommentAction,
    DetectLanguageAction,
    GetNameOfEmojiAction,
    GetTextFromInputAction,
    ScanQRBarCodeAction,
    ShowDefinitionAction,
    SplitTextAction,
    TextAction,
)
from .variables import (
    AppendVariableAction,
    GetVariableAction,
    SetVariableAction,
)
from .web import (
    ExpandURLAction,
    GetURLAction,
    OpenURLAction,
    URLAction,
    URLDecodeAction,
    URLEncodeAction,
)


# flake8: noqa

logger = logging.getLogger(__name__)

actions_registry = ActionsRegistry()


def _register_actions():
    # register all imported actions in the actions registry
    for _, val in globals().items():
        if isinstance(val, type) and issubclass(val, BaseAction) and val.keyword:
            actions_registry.register_action(val)
    logging.debug(f'Registered actions: {len(actions_registry.actions)}')


_register_actions()
