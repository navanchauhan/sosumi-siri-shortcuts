from .base import BaseAction, Field


class ShareAction(BaseAction):
    '''Share via the share sheet'''

    itype = 'is.workflow.actions.share'
    keyword = 'share'


class AirDropAction(BaseAction):
    '''Send via AirDrop'''

    itype = 'is.workflow.actions.airdrop'
    keyword = 'airdrop'


class SendEmailAction(BaseAction):
    '''Send an email'''

    itype = 'is.workflow.actions.sendemail'
    keyword = 'send_email'

    to = Field('WFSendEmailActionToRecipients', required=False)
    subject = Field('WFSendEmailActionSubject', required=False)
    body = Field('WFSendEmailActionBody', required=False)
    show_compose = Field('WFSendEmailActionShowComposeSheet', required=False)
