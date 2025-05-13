# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Comprehensive property-based tests for state preservation
- Enhanced documentation for all modules with detailed examples
- Improved test organization with describe blocks and better coverage
- New benchmarking capabilities to measure performance overhead
- Additional edge case tests for supervisor restart limits

### Changed
- Updated dependencies to latest versions
- Improved project structure with better organization of test files
- Enhanced README with clearer installation and usage instructions

## [0.3.0] - 2023-03-22

### Added
- Support for process migration between supervisors, including remote nodes
- Process dictionary preservation between crashes
- Listener hooks for state changes and termination events
- ETS table ownership transfer capabilities
- More examples in the documentation

### Changed
- Improved supervision tree structure for better fault tolerance
- Enhanced API for interacting with Peeper processes
- Refactored internal state handling for better performance
- Updated documentation with more comprehensive examples
- Refined error handling and logging

### Fixed
- Issue with ETS table inheritance during crashes
- Race condition in state keeper process
- Improved handling of edge cases in process initialization

## [0.2.0] - 2023-01-15

### Added
- Support for ETS table preservation between crashes
- Handle_continue callback support in GenServer implementation
- More comprehensive typespecs for better Dialyzer checks
- Auto-shutdown configuration options for supervisors

### Changed
- Refined API for better ergonomics
- Improved documentation with more complete examples
- Enhanced test suite with better coverage

### Fixed
- Issue with state restoration after complex crashes
- Bug in child_spec generation
- Race condition in process restart sequence

## [0.1.0] - 2022-11-10

### Added
- Initial release with core functionality
- Basic GenServer-like API with state preservation between crashes
- Simple supervision tree for managing worker and state processes
- Support for named processes
- Basic documentation and examples
- Initial test suite covering basic functionality

[Unreleased]: https://github.com/am-kantox/peeper/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/am-kantox/peeper/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/am-kantox/peeper/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/am-kantox/peeper/releases/tag/v0.1.0

