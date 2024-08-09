<p align="center">
    <img src="assets/logo_alloy_light.svg#gh-dark-mode-only" alt="Grafana Alloy logo" height="100px">
    <img src="assets/logo_alloy_dark.svg#gh-light-mode-only" alt="Grafana Alloy logo" height="100px">
</p>

<p align="center">
  <a href="https://github.com/giantswarm/alloy/releases"><img src="https://img.shields.io/github/release/giantswarm/alloy.svg" alt="Latest Release"></a>
  <a href="https://dl.circleci.com/status-badge/redirect/gh/giantswarm/alloy-app/tree/main"><img src="https://dl.circleci.com/status-badge/img/gh/giantswarm/alloy-app/tree/main.svg?style=svg" alt="CircleCI"></a>
</p>

Giant Swarm offers Grafana Alloy App which can be installed in workload clusters.

Here we define the Grafana Alloy chart with its templates and default configuration.

**What is this app?**

Alloy is an [OpenTelemetry](https://opentelemetry.io/) collector with support for metrics, logs, traces, and profiles.

More details at https://github.com/grafana/alloy

**Why did we add it?**

We added Alloy in order to be able to improve our Observability platform and provide additional capabilities towards observability data ingestion and transformation.

**Who can use it?**

Anyone with a need to collect observability data and who need an [OpenTelemetry](https://opentelemetry.io/) compatible collector.

## Installing

There are several ways to install this app onto a workload cluster.

### Using `helm`

```
helm repo add giantswarm https://giantswarm.github.io/giantswarm-catalog/
helm repo update
helm install alloy giantswarm/alloy --values helm/alloy/examples/mimir-rules/values.yaml
```

### Using `kubectl` GiantSwarm plugin

```
kubectl gs template app --cluster-name myCluster --name alloy --catalog giantswarm --target-namespace alloy --version 1.0.0 --user-configmap helm/alloy/examples/mimir-rules/values.yaml | kubectl apply -f -
```

See [App platform documentation](https://docs.giantswarm.io/vintage/getting-started/app-platform/deploy-app/) and [kubectl gs template app](https://docs.giantswarm.io/vintage/use-the-api/kubectl-gs/template-app/) reference.

### Using GiantsSwarm web interface

See [Web interface documentation](https://docs.giantswarm.io/vintage/platform-overview/web-interface/app-platform/#installing-an-app)

### Using GitOps

See [GitOps documentation](https://docs.giantswarm.io/vintage/advanced/gitops/apps/add_appcr/)

## Configuring

See examples in [helm/alloy/examples](helm/alloy/examples) for how to configure the app.

See our [full reference on how to configure apps](https://docs.giantswarm.io/getting-started/app-platform/app-configuration/) for more details.

## Credit

- https://github.com/grafana/alloy
