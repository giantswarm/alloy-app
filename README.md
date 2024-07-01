[![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/alloy-app/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/alloy-app/tree/main)

[Read me after cloning this template (GS staff only)](https://handbook.giantswarm.io/docs/dev-and-releng/app-developer-processes/adding_app_to_appcatalog/)

# alloy chart

Giant Swarm offers a alloy App which can be installed in workload clusters.
Here we define the alloy chart with its templates and default configuration.

**What is this app?**

Alloy is an OpenTelemetry collector with support for metrics, logs, traces, and profiles.

More details at https://github.com/grafana/alloy

**Why did we add it?**

We added Alloy in order to be able to improve our Observability platform and provide additional capabilities towards observability data ingestion and transformation.

**Who can use it?**

Anyone with a need to collect observability data and who need an OpenTelemetry compatible collector.

## Installing

There are several ways to install this app onto a workload cluster.

- [Using GitOps to instantiate the App](https://docs.giantswarm.io/advanced/gitops/apps/)
- [Using our web interface](https://docs.giantswarm.io/platform-overview/web-interface/app-platform/#installing-an-app).
- By creating an [App resource](https://docs.giantswarm.io/use-the-api/management-api/crd/apps.application.giantswarm.io/) in the management cluster as explained in [Getting started with App Platform](https://docs.giantswarm.io/getting-started/app-platform/).

## Configuring

### values.yaml

**This is an example of a values file you could upload using our web interface.**

```yaml
# values.yaml

```

### Sample App CR and ConfigMap for the management cluster

If you have access to the Kubernetes API on the management cluster, you could create
the App CR and ConfigMap directly.

Here is an example that would install the app to
workload cluster `abc12`:

```yaml
# appCR.yaml

```

```yaml
# user-values-configmap.yaml

```

See our [full reference on how to configure apps](https://docs.giantswarm.io/getting-started/app-platform/app-configuration/) for more details.

## Credit

- https://github.com/grafana/alloy
