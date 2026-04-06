#if defined(__linux__)
#define _GNU_SOURCE
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <getopt.h>
#include <poll.h>
#include <sys/select.h>

#define BUFFER_SIZE 1024
#define DEFAULT_PORT 514
#define DEFAULT_HOST "127.0.0.1"
#define DEFAULT_TIMEOUT 300  // 5 minutes default timeout
#define MAX_CLIENTS 1000
#define BACKLOG 5

// Client connection structure
typedef struct {
    int sockfd;
    struct sockaddr_in addr;
    time_t last_activity;
    int active;
} client_conn_t;

// Global flag for graceful shutdown
volatile sig_atomic_t running = 1;

void signal_handler(int sig) {
    printf("\nReceived signal %d, shutting down gracefully...\n", sig);
    running = 0;
}

void print_usage(const char *program_name) {
    printf("Usage: %s [-h host] [-p port] [-t timeout]\n", program_name);
    printf("Options:\n");
    printf("  -h host      Bind to host/IP (default: %s)\n", DEFAULT_HOST);
    printf("  -p port      Listen on port (default: %d)\n", DEFAULT_PORT);
    printf("  -t timeout   Connection timeout in seconds (default: %d)\n", DEFAULT_TIMEOUT);
    printf("  --help       Show this help message\n");
}

int create_server_socket(const char *host, int port) {
    int sockfd;
    struct sockaddr_in server_addr;
    int opt = 1;
    
    // Create socket
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("Error creating socket");
        return -1;
    }
    
    // Set SO_REUSEADDR to avoid "Address already in use" error
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("Warning: Failed to set SO_REUSEADDR");
    }
    
    // Set SO_REUSEPORT for better performance with multiple processes (if available)
#ifdef SO_REUSEPORT
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt)) < 0) {
        perror("Warning: Failed to set SO_REUSEPORT");
        // Continue anyway - this is not critical
    }
#endif
    
    // Configure server address
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);
    
    // Convert IP address
    if (inet_pton(AF_INET, host, &server_addr.sin_addr) <= 0) {
        perror("Invalid address or address not supported");
        close(sockfd);
        return -1;
    }
    
    // Bind socket
    if (bind(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("Bind failed");
        close(sockfd);
        return -1;
    }
    
    // Listen for connections
    if (listen(sockfd, BACKLOG) < 0) {
        perror("Listen failed");
        close(sockfd);
        return -1;
    }
    
    printf("Server listening on %s:%d\n", host, port);
    return sockfd;
}

void configure_client_socket(int client_sockfd) {
    int flag = 1;
    
    // Set TCP_NODELAY to disable Nagle's algorithm
    if (setsockopt(client_sockfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag)) < 0) {
        perror("Warning: Failed to set TCP_NODELAY on client socket");
    }
    
    // Set SO_KEEPALIVE to detect dead connections
    if (setsockopt(client_sockfd, SOL_SOCKET, SO_KEEPALIVE, &flag, sizeof(flag)) < 0) {
        perror("Warning: Failed to set SO_KEEPALIVE on client socket");
    }
}

int accept_new_client(int server_sockfd, client_conn_t *clients, int max_clients) {
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    int client_sockfd;
    
    // Find available client slot
    int slot = -1;
    for (int i = 0; i < max_clients; i++) {
        if (!clients[i].active) {
            slot = i;
            break;
        }
    }
    
    if (slot == -1) {
        printf("Maximum clients reached, rejecting new connection\n");
        // Accept and immediately close to send proper rejection
        client_sockfd = accept(server_sockfd, (struct sockaddr *)&client_addr, &client_len);
        if (client_sockfd >= 0) {
            close(client_sockfd);
        }
        return -1;
    }
    
    // Accept the connection
    client_sockfd = accept(server_sockfd, (struct sockaddr *)&client_addr, &client_len);
    if (client_sockfd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            perror("Accept failed");
        }
        return -1;
    }
    
    // Configure client socket
    configure_client_socket(client_sockfd);
    
    // Initialize client structure
    clients[slot].sockfd = client_sockfd;
    clients[slot].addr = client_addr;
    clients[slot].last_activity = time(NULL);
    clients[slot].active = 1;
    
    char client_ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, INET_ADDRSTRLEN);
    printf("New client connected: %s:%d (slot %d)\n", 
           client_ip, ntohs(client_addr.sin_port), slot);
    
    return slot;
}

void close_client_connection(client_conn_t *client, int slot, const char *reason) {
    if (!client->active) return;
    
    char client_ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client->addr.sin_addr, client_ip, INET_ADDRSTRLEN);
    printf("Closing connection to %s:%d (slot %d): %s\n", 
           client_ip, ntohs(client->addr.sin_port), slot, reason);
    
    close(client->sockfd);
    memset(client, 0, sizeof(client_conn_t));
}

