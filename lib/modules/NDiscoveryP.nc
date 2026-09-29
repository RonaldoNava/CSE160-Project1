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
        MAX_NEIGHBORS = 10
    };
    typedef struct
    {
        uint16_t nodeID;
    } Neighbor;

    Neighbor neighborTable[MAX_NEIGHBORS];
    uint8_t neighborCount = 0;
    uint16_t discoverySeq = 0;

    command void NDiscovery.start()
    {
        neighborCount = 0;
        discoverySeq = 0;

        call periodicTimer.startPeriodic(5000);

        dbg(NEIGHBOR_CHANNEL, "Node %d: Neighbor discovery started\n", TOS_NODE_ID);
    }

    event void periodicTimer.fired()
    {
        pack discoveryPacket;

        discoverySeq++;

        discoveryPacket.src = TOS_NODE_ID;            // currentnode is the source
        discoveryPacket.dest = AM_BROADCAST_ADDR;     // nodes within range will receive the packet (TTL)
        discoveryPacket.seq = discoverySeq;           // for every discovery announcment
        discoveryPacket.TTL = 1;                      // only 1 hop (neighbor)
        discoveryPacket.protocol = PROTOCOL_NEIGHBOR; // reuse packet structure

        call Sender.send(discoveryPacket, AM_BROADCAST_ADDR);

        dbg(NEIGHBOR_CHANNEL, "Node %d sent neighbor discovery seq %d\n", TOS_NODE_ID, discoverySeq);
    }

    command void NDiscovery.printNeighbors()
    {
        uint8_t i;

        dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID);

        for (i = 0; i < neighborCount; i++)
        {
            dbg(NEIGHBOR_CHANNEL, "Neighbor ID: %d\n", neighborTable[i].nodeID);
        }
    }

    command bool NDiscovery.isCurrentNeighbor(uint16_t nodeID)
    {

        uint8_t i;

        for (i = 0; i < neighborCount; i++)
        {

            if (neighborTable[i].nodeID == nodeID)
            {
                return TRUE;
            }
        }

        return FALSE;
    }

    command void NDiscovery.recordNeighbor(uint16_t nodeID)
    {
        uint8_t i;

        // dont add ourselves
        if (nodeID == TOS_NODE_ID)
        {
            return;
        }

        // check if the neighbor already exists
        for (i = 0; i < neighborCount; i++)
        {
            if (neighborTable[i].nodeID == nodeID)
            {
                return;
            }
        }

        // add the neighbor if there is space
        if (neighborCount < MAX_NEIGHBORS)
        {
            neighborTable[neighborCount].nodeID = nodeID;
            neighborCount++;

            dbg(NEIGHBOR_CHANNEL, "Node %d added neighbor %d\n", TOS_NODE_ID, nodeID);
        }
        else
        {
            dbg(NEIGHBOR_CHANNEL, "Node %d: Neighbor table is full\n", TOS_NODE_ID);
        }
    }
}