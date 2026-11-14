# Reach a plane on another machine

The plane listens only on `127.0.0.1` and only with plain `ws://`. AgentLink does not terminate TLS. Pick one route below, then set `plane_url` in the link file to a URL whose path is `/agent`.

The examples use port `8090`. If the plane was started with `--port`, use that port in the tunnel and in `plane_url`.

Do not publish the plane's listen port. A proxy can log the `?token=` query string. Turn query logging off before you proxy the plane. The uplink sends the token in the `Authorization` header and does not put the token in `plane_url`. [Security model](../explanation/security.md) explains why the listen port stays on localhost.

## Use an ssh tunnel

Use this when you can ssh to the plane and you want no extra software. Run the tunnel on the relay's machine. `plane-host` is the machine that runs the plane.

```sh
ssh -L 8090:127.0.0.1:8090 plane-host
```

Set `plane_url` to `ws://127.0.0.1:8090/agent`.

## Use Tailscale TCP

Use this when both machines are on a tailnet and you want the bytes left as plain WebSocket. Run this on the plane's machine. Raw TCP forwarding does not terminate TLS.

```sh
tailscale serve --tcp 8443 tcp://127.0.0.1:8090
```

Set `plane_url` to `ws://HOST:8443/agent`. Replace `HOST` with the plane's Tailscale host. The Tailscale Serve reference is at <https://tailscale.com/kb/1242/tailscale-serve>.

## Use Tailscale HTTPS

Use this when both machines are on a tailnet and you want Tailscale to terminate TLS. Run this on the plane's machine.

```sh
tailscale serve --https=443 http://127.0.0.1:8090
```

Set `plane_url` to a `wss://` URL whose host is the Tailscale host and whose path is `/agent`.

## Use a TLS reverse proxy

Use this when you have a public name and ports 80 and 443 are reachable. Run Caddy on the plane's machine. Caddy obtains the certificate and proxies the WebSocket upgrade.

```
plane.example.com {
	reverse_proxy 127.0.0.1:8090
}
```

Set `plane_url` to `wss://plane.example.com/agent`.

Another TLS proxy uses the same shape. Forward to `127.0.0.1:8090`, and set `plane_url` to that proxy's `wss://` URL with path `/agent`.

For `wss://` and `https://`, the uplink asks Mint to verify the server certificate. AgentLink does not pass a CA store. Mint 1.11 calls `:public_key.cacerts_get/0`. That function loads the operating system trust store. If the call raises, Mint looks for the CAStore package. AgentLink does not depend on CAStore. [Reconnect and keepalive](../explanation/reconnect.md) describes the dial retry that follows a failed TLS handshake.
