# Project settings
-include .env
PROJECT_NAME = sample-project
PYTHON_VERSION = 3.8.3

# Standard settings
COMMIT_ID ?= $(shell git rev-parse HEAD)
BRANCH_NAME = $(shell git rev-parse --abbrev-ref HEAD)
BRANCH_ID ?= $(shell echo $(BRANCH_NAME) | md5 | cut -c 1-7 -)
STACK_OUTPUTS ?= $$(aws cloudformation describe-stacks --region $${region:-ap-southeast-2} --stack-name $(PROJECT_NAME)-$(BRANCH_ID) --query "Stacks[].Outputs[]" | jq "map( { (.OutputKey): .OutputValue } ) | add")
MAP_TO_KV ?= jq -r 'select(.?)|to_entries[]|(.key|tostring)+"="+(.value//""|tostring)'
SAM_ACCOUNTS ?= 747490648416,327053179056,955827651468,985706409166,800206584181
PIPENV_VERBOSITY=-1 
PIPENV_DONT_LOAD_ENV=1
PIPENV_PYUP_API_KEY ?=
INTEGRATION_PYTEST_ADDOPTS ?= -p no:pytest-responses
ACCEPTANCE_PYTEST_ADDOPTS ?= -p no:pytest-responses
STACK_DESTROYER_SF_ARN = arn:aws:states:ap-southeast-2:327053179056:stateMachine:cloud-platform-stack-destroyer
PYTHONPATH=${PWD}/app
export

all: export AWS_PROFILE = iotninja-sandbox
all: build package deploy integration acceptance

version:
	echo $(COMMIT_ID)

login: export AWS_PROFILE ?= iotninja-sandbox
login:
	${INFO} "Checking SSO status..."
	if ! aws sts get-caller-identity &>/dev/null
	then
		aws sso login
	fi

info: export AWS_PROFILE = iotninja-sandbox
info:
	$(INFO) "Stack Name: $(PROJECT_NAME)-$(BRANCH_ID)"
	$(INFO) "Branch Name: $(BRANCH_NAME)"	
	$(INFO) "Branch ID: $(BRANCH_ID)"
	config_json=$$(yq r config/$*.yaml -d* -j)
	$(call array,configs,echo "$$config_json" | jq -s -c '.[]')
	for i in "$${!configs[@]}"; do
		region=$$(yq r - Region <<< $${configs[$$i]}); region=$${region:-ap-southeast-2}
		$(INFO) "Stack Outputs for $$region:"
		echo "$(STACK_OUTPUTS)" | jq '. // {}'
	done

update: clean
	$(activate)
	$(INFO) "Updating dependencies..."
	pipenv lock --dev --verbose
	pipenv sync --dev
	pipenv clean

install:
	$(activate)
	$(INFO) "Installing dev virtual environment ($$VIRTUAL_ENV)..."
	pipenv sync --dev
	pipenv clean
	timestamp

test:
	#$(activate)
	$(INFO) "Running tests in dev virtual environment ($$VIRTUAL_ENV)..."
	#make test/unit
	#pipenv check

test/%:
	$(activate)
	pytest --cov=app --cov-report term-missing --cov-report xml:build/coverage.xml --cov-report= tests/$* -vv

