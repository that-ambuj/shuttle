SRC_CRATES=deployer common codegen cargo-shuttle proto provisioner service
SRC=$(shell find $(SRC_CRATES) -name "*.rs" -type f -not -path "**/target/*")

COMMIT_SHA ?= $(shell git rev-parse --short HEAD)

BUILDX_CACHE?=/tmp/cache/buildx
ifeq ($(CI),true)
CACHE_FLAGS=--cache-to type=local,dest=$(BUILDX_CACHE),mode=max --cache-from type=local,src=$(BUILDX_CACHE)
endif

ifeq ($(PUSH),true)
BUILDX_OP=--push
else
BUILDX_OP=--load
endif

ifdef PLATFORMS
PLATFORM_FLAGS=--platform $(PLATFORMS)
endif

BUILDX_FLAGS=$(BUILDX_OP) $(PLATFORM_FLAGS) $(CACHE_FLAGS)

# the rust version used by our containers, and as an override for our deployers
# ensuring all user crates are compiled with the same rustc toolchain
RUSTUP_TOOLCHAIN=1.70.0

TAG?=$(shell git describe --tags --abbrev=0)
BACKEND_TAG?=$(TAG)
DEPLOYER_TAG?=$(TAG)
PROVISIONER_TAG?=$(TAG)
RESOURCE_RECORDER_TAG?=$(TAG)

DOCKER_BUILD?=docker buildx build

ifeq ($(CI),true)
DOCKER_BUILD+= --progress plain
endif

DOCKER_COMPOSE=$(shell which docker-compose)
ifeq ($(DOCKER_COMPOSE),)
DOCKER_COMPOSE=docker compose
endif

DOCKER_SOCK?=/var/run/docker.sock

POSTGRES_PASSWORD?=postgres
MONGO_INITDB_ROOT_USERNAME?=mongodb
MONGO_INITDB_ROOT_PASSWORD?=password

ifeq ($(PROD),true)
DOCKER_COMPOSE_FILES=docker-compose.yml
STACK=shuttle-prod
APPS_FQDN=shuttleapp.rs
DB_FQDN=db.shuttle.rs
CONTAINER_REGISTRY=public.ecr.aws/shuttle
DD_ENV=production
# make sure we only ever go to production with `--tls=enable`
USE_TLS=enable
RUST_LOG=debug
else
DOCKER_COMPOSE_FILES=docker-compose.yml docker-compose.dev.yml
STACK?=shuttle-dev
APPS_FQDN=unstable.shuttleapp.rs
DB_FQDN=db.unstable.shuttle.rs
CONTAINER_REGISTRY=public.ecr.aws/shuttle-dev
DD_ENV=unstable
USE_TLS?=disable
RUST_LOG?=shuttle=trace,debug
DEPLOYS_API_KEY?=gateway4deployes
endif

POSTGRES_EXTRA_PATH?=./extras/postgres
POSTGRES_TAG?=14

PANAMAX_EXTRA_PATH?=./extras/panamax
PANAMAX_TAG?=1.0.12

OTEL_EXTRA_PATH?=./extras/otel
OTEL_TAG?=0.72.0

USE_PANAMAX?=enable
ifeq ($(USE_PANAMAX), enable)
PREPARE_ARGS+=-p
COMPOSE_PROFILES+=panamax
endif

ifeq ($(SHUTTLE_DETACH), disable)
SHUTTLE_DETACH=
else
SHUTTLE_DETACH=--detach
endif

