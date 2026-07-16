# Brainstorm brief — per-device full-proxy: the FULL_PROXY_SOURCES band

Date: 2026-07-16 · Mode: greenfield (`/brainstorm`) · Epic: `per-device-full-proxy`
Depends on: `group-model-streamline.md` (this design targets the `Proxy Mode` /
`<Country> Auto` graph that epic ships; this epic drains after that release is
NAS-validated).

## Idea

Keep the current deployment exactly as is — DHCP hands mihomo out as the LAN default
gateway + DNS, `mode: rule` splits CN→direct / foreign→proxy for everyone — but let a
**few named devices send ALL their traffic through the proxy**. The owner asked:
does this need a second set of (2) containers, or can one instance do it?
**Hard requirement added mid-session**: switching a device between rule mode and
full-proxy must be a **router-console-only gesture — never a container restart or a
NAS-side edit per change**.

## The second-container evaluation (the elaboration asked for)

**Verdict: no second container set. One instance does it natively.** mihomo sits on a
macvlan IP with no NAT in front, so forwarded client packets arrive with their
original LAN source addresses — `SRC-IP-CIDR` is a first-class rule match, and a
handful of rendered rule lines gives per-device policy on the existing dataplane.

Options weighed (dimension fan-out + verification pass, mihomo wiki/source-verified):

