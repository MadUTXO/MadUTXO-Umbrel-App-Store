# MadUTXO Community App Store

A community-managed app store for Umbrel. Add this repository to your Umbrel to install other community-developed apps.

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
