# Structs

Use a struct when the shape is ours and more than one function relies on it. GenServer and WebSock state is a struct. `AgentLink.Link` is a struct because `Uplink` reads it.

Keep a map at a boundary we do not own. Build our struct from the fields we need. ACP messages, a pending call, and a fan-out answer stay maps: they are built in one place, or the other side defines the keys.
