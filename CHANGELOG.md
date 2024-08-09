# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/giantswarm/alloy-app/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/giantswarm/alloy-app/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/giantswarm/alloy-app/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/giantswarm/alloy-app/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/giantswarm/alloy-app/releases/tag/v0.1.0