build: clean install test
	export VIRTUAL_ENV=venv
	$(activate)
	$(INFO) "Creating production build virtual environment ($$VIRTUAL_ENV)..."
	pipenv sync
	pipenv clean
	packages=( $$(python -c "import sys; print('\n'.join([p for p in sys.path if p.endswith('site-packages')]))") )
	mkdir -p build/dependencies/python
	for package in "$${packages[@]}"; do
		$(INFO) "Copying production build dependencies from $$package..."
		cp -r $$package/* build/dependencies/python
	done
	$(INFO) "Build complete"

package: ENVIRONMENT ?= sandbox
package:
	$(activate)
	find . -type f -name '*.py[co]' -delete -o -type d -name __pycache__ -delete
	timestamp -s Pipfile.lock -p build/dependencies/python
	$(INFO) "Packaging template(s)..."
	for f in config/*; do
		f=$$(basename $$f .yaml)
		if [ -f config/$$f.yaml ]; then make package/$$f ENVIRONMENT=$(ENVIRONMENT); fi		
	done

package/%:
	config_json=$$(yq r config/$*.yaml -d* -j)
	$(call array,configs,echo "$$config_json" | jq -s -c '.[]')
	for config in "$${configs[@]}"; do
		region=$$(yq r - Region -D ap-southeast-2 <<< $$config)
		file=$$(yq r - Template -D template.yaml <<< $$config)
		f=$$(basename $$file)
		sambuild=$$(yq r - SamBuild <<< $$config)
		if [ "$$sambuild" = "true" ]; then
			$(INFO) "Using sam build for $$file in $$region..."
			rm -rf .aws-sam
			pipenv run sam build -t $$file
			rm -rf .aws-sam/build/*/boto*
			file=.aws-sam/build/template.yaml
		fi
		children=($$(yq r $$file 'Resources.*.Metadata.Template' <<< $$config))
		mkdir -p build/templates/$$region
		bucket=iotninja-$(ENVIRONMENT)-$$region-code-artifacts
		for child in "$${children[@]}"; do
			if ! [ -f build/$$child ]; then
				$(INFO) "Packaging child template $$child for $$region region using $$bucket..."
				aws cloudformation package --s3-bucket $$bucket --s3-prefix $(PROJECT_NAME) --template-file $$child --output-template-file build/$$child --region $$region
				cfn-lint -t build/$$child
			fi
		done
		if ! [ -f build/templates/$$region/$$f ]; then
			$(INFO) "Packaging $$file for $$region region using $$bucket..." 
			aws cloudformation package --s3-bucket $$bucket --s3-prefix $(PROJECT_NAME) --template-file $$file --output-template-file build/templates/$$region/$$f --region $$region
			cfn-lint -t build/templates/$$region/$$f
		fi
	done

generate:
	for f in config/*; do
		f=$$(basename $$f .yaml)
		if [ -f config/$$f.yaml ]; then make generate/$$f; fi
	done

generate/%:
	$(INFO) "Generating template and config for $*..."
	config_json=$$(yq r config/$*.yaml -d* -j)
	$(call array,configs,echo "$$config_json" | jq -s -c '.[]')
	for i in "$${!configs[@]}"; do
		region=$$(yq r - Region -D ap-southeast-2 <<< $${configs[i]})
		file=$$(yq r - Template -D template.yaml <<< $${configs[i]})
		f=$$(basename $$file)
		mkdir -p build/config/$*/$$region
		yq m -a -x build/templates/$$region/$$f <(yq r -d$$i config/$*.yaml Overrides) > build/config/$*/$$region/template.yaml
		yq r -d$$i -j config/$*.yaml | jq '{Parameters,StackPolicy,Tags} | (..|select(type=="number")) |= tostring | del(.[] | nulls)' > build/config/$*/$$region/config.json
	done

deploy:
	if [ $$(git rev-parse --abbrev-ref HEAD) == master ]; then 
		$(ERROR) "Cannot deploy from master - please create a new branch and then deploy"
	fi
	$(call array,configs,yq r config.yaml -d* -j | jq -s -c '.[]')
	stack_outputs=()
	for i in "$${!configs[@]}"; do
		set -f; parsed=$$(eval "echo \"$$(yq r -d$$i config.yaml)\""); set +f
		$(call array,overrides,yq r -j - Parameters <<< "$$parsed" | $(MAP_TO_KV))
		$(call array,tags,yq r -j - Tags <<< "$$parsed" | $(MAP_TO_KV))
		region=$$(yq r - Region -D ap-southeast-2 <<< $${configs[$$i]})
		file=$$(yq r - Template -D template.yaml <<< $${configs[$$i]}); f=$$(basename $$file)
		$(INFO) "Deploying stack $(PROJECT_NAME)-$(BRANCH_ID) to $$region"
		echo "=> Stack overrides: [$${overrides[@]}]"
		aws cloudformation deploy --template-file build/templates/$$region/$$f --stack-name $(PROJECT_NAME)-$(BRANCH_ID) \
			--s3-bucket iotninja-sandbox-$$region-code-artifacts --s3-prefix $(PROJECT_NAME) \
			--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset \
			$${overrides:+--parameter-overrides "$${overrides[@]}"} --region $$region \
			$${tags:+--tags "$${tags[@]}"}
		$(INFO) "Stack Outputs for $$region:"
		echo "$(STACK_OUTPUTS)" | jq '. // {}'
		stack_outputs+=($$(echo $(STACK_OUTPUTS) | jq -c '. // {}'))
	done
	
