from .base import BaseAction, ChoiceField, Field, GroupIDField, VariablesField


IF_CHOICES = (
    'Equals',
    'Contains',
    'Is Greater Than',
    'Is Less Than',
    'Begins With',
    'Ends With',
    'Is',
)


class IfAction(BaseAction):
    '''If'''

    itype = 'is.workflow.actions.conditional'
    keyword = 'if'

    _additional_identifier_field = 'WFControlFlowMode'

    condition = ChoiceField(
        'WFCondition', choices=IF_CHOICES, capitalize=True, default=IF_CHOICES[0]
    )
    compare_with = VariablesField('WFConditionalActionString')
    group_id = GroupIDField('GroupingIdentifier')
    input = Field('WFInput', required=False)
    uuid = Field('UUID', required=False)

    default_fields = {
        'WFControlFlowMode': 0,
    }

    def dump(self):
        from .appintent import AppIntentAction
        result = super().dump()
        params = result.setdefault('WFWorkflowActionParameters', {})

        # Re-serialize compare_with through magic var handler if it was a
        # magic var string -- the VariablesField won't handle <<UUID:Name>>
        compare_raw = self.data.get('compare_with')
        if compare_raw and isinstance(compare_raw, str):
            serialized = AppIntentAction._serialize_param_value(compare_raw)
            if serialized != compare_raw:
                params['WFConditionalActionString'] = serialized

        # Serialize input through magic var handler
        input_raw = self.data.get('input')
        if input_raw and isinstance(input_raw, str):
            serialized = AppIntentAction._serialize_param_value(input_raw)
            if serialized != input_raw:
                params['WFInput'] = serialized

        return result


class ElseAction(BaseAction):
    '''Else'''

    itype = 'is.workflow.actions.conditional'
    keyword = 'else'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')
    uuid = Field('UUID', required=False)

    default_fields = {
        'WFControlFlowMode': 1,
    }


class EndIfAction(BaseAction):
    '''EndIf: end a condition'''

    itype = 'is.workflow.actions.conditional'
    keyword = 'endif'

    _additional_identifier_field = 'WFControlFlowMode'

    group_id = GroupIDField('GroupingIdentifier')
    uuid = Field('UUID', required=False)

    default_fields = {
        'WFControlFlowMode': 2,
    }
