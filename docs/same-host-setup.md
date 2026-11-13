# Running the bridge on the same host as Bitcoin Core

This guide sets up a Castor bridge and a Bitcoin Core full node on one server, each running as its
own user:

| Service | User | Listens on |
| --- | --- | --- |
| Bitcoin Core | `noderunner` | the host's **IPv6** address, port 8333 |
| Castor bridge | `bridgerunner` | the host's **IPv4** address, port 8333 |

The examples use mainnet and the documentation addresses `203.0.113.10` (IPv4) and `2001:db8::1`
(IPv6). Replace them with your server's addresses.

## Why two addresses

Utreexo nodes find bridges by IP address and connect to the network's default P2P port, 8333 on
mainnet. To be reachable without any client configuration, the bridge must listen on 8333.

Bitcoin Core also listens on 8333 by default, and two programs can't listen on the same address and
port. Most servers have both an IPv4 and an IPv6 address, so each program can take port 8333 on a
different address:

```
                     server
                    +------------------------------------------+
 Utreexo nodes ---> | 203.0.113.10:8333   -> Castor bridge     |
                    |                            |  RPC        |
                    |                            v  127.0.0.1  |
 Bitcoin peers ---> | [2001:db8::1]:8333  -> Bitcoin Core      |
                    +------------------------------------------+
```

Castor talks to Core over RPC on `127.0.0.1:8332`, so this split only affects inbound P2P traffic.

### Trade-offs

- **Bitcoin Core** accepts inbound peers only over IPv6. Its outbound connections and initial sync
  still use IPv4 as usual, because `bind` only controls listening.
- **The bridge** is reachable only over IPv4, so IPv6-only Utreexo nodes can't connect.

