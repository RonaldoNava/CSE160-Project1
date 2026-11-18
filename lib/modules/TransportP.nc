#include <string.h>
#include "../../includes/socket.h"
#include "../../includes/transport_packet.h"
#include <Timer.h>

module TransportP {
    provides interface Transport;

    uses interface IP;
    uses interface Timer<TMilli> as transportTimer;
    uses interface Random;    
}

implementation {
// #region Structs and Variables
 //(Provides)
    void enterTimeWait(socket_store_t *s);

    typedef struct {
        uint8_t srcPort, destPort, flags;

        uint16_t seq, ack;

        uint8_t window, length;

        uint8_t data[TP_MAX_DATA_SIZE];
    }TransportSegment;

    socket_store_t sockets[MAX_NUM_OF_SOCKETS];

    bool testDropNextData = FALSE;

// #endregion

// #region Packet Encoding and Decoding
    //encode 16-bit seq or ack numbers (each position in payload arr can only hold one byte)
    void encode16(uint8_t *output, uint16_t value){
        output[0] = (uint8_t)(value >> 8);
        output[1] = (uint8_t)(value & 0xFF);
    }
    uint16_t decode16(uint8_t high, uint8_t low){
        return ((uint16_t)high << 8) | low;
    }

    bool validSegment(TransportSegment *segment){
        if (segment->srcPort == 0 || segment->destPort == 0)
            return FALSE;
        //window must not exceed 128 bytes
        if (segment->window > SOCKET_BUFFER_SIZE)
            return FALSE;
        //dont accept packets who advertise more that 11 bytes of applicattion data
        if (segment->length > TP_MAX_DATA_SIZE)
            return FALSE;

        switch (segment->flags) {
            case TP_FLAG_SYN:
            case TP_FLAG_SYN | TP_FLAG_ACK:
            case TP_FLAG_ACK:
            case TP_FLAG_FIN:
            return segment->length == 0;

            case TP_FLAG_DATA:
            return segment->length > 0;

            default:
                return FALSE;
        }
    }

    uint8_t encodeSegment(TransportSegment *segment, uint8_t *payload, uint8_t capacity){
        uint8_t i;

        if (segment == NULL || payload == NULL)
            return 0;

        if (!validSegment(segment))
            return 0;

        if (TP_HEADER_SIZE + segment->length > capacity)
            return 0;

        payload[TP_OFF_SRC_PORT] = segment->srcPort;
        payload[TP_OFF_DST_PORT] = segment->destPort;
        payload[TP_OFF_FLAGS] = segment->flags;

        encode16(&payload[TP_OFF_SEQ], segment->seq);
        encode16(&payload[TP_OFF_ACK], segment->ack);

        payload[TP_OFF_WINDOW] = segment->window;
        payload[TP_OFF_LENGTH] = segment->length;

        for (i = 0; i < segment->length; i++) {
            payload[TP_HEADER_SIZE + i] = segment->data[i];
        }

        return TP_HEADER_SIZE + segment->length;
    }

    bool decodeSegment(uint8_t *payload, uint8_t payloadSize, TransportSegment *segment){
        uint8_t i;

        if (payload == NULL || segment == NULL)
            return FALSE;

        if (payloadSize < TP_HEADER_SIZE || payloadSize > PACKET_MAX_PAYLOAD_SIZE)
            return FALSE;

        segment->srcPort = payload[TP_OFF_SRC_PORT];
        segment->destPort = payload[TP_OFF_DST_PORT];
        segment->flags = payload[TP_OFF_FLAGS];

        segment->seq = decode16(payload[TP_OFF_SEQ], payload[TP_OFF_SEQ + 1]);
        segment->ack = decode16(payload[TP_OFF_ACK], payload[TP_OFF_ACK + 1]);

        segment->window = payload[TP_OFF_WINDOW];
        segment->length = payload[TP_OFF_LENGTH];

        if (!validSegment(segment))
            return FALSE;

        if (TP_HEADER_SIZE + segment->length > payloadSize)
            return FALSE;

        for (i = 0; i < segment->length; i++) {
            segment->data[i] = payload[TP_HEADER_SIZE + i];
        }

        return TRUE;

    }
// #endregion

// #region Socket Lookup and Allocation
    int8_t findConnection(uint16_t localAddr, uint8_t localPort,
                          uint16_t remoteAddr, uint8_t remotePort) {
        uint8_t i;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].used &&
                sockets[i].state != LISTEN &&
                sockets[i].state != CLOSED &&
                sockets[i].localAddr == localAddr &&
                sockets[i].src == localPort &&
                sockets[i].dest.addr == remoteAddr &&
                sockets[i].dest.port == remotePort) {

                return i;
            }
        }

        return -1;
    }

    int8_t findListener(uint16_t addr, uint8_t port) {
        uint8_t i;
        for (i=0; i<MAX_NUM_OF_SOCKETS; i++)
            if (sockets[i].used && 
                sockets[i].state == LISTEN && 
                sockets[i].localAddr == addr && 
                sockets[i].src == port){
                
                return i;
            }
               
        return -1;
    }

    int8_t allocateSocket() {
        uint8_t i;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (!sockets[i].used) {
                //assign record to 0 before we assign new values
                memset(&sockets[i], 0, sizeof(socket_store_t));

                sockets[i].used = TRUE;
                sockets[i].state = CLOSED;
                sockets[i].localAddr = TOS_NODE_ID;

                return i;
            }
        }

        return -1;
    }

    int8_t socketIndex(socket_t fd) {
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS)
            return -1;
        
        if(!sockets[fd-1].used)
            return -1;

        return fd -1;
    }

