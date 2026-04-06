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

#define BUFFER_SIZE 1024
#define DEFAULT_PORT 514
#define DEFAULT_HOST "127.0.0.1"
#define SEND_INTERVAL 10

// Global flag for graceful shutdown
volatile sig_atomic_t running = 1;

void signal_handler(int sig) {
    if (sig == SIGPIPE) {
        // Handle broken pipe silently - we'll detect it in send() return value
        printf("\nBroken pipe detected, attempting reconnection...\n");
        return;
    }
    printf("\nReceived signal %d, shutting down gracefully...\n", sig);
    running = 0;
}

void print_usage(const char *program_name) {
    printf("Usage: %s [-h host] [-p port] [-i interval] [-m message]\n", program_name);
    printf("Options:\n");
    printf("  -h host      Target host (default: %s)\n", DEFAULT_HOST);
    printf("  -p port      Target port (default: %d)\n", DEFAULT_PORT);
    printf("  -i interval  Send interval in seconds (default: %d)\n", SEND_INTERVAL);
    printf("  -m message   Custom message to send (default: auto-generated)\n");
    printf("  --help       Show this help message\n");
}

int create_socket_connection(const char *host, int port) {
    int sockfd;
    struct sockaddr_in server_addr;
    
    // Create socket
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("Error creating socket");
        return -1;
    }
    
    // Set TCP_NODELAY to disable Nagle's algorithm for immediate transmission
    int flag = 1;
    if (setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag)) < 0) {
        perror("Warning: Failed to set TCP_NODELAY");
        // Continue anyway - this is not critical
    }
    
    // Set SO_KEEPALIVE to detect dead connections
    flag = 1;
    if (setsockopt(sockfd, SOL_SOCKET, SO_KEEPALIVE, &flag, sizeof(flag)) < 0) {
        perror("Warning: Failed to set SO_KEEPALIVE");
    }
    
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
    
    // Connect to server
    if (connect(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("Connection failed");
        close(sockfd);
        return -1;
    }
    
    printf("Connected to %s:%d (TCP_NODELAY enabled)\n", host, port);
    return sockfd;
}

void generate_message(char *buffer, size_t buffer_size, const char *custom_message) {
    time_t now;
    struct tm *timeinfo;
    
    time(&now);
    timeinfo = localtime(&now);
    
    if (custom_message) {
        snprintf(buffer, buffer_size, "[%04d-%02d-%02d %02d:%02d:%02d] %s\n",
                timeinfo->tm_year + 1900, timeinfo->tm_mon + 1, timeinfo->tm_mday,
                timeinfo->tm_hour, timeinfo->tm_min, timeinfo->tm_sec,
                custom_message);
    } else {
        snprintf(buffer, buffer_size, 
                "<134>%04d-%02d-%02dT%02d:%02d:%02d tcp_client[%d]: Heartbeat message #%ld\n",
                timeinfo->tm_year + 1900, timeinfo->tm_mon + 1, timeinfo->tm_mday,
                timeinfo->tm_hour, timeinfo->tm_min, timeinfo->tm_sec,
                getpid(), time(NULL));
    }
}

int check_for_fin(int sockfd) {
    struct pollfd pfd;
    char dummy;
    
    pfd.fd = sockfd;
    pfd.events = POLLIN | POLLHUP;  // Use POLLHUP instead of POLLRDHUP for portability
    pfd.revents = 0;
    
    // Non-blocking check for readable data (potential FIN)
    int poll_result = poll(&pfd, 1, 0);
    
    if (poll_result > 0) {
        // Check for hangup condition first
        if (pfd.revents & POLLHUP) {
            printf("Detected peer hangup (POLLHUP)\n");
            return 1; // Connection closed
        }
        
        if (pfd.revents & POLLIN) {
            // Data available - peek to check for EOF (FIN)
            ssize_t peek_result = recv(sockfd, &dummy, 1, MSG_PEEK | MSG_DONTWAIT);
            if (peek_result == 0) {
                printf("Detected FIN from peer (EOF on recv peek)\n");
                return 1; // FIN detected
            } else if (peek_result < 0) {
                // Check for connection errors
                if (errno == ECONNRESET) {
                    printf("Connection reset detected during FIN check\n");
                    return 1;
                } else if (errno == ENOTCONN) {
                    printf("Socket not connected during FIN check\n");
                    return 1;
                }
                // EAGAIN/EWOULDBLOCK are normal for non-blocking operations
            }
        }
        
        // Check for error conditions
        if (pfd.revents & POLLERR) {
            printf("Socket error detected (POLLERR)\n");
            return 1;
        }
        
        if (pfd.revents & POLLNVAL) {
            printf("Invalid socket detected (POLLNVAL)\n");
            return 1;
        }
    } else if (poll_result < 0) {
        printf("Poll error during FIN check: %s\n", strerror(errno));
        return 1; // Treat poll errors as connection issues
    }
    
    return 0; // No FIN detected
}

