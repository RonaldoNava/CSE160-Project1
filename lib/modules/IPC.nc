configuration IPC
{
    provides interface IP;

    // uses interface LinkState;
    uses interface DistanceVector;
    uses interface SimpleSend as Sender;
}

implementation
{
    components IPP;

    IP = IPP.IP;

    IPP.DistanceVector = DistanceVector;
    IPP.Sender = Sender;
}