DOCKER_COMPOSE_ENV=\
	STACK=$(STACK)\
	BACKEND_TAG=$(BACKEND_TAG)\
	DEPLOYER_TAG=$(DEPLOYER_TAG)\
	PROVISIONER_TAG=$(PROVISIONER_TAG)\
	RESOURCE_RECORDER_TAG=$(RESOURCE_RECORDER_TAG)\
	POSTGRES_TAG=${POSTGRES_TAG}\
	PANAMAX_TAG=${PANAMAX_TAG}\
	OTEL_TAG=${OTEL_TAG}\
	APPS_FQDN=$(APPS_FQDN)\
	DB_FQDN=$(DB_FQDN)\
	POSTGRES_PASSWORD=$(POSTGRES_PASSWORD)\
	RUST_LOG=$(RUST_LOG)\
	DEPLOYS_API_KEY=$(DEPLOYS_API_KEY)\
	CONTAINER_REGISTRY=$(CONTAINER_REGISTRY)\
	MONGO_INITDB_ROOT_USERNAME=$(MONGO_INITDB_ROOT_USERNAME)\
	MONGO_INITDB_ROOT_PASSWORD=$(MONGO_INITDB_ROOT_PASSWORD)\
	DD_ENV=$(DD_ENV)\
	USE_TLS=$(USE_TLS)\
	COMPOSE_PROFILES=$(COMPOSE_PROFILES)\
	DOCKER_SOCK=$(DOCKER_SOCK)

.PHONY: images clean src up down deploy shuttle-% postgres docker-compose.rendered.yml test bump-% deploy-examples publish publish-% --validate-version

clean:
	rm .shuttle-*
	rm docker-compose.rendered.yml

images: shuttle-provisioner shuttle-deployer shuttle-gateway shuttle-auth shuttle-resource-recorder postgres panamax otel

postgres:
	$(DOCKER_BUILD) \
		--build-arg POSTGRES_TAG=$(POSTGRES_TAG) \
		--tag $(CONTAINER_REGISTRY)/postgres:$(POSTGRES_TAG) \
		$(BUILDX_FLAGS) \
		-f $(POSTGRES_EXTRA_PATH)/Containerfile \
		$(POSTGRES_EXTRA_PATH)

panamax:
	if [ $(USE_PANAMAX) = "enable" ]; then \
		$(DOCKER_BUILD) \
			--build-arg PANAMAX_TAG=$(PANAMAX_TAG) \
			--tag $(CONTAINER_REGISTRY)/panamax:$(PANAMAX_TAG) \
			$(BUILDX_FLAGS) \
			-f $(PANAMAX_EXTRA_PATH)/Containerfile \
			$(PANAMAX_EXTRA_PATH); \
	fi

otel:
	$(DOCKER_BUILD) \
		--build-arg OTEL_TAG=$(OTEL_TAG) \
		--tag $(CONTAINER_REGISTRY)/otel:$(OTEL_TAG) \
		$(BUILDX_FLAGS) \
		-f $(OTEL_EXTRA_PATH)/Containerfile \
		$(OTEL_EXTRA_PATH)

deploy: docker-compose.yml
	$(DOCKER_COMPOSE_ENV) docker stack deploy -c $< $(STACK)

test:
	cd e2e; POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) APPS_FQDN=$(APPS_FQDN) cargo test $(CARGO_TEST_FLAGS) -- --nocapture

