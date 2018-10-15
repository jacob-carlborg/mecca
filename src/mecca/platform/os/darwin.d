module mecca.platform.os.darwin;

// This does not exist on Darwin platforms. We'll just use a value that won't
// give any effects when used together with mmap.
enum MAP_POPULATE = 0;

enum O_DSYNC = 0x400000;

enum O_CLOEXEC = 0x1000000;
enum F_DUPFD_CLOEXEC = 67;
enum CLOCK_MONOTONIC = 6;

enum Syscall : int
{
    thread_selfid = 372
}

extern(C) nothrow @system @nogc
{
    import mecca.log : notrace;

    long syscall(int number, ...) nothrow;

    @notrace
    int syscall_int(ARGS...)(int number, auto ref ARGS args) nothrow
    {
        return cast(int)syscall(number, args);
    }

    @notrace
    int gettid() nothrow @trusted
    {
        return syscall_int(Syscall.thread_selfid);
    }
}

enum OSSignal
{
    SIGNONE = 0, /// invalid
    SIGHUP = 1, /// hangup
    SIGINT = 2, /// interrupt
    SIGQUIT = 3, /// quit
    SIGILL = 4, /// illegal instruction (not reset when caught)
    SIGTRAP = 5, /// trace trap (not reset when caught)
    SIGABRT = 6, /// abort()
    SIGIOT = SIGABRT, /// compatibility
    SIGEMT = 7, /// EMT instruction
    SIGFPE = 8, /// floating point exception
    SIGKILL = 9, /// kill (cannot be caught or ignored)
    SIGBUS = 10, /// bus error
    SIGSEGV = 11, /// segmentation violation
    SIGSYS = 12, /// bad argument to system call
    SIGPIPE = 13, /// write on a pipe with no one to read it
    SIGALRM = 14, /// alarm clock
    SIGTERM = 15, /// software termination signal from kill
    SIGURG = 16, /// urgent condition on IO channel
    SIGSTOP = 17, /// sendable stop signal not from tty
    SIGTSTP = 18, /// stop signal from tty
    SIGCONT = 19, /// continue a stopped process
    SIGCHLD = 20, /// to parent on child stop or exit
    SIGTTIN = 21, /// to readers pgrp upon background tty read
    SIGTTOU = 22, /// like TTIN for output if (tp->t_local&LTOSTOP)
    SIGIO = 23, /// input/output possible signal
    SIGXCPU = 24, /// exceeded CPU time limit
    SIGXFSZ = 25, /// exceeded file size limit
    SIGVTALRM = 26, /// virtual time alarm
    SIGPROF = 27, /// profiling time alarm
    SIGWINCH = 28, /// window size changes
    SIGINFO = 29, /// information request
    SIGUSR1 = 30, /// user defined signal 1
    SIGUSR2 = 31, /// user defined signal 2

    // dummy - all of the following enum members are dummy values
    SIGPWR = SIGNONE
}

// dummy - all of the following symbols are dummy symbols
enum O_RSYNC = -1;
alias timer_t = void*;

struct signalfd_siginfo
{
    uint ssi_signo;
    int ssi_errno;
    int ssi_code;
    uint ssi_pid;
    uint ssi_uid;
    int ssi_fd;
    uint ssi_tid;
    uint ssi_band;
    uint ssi_overrun;
    uint ssi_trapno;
    int ssi_status;
    int ssi_int;
    ulong ssi_ptr;
    ulong ssi_utime;
    ulong ssi_stime;
    ulong ssi_addr;
    ubyte[48] __pad;
}

enum SFD_NONBLOCK = 0x800;
enum SFD_CLOEXEC = 0x80000;
enum NUM_SIGS = 65;

alias int clockid_t;

import core.sys.posix.signal : timespec;

struct sigevent;

struct itimerspec
{
    timespec it_interval;
    timespec it_value;
}

int clock_getres(clockid_t, timespec*) { return -1; }
int clock_gettime(clockid_t, timespec*) { return -1; }
int clock_settime(clockid_t, in timespec*) { return -1; }
int timer_create(clockid_t, sigevent*, timer_t*) { return -1; }
int timer_delete(timer_t) { return -1; }
int timer_gettime(timer_t, itimerspec*) { return -1; }
int timer_getoverrun(timer_t) { return -1; }
int timer_settime(timer_t, int, in itimerspec*, itimerspec*) { return -1; }

enum EREMOTEIO = 121;
