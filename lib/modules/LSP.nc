#include "../../includes/packet.h"
#include "../../includes/channels.h"

module LSP {
    provides interface LinkState;

    uses interface NDiscovery;
    uses interface Flooding;
    uses interface Timer<TMilli> as routingTimer;
    uses interface Timer<TMilli> as lsaTimer;
}

implementation {

    uint16_t lsaSeq = 0;

    enum{
    MAX_NEIGHBORS_PER_LSA = 32
    };

    enum{
        MAX_NODES = 32,
        MAX_LSA_PARTS = (MAX_NEIGHBORS_PER_LSA +LSA_MAX_TUPLES - 1)
                        / LSA_MAX_TUPLES
    };

    typedef struct {
        bool used;
        uint16_t origin;
        uint16_t seq;

        uint8_t numParts;
        uint8_t receivedParts[MAX_LSA_PARTS];
        uint8_t partCounts[MAX_LSA_PARTS];

        uint8_t neighborCount;
        uint16_t neighbors[MAX_NEIGHBORS_PER_LSA];
        uint8_t costs[MAX_NEIGHBORS_PER_LSA];

        bool complete;
    }LSAEntry;

    LSAEntry database[MAX_NODES];

    uint16_t distance[MAX_NODES];
    uint16_t nextHop[MAX_NODES];
    bool visited[MAX_NODES];

    enum {
        INFINITY_COST = 65535
    };

    int8_t findLSA(uint16_t origin){
        uint8_t i;

        for (i = 0; i < MAX_NODES; i++){
            if (database[i].used && database[i].origin == origin){
                return i; 
            }
        }
        return -1;
    }

    int8_t findFreeLSASlot() {
        uint8_t i;

        for (i = 0; i < MAX_NODES; i++){
            if (!database[i].used){
                return i;
            }
        }
        return -1;
    }

    void resetLSAEntry(uint8_t slot, uint16_t origin, uint16_t seq, uint8_t numParts){
        uint8_t i;

        database[slot].used = TRUE;
        database[slot].origin = origin;
        database[slot].seq = seq;
        database[slot].numParts = numParts;
        database[slot].neighborCount = 0;
        database[slot].complete = FALSE;
        

        for(i = 0; i < MAX_LSA_PARTS; i++){
            database[slot].receivedParts[i] = 0;
            database[slot].partCounts[i] = 0;
        }
    }

    void storeLSA(uint16_t origin, LSAHeader *header);

    void sendLSA(){
        uint8_t neighborCount;
        uint8_t numParts;
        uint8_t part;
        uint8_t i;

        neighborCount = call NDiscovery.getNeighborCount();

        numParts = (neighborCount + LSA_MAX_TUPLES -1)/ LSA_MAX_TUPLES;

        if (numParts == 0){
            numParts = 1;
        }

        lsaSeq++;

        for (part = 0; part < numParts; part++){
            pack msg;
            LSAHeader *header;
            LSATuple *tuples;
            uint8_t count = 0;

            memset(&msg, 0, sizeof(pack));

            msg.src = TOS_NODE_ID;
            msg.dest = AM_BROADCAST_ADDR;
            msg.TTL = MAX_TTL;
            msg.protocol = PROTOCOL_FLOODING;

            msg.payload[0] = FLOOD_LSA;

            header = (LSAHeader *)&msg.payload[1];

            header->seq = lsaSeq;
            header->parts = part;
            header->numparts = numParts;

            tuples = (LSATuple *)header->tuples;

            for (i = 0; i < LSA_MAX_TUPLES; i++){
                uint8_t neighborIndex;
                uint16_t neighborID;
                uint8_t quality;
                bool active;

                neighborIndex = part * LSA_MAX_TUPLES + i;

                if (neighborIndex >= neighborCount){
                    break;
                }
                if (call NDiscovery.getNeighbor(
                    neighborIndex,
                    &neighborID,
                    &quality,
                    &active)){
                        tuples[count].neighbor = neighborID;
                        tuples[count].cost = 1;
                        count++;
                    }
            }
            header->count = count;

            dbg(ROUTING_CHANNEL,
                "Node %d: Sending LSA seq %d, part %d, count %d\n",
                TOS_NODE_ID,
                header->seq,
                header->parts,
                header->count);
            // store our own LSA in the database
            storeLSA(TOS_NODE_ID, header);
            //send the LSA to other nodes
            call Flooding.flood(msg);
        }
    }
    
    void runDijkstra();

    void storeLSA(uint16_t origin, LSAHeader *header){
        LSATuple *tuples;

        int8_t slot;
        uint8_t i;
        uint8_t position;
        uint8_t total = 0;
        bool allReceived  = TRUE;

        // check that fragment info is valid
        if(header->numparts == 0 ||
            header->numparts > MAX_LSA_PARTS ||
            header->parts >= header->numparts ||
            header->count > LSA_MAX_TUPLES){
                return;
            }
        // all fragments but last must be full
        if (header->parts < header->numparts - 1 &&
            header->count != LSA_MAX_TUPLES){
                return;
            }
        // find the origin in our database
        slot = findLSA(origin);

        if (slot == -1){
            slot = findFreeLSASlot();

            if (slot == -1){
                return;
            }
            resetLSAEntry(slot, origin, header->seq, header->numparts);
        }
        else {
            // ignore older advertisements
            if (header->seq < database[slot].seq){
                return;
            }
            //reset the entry when a newer advertisement arrives
            if (header->seq > database[slot].seq){
                resetLSAEntry(slot, origin, header->seq, header->numparts);
            }
            else if (header->numparts != database[slot].numParts){
                return;
            }
        }
        // ignore fragments already received
        if (database[slot].receivedParts[header->parts]){
            return;
        }

        tuples = (LSATuple *)header->tuples;
        //store the neighbors from this fragment
        for (i = 0; i < header->count; i++){
            position = header->parts * LSA_MAX_TUPLES + i;

            if (position >= MAX_NEIGHBORS_PER_LSA){
                return;
            }

            database[slot].neighbors[position] = tuples[i].neighbor;
            database[slot].costs[position] = tuples[i].cost;
        }

        database[slot].receivedParts[header->parts] = 1;
        database[slot].partCounts[header->parts] = header->count;
        //check if all fragments have arrived
        for (i = 0; i < database[slot].numParts; i++){
            if (!database[slot].receivedParts[i]){
                allReceived = FALSE;
                break;
            }
        }

        dbg(ROUTING_CHANNEL,
            "Node %d: COUNT DEBUG origin %d, numParts %d, partCounts[0] %d\n",
            TOS_NODE_ID,
            origin,
            database[slot].numParts,
            database[slot].partCounts[0]);
        // if complete, count the neighbors
        if (allReceived){
            for (i = 0; i < database[slot].numParts; i++){
                total += database[slot].partCounts[i];
            }
            database[slot].neighborCount = total;
            database[slot].complete = TRUE;

            for (i = 0; i < database[slot].neighborCount; i++){
                dbg(ROUTING_CHANNEL,
                    "Node %d: LSA origin %d, neighbor %d, cost %d\n",
                    TOS_NODE_ID,
                    origin,
                    database[slot].neighbors[i],
                    database[slot].costs[i]);
            }

            dbg(ROUTING_CHANNEL, "Node %d: Complete LSA from %d, seq %d, neighbors %d\n",
            TOS_NODE_ID, origin, header->seq, total);

            dbg(ROUTING_CHANNEL, "Node %d: LSDB updated for origin %d\n",
                TOS_NODE_ID, origin);
        }
        runDijkstra();
    }

    int8_t findClosestNode() {
        uint8_t i;
        int8_t closest = -1;
        uint16_t smallest = INFINITY_COST;

        for (i = 0; i < MAX_NODES; i++){
            if (!visited[i] && distance[i] < smallest){
                smallest = distance[i];
                closest = i;
            }
        }
        return closest;
    }

    void runDijkstra(){
        uint8_t i;
        uint8_t j;
        uint8_t k;
        uint8_t current;
        uint8_t neighborIndex;

        int8_t closest;
        uint16_t newDistance;

        for (i = 0; i < MAX_NODES; i++){
            distance[i] = INFINITY_COST;
            nextHop[i] = 0;
            visited[i] = FALSE;
        }
        //distance to ourselves is 0
        if (TOS_NODE_ID == 0 || TOS_NODE_ID > MAX_NODES){
            return;
        }
        distance[TOS_NODE_ID - 1] = 0;
        // visit nodes in order of shortest distance
        for (i = 0; i < MAX_NODES; i++){
            closest = findClosestNode();

            if (closest == -1){
                break;
            }
            current = closest;
            visited[current] = TRUE;

            for (j = 0; j < MAX_NODES; j++){
                if (!database[j].used ||
                    !database[j].complete ||
                    database[j].origin != current + 1){
                        continue;
                    }

                for (k = 0; k < database[j].neighborCount; k++){
                    uint16_t neighborID = database[j].neighbors[k];

                    if (neighborID == 0 || neighborID > MAX_NODES){
                        continue;
                    }
                    
                    neighborIndex = neighborID - 1;

                    if (visited[neighborIndex]){
                        continue;
                    }

                    newDistance = distance[current] + database[j].costs[k];

                    if (newDistance < distance[neighborIndex]){
                        distance[neighborIndex] = newDistance;
                        // direct neighbor or inhereted next hop 
                        if (current + 1 == TOS_NODE_ID){
                            nextHop[neighborIndex] = neighborID;
                        }
                        else{
                            nextHop[neighborIndex] = nextHop[current];
                        }
                    }
                }
                break;
            }
        }
        dbg(ROUTING_CHANNEL, "Node %d: Dijkstra calculation complete\n", TOS_NODE_ID);
    }

    command void LinkState.start(){ 
        uint8_t i;
        uint8_t j;

        lsaSeq = 0;

        for (i = 0; i < MAX_NODES; i++){
            database[i].used = FALSE;
            database[i].origin = 0;
            database[i].seq = 0;
            database[i].numParts = 0;
            database[i].neighborCount = 0;
            database[i].complete = FALSE;

            distance[i] = INFINITY_COST;
            nextHop[i] = 0;
            visited[i] = FALSE;

            for (j = 0; j < MAX_LSA_PARTS; j++){
                database[i].receivedParts[j] = 0;
                database[i].partCounts[j] = 0;
            }
        }
        call routingTimer.startOneShot(30000);
        dbg(ROUTING_CHANNEL, "Node %d: Link State started\n", TOS_NODE_ID);
    }

    command void LinkState.printRoutingTable(){
        uint8_t i;

        dbg(ROUTING_CHANNEL, "\nNode %d: Routing Table\n", TOS_NODE_ID);

        dbg(ROUTING_CHANNEL, "Destination | Next Hop | Cost\n");

        for (i = 0; i < MAX_NODES; i){
            if (distance[i] == INFINITY_COST){
                continue;
            }

            if (i + 1 == TOS_NODE_ID){
                continue;
            }

            dbg(ROUTING_CHANNEL,
                "     %d      |    %d     |  %d\n",
            i + 1, nextHop[i], distance[i]);
            
        }
    }

    command uint16_t LinkState.getNextHop(uint16_t dest){
        if (dest == 0 || dest > MAX_NODES){
            return 0;
        }

        if (dest == TOS_NODE_ID){
            return 0;
        }

        dbg(ROUTING_CHANNEL,
            "Node %d: LOOKUP destination %d, nextHop %d, distance %d\n",
            TOS_NODE_ID,
            dest,
            nextHop[dest - 1],
            distance[dest - 1]);

        return nextHop[dest - 1];
    }

    event void Flooding.received(pack msg, uint16_t source){
        LSAHeader *header;

        //ignore packets that aren't LSAs
        if (msg.payload[0] != FLOOD_LSA){
            return;
        }
        //ignore our own advertisements
        if (msg.src == TOS_NODE_ID){
            return;
        }
        header = (LSAHeader *)&msg.payload[1];

        dbg(ROUTING_CHANNEL,
            "Node %d: Received LSA from %d, seq %d, part %d, count %d\n",
            TOS_NODE_ID,
            msg.src,
            header->seq,
            header->parts,
            header->count);

        storeLSA(msg.src, header);
    }

    event void lsaTimer.fired() {
        sendLSA();

        call lsaTimer.startOneShot(10000 + (TOS_NODE_ID * 100));
    }

    event void NDiscovery.neighborChanged(){
        dbg(ROUTING_CHANNEL, "Node %d: Neighbor table changed\n", TOS_NODE_ID);
        call lsaTimer.startOneShot(1000 + (TOS_NODE_ID *  100));
    }


    event void routingTimer.fired(){
        uint8_t i;

        dbg(ROUTING_CHANNEL,
            "\nNode %d: Routing Table\n",
            TOS_NODE_ID);

        for (i = 0; i < MAX_NODES; i++){
            if (distance[i] != INFINITY_COST && i + 1 != TOS_NODE_ID){
                dbg(ROUTING_CHANNEL,
                    "Destination %d, Next Hop %d, Cost %d\n",
                    i + 1, nextHop[i], distance[i]);
            }
        }

        dbg(ROUTING_CHANNEL,
            "Node %d: Finished routing table\n",
            TOS_NODE_ID);
    }
}
