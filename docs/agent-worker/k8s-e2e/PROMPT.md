Build K8s e2e tests for Cortex, mirroring the existing Docker e2e pattern in e2e/.

## Context

- SpawnBackend.K8s (lib/cortex/spawn_backend/k8s.ex) creates bare Pods with sidecar + worker containers
- The Docker e2e pattern: Makefile manages infra (compose up/down), Go tests are HTTP clients that POST YAML configs to Cortex API, poll for completion, verify container cleanup
- We want the exact same pattern but with kind instead of Docker Compose
- Use the `default` namespace everywhere — cortex.dev/* labels are sufficient for isolation, no custom namespace needed

## What to build

### 1. K8s manifests in e2e/k8s/

- rbac.yaml — ServiceAccount `cortex-sa` with Role granting pods CRUD in `default` namespace
- secrets.yaml — `cortex-gateway-token` (value: `e2e-k8s-dag-token`) and `anthropic-api-key` (value: `fake-key`)
- cortex-deployment.yaml — Cortex as a Deployment (1 replica) using the `cortex:latest` image, same env vars as e2e/docker-compose.yml (SECRET_KEY_BASE, PHX_HOST, PORT, GRPC_PORT, CORTEX_GATEWAY_TOKEN, DATABASE_PATH, CLAUDE_COMMAND=mock), serviceAccountName: cortex-sa, ports 4000+4001, readiness probe on /health/ready. Set SPAWN_BACKEND=k8s and K8S_NAMESPACE=default so runtime.exs / config can wire SpawnBackend.K8s as the default backend.
- cortex-service.yaml — ClusterIP service exposing 4000 and 4001

### 2. Go test file: e2e/k8s_dag_e2e_test.go

Mirror docker_dag_e2e_test.go but with `backend: k8s`:

- TestK8sDAGSimple — single-team DAG, POST config with `backend: k8s`, poll for completion, verify agent pods created and cleaned up
- TestK8sDAGMultiTeam — 3-team DAG (same topology as Docker multi-team test)

Use kubectl exec or the K8s API (via kubectl proxy + HTTP) to verify pods with `cortex.dev/run-id` labels. Don't add client-go as a dependency — keep it lightweight like the Docker tests (raw HTTP to kubectl proxy or just shell out to kubectl).

### 3. Go helper file: e2e/k8s_helpers_test.go

- k8sClient struct that shells out to `kubectl` to list/get/delete pods by label in the default namespace
- waitForCortexK8s() — polls the port-forwarded Cortex /health/ready endpoint
- assertK8sPodsSpawned() — lists pods with cortex.dev labels, checks count
- assertK8sPodsCleanedUp() — verifies no cortex agent pods remain
- cleanupK8sPods() — deletes all pods with cortex.dev/component=agent-pod label

### 4. Makefile targets

Add these targets mirroring the Docker e2e pattern:

```makefile
# -- K8s E2E (kind) --
K8S_CLUSTER = cortex-e2e

e2e-k8s-setup: ## Create kind cluster + load images + deploy Cortex
	kind create cluster --name $(K8S_CLUSTER) 2>/dev/null || true
	docker build -t cortex:latest .
	cd sidecar && docker build -t cortex-agent-worker:latest -f Dockerfile.combo .
	kind load docker-image cortex:latest --name $(K8S_CLUSTER)
	kind load docker-image cortex-agent-worker:latest --name $(K8S_CLUSTER)
	kubectl --context kind-$(K8S_CLUSTER) apply -f e2e/k8s/rbac.yaml
	kubectl --context kind-$(K8S_CLUSTER) apply -f e2e/k8s/secrets.yaml
	kubectl --context kind-$(K8S_CLUSTER) apply -f e2e/k8s/cortex-deployment.yaml
	kubectl --context kind-$(K8S_CLUSTER) apply -f e2e/k8s/cortex-service.yaml
	kubectl --context kind-$(K8S_CLUSTER) rollout status deployment/cortex --timeout=120s

e2e-k8s-simple: e2e-k8s-setup ## K8s: single-team DAG (mock agent)
	kubectl --context kind-$(K8S_CLUSTER) port-forward svc/cortex 4000:4000 4001:4001 &
	sleep 2
	cd e2e && go test -v -run TestK8sDAGSimple -timeout 300s; \
	EXIT=$$?; kill %1 2>/dev/null; exit $$EXIT

e2e-k8s-multi: e2e-k8s-setup ## K8s: 3-team multi-tier DAG (mock agent)
	kubectl --context kind-$(K8S_CLUSTER) port-forward svc/cortex 4000:4000 4001:4001 &
	sleep 2
	cd e2e && go test -v -run TestK8sDAGMultiTeam -timeout 300s; \
	EXIT=$$?; kill %1 2>/dev/null; exit $$EXIT

e2e-k8s-teardown: ## Delete kind cluster
	kind delete cluster --name $(K8S_CLUSTER)
```

### 5. Config wiring

Check config/runtime.exs — if there's no way to set `backend: k8s` via env var, add support for a `SPAWN_BACKEND` env var that sets the default spawn backend. The K8s connection should auto-detect in-cluster mode (SpawnBackend.K8s.Connection already handles this).

Also check that SpawnBackend.K8s config picks up the namespace from env. Currently PodSpec.default_namespace/0 reads from app config — make sure K8S_NAMESPACE env var flows through runtime.exs into `config :cortex, Cortex.SpawnBackend.K8s, namespace: ...`.

## Constraints

- No new Go dependencies (no client-go) — use kubectl or kubectl proxy + raw HTTP
- Keep the Go test structure identical to the Docker e2e (same helpers pattern, same test flow)
- Use `default` namespace everywhere — no custom namespace needed
- Use `kind-cortex-e2e` as the kubectl context
- Tests should be skippable if kind/kubectl aren't available
- Examples should use model haiku and permission_mode bypassPermissions
