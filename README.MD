# npm-maintenance

A Bash script to quickly toggle a maintenance page on and off across **all** proxy hosts in [Nginx Proxy Manager](https://nginxproxymanager.com/) (NPM) via its REST API. When enabled, every proxy host is redirected to a lightweight `nginx:alpine` container serving a static maintenance page. When disabled, all hosts are restored to their original forwarding targets from an automatic backup — with verbose, timestamped logging throughout.

---

## Features

| Feature | Detail |
|---|---|
| One-command toggle | `./npm-maintenance.sh enable` or `./npm-maintenance.sh disable` |
| Automatic backup | Saves all proxy host forwarding details before switching, restores them cleanly on disable |
| Verbose logging | Timestamped `[INFO]`, `[WARN]`, and `[ERROR]` entries written to log files on the host |
| Preflight checks | Creates missing log files and backup file automatically before each run |
| Safe restore | Backup is only cleared after a fully successful restore; retained on any failure |
| Lightweight maintenance container | Static HTML page served by `nginx:alpine` — no extra dependencies |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `bash` | Script uses `#!/usr/bin/env bash` with `set -euo pipefail` |
| `curl` | Used for all NPM REST API calls |
| `jq` | Used for JSON parsing of API responses |
| Nginx Proxy Manager | Must be running and accessible (default: `http://localhost:81`) |
| Docker / Docker Compose | Required for the maintenance page container |

---

## Repository Structure

```
npm-maintenance/
├── docker/
│   ├── container-snippet-docker-compose.yml   # Snippet to add to an existing Compose file
│   └── example-docker-compose.yml             # Full example with NPM, MariaDB & maintenance container
├── npm-maintenance/
│   ├── index.html                             # Static maintenance page (customise to your style or messaging)
│   └── npm-maintenance.sh                     # Main toggle script
└── LICENSE
```

---

## Setup

### 1. Add the Maintenance Container

If you already have an NPM `docker-compose.yml`, merge in the snippet from `docker/container-snippet-docker-compose.yml`:

```yaml
# --- Maintenance page container ---
maintenance:
  image: nginx:alpine
  restart: unless-stopped
  volumes:
    - ./maintenance:/usr/share/nginx/html:ro
  networks:
    - nginxproxymanager
# ----------------------------------
```

> The container **must** be on the same Docker network as your NPM instance (default network name: `nginxproxymanager`).

If you are starting from scratch, see `docker/example-docker-compose.yml` for a complete working setup including NPM and MariaDB.

### 2. Place the Maintenance Page

Copy `npm-maintenance/index.html` into a `maintenance/` directory alongside your `docker-compose.yml`:

```
./maintenance/index.html
```

The HTML is fully customisable — edit it to match your own style or messaging.

### 3. Configure the Script

Edit the configuration block at the top of `npm-maintenance/npm-maintenance.sh`:

```bash
NPM_URL="http://localhost:81"   # URL of your NPM admin interface
NPM_USER="username"             # NPM admin email/username
NPM_PASS="password"             # NPM admin password
MAINTENANCE_HOST="maintenance"  # Docker service name of the maintenance container
MAINTENANCE_PORT=80             # Port the maintenance container listens on
MAINTENANCE_SCHEME="http"       # Scheme used to reach the maintenance container
```

### 4. Make the Script Executable

```bash
chmod +x npm-maintenance.sh
```

---

## Usage

```bash
# Redirect all proxy hosts to the maintenance page
./npm-maintenance.sh enable

# Restore all proxy hosts to their original targets
./npm-maintenance.sh disable
```

### What `enable` does

1. Authenticates with the NPM API and fetches all proxy hosts.
2. Backs up each host's `forward_host`, `forward_port`, and `forward_scheme` to `proxy_backup.json`.
3. Updates every proxy host to point at the maintenance container.
4. Logs a `✓` or `✗` result for each host.

### What `disable` does

1. Reads `proxy_backup.json` for the original forwarding details.
2. Fetches the current live config for each host and restores only the three forwarding fields — all other settings (SSL, caching, custom headers, etc.) are left untouched.
3. Clears the backup file if all hosts are restored successfully.
4. Retains the backup file if any host fails to restore, so you can recover manually.

---

## Logging

Log files are written to the same directory as the script:

| File | Contents |
|---|---|
| `npm-maintenance.out` | All output — `[INFO]`, `[WARN]`, and `[ERROR]` lines |
| `npm-maintenance.err` | Error lines only |

Example output:

```
[2026-07-26 14:32:01] [INFO] START: Enabling maintenance mode (triggered by root)
[2026-07-26 14:32:01] [INFO] Backed up 5 proxy host(s) to /opt/npm-maintenance/proxy_backup.json
[2026-07-26 14:32:02] [INFO]  ✓ [1/5] example.com (id: 1) → maintenance:80
[2026-07-26 14:32:02] [INFO]  ✓ [2/5] api.example.com (id: 2) → maintenance:80
[2026-07-26 14:32:03] [INFO] DONE: 5 succeeded, 0 failed out of 5 host(s)
```

---

## Notes

- The script runs with `set -euo pipefail`, so any unexpected error causes an immediate exit.
- Running `disable` without a prior `enable` (empty backup file) will abort safely to avoid breaking your proxy configuration.
- Only the three forwarding fields are swapped during enable/disable. All other proxy host settings remain intact because the update payload is built from the live configuration.

---

## License

[MIT](LICENSE) © 2026 mwwalters