// #endregion

// #region Timer and Sequence Helpers
    uint32_t now() {
        return call transportTimer.getNow();
    }

    bool due(uint32_t t, uint32_t deadline) {
        return (int32_t)(t-deadline) >= 0;
    }

    void progress(socket_store_t *s) {
        s->progressDeadline = now() + TRANSPORT_STALL_MS;
    }

    void arm(socket_store_t *s) {
        s->timerActive = TRUE;
        s->retransmissionDeadline = now() + TRANSPORT_RTO_MS;
    }

    uint16_t generateISN() {
        return 100 + (call Random.rand16() % 4096);
    }

     uint8_t window(socket_store_t *s) {
        return SOCKET_BUFFER_SIZE - (s->nextExpected - s->readBase);
    }

    uint16_t ackNumber(socket_store_t *s) {
        return s->nextExpected + (s->finReceived ? 1 : 0);
    }

    void logState(socket_store_t *s, char *eventName) {
        dbg("Project3TGen", "t=%lu node=%u conn=%u:%u->%u:%u fd=%u %s\n", (unsigned long)now(),
            TOS_NODE_ID, s->localAddr, s->src, s->dest.addr, s->dest.port, (unsigned int)(s-sockets+1), eventName);
    }

// #endregion 

// #region Packet Transmission
    error_t sendSegment(uint16_t destination, TransportSegment *segment){
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
        uint8_t length;

        length = encodeSegment(segment, payload, PACKET_MAX_PAYLOAD_SIZE);

        if (length == 0)
            return FAIL;

        return call IP.send(destination, PROTOCOL_TCP, payload, length);
    }

    error_t sendControl(socket_store_t *s, uint8_t flags, uint16_t seq, uint16_t ack){
        TransportSegment segment;

        segment.srcPort = s->src;
        segment.destPort = s->dest.port;

        segment.flags = flags;
        segment.seq = seq;
        segment.ack = ack;

        segment.window = window(s);

        segment.length = 0;

        return sendSegment(s->dest.addr, &segment);    
    }

    void sendAck(socket_store_t *s) {
        uint16_t seq = s->nextSend;

        if (s->finSent)
            seq++;

        s->ackPending = sendControl(s, TP_FLAG_ACK, seq, ackNumber(s)) != SUCCESS;
    }

    error_t sendData(socket_store_t *s, uint16_t seq, uint8_t length, bool retry) {
        TransportSegment segment;
        uint8_t i;

        segment.srcPort = s->src;
        segment.destPort = s->dest.port;
        segment.flags = TP_FLAG_DATA;
        segment.seq = seq;
        segment.ack = 0;
        segment.window = window(s);
        segment.length = length;

        for (i = 0; i < length; i++) {
            segment.data[i] = s->sendBuff[(seq + i) % SOCKET_BUFFER_SIZE];
        }

        if (sendSegment(s->dest.addr, &segment) != SUCCESS)
            return FAIL;

        dbg("Project3TGen", "t=%lu node=%u conn=%u:%u->%u:%u %s seq=%u len=%u peerWnd=%u\n",
            (unsigned long)now(), TOS_NODE_ID, s->localAddr, s->src, s->dest.addr, s->dest.port,
            retry ? "DATA_RETX" : "DATA_TX", seq, length, s->peerWindow);
        return SUCCESS;
    }

