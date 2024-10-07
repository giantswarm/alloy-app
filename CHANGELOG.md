# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add PodLogs as helm chart template.

### Changed

- Upgrade Alloy upstream chart from 0.7.0 to 0.9.1
  - This bumps the version of Alloy from 1.3.1 to 1.4.2
  - Alloy Breaking changes
    - Some debug metrics for otelcol components have changed.
    - [otelcol.processor.transform] The functions convert_sum_to_gauge and convert_gauge_to_sum must now be used in the metric context rather than in the datapoint context.
    - Upgrade Beyla from 1.7.0 to 1.8.2. A complete list of changes can be found on the Beyla releases page: https://github.com/grafana/beyla/releases.
    - See [Alloy v1.4.0 release notes](https://github.com/grafana/alloy/releases/tag/v1.4.0)
  - Helm chart changes, see [Alloy Helm chart v0.9.0 CHANGELOG](https://github.com/grafana/alloy/blob/helm-chart/0.9.0/operations/helm/charts/alloy/CHANGELOG.md)

## [0.5.2] - 2024-09-17

### Added

- Add helm chart templating test in ci pipeline.
- Add tests with ats in ci pipeline.
- Push alloy as a gateway component in collections.

## [0.5.1] - 2024-09-03

### Fixed

- Fix incorrect value path in vertical pod autoscaler.

## [0.5.0] - 2024-09-02

### Added

- Add VPA and default resource requests and limits (https://github.com/giantswarm/roadmap/issues/358)

### Fixed

- Ensure alloy can access root filesystem in read mode only.

## [0.4.1] - 2024-08-20

### Fixed

- Disable Grafana Labs reporting.

## [0.4.0] - 2024-08-12

### Added

- Add Secret template in helm chart to alloy for environment variables injection.

### Changed

- Update alloy upstream chart from 0.5.1 to 0.6.0
  - This bumps the version of alloy from 1.2.1 to 1.3.0
  - It does introduces breaking changes:
    - [`otelcol.exporter.otlp`,`otelcol.exporter.loadbalancing`]: Change the default gRPC load balancing strategy.
    - `beyla.ebpf` default value for argument `unmatched` in the block `routes`.
    - more details at https://github.com/grafana/alloy/blob/v1.3.0/CHANGELOG.md#v130

## [0.3.1] - 2024-07-24

### Added

- Add some useful configuration into the logs helm chart values example

### Fixed

- Allow traffic to nginx-ingress-controller (needed when LB is skipped).

## [0.3.0] - 2024-07-15

### Added

- Add kyverno policy exception for run as non root

### Changed

- Upgrade alloy upstream chart from 0.4.0 to 0.5.1
  - This bumps the version of alloy from 1.2.0 to 1.2.1

## [0.2.0] - 2024-07-08

### Changed

- Change app catalog from giantswarm-playground to giantswarm

## [0.1.0] - 2024-07-08

- changed: `app.giantswarm.io` label group was changed to `application.giantswarm.io`

[Unreleased]: https://github.com/giantswarm/alloy-app/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/giantswarm/alloy-app/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/giantswarm/alloy-app/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/giantswarm/alloy-app/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/giantswarm/alloy-app/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/giantswarm/alloy-app/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/giantswarm/alloy-app/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/giantswarm/alloy-app/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/giantswarm/alloy-app/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/giantswarm/alloy-app/releases/tag/v0.1.0
