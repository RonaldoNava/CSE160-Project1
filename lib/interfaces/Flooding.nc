#include "../../includes/packet.h"

interface Flooding {

    command void start();
    command void flood(pack msg);
    command void receive(pack msg);
}