from .base import BaseAction, Field, FloatField


class CalculateAction(BaseAction):
    '''Perform a math calculation'''

    itype = 'is.workflow.actions.math'
    keyword = 'calculate'

    operation = Field('WFMathOperation', required=False)
    operand = FloatField('WFMathOperand', required=False)
    uuid = Field('UUID', required=False)


class RoundNumberAction(BaseAction):
    '''Round a number'''

    itype = 'is.workflow.actions.round'
    keyword = 'round_number'

    mode = Field('WFRoundMode', required=False)
    decimal_places = Field('WFRoundTo', required=False)
    uuid = Field('UUID', required=False)


class RandomNumberAction(BaseAction):
    '''Generate a random number'''

    itype = 'is.workflow.actions.number.random'
    keyword = 'random_number'

    minimum = FloatField('WFRandomNumberMinimum', required=False)
    maximum = FloatField('WFRandomNumberMaximum', required=False)
    uuid = Field('UUID', required=False)


class CalculateStatisticsAction(BaseAction):
    '''Calculate statistics (average, min, max, sum, etc.)'''

    itype = 'is.workflow.actions.statistics'
    keyword = 'calculate_statistics'

    operation = Field('WFStatisticsOperation', required=False)
    uuid = Field('UUID', required=False)


class MeasurementAction(BaseAction):
    '''Convert between measurement units'''

    itype = 'is.workflow.actions.measurement.convert'
    keyword = 'convert_measurement'

    unit = Field('WFMeasurementUnit', required=False)
    uuid = Field('UUID', required=False)
