# Architecture

AgentLink splits one ACP session across three processes so the editor and the agent do not have to run on the same machine. The agent stays next to its files and its credentials. The editor can be anywhere that can open a WebSocket to the plane.

## Plane

The plane is the process that accepts sockets. It listens on `127.0.0.1` and applies the access policy. One plane keeps one live uplink for each link name. A second relay that dials with the same name is rejected while the first relay is connected.

The plane is not an agent and it is not an editor. It forwards ACP, remembers session updates, and answers the session methods that have to work after a client disconnects. [Protocol paths](protocol.md) explains which methods those are.

## Relay

The relay opens one local agent and dials the plane. The dialer is the uplink. The link file names the agent command and the plane URL. `program` in that file is a label stored for status. It does not select the Elixir module or the command.

ACP on the agent pipe is one JSON object per line. The uplink sends one JSON object in each WebSocket text frame. The relay writes one JSON object and a newline to the agent's standard input.

`agentlink` with no subcommand starts the plane and the relay in one VM. `agentlink plane` and `agentlink relay` split them onto two machines. They still meet on the agent WebSocket.

## Client

A client is a program already connected to the plane. `agentlink connect` is one way to be that program. An editor runs it and speaks ACP on standard input and standard output. The client relay dials `/acp`, selects a runtime, and copies later ACP messages.

You can also open `/acp` yourself. The plane does not care which program dialed, as long as the token is accepted.

## Names in the code

The module map for contributors is the [Glossary](../glossary.md). The rules for struct fields are in [Structs](../structs.md). The rules for module names are in [Names](../names.md).
