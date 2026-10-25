configuration IPC {
    provides interface IP;

    uses interface LinkState;
    uses interface SimpleSend as Sender;
}

implementation {
    components IPP;

    IP = IPP.IP;

    IPP.LinkState = LinkState;
    IPP.Sender = Sender;
}