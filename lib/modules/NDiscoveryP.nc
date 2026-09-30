#include <Timer.h>

#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"

module NDiscoveryP{
    uses interface Timer<TMilli> as periodicTimer;
    uses interface SimpleSend as Sender;

    provides interface NDiscovery;
}

implementation {

    enum
    {
        MAX_NEIGHBORS = 32,
        MAX_MISSED = 5,
        DISCOVERY_PERIOD = 5000        
    };

    typedef struct
    {
        uint16_t nodeID;
        uint8_t quality;
        bool active;
    } Neighbor;

    typedef struct {
        bool used;

        uint16_t sent;
        uint16_t received;

        uint16_t lastSeq;

        uint8_t consecutiveMisses;
    }NeighborStats;

    Neighbor neighborTable[MAX_NEIGHBORS];
    NeighborStats neighborStats[MAX_NEIGHBORS];

    uint16_t discoverySeq = 0;
    task void sendDiscoveryTask();

    int8_t findNeighbor(uint16_t nodeID) {
        uint8_t i;

        for (i=0; i < MAX_NEIGHBORS; i++) {
            if (neighborStats[i].used && neighborTable[i].nodeID == nodeID){
                return i;
            }
        }
        return -1;
    }

    int8_t findFreeSlot() {
        uint8_t i;

        for (i = 0; i < MAX_NEIGHBORS; i++){
            if (!neighborStats[i].used){
            return i;
            }
        }
        return -1;
    }

    void updateQuality(uint8_t index){

        if(neighborStats[index].sent == 0){
            neighborTable[index].quality = 0;
        }else {
            neighborTable[index].quality = (uint8_t)((uint32_t)neighborStats[index].received *100) / neighborStats[index].sent;
        }
    }

    command void NDiscovery.start()
    {
        uint8_t i;
        discoverySeq = 0;

        for (i = 0; i< MAX_NEIGHBORS; i++){
        neighborTable[i].nodeID = 0;
        neighborTable[i].quality = 0;
        neighborTable[i].active = FALSE;
        
        neighborStats[i].used = FALSE;
        neighborStats[i].sent = 0;
        neighborStats[i].received = 0;
        neighborStats[i].lastSeq = 0;
        neighborStats[i].consecutiveMisses = 0;
        }
        call periodicTimer.startPeriodic(DISCOVERY_PERIOD);

        dbg(NEIGHBOR_CHANNEL, "Node %d: Neighbor discovery started\n", TOS_NODE_ID);
    }

    event void periodicTimer.fired() {
        post sendDiscoveryTask();
    }

    task void sendDiscoveryTask(){
        pack discoveryPacket;

        NeighborDiscoveryHeader *header;

        uint8_t i;
        discoverySeq++;

        discoveryPacket.src = TOS_NODE_ID;            // currentnode is the source
        discoveryPacket.dest = AM_BROADCAST_ADDR;     // nodes within range will receive the packet (TTL)
        discoveryPacket.seq = discoverySeq;           // for every discovery announcment
        discoveryPacket.TTL = 1;                      // only 1 hop (neighbor)
        discoveryPacket.protocol = PROTOCOL_NEIGHBOR; // reuse packet structure

        header = (NeighborDiscoveryHeader *)discoveryPacket.payload;
        header->type = ND_REQUEST;
        header->seq = discoverySeq;

        for (i = 0; i < MAX_NEIGHBORS; i++){
            if (neighborStats[i].used){
                neighborStats[i].sent++;

                if (discoverySeq > neighborStats[i].lastSeq){
                    uint16_t missed = discoverySeq - neighborStats[i].lastSeq - 1;

                    if (missed >= MAX_MISSED) {
                        neighborStats[i].consecutiveMisses = MAX_MISSED;
                        neighborTable[i].active = FALSE;
                    }
                }
                updateQuality(i);
            }
        }


        call Sender.send(discoveryPacket, AM_BROADCAST_ADDR);

        dbg(NEIGHBOR_CHANNEL, "Node %d sent neighbor discovery seq %d\n", TOS_NODE_ID, discoverySeq);
    }

    command void NDiscovery.receive(pack msg, uint16_t source) {

        NeighborDiscoveryHeader *header;

        pack replyPacket;

        int8_t index;


        /*
         * Ignore ourselves.
         */
        if (source == TOS_NODE_ID) {
            return;
        }


        header =
            (NeighborDiscoveryHeader *)msg.payload;


        /*
         * ------------------------------------------------
         * NEIGHBOR REQUEST
         * ------------------------------------------------
         */
        if (header->type == ND_REQUEST) {

            /*
             * Build the reply.
             */
            replyPacket.src = TOS_NODE_ID;

            replyPacket.dest = source;

            replyPacket.seq = header->seq;

            replyPacket.TTL = 1;

            replyPacket.protocol = PROTOCOL_NEIGHBOR;


            /*
             * Put the Neighbor Reply header
             * inside the payload.
             */
            header =
                (NeighborDiscoveryHeader *)replyPacket.payload;

            header->type = ND_REPLY;

            header->seq = msg.seq;


            /*
             * Reply immediately.
             */
            call Sender.send(
                replyPacket,
                source
            );


            dbg(NEIGHBOR_CHANNEL,
                "Node %d replied to neighbor request from %d seq %d\n",
                TOS_NODE_ID,
                source,
                msg.seq);
        }


        /*
         * ------------------------------------------------
         * NEIGHBOR REPLY
         * ------------------------------------------------
         */
        else if (header->type == ND_REPLY) {

            index = findNeighbor(source);


            /*
             * This is a new neighbor.
             */
            if (index < 0) {

                index = findFreeSlot();


                /*
                 * Table is full.
                 */
                if (index < 0) {

                    dbg(NEIGHBOR_CHANNEL,
                        "Node %d neighbor table full; ignoring %d\n",
                        TOS_NODE_ID,
                        source);

                    return;
                }


                neighborStats[index].used = TRUE;

                neighborTable[index].nodeID = source;


                /*
                 * Since the sequence number is global,
                 * it tells us how many discovery requests
                 * have happened so far.
                 */
                neighborStats[index].sent =
                    header->seq;

                neighborStats[index].received = 1;

                neighborStats[index].lastSeq =
                    header->seq;


                /*
                 * Requests before this reply were missed.
                 */
                if (header->seq > 1) {

                    neighborStats[index].consecutiveMisses =
                        header->seq - 1;

                } else {

                    neighborStats[index].consecutiveMisses = 0;
                }


                neighborTable[index].active =
                    (neighborStats[index].consecutiveMisses
                     < MAX_MISSED);


                updateQuality(index);
            }


            /*
             * Existing neighbor.
             */
            else {

                /*
                 * Ignore duplicate or old replies.
                 */
                if (header->seq <=
                    neighborStats[index].lastSeq) {

                    return;
                }


                /*
                 * Check for missing sequence numbers.
                 */
                if (header->seq >
                    neighborStats[index].lastSeq + 1) {

                    uint16_t missed =
                        header->seq -
                        neighborStats[index].lastSeq -
                        1;


                    if (missed >= MAX_MISSED) {

                        neighborTable[index].active = FALSE;

                        neighborStats[index].consecutiveMisses =
                            MAX_MISSED;

                    } else {

                        neighborStats[index].consecutiveMisses =
                            missed;
                    }

                } else {

                    /*
                     * We received the next expected reply.
                     */
                    neighborStats[index].consecutiveMisses = 0;
                }


                neighborStats[index].received++;

                neighborStats[index].lastSeq =
                    header->seq;


                /*
                 * A response means the neighbor is
                 * currently reachable again.
                 */
                neighborTable[index].active = TRUE;


                updateQuality(index);
            }


            dbg(NEIGHBOR_CHANNEL,
                "Node %d received neighbor reply from %d seq %d quality %d%% active %d\n",
                TOS_NODE_ID,
                source,
                header->seq,
                neighborTable[index].quality,
                neighborTable[index].active);
        }
    }

    command void NDiscovery.printNeighbors() {
        uint8_t i;

        dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID);

        for (i = 0; i < MAX_NEIGHBORS; i++){
            if (neighborStats[i].used) {
                dbg(NEIGHBOR_CHANNEL, "Neighbor %d: quality=%d%% active=%d\n", neighborTable[i].nodeID, neighborTable[i].quality, neighborTable[i].active);
            }
        }
    }

    command bool NDiscovery.isCurrentNeighbor(uint16_t nodeID)
    {

        uint8_t index;

        index = findNeighbor(nodeID);

        if (index < 0) {
            return FALSE;
        }

        return neighborTable[index].active;
    }

        command uint8_t NDiscovery.getNeighborCount() {

        uint8_t i;

        uint8_t count = 0;


        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used &&
                neighborTable[i].active) {

                count++;
            }
        }


        return count;
    }


    /*
     * Allow another module to query the table.
     */
    command bool NDiscovery.getNeighbor(
        uint8_t index,
        uint16_t* nodeID,
        uint8_t* quality,
        bool* active) {

        uint8_t i;

        uint8_t current = 0;


        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used) {

                if (current == index) {

                    *nodeID =
                        neighborTable[i].nodeID;

                    *quality =
                        neighborTable[i].quality;

                    *active =
                        neighborTable[i].active;

                    return TRUE;
                }

                current++;
            }
        }


        return FALSE;
    }
}