# Sample API Project

This repository is a simple REST API project that demonstrates the use of an API Gateway endpoint using swagger and proxies the request to a Lambda function that handles backend data services.

## Requirements
The following are required to build and test this application:

* [pyenv (Python Version Manager)](https://github.com/pyenv/pyenv)
* Python 3.8 or higher (pyenv install 3.8.3)
* [pipenv (Python Package Manager)](https://github.com/pypa/pipenv)
* gnumake (https://www.gnu.org/software/make/)
---

## HOW TO RUN
### 1. Setup environment
```
pyenv global 3.8.3
pipenv install
pipenv shell
```

### 2. Deploy to AWS Cloud
```
export AWS_PROFILE=my-profile-name
make
```

### 3. Run Unit Tests
```
make test
```
