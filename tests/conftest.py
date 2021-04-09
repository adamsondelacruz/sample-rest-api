import os
import json

import pytest

@pytest.fixture(scope='session')
def stack_outputs():
    yield json.loads(os.environ.get('STACK_OUTPUTS', '{}'))


@pytest.fixture(scope='session')
def run_lambda():
    import boto3
    client = boto3.client('lambda')

    def run(function_arn, event):
        """
        :param name: lambda function ARN
        :param event: lambda function input
        :returns: lambda function return value
        """
        response = client.invoke(
            FunctionName=function_arn,
            InvocationType='RequestResponse',
            Payload=bytes(json.dumps(event).encode())
        )
        return json.loads(response['Payload'].read())

    return run
