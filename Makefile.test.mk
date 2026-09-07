##@ Chart tests

# Named "Makefile.test.mk" rather than "Makefile.custom.mk" on purpose: `Makefile` pulls
# these in with `include Makefile.*.mk`, which expands sorted, so a name sorting before
# "Makefile.gen.app.mk" would steal the default goal.
#
# These targets deliberately use whatever `helm` is on PATH. `ct lint` (see the lint-chart
# target) pins giantswarm/helm-chart-testing:v3.0.0-rc.1, which ships helm 3.1.2 whose
# `helm lint` does not fail on template rendering errors, so it cannot be relied on to catch
# them.

CHART_DIR := helm/alloy
CHART_REPO_NAME := grafana
CHART_REPO_URL := https://grafana.github.io/helm-charts

# Pretend the Kyverno and VPA APIs exist, so the templates guarded by
# `.Capabilities.APIVersions.Has` are actually rendered.
CHART_API_VERSIONS := \
	--api-versions kyverno.io/v2/PolicyException \
	--api-versions autoscaling.k8s.io/v1

# Switch every optional Giant Swarm feature on, so a template that is not gated on
# `alloy.enabled` cannot hide behind a disabled feature flag. networkPolicy.flavor and
# kyvernoPolicyExceptions.enabled keep their defaults (cilium / true) on purpose: disabling
# the chart must not require touching them.
CHART_ALL_FEATURES := \
	--set verticalPodAutoscaler.enabled=true \
	--set 'podLogs[0].name=test' \
	--set 'podLogs[0].namespace=test' \
	--set 'podLogs[0].spec.selector.matchLabels.app=test' \
	--set 'alloy.alloy.extraSecretEnv[0].name=TEST' \
	--set 'alloy.alloy.extraSecretEnv[0].value=test' \
	--set 'vcenterReceiver.enabled=true'

# Objects the chart must produce when it is enabled. Guards against a gate that is
# accidentally always false, which would pass the disabled check for the wrong reason.
CHART_EXPECTED_KINDS := CiliumNetworkPolicy PolicyException VerticalPodAutoscaler PodLogs Secret DaemonSet Role RoleBinding

.PHONY: test-chart test-chart-render test-chart-disabled chart-deps test-liveness-probe

test-chart: test-chart-render test-chart-disabled ## Run all chart rendering tests.

chart-deps: ## Fetch the upstream Alloy subchart.
	helm repo add $(CHART_REPO_NAME) $(CHART_REPO_URL) --force-update
	helm dependency build $(CHART_DIR)

test-chart-render: chart-deps ## Assert the chart renders with every ci/*-values.yaml file.
	@echo "====> $@"
	@for values in $(CHART_DIR)/ci/*-values.yaml; do \
		printf '%s\n' "--> $$values"; \
		helm template test $(CHART_DIR) --values "$$values" $(CHART_API_VERSIONS) >/dev/null || exit 1; \
	done
	@echo "PASS"

test-chart-disabled: chart-deps ## Assert `alloy.enabled=false` renders nothing at all, and that the chart still renders everything when enabled.
	@echo "====> $@"
	@echo "--> alloy.enabled=false: expecting zero rendered objects"
	@out=$$(helm template test $(CHART_DIR) --set alloy.enabled=false $(CHART_ALL_FEATURES) $(CHART_API_VERSIONS)) || exit 1; \
	if printf '%s\n' "$$out" | grep -qE '^(kind|apiVersion):'; then \
		echo "FAIL: alloy.enabled=false still renders objects:"; printf '%s\n' "$$out"; exit 1; \
	fi
	@echo "--> alloy.enabled=true: expecting $(CHART_EXPECTED_KINDS)"
	@out=$$(helm template test $(CHART_DIR) --set alloy.enabled=true $(CHART_ALL_FEATURES) $(CHART_API_VERSIONS)) || exit 1; \
	for kind in $(CHART_EXPECTED_KINDS); do \
		printf '%s\n' "$$out" | grep -q "^kind: $$kind$$" || { echo "FAIL: expected 'kind: $$kind' in the enabled render"; exit 1; }; \
	done
	@echo "PASS"

##@ Script tests

test-liveness-probe: ## Run scripts/mimir-rules-liveness-probe.sh against a mock Alloy API and Mimir ruler.
	@echo "====> $@"
	@tests/liveness-probe/run-tests.sh
