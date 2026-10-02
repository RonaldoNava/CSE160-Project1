#include "../../includes/packet.h"

interface Flooding {

    command void start();
    command void flood(pack msg);
    command void receive(pack msg, uint16_t source);

    event void received(pack msg, uint16_t source);
}