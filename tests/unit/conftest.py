import pytest
import sys


@pytest.fixture(autouse=True)
def xray(mocker):
    """
    Disables AWS X-Ray
    """
    mocker.patch('aws_xray_sdk.core.xray_recorder')
    mocker.patch('aws_xray_sdk.core.patch_all')


@pytest.fixture
def sample_project(mocker):
  """
  Fixture for sample_project app
  """
  mocker.patch('boto3.client')
  if sys.modules.get('app.main'):
    del sys.modules['app.main']
  import main
  yield main