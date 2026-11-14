# Reconnect and keepalive

The uplink treats a dead network and a rejected hello as different problems. A dead network is worth another dial. A rejected hello is not, until something that the hello depends on has changed. There is no setting for a ping interval or a pong timeout.

## Retry

The dial timeout is 3 seconds. A failed dial, and any close that is not one of the permanent codes, waits 500 milliseconds and dials again. The wait is not an environment variable. Callers inside the VM can pass a longer backoff. A value under 50 milliseconds is raised to 50 so a refused port cannot spin.

Before that retry, the uplink reads the link file again. A new `plane_url` is used for the next dial. A missing file stops the relay instead of dialing.

The plane's WebSocket is upgraded with an idle timeout of infinity. An open socket is not closed because it has been quiet. The uplink answers a WebSocket ping with a pong. It does not send pings on a timer. AgentLink does not read `AGENTLINK_WEBSOCKET_PING_INTERVAL` or `AGENTLINK_WEBSOCKET_PONG_TIMEOUT`. Those names are not configuration.

A tunnel or a proxy can still drop a quiet socket when that hop has its own idle limit. The 500 millisecond retry brings the uplink back. The same relay's instance id lets the plane take the new socket and drop the old session state. In-flight client requests fail with `runtime reconnected`.

## Parking

Close codes 4001, 4002, 4003, and 4004 park the uplink. A parked transport does not dial again until the relay asks it to. Another dial of a name clash would get the same close. The uplink waits until `name` or `plane_url` changes, or until the process is restarted. The file watch runs every 1000 milliseconds.

Code 4002 is the exception inside that rule. The instance id is generated in the VM and is not stored in the link file. A new name would still present the same oversized id, so the watch does not redial. Restart the VM.

A change to `label` or `program` updates a live uplink's hello on the next reconnect, but it does not wake a parked one. The plane would still be rejecting the name, the id, or the policy.

The client relay is stricter after it has selected a runtime. A closed plane socket during `runtime/list` or `runtime/select` sends that request again. After `runtime/select` succeeds, a closed socket stops the client relay with `plane closed`. The editor sees the command exit with status 1 and can start it again. Holding the client open across a plane restart would deliver ACP into a session the plane has already dropped.

## TLS

`wss` and `https` dial TLS. `ws` and `http` stay plain. AgentLink does not pass CA options. Mint 1.11 calls `:public_key.cacerts_get/0`. That function loads the operating system trust store. If that call raises, Mint looks for the CAStore package, and AgentLink does not depend on CAStore. A certificate failure is a failed dial, so it uses the 500 millisecond retry. [Reach a plane on another machine](../how-to/reach-another-machine.md) is where you choose the URL.
