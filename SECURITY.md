# Security policy

## Reporting

Report vulnerabilities through GitHub → **Security** → **Advisories** → **Report a vulnerability** on `MadUTXO/MadUTXO-Umbrel-App-Store`. If advisories are unavailable, open a normal issue without exploit detail and say a private report follows.

Include the app, version, image digest, Umbrel/umbrelOS version, reproduction and impact. Do not include onion addresses, tokens or wallet material in public issues.

## Scope

- The five app packages in this store, their compose files, Dockerfiles, hooks, routers and CI.
- Upstream bugs only when our packaging makes the impact worse; otherwise report upstream.

Not in scope: umbrelOS itself, the Umbrel app store, upstream projects' own infrastructure.

## Handling

- Acknowledgement is best effort; this is a volunteer community store with no bounty.
- Fixes ship as a new version through the normal release flow and are recorded in `reports/madutxo/security-findings.md`.
- Status vocabulary: `confirmed affected` · `potentially affected` · `not affected by this vulnerability` · `fixed` (verified) · `unknown — verification required`.
