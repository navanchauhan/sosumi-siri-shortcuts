from typing import Dict, Union

from .base import BaseAction, BooleanField, DictionaryField, Field, IntegerField


class URLAction(BaseAction):
    '''URL: returns url as an output'''

    itype = 'is.workflow.actions.url'
    keyword = 'url'

    url = Field('WFURLActionURL')


class HTTPMethodField(Field):
    methods = (
        'GET',
        'POST',
        'PUT',
        'PATCH',
        'DELETE',
    )

    def process_value(self, value):
        value = super().process_value(value).upper()
        if value not in self.methods:
            raise ValueError(
                f'Unsupported HTTP method: {value}. \nSupported: {self.methods}'
            )
        return value


class GetURLAction(BaseAction):
    '''Get URL'''

    itype = 'is.workflow.actions.downloadurl'
    keyword = 'get_url'

    advanced = BooleanField('Advanced', required=False)
    method = HTTPMethodField('WFHTTPMethod', required=False)
    headers = DictionaryField('WFHTTPHeaders', required=False)
    json = DictionaryField('WFJSONValues', required=False)  # todo: array or dict
    form = DictionaryField('WFFormValues', required=False)  # todo: array or dict
    url = Field('WFInput', required=False)

    def __init__(self, data: Union[Dict, None] = None) -> None:
        self.default_fields = {}
        super().__init__(data=data)

        if data and data.get('form'):
            self.default_fields['WFHTTPBodyType'] = 'Form'
        elif data and data.get('json'):
            self.default_fields['WFHTTPBodyType'] = 'Json'

        if data and data.get('headers'):
            self.default_fields['ShowHeaders'] = True

    def dump(self):
        # Process magic var syntax in the url field before dumping
        if self.data.get('url') and isinstance(self.data['url'], str):
            from .appintent import AppIntentAction
            self.data['url'] = AppIntentAction._serialize_param_value(self.data['url'])
        return super().dump()


class URLEncodeAction(BaseAction):
    '''URL Encode'''

    itype = 'is.workflow.actions.urlencode'
    keyword = 'urlencode'

    _additional_identifier_field = 'WFEncodeMode'
    _default_class = True

    default_fields = {
        'WFEncodeMode': 'Encode',
    }


class URLDecodeAction(BaseAction):
    '''URL Dencode'''

    itype = 'is.workflow.actions.urlencode'
    keyword = 'urldecode'

    _additional_identifier_field = 'WFEncodeMode'

    default_fields = {
        'WFEncodeMode': 'Decode',
    }


class ExpandURLAction(BaseAction):
    '''
    Expand URL: This action expands and cleans up URLs
    that have been shortened by a URL shortening
    service like TinyURL or bit.ly
    '''

    itype = 'is.workflow.actions.url.expand'
    keyword = 'expand_url'


class OpenURLAction(BaseAction):
    '''Open URL from previous action'''

    itype = 'is.workflow.actions.openurl'
    keyword = 'open_url'


class GetArticleAction(BaseAction):
    '''Get the article from a web page (reader mode)'''

    itype = 'is.workflow.actions.getarticle'
    keyword = 'get_article'

    uuid = Field('UUID', required=False)


class GetRSSFeedAction(BaseAction):
    '''Get items from an RSS feed'''

    itype = 'is.workflow.actions.rss'
    keyword = 'get_rss_feed'

    count = IntegerField('WFRSSItemQuantity', required=False)
    uuid = Field('UUID', required=False)


class SearchWebAction(BaseAction):
    '''Search the web'''

    itype = 'is.workflow.actions.searchweb'
    keyword = 'search_web'

    query = Field('WFSearchQuery', required=False)
