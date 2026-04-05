from .base import BaseAction, BooleanField, Field


class CreatePDFAction(BaseAction):
    '''Create a PDF from input'''

    itype = 'is.workflow.actions.makepdf'
    keyword = 'create_pdf'

    uuid = Field('UUID', required=False)


class MarkupAction(BaseAction):
    '''Markup an image or PDF'''

    itype = 'is.workflow.actions.markup'
    keyword = 'markup'

    uuid = Field('UUID', required=False)


class PrintAction(BaseAction):
    '''Print the input'''

    itype = 'is.workflow.actions.print'
    keyword = 'print'


class MakeRichTextFromHTMLAction(BaseAction):
    '''Convert HTML to rich text'''

    itype = 'is.workflow.actions.getrichtextfromhtml'
    keyword = 'rich_text_from_html'

    uuid = Field('UUID', required=False)


class MakeRichTextFromMarkdownAction(BaseAction):
    '''Convert Markdown to rich text'''

    itype = 'is.workflow.actions.getrichtextfrommarkdown'
    keyword = 'rich_text_from_markdown'

    uuid = Field('UUID', required=False)


class MakeHTMLFromRichTextAction(BaseAction):
    '''Convert rich text to HTML'''

    itype = 'is.workflow.actions.gethtmlfromrichtext'
    keyword = 'html_from_rich_text'

    uuid = Field('UUID', required=False)


class MakeMarkdownFromRichTextAction(BaseAction):
    '''Convert rich text to Markdown'''

    itype = 'is.workflow.actions.getmarkdownfromrichtext'
    keyword = 'markdown_from_rich_text'

    uuid = Field('UUID', required=False)


class GetFileAction(BaseAction):
    '''Get a file from iCloud or local'''

    itype = 'is.workflow.actions.documentpicker.open'
    keyword = 'get_file'

    path = Field('WFGetFilePath', required=False)
    show_picker = BooleanField('WFFilePickerShowDocumentPicker', required=False)
    uuid = Field('UUID', required=False)


class TranscribeAudioAction(BaseAction):
    '''Transcribe audio to text'''

    itype = 'is.workflow.actions.transcribeaudio'
    keyword = 'transcribe_audio'

    uuid = Field('UUID', required=False)
