module mecca.reactor.platform.kqueue;

version (Kqueue):
package:

alias Poller = Kqueue;

struct Kqueue
{
    public import mecca.reactor.subsystems.poller : FdContext;

    import core.time : Duration, msecs;

    import mecca.containers.pools : FixedPool;
    import mecca.lib.exception : ASSERT, enforceNGC, errnoEnforceNGC;
    import mecca.lib.io : FD;
    import mecca.lib.time : Timeout;
    import mecca.log : INFO, notrace;
    import mecca.platform.os : OSSignal;
    import mecca.reactor : theReactor;
    import mecca.reactor.platform : kevent64, kevent64_s;

    package(mecca.reactor) alias SignalHandler = void delegate(OSSignal);

    private
    {
        enum MIN_DURATION = 1.msecs;
        enum NUM_BATCH_EVENTS = 32;
        enum MAX_CONCURRENT_FDS = 512;

        FD kqueueFd;
        FixedPool!(FdContext, MAX_CONCURRENT_FDS) fdPool;

        int numberOfChanges;
        kevent64_s[NUM_BATCH_EVENTS] changes;
    }

    invariant
    {
        assert(changes.length > numberOfChanges);
    }

    void open() @safe
    {
        enum assertMessage = "Must call theReactor.setup before calling " ~
            "ReactorFD.openReactor";

        ASSERT!assertMessage(theReactor.isOpen);

        const fd = kqueue();
        errnoEnforceNGC(fd >= 0, "Failed to create kqueue file descriptor");
        kqueueFd = FD(fd);

        fdPool.open();
    }

    void close()
    {
        kqueueFd.close();
    }

    @property bool isOpen() const pure nothrow @safe @nogc
    {
        return kqueueFd.isValid;
    }

    FdContext* registerFD(ref FD fd, bool alreadyNonBlocking = false) @safe @nogc
    {
        import core.sys.posix.fcntl : F_SETFL, FD_CLOEXEC, O_NONBLOCK;

        enum reactorMessage = "registerFD called outside of an open reactor";
        enum fdMessage = "registerFD called without first calling " ~
            "ReactorFD.openReactor";

        ASSERT!reactorMessage(theReactor.isOpen);
        ASSERT!fdMessage(kqueueFd.isValid);

        FdContext* context = fdPool.alloc();
        context.type = FdContext.Type.None;
        context.fdNum = fd.fileNo;
        scope(failure) fdPool.release(context);

        if (!alreadyNonBlocking)
        {
            const res = fcntl(fd.fileNo, F_SETFL, O_NONBLOCK | FD_CLOEXEC);
            errnoEnforceNGC(res >=0 , "Failed to set fd to non-blocking mode");
        }

        internalRegisterFD(fd.fileNo, context);

        return context;
    }

    void deregisterFd(ref FD fd, FdContext* ctx) nothrow @safe @nogc
    {
        if (ctx.type != FdContext.Type.NoiseReduction)
            internalDeregisterFD(fd.fileNo, ctx);

        fdPool.release(ctx);
    }

    void waitForEvent(FdContext* ctx, int fd, Timeout timeout = Timeout.infinite) @safe @nogc
    {
        /*
            TODO: In the future, we might wish to allow one fiber to read from an ReactorFD while another writes to the same ReactorFD. As the code
            currently stands, this will trigger the assert below
         */
        with(FdContext.Type) final switch(ctx.type) {
        case None:
            break;
        case FiberHandle:
            ASSERT!"Two fibers cannot wait on the same ReactorFD %s at once: %s asked to wait with %s already waiting"(
                    false, fd, theReactor.currentFiberHandle.fiberId, ctx.fibHandle.fiberId );
            break;
        case Callback:
        case CallbackOneShot:
            ASSERT!"Cannot wait on FD %s already waiting on a callback"(false, fd);
            break;
        case NoiseReduction:
            // FD was deregistered from the queue because it was noisy. Reregister it.
            internalRegisterFD(fd, ctx);
            ctx.type = None;
            break;
        case SignalHandler:
            ASSERT!"Cannot wait on signal %s already waiting on a signal handler"(false, fd);
            break;
        }
        ctx.type = FdContext.Type.FiberHandle;
        scope(exit) ctx.type = FdContext.Type.None;
        ctx.fibHandle = theReactor.currentFiberHandle;

        theReactor.suspendCurrentFiber(timeout);
    }

    @notrace void registerFdCallback(FdContext* ctx, int fd, void delegate(void*) callback, void* opaq, bool oneShot)
        nothrow @trusted @nogc
    {
        INFO!"Registered callback %s on fd %s one shot %s"(&callback, fd, oneShot);
        ASSERT!"Trying to register callback on busy FD %s: state %s"(ctx.type==FdContext.Type.None, fd, ctx.type);
        ASSERT!"Cannot register a null callback on FD %s"(callback !is null, fd);

        ctx.type = oneShot ? FdContext.Type.CallbackOneShot : FdContext.Type.Callback;
        ctx.callback = callback;
        ctx.opaq = opaq;
    }

    @notrace void unregisterFdCallback(FdContext* ctx, int fd) nothrow @trusted @nogc
    {
        INFO!"Unregistered callback on fd %s"(fd);
        ASSERT!"Trying to deregister callback on non-registered FD %s: state %s"(
                ctx.type==FdContext.Type.Callback || ctx.type==FdContext.Type.CallbackOneShot, fd, ctx.type);

        ctx.type = FdContext.Type.None;
    }