// #endregion

// #region Socket Management
    //start the shared transport timer (each socket has its own deadline).
    command void Transport.start() {
        call transportTimer.startPeriodic(TRANSPORT_TIMER_MS);
    }

    command socket_t Transport.socket(){
        int8_t index = allocateSocket();

        if (index < 0)
            return 0;

        return index + 1;
    }

    command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
        int8_t index = socketIndex(fd);

        if (index < 0 || addr == NULL)
            return FAIL;

        if (sockets[index].state != CLOSED)
            return FAIL;
        
        if (addr->addr != TOS_NODE_ID || addr->port == 0)
            return FAIL;

        sockets[index].localAddr = addr->addr;
        sockets[index].src = addr->port;

        return SUCCESS;
    }

    command error_t Transport.listen(socket_t fd) {
        int8_t index = socketIndex(fd);
        socket_store_t *s;

        if (index < 0)
            return FAIL;

        s = &sockets[index];
        if (s->state != CLOSED || s->src == 0)
            return FAIL;

        if (findListener(s->localAddr, s->src) >= 0)
            return FAIL;

        s->state = LISTEN;
        logState(s, "LISTEN");
        return SUCCESS;
    }

        command socket_t Transport.accept(socket_t fd) {
        int8_t index = socketIndex(fd);
        uint8_t i;

        if (index < 0 || sockets[index].state != LISTEN)
            return 0;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].used && sockets[i].state == ESTABLISHED &&
                sockets[i].src == sockets[index].src && sockets[i].acceptedPending) {
                sockets[i].acceptedPending = FALSE;
                return i + 1;
            }
        }
        return 0;
    }

    command socket_t Transport.lookup(uint16_t remote, uint8_t localPort, uint8_t remotePort) {
        int8_t index = findConnection(TOS_NODE_ID, localPort, remote, remotePort);
        if (index < 0)
            return 0;
        return index + 1;
    }

// #endregion

