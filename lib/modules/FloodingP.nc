#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"

module FloodingP{uses interface SimpleSend as Sender;
uses interface NDiscovery;

provides interface Flooding;
}

implementation
{

    enum
    {
        MAX_CACHE_SIZE = 32
    };
    // flooding cache entry
    typedef struct
    {
        bool used;
        uint16_t nodeID;
        uint16_t seq;
    } FloodCacheEntry;

    FloodCacheEntry floodCache[MAX_CACHE_SIZE];

    uint16_t floodSeq = 0;

    // find the cache entry for a node.
    int8_t findCacheEntry(uint16_t nodeID)
    {
        uint8_t i;

        for (i = 0; i < MAX_CACHE_SIZE; i++)
        {
            if (floodCache[i].used &&
                floodCache[i].nodeID == nodeID)
            {

                return i;
            }
        }

        return -1;
    }

    // find an empty space in the cache
    int8_t findFreeCacheSlot()
    {
        uint8_t i;

        for (i = 0; i < MAX_CACHE_SIZE; i++)
        {
            if (!floodCache[i].used)
            {
                return i;
            }
        }

        return -1;
    }

    // begin flooding
    command void Flooding.start()
    {
        uint8_t i;

        floodSeq = 0;

        for (i = 0; i < MAX_CACHE_SIZE; i++)
        {
            floodCache[i].used = FALSE;
            floodCache[i].nodeID = 0;
            floodCache[i].seq = 0;
        }

        // dbg(FLOODING_CHANNEL, "Node %d: flooding started\n", TOS_NODE_ID);
    }

    // start a new flood
    command void Flooding.flood(pack msg)
    {
        pack floodPacket;
        FloodingHeader *header;

        int8_t index;

        uint8_t i;
        uint8_t neighborCount;
        uint16_t neighborID;
        uint8_t quality;
        bool active;

        // give this flood a new sequence number
        floodSeq++;

        // set the link layer info
        floodPacket.src = TOS_NODE_ID;
        floodPacket.dest = msg.dest;
        floodPacket.seq = floodSeq;
        floodPacket.TTL = MAX_TTL;
        floodPacket.protocol = PROTOCOL_FLOODING;

        // set the flooding header
        header = (FloodingHeader *)floodPacket.payload;

        header->src = TOS_NODE_ID;
        header->seq = floodSeq;
        header->TTL = MAX_TTL;
        // carry original application data in the payload
        memcpy(header->payload, msg.payload, FLOODING_MAX_PAYLOAD_SIZE);

        // save our own flood in the cache.
        index = findCacheEntry(TOS_NODE_ID);
        // find an empty slot
        if (index < 0)
        {
            index = findFreeCacheSlot();
        }

        if (index >= 0)
        {
            floodCache[index].used = TRUE;
            floodCache[index].nodeID = TOS_NODE_ID;
            floodCache[index].seq = floodSeq;
        }

        // send the flood to every active neighbor
        neighborCount = call NDiscovery.getNeighborCount();

        for (i = 0; i < neighborCount; i++)
        {

            if (call NDiscovery.getNeighbor(
                    i,
                    &neighborID,
                    &quality,
                    &active))
            {

                if (active)
                {

                    call Sender.send(
                        floodPacket,
                        neighborID);

                    dbg(FLOODING_CHANNEL,
                        "Node %d: sent flood to neighbor %d, seq %d, TTL %d\n",
                        TOS_NODE_ID,
                        neighborID,
                        floodSeq,
                        MAX_TTL);
                }
            }
        }
    }

    // receive a flood from another node
    command void Flooding.receive(pack msg, uint16_t source)
    {
        FloodingHeader *header;
        pack forwardPacket;
        pack appPacket;

        int8_t index;

        uint8_t i;
        uint8_t neighborCount;
        uint16_t neighborID;
        uint8_t quality;
        bool active;

        header = (FloodingHeader *)msg.payload;

        // check the cache using the original flood src
        index = findCacheEntry(header->src);

        // new flood from src
        if (index < 0)
        {

            index = findFreeCacheSlot();

            if (index < 0)
            {
                dbg(FLOODING_CHANNEL, "Node %d: flood cache full\n", TOS_NODE_ID);

                return;
            }

            floodCache[index].used = TRUE;
            floodCache[index].nodeID = header->src;
            floodCache[index].seq = header->seq;
        }

        // ingore duplicate or old floods
        else
        {
            // way to prevent loops
            if (header->seq <= floodCache[index].seq)
            {

                dbg(FLOODING_CHANNEL,
                    "Node %d: duplicate flood from %d seq %d\n",
                    TOS_NODE_ID,
                    header->src,
                    header->seq);

                return; // dont forward it
            }

            floodCache[index].seq = header->seq;
        }

        dbg(FLOODING_CHANNEL,
            "Node %d: received flood from %d to %d, seq %d TTL %d\n",
            TOS_NODE_ID,
            header->src,
            msg.dest,
            header->seq,
            header->TTL);

        // give the application the packet
        appPacket.src = header->src;
        appPacket.dest = msg.dest;
        appPacket.seq = header->seq;
        appPacket.TTL = header->TTL;
        appPacket.protocol = PROTOCOL_FLOODING;
        // copies the appplication data
        memcpy(appPacket.payload, header->payload, FLOODING_MAX_PAYLOAD_SIZE);

        signal Flooding.received(appPacket, header->src);

        // stop if the TTL has reached zero
        if (header->TTL == 0)
        {

            dbg(FLOODING_CHANNEL, "Node %d: flood expired\n", TOS_NODE_ID);

            return;
        }

        // prepare the packet for the next hop
        forwardPacket.src = TOS_NODE_ID;
        forwardPacket.dest = msg.dest;
        forwardPacket.seq = msg.seq;
        forwardPacket.TTL = header->TTL - 1;
        forwardPacket.protocol = PROTOCOL_FLOODING;

        memcpy(forwardPacket.payload, msg.payload, PACKET_MAX_PAYLOAD_SIZE);
        // decrement the TTL in the flooding header
        ((FloodingHeader *)forwardPacket.payload)->TTL = header->TTL - 1;

        // send to every neighbor except the node that sent us the packet
        neighborCount = call NDiscovery.getNeighborCount();

        for (i = 0; i < neighborCount; i++)
        {

            if (call NDiscovery.getNeighbor(i, &neighborID, &quality, &active))
            {

                if (active && neighborID != source)
                {

                    call Sender.send(forwardPacket, neighborID);

                    dbg(FLOODING_CHANNEL,
                        "Node %d: forwarded flood to neighbor %d, from %d, seq %d, TTL %d\n",
                        TOS_NODE_ID,
                        neighborID,
                        source,
                        header->seq,
                        header->TTL - 1);
                }
            }
        }
    }
}