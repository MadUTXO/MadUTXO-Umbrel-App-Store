# Community Umbrel App Store

A community-managed app store for Umbrel. Add this repository to your Umbrel to install Nostr VPN and other community-developed apps.

## How to Add This App Store to Your Umbrel

1. **Access your Umbrel via SSH:**
   ```bash
   ssh umbrel@umbrel.local
   ```

2. **Edit the app store configuration:**
   ```bash
   sudo nano /home/umbrel/umbrel/dashboard/.env
   ```

3. **Add this line to include the community repo:**
   ```
   APP_STORE_REPOSITORIES=unauthenticated=https://github.com/MadUTXO/community-umbrel-apps
   ```

4. **Restart Umbrel:**
   ```bash
   cd ~/umbrel
   ./scripts/stop
   ./scripts/start
   ```

5. **Access your Umbrel dashboard** - the community apps should now be available!

## Available Apps

### Nostr VPN
A Tailscale-style mesh VPN powered by Nostr for peer discovery and signaling, with WireGuard for the encrypted data plane.

**Features:**
- Nostr-based peer discovery and signaling
- WireGuard encryption
- NAT traversal support
- Exit node support
- MagicDNS support
- Peer-to-peer mesh networking

**Requirements:**
- Host network mode (required for VPN)
- NET_ADMIN capability
- /dev/net/tun device access

## Contributing

To add your own apps to this community store:

1. Fork this repository
2. Add your app in a new folder (follow the umbrel-apps structure)
3. Submit a pull request

## Support

For issues with Nostr VPN, visit: https://github.com/mmalmi/nostr-vpn/issues

For Umbrel community app store questions, open an issue in this repository.