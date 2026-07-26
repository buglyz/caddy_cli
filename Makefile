VERSION ?= dev

.PHONY: build test race vet fmt-check check clean

build:
	CGO_ENABLED=0 go build -trimpath \
		-ldflags="-X github.com/buglyz/caddy_cli/internal/caddyctl.Version=$(VERSION)" \
		-o bin/caddyctl ./cmd/caddyctl

test:
	go test ./...

race:
	go test -race ./...

vet:
	go vet ./...

fmt-check:
	test -z "$$(gofmt -l cmd internal)"

check: fmt-check test race vet

clean:
	rm -rf bin
