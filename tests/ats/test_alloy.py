import logging
from typing import List, Tuple

import pytest
import pykube
from pytest_helm_charts.clusters import Cluster
from pytest_helm_charts.k8s.stateful_set import wait_for_stateful_sets_to_run


logger = logging.getLogger(__name__)

namespace_name = "kube-system"
statefulset_name = "alloy"

timeout: int = 900

@pytest.mark.smoke
def test_api_working(kube_cluster: Cluster) -> None:
    """Very minimalistic example of using the [kube_cluster](pytest_helm_charts.fixtures.kube_cluster)
    fixture to get an instance of [Cluster](pytest_helm_charts.clusters.Cluster) under test
    and access its [kube_client](pytest_helm_charts.clusters.Cluster.kube_client) property
    to get access to Kubernetes API of cluster under test.
    Please refer to [pykube](https://pykube.readthedocs.io/en/latest/api/pykube.html) to get docs
    for [HTTPClient](https://pykube.readthedocs.io/en/latest/api/pykube.html#pykube.http.HTTPClient).
    """
    assert kube_cluster.kube_client is not None
    assert len(pykube.Node.objects(kube_cluster.kube_client)) >= 1

# scope "module" means this is run only once, for the first test case requesting! It might be tricky
# if you want to assert this multiple times
# -- Checking that mimir's statefulset is present on the cluster
@pytest.fixture(scope="module")
def components(kube_cluster: Cluster) -> List[pykube.StatefulSet]:
    logger.info("Waiting for alloy statefulset component to be deployed..")

    components_ready = wait_for_components(kube_cluster)

    logger.info("alloy component are deployed..")

    return components_ready

def wait_for_components(kube_cluster: Cluster) -> List[pykube.StatefulSet]:
    statefulsets = wait_for_stateful_sets_to_run(
        kube_cluster.kube_client,
        [statefulset_name],
        namespace_name,
        timeout,
    )
    return (statefulsets)

@pytest.fixture(scope="module")
def pods(kube_cluster: Cluster) -> List[pykube.Pod]:
    pods = pykube.Pod.objects(kube_cluster.kube_client)

    pods = pods.filter(namespace=namespace_name, selector={
                       'app.kubernetes.io/name': 'alloy', 'app.kubernetes.io/instance': 'alloy'})

    return pods

# when we start the tests on circleci, we have to wait for pods to be available, hence
# this additional delay and retries
# -- Checking that all pods from alloy's statefulset are available (i.e in "Ready" state)
@pytest.mark.smoke
@pytest.mark.upgrade
@pytest.mark.flaky(reruns=5, reruns_delay=10)
def test_pods_available(components: List[pykube.StatefulSet]):
    # loop over the list of deployments
    for d in components:
        assert int(d.obj["status"]["readyReplicas"]) == int(d.obj["spec"]["replicas"])
