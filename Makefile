# GiftList devenv — orchestration for the local Docker Compose stack.
#
# Lives next to docker-compose.yml rather than at the repo root: this whole
# directory (devenv/) becomes the root of its own repo, giftlist-devenv, at the
# Phase 2.5 split (docs/ARCHITECTURE.md "Packaging: local feed"/"Making the local feed visible to containers", docs/SETUP.md "Bootstrap the workspace"). Keeping the
# Makefile here means nothing needs to move or be rewritten when that happens —
# `git mv devenv giftlist-devenv` (roughly) is the whole migration.
#
# Location-independent by design, so it works whichever way it's invoked:
#   cd devenv && make up
#   make -C devenv up
#   make -f devenv/Makefile up      (from the repo root)

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# Directory this Makefile lives in, resolved from MAKEFILE_LIST rather than $(CURDIR)
# so recipes are correct no matter what the caller's working directory was.
THIS_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
ROOT_DIR := $(dir $(THIS_MAKEFILE))

COMPOSE := docker compose -f "$(ROOT_DIR)docker-compose.yml" --project-directory "$(ROOT_DIR)"

.PHONY: help up down reset restart build logs ps reset-testcontainers pack-all clone-all

help:
	@echo "GiftList devenv"
	@echo ""
	@echo "  make clone-all            clone the other six repos as siblings, plus an empty"
	@echo "                            local-feed/ — see scripts/clone-all.sh"
	@echo "  make pack-all             pack the BuildingBlocks family, the *.Contracts packages"
	@echo "                            and the Gateway's npm client into local-feed/, in"
	@echo "                            dependency order — safe to run again (skips anything"
	@echo "                            unchanged), fails hard if a version's content changed"
	@echo "                            without a version bump (see scripts/pack-all.sh)"
	@echo "  make up                   build (if needed) and start the whole stack, detached"
	@echo "  make down                 stop and remove containers; named volumes are kept"
	@echo "  make reset                down, then drop the named volumes (rabbitmq-data,"
	@echo "                            mongodb-data, web-node-modules, *-buildoutput) for a"
	@echo "                            genuinely clean start"
	@echo "  make restart              down, then up"
	@echo "  make build                (re)build images without starting containers"
	@echo "  make logs                 follow logs for every service"
	@echo "  make ps                   show container status"
	@echo "  make reset-testcontainers reap every Testcontainers-managed container left behind"
	@echo "                            by 'dotnet test' — see README.md \"Integration tests and"
	@echo "                            container reuse\""
	@echo ""
	@echo "First time: make clone-all, then make pack-all, then cp .env.example .env (optional"
	@echo "            — see .env.example for why), then make up"

clone-all:
	"$(ROOT_DIR)scripts/clone-all.sh"

# Dependency-ordered; safe to run repeatedly (unchanged packages are skipped) but still refuses
# to overwrite a version already in local-feed with DIFFERENT content. See scripts/pack-all.sh's
# header for why that guard has no bypass, and README.md "The sibling-clone layout" for the
# layout it assumes.
pack-all:
	"$(ROOT_DIR)scripts/pack-all.sh"

up:
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

# `--volumes` drops the named volumes declared in docker-compose.yml's top-level
# `volumes:` block (rabbitmq-data, mongodb-data, web-node-modules, and the four
# *-buildoutput volumes — GL-59) — not just the containers. Without this, a stale
# Rabbit queue, a stale Mongo database or a node_modules built against an old
# lockfile can survive a `down`/`up` and produce a "clean start" that isn't.
reset:
	$(COMPOSE) down --volumes --remove-orphans

restart:
	$(MAKE) -f $(THIS_MAKEFILE) down
	$(MAKE) -f $(THIS_MAKEFILE) up

build:
	$(COMPOSE) build

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

# GL-93: `dotnet test`'s local default, `.WithReuse(true)`, disables Testcontainers' own Ryuk
# reaper — reuse and automatic cleanup are mutually exclusive, by design of the reuse feature
# itself, not a bug in it. Nothing else in this repo ever removes these containers, so left alone
# they accumulate indefinitely (found: containers still `Up` days after the run that started
# them, one pair resurrected from `Exited` with no `make` target in between). This is independent
# of the docker-compose stack above — filters on the label Testcontainers itself applies, not on
# any compose project, so it is safe to run whether or not `make up` has ever been used.
reset-testcontainers:
	@ids="$$(docker ps -aq --filter 'label=org.testcontainers=true')"; \
	if [ -z "$$ids" ]; then \
		echo "No Testcontainers-managed containers found."; \
	else \
		echo "Removing:"; \
		docker ps -a --filter 'label=org.testcontainers=true' \
			--format '  {{.Names}}  {{.Image}}  {{.Status}}  {{.Label "giftlist.suite"}}'; \
		docker rm -f $$ids; \
	fi