deploy/%: export AWS_PROFILE = iotninja-build
deploy/%: build
	make package/$* ENVIRONMENT=build
	make generate/$*
	config_json=$$(yq r config/$*.yaml -d* -j)
	$(call array,configs,echo "$$config_json" | jq -s -c '.[]')
	for config in "$${configs[@]}"; do
		region=$$(yq r - Region <<< $$config); region=$${region:-ap-southeast-2}
		$(call array,tags,yq r -j build/config/$*/$$region/config.json Tags | $(MAP_TO_KV))
		$(call array,overrides,yq r -j build/config/$*/$$region/config.json Parameters | $(MAP_TO_KV))
		$(INFO) "Deploying application to $* environment in $$region..."
		aws cloudformation deploy \
			--profile iotninja-$* --template-file build/config/$*/$$region/template.yaml --stack-name $(PROJECT_NAME) \
			--s3-bucket iotninja-$*-$$region-code-artifacts --s3-prefix $(PROJECT_NAME) \
			--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset \
			$${overrides:+--parameter-overrides "$${overrides[@]}"} --region $$region \
			$${tags:+--tags "$${tags[@]}"}
	done

integration: export PYTEST_ADDOPTS=$(INTEGRATION_PYTEST_ADDOPTS)
integration:
	$(activate)
	$(INFO) "Running integration tests in dev virtual environment ($$VIRTUAL_ENV)..."
	export STACK_OUTPUTS=$(STACK_OUTPUTS)
	pytest tests/integration -vv

acceptance: export PYTEST_ADDOPTS=$(ACCEPTANCE_PYTEST_ADDOPTS)
acceptance:
	$(activate)
	$(INFO) "Running acceptance tests in dev virtual environment ($$VIRTUAL_ENV)..."
	export STACK_OUTPUTS=$(STACK_OUTPUTS)
	pytest tests/acceptance -vv

destroy:
	$(INFO) "Deleting stack $(PROJECT_NAME)-$(BRANCH_ID)"
	rand=$$RANDOM
	aws stepfunctions start-execution --state-machine-arn ${STACK_DESTROYER_SF_ARN} --name $(PROJECT_NAME)-$(BRANCH_ID)-$$rand --input "{\"stack_name\": \"$(PROJECT_NAME)-$(BRANCH_ID)\",\"region\": \"ap-southeast-2\",\"no_check\": \"true\"}"

tag:
	$(activate) 2>/dev/null
	current_versions=$$(git tag | grep ^[[:digit:]]*.[[:digit:]]*.[[:digit:]]*$$ || printf '0.0.0')
	current_sorted_versions=( $$(printf "$$current_versions" | sort -V) )
	current_version=$${current_sorted_versions[@]:(-1)}
	target_version=$$(yq r template.yaml Metadata.AWS::ServerlessRepo::Application.SemanticVersion)
	target_version=$${target_version:-0.0.0}
	eval $$(bumpversion --current-version $$current_version --dry-run --allow-dirty --list patch)
	versions=( $$(printf "$$target_version\n$$new_version" | sort -V) )
	echo $${versions[@]:(-1)}

clean:
	$(INFO) "Cleaning environment..."
	rm -rf .aws-sam .pytest_cache build .venv
	find . -type f -name '*.py[co]' -delete -o -type d -name __pycache__ -delete

