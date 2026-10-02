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

    enum{
        MAX_NEIGHBORS = 32,
        MAX_MISSED = 5,
        DISCOVERY_PERIOD = 5000
    };

    //Information about each neighbor
    typedef struct{
        uint16_t nodeID;
        uint8_t quality;
        bool active;
    } Neighbor;


    //Information used to track each neighbor
    typedef struct{
        bool used;
        uint16_t sent;
        uint16_t received;
        uint16_t lastSeq;
        uint8_t consecutiveMisses;
    } NeighborStats;


    Neighbor neighborTable[MAX_NEIGHBORS];
    NeighborStats neighborStats[MAX_NEIGHBORS];

    uint16_t discoverySeq = 0;

    task void sendDiscoveryTask();


    //Find a neighbor in the table
    int8_t findNeighbor(uint16_t nodeID){
        uint8_t i;

        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used && neighborTable[i].nodeID == nodeID) {

                return i;
            }
        }

        return -1;
    }


    //Find an empty spot in the table
    int8_t findFreeSlot(){
        uint8_t i;

        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (!neighborStats[i].used) {
                return i;
            }
        }

        return -1;
    }


    //Calculate the percentage of discovery packets that we received from this neighbor
    void updateQuality(uint8_t index){
        if (neighborStats[index].sent == 0) {

            neighborTable[index].quality = 0;

        } else {

            neighborTable[index].quality =
                (uint8_t)((uint32_t)neighborStats[index].received * 100 / neighborStats[index].sent);
        }
    }


    //Start neighbor discovery
    command void NDiscovery.start(){
        uint8_t i;

        discoverySeq = 0;

        for (i = 0; i < MAX_NEIGHBORS; i++) {

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

        dbg(NEIGHBOR_CHANNEL,"Node %d: Neighbor discovery started\n",TOS_NODE_ID);
    }


    //Every 5 seconds, send a discovery packet
    event void periodicTimer.fired(){
        post sendDiscoveryTask();
    }


    //Send a neighbor discovery request
    task void sendDiscoveryTask(){
        pack discoveryPacket;
        NeighborDiscoveryHeader *header;

        uint8_t i;

        discoverySeq++;


        //Set up the packet
        discoveryPacket.src = TOS_NODE_ID;
        discoveryPacket.dest = AM_BROADCAST_ADDR;
        discoveryPacket.seq = discoverySeq;
        discoveryPacket.TTL = 1;
        discoveryPacket.protocol = PROTOCOL_NEIGHBOR;


        //Put the discovery header inside the packet
        header = (NeighborDiscoveryHeader *)discoveryPacket.payload;

        header->type = ND_REQUEST;
        header->seq = discoverySeq;


        //Count this request for every neighbor that we already know about
        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used) {

                neighborStats[i].sent++;

                //Check if this neighbor has missed too many discovery replies
                if (discoverySeq > neighborStats[i].lastSeq) {

                    uint16_t missed;

                    missed =
                        discoverySeq - neighborStats[i].lastSeq - 1;

                    if (missed >= MAX_MISSED) {

                        neighborStats[i].consecutiveMisses = MAX_MISSED;

                        neighborTable[i].active = FALSE;
                    }
                }

                updateQuality(i);
            }
        }


        //Send the discovery request
        call Sender.send( discoveryPacket, AM_BROADCAST_ADDR);

        dbg(NEIGHBOR_CHANNEL, "Node %d sent neighbor discovery seq %d\n", TOS_NODE_ID, discoverySeq);
    }



    //Receive a neighbor discovery packet
    command void NDiscovery.receive(pack msg, uint16_t source){
        NeighborDiscoveryHeader *header;
        pack replyPacket;

        int8_t index;


        //Ignore packets from ourselves
        if (source == TOS_NODE_ID) {
            return;
        }


        header = (NeighborDiscoveryHeader *)msg.payload;


        //A neighbor is asking us to reply
        if (header->type == ND_REQUEST) {

            replyPacket.src = TOS_NODE_ID;
            replyPacket.dest = source;
            replyPacket.seq = header->seq;
            replyPacket.TTL = 1;
            replyPacket.protocol = PROTOCOL_NEIGHBOR;


            header = (NeighborDiscoveryHeader *)replyPacket.payload;

            header->type = ND_REPLY;
            header->seq = msg.seq;


            call Sender.send(replyPacket,source);

            dbg(NEIGHBOR_CHANNEL,
                "Node %d replied to neighbor request from %d seq %d\n",
                TOS_NODE_ID,
                source,
                msg.seq);
        }


        //We received a reply from a neighbor
        else if (header->type == ND_REPLY) {

            index = findNeighbor(source);


            //This is a new neighbor
            if (index < 0) {

                index = findFreeSlot();


                //No room in the table
                if (index < 0) {

                    dbg(NEIGHBOR_CHANNEL,
                        "Node %d neighbor table full; ignoring %d\n",
                        TOS_NODE_ID,
                        source);

                    return;
                }


                //Add the new neighbor
                neighborStats[index].used = TRUE;

                neighborTable[index].nodeID = source;

                neighborStats[index].sent = header->seq;
                neighborStats[index].received = 1;
                neighborStats[index].lastSeq = header->seq;


                //Discovery requests before this reply were missed
                if (header->seq > 1) {

                    neighborStats[index].consecutiveMisses = header->seq - 1;

                } else {

                    neighborStats[index].consecutiveMisses = 0;
                }


                neighborTable[index].active = neighborStats[index].consecutiveMisses < MAX_MISSED;

                updateQuality(index);
            }


            //This is an existing neighbor
            else {

                //Ignore an old or duplicate reply
                if (header->seq <= neighborStats[index].lastSeq) {
                    return;
                }


                //Check how many discovery packetswere missed
                if (header->seq >
                    neighborStats[index].lastSeq + 1) {

                    uint16_t missed;

                    missed = header->seq - neighborStats[index].lastSeq - 1;


                    if (missed >= MAX_MISSED) {

                        neighborTable[index].active = FALSE;

                        neighborStats[index].consecutiveMisses = MAX_MISSED;

                    } else {

                        neighborStats[index].consecutiveMisses = missed;
                    }

                } else {

                    //We received the next expected reply
                    neighborStats[index].consecutiveMisses = 0;
                }


                neighborStats[index].received++;
                neighborStats[index].lastSeq = header->seq;

                //The neighbor is reachable again
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


    //print the current neighbor table
     
    command void NDiscovery.printNeighbors(){
        uint8_t i;

        dbg(NEIGHBOR_CHANNEL,"Node %d neighbors:\n",TOS_NODE_ID);

        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used) {

                dbg(NEIGHBOR_CHANNEL,
                    "Neighbor %d: quality=%d%% active=%d\n",
                    neighborTable[i].nodeID,
                    neighborTable[i].quality,
                    neighborTable[i].active);
            }
        }
    }


    //check if a node is currently our neighbor
    command bool NDiscovery.isCurrentNeighbor(uint16_t nodeID)
    {
        int8_t index;

        index = findNeighbor(nodeID);

        if (index < 0) {
            return FALSE;
        }

        return neighborTable[index].active;
    }


    //Return the number of active neighbors
    command uint8_t NDiscovery.getNeighborCount()
    {
        uint8_t i;
        uint8_t count = 0;

        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used && neighborTable[i].active) {

                count++;
            }
        }

        return count;
    }


    //Get an active neighbor by its position in the active-neighbor list
    command bool NDiscovery.getNeighbor(uint8_t index,uint16_t *nodeID,uint8_t *quality,bool *active){
        uint8_t i;
        uint8_t current = 0;

        for (i = 0; i < MAX_NEIGHBORS; i++) {

            if (neighborStats[i].used &&
                neighborTable[i].active) {

                if (current == index) {

                    *nodeID = neighborTable[i].nodeID;
                    *quality = neighborTable[i].quality;
                    *active = neighborTable[i].active;

                    return TRUE;
                }

                current++;
            }
        }
        return FALSE;
    }
}