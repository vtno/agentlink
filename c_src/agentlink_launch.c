#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child_pid = -1;
static int wake_write = -1;

static void on_signal(int sig) {
    unsigned char byte = (unsigned char)sig;

    if (wake_write >= 0) {
        ssize_t wrote = write(wake_write, &byte, 1);
        (void)wrote;
    }
}

static int ppid_of(int pid) {
    char path[64];
    char buf[1024];
    FILE *file;
    size_t n;
    char *end;
    int ppid = -1;

    if (snprintf(path, sizeof path, "/proc/%d/stat", pid) >= (int)sizeof path) {
        return -1;
    }

    file = fopen(path, "r");

    if (!file) {
        return -1;
    }

    n = fread(buf, 1, sizeof buf - 1, file);
    fclose(file);

    if (n == 0) {
        return -1;
    }

    buf[n] = '\0';
    end = strrchr(buf, ')');

    if (!end || sscanf(end + 1, " %*c %d", &ppid) != 1) {
        return -1;
    }

    return ppid;
}

static void forward(int sig) {
    DIR *dir = opendir("/proc");
    struct dirent *ent;
    int found = 0;

    if (dir) {
        while ((ent = readdir(dir)) != NULL) {
            int pid;

            if (!isdigit((unsigned char)ent->d_name[0])) {
                continue;
            }

            pid = atoi(ent->d_name);

            if (pid > 1 && ppid_of(pid) == (int)child_pid) {
                if (kill(pid, sig) == 0) {
                    found = 1;
                }
            }
        }

        closedir(dir);
    }

    if (!found && child_pid > 1) {
        kill(child_pid, sig);
    }
}

static int status_code(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    return 1;
}

static int inner_path(char *dest, size_t dest_len) {
    ssize_t n = readlink("/proc/self/exe", dest, dest_len - strlen(".burrito") - 1);

    if (n <= 0 || (size_t)n >= dest_len - strlen(".burrito") - 1) {
        return -1;
    }

    dest[n] = '\0';
    memcpy(dest + n, ".burrito", strlen(".burrito") + 1);
    return 0;
}

int main(int argc, char **argv) {
    char inner[4096];
    int pipefd[2];
    struct sigaction action;

    (void)argc;

    if (inner_path(inner, sizeof inner) != 0 || pipe(pipefd) != 0) {
        return 127;
    }

    child_pid = fork();

    if (child_pid < 0) {
        return 127;
    }

    if (child_pid == 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        execv(inner, argv);
        perror("agentlink launch");
        _exit(127);
    }

    wake_write = pipefd[1];
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
    fcntl(pipefd[1], F_SETFL, O_NONBLOCK);

    memset(&action, 0, sizeof action);
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    for (;;) {
        int status = 0;
        pid_t got = waitpid(child_pid, &status, WNOHANG);
        unsigned char sig = 0;
        struct pollfd ready;

        if (got == child_pid) {
            return status_code(status);
        }

        if (got < 0 && errno != EINTR) {
            return 1;
        }

        while (read(pipefd[0], &sig, 1) == 1) {
            forward((int)sig);
        }

        ready.fd = pipefd[0];
        ready.events = POLLIN;
        poll(&ready, 1, 200);
    }
}
