from .base import BaseAction, BooleanField, ChoiceField, Field, VariablesField


class CommentAction(BaseAction):
    '''Comment: just a comment'''

    itype = 'is.workflow.actions.comment'
    keyword = 'comment'

    text = Field('WFCommentActionText', help='Text to show in the comment')


class TextAction(BaseAction):
    '''Text: returns text as an output.

    Supports ``{{named_var}}``, ``<<UUID:Name>>`` magic variables, and
    literal text mixed together.
    '''

    itype = 'is.workflow.actions.gettext'
    keyword = 'text'

    text = VariablesField('WFTextActionText', help='Output of this action')
    uuid = Field('UUID', required=False)

    def dump(self):
        # Use AppIntentAction's serializer for the text field so that
        # <<UUID:Name>> magic variable references work in addition to
        # the {{named_var}} references that VariablesField handles.
        from .appintent import AppIntentAction

        data = super().dump()
        raw_text = self.data.get('text', '')
        if isinstance(raw_text, str) and '<<' in raw_text:
            data['WFWorkflowActionParameters']['WFTextActionText'] = (
                AppIntentAction._serialize_param_value(raw_text)
            )
        if self.data.get('uuid'):
            data['WFWorkflowActionParameters']['UUID'] = self.data['uuid']
        return data


CASE_CHOICES = (
    'UPPERCASE',
    'lowercase',
    'Capitalize Every Word',
    'Capitalize with Title Case',
    'Capitalize with sentence case.',
    'cApItAlIzE wItH aLtErNaTiNg CaSe.',
)


class ChangeCaseAction(BaseAction):
    '''Change case'''

    itype = 'is.workflow.actions.text.changecase'
    keyword = 'change_case'

    case_type = ChoiceField('WFCaseType', choices=CASE_CHOICES)


SPLIT_SEPARATOR_CHOICES = (
    'New Lines',
    'Spaces',
    'Every Character',
    'Custom',
)


class SplitTextAction(BaseAction):
    '''Split text'''

    itype = 'is.workflow.actions.text.split'
    keyword = 'split_text'

    separator_type = ChoiceField(
        'WFTextSeparator',
        choices=SPLIT_SEPARATOR_CHOICES,
        default=SPLIT_SEPARATOR_CHOICES[0],
    )
    custom_separator = Field(
        'WFTextCustomSeparator',
        help='Works only with "Custom" `separator_type`',
        required=False,
    )


class DetectLanguageAction(BaseAction):
    '''Detect Language with Microsoft'''

    itype = 'is.workflow.actions.detectlanguage'
    keyword = 'detect_language'


class GetNameOfEmojiAction(BaseAction):
    '''Get name of emoji'''

    itype = 'is.workflow.actions.getnameofemoji'
    keyword = 'get_name_of_emoji'


class GetTextFromInputAction(BaseAction):
    '''
    Get text from input

    Returns text from the previous action's input.
    For example, this action can get the name of a photo
    or song, or the text of a web page.
    '''

    itype = 'is.workflow.actions.detect.text'
    keyword = 'get_text_from_input'


class ScanQRBarCodeAction(BaseAction):
    '''Scan QR/Barcode'''

    itype = 'is.workflow.actions.scanbarcode'
    keyword = 'scan_barcode'


class ShowDefinitionAction(BaseAction):
    '''Show definition'''

    itype = 'is.workflow.actions.showdefinition'
    keyword = 'show_definition'


class CombineTextAction(BaseAction):
    '''Combine a list of text into one'''

    itype = 'is.workflow.actions.text.combine'
    keyword = 'combine_text'

    separator = Field('WFTextSeparator', required=False)
    custom_separator = Field('WFTextCustomSeparator', required=False)
    uuid = Field('UUID', required=False)


class MatchTextAction(BaseAction):
    '''Match text with a regular expression'''

    itype = 'is.workflow.actions.text.match'
    keyword = 'match_text'

    pattern = Field('WFMatchTextPattern')
    case_sensitive = BooleanField('WFMatchTextCaseSensitive', required=False)
    uuid = Field('UUID', required=False)


class GetMatchGroupAction(BaseAction):
    '''Get a group from matched text'''

    itype = 'is.workflow.actions.text.match.getgroup'
    keyword = 'get_match_group'

    index = Field('WFGetGroupType', required=False)
    uuid = Field('UUID', required=False)


class ReplaceTextAction(BaseAction):
    '''Replace text using find/replace'''

    itype = 'is.workflow.actions.text.replace'
    keyword = 'replace_text'

    find = Field('WFReplaceTextFind')
    replace_with = Field('WFReplaceTextReplace', required=False)
    case_sensitive = BooleanField('WFReplaceTextCaseSensitive', required=False)
    regex = BooleanField('WFReplaceTextRegularExpression', required=False)
    uuid = Field('UUID', required=False)


class CorrectSpellingAction(BaseAction):
    '''Correct spelling of text'''

    itype = 'is.workflow.actions.correctspelling'
    keyword = 'correct_spelling'

    uuid = Field('UUID', required=False)
