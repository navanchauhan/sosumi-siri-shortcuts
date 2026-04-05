import logging

from .appintent import AppIntentAction
from .b64 import Base64DecodeAction, Base64EncodeAction
from .base import BaseAction, RawAction
from .calculation import CountAction
from .calendar import (
    CreateEventAction,
    CreateReminderAction,
    FindEventsAction,
    FindRemindersAction,
    GetUpcomingEventsAction,
)
from .contacts import (
    EmailAddressAction,
    FindContactsAction,
    GetContactsAction,
    PhoneNumberAction,
    SelectContactAction,
)
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
    LockScreenAction,
    LogOutAction,
    RestartAction,
    SetAirplaneModeAction,
    SetAppearanceAction,
    SetBluetoothAction,
    SetBrightnessAction,
    SetDoNotDisturbAction,
    SetLowPowerModeAction,
    SetMobileDataAction,
    SetNightShiftAction,
    SetSoundOutputAction,
    SetStageManagerAction,
    SetTorchAction,
    SetVolumeAction,
    SetWiFiAction,
    ShutDownAction,
    SleepAction,
)
from .documents import (
    CreatePDFAction,
    GetFileAction,
    MakeHTMLFromRichTextAction,
    MakeMarkdownFromRichTextAction,
    MakeRichTextFromHTMLAction,
    MakeRichTextFromMarkdownAction,
    MarkupAction,
    PrintAction,
    TranscribeAudioAction,
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
from .location import (
    GetAddressFromInputAction,
    GetCurrentLocationAction,
    GetDirectionsAction,
    GetDistanceAction,
    GetTravelTimeAction,
    SearchMapsAction,
    ShowInMapsAction,
)
from .math import (
    CalculateAction,
    CalculateStatisticsAction,
    MeasurementAction,
    RandomNumberAction,
    RoundNumberAction,
)
from .media import (
    AddToPlaylistAction,
    GetCurrentSongAction,
    GetPlaybackDestinationAction,
    PauseMusicAction,
    PlayMusicAction,
    SetPlaybackDestinationAction,
    SkipBackAction,
    SkipForwardAction,
)
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
    GetCurrentWeatherAction,
    GetItemFromListAction,
    GetMyShortcutsAction,
    GetNameAction,
    GetTypeAction,
    GetWeatherForecastAction,
    HashAction,
    ListAction,
    NothingAction,
    OpenAppAction,
    OutputAction,
    RepeatEachEndAction,
    RepeatEachStartAction,
    RepeatEndAction,
    RepeatStartAction,
    RunJavaScriptAction,
    RunShellScriptAction,
    RunShortcutAction,
    SetItemNameAction,
    ViewContentGraphAction,
    WaitToReturnAction,
)
from .sharing import AirDropAction, SendEmailAction, ShareAction
from .text import (
    ChangeCaseAction,
    CombineTextAction,
    CommentAction,
    CorrectSpellingAction,
    DetectLanguageAction,
    GetMatchGroupAction,
    GetNameOfEmojiAction,
    GetTextFromInputAction,
    MatchTextAction,
    ReplaceTextAction,
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
    GetArticleAction,
    GetRSSFeedAction,
    GetURLAction,
    OpenURLAction,
    SearchWebAction,
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
