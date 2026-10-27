/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC
{
}
implementation
{
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node->MainC.Boot;

    Node.Receive->GeneralReceive;

    components ActiveMessageC;
    Node.AMControl->ActiveMessageC;
    Node.AMPacket->ActiveMessageC;

    components new SimpleSendC(AM_PACK) as SenderC;
    Node.Sender->SenderC;

    components CommandHandlerC;
    Node.CommandHandler->CommandHandlerC;

    components NDiscoveryC;
    Node.NDiscovery->NDiscoveryC;
    NDiscoveryC.Sender->SenderC;

    components FloodingC;
    Node.Flooding->FloodingC;
    FloodingC.Sender->SenderC;
    FloodingC.NDiscovery->NDiscoveryC;

    // project 2 link state routing
    // components LSC;
    // Node.LinkState->LSC.LinkState;
    // LSC.NDiscovery->NDiscoveryC;
    // LSC.Flooding->FloodingC;

    // new project 2 distance vector routing
    components DVC;
    Node.DistanceVector->DVC.DistanceVector;
    DVC.NDiscovery->NDiscoveryC;
    DVC.Sender->SenderC;

    components IPC;
    Node.IP->IPC.IP;
    // IPC.LinkState->LSC.LinkState;
    IPC.DistanceVector->DVC.DistanceVector;
    IPC.Sender->SenderC;
}
