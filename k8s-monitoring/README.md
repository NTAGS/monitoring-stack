# Kubernetes Observability Lab

A hands-on Kubernetes observability project that brings together **Flask
applications, Fluentd, OpenTelemetry Collector, Prometheus, Node
Exporter, Grafana, Alertmanager, Jaeger, Splunk, and Slack**.

The project demonstrates how application logs and infrastructure metrics
move through a Kubernetes environment, how Prometheus evaluates alert
rules, and how alerts reach an operations channel.

> **Lab status and scope:** This README describes the two-VM lab
> topology documented during implementation: `vm1` (`192.168.56.5`) and
> `vm2` (`192.168.56.6`). Splunk is running on the MacBook host
> (`192.168.1.15`), outside Kubernetes. Check the live cluster before
> assuming node roles or IP addresses are unchanged.

------------------------------------------------------------------------

## Contents

-   [1. Project overview](#1-project-overview)
-   [2. Architecture](#2-architecture)
-   [3. End-to-end data flows](#3-end-to-end-data-flows)
-   [4. Lab environment](#4-lab-environment)
-   [5. Repository structure](#5-repository-structure)
-   [6. What each file does](#6-what-each-file-does)
-   [7. Deployment sequence](#7-deployment-sequence)
-   [8. Secrets and credentials](#8-secrets-and-credentials)
-   [9. Access points](#9-access-points)
-   [10. Validation](#10-validation)
-   [11. Example Splunk searches](#11-example-splunk-searches)
-   [12. Troubleshooting](#12-troubleshooting)
-   [13. Security and Git hygiene](#13-security-and-git-hygiene)
-   [14. Current implementation notes and
    gaps](#14-current-implementation-notes-and-gaps)

------------------------------------------------------------------------

## 1. Project overview

### Objectives

This lab demonstrates:

1.  Running sample applications in separate Kubernetes namespaces.
2.  Collecting container logs from Kubernetes nodes using a Fluentd
    DaemonSet.
3.  Enriching logs with Kubernetes metadata.
4.  Sending logs to Splunk through two parallel paths:
    -   Fluentd directly to Splunk HTTP Event Collector (HEC).
    -   Fluentd to OpenTelemetry Collector, then from the Collector to
        Splunk HEC.
5.  Collecting node-level CPU, memory, and filesystem metrics with Node
    Exporter.
6.  Scraping metrics and evaluating alert rules with Prometheus.
7.  Visualizing metrics in Grafana.
8.  Routing Prometheus alerts through Alertmanager to Slack.
9.  Deploying Jaeger as the tracing backend; application trace ingestion
    is not yet verified.

### Technology stack

  -----------------------------------------------------------------------
  Layer                   Component               Responsibility
  ----------------------- ----------------------- -----------------------
  Container orchestration Kubernetes              Runs and manages
                                                  workloads

  Container networking    Calico                  Pod networking and CNI

  Sample workloads        Flask                   Generates application
                                                  activity and JSON logs

  Log collection          Fluentd                 Tails container logs
                                                  and adds Kubernetes
                                                  metadata

  Telemetry pipeline      OpenTelemetry Collector Receives Fluent Forward
                                                  events, transforms
                                                  attributes, exports to
                                                  Splunk

  Infrastructure metrics  Node Exporter           Exposes host-level
                                                  metrics

  Metrics and alert       Prometheus              Scrapes metrics and
  evaluation                                      evaluates rules

  Dashboards              Grafana                 Visualizes Prometheus
                                                  metrics

  Alert routing           Alertmanager            Routes firing and
                                                  resolved alerts

  Tracing backend         Jaeger                  Deployed tracing
                                                  backend; trace path not
                                                  yet verified

  Log analytics           Splunk                  Receives and searches
                                                  logs through HEC

  Notifications           Slack                   Receives Alertmanager
                                                  notifications
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 2. Architecture

### Kubernetes environment

The lab uses two Ubuntu VMs:

  ------------------------------------------------------------------------
  Node             Hostname                            IP Role in the lab
  ---------------- ---------------- --------------------- ----------------
  VM1              `vm1`                   `192.168.56.5` Control-plane
                                                          host and
                                                          selected
                                                          monitoring
                                                          workloads

  VM2              `vm2`                   `192.168.56.6` Additional
                                                          Kubernetes node
                                                          and application
                                                          workload
  ------------------------------------------------------------------------

Kubernetes version: `v1.35.9`\
Calico version: `v3.31.2`\
Pod CIDR: `10.244.0.0/16`\
Service CIDR: `10.96.0.0/12`

Confirm the actual node roles and addresses before deployment:

``` bash
kubectl get nodes -o wide
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,ROLES:.metadata.labels.node-role\\.kubernetes\\.io/control-plane,INTERNAL-IP:.status.addresses[0].address
```

The Kubernetes control plane consists of:

-   `kube-apiserver` --- API entry point for Kubernetes operations.
-   `etcd` --- stores cluster state.
-   `kube-scheduler` --- assigns pending Pods to nodes.
-   `kube-controller-manager` --- runs controllers that reconcile
    desired and actual state.

The control-plane components are managed by the Kubernetes bootstrap
process. The current application/observability repository inventory does
**not** include the original kubeadm bootstrap or Calico installation
files.

### Namespaces

  -----------------------------------------------------------------------
  Namespace                           Workloads
  ----------------------------------- -----------------------------------
  `app-123-lob`                       Flask application 123

  `app-143-lob`                       Flask application 143

  `monitoring`                        Node Exporter, Fluentd, Prometheus,
                                      Grafana, Alertmanager

  `observability`                     OpenTelemetry Collector and Jaeger
  -----------------------------------------------------------------------

### External systems

  -----------------------------------------------------------------------
  System                  Location                Purpose
  ----------------------- ----------------------- -----------------------
  Splunk                  MacBook host,           Receives logs through
                          `192.168.1.15`          HEC on port `8088`

  Slack                   External SaaS           Receives Alertmanager
                                                  notifications
  -----------------------------------------------------------------------

Splunk is external to Kubernetes in this lab. The presence of
`splunk/splunk.yaml` in the repository does not mean Splunk is currently
running as a Kubernetes workload.

------------------------------------------------------------------------

## 3. End-to-end data flows

### 3.1 Application logs: Fluentd directly to Splunk

1.  A user accesses a Flask application.
2.  The user clicks an application action such as **Groceries**,
    **Electronics**, or **Restaurants**.
3.  The application writes a JSON event to its container log.
4.  Fluentd tails files under `/var/log/containers/*.log`.
5.  Fluentd parses the container log and enriches the record with
    Kubernetes metadata.
6.  Fluentd sends the event directly to Splunk HEC.

``` text
User
  |
  v
Flask application Pod
  |
  v
Container stdout/stderr
  |
  v
/var/log/containers/*.log
  |
  v
Fluentd DaemonSet
  |
  v
Splunk HEC (192.168.1.15:8088)
  |
  v
Splunk index: main
```

### 3.2 Application logs: Fluentd through OpenTelemetry Collector to Splunk

Fluentd also forwards events to the OpenTelemetry Collector using the
Fluent Forward protocol.

1.  Fluentd forwards the event to
    `otel-collector.observability.svc.cluster.local:24224`.
2.  The Collector receives it through its `fluentforward` receiver.
3.  A transform processor assigns a sourcetype based on the Kubernetes
    namespace.
4.  The `splunk_hec` exporter sends the event to Splunk HEC.

``` text
Flask application
  |
  v
Container log
  |
  v
Fluentd DaemonSet
  |
  v
OpenTelemetry Collector
  |  Receiver: fluentforward (:24224)
  |  Processor: transform/sourcetype
  |  Exporter: splunk_hec
  v
Splunk HEC (192.168.1.15:8088)
```

**Both Fluentd-to-Splunk paths are active in the documented lab.** The
direct path is intentionally retained while the OpenTelemetry path is
validated.

### 3.3 Infrastructure metrics: Node Exporter to Prometheus

1.  Node Exporter runs as a DaemonSet on eligible Kubernetes nodes.
2.  It exposes host metrics on port `9100`.
3.  Prometheus scrapes the configured targets every 15 seconds.
4.  Grafana queries Prometheus to render dashboards.
5.  Prometheus evaluates the configured alert rules.

``` text
VM1 Node Exporter ----\
VM2 Node Exporter -----+--> Prometheus --> Grafana
MacBook Node Exporter -/         |
                                 v
                           Alert evaluation
                                 |
                                 v
                            Alertmanager
                                 |
                                 v
                              Slack
```

The MacBook Node Exporter target is configured separately from the
Kubernetes DaemonSet.

### 3.4 Alerting: Prometheus to Alertmanager to Slack

Prometheus evaluates seven configured rules:

-   `HighCPUUsage`
-   `CriticalCPUUsage`
-   `HighMemoryUsage`
-   `CriticalMemoryUsage`
-   `HighDiskUsage`
-   `CriticalDiskUsage`
-   `NodeExporterDown`

The resource warning and critical thresholds are 75% and 90%,
respectively. Resource alerts use a five-minute pending period;
`NodeExporterDown` uses one minute.

When a rule fires, Prometheus sends the alert to Alertmanager.
Alertmanager groups and routes it to the Slack `#alerts` channel.
Resolved notifications are also enabled.

``` text
Node Exporter --> Prometheus --> Alertmanager --> Slack #alerts
```

### 3.5 Tracing: OpenTelemetry and Jaeger

Jaeger is deployed in the `observability` namespace. However, a complete
application-to-OpenTelemetry-to-Jaeger trace ingestion path has not yet
been verified in this lab.

Do not interpret the presence of the Jaeger Deployment as proof that
application traces are being received.

------------------------------------------------------------------------

## 4. Lab environment

### Verify cluster health

``` bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl get namespaces
```

Expected namespaces include:

``` text
monitoring
observability
app-123-lob
app-143-lob
```

### Project working directory

The project directory used during implementation:

``` bash
cd ~/k8s-monitoring
```

------------------------------------------------------------------------

## 5. Repository structure

The following structure reflects the project files identified during
implementation. Keep the directory names consistent when committing the
manifests to Git.

``` text
k8s-monitoring/
├── alertmanager/
│   ├── alertmanager-deploy.yaml
│   └── alertmanager.yml
│
├── flask-app/
│   └── flask-apps.yaml
│
├── fluentd/
│   ├── fluent.conf
│   ├── fluentd-config-backup.yaml
│   ├── fluentd-configmap.yaml
│   ├── fluentd-daemonset.yaml
│   ├── fluentd-rbac.yaml
│   └── fluentd-secret.yaml
│
├── grafana/
│   └── grafana.yaml
│
├── jaeger/
│   └── jaeger.yaml
│
├── node-exporter/
│   └── node-exporter.yaml
│
├── otel/
│   ├── otel-collector-config.yaml
│   ├── otel-collector-deployment.yaml
│   └── otel-collector.yaml
│
├── prometheus/
│   ├── alert-rules.yml
│   ├── prometheus-config-update.yaml
│   ├── prometheus.yaml
│   └── prometheus.yml
│
└── splunk/
    └── splunk.yaml
```

> This is the known file inventory, not a claim that every file is
> required to be applied. Some files are source configuration, backups,
> or manifests for workloads that are currently running outside the
> cluster.

------------------------------------------------------------------------

## 6. What each file does

### Flask applications

  -----------------------------------------------------------------------
  File                                Purpose
  ----------------------------------- -----------------------------------
  `flask-app/flask-apps.yaml`         Defines the sample Flask
                                      application workloads and their
                                      Kubernetes exposure. The two
                                      application namespaces are
                                      `app-123-lob` and `app-143-lob`.

  -----------------------------------------------------------------------

The applications emit JSON button-click events containing fields such as
timestamp, application ID, namespace, action, and event name.

### Fluentd

  --------------------------------------------------------------------------
  File                                   Purpose
  -------------------------------------- -----------------------------------
  `fluentd/fluentd-daemonset.yaml`       Runs Fluentd on eligible Kubernetes
                                         nodes.

  `fluentd/fluentd-rbac.yaml`            Defines the Kubernetes permissions
                                         Fluentd needs to read metadata.

  `fluentd/fluentd-configmap.yaml`       Supplies Fluentd configuration to
                                         the workload.

  `fluentd/fluent.conf`                  Fluentd pipeline: tails container
                                         logs, parses CRI records, enriches
                                         Kubernetes metadata, and configures
                                         outputs.

  `fluentd/fluentd-secret.yaml`          Secret-related manifest. Review it
                                         before committing; never commit
                                         live credentials.

  `fluentd/fluentd-config-backup.yaml`   Backup copy; retain for reference
                                         but do not apply as part of the
                                         normal deployment sequence unless
                                         intentionally restoring it.
  --------------------------------------------------------------------------

Fluentd uses the
`fluent/fluentd-kubernetes-daemonset:v1.20.1-debian-forward-arm64-1.0`
image in the documented lab.

The configuration uses a copy output to keep the direct Splunk HEC and
OpenTelemetry forwarding destinations active in parallel. Fluentd
excludes its own logs and OpenTelemetry Collector logs to avoid a
feedback loop.

### Node Exporter

  ------------------------------------------------------------------------
  File                                 Purpose
  ------------------------------------ -----------------------------------
  `node-exporter/node-exporter.yaml`   Deploys Node Exporter as a
                                       DaemonSet to expose node-level
                                       metrics.

  ------------------------------------------------------------------------

### Prometheus

  --------------------------------------------------------------------------------
  File                                         Purpose
  -------------------------------------------- -----------------------------------
  `prometheus/prometheus.yml`                  Prometheus scrape configuration,
                                               including scrape interval, targets,
                                               Alertmanager endpoint, and rule
                                               file reference.

  `prometheus/alert-rules.yml`                 Defines the seven CPU, memory,
                                               disk, and Node Exporter
                                               availability alert rules.

  `prometheus/prometheus-config-update.yaml`   ConfigMap manifest applied during
                                               the configuration/rule update. It
                                               carries the Prometheus
                                               configuration and alert rules.

  `prometheus/prometheus.yaml`                 In the current repository state,
                                               this is a ConfigMap-only manifest.
                                               It is not the missing Prometheus
                                               Deployment/Service definition.
  --------------------------------------------------------------------------------

The Prometheus configuration uses a 15-second scrape interval and
evaluation interval. Configured Node Exporter targets include:

-   `192.168.56.5:9100`
-   `192.168.56.6:9100`
-   `192.168.1.15:9100`

It also scrapes `localhost:9090` for Prometheus's own metrics.

### Grafana

  -----------------------------------------------------------------------
  File                                Purpose
  ----------------------------------- -----------------------------------
  `grafana/grafana.yaml`              Defines the Grafana workload and
                                      service. Grafana uses Prometheus as
                                      its metrics data source in this
                                      lab.

  -----------------------------------------------------------------------

### Alertmanager

  -----------------------------------------------------------------------------
  File                                      Purpose
  ----------------------------------------- -----------------------------------
  `alertmanager/alertmanager-deploy.yaml`   Defines the Alertmanager Deployment
                                            and Service.

  `alertmanager/alertmanager.yml`           Defines alert grouping, routing,
                                            and Slack notification formatting.
  -----------------------------------------------------------------------------

The Slack webhook is mounted from a Kubernetes Secret. The webhook value
must not be stored in the ConfigMap or committed to Git.

### OpenTelemetry Collector

  ---------------------------------------------------------------------------
  File                                    Purpose
  --------------------------------------- -----------------------------------
  `otel/otel-collector.yaml`              Defines the Collector Service used
                                          by Fluentd.

  `otel/otel-collector-deployment.yaml`   Defines the Collector Deployment.

  `otel/otel-collector-config.yaml`       Configures the Fluent Forward
                                          receiver, sourcetype transform
                                          processor, debug exporter, and
                                          Splunk HEC exporter.
  ---------------------------------------------------------------------------

The Collector Service is available inside the cluster at:

``` text
otel-collector.observability.svc.cluster.local:24224
```

The Splunk HEC token is supplied to the Collector through the
`splunk-hec` Secret in the `observability` namespace.

### Jaeger

  -----------------------------------------------------------------------
  File                                Purpose
  ----------------------------------- -----------------------------------
  `jaeger/jaeger.yaml`                Deploys Jaeger in the
                                      `observability` namespace.

  -----------------------------------------------------------------------

Jaeger is deployed, but the application trace instrumentation/export
path remains to be validated.

### Splunk

  -----------------------------------------------------------------------
  File                                Purpose
  ----------------------------------- -----------------------------------
  `splunk/splunk.yaml`                Splunk-related Kubernetes manifest
                                      retained in the repository.

  -----------------------------------------------------------------------

**Current runtime:** Splunk is running directly on the MacBook host at
`192.168.1.15`, not inside Kubernetes. Do not apply `splunk/splunk.yaml`
as part of this lab's normal deployment unless intentionally changing
the topology.

------------------------------------------------------------------------

## 7. Deployment sequence

Run commands from the project root:

``` bash
cd ~/k8s-monitoring
```

### 7.1 Check cluster readiness

``` bash
kubectl get nodes -o wide
kubectl get pods -A
```

Do not proceed until the nodes required by the workloads are `Ready`.

### 7.2 Ensure namespaces exist

If the manifests do not already create these namespaces, create them:

``` bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace app-123-lob --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace app-143-lob --dry-run=client -o yaml | kubectl apply -f -
```

These commands are idempotent. If namespace resources are already
defined in the application manifest, applying the manifest is also
sufficient.

### 7.3 Deploy sample applications

``` bash
kubectl apply -f flask-app/flask-apps.yaml
kubectl get pods -n app-123-lob
kubectl get pods -n app-143-lob
kubectl get svc -n app-123-lob
kubectl get svc -n app-143-lob
```

### 7.4 Deploy Node Exporter

``` bash
kubectl apply -f node-exporter/node-exporter.yaml
kubectl get daemonset -n monitoring
kubectl get pods -n monitoring -o wide
```

### 7.5 Deploy Fluentd

Apply permissions and configuration before the DaemonSet:

``` bash
kubectl apply -f fluentd/fluentd-rbac.yaml
kubectl apply -f fluentd/fluentd-configmap.yaml
```

Create or verify the Fluentd Secret using the credential keys expected
by the manifest. Do not apply a file containing real credentials from a
public Git repository.

Then deploy Fluentd:

``` bash
kubectl apply -f fluentd/fluentd-daemonset.yaml
kubectl get daemonset -n monitoring
kubectl get pods -n monitoring -o wide
```

### 7.6 Configure OpenTelemetry Collector

Ensure the `splunk-hec` Secret exists in the `observability` namespace
before starting the Collector. See [Secrets and
credentials](#8-secrets-and-credentials).

Apply the Collector configuration and workload:

``` bash
kubectl apply -f otel/otel-collector-config.yaml
kubectl apply -f otel/otel-collector.yaml
kubectl apply -f otel/otel-collector-deployment.yaml

kubectl get pods -n observability
kubectl get svc -n observability
```

### 7.7 Configure Prometheus

The configuration/rules update used in the lab was applied with:

``` bash
kubectl apply -f prometheus/prometheus-config-update.yaml
```

The raw source files are:

``` text
prometheus/prometheus.yml
prometheus/alert-rules.yml
```

Validate the Prometheus configuration and rules with `promtool` before
applying changes. Example:

``` bash
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/alert-rules.yml
```

The alert-rule validation in the lab reported seven rules found.

**Important:** The current file inventory does not show a separate
Prometheus Deployment/Service manifest. `prometheus/prometheus.yaml` is
ConfigMap-only. The running Prometheus workload was already present in
the lab. Add and validate a Deployment/Service manifest before claiming
this repository can create Prometheus from a completely clean cluster.

### 7.8 Deploy Alertmanager and Grafana

Create the Alertmanager Slack Secret first, then apply:

``` bash
kubectl apply -f alertmanager/alertmanager-deploy.yaml
kubectl apply -f grafana/grafana.yaml

kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

`alertmanager/alertmanager.yml` is the Alertmanager configuration
content referenced by the deployment/configuration resource. Confirm
that the deployed ConfigMap contains the current version before
restarting or reloading Alertmanager.

### 7.9 Deploy Jaeger

``` bash
kubectl apply -f jaeger/jaeger.yaml
kubectl get pods -n observability
kubectl get svc -n observability
```

This deploys Jaeger. It does not by itself configure Flask application
tracing.

### 7.10 Check all workloads

``` bash
kubectl get pods -A -o wide
kubectl get daemonsets -A
kubectl get deployments -A
kubectl get services -A
```

> The commands above are the logical deployment sequence for the
> identified manifests. Before treating them as a one-command
> clean-install procedure, reconcile the manifest gaps listed in
> [Current implementation notes and
> gaps](#14-current-implementation-notes-and-gaps).

------------------------------------------------------------------------

## 8. Secrets and credentials

Never commit live tokens, Slack webhook URLs, passwords, or private
keys.

### OpenTelemetry Collector: Splunk HEC token

The Collector reads the HEC token from the `splunk-hec` Secret in
namespace `observability`.

Example creation command (run in a secure shell; do not paste the token
into Git):

``` bash
read -s SPLUNK_HEC_TOKEN
kubectl create secret generic splunk-hec \
  --namespace observability \
  --from-literal=SPLUNK_HEC_TOKEN="$SPLUNK_HEC_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
unset SPLUNK_HEC_TOKEN
```

The Secret key must match the `secretKeyRef` used in
`otel/otel-collector-deployment.yaml`.

### Alertmanager: Slack webhook

The Alertmanager configuration expects a file at:

``` text
/etc/alertmanager/secrets/slack-webhook
```

Create the Secret from a protected local file:

``` bash
kubectl create secret generic alertmanager-slack \
  --namespace monitoring \
  --from-file=slack-webhook=/secure/path/slack-webhook \
  --dry-run=client -o yaml | kubectl apply -f -
```

The Secret name and key must match the volume reference in
`alertmanager/alertmanager-deploy.yaml`.

### Secret verification

``` bash
kubectl get secrets -n monitoring
kubectl get secrets -n observability
```

List Secret names and metadata only. Avoid printing decoded Secret
values into terminal logs, screenshots, or documentation.

------------------------------------------------------------------------

## 9. Access points

The following endpoints were used in the lab. They assume the VM IP
addresses and NodePort/hostPort configuration have not changed.

  --------------------------------------------------------------------------------------------------------
  Component               URL / endpoint                                           Notes
  ----------------------- -------------------------------------------------------- -----------------------
  Flask App 123           `http://192.168.56.5:30080`                              `app-123-lob`

  Flask App 143           `http://192.168.56.5:30081`                              `app-143-lob`

  Prometheus              `http://192.168.56.5:9090`                               Host port on VM1

  Grafana                 `http://192.168.56.5:3000`                               Host port on VM1

  Alertmanager            `http://192.168.56.5:9093`                               Host port on VM1

  Splunk HEC              `https://192.168.1.15:8088`                              MacBook host

  OpenTelemetry Collector `otel-collector.observability.svc.cluster.local:24224`   Cluster-internal Fluent
                                                                                   Forward endpoint
  --------------------------------------------------------------------------------------------------------

The lab Grafana manifest used `admin/admin`. This is a lab credential
only; change it before using the deployment in any shared or production
environment.

------------------------------------------------------------------------

## 10. Validation

### 10.1 Application validation

Open both Flask application URLs and generate button-click events.

Check that the application Pods are running:

``` bash
kubectl get pods -n app-123-lob
kubectl get pods -n app-143-lob
```

### 10.2 Fluentd validation

``` bash
kubectl get pods -n monitoring -o wide
kubectl logs -n monitoring <fluentd-pod-name>
```

Confirm that Fluentd:

-   Tails `/var/log/containers/*.log`.
-   Parses CRI-formatted container logs.
-   Adds Kubernetes metadata.
-   Sends events to the direct Splunk HEC output.
-   Forwards events to the OpenTelemetry Collector on port `24224`.

### 10.3 OpenTelemetry Collector validation

``` bash
kubectl get pods -n observability
kubectl logs -n observability deployment/otel-collector
```

The Collector debug exporter was enabled during validation. Its logs
showed received button-click events and Kubernetes metadata.

Check the Collector Service:

``` bash
kubectl get svc -n observability
```

### 10.4 Splunk log validation

Run this search in Splunk:

``` spl
index=main source=kubernetes earliest=-10m event=button_clicked
| stats count by sourcetype
```

The implementation validation showed events for the two application
sourcetypes (123 and 143). This verified namespace-based sourcetype
assignment and HEC ingestion for the test events.

### 10.5 Prometheus validation

Open:

``` text
http://192.168.56.5:9090
```

Check targets:

``` text
Status → Targets
```

Check alert rules:

``` text
Alerts
```

The seven configured rules were validated with `promtool`, and the
Prometheus Rules UI showed the rules as healthy (`ok`).

Check the Alertmanager connection through the Prometheus API:

``` bash
curl -s http://192.168.56.5:9090/api/v1/alertmanagers
```

The lab validation showed an active Alertmanager at:

``` text
http://192.168.56.5:9093/api/v2/alerts
```

The Prometheus configuration reload endpoint returned HTTP 200 during
the documented configuration update:

``` bash
curl -X POST http://192.168.56.5:9090/-/reload
```

This endpoint is enabled by the Prometheus `--web.enable-lifecycle`
argument in the running workload.

### 10.6 Grafana validation

Open:

``` text
http://192.168.56.5:3000
```

Confirm that Grafana can query Prometheus and render the configured
dashboards.

### 10.7 Alertmanager validation

Open:

``` text
http://192.168.56.5:9093
```

Check that Alertmanager is ready and has loaded its configuration.
Trigger a test alert only in a controlled lab window, then confirm that
Slack receives firing and resolved notifications.

### 10.8 Jaeger validation

Confirm that the Jaeger Pods and Services are healthy:

``` bash
kubectl get pods -n observability
kubectl get svc -n observability
```

A healthy Jaeger Pod confirms deployment, not trace ingestion. Generate
and verify traces only after application instrumentation and an exporter
path have been configured.

------------------------------------------------------------------------

## 11. Example Splunk searches

### Button-click events

``` spl
index=main source=kubernetes event=button_clicked
| sort -_time
```

### Events by application and action

``` spl
index=main source=kubernetes event=button_clicked
| stats count by application_id, action
```

### Events by sourcetype

``` spl
index=main source=kubernetes earliest=-30m event=button_clicked
| stats count by sourcetype
```

### Events by Kubernetes namespace

``` spl
index=main source=kubernetes event=button_clicked
| stats count by kubernetes.namespace_name
```

Field availability depends on the event payload and metadata produced by
the active Fluentd/Collector pipeline.

------------------------------------------------------------------------

## 12. Troubleshooting

### Pods are not starting

``` bash
kubectl get pods -A
kubectl describe pod -n <namespace> <pod-name>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

Check image availability, node readiness, PVC requirements (if any),
resource requests, and Secret references.

### Fluentd is not forwarding logs

``` bash
kubectl get daemonset -n monitoring
kubectl logs -n monitoring <fluentd-pod-name>
kubectl get configmap -n monitoring
kubectl get secrets -n monitoring
```

Check:

-   The container log path is mounted.
-   Fluentd has the required Kubernetes RBAC permissions.
-   The Fluentd configuration is mounted at the expected path.
-   The Splunk HEC endpoint is reachable from the VM.
-   The HEC token is valid.
-   The Collector Service name and port resolve inside the cluster.

### OpenTelemetry Collector is not exporting to Splunk

``` bash
kubectl logs -n observability deployment/otel-collector
kubectl describe pod -n observability -l app=otel-collector
kubectl get secret splunk-hec -n observability
kubectl get svc otel-collector -n observability
```

Check the receiver, processor, exporter, Secret key reference, HEC
endpoint, and TLS settings. The lab Collector configuration used
`insecure_skip_verify: true`; this is a lab convenience and should not
be copied into a production deployment without a security review.

### Prometheus target is down

Open **Status → Targets** in Prometheus. Check the target address,
routing, firewall, Node Exporter Pod, and port `9100`.

### Prometheus rules are not loading

``` bash
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/alert-rules.yml
```

Confirm that the ConfigMap contains both files and that the Prometheus
Pod mounts the ConfigMap at `/etc/prometheus`.

### Alertmanager does not notify Slack

``` bash
kubectl logs -n monitoring deployment/alertmanager
kubectl get secret alertmanager-slack -n monitoring
kubectl describe deployment alertmanager -n monitoring
```

Check the Secret name, key, mount path, webhook validity, Slack channel,
and Alertmanager route configuration.

------------------------------------------------------------------------

## 13. Security and Git hygiene

Before pushing the repository:

-   Replace live Secret manifests with templates or documented
    `kubectl create secret` commands.
-   Never commit Splunk HEC tokens, Slack webhook URLs, passwords, or
    private keys.
-   Review `fluentd/fluentd-secret.yaml` before committing.
-   Do not include kubeconfig files, client certificates, private keys,
    or generated credentials.
-   Change default Grafana credentials.
-   Review the use of `insecure_skip_verify: true` before moving beyond
    the lab.
-   Consider Kubernetes NetworkPolicies and least-privilege RBAC for a
    shared environment.

Suggested `.gitignore` entries:

``` gitignore
# Credentials and local secret material
.env
.env.*
*.key
*.pem
*secret*.local.yaml
*secret*.local.yml
slack-webhook
kubeconfig
admin.conf

# Local state and backups
*.log
*.bak
```

Do not blindly ignore every file containing the word `secret`: commit
only sanitized Secret templates if you choose to maintain them in Git.

------------------------------------------------------------------------

## 14. Current implementation notes and gaps

This section intentionally separates verified implementation from items
that still need work.

### Implemented and validated

-   Two-VM Kubernetes lab with Calico networking.
-   Flask applications in `app-123-lob` and `app-143-lob`.
-   Node Exporter DaemonSet.
-   Fluentd DaemonSet with container log collection and Kubernetes
    metadata.
-   Parallel Fluentd outputs: direct Splunk HEC and OpenTelemetry
    Collector.
-   OpenTelemetry Collector Fluent Forward receiver, sourcetype
    transform, debug exporter, and Splunk HEC exporter.
-   Splunk HEC ingestion of application button-click events.
-   Prometheus scrape configuration and seven alert rules.
-   Prometheus-to-Alertmanager integration.
-   Grafana deployment.
-   Alertmanager Slack notification configuration.
-   Jaeger deployment.

### Not yet verified or not present in the known manifest inventory

1.  **Clean-cluster Prometheus deployment:** The known
    `prometheus/prometheus.yaml` is ConfigMap-only. A separate
    Prometheus Deployment/Service manifest is not present in the
    identified file list.
2.  **Kubernetes bootstrap automation:** kubeadm initialization, node
    join, and Calico installation files are not in the identified
    `k8s-monitoring/` inventory.
3.  **Jaeger trace ingestion:** Jaeger is deployed, but the application
    instrumentation and trace-export path have not been verified.
4.  **Splunk deployment in Kubernetes:** Splunk currently runs on the
    MacBook host. `splunk/splunk.yaml` is retained in the repository but
    is not part of the active runtime path.
5.  **Secret reproducibility:** Live credentials must be supplied
    securely during deployment; they should not be committed to Git.

### Next steps to make the repository reproducible

-   Add the missing Prometheus Deployment/Service manifest, or document
    the external/previous deployment that creates it.
-   Add or link the Ansible/kubeadm and Calico bootstrap automation if
    this repository is intended to provision the cluster as well as the
    observability stack.
-   Replace live Secret YAMLs with sanitized templates and a secure
    secret-creation procedure.
-   Complete and validate the application-to-Jaeger trace pipeline.
-   Add a single deployment script only after the manifest order and
    prerequisites have been verified.

------------------------------------------------------------------------

## 15. Project outcome

This lab demonstrates an end-to-end observability workflow:

-   **Logs:** Flask → container logs → Fluentd → Splunk directly, and
    Fluentd → OpenTelemetry Collector → Splunk.
-   **Metrics:** Node Exporter → Prometheus → Grafana.
-   **Alerts:** Prometheus rules → Alertmanager → Slack.
-   **Tracing:** Jaeger is deployed; application trace ingestion remains
    a follow-up validation item.

The design keeps application workloads separate from the monitoring and
observability services, while allowing telemetry to be collected and
analyzed centrally.