| Option | Verdict |
|---|---|
| **A. SRC-IP band rule on the existing instance** | **Chosen** (DEC-1). Zero new containers/IPs/probes; reuses the COUNTRY_GROUPS validate+splice renderer pattern; unset knob = byte-identical render. |
| **B. Second mihomo(+dashboard) pair, match-all, second macvlan IP** | Rejected. Doubles the privileged TUN container, the provider fetch + health probes against the airport (throttle risk), cache.db, and upgrade drift; needs a second Nimbus CIDR; the repo's single-container assumption (MIHOMO_CONTAINER in lib/compose.sh:6, auto-update exact-match image mapping, doctor/seed/validate plumbing) all need a second-instance story (~3-4× test-infra cost). And it doesn't even deliver the switch gesture: stock UniFi **cannot** point individual clients at a different gateway (verified below), so devices would need manual static config anyway. The only thing B can do that A cannot is per-source DNS policy (mihomo's `dns:` block is global; nameserver-policy keys are domain patterns, never source IPs) — a hostname-visibility asymmetry, not a traffic leak, and not worth a second dataplane. |
| **C. SUB-RULE tree keyed on source IP** | Rejected. Buys nothing over N flat SRC-IP lines for "N sources → one group"; no-match fallthrough semantics are undocumented (risky in a leak-sensitive path); more renderer surface. |
| **D. Inbound-differentiated routing (listener `proxy:` override / IN-NAME)** | Rejected as the mechanism (only proxy-capable clients participate — phones/TVs route via the gateway and never touch a proxy port). Noted as a possible later opt-in "full-proxy port" for laptops. |
| **E. Second gateway IP on the SAME container (2nd macvlan iface + TPROXY diversion into a listener with `proxy:` override)** | Rejected. Architecturally sound but gateway choice exists only as the L2 next-hop MAC — distinguishing requires separate interfaces plus mangle-PREROUTING TPROXY plumbing gated on unverified Synology kernel modules (xt_TPROXY), and nft-backed iptables is known-broken on this DSM (the reason TUN auto-redirect ships OFF). |
| **F. Full-proxy VLAN + per-client Virtual Network Override** | Viable but heavy: new VLAN/subnet + trunk config, a second VLAN-tagged macvlan attachment on the OVS-backed NAS, second Nimbus CIDR; wired-client VNO is UniFi-version-dependent. The band (option A) delivers the same console-only gesture with zero infrastructure. |

## Dimensions (verification-pass findings, 2026-07-16)

### UniFi steering (why the band, not a gateway flip)

- **Per-client DHCP gateway override does not exist in stock UniFi** (through
  Network 9.x): gateway/DNS are per-network DHCP settings; a Fixed IP reservation
  pins only the address. The literal "change the device's DHCP gateway" gesture is
  impossible per-device without a second VLAN.
- **Per-client Fixed-IP reservation IS native**: Client → Settings → Use Fixed IP
  Address. Changing it is the equivalent per-device console gesture.
- Adoption: the device picks up a changed reservation at lease renewal or reconnect —
  use the console **Reconnect** kick (WiFi) or reboot the device.

### mihomo runtime (why no restart is ever needed)

- `PUT /configs` hot-reloads the full config in-process (`executor.ApplyConfig`):
  rules replace immediately for new connections; TUN device survives when the tun
  section is unchanged; selector pins survive via store-selected; providers re-init
  from on-disk cache (no refetch). `?force=true` only gates port-listener
  recreation. `DELETE /connections` re-matches established flows. (Relevant for
  band-value changes; routine mode switches never touch the NAS at all.)
- `PATCH /rules/disable` (mihomo ≥ Jan 2026) can flip pre-staged rules by index at
  runtime — ephemeral (lost on reload/restart) and index-addressed; noted, not used.
- Under fake-ip, the node resolves band devices' domains **remotely** — CN domains
  correctly ride the tunnel with no domestic-resolver leak; DNS needs no change.
- **UDP caveat (wiki-verified)**: a UDP flow whose node lacks UDP support *falls
  through the SRC rule to later rules* — a potential silent-DIRECT path for QUIC if
  airport nodes lack UDP relay. See deferred DEC-A.

## Decisions

- **DEC-1 — Full-proxy IP band + reservation flip.** New `.env` knob
  `FULL_PROXY_SOURCES` (comma-separated IPv4 addresses/CIDRs; intended use: one
  small reserved band, e.g. a /28 slice of the LAN) renders static
  `SRC-IP-CIDR,<entry>,Full Proxy` lines once. Switching a device's mode = UniFi
  console: move its Fixed-IP reservation into/out of the band + Reconnect. Zero NAS
  touch, zero restart; old flows die naturally because the device changes IP.
- **DEC-2 — Strict full-proxy.** Band rules sit immediately AFTER
  `GEOIP,LAN,DIRECT,no-resolve` and BEFORE the streaming/CN rules: everything except
  LAN destinations rides the proxy — including streaming (ignores Streaming Sites
  pins) and CN sites (overseas exit; CN apps/banking on band devices may geo-block —
  documented, accepted). LAN stays DIRECT (printers/NAS reachable; routed RFC1918
  must never tunnel — the Delivery-Optimization incident rationale).
- **DEC-3 — Dedicated fail-closed `Full Proxy` group.** Fenced select group,
  renders only when the knob is set: members `[Proxy Mode, <country autos>, REJECT]`
  — **no DIRECT** (a band device can never be silently un-proxied; REJECT is the
  kill switch), default `Proxy Mode` (follows the household pick, independently
  steerable per-country from the dashboard). Select type = zero probe traffic.
  Name joins the reserved lists (already reserved by the group-model-streamline epic).

### Deferred decision points (decided at execution)

- **DEC-A — QUIC/UDP-block companion knob**: default = ship without; the doctor
  flags UDP flows from band sources that matched a later rule (the fallthrough
  leak signal). Add an opt-in block knob only if the airport's UDP proves unreliable.
- **DEC-B — validate_release end-to-end probe**: default = automated macvlan probe
  container gated behind `--probe-ip <spare-ip>` (owner-supplied), falling back to a
  B3-style manual prompt when unset.

### Pre-decided constraints

- Knob validation fail-closed, mirroring COUNTRY_GROUPS error classes: IPv4/CIDR
  only (reject IPv6 entries with a pointer to the ipv6_bypass reality, reject
  hostnames, octet/prefix range checks, no backticks, no empty/duplicate entries);
  bare IP normalizes to /32; empty/unset knob renders **byte-identical** (feature
  fully additive; upgrade-safe).
- Doctor gains a `full_proxy` check: (a) static parity — rendered SRC-IP lines vs
  the knob (stale-render pattern); (b) runtime — `/connections` scan flagging any
  non-LAN flow from a band source whose chain lacks `Full Proxy`; the check
  references `ipv6_bypass` (the guarantee only holds with no routable LAN IPv6).
- Docs must state: DHCP fixed-IP reservation is a prerequisite (the gateway does not
  control leases); CN apps on band devices see overseas exits; the band value in
  `.env.example` uses placeholder addresses only (CLAUDE.md no-real-addresses rule).
- New CI: render_check.py section (knob classes, splice position, inertness) + a
  hermetic `full_proxy` doctor suite on the proxy_groups_check.sh PATH-stub
  template; no new CI steps (parity rule satisfied by extending existing blocks).

## Verification gate

Same full gate as every epic (docs/development.md:235-284, alpine-adjudicated sh suites)
plus this epic's additions: the new `full_proxy_check.sh` hermetic suite joins the
dsm-shell block (CI + local-mirror parity in the same change) and the DEC-B
validate_release helpers join `--self-test`. Verbatim commands live in issue #46.

## Work breakdown

One issue (feature is additive and self-contained):

1. `feat(routing): full-proxy IP band — FULL_PROXY_SOURCES knob + Full Proxy group`
   — renderer knob + fenced group + `{{FULL_PROXY_RULES}}` splice, doctor check,
   CI coverage, docs EN/zh/.txt + `.env.example`. Epic `per-device-full-proxy`,
   Sequence 10, no Next. Drains after `group-model-streamline` ships and validates.
