You can deploy this example with the following command:

```
helm install alloy-mimir-rules helm/alloy --values helm/alloy/examples/mimir-rules/values.yaml
```

This will deploy and configure Alloy to load PrometheusRules to Mimir.

Alloy will select PrometheusRules with the foo=bar label in every namespaces and load them to Mimir.

It uses Alloy [`mimir.rules.prometheus`](https://grafana.com/docs/alloy/latest/reference/components/mimir/mimir.rules.kubernetes) component is used.

### Authentication

The authentication to Mimir is configured using basic auth. The username and password are stored in a secret which are then used as environment variables in the Alloy config.

NOTE: there is a limitation related to the secret name, therefore the helm release name should be identical to the secret name referenced under secretRef in values.yaml.
