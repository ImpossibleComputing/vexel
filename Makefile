# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOCLEAN=$(GOCMD) clean
GOTEST=$(GOCMD) test
GOGET=$(GOCMD) get
BINARY_NAME=vexel
METAL_TAGS=-tags metal

# Default target
all: test build

# Build the unified vexel binary (requires Metal on macOS)
build:
	CGO_ENABLED=1 $(GOBUILD) $(METAL_TAGS) -o $(BINARY_NAME) ./inference/cmd/vexel/

# Build all packages (including non-Metal)
build-all:
	$(GOBUILD) -v ./...

# Run all tests
test:
	$(GOTEST) -v ./...

# Run tests with Metal backend
test-metal:
	CGO_ENABLED=1 $(GOTEST) $(METAL_TAGS) -v ./...

# Download the TinyLlama-1.1B golden-test fixture (multi-GB, git-ignored).
# The golden tests in ./test/golden skip themselves until this fixture is present.
golden-model:
	./test/golden/fetch_model.sh

# Run only the golden reference tests (skip cleanly if the fixture is absent)
test-golden:
	$(GOTEST) -v ./test/golden/...

# Clean build artifacts
clean:
	$(GOCLEAN)
	rm -f $(BINARY_NAME)

# Install dependencies
deps:
	$(GOGET) ./...

# Format code
fmt:
	$(GOCMD) fmt ./...

# Run vet
vet:
	$(GOCMD) vet ./...

# Vet with Metal tags
vet-metal:
	CGO_ENABLED=1 $(GOCMD) vet $(METAL_TAGS) ./...

# Run linting (assumes golangci-lint is installed)
lint:
	golangci-lint run

# Generate coverage report
coverage:
	$(GOTEST) -coverprofile=coverage.out ./...
	$(GOCMD) tool cover -html=coverage.out -o coverage.html

.PHONY: all build build-all test test-metal golden-model test-golden clean deps fmt vet vet-metal lint coverage
