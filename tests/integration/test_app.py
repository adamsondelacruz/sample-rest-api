import json

def test_app(run_lambda, stack_outputs):
  event = {'foo': 'bar'}
  response = run_lambda(stack_outputs['SampleFunctionArn'], event)
  assert response['statusCode'] == 200
  assert response['body'] == json.dumps(event)
