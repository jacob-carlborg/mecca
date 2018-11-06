module mecca.reactor.subsystems.poller;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

public import mecca.reactor.platform.poller;

struct FdContext {
     import mecca.reactor : FiberHandle;

    enum Type { None, FiberHandle, Callback, CallbackOneShot, NoiseReduction }
    Type type = Type.None;
    int fdNum;
    union {
        FiberHandle fibHandle;
        void delegate(void* opaq) callback;
    }
    void* opaq;
}

private __gshared Poller __poller;
public @property ref Poller poller() nothrow @trusted @nogc {
    return __poller;
}
