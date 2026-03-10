export COMPOSE_PROJECT_NAME=e2e

DC=docker compose --progress plain

.PHONY: up down test test-only clean logs build

# Start all services (gno, atomone, tx-indexer, relayer)
up:
	$(DC) up -d --build --force-recreate

# Stop everything and remove volumes
down:
	$(DC) down -v

# Full e2e: build images, start services, run Go tests, teardown
test:
	$(DC) up -d --build --force-recreate
	go test -v -timeout 10m -count=1 ./...; ret=$$?; $(DC) down -v; exit $$ret

# Run Go tests against already-running infrastructure
test-only:
	go test -v -timeout 10m -count=1 ./...

# Stop everything, remove volumes and locally-built images
clean:
	$(DC) down -v --rmi local

# Follow logs for all services
logs:
	$(DC) logs -f

# Build all images without running
build:
	$(DC) build