// #region Three-Way Handshake
    command error_t Transport.connect(socket_t fd, socket_addr_t *addr){
        int8_t index = socketIndex(fd);
        socket_store_t *s;

        if (index < 0 || addr == NULL)
            return FAIL;
        
        s = &sockets[index];

        if (s->state != CLOSED || s->src == 0)
            return FAIL;

        if (addr->addr == 0 || addr->addr > 255 ||
        addr->addr == TOS_NODE_ID || addr->port == 0)
        return FAIL;
        //prevent duplicate connections
        if (findConnection(s->localAddr, s->src, addr->addr, addr->port) >= 0)
            return FAIL;

        //assign remote endpoint
        s->dest.addr = addr->addr;
        s->dest.port = addr->port;

        //initialize connection
        s->localISN = generateISN();
        s->peerWindow = 0;
        s->sendWindow = TP_MAX_DATA_SIZE;
        s->retryCount = 0;

        s->state = SYN_SENT;
        s->activeOpen = TRUE;

        //transmit SYN
        s->synSubmitted = sendControl(s, TP_FLAG_SYN, s->localISN, 0) == SUCCESS;

        //set retransmission deadline
        s->timerActive = TRUE;
        s->retransmissionDeadline = call transportTimer.getNow() + TRANSPORT_RTO_MS;

        dbg("Project3TGen",
            "Node %d: conn=%d:%d->%d:%d SYN_SENT seq=%u submitted=%d\n",
            TOS_NODE_ID,
            s->localAddr, s->src,
            s->dest.addr, s->dest.port,
            s->localISN, s->synSubmitted);

        return SUCCESS;
    }

    error_t sendSynAck(socket_store_t *s) {
        error_t result;

        result = sendControl(s, TP_FLAG_SYN | TP_FLAG_ACK,
                             s->localISN, s->remoteISN + 1);
                    
        if (result == SUCCESS)
            s->synSubmitted = TRUE;
        
        return result;
    }



    void handleSyn(uint16_t source, TransportSegment *segment) {

        int8_t index;
        socket_store_t *s;

        // Validate the SYN
        if (segment->flags != TP_FLAG_SYN ||
            segment->length != 0 ||
            segment->ack != 0)
            return;

        if (source == 0 || source > 255 ||
            source == TOS_NODE_ID ||
            segment->seq > 65533U)
            return;

        //check for existing connection
        index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);

        if (index >= 0) {
            s = &sockets[index];

            if (!s->activeOpen &&
                s->remoteISN == segment->seq &&
                (s->state == SYN_RCVD || s->state == ESTABLISHED)) {
                sendSynAck(s);
            }

            return;
        }

        //check if a server is listening
        if (findListener(TOS_NODE_ID, segment->destPort) < 0)
            return;

        //allocate independent connection
        index = allocateSocket();

        if (index < 0)
            return;

        s = &sockets[index];

        //initialize connection endpoints
        s->src = segment->destPort;
        s->dest.addr = source;
        s->dest.port = segment->srcPort;

        //initialize seq numbers
        s->localISN = generateISN();
        s->remoteISN = segment->seq;

        s->sendBase = s->localISN + 1;
        s->nextSend = s->localISN + 1;
        s->writeEnd = s->localISN + 1;

        s->readBase = s->remoteISN + 1;
        s->nextExpected = s->remoteISN + 1;

        //initialize windows
        s->sendWindow = TP_MAX_DATA_SIZE;
        s->peerWindow = segment->window;

        //update connection state
        s->state = SYN_RCVD;
        s->retryCount = 0;

        //send SYN-ACK
        sendSynAck(s);

        //start retransmission tracking
        s->timerActive = TRUE;
        s->retransmissionDeadline = call transportTimer.getNow() + TRANSPORT_RTO_MS;

        dbg("Project3TGen",
            "Node %d: conn=%d:%d->%d:%d SYN_RCVD seq=%u ack=%u submitted=%d\n",
            TOS_NODE_ID,
            s->localAddr, s->src,
            s->dest.addr, s->dest.port,
            s->localISN, s->nextExpected,
            s->synSubmitted);
    }

    void handleSynAck(uint16_t source, TransportSegment *segment){
        int8_t index;
        socket_store_t *s;

        index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);

        if (index < 0)
            return;

        s = &sockets[index];

        //validate the SYN-ACK
        if (segment->flags != (TP_FLAG_SYN | TP_FLAG_ACK) ||
            segment->length != 0 ||
            segment->seq > 65533U ||
            segment->ack != s->localISN + 1 ||
            !s->synSubmitted ||
            !s->activeOpen || s->failed)
            return;

        //handle retransmitted SYN-ACK
        if (s->state != SYN_SENT) {
            if (segment->seq == s->remoteISN) {
                sendControl(s, TP_FLAG_ACK, s->localISN + 1, s->remoteISN + 1);
            }
            return;
        }

        //send final handshake ACK
        if (sendControl(s, TP_FLAG_ACK,
                        s->localISN + 1,
                        segment->seq + 1) != SUCCESS)
            return;

        //initialize sequence numbers
        s->remoteISN = segment->seq;

        s->sendBase = s->localISN + 1;
        s->nextSend = s->localISN + 1;
        s->writeEnd = s->localISN + 1;

        s->readBase = s->remoteISN + 1;
        s->nextExpected = s->remoteISN + 1;

        s->peerWindow = segment->window;

        //complete client-side setup
        s->timerActive = FALSE;
        s->retryCount = 0;
        s->state = ESTABLISHED;
        progress(s);

        dbg("Project3TGen",
            "Node %d: conn=%d:%d->%d:%d ESTABLISHED sendBase=%u nextExpected=%u\n",
            TOS_NODE_ID,
            s->localAddr, s->src,
            s->dest.addr, s->dest.port,
            s->sendBase, s->nextExpected);

        signal Transport.connectDone(index + 1, SUCCESS);
    }


    void handleHandshakeAck(uint16_t source, TransportSegment *segment) {
        int8_t index;
        int8_t listener;
        socket_store_t *s;

        index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);

        if (index < 0)
            return;

        s = &sockets[index];

        //validate the final ACK
        if (s->state != SYN_RCVD ||
            !s->synSubmitted ||
            segment->flags != TP_FLAG_ACK ||
            segment->length != 0 ||
            segment->seq != s->remoteISN + 1 ||
            segment->ack != s->localISN + 1)
            return;

        s->peerWindow = segment->window;

        //complete server-side setup
        s->timerActive = FALSE;
        s->retryCount = 0;
        s->state = ESTABLISHED;
        progress(s);

        dbg("Project3TGen",
            "Node %d: conn=%d:%d->%d:%d ESTABLISHED sendBase=%u nextExpected=%u\n",
            TOS_NODE_ID,
            s->localAddr, s->src,
            s->dest.addr, s->dest.port,
            s->sendBase, s->nextExpected);

        listener = findListener(s->localAddr, s->src);

        if (listener >= 0) {
            s->acceptedPending = TRUE;

            signal Transport.accepted(listener + 1, index + 1);
        }
    }