If your server has no global IPv6 address, or you want both programs reachable over both address
families, see [Alternatives](#alternatives).

## Requirements

- A Linux server with a public IPv4 and a global IPv6 address. Check for IPv6 with:

  ```bash
  ip -6 addr show scope global
  # 2: eth0: ...
  #     inet6 2001:db8::1/64 scope global
  ```

  A line with `scope global` means the server has a public IPv6 address.
- Bitcoin Core, fully synced, with `txindex=1` and no pruning.
- Castor built from source (see the [README](../README.md)).
- Enough RAM and disk for both. See the README's requirements for the bridge.

## 1. Users and permissions

Create the two users if they don't exist:

```bash
sudo useradd --system --create-home noderunner
sudo useradd --system --create-home bridgerunner
```

The bridge authenticates to Core's RPC with Core's cookie file, so `bridgerunner` needs to read it.
Add `bridgerunner` to Core's group:

```bash
sudo usermod -aG noderunner bridgerunner
```

Log in again (or restart the bridge service) for the new group to take effect.

`bridgerunner` also needs to reach Core's datadir during the bootstrap (step 4). If it lives under
`/home/noderunner`, make sure the home directory is group-accessible (`chmod 750 /home/noderunner`);
some distributions create home directories with mode `700`.

## 2. Configure Bitcoin Core

`bitcoin.conf` for `noderunner`:

```ini
# Network
chain=main

# The bridge needs full blocks and a transaction index
prune=0
txindex=1

# Listen for P2P only on the IPv6 address; IPv4 port 8333 is the bridge's
listen=1
bind=[2001:db8::1]:8333

# RPC, local only
server=1
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=8332

# Cookie readable by Core's group, so the bridge user can authenticate
rpccookiefile=/run/bitcoin-rpc/.cookie
rpccookieperms=group
```

Notes:

- Use the exact IPv6 address in `bind` rather than `[::]`. Binding `[::]` also works, because Core
  marks its IPv6 socket as IPv6-only, but the explicit address is clearer.
- The cookie directory must be accessible to the group. If Core runs under systemd, create it with
  `RuntimeDirectory=bitcoin-rpc` and `RuntimeDirectoryMode=0750` in the bitcoind unit.

Restart Core to apply the changes.

## 3. Configure the bridge

As `bridgerunner`, create `~/.config/castor/castor.env`:

```bash
NETWORK=bitcoin
# noderunner's datadir, as passed to Core's -datadir. Only needed for bootstrap.
BITCOIN_CORE_DATADIR=/home/noderunner/.bitcoin
BITCOIN_CORE_COOKIE_FILE=/run/bitcoin-rpc/.cookie
BITCOIN_CORE_RPC_URL=127.0.0.1:8332
# Listen on IPv4 only, on the default port
P2P_HOST=0.0.0.0
P2P_PORT=8333
```

`P2P_HOST=0.0.0.0` binds every IPv4 address and no IPv6 address. That is the bridge's default, so
it doesn't clash with Core's IPv6 listener.

## 4. Bootstrap the bridge

The bootstrap reads Core's block files and databases directly, so it has two extra requirements:

- **Bitcoin Core must be stopped** while it runs, because Core's databases allow only one process
  at a time.
- **`bridgerunner` needs write access** to Core's datadir, because opening Core's databases
  creates lock and log files.

The bootstrap runs once. Afterwards, the bridge only uses RPC, and Core keeps running.

```bash
# As an administrator: stop Core and allow the group to write to its datadir
sudo systemctl stop bitcoind
sudo chmod -R g+w /home/noderunner/.bitcoin

# As bridgerunner
contrib/castor.sh hints    # downloads the mainnet hintsfile
contrib/castor.sh build    # builds the forest; this takes a long time

# As an administrator: restore permissions and start Core again
sudo chmod -R g-w /home/noderunner/.bitcoin
sudo systemctl start bitcoind
```

If you'd rather not grant write access to Core's datadir, copy it while Core is stopped and point
`BITCOIN_CORE_DATADIR` at the copy for the bootstrap.

## 5. Check and start

As `bridgerunner`:

```bash
contrib/castor.sh check
contrib/castor.sh start
contrib/castor.sh status
contrib/castor.sh logs      # Ctrl-C to stop following
```

`check` verifies that the bridge can read the cookie, reach Core's RPC, find `txindex` enabled and
pruning disabled, and that port 8333 is free. If it reports port 8333 as in use before you start the
bridge, Core is still listening on IPv4: recheck the `bind` line and restart Core.

## 6. Test the setup

### On the server

Both programs should listen on port 8333, on different addresses:

```bash
sudo ss -ltnp 'sport = :8333'
```

Expected output:

```
State  Recv-Q Send-Q  Local Address:Port        Peer Address:Port Process
LISTEN 0      128           0.0.0.0:8333             0.0.0.0:*     users:(("bridge",...))
LISTEN 0      4096    [2001:db8::1]:8333                [::]:*     users:(("bitcoind",...))
```

- `0.0.0.0:8333` owned by `bridge`: the bridge listens on IPv4.
- `[2001:db8::1]:8333` owned by `bitcoind`: Core listens on IPv6.

If `bitcoind` also shows `0.0.0.0:8333`, the `bind` line isn't in effect. If the bridge isn't
listed, check `contrib/castor.sh logs` for a bind error.

### Firewall

Port 8333/TCP must be open for both address families. With `ufw`:

```bash
sudo ufw allow 8333/tcp
sudo ufw status
```

`ufw` applies the rule to IPv6 too when `IPV6=yes` is set in `/etc/default/ufw`. Many hosting
providers also have a separate firewall in their control panel: open 8333/TCP for IPv4 and IPv6
there as well.

### From another machine

Test from outside the server, because local connections bypass the firewall and the provider's
network:

```bash
# IPv4 → should connect to the bridge
nc -vz 203.0.113.10 8333

# IPv6 → should connect to Bitcoin Core (needs a client machine with IPv6)
nc -vz -6 2001:db8::1 8333
```

A `succeeded` or `open` result means the port is reachable. A timeout usually means a firewall is
blocking it; `connection refused` means nothing is listening on that address.

`nc` only proves the TCP port is open. To confirm which program answered, connect to the IPv6
address with a Bitcoin node, for example `bitcoin-cli addnode "[2001:db8::1]:8333" onetry` from
another Core node, then check its `getpeerinfo`. For the bridge, configure a Utreexo node such as
Floresta to connect to `203.0.113.10:8333`: the bridge logs connected peers every minute,
for example `Floresta=1`.

### Core keeps its peers

On the server, check that Core still has outbound peers over IPv4 and accepts inbound peers over
IPv6:

```bash
sudo -u noderunner bitcoin-cli -netinfo
```

Outbound connections should appear as usual. Inbound peers, once they arrive, connect over IPv6.

## Alternatives

| Option | Bridge reachable on | Core inbound |
| --- | --- | --- |
| IPv6/IPv4 split (this guide) | IPv4, port 8333 | IPv6 only |
| Core on another port | IPv4, port 8333 | IPv4 and IPv6, port 8335 |
| Core with `listen=0` | IPv4, port 8333 | none |

- **Core on another port.** Use this when the server has no IPv6 address. Replace the `bind` line
  in `bitcoin.conf` with `port=8335`. Don't use 8334: Core listens there for incoming Tor
  connections by default. Core peers have connected to non-default ports since Bitcoin Core 23.
- **`listen=0`.** Use this if the node exists only to feed the bridge. Core makes outbound
  connections but serves no inbound peers.

In every case the bridge stays on port 8333. The bridge currently listens on a single address
(`P2P_HOST`), so it can't serve IPv4 and IPv6 at the same time.
