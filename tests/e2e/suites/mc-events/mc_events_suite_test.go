package mcevents

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

func TestMCEvents(t *testing.T) {
	var installNamespace = "kube-system"

	suite.New().
		WithInstallNamespace(installNamespace).
		WithInstallName("alloy-events").
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		InAppBundle("observability-bundle").
		AfterClusterReady(func() {
			It("should connect to the management cluster", func() {
				err := state.GetFramework().MC().CheckConnection()
				Expect(err).NotTo(HaveOccurred())
			})
		}).
		Tests(func() {
			It("should have alloy-events deployment running on the MC", func() {
				mcClient := state.GetFramework().MC()

				Eventually(func() error {
					logger.Log("Checking if alloy-events deployment exists on the management cluster")
					var dep appsv1.Deployment
					return mcClient.Get(state.GetContext(), types.NamespacedName{
						Namespace: installNamespace,
						Name:      "alloy-events",
					}, &dep)
				}).
					WithPolling(5 * time.Second).
					WithTimeout(5 * time.Minute).
					ShouldNot(HaveOccurred())
			})

			It("should have alloy-events deployment ready on the MC", func() {
				mcClient := state.GetFramework().MC()

				Eventually(func() bool {
					logger.Log("Checking if alloy-events deployment is ready on the management cluster")
					var dep appsv1.Deployment
					err := mcClient.Get(state.GetContext(), types.NamespacedName{
						Namespace: installNamespace,
						Name:      "alloy-events",
					}, &dep)
					if err != nil {
						return false
					}
					return dep.Status.ReadyReplicas == *dep.Spec.Replicas
				}).
					WithPolling(5 * time.Second).
					WithTimeout(5 * time.Minute).
					Should(BeTrue())
			})
		}).
		Run(t, "Alloy events MC test")
}