// #endregion

// #region Reliable Data Transfer
    //store bytes until they are acknowledged; never overwrite unacknowledged data.
    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        int8_t index = socketIndex(fd);
        uint16_t count = 0;
        socket_store_t *s;

        if (index < 0 || buff == NULL)
            return 0;
        s = &sockets[index];
        if (s->state != ESTABLISHED || s->closeRequested)
            return 0;

        if (s->writeEnd == s->sendBase && bufflen > 0)
            progress(s);

        while (count < bufflen && s->writeEnd - s->sendBase < SOCKET_BUFFER_SIZE &&
               s->writeEnd < 65534U) {
            s->sendBuff[s->writeEnd % SOCKET_BUFFER_SIZE] = buff[count];
            s->writeEnd++;
            count++;
        }
        return count;
    }

    //read bytes that have arrived in order and advertise the newly available space.
    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        int8_t index = socketIndex(fd);
        uint16_t count = 0;
        socket_store_t *s;

        if (index < 0 || buff == NULL)
            return 0;
        s = &sockets[index];

        while (count < bufflen && s->readBase < s->nextExpected) {
            buff[count] = s->rcvdBuff[s->readBase % SOCKET_BUFFER_SIZE];
            s->readBase++;
            count++;
        }
        if (count > 0 && !s->failed)
            s->ackPending = TRUE;
        return count;
    }

    command void Transport.dropNextData() {
        testDropNextData = TRUE;
    }

    void handleAck(uint16_t source, TransportSegment *segment) {
        int8_t index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);
        socket_store_t *s;
        uint16_t count;

        if (index < 0)
            return;
        s = &sockets[index];

        if (s->state == SYN_RCVD) {
            handleHandshakeAck(source, segment);
            return;
        }
        if (s->state == SYN_SENT || s->state == TIME_WAIT || s->failed)
            return;

        //an ACK for FIN consumes sequence space but acknowledges no data bytes
        if (s->finSent && segment->ack == s->finSeq + 1) {
            if (s->finAcknowledged)
                return;
            s->finAcknowledged = TRUE;
            s->timerActive = FALSE;
            s->retryCount = 0;
            progress(s);
            logState(s, "FIN_ACK_RX");
            if (s->finReceived) {
                enterTimeWait(s);
            } else {
                s->state = FIN_WAIT_2;
                logState(s, "FIN_WAIT_2");
            }
            return;
        }

        if (segment->ack < s->sendBase || segment->ack > s->nextSend)
            return;
        // Stop-and-wait accepts only complete segment ACKs
        if (segment->ack != s->sendBase && segment->ack != s->nextSend)
            return;

        count = segment->ack - s->sendBase;
        if (count > 0 || segment->window > s->peerWindow)
            s->peerWindow = segment->window;
        if (count > 0) {
            s->sendBase = segment->ack;
            s->timerActive = FALSE;
            s->retryCount = 0;
            progress(s);
            dbg("Project3TGen", "t=%lu node=%u ACK_RX ack=%u wnd=%u outstanding=%u\n",
                (unsigned long)now(), TOS_NODE_ID, segment->ack, s->peerWindow, s->nextSend - s->sendBase);
            signal Transport.acknowledged(index + 1, count);
        }
    }

    void handleData(uint16_t source, TransportSegment *segment) {
        int8_t index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);
        socket_store_t *s;
        uint8_t i;

        if (index < 0)
            return;
        s = &sockets[index];
        if (s->failed || s->state == SYN_SENT || s->state == SYN_RCVD)
            return;

        //test: discard one incoming DATA at the receiver
        if (testDropNextData && s->state == ESTABLISHED) {
            testDropNextData = FALSE;
            dbg("Project3TGen", "t=%lu node=%u TEST_DROP seq=%u len=%u\n",
                (unsigned long)now(), TOS_NODE_ID, segment->seq, segment->length);
            return;
        }

        if (!s->finReceived && segment->seq == s->nextExpected &&
            segment->length <= window(s) && (uint32_t)segment->seq + segment->length <= 65534UL) {
            for (i = 0; i < segment->length; i++) {
                s->rcvdBuff[(segment->seq + i) % SOCKET_BUFFER_SIZE] = segment->data[i];
            }
            s->nextExpected += segment->length;
            progress(s);
            dbg("Project3TGen", "t=%lu node=%u DATA_RX seq=%u len=%u ack=%u wnd=%u\n",
                (unsigned long)now(), TOS_NODE_ID, segment->seq, segment->length, ackNumber(s), window(s));
        } else {
            logState(s, "DATA_DISCARD duplicate/gap/window");
        }
        //duplicate or out-of-order data receives the same ACK
        sendAck(s);
    }

