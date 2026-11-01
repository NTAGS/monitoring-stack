# Splunk Enterprise on Apple Silicon MacBook — Docker AMD64 POC

This README captures the working Splunk Enterprise setup and the HEC validation performed on an Apple Silicon MacBook Pro.

## 1. Tested setup

| Item | Setting |
|---|---|
| Host | Apple Silicon MacBook Pro (`arm64`) |
| Runtime | Docker Desktop |
| Splunk image | `splunk/splunk:10.2.9` |
| Container platform | `linux/amd64` (Docker Desktop emulation) |
| Container name | `splunk` |
| Splunk Web | `http://localhost:8000` |
| Management API | `https://localhost:8089` |
| HEC | `https://localhost:8088` |
| Splunk TCP receiver | `9997` (published; not required for HEC) |
| Persistent volumes | `splunk-etc`, `splunk-var` |
| HEC test index | `main` |

Docker Desktop was configured with approximately **8 GB memory** for this POC. Splunk ran successfully with the AMD64 image under Docker Desktop emulation.

> **Lab security:** The commands below use example credentials and a sample HEC token for repeatability. Replace them before running. Do not use these lab credentials in production, and do not commit real passwords or tokens to source control.

## 2. Prerequisites

1. Install and start Docker Desktop.
2. In Docker Desktop, allocate approximately 8 GB memory to Docker.
3. Open Terminal on the MacBook.
4. Confirm Docker is available:

```bash
uname -m
docker version
docker info --format 'Docker architecture: {{.Architecture}} | CPUs: {{.NCPU}} | Memory: {{.MemTotal}}'
```

The Mac should report `arm64`. Docker's host architecture may report `aarch64`; that is expected. The Splunk container will explicitly use `linux/amd64`.

## 3. Installation command block

This block creates the two persistent Docker volumes and starts Splunk using the AMD64 image.

**Important volume-permission behavior:** On a genuinely fresh Docker named volume, Docker initializes the volume from the image's existing directory contents when it is first mounted. Let the Splunk image's startup process initialize and manage its own files. Do **not** run a blanket `chown -R` against `/opt/splunk/etc` or `/opt/splunk/var`. In this POC, recursive ownership changes were followed by Splunk CLI and log-file permission warnings. This install block deliberately avoids that operation.

```bash
# ---- Set lab credentials before running ----
export SPLUNK_PASSWORD='REPLACE_WITH_A_STRONG_PASSWORD'
export SPLUNK_HEC_TOKEN='REPLACE_WITH_A_LONG_RANDOM_HEC_TOKEN'

# ---- Confirm Docker Desktop is running ----
docker info >/dev/null || {
  echo "Docker Desktop is not running. Start Docker Desktop and retry."
  exit 1
}

# ---- Pull the explicitly AMD64 image ----
docker pull --platform linux/amd64 splunk/splunk:10.2.9

# ---- Create persistent volumes (safe if they already exist) ----
docker volume create splunk-etc >/dev/null
docker volume create splunk-var >/dev/null

# ---- Replace only the container, not its data volumes ----
# This preserves splunk-etc and splunk-var if they already contain data.
docker rm -f splunk 2>/dev/null || true

# ---- Start Splunk Enterprise ----
docker run -d \
  --name splunk \
  --platform linux/amd64 \
  --hostname splunk \
  --restart unless-stopped \
  --shm-size=2g \
  -p 8000:8000 \
  -p 8088:8088 \
  -p 8089:8089 \
  -p 9997:9997 \
  -e SPLUNK_START_ARGS='--accept-license' \
  -e SPLUNK_GENERAL_TERMS='--accept-sgt-current-at-splunk-com' \
  -e SPLUNK_PASSWORD="$SPLUNK_PASSWORD" \
  -e SPLUNK_HEC_TOKEN="$SPLUNK_HEC_TOKEN" \
  -v splunk-etc:/opt/splunk/etc \
  -v splunk-var:/opt/splunk/var \
  splunk/splunk:10.2.9

echo
echo "Container started. Follow startup logs with:"
echo "docker logs -f splunk"
echo
echo "Splunk Web: http://localhost:8000"
```

### What persists?

- `splunk-etc`: Splunk configuration, apps, and related configuration state.
- `splunk-var`: Splunk runtime data, indexes, logs, and other variable data.

The container can be removed and recreated without removing these named volumes. **Do not delete the volumes** if you want to retain Splunk configuration and indexed data.

## 4. Wait for Splunk startup

Splunk startup can take several minutes, particularly when running an AMD64 image under emulation.

Run:

```bash
echo "===== CONTAINER STATUS ====="
docker ps --filter name='^/splunk$'

echo
echo "===== HEALTH STATUS ====="
docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}No healthcheck{{end}}' splunk

echo
echo "===== RECENT STARTUP LOGS ====="
docker logs --tail 60 splunk
```

Wait until the container health status is `healthy` before testing HEC. You can also follow startup with `docker logs -f splunk` and stop following with `Ctrl+C`; this does not stop the container.

Open Splunk Web:

- URL: `http://localhost:8000`
- Username: `admin`
- Password: the value assigned to `SPLUNK_PASSWORD`

## 5. Configure and verify HTTP Event Collector (HEC)

The installation passes `SPLUNK_HEC_TOKEN` to the Splunk image so it can configure a HEC token during startup. Verify the resulting configuration in Splunk Web.

