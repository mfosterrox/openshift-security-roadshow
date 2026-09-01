# Splunk setup — UI guide

Vendored from [rhacs-demo/splunk-setup](https://github.com/mfosterrox/rhacs-demo/tree/main/splunk-setup) for OpenShift Security Roadshow lab **201-06**.

Roadshow extras (not in upstream):

* `install.sh` — `setup.sh` then `configure-openshift-audit.sh` (`SPLUNK_RUN_CLEAN_FIRST` defaults to `false`)
* `configure-openshift-audit.sh` — HEC token + `ClusterLogForwarder` for OpenShift API audit
* `push-recent-audit.sh` — seed Splunk from `oc adm node-logs` while the collector starts
* `cleanup-openshift-audit.sh` — remove the forwarder (called from `clean.sh`)

---

# Splunk setup — UI guide

After `setup.sh` or `install.sh` completes, Splunk Web includes the **RHACS Security Operations Dashboard** automatically. The setup script imports the Dashboard Studio JSON via REST, shares it globally, and sets it as the **home dashboard** for the `admin` user (and the default for new users).

## Splunk Web access

From the setup summary, or from the cluster:

```bash
oc get route splunk-web -n splunk -o jsonpath='https://{.spec.host}{"\n"}'
```

Sign in as `admin` with the password printed at the end of setup (or from `secret/splunk-auth` in the `splunk` namespace).

## RHACS Security Operations Dashboard

### Automatic deploy (default)

`setup.sh` runs after RHACS integration and:

1. Imports `dashboards/openshift-security-visualization.json` into the **Search & Reporting** app (`search`).
2. Saves it as view id **`rhacs_security_operations`** (title: **RHACS Security Operations Dashboard**).
3. Sets **global read** permissions so all users can open it.
4. Sets it as the **Splunk home dashboard** for `admin` and as the default for new users.

After login, Splunk opens this dashboard on the home page. You can also open it from **Dashboards** in the left navigation.

Direct path (after login):

```text
/app/search/dashboard/rhacs_security_operations
```

Skip auto-deploy:

```bash
SPLUNK_DEPLOY_RHACS_DASHBOARD=false ./setup.sh
```

Re-deploy after editing the JSON (existing cluster):

```bash
./setup.sh
```

Or set only the dashboard step if Splunk is already running (requires `oc` access to the Splunk pod):

```bash
SPLUNK_RUN_CLEAN_FIRST=false SPLUNK_INSTALL_RHACS_ADDON=false \
  SPLUNK_INTEGRATE_WITH_RHACS=false SPLUNK_CONFIGURE_ADDON_INPUTS=false \
  ./setup.sh
```

### Favorites

Splunk’s **Favorites** list (star icon on a dashboard) is stored per user in Splunk’s internal KV store and is not exposed via a supported REST API. Setting the dashboard as the **home dashboard** gives the same landing experience after login. To also star it manually: open the dashboard → click the **star** icon once.

### Manual import (fallback)

If auto-deploy was skipped or failed:

1. In Splunk Web, go to **Dashboards** → **Create** → **Dashboard Studio**.
2. Open the **…** menu → **Import** (or paste the JSON definition).
3. Use `dashboards/openshift-security-visualization.json` from this directory.
4. Save as **RHACS Security Operations Dashboard**.
5. **Home** → **Choose a home dashboard** → select this dashboard.

## Set Global Time Range

The dashboard includes a **Global Time Range** control at the top. It defaults to **Last 24 hours** (`-24h@h,now`). For demos and active clusters, use a shorter window so panels reflect recent RHACS events.

1. On the dashboard, click the **Global Time Range** picker (top of the page).
2. Choose a preset:
   - **Last 15 minutes** — quick sanity check after RHACS integration
   - **Last 1 hour** — recommended for live demos
   - **Last 4 hours** — longer session or slower compliance refresh
3. Confirm the picker shows your selection; all dashboard panels use this range via the `global_time` token.

**Tip:** If charts look empty but RHACS is sending data, widen the range briefly, then return to **Last 1 hour** once events appear.

## Verify data in Search

Before or after opening the dashboard, confirm events are indexed:

1. Open the **Search** app (Splunk home → **Search & Reporting**, or **Apps** → **Search & Reporting**).
2. Set the time picker (upper right) to **Last 1 hour** (or match the dashboard range).
3. Run:

```spl
index=* sourcetype="stackrox-*" | stats count by sourcetype
```

You should see non-zero counts after the RHACS Splunk add-on inputs have run. If counts are 0, check **Settings** → **Apps** → **Manage Apps** for **Red Hat Advanced Cluster Security** (TA-stackrox) and verify RHACS notifier integration from `setup.sh`.

## Related files

| File | Purpose |
|------|---------|
| `setup.sh` | Deploy Splunk on OpenShift, install TA-stackrox, integrate RHACS, import dashboard |
| `install.sh` | Wrapper for `setup.sh` (used by `install-all-setup.sh`) |
| `clean.sh` | Tear down Splunk resources |
| `lib/build-dashboard-xml.py` | Wraps Dashboard Studio JSON for Splunk REST import |
| `dashboards/openshift-security-visualization.json` | Dashboard Studio export (source for auto-deploy) |

## Environment variables (dashboard)

| Variable | Default | Description |
|----------|---------|-------------|
| `SPLUNK_DEPLOY_RHACS_DASHBOARD` | `true` | Import dashboard via REST |
| `SPLUNK_RHACS_DASHBOARD_FILE` | `./dashboards/openshift-security-visualization.json` | JSON source file |
| `SPLUNK_RHACS_DASHBOARD_ID` | `rhacs_security_operations` | Splunk view name / URL id |
| `SPLUNK_RHACS_DASHBOARD_APP` | `search` | Splunk app context |
| `SPLUNK_RHACS_DASHBOARD_HOME` | `true` | Set as home dashboard for admin + new users |