pipeline:
	aws cloudformation deploy --profile iotninja-build --template-file pipeline.yaml --stack-name $(PROJECT_NAME)-pipeline \
	  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset

metadata/%:
	tag=$$(make tag)
	for d in build/templates/*; do
		if [ -d $$d ]; then
			for f in $$d/*; do
			if [ -f $$f ]; then
				yq w -i $$f Metadata.AWS::ServerlessRepo::Application.SemanticVersion $$tag
				if [ $$CODEBUILD_BUILD_ID ]; then
					IFS=':' read -ra build_id <<< "$$CODEBUILD_BUILD_ID"
					yq w -i $$f $*.BuildId "$$CODEBUILD_BUILD_ID"
					yq w -i $$f $*.BuildUrl "https://$${AWS_REGION}.console.aws.amazon.com/codesuite/codebuild/projects/$${build_id[0]}/build/$${CODEBUILD_BUILD_ID}"
					yq w -i $$f $*.CommitId "$$CODEBUILD_RESOLVED_SOURCE_VERSION"
					yq w -i $$f $*.SourceVersion "$$CODEBUILD_SOURCE_VERSION"
				fi
			fi
			done
		fi
	done

kernel: clean install
	$(activate)
	$(INFO) "Creating iPython kernel $(PROJECT_NAME)"
	ipython kernel install --user --name=$(PROJECT_NAME)
	$(INFO) "Kernel named $(PROJECT_NAME) now available in Jupyter"

jupyter:
	$(activate)
	jupyter lab

schema: AWS_PROFILE=iotninja-sandbox
schema:
	tmp=$$(mktemp -d)
	registry=integration-platform-schema-registry
	schemas=($$(aws schemas list-schemas --registry-name $$registry --query "Schemas[].{x:join(':',[SchemaName,to_string(VersionCount)])}" --output text))
	for schema in $${schemas[@]}
	do
		name=$${schema//[^a-zA-Z]}
		version=$${schema//[^0-9]}
		if [ ! "$$(aws schemas describe-code-binding --language Python36 --registry-name $$registry --schema-name $$name --schema-version $$version 2>/dev/null)" ]
		then
			$(INFO) "Publishing code binding for schema $$name:$$version"
			aws schemas put-code-binding --language Python36 --registry-name $$registry --schema-name $$name --schema-version $$version
		fi
		$(INFO) "Fetching code binding for schema $$name:$$version"
		aws schemas get-code-binding-source --language Python36 --registry-name $$registry --schema-name $$name --schema-version $$version $$tmp/$$name-$$version.zip
		unzip -o $$tmp/$$name-$$version.zip -x / -d app
	done
	rm -rf $$tmp

# Array function
define array
	$(1)=(); while read -r var; do $(1)+=("$$var"); done < <($(2))
endef

# Activate function
define activate
	if [ $$VIRTUAL_ENV ]
	then
		if ! [ -f $$VIRTUAL_ENV/bin/activate ]
		then
			PIPENV_IGNORE_VIRTUALENVS=1 pipenv run -- virtualenv $$VIRTUAL_ENV --python python$(PYTHON_VERSION)
		fi
		source $$VIRTUAL_ENV/bin/activate
	else
		if ! pipenv --venv >/dev/null; then pipenv --python $(PYTHON_VERSION); fi
		source $$(pipenv --venv)/bin/activate
	fi
endef

# Make settings
.PHONY: all version info update install test build package deploy integration destroy tag clean generate pipeline metadata kernel jupyter login schema
.ONESHELL:
.SILENT:
SHELL=/bin/bash
.SHELLFLAGS = -ceo pipefail
YELLOW := "\e[1;33m"
RED := "\e[1;31m"
NC := "\e[0m"
INFO := @bash -c 'printf $(YELLOW); echo "=> $$0"; printf $(NC)'
ERROR := @bash -c 'printf $(RED); echo "ERROR: $$0"; printf $(NC); exit 1'
MAKEFLAGS += --no-print-directory
