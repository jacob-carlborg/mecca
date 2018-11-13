module mecca.reactor.platform.linux.poller;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux):
package(mecca.reactor.platform):

import core.stdc.errno;
import core.sys.linux.epoll;
import core.sys.posix.fcntl;
import unistd = core.sys.posix.unistd;
import std.conv;
import std.exception;
import std.meta;
import std.traits;
import std.string;

import mecca.reactor;
import mecca.containers.pools;
import mecca.lib.io;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;


//
// epoll subsystems (sleep in the kernel until events occur)
//

// Definitions missing from the phobos headers or lacking nothrow @nogc
private extern(C) {
    int epoll_create1 (int flags) nothrow @trusted @nogc;
    int fcntl(int, int, ...) nothrow @trusted @nogc;
    /+
    int epoll_pwait(int epfd, epoll_event* events,
                      int maxevents, int timeout,
                      const sigset_t *sigmask);
    +/
}

struct Poller {
    public import mecca.reactor.subsystems.poller : FdContext;

private: // Not that this does anything, as the struct itself is only visible to this file.
    FD epollFd;
    FixedPool!(FdContext, MAX_CONCURRENT_FDS) fdPool;

    enum MIN_DURATION = dur!"msecs"(1);
    enum NUM_BATCH_EVENTS = 32;
    enum MAX_CONCURRENT_FDS = 512;

public:

    void open() @safe {
        ASSERT!"Must call theReactor.setup before calling ReactorFD.openReactor"(theReactor.isOpen);
        int epollFdOs = epoll_create1(EPOLL_CLOEXEC);
        errnoEnforceNGC( epollFdOs>=0, "Failed to create epoll fd" );
        epollFd = FD(epollFdOs);

        fdPool.open();
    }

    void close() {
        epollFd.close();
    }

    @property bool isOpen() const pure nothrow @safe @nogc {
        return epollFd.isValid;
    }

    FdContext* registerFD(ref FD fd, bool alreadyNonBlocking = false) @safe @nogc {
        ASSERT!"registerFD called outside of an open reactor"( theReactor.isOpen );
        ASSERT!"registerFD called without first calling ReactorFD.openReactor"( epollFd.isValid );
        FdContext* ctx = fdPool.alloc();
        ctx.type = FdContext.Type.None;
        ctx.fdNum = fd.fileNo;
        scope(failure) fdPool.release(ctx);

        if( !alreadyNonBlocking ) {
            int res = .fcntl(fd.fileNo, F_SETFL, O_NONBLOCK|FD_CLOEXEC);
            errnoEnforceNGC( res>=0, "Failed to set fd to non-blocking mode" );
        }

        internalRegisterFD(fd.fileNo, ctx);

        return ctx;
    }

    void deregisterFd(ref FD fd, FdContext* ctx) nothrow @safe @nogc {
        if( ctx.type!=FdContext.Type.NoiseReduction )
            internalDeregisterFD(fd.fileNo, ctx);

        fdPool.release(ctx);
    }

    void waitForEvent(FdContext* ctx, int fd, Timeout timeout = Timeout.infinite) @safe @nogc {
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
            // FD was deregistered from the epoll because it was noisy. Reregister it.
            internalRegisterFD(fd, ctx);
            ctx.type = None;
            break;
        case SignalHandler:
            ASSERT!"Should never happen for epoll, SignalHandler is kqueue only";
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
        ASSERT!"Trying to register callback on busy FD %s: state %s"( ctx.type==FdContext.Type.None, fd, ctx.type );
        ASSERT!"Cannot register a null callback on FD %s"( callback !is null, fd );

        ctx.type = oneShot ? FdContext.Type.CallbackOneShot : FdContext.Type.Callback;
        ctx.callback = callback;
        ctx.opaq = opaq;
    }

    @notrace void unregisterFdCallback(FdContext* ctx, int fd) nothrow @trusted @nogc {
        INFO!"Unregistered callback on fd %s"(fd);
        ASSERT!"Trying to deregister callback on non-registered FD %s: state %s"(
                ctx.type==FdContext.Type.Callback || ctx.type==FdContext.Type.CallbackOneShot, fd, ctx.type);

        ctx.type = FdContext.Type.None;
    }

    /// Export of the poller function
    ///
    /// A variation of this function is what's called by the reactor idle callback (unless `OpenOptions.registerDefaultIdler`
    /// is set to `false`).
    @notrace void poll() {
        reactorIdle(Duration.zero);
    }

    @notrace bool reactorIdle(Duration timeout) {
        int intTimeout;
        if( timeout == Duration.max )
            intTimeout = -1;
        else
            intTimeout = to!int(timeout.total!"msecs");

        epoll_event[NUM_BATCH_EVENTS] events;
        if( timeout > Duration.zero && intTimeout == 0 )
            intTimeout = 1;
        int res = epollFd.osCall!epoll_wait(events.ptr, NUM_BATCH_EVENTS, intTimeout);

        if( res<0 &&  errno==EINTR ) {
            DEBUG!"epoll call interrupted by signal"();
            return true;
        }

        errnoEnforceNGC( res>=0, "epoll_wait failed" );

        foreach( ref event; events[0..res] ) {
            auto ctx = cast(FdContext*)event.data.ptr;

            with(FdContext.Type) final switch(ctx.type) {
            case None:
                WARN!"epoll returned handle %s which is no longer valid: Disabling"(ctx);
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
                ASSERT!"FD %s triggered epoll despite being disabled on ctx %s"(false, ctx.fdNum, ctx);
                break;
            case SignalHandler:
                ASSERT!"Should never happen for epoll, SignalHandler is kqueue only";
                break;
            }
        }

        return true;
    }

private:
    void internalRegisterFD(int fd, FdContext* ctx) @trusted @nogc {
        epoll_event event = void;
        event.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET; // Register with Edge Trigger behavior
        event.data.ptr = ctx;
        int res = epollFd.osCall!epoll_ctl(EPOLL_CTL_ADD, fd, &event);
        errnoEnforceNGC( res>=0, "Adding fd to epoll failed" );
    }

    void internalDeregisterFD(int fd, FdContext* ctx) nothrow @trusted @nogc {
        int res = epollFd.osCall!epoll_ctl(EPOLL_CTL_DEL, fd, null);

        // There is no reason for a registered FD to fail removal, so we assert instead of throwing
        ASSERT!"Removing fd from epoll failed with errno %s"( res>=0, errno );
    }
}

// Unit test in mecca.reactor.io
