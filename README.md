# MadUTXO Community App Store

Add community-made apps to your Umbrel. Simple as that.

## How to Add This Store

### Using the Umbrel Web Interface (Recommended)

1. Open Umbrel in your browser (usually `http://umbrel.local`)
2. Click the **three dots** (⋮) in the top-right corner
3. Select **Community App Stores**
4. Paste this URL in the input field:
   ```
   https://github.com/MadUTXO/MadUTXO-Umbrel-App-Store
   ```
5. Click **Add**
6. Browse your new community store from the App Store

### Using the Terminal

```bash
cd ~/umbrel
sudo ./scripts/app install https://github.com/MadUTXO/MadUTXO-Umbrel-App-Store
```

## Apps

| App | Upstream | License |
|---|---|---|
| Electrs Liquid | `Blockstream/electrs` | MIT |
| LibreTranslate | `LibreTranslate/LibreTranslate` | AGPL-3.0 |
| Routstrd | `Routstr/routstrd-remote` | unknown (no license file found) |
| RustDesk Server | `rustdesk/rustdesk-server` | AGPL-3.0 |
| TorLink | `baairon/torlink` | MIT |

AGPL apps are run as separate services; the packaging files here are MIT.

## Backups, updates and rollback

- Umbrel app-data backups include each app's `/data`. For Routstrd that means the wallet database and the mnemonic — keep backups private and treat them like the wallet.
- Uninstalling deletes app data, including wallets and keys. Back up before uninstalling.
- Updates keep app data. The store ships digest-pinned images; an update is an explicit version bump.
- Rollback: reinstall the previous version from the store history and restore its data from a backup if the update migrated it. Electrs and LibreTranslate reuse their index/data across versions; Routstrd wallet migrations are forward-only, so restore the matching backup.

## Need Help?

Open an issue here if something isn't working or you have questions.

## Important Disclaimer

⚠️ **Please read carefully before adding this store:**

- **Your responsibility**: You install and use these apps at your own risk. This is a community project, not affiliated with Umbrel.

- **Check licenses**: Each app has its own license and terms. Make sure you agree to them before installing.

- **No guarantees**: Apps are provided as-is. We don't guarantee they work perfectly or are secure.

- **Protect your data**: You're in charge of securing your Umbrel and your data. Follow good security practices.

- **No liability**: We can't be held responsible if something goes wrong, you lose data, or anything else happens.

By adding this store and installing apps, you agree to these terms.

---

License: MIT
