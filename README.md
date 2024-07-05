[![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/alloy-app/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/alloy-app/tree/main)

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

- [Using GitOps](https://docs.giantswarm.io/vintage/advanced/gitops/apps/add_appcr/)
- [Using our web interface](https://docs.giantswarm.io/vintage/platform-overview/web-interface/app-platform/#installing-an-app)
- [Using the App platform](https://docs.giantswarm.io/vintage/getting-started/app-platform/deploy-app/) ([kubectl gs template app](https://docs.giantswarm.io/vintage/use-the-api/kubectl-gs/template-app/) reference)

Example with `kubectl gs`:

```
kubectl gs template app --name alloy --catalog giantswarm-playground --target-namespace alloy --cluster-name myCluster --version 0.1.0 --user-configmap helm/alloy/examples/mimir-rules/values.yaml | kubectl apply -f -
```

## Configuring

See examples in [helm/alloy/examples](helm/alloy/examples) for how to configure the app.

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
