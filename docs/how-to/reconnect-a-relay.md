# Reconnect a relay

A dropped dial retries on its own. A rejected hello does not.

## Let a dropped dial retry

If the plane or the path to it is briefly down, leave the relay running. The uplink dials again after 500 milliseconds. The plane log shows `Uplink connected:` and the link name when the hello is accepted.

A missed pong is one of those drops. The transport log contains `transport keepalive expired`. The socket is reported as code 1006 with the reason `keepalive pong timeout`. [Set the keepalive](set-the-keepalive.md) changes the interval and the timeout. [Reconnect and keepalive](../explanation/reconnect.md) describes the timer.

The plane does not close an idle socket for inactivity. The uplink and `agentlink connect` answer a ping from the peer with a pong.

After `runtime/select` succeeds, `agentlink connect` does not dial again. A closed plane socket stops that process with `plane closed`, and the status is 1. Start the command again from the editor.

## Release a parked name

A permanent rejection parks the uplink. The relay log includes `uplink rejected` and a reason. The close codes are in [Client and uplink protocol](../reference/protocol.md).

When the reason says the name is in use, stop the other relay that holds that name, or edit `name` in the link file. `Lab Box` and `lab-box` are the same slug, so they collide. After a change to `name` or to `plane_url`, the parked uplink dials again. You can also restart the relay.

When the reason says the link name must be a short slug, or that the uplink is not allowed, the same rule applies. Change `name` or `plane_url`, or restart after the plane operator allows the uplink.

When the reason says the instance id is too long, editing the link file does not help. The id is not in the file. Restart the relay after the id is fixed. A normal start generates an id of 22 characters, which is under the 128 byte limit.

A change to only `label` or `program` does not wake a parked uplink. A change to only `command` or `args` does not either. Restart the relay to open a new `command`.
