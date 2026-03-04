package wcmetrics

import (
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/v3/pkg/state"
	"github.com/giantswarm/apptest-framework/v3/pkg/suite"

	"github.com/giantswarm/clustertest/v3/pkg/logger"
	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/types"
)

const (
	isUpgrade = false
)

func TestWCMetrics(t *testing.T) {
	var installNamespace = "kube-system"

	suite.New().
		WithInstallNamespace(installNamespace).
		WithInstallName("alloy-metrics").
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		InAppBundle("observability-bundle").
		AfterClusterReady(func() {
			It("should connect to the management cluster", func() {
				err := state.GetFramework().MC().CheckConnection()
				Expect(err).NotTo(HaveOccurred())
			})

			It("should connect to the workload cluster", func() {
				wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
				Expect(err).NotTo(HaveOccurred())
				err = wcClient.CheckConnection()
				Expect(err).NotTo(HaveOccurred())
			})
		}).
		Tests(func() {
			It("should have alloy-metrics statefulset running", func() {
				wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
				Expect(err).NotTo(HaveOccurred())

				Eventually(func() error {
					logger.Log("Checking if alloy-metrics statefulset exists in the workload cluster")
					var sts appsv1.StatefulSet
					return wcClient.Get(state.GetContext(), types.NamespacedName{
						Namespace: installNamespace,
						Name:      "alloy-metrics",
					}, &sts)
				}).
					WithPolling(5 * time.Second).
					WithTimeout(5 * time.Minute).
					ShouldNot(HaveOccurred())
			})

			It("should have alloy-metrics statefulset ready", func() {
				wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
				Expect(err).NotTo(HaveOccurred())

				Eventually(func() bool {
					logger.Log("Checking if alloy-metrics statefulset is ready")
					var sts appsv1.StatefulSet
					err := wcClient.Get(state.GetContext(), types.NamespacedName{
						Namespace: installNamespace,
						Name:      "alloy-metrics",
					}, &sts)
					if err != nil {
						return false
					}
					return sts.Status.ReadyReplicas == *sts.Spec.Replicas
				}).
					WithPolling(5 * time.Second).
					WithTimeout(5 * time.Minute).
					Should(BeTrue())
			})
		}).
		Run(t, "Alloy metrics WC test")
}
