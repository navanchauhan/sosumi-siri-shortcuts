from .base import BaseAction, Field


class GetCurrentLocationAction(BaseAction):
    '''Get the current location of the device'''

    itype = 'is.workflow.actions.location'
    keyword = 'get_current_location'

    uuid = Field('UUID', required=False)


class GetDirectionsAction(BaseAction):
    '''Get directions to a location'''

    itype = 'is.workflow.actions.getdirections'
    keyword = 'get_directions'

    transport_type = Field('WFGetDirectionsActionMode', required=False)
    uuid = Field('UUID', required=False)


class GetDistanceAction(BaseAction):
    '''Get the distance between two locations'''

    itype = 'is.workflow.actions.getdistance'
    keyword = 'get_distance'

    uuid = Field('UUID', required=False)


class GetTravelTimeAction(BaseAction):
    '''Get the travel time between two locations'''

    itype = 'is.workflow.actions.gettraveltime'
    keyword = 'get_travel_time'

    transport_type = Field('WFGetDirectionsActionMode', required=False)
    uuid = Field('UUID', required=False)


class SearchMapsAction(BaseAction):
    '''Search for a location in Maps'''

    itype = 'is.workflow.actions.searchmaps'
    keyword = 'search_maps'

    query = Field('WFSearchQuery', required=False)
    uuid = Field('UUID', required=False)


class ShowInMapsAction(BaseAction):
    '''Show a location in Maps'''

    itype = 'is.workflow.actions.showinmaps'
    keyword = 'show_in_maps'

    uuid = Field('UUID', required=False)


class GetAddressFromInputAction(BaseAction):
    '''Get street address from text input'''

    itype = 'is.workflow.actions.detect.address'
    keyword = 'get_address'

    uuid = Field('UUID', required=False)
