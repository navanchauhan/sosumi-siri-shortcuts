from .base import BaseAction, Field


class GetContactsAction(BaseAction):
    '''Get contacts'''

    itype = 'is.workflow.actions.contacts'
    keyword = 'get_contacts'

    uuid = Field('UUID', required=False)


class FindContactsAction(BaseAction):
    '''Find contacts matching criteria'''

    itype = 'is.workflow.actions.filter.contacts'
    keyword = 'find_contacts'

    uuid = Field('UUID', required=False)


class PhoneNumberAction(BaseAction):
    '''Create a phone number'''

    itype = 'is.workflow.actions.phonenumber'
    keyword = 'phone_number'

    number = Field('WFPhoneNumber')


class EmailAddressAction(BaseAction):
    '''Create an email address'''

    itype = 'is.workflow.actions.email'
    keyword = 'email_address'

    address = Field('WFEmailAddress')


class SelectContactAction(BaseAction):
    '''Let the user select a contact'''

    itype = 'is.workflow.actions.selectcontact'
    keyword = 'select_contact'

    uuid = Field('UUID', required=False)
