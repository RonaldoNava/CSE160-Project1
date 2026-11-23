#ifndef __SOCKET_H__
#define __SOCKET_H__

enum{
    MAX_NUM_OF_SOCKETS = 3,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
};

enum socket_state{
    CLOSED,
    LISTEN,
    ESTABLISHED,
    SYN_SENT,
    SYN_RCVD,

    FIN_WAIT_1,
    FIN_WAIT_2,
    CLOSE_WAIT,
    CLOSING,
    LAST_ACK,
    TIME_WAIT,
};

enum {
    TRANSPORT_RTO_MS = 3000,
    TRANSPORT_MAX_RETRIES = 5,
    TRANSPORT_TIMER_MS = 100,
    TRANSPORT_TIME_WAIT_MS = 20000,
    TRANSPORT_STALL_MS = 60000,
    TRANSPORT_WINDOW_CHECK_MS = 3000
};

typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;


// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// State of a socket. 
typedef struct socket_store_t{
    bool used;
    enum socket_state state;
    uint16_t localAddr;
    socket_port_t src; //src port
    socket_addr_t dest;

    //Connection establishment
    uint16_t localISN;
    uint16_t remoteISN;
    bool synSubmitted;
    bool activeOpen;

    // This is the sender portion.
    uint8_t sendBuff[SOCKET_BUFFER_SIZE];
  
    //Sender sequence number
    uint16_t sendBase; //last unacknowledged byte/seq num
    uint16_t nextSend; //next expected byte to be sent
    uint16_t writeEnd; //everything that is going to be sent (can be in queue)

    //Sender flow control
    uint8_t sendWindow;
    uint8_t peerWindow;

    // This is the receiver portion
    uint8_t rcvdBuff[SOCKET_BUFFER_SIZE];
    uint16_t readBase; //Sequence number of the first received byte the application hasn't read yet
    uint16_t nextExpected; //Sequence number of the next byte the receiver expects to arrive

    // Retransmission tracking
    bool timerActive; //whether it's waiting for an ACK
    uint32_t retransmissionDeadline; //DATA sent (timer starts) -> 3 second retransmission timeout-> deadline
    uint8_t retryCount; //bounded failure handling
    // Zero-Window recovery
    bool windowCheckActive;
    uint32_t windowCheckDeadline;

    // Connection teardown tracking
    bool closeRequested;
    bool finSent;
    bool finAcknowledged;
    bool finReceived;

    uint16_t finSeq;
    uint32_t timeWaitDeadline;

    bool acceptedPending;

    bool ackPending;
    bool failed;
    uint32_t progressDeadline;

}socket_store_t;

#endif
