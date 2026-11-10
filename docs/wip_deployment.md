# Deployment

## Production secret management

Helm stores supplied values in its release data. For production secret
management, create the Secrets separately in the release namespace and
reference them instead:

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-runner-stack \
  --create-namespace \
  --set-string runnerPools.linux.queue=<queue> \
  --set runnerPools.linux.maxReplicas=<maximum> \
  --set-string agentToken.existingSecret.name=<agent-secret> \
  --set-string metricsToken.existingSecret.name=<metrics-secret>
```

The metrics Secret key must contain the complete `Authorization` value in the
form `Token <cluster-agent-token>`.
