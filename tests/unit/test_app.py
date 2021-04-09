import json

def test_returns_ok(sample_project):
  event = {'foo': 'bar'}
  response = sample_project.handler(event,{})
  assert response['statusCode'] == 200
  assert response['body'] == json.dumps(event)
