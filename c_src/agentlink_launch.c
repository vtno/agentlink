#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
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

#if defined(__linux__)
#include <dirent.h>
#elif defined(__APPLE__)
#include <libproc.h>
#include <mach-o/dyld.h>
#include <sys/proc_info.h>
#endif

/*
 * The Burrito child is placed in its own process group before exec.
 * A signal delivered to this wrapper's group reaches only the wrapper.
 * The wrapper forwards that one signal to the Burrito process's direct
 * child. That child is the VM: the launcher execs erlexec, which becomes
 * beam.smp. Helpers such as erl_child_setup are grandchildren, so a leaf
 * walk would signal them and miss the VM. The signal is sent only when
 * the recorded start time still matches. The wrapper waits until that
 * VM is gone and exits with the status of the Burrito process, which
 * has waited for the VM.
 */

#define MAX_PROCS 4096
#define MAX_TRACKED 64

struct proc_row {
    pid_t pid;
    pid_t ppid;
    unsigned long long start;
};

struct tracked {
    pid_t pid;
    unsigned long long start;
};

static pid_t child_pid = -1;
static int wake_write = -1;
static struct tracked tracked_vm[MAX_TRACKED];
static int tracked_count = 0;

static void on_signal(int sig) {
    unsigned char byte = (unsigned char)sig;

    if (wake_write >= 0) {
        ssize_t wrote = write(wake_write, &byte, 1);
        (void)wrote;
    }
}

static void remember(pid_t pid, unsigned long long start) {
    int index;

    if (pid <= 1) {
        return;
    }

    for (index = 0; index < tracked_count; index++) {
        if (tracked_vm[index].pid == pid) {
            return;
        }
    }

    if (tracked_count < MAX_TRACKED) {
        tracked_vm[tracked_count].pid = pid;
        tracked_vm[tracked_count].start = start;
        tracked_count++;
    }
}

static int remembered_start(pid_t pid, unsigned long long *start) {
    int index;

    for (index = 0; index < tracked_count; index++) {
        if (tracked_vm[index].pid == pid) {
            *start = tracked_vm[index].start;
            return 1;
        }
    }

    return 0;
}

#if defined(__linux__)
static int read_stat(pid_t pid, pid_t *ppid, unsigned long long *start) {
    char path[64];
    char buf[1024];
    FILE *file;
    size_t n;
    char *end;
    char *cursor;
    int index;

    if (snprintf(path, sizeof path, "/proc/%d/stat", (int)pid) >= (int)sizeof path) {
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

    if (!end) {
        return -1;
    }

    cursor = end + 1;

    for (index = 0; index <= 19 && *cursor; index++) {
        char *token;

        while (*cursor == ' ') {
            cursor++;
        }

        token = cursor;

        while (*cursor && *cursor != ' ') {
            cursor++;
        }

        if (index == 1) {
            *ppid = (pid_t)atoi(token);
        }

        if (index == 19) {
            *start = strtoull(token, NULL, 10);
        }
    }

    return index > 19 ? 0 : -1;
}

static int list_procs(struct proc_row *rows, int max) {
    DIR *dir = opendir("/proc");
    struct dirent *ent;
    int count = 0;

    if (!dir) {
        return 0;
    }

    while ((ent = readdir(dir)) != NULL && count < max) {
        pid_t pid;
        pid_t ppid = -1;
        unsigned long long start = 0;

        if (!isdigit((unsigned char)ent->d_name[0])) {
            continue;
        }

        pid = (pid_t)atoi(ent->d_name);

        if (pid <= 1 || read_stat(pid, &ppid, &start) != 0) {
            continue;
        }

        rows[count].pid = pid;
        rows[count].ppid = ppid;
        rows[count].start = start;
        count++;
    }

    closedir(dir);
    return count;
}
#elif defined(__APPLE__)
static int read_stat(pid_t pid, pid_t *ppid, unsigned long long *start) {
    struct proc_bsdinfo info;
    int wrote = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info);

    if (wrote != (int)sizeof info) {
        return -1;
    }

    *ppid = (pid_t)info.pbi_ppid;
    *start = (info.pbi_start_tvsec << 32) | info.pbi_start_tvusec;
    return 0;
}

