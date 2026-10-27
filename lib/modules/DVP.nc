#include <string.h>
#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

module DVP{provides interface DistanceVector;

uses interface NDiscovery;
uses interface SimpleSend as Sender;
uses interface Timer<TMilli> as periodicTimer;
uses interface Timer<TMilli> as sendTimer;
uses interface Timer<TMilli> as triggerTimer;
uses interface Random;
}

implementation
{

    enum
    {
        DV_INFINITY = 16,
        DV_MAX_ROUTES = 32,
        DV_MAX_PEERS = 8,
        DV_UPDATE_MS = 10000,
        DV_SEND_SPACING_MS = 200,
        DV_EXPIRE_TICKS = 5,
        DV_WITHDRAW_TICKS = 5,
        DV_PAYLOAD_VERSION = 1,
        DV_ENTRY_SIZE = 3,
        DV_PACKET_HEADER = 2,
        DV_ENTRIES_PER_PACKET = (PACKET_MAX_PAYLOAD_SIZE - DV_PACKET_HEADER) / DV_ENTRY_SIZE
    };

    // Information stored for each known destination
    typedef struct
    {
        bool used;
        uint16_t dest;
        uint8_t cost;
        uint16_t nextHop;
        uint16_t withdrawUntil;
    } DVRoute;

    // Last advertised cost for each destination from a neighbor
    typedef struct
    {
        bool used;
        uint16_t node;
        uint8_t cost[DV_MAX_ROUTES];
        uint16_t seen[DV_MAX_ROUTES];
    } DVPeer;

    DVRoute routes[DV_MAX_ROUTES];
    DVPeer peers[DV_MAX_PEERS];

    uint16_t ticks = 1;
    uint16_t sequence = 0;

    bool started = FALSE;
    bool advertising = FALSE;
    bool pendingRound = FALSE;

    uint8_t sendPeer = 0;
    uint8_t sendSlot = 0;

    task void recalculateTask();
    void requestUpdate();

    // Find an existing destination in the routing table
    int8_t findRoute(uint16_t destination)
    {
        uint8_t i;

        for (i = 0; i < DV_MAX_ROUTES; i++)
        {
            if (routes[i].used && routes[i].dest == destination)
            {
                return i;
            }
        }

        return -1;
    }

    // Create an entry for a destination if it does not exist
    int8_t ensureRoute(uint16_t destination)
    {
        int8_t index;
        uint8_t i;
        uint8_t j;

        if (destination == 0 || destination > 255)
        {
            return -1;
        }

        index = findRoute(destination);
        if (index >= 0)
        {
            return index;
        }

        for (i = 0; i < DV_MAX_ROUTES; i++)
        {
            if (!routes[i].used)
            {
                routes[i].used = TRUE;
                routes[i].dest = destination;
                routes[i].cost = DV_INFINITY;
                routes[i].nextHop = 0;
                routes[i].withdrawUntil = 0;

                for (j = 0; j < DV_MAX_PEERS; j++)
                {
                    peers[j].cost[i] = DV_INFINITY;
                    peers[j].seen[i] = 0;
                }

                return i;
            }
        }

        dbg(ROUTING_CHANNEL,
            "Node %d: DV table full, cannot learn %d\n",
            TOS_NODE_ID, destination);

        return -1;
    }

    // Find a neighbor in the advertised-vector cache
    int8_t findPeer(uint16_t nodeID)
    {
        uint8_t i;

        for (i = 0; i < DV_MAX_PEERS; i++)
        {
            if (peers[i].used && peers[i].node == nodeID)
            {
                return i;
            }
        }

        return -1;
    }

    // Allocate storage for a neighbor's distance vector
    int8_t ensurePeer(uint16_t nodeID)
    {
        int8_t index;
        uint8_t i;
        uint8_t j;

        index = findPeer(nodeID);
        if (index >= 0)
        {
            return index;
        }

        for (i = 0; i < DV_MAX_PEERS; i++)
        {
            if (!peers[i].used)
            {
                peers[i].used = TRUE;
                peers[i].node = nodeID;

                for (j = 0; j < DV_MAX_ROUTES; j++)
                {
                    peers[i].cost[j] = DV_INFINITY;
                    peers[i].seen[j] = 0;
                }

                return i;
            }
        }

        dbg(ROUTING_CHANNEL,
            "Node %d: DV peer cache full, cannot cache %d\n",
            TOS_NODE_ID, nodeID);

        return -1;
    }

    // Remove cached costs when a neighbor is no longer active
    void forgetPeer(uint8_t peerIndex)
    {
        uint8_t i;

        peers[peerIndex].used = FALSE;

        for (i = 0; i < DV_MAX_ROUTES; i++)
        {
            peers[peerIndex].cost[i] = DV_INFINITY;
            peers[peerIndex].seen[i] = 0;
        }
    }

    // Choose the lowest-cost route using neighbors' advertised distances
    bool recompute()
    {
        uint8_t routeIndex;
        uint8_t peerIndex;
        bool changed = FALSE;

        for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
        {
            uint8_t best = DV_INFINITY;
            uint16_t next = 0;
            uint16_t destination;
            uint8_t previous;
            uint16_t oldNext;

            if (!routes[routeIndex].used)
            {
                continue;
            }

            destination = routes[routeIndex].dest;
            previous = routes[routeIndex].cost;
            oldNext = routes[routeIndex].nextHop;

            if (destination == TOS_NODE_ID)
            {
                best = 0;
            }
            else
            {
                // A direct active neighbor has cost 1
                if (call NDiscovery.isCurrentNeighbor(destination))
                {
                    best = 1;
                    next = destination;
                }

                for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
                {
                    uint8_t candidate;

                    if (!peers[peerIndex].used ||
                        !call NDiscovery.isCurrentNeighbor(peers[peerIndex].node))
                    {
                        continue;
                    }

                    if (peers[peerIndex].seen[routeIndex] == 0 ||
                        (uint16_t)(ticks - peers[peerIndex].seen[routeIndex]) >= DV_EXPIRE_TICKS)
                    {
                        continue;
                    }

                    if (peers[peerIndex].cost[routeIndex] >= DV_INFINITY)
                    {
                        continue;
                    }

                    candidate = peers[peerIndex].cost[routeIndex] + 1;
                    if (candidate >= DV_INFINITY)
                    {
                        continue;
                    }

                    // Keep the current next hop when equal-cost paths exist
                    if (candidate < best ||
                        (candidate == best && peers[peerIndex].node == oldNext))
                    {
                        best = candidate;
                        next = peers[peerIndex].node;
                    }
                }
            }

            if (best != previous || next != oldNext)
            {
                routes[routeIndex].cost = best;
                routes[routeIndex].nextHop = next;

                if (best == DV_INFINITY && previous != DV_INFINITY)
                {
                    routes[routeIndex].withdrawUntil = ticks + DV_WITHDRAW_TICKS;
                }
                else if (best != DV_INFINITY)
                {
                    routes[routeIndex].withdrawUntil = 0;
                }

                changed = TRUE;

                dbg(ROUTING_CHANNEL,
                    "Node %d: DV route dest %d next %d cost %d\n",
                    TOS_NODE_ID, destination, next, best);
            }
        }

        return changed;
    }

    // Schedule a short randomized triggered advertisement
    void requestUpdate()
    {
        if (!started)
        {
            return;
        }

        if (!call triggerTimer.isRunning())
        {
            call triggerTimer.startOneShot(400 + (call Random.rand16() % 400));
        }
    }

    // Update routes outside the receive and neighbor-change handlers
    task void recalculateTask()
    {
        uint8_t peerIndex;

        for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
        {
            if (peers[peerIndex].used &&
                !call NDiscovery.isCurrentNeighbor(peers[peerIndex].node))
            {
                forgetPeer(peerIndex);
            }
        }

        if (recompute())
        {
            signal DistanceVector.routeChanged();
            requestUpdate();
        }
    }

    // Begin sending a new vector to every active neighbor
    void beginRound()
    {
        if (advertising)
        {
            pendingRound = TRUE;
            return;
        }

        advertising = TRUE;
        sendPeer = 0;
        sendSlot = 0;

        call sendTimer.startOneShot(1 + (call Random.rand16() % 200));
    }

    command void DistanceVector.start()
    {
        uint8_t routeIndex;
        uint8_t peerIndex;

        started = FALSE;
        advertising = FALSE;
        pendingRound = FALSE;
        ticks = 1;
        sequence = 0;

        for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
        {
            routes[routeIndex].used = FALSE;
        }

        for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
        {
            peers[peerIndex].used = FALSE;
        }

        ensureRoute(TOS_NODE_ID);
        recompute();

        started = TRUE;
        call periodicTimer.startPeriodic(DV_UPDATE_MS);
        requestUpdate();
    }

    event void NDiscovery.neighborChanged()
    {
        uint8_t i;
        uint8_t count;
        uint16_t nodeID;
        uint8_t quality;
        bool active;

        count = call NDiscovery.getNeighborCount();

        for (i = 0; i < count; i++)
        {
            if (call NDiscovery.getNeighbor(i, &nodeID, &quality, &active) && active)
            {
                ensureRoute(nodeID);
                ensurePeer(nodeID);
            }
        }

        post recalculateTask();
    }

    event void periodicTimer.fired()
    {
        uint8_t routeIndex;
        uint8_t peerIndex;

        ticks++;

        // Expire old neighbor advertisements
        for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
        {
            if (!peers[peerIndex].used)
            {
                continue;
            }

            if (!call NDiscovery.isCurrentNeighbor(peers[peerIndex].node))
            {
                forgetPeer(peerIndex);
                continue;
            }

            for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
            {
                if (peers[peerIndex].seen[routeIndex] &&
                    (uint16_t)(ticks - peers[peerIndex].seen[routeIndex]) >= DV_EXPIRE_TICKS)
                {
                    peers[peerIndex].cost[routeIndex] = DV_INFINITY;
                    peers[peerIndex].seen[routeIndex] = 0;
                }
            }
        }

        post recalculateTask();

        // Reclaim unreachable destinations after the withdrawal interval
        for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
        {
            if (routes[routeIndex].used &&
                routes[routeIndex].cost == DV_INFINITY &&
                routes[routeIndex].withdrawUntil &&
                (int16_t)(ticks - routes[routeIndex].withdrawUntil) >= 0)
            {
                routes[routeIndex].used = FALSE;

                for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
                {
                    peers[peerIndex].cost[routeIndex] = DV_INFINITY;
                    peers[peerIndex].seen[routeIndex] = 0;
                }
            }
        }

        beginRound();
    }

    event void triggerTimer.fired()
    {
        beginRound();
    }

    // Send a bounded portion of the vector to one neighbor at a time
    event void sendTimer.fired()
    {
        pack msg;
        uint8_t entryCount = 0;
        uint8_t routeIndex;
        uint16_t recipient = 0;
        uint8_t quality;
        bool active;
        uint8_t count;

        count = call NDiscovery.getNeighborCount();

        if (!advertising)
        {
            return;
        }

        if (sendPeer >= count)
        {
            advertising = FALSE;

            if (pendingRound)
            {
                pendingRound = FALSE;
                beginRound();
            }
            return;
        }

        if (!call NDiscovery.getNeighbor(sendPeer, &recipient, &quality, &active) || !active)
        {
            sendPeer++;
            sendSlot = 0;
            call sendTimer.startOneShot(DV_SEND_SPACING_MS);
            return;
        }

        memset(&msg, 0, sizeof(msg));
        msg.src = TOS_NODE_ID;
        msg.dest = recipient;
        msg.seq = ++sequence;
        msg.TTL = 1;
        msg.protocol = PROTOCOL_DV;
        msg.payload[0] = DV_PAYLOAD_VERSION;
        msg.payload[1] = 0;

        routeIndex = sendSlot;

        while (routeIndex < DV_MAX_ROUTES && entryCount < DV_ENTRIES_PER_PACKET)
        {
            if (routes[routeIndex].used)
            {
                uint16_t destination = routes[routeIndex].dest;
                uint8_t cost = routes[routeIndex].cost;
                uint8_t offset = DV_PACKET_HEADER + entryCount * DV_ENTRY_SIZE;

                // Poison the route when advertising to the selected next hop
                if (destination != TOS_NODE_ID && routes[routeIndex].nextHop == recipient)
                {
                    cost = DV_INFINITY;
                }

                msg.payload[offset] = (uint8_t)(destination & 0xff);
                msg.payload[offset + 1] = (uint8_t)(destination >> 8);
                msg.payload[offset + 2] = cost;

                dbg(ROUTING_CHANNEL,
                    "DV ADV from %d to %d dest %d cost %d\n",
                    TOS_NODE_ID, recipient, destination, cost);

                entryCount++;
            }
            routeIndex++;
        }

        sendSlot = routeIndex;
        msg.payload[1] = entryCount;

        if (entryCount)
        {
            if (call Sender.send(msg, recipient) != SUCCESS)
            {
                dbg(ROUTING_CHANNEL,
                    "Node %d: DV advertisement queue full to %d\n",
                    TOS_NODE_ID, recipient);
            }
        }

        if (sendSlot >= DV_MAX_ROUTES)
        {
            sendSlot = 0;
            sendPeer++;
        }

        call sendTimer.startOneShot(DV_SEND_SPACING_MS);
    }

    // Process a one-hop advertisement without flooding or forwarding it
    command void DistanceVector.receive(pack msg, uint16_t linkSource)
    {
        uint8_t count;
        uint8_t i;
        int8_t peerIndex;

        if (!started || msg.protocol != PROTOCOL_DV)
        {
            return;
        }

        if (linkSource == TOS_NODE_ID || !call NDiscovery.isCurrentNeighbor(linkSource))
        {
            return;
        }

        if (msg.dest != TOS_NODE_ID || msg.TTL != 1)
        {
            return;
        }

        if (msg.payload[0] != DV_PAYLOAD_VERSION)
        {
            return;
        }

        count = msg.payload[1];
        if (count > DV_ENTRIES_PER_PACKET)
        {
            return;
        }

        peerIndex = ensurePeer(linkSource);
        if (peerIndex < 0)
        {
            return;
        }

        for (i = 0; i < count; i++)
        {
            uint8_t offset = DV_PACKET_HEADER + i * DV_ENTRY_SIZE;
            uint16_t destination = (uint16_t)msg.payload[offset] |
                                   ((uint16_t)msg.payload[offset + 1] << 8);
            uint8_t cost = msg.payload[offset + 2];
            int8_t routeIndex;

            if (destination == 0 || destination > 255 ||
                cost > DV_INFINITY || destination == TOS_NODE_ID)
            {
                continue;
            }

            routeIndex = findRoute(destination);
            if (routeIndex < 0 && cost == DV_INFINITY)
            {
                continue;
            }

            if (routeIndex < 0)
            {
                routeIndex = ensureRoute(destination);
            }

            if (routeIndex < 0)
            {
                continue;
            }

            peers[peerIndex].cost[routeIndex] = cost;
            peers[peerIndex].seen[routeIndex] = ticks;
        }

        post recalculateTask();
    }

    command uint16_t DistanceVector.getNextHop(uint16_t destination)
    {
        int8_t routeIndex;

        routeIndex = findRoute(destination);
        if (routeIndex < 0 || routes[routeIndex].cost >= DV_INFINITY)
        {
            return 0;
        }

        if (!call NDiscovery.isCurrentNeighbor(routes[routeIndex].nextHop))
        {
            return 0;
        }

        return routes[routeIndex].nextHop;
    }

    command uint8_t DistanceVector.getCost(uint16_t destination)
    {
        int8_t routeIndex;

        routeIndex = findRoute(destination);
        if (routeIndex < 0)
        {
            return DV_INFINITY;
        }

        return routes[routeIndex].cost;
    }

    command void DistanceVector.printRoutingTable()
    {
        uint8_t routeIndex;

        dbg(ROUTING_CHANNEL, "Node %d: DV Routing Table\n", TOS_NODE_ID);
        dbg(ROUTING_CHANNEL, "Dest | NextHop | Cost | State\n");

        for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
        {
            if (!routes[routeIndex].used)
            {
                continue;
            }

            if (routes[routeIndex].cost == DV_INFINITY)
            {
                dbg(ROUTING_CHANNEL,
                    "%d | - | INF | UNREACHABLE\n",
                    routes[routeIndex].dest);
            }
            else
            {
                dbg(ROUTING_CHANNEL,
                    "%d | %d | %d | VALID\n",
                    routes[routeIndex].dest,
                    routes[routeIndex].nextHop,
                    routes[routeIndex].cost);
            }
        }
    }
}
