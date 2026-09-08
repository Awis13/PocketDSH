#include "CPTY.h"
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <errno.h>

pid_t harness_open_pty(int *master, const char *cwd, char *const argv[], char *const env[], unsigned short rows, unsigned short columns) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    int descriptor_limit = getdtablesize();
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // Only libc operations before exec. forkpty establishes the session and
        // controlling terminal; an ordinary pipe cannot provide job control.
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        for (int sig = 1; sig < NSIG; ++sig) sigaction(sig, &action, NULL);
        // Parent descriptors (database/control sockets) must not reach the shell.
        for (int fd = 3; fd < descriptor_limit; ++fd) close(fd);
        if (chdir(cwd) != 0) _exit(126);
        execve(argv[0], argv, env);
        _exit(127);
    }
    return pid;
}
int harness_resize_pty(int master, unsigned short rows, unsigned short columns) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(master, TIOCSWINSZ, &size);
}