docker-compose.rendered.yml: docker-compose.yml docker-compose.dev.yml
	$(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml $(DOCKER_COMPOSE_CONFIG_FLAGS) -p $(STACK) config > $@

# Start the containers locally. This does not start panamax by default,
# to start panamax locally run this command with an override for the profiles:
# `make COMPOSE_PROFILES=panamax up`
up: $(DOCKER_COMPOSE_FILES)
	$(DOCKER_COMPOSE_ENV) \
	$(DOCKER_COMPOSE) \
	$(addprefix -f ,$(DOCKER_COMPOSE_FILES)) \
	-p $(STACK) \
	up \
	$(SHUTTLE_DETACH)

down: $(DOCKER_COMPOSE_FILES)
	$(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE) $(addprefix -f ,$(DOCKER_COMPOSE_FILES)) -p $(STACK) down

shuttle-%: ${SRC} Cargo.lock
	$(DOCKER_BUILD) \
		--build-arg folder=$(*) \
		--build-arg prepare_args=$(PREPARE_ARGS) \
		--build-arg PROD=$(PROD) \
		--build-arg RUSTUP_TOOLCHAIN=$(RUSTUP_TOOLCHAIN) \
		--tag $(CONTAINER_REGISTRY)/$(*):$(COMMIT_SHA) \
		--tag $(CONTAINER_REGISTRY)/$(*):$(TAG) \
		--tag $(CONTAINER_REGISTRY)/$(*):latest \
		$(BUILDX_FLAGS) \
		-f Containerfile \
		.

# Bunch of targets to make bumping the shuttle version easier
#
# Dependencies: git, cargo-edit, fastmod, ripgrep
# Usage: make bump-version current=0.6.3 version=0.7.0
bump-version: --validate-version
	git checkout development
	git fetch --all
	git pull upstream
	git checkout -b "chore/v$(version)"
	cargo set-version --workspace "$(version)"

	$(call next, bump-resources)

bump-resources:
	git commit -m "chore: v$(version)"
	fastmod --fixed-strings $(current) $(version) resources

	$(call next, bump-examples)

bump-examples:
	git commit -m "chore: resources v$(version)"
	fastmod --fixed-strings $(current) $(version) examples

	$(call next, bump-misc)

bump-misc:
	git commit -m "docs: v$(version)"
	fastmod --fixed-strings $(current) $(version)

	$(call next, bump-final)

bump-final:
	git commit -m "misc: v$(version)"
	git push --set-upstream origin $$(git rev-parse --abbrev-ref HEAD)

	echo "Make pull request and confirm everything is okay. Then run:"
	echo "make publish"

# Deploy all our example using the command set in shuttle-command
# Usage: make deploy-examples shuttle-command="cargo shuttle" -j 2
deploy-examples: deploy-examples/rocket/hello-world \
	deploy-examples/rocket/persist \
	deploy-examples/rocket/postgres \
	deploy-examples/rocket/secrets \
	deploy-examples/rocket/authentication \
	deploy-examples/axum/hello-world \
	deploy-examples/axum/websocket \
	deploy-examples/poem/hello-world \
	deploy-examples/poem/mongodb \
	deploy-examples/poem/postgres \
	deploy-examples/salvo/hello-world \
	deploy-examples/tide/hello-world \
	deploy-examples/tide/postgres \
	deploy-examples/tower/hello-world \
	deploy-examples/warp/hello-world \

	echo "All example have been redeployed"

deploy-examples/%:
	cd examples/$(*); $(shuttle-command) project stop || echo -e "\x1B[33m>> Nothing to remove for $*\x1B[39m"
	sleep 5
	cd examples/$(*); $(shuttle-command) project start
	sleep 5
	cd examples/$(*); $(shuttle-command) deploy

define next
	cargo check # To update Cargo.lock
	git add --all
	git --no-pager diff --staged

	echo -e "\x1B[36m>> Is this correct?\x1B[39m"
	read yn; if [ $$yn != "y" ]; then echo "Fix the issues then continue with:"; echo "make version=$(version) current=$(current) $1"; exit 2; fi

	make $1
endef

# Publish all our crates to crates.io
# See CONTRIBUTING.md for the dependency graph
# Usage: make publish -j 4
publish: publish-resources publish-cargo-shuttle
	echo "The branch can now be safely merged"

publish-resources: publish-resources/aws-rds \
	publish-resources/persist \
	publish-resources/shared-db
	publish-resources/static-folder

publish-cargo-shuttle: publish-resources/secrets
	cd cargo-shuttle; cargo publish
	sleep 10 # Wait for crates.io to update

publish-service: publish-codegen publish-common
	cd service; cargo publish
	sleep 10 # Wait for crates.io to update

publish-codegen:
	cd codegen; cargo publish
	sleep 10 # Wait for crates.io to update

publish-common:
	cd common; cargo publish
	sleep 10 # Wait for crates.io to update

publish-resources/%: publish-service
	cd resources/$(*); cargo publish
	sleep 10 # Wait for crates.io to update

--validate-version:
	echo "$(version)" | rg -q "\d+\.\d+\.\d+" || { echo "version argument must be in the form x.y.z"; exit 1; }
	echo "$(current)" | rg -q "\d+\.\d+\.\d+" || { echo "current argument must be in the form x.y.z"; exit 1; }