    package(mecca.reactor) @notrace FdContext* registerSignalHandler(OSSignal signal, SignalHandler handler)
        @trusted @nogc
    {
        enum reactorMessage = "registerFD called outside of an open reactor";
        enum fdMessage = "registerFD called without first calling " ~
            "ReactorFD.openReactor";

        ASSERT!reactorMessage(theReactor.isOpen);
        ASSERT!fdMessage(kqueueFd.isValid);

        auto context = fdPool.alloc();
        context.type = FdContext.Type.SignalHandler;
        context.callback = cast(void delegate(void*)) handler;
        context.fdNum = signal;
        scope(failure) fdPool.release(context);

        internalRegisterSignalHandler(context);
        return context;
    }

    package(mecca.reactor) @notrace void unregisterSignalHandler(FdContext* ctx) nothrow @safe @nogc
    {
        if (ctx.type != FdContext.Type.NoiseReduction)
            internalDeregisterSignalHandler(ctx);

        fdPool.release(ctx);
    }

    /// Export of the poller function
    ///
    /// A variation of this function is what's called by the reactor idle callback (unless `OpenOptions.registerDefaultIdler`
    /// is set to `false`).
    @notrace void poll()
    {
        reactorIdle(Duration.zero);
    }

    @notrace bool reactorIdle(Duration timeout)
    {
        import core.stdc.errno : EINTR, errno;

        import mecca.lib.time : toTimespec;
        import mecca.log : DEBUG, WARN;
        import mecca.reactor.platform : EV_DELETE;

        const spec = timeout.toTimespec();
        const specTimeout = timeout == Duration.max ? null : &spec;

        kevent64_s[NUM_BATCH_EVENTS] events;

        const result = kqueueFd.osCall!kevent64(
            changes.ptr,
            numberOfChanges,
            events.ptr,
            cast(int) events.length,
            0,
            specTimeout
        );

        if (result < 0 && errno == EINTR)
        {
            DEBUG!"kevent64 call interrupted by signal";
            return true;
        }

        errnoEnforceNGC(result >= 0, "kevent64 failed");

        foreach (ref event ; events[0 .. result])
        {
            if (event.flags & EV_DELETE)
                continue;

            auto ctx = cast(FdContext*) event.udata;
            ASSERT!"ctx is null"(ctx !is null);

            with(FdContext.Type) final switch(ctx.type)
            {
            case None:
                WARN!"kevent64 returned handle %s which is no longer valid: Disabling"(ctx);
                internalDeregisterFD(ctx.fdNum, ctx);
                ctx.type = NoiseReduction;
                break;
            case FiberHandle:
                theReactor.resumeFiber(ctx.fibHandle);
                break;
            case Callback:
                ctx.callback(ctx.opaq);
                break;
            case CallbackOneShot:
                ctx.type = None;
                ctx.callback(ctx.opaq);
                break;
            case NoiseReduction:
                ASSERT!"FD %s triggered kevent64 despite being disabled on ctx %s"(false, ctx.fdNum, ctx);
                break;
            case SignalHandler:
                ASSERT!"Event signal %s was not the same as the registered signal %s"(event.ident == ctx.fdNum, event.ident, ctx.fdNum);
                const signal = cast(OSSignal) event.ident;
                (cast(Kqueue.SignalHandler) ctx.callback)(signal);
                break;
            }
        }

        return true;
    }

private:

    void internalRegisterFD(int fd, FdContext* ctx) @trusted @nogc
    {
        import mecca.reactor.platform : EV_ADD, EV_CLEAR, EV_ENABLE,
            EVFILT_READ, EVFILT_WRITE;

        ASSERT!"ctx is null"(ctx !is null);

        const kevent64_s event = {
            ident: fd,
            filter: EVFILT_READ | EVFILT_WRITE,
            flags: EV_ADD | EV_ENABLE | EV_CLEAR,
            udata: cast(ulong) ctx
        };

        const result = queueEvent(event);
        errnoEnforceNGC(result >= 0, "Adding fd to queue failed");
    }

    void internalDeregisterFD(int fd, FdContext* ctx) nothrow @trusted @nogc
    {
        import core.stdc.errno : errno;
        import mecca.reactor.platform : EV_DELETE;

        const kevent64_s event = { ident: fd, flags: EV_DELETE };

        const result = queueEvent(event);
        ASSERT!"Removing fd from queue failed with errno %s"(result >= 0, errno);
    }

    void internalRegisterSignalHandler(FdContext* ctx) @trusted @nogc
    {
        import mecca.reactor.platform : EV_ADD, EV_CLEAR, EV_ENABLE,
            EVFILT_SIGNAL;

        ASSERT!"ctx is null"(ctx !is null);

        const kevent64_s event = {
            ident: ctx.fdNum,
            filter: EVFILT_SIGNAL,
            flags: EV_ADD | EV_ENABLE | EV_CLEAR,
            udata: cast(ulong) ctx
        };

        const result = queueEvent(event);
        errnoEnforceNGC(result >= 0, "Adding signal to queue failed");
    }

    void internalDeregisterSignalHandler(FdContext* ctx) nothrow @trusted @nogc
    {
        import core.stdc.errno : errno;
        import mecca.reactor.platform : EV_DELETE;

        const kevent64_s event = { ident: ctx.fdNum, flags: EV_DELETE };

        const result = queueEvent(event);
        ASSERT!"Removing signal from queue failed with errno %s"(result >= 0, errno);
    }

    int queueEvent(const ref kevent64_s event) nothrow @trusted @nogc
    {
        changes[numberOfChanges++] = event;

        if (numberOfChanges != changes.length)
            return 1;

        const result = kqueueFd.osCall!kevent64(changes.ptr, numberOfChanges,
            null, 0, 0, null);
        numberOfChanges = 0;

        return result;
    }

}

extern (C) int kqueue() nothrow @trusted @nogc;
extern (C) int fcntl(int, int, ...) nothrow @trusted @nogc;
