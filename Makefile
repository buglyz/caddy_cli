VERSION ?= dev

.PHONY: build test check clean

build:
	CGO_ENABLED=0 go build -trimpath \
		-ldflags="-X github.com/buglyz/caddy_cli/internal/caddyctl.Version=$(VERSION)" \
		-o bin/caddyctl ./cmd/caddyctl

test:
	go test ./...

check:
	gofmt -w cmd internal
	go test ./...
	go vet ./...
	bash tests/smoke.sh
	bash tests/functional.sh

clean:
	rm -rf bin
