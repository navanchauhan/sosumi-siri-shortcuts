from .base import BaseAction, BooleanField, Field


class CreateEventAction(BaseAction):
    '''Create a calendar event'''

    itype = 'is.workflow.actions.addnewevent'
    keyword = 'create_event'

    title = Field('WFCalendarItemTitle', required=False)
    start_date = Field('WFCalendarItemStartDate', required=False)
    end_date = Field('WFCalendarItemEndDate', required=False)
    location = Field('WFCalendarItemLocation', required=False)
    notes = Field('WFCalendarItemNotes', required=False)
    all_day = BooleanField('WFCalendarItemAllDay', required=False)
    uuid = Field('UUID', required=False)


class FindEventsAction(BaseAction):
    '''Find calendar events'''

    itype = 'is.workflow.actions.filter.calendarevents'
    keyword = 'find_events'

    uuid = Field('UUID', required=False)


class GetUpcomingEventsAction(BaseAction):
    '''Get upcoming calendar events'''

    itype = 'is.workflow.actions.getupcomingevents'
    keyword = 'get_upcoming_events'

    uuid = Field('UUID', required=False)


class CreateReminderAction(BaseAction):
    '''Create a reminder'''

    itype = 'is.workflow.actions.addnewreminder'
    keyword = 'create_reminder'

    title = Field('WFReminderTitle', required=False)
    notes = Field('WFReminderNotes', required=False)
    uuid = Field('UUID', required=False)


class FindRemindersAction(BaseAction):
    '''Find reminders'''

    itype = 'is.workflow.actions.filter.reminders'
    keyword = 'find_reminders'

    uuid = Field('UUID', required=False)
