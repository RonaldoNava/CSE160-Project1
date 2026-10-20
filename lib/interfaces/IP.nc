#include "../includes/packet.h"

interface IP
{
    command error_t send(uint16_t dest, uint8_t protocol, uint8_t *payload, uint8_t len);
    event void receive(pack msg);

    event void received(pack msg);
}