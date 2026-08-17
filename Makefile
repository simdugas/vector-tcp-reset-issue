CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -pedantic -O2
CLIENT_TARGET = tcp_client
SERVER_TARGET = tcp_server
CLIENT_SOURCE = tcp_client.c
SERVER_SOURCE = tcp_server.c

# Default target - build both client and server
all: $(CLIENT_TARGET) $(SERVER_TARGET)

# Compile the client
$(CLIENT_TARGET): $(CLIENT_SOURCE)
	$(CC) $(CFLAGS) -o $(CLIENT_TARGET) $(CLIENT_SOURCE)

# Compile the server
$(SERVER_TARGET): $(SERVER_SOURCE)
	$(CC) $(CFLAGS) -o $(SERVER_TARGET) $(SERVER_SOURCE)

# Debug build
debug: CFLAGS += -g -DDEBUG
debug: $(CLIENT_TARGET) $(SERVER_TARGET)

# Clean build artifacts
clean:
	rm -f $(CLIENT_TARGET) $(SERVER_TARGET)

# Install to /usr/local/bin (requires sudo)
install: $(CLIENT_TARGET) $(SERVER_TARGET)
	install -m 755 $(CLIENT_TARGET) /usr/local/bin/
	install -m 755 $(SERVER_TARGET) /usr/local/bin/

# Uninstall from /usr/local/bin (requires sudo)
uninstall:
	rm -f /usr/local/bin/$(CLIENT_TARGET)
	rm -f /usr/local/bin/$(SERVER_TARGET)

# Run client with default settings
run-client: $(CLIENT_TARGET)
	./$(CLIENT_TARGET)

# Run server with default settings
run-server: $(SERVER_TARGET)
	./$(SERVER_TARGET)

# Run client with syslog server settings
run-client-syslog: $(CLIENT_TARGET)
	./$(CLIENT_TARGET) -h 127.0.0.1 -p 514

# Run server with custom timeout
run-server-custom: $(SERVER_TARGET)
	./$(SERVER_TARGET) -h 127.0.0.1 -p 514 -t 120

# Run client with custom settings
run-client-custom: $(CLIENT_TARGET)
	./$(CLIENT_TARGET) -h 127.0.0.1 -p 8080 -i 5 -m "Custom heartbeat message"

# --- Automated harness (see harness/README.md) ---

# Run the automated delivery test against both pinned Vector revisions.
# Set VECTOR_LOCAL_CHECKOUT=/path/to/vector to reuse an existing clone.
test: $(SERVER_TARGET)
	./harness/run_comparison.sh

# Self-checks for the assertion logic; needs no Vector build.
test-assert:
	./harness/test_assert.sh

# Remove per-run artifacts but keep the (expensive) build cache.
clean-runs:
	rm -rf harness/run

# Remove everything the harness generated, including cached Vector builds.
clean-harness: clean-runs
	rm -rf harness/.cache

# Help target
help:
	@echo "Available targets:"
	@echo "  all               - Build both client and server (default)"
	@echo "  debug             - Build with debug symbols"
	@echo "  clean             - Remove build artifacts"
	@echo "  install           - Install to /usr/local/bin (requires sudo)"
	@echo "  uninstall         - Remove from /usr/local/bin (requires sudo)"
	@echo "  run-client        - Run client with default settings"
	@echo "  run-server        - Run server with default settings"
	@echo "  run-client-syslog - Run client targeting syslog server"
	@echo "  run-server-custom - Run server with custom timeout"
	@echo "  run-client-custom - Run client with custom settings example"
	@echo "  test              - Automated delivery test, both pinned revisions"
	@echo "  test-assert       - Self-checks for the assertion logic"
	@echo "  clean-runs        - Remove per-run artifacts, keep build cache"
	@echo "  clean-harness     - Remove all harness artifacts and build cache"
	@echo "  help              - Show this help message"

.PHONY: all debug clean install uninstall run-client run-server run-client-syslog \
        run-server-custom run-client-custom test test-assert clean-runs clean-harness help