static int list_procs(struct proc_row *rows, int max) {
    int bytes = proc_listallpids(NULL, 0);
    int slots;
    pid_t *pids;
    int count = 0;
    int index;

    if (bytes <= 0) {
        return 0;
    }

    slots = bytes / (int)sizeof(pid_t) + 64;
    pids = calloc((size_t)slots, sizeof(pid_t));

    if (!pids) {
        return 0;
    }

    bytes = proc_listallpids(pids, slots * (int)sizeof(pid_t));

    if (bytes > 0) {
        int n = bytes / (int)sizeof(pid_t);

        for (index = 0; index < n && count < max; index++) {
            pid_t ppid = -1;
            unsigned long long start = 0;

            if (pids[index] <= 1 || read_stat(pids[index], &ppid, &start) != 0) {
                continue;
            }

            rows[count].pid = pids[index];
            rows[count].ppid = ppid;
            rows[count].start = start;
            count++;
        }
    }

    free(pids);
    return count;
}
#else
static int read_stat(pid_t pid, pid_t *ppid, unsigned long long *start) {
    (void)pid;
    (void)ppid;
    (void)start;
    return -1;
}

static int list_procs(struct proc_row *rows, int max) {
    (void)rows;
    (void)max;
    return 0;
}
#endif

/* The VM is the direct child of the Burrito process. Grandchildren are helpers. */
static int find_vm(pid_t root, struct proc_row *vms, int max) {
    struct proc_row rows[MAX_PROCS];
    int count = list_procs(rows, MAX_PROCS);
    int index;
    int found = 0;

    for (index = 0; index < count && found < max; index++) {
        if (rows[index].ppid == root) {
            vms[found++] = rows[index];
        }
    }

    return found;
}

static int same_start(pid_t pid, unsigned long long start) {
    pid_t ppid = -1;
    unsigned long long now = 0;

    if (read_stat(pid, &ppid, &now) != 0) {
        return 0;
    }

    return now == start;
}

static int vm_alive(void) {
    int index;

    for (index = 0; index < tracked_count; index++) {
        if (same_start(tracked_vm[index].pid, tracked_vm[index].start)) {
            return 1;
        }
    }

    return 0;
}

static void observe(void) {
    struct proc_row vms[MAX_TRACKED];
    int count = find_vm(child_pid, vms, MAX_TRACKED);
    int index;

    for (index = 0; index < count; index++) {
        remember(vms[index].pid, vms[index].start);
    }
}

static void forward(int sig) {
    struct proc_row vms[MAX_TRACKED];
    int count = find_vm(child_pid, vms, MAX_TRACKED);
    int index;
    int sent = 0;

    observe();

    for (index = 0; index < count; index++) {
        unsigned long long start = vms[index].start;
        pid_t pid = vms[index].pid;

        remember(pid, start);

        if (!remembered_start(pid, &start)) {
            continue;
        }

        if (pid > 1 && same_start(pid, start) && kill(pid, sig) == 0) {
            sent = 1;
        }
    }

    if (!sent && child_pid > 1) {
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

static int self_path(char *dest, size_t dest_len) {
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", dest, dest_len - 1);

    if (n <= 0) {
        return -1;
    }

    dest[n] = '\0';
    return 0;
#elif defined(__APPLE__)
    uint32_t size = (uint32_t)dest_len;

    if (_NSGetExecutablePath(dest, &size) != 0) {
        return -1;
    }

    return 0;
#else
    (void)dest;
    (void)dest_len;
    return -1;
#endif
}

static int inner_path(char *dest, size_t dest_len) {
    size_t suffix = strlen(".burrito");
    size_t len;

    if (self_path(dest, dest_len) != 0) {
        return -1;
    }

    len = strlen(dest);

    if (len + suffix + 1 > dest_len) {
        return -1;
    }

    memcpy(dest + len, ".burrito", suffix + 1);
    return 0;
}

int main(int argc, char **argv) {
    char inner[4096];
    int pipefd[2];
    struct sigaction action;
    int child_done = 0;
    int child_code = 1;
    int escalated = 0;

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
        setpgid(0, 0);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        /* Burrito finds its payload from argv[0]. The wrapper path has no payload. */
        argv[0] = inner;
        execv(inner, argv);
        perror("agentlink launch");
        _exit(127);
    }

    setpgid(child_pid, child_pid);
    wake_write = pipefd[1];
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
    fcntl(pipefd[1], F_SETFL, O_NONBLOCK);

    memset(&action, 0, sizeof action);
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    for (;;) {
        unsigned char sig = 0;
        struct pollfd ready;

        observe();

        if (!child_done) {
            int status = 0;
            pid_t got = waitpid(child_pid, &status, WNOHANG);

            if (got == child_pid) {
                child_done = 1;
                child_code = status_code(status);
            } else if (got < 0 && errno != EINTR) {
                child_done = 1;
                child_code = 1;
            }
        }

        while (read(pipefd[0], &sig, 1) == 1) {
            forward((int)sig);
        }

        if (child_done && !vm_alive()) {
            return child_code;
        }

        if (child_done && vm_alive() && !escalated) {
            forward(SIGTERM);
            escalated = 1;
        }

        ready.fd = pipefd[0];
        ready.events = POLLIN;
        poll(&ready, 1, 50);
    }
}
