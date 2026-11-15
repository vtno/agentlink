# Reconnect and keepalive

The uplink treats a dead network and a rejected hello as different problems. A dead network is worth another dial. A rejected hello is not, until something that the hello depends on has changed.

A host that vanishes can leave the TCP connection half-open. The local kernel still reports the socket as up. The uplink, `agentlink connect`, and the plane each send a WebSocket ping. A missed pong closes that socket. The dial treats the close as a failed dial. The plane exits the socket process. An agent socket exit deletes the runtime. A client socket exit runs the client disconnect path.

## Retry

The dial timeout is 3 seconds. A failed dial, and any close that is not one of the permanent codes, waits 500 milliseconds and dials again. The wait is not an environment variable. Callers inside the VM can pass a longer backoff. A value under 50 milliseconds is raised to 50 so a refused port cannot spin.

Before that retry, the uplink reads the link file again. A new `plane_url` is used for the next dial. A missing file stops the relay instead of dialing.

The plane upgrades `/acp` and `/agent` with an idle timeout of infinity. That timeout does not close a socket that has sent no ACP traffic. The ping is a separate timer. A pong keeps the socket open. A missed pong closes it. A tunnel or a proxy can still drop a socket when that hop has its own idle limit. The 500 millisecond retry brings the uplink back. The same relay's instance id lets the plane take the new socket and drop the old session state. In-flight client requests fail with `runtime reconnected`.

## Keepalive

`AgentLink.Transport.WebSocket` is the dial for the uplink and for `agentlink connect`. After the socket is up, the first ping waits one interval. Each later ping is one interval after the tick that sent the previous ping. The ping payload is empty. The default interval is 30000 milliseconds.

The plane answers that ping with a pong. The Mint client also answers a ping from the peer with a pong. A pong clears the deadline. A deadline that is already armed stays where it is. A later ping does not postpone it.

If no pong arrives within the pong timeout, the transport closes the socket. It reports code 1006 and the reason `keepalive pong timeout`. The log line is `transport keepalive expired`. The default pong timeout is 10000 milliseconds. Code 1006 is a local status. The transport does not put that code in a close frame.

`AgentLink.AgentSocket` and `AgentLink.ClientSocket` send their own ping with the same interval and the same pong timeout. The first ping waits one interval. Each later ping is one interval after the tick that sent the previous ping. The payload is empty. A pong clears the deadline. A deadline that is already armed stays where it is. If no pong arrives, the socket stops. The close code is 1001 and the reason is `keepalive pong timeout`. The log line is `plane keepalive expired`. The process exits without waiting for the peer to finish the close handshake. The registry and the plane see that exit at once. An agent socket exit deletes the runtime. In-flight requests and queued prompts fail with `runtime disconnected`. A client socket exit drops that client's sessions and queued prompts. Each plane timer message carries the token of the timer that armed it. A message is handled only when that token is still current.

A path that dies at the moment a ping is sent is noticed after the pong timeout. A path that dies just after a pong, or before the first ping, is noticed after one interval plus the pong timeout. With the defaults, those waits are 10 seconds and 40 seconds.

The uplink treats a missed pong on the dial like any other close that is not permanent. The transport dials again after the backoff. `agentlink connect` dials again only before a runtime is selected. During `runtime/list` or `runtime/select`, the client relay sends that request again. After `runtime/select` succeeds, the client relay calls `hold/1`, which cancels the next dial, and then stops with `plane closed`. The process exits with status 1.

Each timer message carries the Mint request ref of the socket that armed it. A message is handled only when that ref is still the open socket.

On Linux the dial sets `TCP_USER_TIMEOUT` to the interval plus the pong timeout. The value is not set above 2147483647 milliseconds. The kernel then aborts a write that stays unacknowledged. That limit covers a ping stuck in retransmission. The pong timer covers a socket that stays quiet. Other operating systems leave the option unset. The dial does not enable `SO_KEEPALIVE`. On Linux the idle time for that flag is `tcp_keepalive_time`, and the default is 7200 seconds. The plane sockets do not set `TCP_USER_TIMEOUT`.

The dial reads a start option, then an environment variable, then the application env, then the defaults above. A plane socket reads an `init/1` option, then the same environment variable, then the same application env, then the same defaults. [Configuration](../reference/configuration.md) lists that order. [Set the keepalive](../how-to/set-the-keepalive.md) is how you change the two durations.

## Parking

Close codes 4001, 4002, 4003, and 4004 park the uplink. A parked transport does not dial again until the relay asks it to. Another dial of a name clash would get the same close. The uplink waits until `name` or `plane_url` changes, or until the process is restarted. The file watch runs every 1000 milliseconds.

Code 4002 is the exception inside that rule. The instance id is generated in the VM and is not stored in the link file. A new name would still present the same oversized id, so the watch does not redial. Restart the VM.

A change to `label` or `program` updates a live uplink's hello on the next reconnect, but it does not wake a parked one. The plane would still be rejecting the name, the id, or the policy.

The client relay is stricter after it has selected a runtime. A closed plane socket during `runtime/list` or `runtime/select` sends that request again. After `runtime/select` succeeds, a closed socket stops the client relay with `plane closed`. The editor sees the command exit with status 1 and can start it again. Holding the client open across a plane restart would deliver ACP into a session the plane has already dropped.

## TLS

`wss` and `https` dial TLS. `ws` and `http` stay plain. AgentLink does not pass CA options. Mint 1.11 calls `:public_key.cacerts_get/0`. That function loads the operating system trust store. If that call raises, Mint looks for the CAStore package, and AgentLink does not depend on CAStore. A certificate failure is a failed dial, so it uses the 500 millisecond retry. [Reach a plane on another machine](../how-to/reach-another-machine.md) is where you choose the URL.
