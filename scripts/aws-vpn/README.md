# aws-vpn

Connect to an **AWS Client VPN** (SAML / SSO-federated) profile from the
terminal, without opening the GUI AWS VPN Client.

## Commands

| command            | what it does                                        |
|--------------------|-----------------------------------------------------|
| `vpn-up [profile]` | connect (default `ariel-ps`); a browser opens for SSO |
| `vpn-down`         | tear the headless tunnel down                        |
| `vpn-status`       | is a headless tunnel up?                              |
| `awsvpn ...`       | explicit entrypoint (same flags)                     |

```sh
vpn-up            # connect ariel-ps
vpn-up ariel-ps-2 # a different exported profile
vpn-status
vpn-down
```

## How it works

The profile uses **federated (SAML) auth**, so a browser login is required —
there is no stored password. The helper avoids the GUI by reusing what the
official **AWS VPN Client** already installed:

1. its SAML-patched openvpn binary — `acvc-openvpn`
2. the exported profile — `~/.config/AWSVPNClient/OpenVpnConfigs/<profile>`

It then runs the standard AWS SAML handshake (the "samm-git" two-step):

1. **challenge** — connect once with password `ACS::35001`; the endpoint
   answers `AUTH_FAILED` with a `CRV1` challenge containing the IdP login URL.
2. **login** — open that URL in the browser; on success the IdP POSTs the
   `SAMLResponse` to `127.0.0.1:35001`, captured by `bin/aws-saml-capture.py`.
3. **connect** — reconnect for real with password
   `CRV1::<sid>::<SAMLResponse>`; openvpn brings up the tun + routes.

Only step 3 needs root, so `vpn-up` prompts for `sudo` once near the end.

## Requirements

- The **AWS VPN Client** app installed (provides the binary + profile). Import
  a profile once in the GUI so its `.ovpn` lands in `OpenVpnConfigs/`.
- `python3` (system Python is fine).

## Notes / gotchas

- **Don't run both at once.** A GUI tunnel and a headless tunnel to the same
  endpoint fight over routes. `vpn-up` refuses if the GUI client has an active
  tunnel; pass `--force` to override.
- Logs: `~/.config/AWSVPNClient/headless/openvpn.log`.
- The captured SAML token is written only to a `chmod 700` temp dir under
  `~/.config/AWSVPNClient/headless/` and wiped when the connect script exits.
- Reconnecting after the session expires means logging in through the browser
  again — that's inherent to SAML, not a limitation of the script.