int handle_client_data(client_conn_t *client, int slot) {
    char buffer[BUFFER_SIZE];
    ssize_t bytes_received;
    
    bytes_received = recv(client->sockfd, buffer, sizeof(buffer) - 1, MSG_DONTWAIT);
    
    if (bytes_received > 0) {
        // Update last activity time
        client->last_activity = time(NULL);
        
        // Null-terminate the received data
        buffer[bytes_received] = '\0';
        
        char client_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &client->addr.sin_addr, client_ip, INET_ADDRSTRLEN);
        
        printf("Received %zd bytes from %s:%d: %s", 
               bytes_received, client_ip, ntohs(client->addr.sin_port), buffer);
        
        return 0;
    } else if (bytes_received == 0) {
        // Client closed connection gracefully
        close_client_connection(client, slot, "client disconnected");
        return -1;
    } else {
        // Error occurred
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // No data available (non-blocking)
            return 0;
        } else if (errno == ECONNRESET) {
            close_client_connection(client, slot, "connection reset by peer");
            return -1;
        } else {
            char error_msg[256];
            snprintf(error_msg, sizeof(error_msg), "recv error: %s", strerror(errno));
            close_client_connection(client, slot, error_msg);
            return -1;
        }
    }
}

void check_client_timeouts(client_conn_t *clients, int max_clients, int timeout_seconds) {
    time_t current_time = time(NULL);
    
    for (int i = 0; i < max_clients; i++) {
        if (clients[i].active) {
            time_t idle_time = current_time - clients[i].last_activity;
            if (idle_time >= timeout_seconds) {
                char timeout_msg[256];
                snprintf(timeout_msg, sizeof(timeout_msg), 
                         "connection timeout (%ld seconds idle)", idle_time);
                close_client_connection(&clients[i], i, timeout_msg);
            }
        }
    }
}

int main(int argc, char *argv[]) {
    char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;
    int timeout = DEFAULT_TIMEOUT;
    int server_sockfd;
    client_conn_t clients[MAX_CLIENTS];
    struct pollfd poll_fds[MAX_CLIENTS + 1];  // +1 for server socket
    int opt;
    
    // Initialize client array
    memset(clients, 0, sizeof(clients));
    
    // Parse command line arguments
    while ((opt = getopt(argc, argv, "h:p:t:")) != -1) {
        switch (opt) {
            case 'h':
                host = optarg;
                break;
            case 'p':
                port = atoi(optarg);
                if (port <= 0 || port > 65535) {
                    fprintf(stderr, "Invalid port number: %s\n", optarg);
                    exit(EXIT_FAILURE);
                }
                break;
            case 't':
                timeout = atoi(optarg);
                if (timeout <= 0) {
                    fprintf(stderr, "Invalid timeout: %s\n", optarg);
                    exit(EXIT_FAILURE);
                }
                break;
            default:
                print_usage(argv[0]);
                exit(EXIT_FAILURE);
        }
    }
    
    // Check for help argument
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            exit(EXIT_SUCCESS);
        }
    }
    
    // Set up signal handlers for graceful shutdown
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);  // Ignore SIGPIPE, handle broken pipes in code
    
    printf("TCP Server starting...\n");
    printf("Listening on: %s:%d\n", host, port);
    printf("Connection timeout: %d seconds\n", timeout);
    printf("Maximum clients: %d\n", MAX_CLIENTS);
    printf("Press Ctrl+C to stop\n\n");
    
    // Create server socket
    server_sockfd = create_server_socket(host, port);
    if (server_sockfd < 0) {
        exit(EXIT_FAILURE);
    }
    
    // Main server loop
    while (running) {
        // Set up poll file descriptors
        int nfds = 1;  // Start with server socket
        poll_fds[0].fd = server_sockfd;
        poll_fds[0].events = POLLIN;
        poll_fds[0].revents = 0;
        
        // Add active client sockets to poll set
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i].active) {
                poll_fds[nfds].fd = clients[i].sockfd;
                poll_fds[nfds].events = POLLIN;
                poll_fds[nfds].revents = 0;
                nfds++;
            }
        }
        
        // Poll with 1 second timeout for periodic timeout checks
        int poll_result = poll(poll_fds, nfds, 1000);
        
        if (poll_result < 0) {
            if (errno == EINTR) {
                // Interrupted by signal, continue
                continue;
            }
            perror("Poll failed");
            break;
        }
        
        if (poll_result > 0) {
            // Check server socket for new connections
            if (poll_fds[0].revents & POLLIN) {
                accept_new_client(server_sockfd, clients, MAX_CLIENTS);
            }
            
            // Check client sockets for data
            int poll_index = 1;
            for (int i = 0; i < MAX_CLIENTS; i++) {
                if (clients[i].active) {
                    if (poll_index < nfds && poll_fds[poll_index].revents & POLLIN) {
                        handle_client_data(&clients[i], i);
                    }
                    poll_index++;
                }
            }
        }
        
        // Check for client timeouts
        check_client_timeouts(clients, MAX_CLIENTS, timeout);
    }
    
    // Cleanup - close all client connections
    printf("Shutting down server...\n");
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active) {
            close_client_connection(&clients[i], i, "server shutdown");
        }
    }
    
    close(server_sockfd);
    printf("TCP Server stopped.\n");
    
    return EXIT_SUCCESS;
}
