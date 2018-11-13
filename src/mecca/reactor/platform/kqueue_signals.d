/// Manage signals as reactor callbacks
module mecca.reactor.platform.kqueue_signals;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (Kqueue):
package(mecca.reactor.platform):

alias ReactorSignal = KqueueReactorSignal;

private struct KqueueReactorSignal {
    import mecca.lib.exception : ASSERT;
    import mecca.platform.os : OSSignal;
    import mecca.reactor.platform.kqueue : Kqueue;
    import mecca.reactor.subsystems.poller : poller, Poller;

    alias SignalHandler = Kqueue.SignalHandler;

    private Poller.FdContext*[OSSignal.max] handlers;

    /**
     * Must be called prior to registering any signals.
     *
     * Must be called after the reactor is open, and also after ReactorFS.openReactor has already been called.
     */
    void _open() @safe @nogc {
        ASSERT!"ReactorSignal.open called without first calling ReactorFD.openReactor"(poller.isOpen);
    }

    /// Call this when shutting down the reactor. Mostly necessary for unit tests
    void _close() @safe @nogc {
        // noop
    }

    /**
     * register a signal handler
     *
     * Register a handler for a specific signal. The signal must not already be handled, either through ReactorSignal or
     * otherwise.
     *
     * Params:
     * signum = the signal to be handled
     * handler = a delegate to be called when the signal arrives
     */
    void registerHandler(OSSignal signum, SignalHandler handler) @trusted @nogc {
        ASSERT!"registerHandler called with invalid signal %s"(signum <= OSSignal.max || signum<=0, signum);
        ASSERT!"signal %s registered twice"(handlers[signum] is null, signum);

        handlers[signum] = poller.registerSignalHandler(signum, handler);
    }

    void registerHandler(string sig, T)(T handler) @trusted {
        registerHandler(__traits(getMember, OSSignal, sig), (ref _){handler();});
    }

    void unregisterHandler(OSSignal signum) @trusted @nogc {
        ASSERT!"registerHandler called with invalid signal %s"(signum <= OSSignal.max || signum<=0, signum);
        ASSERT!"signal %s not registered"(handlers[signum] !is null, signum);

        poller.unregisterSignalHandler(handlers[signum]);
        handlers[signum] = null;
    }

    void unregisterHandler(string sig)() @trusted @nogc {
        unregisterHandler(__traits(getMember, OSSignal, sig));
    }
}