// #endregion

 // #region Connection Teardown
    //keep sequence state around so a duplicate FIN can still be acknowledged
    void enterTimeWait(socket_store_t *s) {
        s->state = TIME_WAIT;
        s->timerActive = FALSE;
        s->timeWaitDeadline = now() + TRANSPORT_TIME_WAIT_MS;
        logState(s, "TIME_WAIT");
    }

    void handleFin(uint16_t source, TransportSegment *segment) {
        int8_t index = findConnection(TOS_NODE_ID, segment->destPort, source, segment->srcPort);
        socket_store_t *s;

        if (index < 0)
            return;
        s = &sockets[index];
        if (s->failed || s->state == SYN_SENT || s->state == SYN_RCVD)
            return;

        if (s->finReceived) {
            if (segment->seq == s->nextExpected) {
                sendAck(s);
                if (s->state == TIME_WAIT)
                    s->timeWaitDeadline = now() + TRANSPORT_TIME_WAIT_MS;
            }
            return;
        }
        if (segment->seq != s->nextExpected || segment->seq > 65534U) {
            sendAck(s);
            return;
        }

        s->finReceived = TRUE;
        //the server automatically requests its own close on FIN
        s->closeRequested = TRUE;
        progress(s);
        logState(s, "FIN_RX");
        sendAck(s);

        if (s->finAcknowledged) {
            enterTimeWait(s);
        } else if (s->finSent) {
            s->state = CLOSING;
            logState(s, "CLOSING");
        } else {
            s->state = CLOSE_WAIT;
            logState(s, "CLOSE_WAIT");
        }
    }

    command error_t Transport.close(socket_t fd) {
        int8_t index = socketIndex(fd);
        socket_store_t *s;

        if (index < 0)
            return FAIL;
        s = &sockets[index];
        if (s->state != ESTABLISHED && s->state != CLOSE_WAIT)
            return FAIL;
        s->closeRequested = TRUE;
        progress(s);
        return SUCCESS;
    }

    command error_t Transport.release(socket_t fd) {
        int8_t index = socketIndex(fd);
        if (index < 0 || sockets[index].state != CLOSED)
            return FAIL;
        sockets[index].used = FALSE;
        return SUCCESS;
    }
 // #endregion

