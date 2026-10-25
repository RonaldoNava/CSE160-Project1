#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module IPP {
    provides interface IP;

    uses interface LinkState;
    uses interface SimpleSend as Sender;
}

implementation {

    command error_t IP.send(uint16_t dest, uint8_t protocol, uint8_t *payload, uint8_t len){
        pack msg;
        uint16_t next;

        if (len > PACKET_MAX_PAYLOAD_SIZE){
            return FAIL;
        }
        if (dest == TOS_NODE_ID){
            return FAIL;
        }

        next = call LinkState.getNextHop(dest);

        if (next == 0){
            dbg(ROUTING_CHANNEL, "Node %d: No route to destination %d\n",
                TOS_NODE_ID, dest);

            return FAIL;
        }
        memset(&msg, 0, sizeof(pack));

        msg.src = TOS_NODE_ID;
        msg.dest = dest;
        msg.seq = 0;
        msg.TTL = MAX_TTL;
        msg.protocol = protocol;

        memcpy(msg.payload, payload, len);

        dbg(ROUTING_CHANNEL, "Node %d: IP sending to %d through next hop %d\n",
            TOS_NODE_ID, dest, next);

        return call Sender.send(msg, next);
    }

    command void IP.receive(pack msg){
        uint16_t next;

        if (msg.dest == TOS_NODE_ID){

            dbg(ROUTING_CHANNEL, "Node %d: IP packet received from %d\n",
                TOS_NODE_ID, msg.src);

            signal IP.received(msg);
            return;
        }

        if (msg.TTL <= 1){
            dbg(ROUTING_CHANNEL, "Node  %d: IP packet TTL expired\n",
                TOS_NODE_ID);
            return;
        }
        next = call LinkState.getNextHop(msg.dest);
        
        if (next == 0) {
            dbg(ROUTING_CHANNEL, "Node %d: No route to destination %d\n",
                TOS_NODE_ID, msg.dest);
            return;
        }
        msg.TTL--;
        dbg(ROUTING_CHANNEL, "Node %d: IP forwarding from %d to %d through %d, TTL %d\n",
            TOS_NODE_ID, msg.src, msg.dest, next, msg.TTL);

        call Sender.send(msg, next);
    }
}