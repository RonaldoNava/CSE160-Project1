#include <string.h>
#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"
// uses neigbor discovery to determine which nodes are directly connected
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
    // cost of 16 means the destination is unreachable
    // each packet can hold only part of the routing table
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

    // information stored for each known destination
    typedef struct
    {
        bool used;
        uint16_t dest;
        uint8_t cost;
        uint16_t nextHop;
        uint16_t withdrawUntil;
    } DVRoute;

    // last advertised cost for each destination from a neighbor
    typedef struct
    {
        bool used;
        uint16_t node;
        uint8_t cost[DV_MAX_ROUTES];
        uint16_t seen[DV_MAX_ROUTES];
    } DVPeer;
    // routing table holds the best route to each destination
    DVRoute routes[DV_MAX_ROUTES];
    DVPeer peers[DV_MAX_PEERS];
    // save costs advertised by each neighbor
    // ticks counts periodic update rounds, not individual packets
    uint16_t ticks = 1;
    uint16_t sequence = 0;
    // add flags to help control when DV starts
    bool started = FALSE;
    bool advertising = FALSE;
    bool pendingRound = FALSE;
    // remember which neighbor and which slot of the routing table is being sent
    uint8_t sendPeer = 0;
    uint8_t sendSlot = 0;

    task void updateRoutesTask();
    void scheduleRouteUpdate();

    // look through the routing table for a destination, return the index or -1 if not found
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

    // create an entry for a destination if it does not exist
    int8_t addRouteIfMissing(uint16_t destination)
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

    // find the saved advertisement for a specific neighbor
    int8_t findNeighborInfo(uint16_t nodeID)
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

    // give a neighbor space in our cache so we can remember its advertised costs
    int8_t addNeighborIfMissing(uint16_t nodeID)
    {
        int8_t index;
        uint8_t i;
        uint8_t j;

        index = findNeighborInfo(nodeID);
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

    // if a neighbor is no longer active, clear the routes it told us about
    void removeNeighborInfo(uint8_t peerIndex)
    {
        uint8_t i;

        peers[peerIndex].used = FALSE;

        for (i = 0; i < DV_MAX_ROUTES; i++)
        {
            peers[peerIndex].cost[i] = DV_INFINITY;
            peers[peerIndex].seen[i] = 0;
        }
    }

    // calculate my best routes using Bellman-Ford
    // for each destination, compare direct links and the costs with my neighbors sent
    bool updateRoutingTable()
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
            // a node is zero hops away from itself
            if (destination == TOS_NODE_ID)
            {
                best = 0;
            }
            else
            {
                // a direct active neighbor has cost 1
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
                    // ignore a neighbor's route if we haven't hear about it recently or if it is unreachable
                    if (peers[peerIndex].seen[routeIndex] == 0 ||
                        (uint16_t)(ticks - peers[peerIndex].seen[routeIndex]) >= DV_EXPIRE_TICKS)
                    {
                        continue;
                    }
                    // a cost of 16 meas that neighbor does not have a usable path
                    if (peers[peerIndex].cost[routeIndex] >= DV_INFINITY)
                    {
                        continue;
                    }

                    candidate = peers[peerIndex].cost[routeIndex] + 1;
                    if (candidate >= DV_INFINITY)
                    {
                        continue;
                    }
                    // choose lowest cost. if cost match, try to keep our old next hop.
                    // helps stop route from switching back and forth for no reason
                    if (candidate < best ||
                        (candidate == best && peers[peerIndex].node == oldNext))
                    {
                        best = candidate;
                        next = peers[peerIndex].node;
                    }
                }
            }
            // only update routing table if cost or next hop changed
            if (best != previous || next != oldNext)
            {
                routes[routeIndex].cost = best;
                routes[routeIndex].nextHop = next;
                // if working route becomes unreachable, keep it temporarily
                // gives us time to tell neighbors that its cost is now 16
                if (best == DV_INFINITY && previous != DV_INFINITY)
                {
                    routes[routeIndex].withdrawUntil = ticks + DV_WITHDRAW_TICKS;
                }
                // if we find a working route again, cancel withdrawal timer
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

    // when a route changes, schedule another advertisement right after
    // small delay helps keep nodes from transmitting at the same time
    void scheduleRouteUpdate()
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

    // run the route calculation as a task instead of directly in receive events
    // first remove inactive neighbors, then check if best routes changed
    task void updateRoutesTask()
    {
        uint8_t peerIndex;

        for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
        {
            if (peers[peerIndex].used &&
                !call NDiscovery.isCurrentNeighbor(peers[peerIndex].node))
            {
                removeNeighborInfo(peerIndex);
            }
        }

        if (updateRoutingTable())
        {
            signal DistanceVector.routeChanged();
            scheduleRouteUpdate();
        }
    }

    // start sending routing updates to every active neighbor
    // if a round is already being sent, remember to send another after
    void startUpdateRound()
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
    // reset routing info when dv starts
    // add a route with zero cost to our own node and start periodic timer
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

        addRouteIfMissing(TOS_NODE_ID);
        updateRoutingTable();

        started = TRUE;
        call periodicTimer.startPeriodic(DV_UPDATE_MS);
        scheduleRouteUpdate();
    }
    // neighbor discover tells us when the neighbor list changes
    // save active neighbors and recalculate routes
    event void NDiscovery.neighborChanged()
    {
        uint8_t i;
        uint8_t count;
        uint16_t nodeID;
        uint8_t quality;
        bool active;

        count = call NDiscovery.getNeighborCount();
        // go through current neighbor list and save active neighbors
        for (i = 0; i < count; i++)
        {
            if (call NDiscovery.getNeighbor(i, &nodeID, &quality, &active) && active)
            {
                addRouteIfMissing(nodeID);
                addNeighborIfMissing(nodeID);
            }
        }

        post updateRoutesTask();
    }
    // every 10 secs, check old advertisements and start another update round
    event void periodicTimer.fired()
    {
        uint8_t routeIndex;
        uint8_t peerIndex;

        ticks++;

        // expire old neighbor advertisements
        for (peerIndex = 0; peerIndex < DV_MAX_PEERS; peerIndex++)
        {
            if (!peers[peerIndex].used)
            {
                continue;
            }

            if (!call NDiscovery.isCurrentNeighbor(peers[peerIndex].node))
            {
                removeNeighborInfo(peerIndex);
                continue;
            }

            for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
            {
                // if a nighbor has not refreshed this destination for five rounds, expire it
                // also works when the neighbor itself is still active
                if (peers[peerIndex].seen[routeIndex] &&
                    (uint16_t)(ticks - peers[peerIndex].seen[routeIndex]) >= DV_EXPIRE_TICKS)
                {
                    peers[peerIndex].cost[routeIndex] = DV_INFINITY;
                    peers[peerIndex].seen[routeIndex] = 0;
                }
            }
        }

        post updateRoutesTask();

        for (routeIndex = 0; routeIndex < DV_MAX_ROUTES; routeIndex++)
        {
            // renove routes that have stayed unreachable past the withdrawal deadline
            // clear matching cache values so the slot can be used again
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

        startUpdateRound();
    }
    // send an update soon after a change instead of waiting for the next 10 seconds
    event void triggerTimer.fired()
    {
        startUpdateRound();
    }

    // send one part of the routing table to one neighbor at a time
    // the short spacing between sends helps avoid too many packets at once
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
        // when all neighbors have been handled, finish this update round
        if (sendPeer >= count)
        {
            advertising = FALSE;

            if (pendingRound)
            {
                pendingRound = FALSE;
                startUpdateRound();
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
        // build a one-hop dv control packet addressed to this neighbor
        // dv updates aren't forwarded across the network like flooded packets
        memset(&msg, 0, sizeof(msg));
        msg.src = TOS_NODE_ID;
        msg.dest = recipient;
        msg.seq = ++sequence;
        msg.TTL = 1;
        msg.protocol = PROTOCOL_DV;
        msg.payload[0] = DV_PAYLOAD_VERSION;
        msg.payload[1] = 0;

        routeIndex = sendSlot;
        // put as many route entries as will fit into this advertisement
        // if the table is larger, the next timer event sends another packet
        while (routeIndex < DV_MAX_ROUTES && entryCount < DV_ENTRIES_PER_PACKET)
        {
            if (routes[routeIndex].used)
            {
                uint16_t destination = routes[routeIndex].dest;
                uint8_t cost = routes[routeIndex].cost;
                uint8_t offset = DV_PACKET_HEADER + entryCount * DV_ENTRY_SIZE;

                // Poison reverse: if this neighbor is our next hop for the route
                // advertise cost 16 back to it so it does not try to route through us
                if (destination != TOS_NODE_ID && routes[routeIndex].nextHop == recipient)
                {
                    cost = DV_INFINITY;
                }
                // store the destination ID in two bytes plus its advertised cost
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
        // send the packet only if it contains at least one route entry
        if (entryCount)
        {
            if (call Sender.send(msg, recipient) != SUCCESS)
            {
                dbg(ROUTING_CHANNEL,
                    "Node %d: DV advertisement queue full to %d\n",
                    TOS_NODE_ID, recipient);
            }
        }
        // once this neighbor has received all parts, move to the next neighbor
        if (sendSlot >= DV_MAX_ROUTES)
        {
            sendSlot = 0;
            sendPeer++;
        }

        call sendTimer.startOneShot(DV_SEND_SPACING_MS);
    }

    // handle a dv update sent directly by one of our active neighbors
    // check the packet first, then save only the destination it actually includes
    command void DistanceVector.receive(pack msg, uint16_t linkSource)
    {
        uint8_t count;
        uint8_t i;
        int8_t peerIndex;

        if (!started || msg.protocol != PROTOCOL_DV)
        {
            return;
        }
        // ignor packets from ourselves or nodes that arent active neighbors
        if (linkSource == TOS_NODE_ID || !call NDiscovery.isCurrentNeighbor(linkSource))
        {
            return;
        }
        // a dv update should be addressed to us and sent only over one hop
        if (msg.dest != TOS_NODE_ID || msg.TTL != 1)
        {
            return;
        }
        // make sure we understand the format of this update
        if (msg.payload[0] != DV_PAYLOAD_VERSION)
        {
            return;
        }

        count = msg.payload[1];
        // dont read more entries than this packet has space for
        if (count > DV_ENTRIES_PER_PACKET)
        {
            return;
        }

        peerIndex = addNeighborIfMissing(linkSource);
        if (peerIndex < 0)
        {
            return;
        }
        // read each destination and cost from the received packet
        // missing entries are left alone, since updates can span several packets
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
            // do not create a new routing table entry just for an unreachable route
            if (routeIndex < 0 && cost == DV_INFINITY)
            {
                continue;
            }

            if (routeIndex < 0)
            {
                routeIndex = addRouteIfMissing(destination);
            }

            if (routeIndex < 0)
            {
                continue;
            }
            // remember this neighbor's advertised cost and when we last heard it
            peers[peerIndex].cost[routeIndex] = cost;
            peers[peerIndex].seen[routeIndex] = ticks;
        }

        post updateRoutesTask();
    }
    // IP calls this to find which neighbor should receive the next packet
    // return zero if theres no working route or the next hop is inactive
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
    // return the number of hops for a destination, or 16 if unknown
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
    // print the routing table for routeDMP during sims
    // show INF when a destination is currently unreachable
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
