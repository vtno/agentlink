#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/*
 * Runs the Burrito executable in a job with KILL_ON_JOB_CLOSE.
 * Ctrl-C, Ctrl-Break, and console close become one Ctrl-Break delivered
 * to the child process group. GenerateConsoleCtrlEvent cannot address a
 * process group with CTRL_C_EVENT, and CREATE_NEW_PROCESS_GROUP makes the
 * child ignore Ctrl-C, so Ctrl-Break is the graceful stop the child can see.
 * The wrapper waits for the child and returns its exit code. After
 * Ctrl-Break it waits 2000 milliseconds. If the child is still running,
 * TerminateJobObject kills the job and the wrapper exits 1.
 */

static DWORD child_pid = 0;
static volatile LONG signaled = 0;

static BOOL WINAPI on_console(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
        if (InterlockedCompareExchange(&signaled, 1, 0) == 0 && child_pid != 0) {
            GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child_pid);
        }

        return TRUE;
    }

    return FALSE;
}

static const wchar_t *skip_argv0(const wchar_t *command) {
    const wchar_t *cursor = command;

    if (*cursor == L'"') {
        cursor++;

        while (*cursor && *cursor != L'"') {
            cursor++;
        }

        if (*cursor == L'"') {
            cursor++;
        }
    } else {
        while (*cursor && *cursor != L' ' && *cursor != L'\t') {
            cursor++;
        }
    }

    while (*cursor == L' ' || *cursor == L'\t') {
        cursor++;
    }

    return cursor;
}

static int inner_path(wchar_t *dest, DWORD dest_chars) {
    DWORD length = GetModuleFileNameW(NULL, dest, dest_chars);
    const wchar_t *suffix = L".burrito.exe";
    size_t suffix_chars = wcslen(suffix);
    size_t len;

    if (length == 0 || length >= dest_chars) {
        return 0;
    }

    len = wcslen(dest);

    if (len < 4 || _wcsicmp(dest + len - 4, L".exe") != 0) {
        return 0;
    }

    if (len - 4 + suffix_chars + 1 > dest_chars) {
        return 0;
    }

    wcscpy(dest + len - 4, suffix);
    return 1;
}

static int build_command(wchar_t *dest, size_t dest_chars, const wchar_t *inner, const wchar_t *tail) {
    size_t inner_len = wcslen(inner);
    size_t tail_len = tail ? wcslen(tail) : 0;
    size_t used = inner_len + 2;

    if (tail_len > 0) {
        used += 1 + tail_len;
    }

    if (used + 1 > dest_chars) {
        return 0;
    }

    dest[0] = L'"';
    wcscpy(dest + 1, inner);
    dest[1 + inner_len] = L'"';

    if (tail_len > 0) {
        dest[2 + inner_len] = L' ';
        wcscpy(dest + 3 + inner_len, tail);
    } else {
        dest[2 + inner_len] = L'\0';
    }

    return 1;
}

int main(void) {
    wchar_t inner[32768];
    wchar_t command[32768];
    const wchar_t *tail;
    HANDLE job;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = 127;

    if (!inner_path(inner, 32768)) {
        fprintf(stderr, "agentlink launch: could not resolve the Burrito executable\n");
        return 127;
    }

    tail = skip_argv0(GetCommandLineW());

    if (!build_command(command, 32768, inner, tail)) {
        fprintf(stderr, "agentlink launch: command line is too long\n");
        return 127;
    }

    job = CreateJobObjectW(NULL, NULL);

    if (!job) {
        fprintf(stderr, "agentlink launch: CreateJobObject failed %lu\n", GetLastError());
        return 127;
    }

    ZeroMemory(&info, sizeof info);
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof info)) {
        fprintf(stderr, "agentlink launch: SetInformationJobObject failed %lu\n", GetLastError());
        CloseHandle(job);
        return 127;
    }

    ZeroMemory(&startup, sizeof startup);
    startup.cb = sizeof startup;
    ZeroMemory(&process, sizeof process);

    if (!CreateProcessW(inner, command, NULL, NULL, TRUE, CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP,
                         NULL, NULL, &startup, &process)) {
        fprintf(stderr, "agentlink launch: CreateProcess failed %lu\n", GetLastError());
        CloseHandle(job);
        return 127;
    }

    if (!AssignProcessToJobObject(job, process.hProcess)) {
        fprintf(stderr, "agentlink launch: AssignProcessToJobObject failed %lu\n", GetLastError());
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        return 127;
    }

    child_pid = process.dwProcessId;
    SetConsoleCtrlHandler(on_console, TRUE);
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);

    {
        int forced = 0;
        ULONGLONG grace_from = 0;

        for (;;) {
            DWORD wait = WaitForSingleObject(process.hProcess, 50);

            if (wait == WAIT_OBJECT_0) {
                if (forced || !GetExitCodeProcess(process.hProcess, &code)) {
                    code = 1;
                }

                break;
            }

            if (InterlockedCompareExchange(&signaled, 0, 0) == 1) {
                ULONGLONG now = GetTickCount64();

                if (grace_from == 0) {
                    grace_from = now;
                }

                if (!forced && now - grace_from >= 2000) {
                    TerminateJobObject(job, 1);
                    forced = 1;
                }

                if (forced && now - grace_from >= 4000) {
                    code = 1;
                    break;
                }
            }
        }
    }

    CloseHandle(process.hProcess);
    CloseHandle(job);
    return (int)code;
}
