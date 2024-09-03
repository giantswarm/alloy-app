package basic

import (
	"os"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/pkg/config"
	"github.com/giantswarm/apptest-framework/pkg/state"
	"github.com/giantswarm/apptest-framework/pkg/suite"

	"github.com/giantswarm/clustertest/pkg/application"
	"github.com/giantswarm/clustertest/pkg/logger"
	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/types"
)

const (
	isUpgrade = false
)

func TestConfig(t *testing.T) {
	var installNamespace = "kube-system"

	appConfig := config.MustLoad("../../config.yaml")

	// Ensure we use an actual semver version instead of "latest"
	if os.Getenv("E2E_APP_VERSION") == "latest" {
		latestVersion, err := application.GetLatestAppVersion(appConfig.RepoName)
		if err != nil {
			panic(err)
		}
		latestVersion = strings.TrimPrefix(latestVersion, "v")
		logger.Log("Overriding 'latest' version to '%s'", latestVersion)
		os.Setenv("E2E_APP_VERSION", latestVersion)

		defer (func() {
			// Set the env back to latest so it doesn't conflict with other suites
			os.Setenv("E2E_APP_VERSION", "latest")
		})()
	}

	suite.New(appConfig).
		WithInstallNamespace(installNamespace).
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
		BeforeUpgrade(func() {

			It("should not have run the before upgrade", func() {
				logger.Log("This isn't an upgrade test so this test case shouldn't have happened")
				Fail("Shouldn't perform pre-upgrade tests if not an upgrade test suite")
			})

		}).
		Tests(func() {
			It("should be disabled by default", func() {
				When("the app is alloy logs", func() {
					wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
					Expect(err).NotTo(HaveOccurred())

					Eventually(func() error {
						logger.Log("Checking if daemonset does exists in the workload cluster")
						var ds appsv1.DaemonSet
						err := wcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-logs"}, &ds)
						if err != nil {
							logger.Log("Failed to get daemonset: %v", err)
						}
						return err
					}).
						WithPolling(5 * time.Second).
						WithTimeout(5 * time.Minute).
						Should(HaveOccurred())
				})

				When("the app is alloy metrics", func() {
					wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
					Expect(err).NotTo(HaveOccurred())

					Eventually(func() error {
						logger.Log("Checking if statefulset does exists in the workload cluster")
						var sts appsv1.StatefulSet
						err := wcClient.Get(state.GetContext(), types.NamespacedName{Namespace: installNamespace, Name: "alloy-metrics"}, &sts)
						if err != nil {
							logger.Log("Failed to get statefulset: %v", err)
						}
						return err
					}).
						WithPolling(5 * time.Second).
						WithTimeout(5 * time.Minute).
						Should(HaveOccurred())
				})
			})

		}).
		Run(t, "Basic Test")
}
