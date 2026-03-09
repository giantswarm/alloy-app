package mc

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
	isUpgrade        = false
	installNamespace = "kube-system"
)

func TestMC(t *testing.T) {
	suite.New().
		WithInstallNamespace(installNamespace).
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		InAppBundle("observability-bundle").
		AfterClusterReady(func() {
			It("should connect to the management cluster", func() {
				Expect(state.GetFramework().MC().CheckConnection()).To(Succeed())
			})
		}).
		Tests(func() {
			It("should have alloy-metrics statefulset ready on the MC", func() {
				mcClient := state.GetFramework().MC()

				Eventually(func() bool {
					logger.Log("Checking alloy-metrics statefulset")
					var sts appsv1.StatefulSet
					if err := mcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-metrics"}, &sts); err != nil {
						return false
					}
					return sts.Status.ReadyReplicas == *sts.Spec.Replicas
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})

			It("should have alloy-logs daemonset ready on the MC", func() {
				mcClient := state.GetFramework().MC()

				Eventually(func() bool {
					logger.Log("Checking alloy-logs daemonset")
					var ds appsv1.DaemonSet
					if err := mcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-logs"}, &ds); err != nil {
						return false
					}
					return ds.Status.NumberReady == ds.Status.DesiredNumberScheduled
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})

			It("should have alloy-events deployment ready on the MC", func() {
				mcClient := state.GetFramework().MC()

				Eventually(func() bool {
					logger.Log("Checking alloy-events deployment")
					var dep appsv1.Deployment
					if err := mcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-events"}, &dep); err != nil {
						return false
					}
					return dep.Status.ReadyReplicas == *dep.Spec.Replicas
				}).WithPolling(5 * time.Second).WithTimeout(5 * time.Minute).Should(BeTrue())
			})
		}).
		Run(t, "Alloy MC test")
}
