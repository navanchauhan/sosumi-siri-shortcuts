from .base import BaseAction, BooleanField, Field


class PlayMusicAction(BaseAction):
    '''Play music'''

    itype = 'is.workflow.actions.playmusic'
    keyword = 'play_music'

    shuffle = BooleanField('WFPlayMusicActionShuffle', required=False)
    repeat = Field('WFPlayMusicActionRepeat', required=False)


class GetCurrentSongAction(BaseAction):
    '''Get the currently playing song'''

    itype = 'is.workflow.actions.getcurrentsong'
    keyword = 'get_current_song'

    uuid = Field('UUID', required=False)


class PauseMusicAction(BaseAction):
    '''Pause/resume music playback'''

    itype = 'is.workflow.actions.pausemusic'
    keyword = 'pause_music'

    behavior = Field('WFPlayPauseBehavior', required=False)  # Play, Pause, Toggle


class SkipForwardAction(BaseAction):
    '''Skip to the next song'''

    itype = 'is.workflow.actions.skipforward'
    keyword = 'skip_forward'


class SkipBackAction(BaseAction):
    '''Skip to the previous song'''

    itype = 'is.workflow.actions.skipback'
    keyword = 'skip_back'


class AddToPlaylistAction(BaseAction):
    '''Add a song to a playlist'''

    itype = 'is.workflow.actions.addtoplaylist'
    keyword = 'add_to_playlist'

    playlist = Field('WFPlaylistName', required=False)


class SetPlaybackDestinationAction(BaseAction):
    '''Set the audio playback destination'''

    itype = 'is.workflow.actions.setplaybackdestination'
    keyword = 'set_playback_destination'


class GetPlaybackDestinationAction(BaseAction):
    '''Get current audio playback destination'''

    itype = 'is.workflow.actions.getplaybackdestination'
    keyword = 'get_playback_destination'

    uuid = Field('UUID', required=False)