// #region Retransmission and Timeouts

    void failConnection(uint8_t index) {
        socket_store_t *s = &sockets[index];
        bool opening = s->state == SYN_SENT;

        logState(s, "FAIL retry/stall limit");
        s->failed = TRUE;
        s->ackPending = FALSE;
        enterTimeWait(s);
        if (opening)
            signal Transport.connectDone(index + 1, FAIL);
    }

    event void transportTimer.fired() {
        uint8_t i, length;
        uint16_t remaining;
        uint32_t current = now();
        socket_store_t *s;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            s = &sockets[i];
            if (!s->used || s->state == CLOSED || s->state == LISTEN)
                continue;

            if (s->ackPending && !s->failed)
                sendAck(s);

            if (s->state == TIME_WAIT) {
                if (due(current, s->timeWaitDeadline) && s->readBase == s->nextExpected &&
                    !s->ackPending) {
                    s->state = CLOSED;
                    logState(s, "CLOSED");
                    // Free before notifying the application; do not clear a newly allocated socket.
                    s->used = FALSE;
                    signal Transport.closed(i + 1, s->failed ? FAIL : SUCCESS);
                }
                continue;
            }

            //retransmit the same logical sequence number when its deadline expires
            if (s->timerActive && due(current, s->retransmissionDeadline)) {
                if (s->retryCount >= TRANSPORT_MAX_RETRIES) {
                    failConnection(i);
                    continue;
                }
                s->retryCount++;
                logState(s, "TIMEOUT_RETRY");

                if (s->state == SYN_SENT) {
                    if (sendControl(s, TP_FLAG_SYN, s->localISN, 0) == SUCCESS)
                        s->synSubmitted = TRUE;
                } else if (s->state == SYN_RCVD) {
                    sendSynAck(s);
                } else if (s->finSent && !s->finAcknowledged) {
                    sendControl(s, TP_FLAG_FIN, s->finSeq, 0);
                } else if (s->nextSend > s->sendBase) {
                    sendData(s, s->sendBase, s->nextSend - s->sendBase, TRUE);
                
                }
                arm(s);
                continue;
            }

            if (s->state == SYN_SENT || s->state == SYN_RCVD || s->finSent) {
                if (s->state == FIN_WAIT_2 && due(current, s->progressDeadline))
                    failConnection(i);
                continue;
            }

            // Stop-and-wait: send new bytes ONLY if the previous segment was ACKed
            if (s->nextSend == s->sendBase && s->writeEnd > s->nextSend && s->peerWindow > 0) {
                remaining = s->writeEnd - s->nextSend;
                length = TP_MAX_DATA_SIZE;
                if (remaining < length)
                    length = remaining;
                if (s->peerWindow < length)
                    length = s->peerWindow;
                if (s->sendWindow < length)
                    length = s->sendWindow;

                if (length > 0 && sendData(s, s->nextSend, length, FALSE) == SUCCESS) {
                    s->nextSend += length;
                    s->retryCount = 0;
                    arm(s);
                }
            } else if (s->closeRequested && s->sendBase == s->writeEnd && !s->finSent) {
                // FIN is sent only after all queued data has been acknowledged
                s->finSeq = s->writeEnd;
                if (sendControl(s, TP_FLAG_FIN, s->finSeq, 0) == SUCCESS) {
                    s->finSent = TRUE;
                    s->state = s->finReceived ? LAST_ACK : FIN_WAIT_1;
                    logState(s, s->finReceived ? "LAST_ACK" : "FIN_WAIT_1");
                    s->retryCount = 0;
                    arm(s);
                }
            }

            if (!s->timerActive && ((s->writeEnd > s->nextSend && s->peerWindow > 0) ||
                                    s->closeRequested) && due(current, s->progressDeadline)) {
                if (s->writeEnd == s->nextSend || s->peerWindow > 0)
                    failConnection(i);
            }
        }
    }
    
// #endregion

// #region Incoming Packet Processing
    error_t receiveTransport(pack *packet) {
        TransportSegment segment;
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];

        //validate network packet
        if (packet == NULL)
            return FAIL;

        if (packet->protocol != PROTOCOL_TCP ||
            packet->dest != TOS_NODE_ID)
            return FAIL;

        //copy transport payload
        memcpy(payload, packet->payload,
            PACKET_MAX_PAYLOAD_SIZE);

        //decode and validate segment
        if (!decodeSegment(payload,
                        PACKET_MAX_PAYLOAD_SIZE,
                        &segment))
            return FAIL;

        //dispatch the segment
        switch (segment.flags) {
            case TP_FLAG_SYN:
                handleSyn(packet->src, &segment);
                break;

            case TP_FLAG_SYN | TP_FLAG_ACK:
                handleSynAck(packet->src, &segment);
                break;

            case TP_FLAG_ACK:
                handleAck(packet->src, &segment);
                break;

            case TP_FLAG_DATA:
                handleData(packet->src, &segment);
                break;

            case TP_FLAG_FIN:
                handleFin(packet->src, &segment);
                break;

            default:
                return FAIL;
        }

        return SUCCESS;
    }

    command error_t Transport.receive(pack *packet) {
        return receiveTransport(packet);
    }

    event void IP.received(pack msg) {
        if (msg.protocol == PROTOCOL_TCP) {
            receiveTransport(&msg);
        }
    }
// #endregion
}