1. Sign in to Splunk Web.
2. Go to **Settings → Data Inputs → HTTP Event Collector**.
3. Confirm the token is enabled. In the tested setup, the token appeared as `splunk_hec_token`.
4. Open **Global Settings**.
5. Confirm **All Tokens** is enabled.
6. Confirm the HEC HTTP port is `8088`.
7. Save if you changed any settings.

The tested HEC endpoint accepted HTTPS requests at `https://localhost:8088`. The `-k` option in the test commands below skips certificate verification for this local lab certificate only. For production, configure and validate trusted TLS certificates.

## 6. Send a correctly formatted JSON test event

Run this on the **MacBook Terminal**. Replace the token with the same value configured for `SPLUNK_HEC_TOKEN`.

```bash
export SPLUNK_HEC_TOKEN='REPLACE_WITH_THE_SAME_HEC_TOKEN'

curl -sk https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "index": "main",
    "event": {
      "message": "KUBERNETES_POC_HEC_VALIDATION",
      "component": "observability",
      "platform": "kubernetes"
    },
    "source": "hec-validation",
    "sourcetype": "_json"
  }'

echo
```

Expected HEC response:

```json
{"text":"Success","code":0}
```

**Important:** Because the sourcetype is `_json`, the `event` value must be a JSON object (or valid JSON), not an unstructured plain-text string. The earlier plain-text test generated a `JsonLineBreaker` parsing error. The JSON-object test above was successful.

A `Success` response confirms HEC accepted the request. It does not, by itself, prove that the event is searchable; perform the search below.

## 7. Verify the event in Splunk Search

In Splunk Web, open **Search & Reporting** and run:

```spl
index=main "KUBERNETES_POC_HEC_VALIDATION"
```

Set the time range to **Last 24 hours** or **All time**.

The successful test returned one event with these extracted fields:

| Field | Value |
|---|---|
| `message` | `KUBERNETES_POC_HEC_VALIDATION` |
| `component` | `observability` |
| `platform` | `kubernetes` |
| `host` | `localhost:8088` |
| `source` | `hec-validation` |
| `sourcetype` | `_json` |
| `index` | `main` |

This confirmed that the event was accepted, indexed in `main`, and searchable with JSON fields extracted.

## 8. Useful operational commands

```bash
# Container status
docker ps --filter name='^/splunk$'

# Health
docker inspect --format='{{.State.Health.Status}}' splunk

# Follow logs
docker logs -f splunk

# Last 100 log lines
docker logs --tail 100 splunk

# Confirm the image platform
docker image inspect splunk/splunk:10.2.9 \
  --format '{{.Os}}/{{.Architecture}}'

# Confirm named volumes
docker volume ls --filter name=splunk-

# Inspect volume metadata
docker volume inspect splunk-etc splunk-var

# Stop and start without deleting data
docker stop splunk
docker start splunk

# Recreate the container while retaining both data volumes
docker rm -f splunk
# Then rerun the docker run block in Section 3.
```

## 9. Troubleshooting notes from this setup

### HEC returns `Success`, but Search shows zero events

- Search the exact index specified in the HEC payload: `index=main`.
- Widen the time picker to **All time** or **Last 24 hours**.
- Search for the exact unique marker: `KUBERNETES_POC_HEC_VALIDATION`.
- Confirm the HEC token is enabled and that its allowed-index configuration permits `main`.
- Confirm the target index exists.
- Check the Splunk logs for HEC, parsing, index, and permission errors.

### `JsonLineBreaker` reports an unexpected character such as `H`

This occurred when a plain-text event was sent with `sourcetype` set to `_json`. Send a JSON object as the `event` value, as shown in Section 6.

### Permission warnings after changing ownership

Do not repeatedly run recursive `chown` commands against the Splunk directories. The POC encountered permission warnings in files under `/opt/splunk/var/log/splunk` and CLI diagnostics after a recursive ownership change. A healthy container and running `splunkd` processes were observed even while some CLI diagnostics reported permission problems.

For a clean first installation, use fresh named volumes and allow the image startup process to initialize them. If an existing volume has already been modified and has permission problems, preserve it and diagnose it separately rather than deleting it or applying another blind recursive ownership change.

### Container is healthy, but the Splunk CLI reports `splunkd is not running`

In this POC, the CLI status check reported that message while `splunkd` processes were visible and the Docker health check later reported `healthy`. Do not rely on that one CLI message alone. Check container health, process state, startup logs, and whether the Web and HEC endpoints respond.

## 10. Stop, preserve, reset, and uninstall

### Stop Splunk but keep all data

```bash
docker stop splunk
```

### Start it again

```bash
docker start splunk
```

### Remove only the container (volumes remain)

```bash
docker rm -f splunk
```

### Permanently delete the POC and its data

**Destructive:** this deletes the persistent configuration and indexed data. Run only when you intentionally want a completely fresh Splunk installation.

```bash
docker rm -f splunk 2>/dev/null || true
docker volume rm splunk-etc splunk-var
```

Then rerun the installation block in Section 3.

## 11. POC outcome and next integration

The MacBook Splunk instance was verified with:

- AMD64 Splunk Enterprise image running on Apple Silicon through Docker Desktop emulation.
- Persistent configuration and data volumes.
- Splunk Web and HEC ports published.
- HEC token enabled and accepting authenticated HTTPS requests.
- A JSON event successfully indexed in `main` and found through Splunk Search.

**Next integration:** Configure Fluentd in the Kubernetes monitoring namespace to send Kubernetes container logs to the MacBook's reachable IP address on HEC port `8088`, using the same HEC token. Before deploying Fluentd, verify that the Kubernetes VMs can reach the MacBook over the VirtualBox/network interface and that the HEC port is reachable from the VMs.
