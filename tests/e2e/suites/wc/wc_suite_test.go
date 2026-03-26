package wc

import (
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/v4/pkg/state"
	"github.com/giantswarm/apptest-framework/v4/pkg/suite"
	"github.com/giantswarm/clustertest/v4/pkg/client"
	"github.com/giantswarm/clustertest/v4/pkg/logger"
	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/types"
)

const (
	isUpgrade        = false
	installNamespace = "kube-system"
)

func TestWC(t *testing.T) {
	suite.New().
		WithInstallNamespace(installNamespace).
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		// WithInstallName is intentionally omitted: this suite installs the
		// observability-bundle as a whole and checks all three alloy instances
		// (alloy-metrics, alloy-logs, alloy-events) within a single cluster.
		InAppBundle("observability-bundle").
		AfterClusterReady(func() {
			It("should connect to the management cluster", func() {
				Expect(state.GetFramework().MC().CheckConnection()).To(Succeed())
			})

			It("should connect to the workload cluster", func() {
				wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
				Expect(err).NotTo(HaveOccurred())
				Expect(wcClient.CheckConnection()).To(Succeed())
			})
		}).
		Tests(func() {
			var wcClient *client.Client

			BeforeEach(func() {
				var err error
				wcClient, err = state.GetFramework().WC(state.GetCluster().Name)
				Expect(err).NotTo(HaveOccurred())
			})

			It("should have alloy-metrics statefulset ready", func() {
				Eventually(func() bool {
					logger.Log("Checking alloy-metrics statefulset")
					var sts appsv1.StatefulSet
					if err := wcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-metrics"}, &sts); err != nil {
						return false
					}
					return sts.Status.ReadyReplicas == *sts.Spec.Replicas
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})

			It("should have alloy-logs daemonset ready", func() {
				Eventually(func() bool {
					logger.Log("Checking alloy-logs daemonset")
					var ds appsv1.DaemonSet
					if err := wcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-logs"}, &ds); err != nil {
						return false
					}
					return ds.Status.NumberReady == ds.Status.DesiredNumberScheduled
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})

			It("should have alloy-events deployment ready", func() {
				Eventually(func() bool {
					logger.Log("Checking alloy-events deployment")
					var dep appsv1.Deployment
					if err := wcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-events"}, &dep); err != nil {
						return false
					}
					return dep.Status.ReadyReplicas == *dep.Spec.Replicas
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})
		}).
		Run(t, "Alloy WC test")
}
