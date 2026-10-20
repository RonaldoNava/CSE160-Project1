#include <Timer.h>

#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"

module NDiscoveryP{uses interface Timer<TMilli> as periodicTimer;
uses interface SimpleSend as Sender;

provides interface NDiscovery;
}

implementation
{

    enum
    {
        MAX_NEIGHBORS = 32,
        MAX_MISSED = 5,
        DISCOVERY_PERIOD = 5000
    };

    // node info stored in the neighbor table
    typedef struct
    {
        uint16_t nodeID;
        uint8_t quality;
        bool active;
    } Neighbor;

    // info used to update node info
    typedef struct
    {
        bool used;
        uint16_t sent;
        uint16_t received;
        uint16_t lastSeq;
        uint8_t consecutiveMisses;
    } NeighborStats;

    Neighbor neighborTable[MAX_NEIGHBORS];
    NeighborStats neighborStats[MAX_NEIGHBORS];

    uint16_t discoverySeq = 0;
    // tells tinyos that this task exists and can be posted to the scheduler
    task void sendDiscoveryTask();

    // find a neighbor in the table
    int8_t findNeighbor(uint16_t nodeID)
    {
        uint8_t i;

        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (neighborStats[i].used && neighborTable[i].nodeID == nodeID)
            {

                return i;
            }
        }

        return -1;
    }

    // find an empty spot in the table
    int8_t findFreeSlot()
    {
        uint8_t i;

        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (!neighborStats[i].used)
            {
                return i;
            }
        }
        return -1;
    }

    // calculate percentage of discovery packets received from a neighbor
    void updateQuality(uint8_t index)
    {
        if (neighborStats[index].sent == 0)
        {
            neighborTable[index].quality = 0;
        }
        else
        {
            neighborTable[index].quality =
                (uint8_t)((uint32_t)neighborStats[index].received * 100 / neighborStats[index].sent);
        }
    }

    // start neighbor discovery
    command void NDiscovery.start()
    {
        uint8_t i;

        discoverySeq = 0;
        // init neighbor table and stats
        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

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

        // dbg(NEIGHBOR_CHANNEL, "Node %d: Neighbor discovery started\n", TOS_NODE_ID);
    }

    // send a discovery packet every 5 seconds
    event void periodicTimer.fired()
    {
        post sendDiscoveryTask(); // let's the scheduler know that this task is ready to run
    }

    // send a neighbor discovery request
    task void sendDiscoveryTask()
    {
        pack discoveryPacket;
        NeighborDiscoveryHeader *header;

        uint8_t i;
        bool changed = false;

        discoverySeq++;

        // set up packet
        discoveryPacket.src = TOS_NODE_ID;
        discoveryPacket.dest = AM_BROADCAST_ADDR;
        discoveryPacket.seq = discoverySeq;
        discoveryPacket.TTL = 1;
        discoveryPacket.protocol = PROTOCOL_NEIGHBOR;

        // treat the payload area as a neighbor discovery header
        header = (NeighborDiscoveryHeader *)discoveryPacket.payload;

        header->type = ND_REQUEST;
        header->seq = discoverySeq;

        // count this request for every neighbor that we already know about
        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (neighborStats[i].used)
            {

                neighborStats[i].sent++;

                // check if this neighbor has missed too many discovery replies
                if (discoverySeq > neighborStats[i].lastSeq)
                {

                    uint16_t missed;

                    missed =
                        discoverySeq - neighborStats[i].lastSeq - 1;

                    if (missed >= MAX_MISSED)
                    {

                        neighborStats[i].consecutiveMisses = MAX_MISSED;

                        if (neighborTable[i].active)
                        {
                            changed = true
                        }
                        neighborTable[i].active = FALSE;
                    }
                }

                updateQuality(i);
            }
        }

        // send the discovery request
        call Sender.send(discoveryPacket, AM_BROADCAST_ADDR);

        // dbg(NEIGHBOR_CHANNEL, "Node %d sent neighbor discovery seq %d\n", TOS_NODE_ID, discoverySeq);
    }

    // receive a neighbor discovery packet
    command void NDiscovery.receive(pack msg, uint16_t source)
    {
        NeighborDiscoveryHeader *header;
        pack replyPacket;

        int8_t index;

        // ignore packets from ourselves
        if (source == TOS_NODE_ID)
        {
            return;
        }

        header = (NeighborDiscoveryHeader *)msg.payload;

        // A neighbor is asking us to reply
        if (header->type == ND_REQUEST)
        {

            replyPacket.src = TOS_NODE_ID;
            replyPacket.dest = source;
            replyPacket.seq = header->seq;
            replyPacket.TTL = 1;
            replyPacket.protocol = PROTOCOL_NEIGHBOR;

            header = (NeighborDiscoveryHeader *)replyPacket.payload;

            header->type = ND_REPLY;
            header->seq = msg.seq;

            call Sender.send(replyPacket, source);

            /*
            dbg(NEIGHBOR_CHANNEL,
                "Node %d replied to neighbor request from %d seq %d\n",
                TOS_NODE_ID,
                source,
                msg.seq);
                */
        }

        // we received a reply from a neighbor
        else if (header->type == ND_REPLY)
        {

            index = findNeighbor(source);

            // this is a new neighbor
            if (index < 0)
            {

                index = findFreeSlot();

                // no room in the table
                if (index < 0)
                {
                    /*
                    dbg(NEIGHBOR_CHANNEL,
                        "Node %d neighbor table full; ignoring %d\n",
                        TOS_NODE_ID,
                        source);
                    */
                    return;
                }

                // add the new neighbor
                neighborStats[index].used = TRUE;

                neighborTable[index].nodeID = source;

                neighborStats[index].sent = header->seq;
                neighborStats[index].received = 1;
                neighborStats[index].lastSeq = header->seq;

                // discovery requests before this reply were missed
                if (header->seq > 1)
                {
                    neighborStats[index].consecutiveMisses = header->seq - 1;
                }
                else
                {
                    neighborStats[index].consecutiveMisses = 0;
                }
                neighborTable[index].active = neighborStats[index].consecutiveMisses < MAX_MISSED;

                updateQuality(index);
            }

            // this is an existing neighbor
            else
            {
                // ignore an old or duplicate reply
                if (header->seq <= neighborStats[index].lastSeq)
                {
                    return;
                }

                // check how many discovery packetswere missed
                if (header->seq > neighborStats[index].lastSeq + 1)
                {

                    uint16_t missed;

                    missed = header->seq - neighborStats[index].lastSeq - 1;

                    if (missed >= MAX_MISSED)
                    {

                        neighborTable[index].active = FALSE;

                        neighborStats[index].consecutiveMisses = MAX_MISSED;
                    }
                    else
                    {

                        neighborStats[index].consecutiveMisses = missed;
                    }
                }
                else
                {

                    // we received the next expected reply
                    neighborStats[index].consecutiveMisses = 0;
                }

                neighborStats[index].received++;
                neighborStats[index].lastSeq = header->seq;

                // the neighbor is reachable again
                neighborTable[index].active = TRUE;

                updateQuality(index);
            }

            /*
            dbg(NEIGHBOR_CHANNEL,
                "Node %d received neighbor reply from %d seq %d quality %d%% active %d\n",
                TOS_NODE_ID,
                source,
                header->seq,
                neighborTable[index].quality,
                neighborTable[index].active);
                */
        }
    }

    // print the current neighbor table

    command void NDiscovery.printNeighbors()
    {
        uint8_t i;

        dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID);

        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (neighborStats[i].used)
            {

                dbg(NEIGHBOR_CHANNEL,
                    "Neighbor %d: quality=%d%% active=%d\n",
                    neighborTable[i].nodeID,
                    neighborTable[i].quality,
                    neighborTable[i].active);
            }
        }
    }

    // check if a node is currently our neighbor
    command bool NDiscovery.isCurrentNeighbor(uint16_t nodeID)
    {
        int8_t index;

        index = findNeighbor(nodeID);

        if (index < 0)
        {
            return FALSE;
        }

        return neighborTable[index].active;
    }

    // return the number of active neighbors
    command uint8_t NDiscovery.getNeighborCount()
    {
        uint8_t i;
        uint8_t count = 0;

        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (neighborStats[i].used && neighborTable[i].active)
            {

                count++;
            }
        }

        return count;
    }

    // get an active neighbor by its position in the active-neighbor list
    command bool NDiscovery.getNeighbor(uint8_t index, uint16_t *nodeID, uint8_t *quality, bool *active)
    {
        uint8_t i;
        uint8_t current = 0;

        for (i = 0; i < MAX_NEIGHBORS; i++)
        {

            if (neighborStats[i].used && neighborTable[i].active)
            {

                if (current == index)
                {

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