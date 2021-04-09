import os
import logging
import json
import boto3
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# X-Ray
xray_recorder.configure(context_missing='LOG_ERROR')
patch_all()

# Configure logging
logging.basicConfig()
log = logging.getLogger()
log.setLevel(os.environ.get('LOG_LEVEL', 'INFO'))
jsonify = lambda data: json.dumps(data, default=str)

# Sample Handler
def handler(event, context):
  log.info(f"Received event {jsonify(event)}")
  # Do something
  return {'statusCode': 200, 'body': jsonify(event)}