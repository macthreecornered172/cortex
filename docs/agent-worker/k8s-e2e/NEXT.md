# K8s E2E: Real Claude Support

## What's done
- K8s e2e tests pass in mock mode (TestK8sDAGSimple, TestK8sDAGMultiTeam)
- kind cluster setup, image loading, deployment, port-forward, test, teardown all automated via Makefile
- Executor wired for `:k8s` backend with worker env passthrough (CLAUDE_COMMAND, model, turns, permissions)
- PodSpec: container commands, imagePullPolicy, worker_env support

## What's next

### 1. Makefile targets for real Claude
Add `e2e-k8s-simple-claude` and `e2e-k8s-multi-claude` mirroring the Docker pattern:
- Build combo image with Claude CLI: `docker-combo-claude` (already exists)
- Load `cortex-agent-worker:latest` into kind (with Claude CLI baked in)
- Patch the `cortex-gateway-token` and `anthropic-api-key` secrets with real values
- Set `CLAUDE_COMMAND=claude` on the Cortex deployment (env patch or separate deployment YAML)

### 2. Secret handling
The current `secrets.yaml` hardcodes `fake-key` for the API key. For real Claude:
- Either: `kubectl create secret` from env var at runtime (like Docker uses `$ANTHROPIC_API_KEY`)
- Or: patch existing secret: `kubectl patch secret anthropic-api-key -p '{"stringData":{"key":"REAL_KEY"}}'`

### 3. Suggested Makefile pattern
```makefile
e2e-k8s-simple-claude: docker-combo-claude e2e-k8s-setup ## K8s: single-team DAG, real Claude
	kubectl --context kind-$(K8S_CLUSTER) create secret generic anthropic-api-key \
		--from-literal=key=$$(cat ../.key 2>/dev/null || echo $$ANTHROPIC_API_KEY) \
		--dry-run=client -o yaml | kubectl --context kind-$(K8S_CLUSTER) apply -f -
	kubectl --context kind-$(K8S_CLUSTER) set env deployment/cortex CLAUDE_COMMAND=claude
	kubectl --context kind-$(K8S_CLUSTER) rollout status deployment/cortex --timeout=60s
	kubectl --context kind-$(K8S_CLUSTER) port-forward svc/cortex 4000:4000 4001:4001 &
	sleep 2
	cd e2e && go test -v -run TestK8sDAGSimple -timeout 300s; \
	EXIT=$$?; kill %1 2>/dev/null; exit $$EXIT
```

### 4. Timeout tuning
Real Claude takes longer. The test configs already set `timeout_minutes: 3` (simple) and `timeout_minutes: 5` (multi), and Go test timeout is 300s. These should be sufficient but may need bumping for slow API responses.