int send_data(int sockfd, const char *data) {
    // CRITICAL: Check for FIN before attempting send
    if (check_for_fin(sockfd)) {
        printf("Cannot send: peer has closed connection\n");
        return -1;
    }
    
    ssize_t bytes_sent = send(sockfd, data, strlen(data), MSG_NOSIGNAL);
    if (bytes_sent < 0) {
        // Handle all connection-related errors through send() return value
        if (errno == EPIPE) {
            printf("Connection lost: Broken pipe (peer closed connection)\n");
        } else if (errno == ECONNRESET) {
            printf("Connection lost: Connection reset by peer\n");
        } else if (errno == ENOTCONN) {
            printf("Connection lost: Socket not connected\n");
        } else if (errno == ECONNABORTED) {
            printf("Connection lost: Connection aborted\n");
        } else if (errno == ETIMEDOUT) {
            printf("Connection lost: Connection timed out\n");
        } else if (errno == EHOSTUNREACH) {
            printf("Connection lost: Host unreachable\n");
        } else if (errno == ENETUNREACH) {
            printf("Connection lost: Network unreachable\n");
        } else {
            printf("Send failed (errno=%d): %s\n", errno, strerror(errno));
        }
        return -1;
    }
    
    printf("Sent %zd bytes: %s", bytes_sent, data);
    return 0;
}

int main(int argc, char *argv[]) {
    char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;
    int interval = SEND_INTERVAL;
    char *custom_message = NULL;
    int sockfd;
    char buffer[BUFFER_SIZE];
    int opt;
    
    // Parse command line arguments
    while ((opt = getopt(argc, argv, "h:p:i:m:")) != -1) {
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
            case 'i':
                interval = atoi(optarg);
                if (interval <= 0) {
                    fprintf(stderr, "Invalid interval: %s\n", optarg);
                    exit(EXIT_FAILURE);
                }
                break;
            case 'm':
                custom_message = optarg;
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
    // signal(SIGPIPE, signal_handler);
    
    printf("TCP Client starting...\n");
    printf("Target: %s:%d\n", host, port);
    printf("Send interval: %d seconds\n", interval);
    printf("Press Ctrl+C to stop\n\n");
    
    // Create connection
    sockfd = create_socket_connection(host, port);
    if (sockfd < 0) {
        exit(EXIT_FAILURE);
    }
    
    // Main loop - send data every interval seconds
    while (running) {
        // Generate message
        generate_message(buffer, sizeof(buffer), custom_message);
        
        // Send data
        if (send_data(sockfd, buffer) < 0) {
            fprintf(stderr, "Failed to send data, attempting to reconnect...\n");
            close(sockfd);
            
            // Attempt to reconnect
            sockfd = create_socket_connection(host, port);
            if (sockfd < 0) {
                fprintf(stderr, "Reconnection failed, exiting...\n");
                break;
            }
            continue;
        }
        
        // Wait for the specified interval
        for (int i = 0; i < interval && running; i++) {
            sleep(1);
        }
    }
    
    // Cleanup
    printf("Closing connection...\n");
    close(sockfd);
    printf("TCP Client stopped.\n");
    
    return EXIT_SUCCESS;
}
