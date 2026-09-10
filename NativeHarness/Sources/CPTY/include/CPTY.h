#ifndef HARNESS_CPTY_H
#define HARNESS_CPTY_H
#include <sys/types.h>
// Tiny libc bridge: no Swift/Foundation execution in the post-fork child.
pid_t harness_open_pty(int *master, const char *cwd, char *const argv[], char *const env[], unsigned short rows, unsigned short columns);
int harness_resize_pty(int master, unsigned short rows, unsigned short columns);
#endif
