export COMPOSE_PROJECT_NAME=e2e

.PHONY: up down test test-only clean logs build

# Start all services (gno, atomone, tx-indexer, relayer)
up:
	docker compose up -d --build --force-recreate

# Stop everything and remove volumes
down:
	docker compose down -v

# Full e2e: build images, start services, run Go tests, teardown
test:
	docker compose up -d --build --force-recreate
	go test -v -timeout 10m -count=1 ./...; ret=$$?; docker compose down -v; exit $$ret

# Run Go tests against already-running infrastructure
test-only:
	go test -v -timeout 10m -count=1 ./...

# Stop everything, remove volumes and locally-built images
clean:
	docker compose down -v --rmi local

# Follow logs for all services
logs:
	docker compose logs -f

# Build all images without running
build:
	docker compose build
