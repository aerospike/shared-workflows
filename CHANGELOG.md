## [](https://github.com/aerospike/shared-workflows/compare/v2.0.1...v) (2025-11-04)

### Bug Fixes

* **workflows:** [INFRA-235] deploy for rpm and deb should not include prefix ([#73](https://github.com/aerospike/shared-workflows/issues/73)) ([f9da14b](https://github.com/aerospike/shared-workflows/commit/f9da14bdbd362d362675ff60de48e583b6d054eb))
## [2.0.0](https://github.com/aerospike/shared-workflows/compare/v1.2.0...v2.0.0) (2025-10-16)

### ⚠ BREAKING CHANGES

* **workflows:** update reusable workflows to use consistent naming conventions (#58)
* **workflows:** build info in build step [INFRA-189] (#53)

### Features

* **release:** add semantic release configuration and GitHub workflow for automated releases ([84b34f3](https://github.com/aerospike/shared-workflows/commit/84b34f32fd30be168dfe23e7de5af52c9b97d9cf))
* **workflows:** add example Docker build and deploy workflow ([7420fc8](https://github.com/aerospike/shared-workflows/commit/7420fc85824d8db35263563939ac2a982eb1760c))
* **workflows:** add use-artifacts job for JFrog CLI integration and Docker build ([20eaf2b](https://github.com/aerospike/shared-workflows/commit/20eaf2b44746e57e115d34a7adaa99787ecadb57))
* **workflows:** add xray scan step to docker build workflow ([81f5a80](https://github.com/aerospike/shared-workflows/commit/81f5a808c226b1fbc0924f2fc205dd2838dff3d2))
* **workflows:** example reusable integration workflow ([e9de96d](https://github.com/aerospike/shared-workflows/commit/e9de96d920618b04c155e5bbb8042cf12cdf50fe))

### Bug Fixes

* duplicate release-notes-generator item in .releaserc.json ([4412523](https://github.com/aerospike/shared-workflows/commit/44125235f019eed15da8a71847ed3c0e4ef2a57a))
* **workflows:**  check for create-release-bundle job to trigger only on workflow_dispatch event ([bfa5ab9](https://github.com/aerospike/shared-workflows/commit/bfa5ab9189f486eb58ae791a92bfd503aabc86c1))
* **workflows:**  consistency is the enemy of enterprise ([205f2b1](https://github.com/aerospike/shared-workflows/commit/205f2b17f3dc75391a96e68372720df01e12cbbb))
* **workflows:**  problems escaping auth lead to doing things "the right way" ([126817d](https://github.com/aerospike/shared-workflows/commit/126817d785a8dd641a1cee0fb6ce11b7d80491bf))
* **workflows:** add Docker login step ([6edeaa9](https://github.com/aerospike/shared-workflows/commit/6edeaa9bbaae927045278a089a527bbe4db83d9a))
* **workflows:** automated build name and build number not working ([76f30c2](https://github.com/aerospike/shared-workflows/commit/76f30c2ac3e88eb3fdcc28c0cd9ca6d06c6587db))
* **workflows:** update checkout reference to specific commit ([bf987f5](https://github.com/aerospike/shared-workflows/commit/bf987f51782e3157de0cd2e4664a42b3ba3b73b2))
* **workflows:** update checkout references to latest commit for reusable workflows ([c339172](https://github.com/aerospike/shared-workflows/commit/c3391724809c73637fb1efe8a224789ee234851c))
* **workflows:** update CHECKOUT_REF to use github.workflow_sha for latest commit reference ([89275e3](https://github.com/aerospike/shared-workflows/commit/89275e31ce190f533705ab4dbc2e84a0908cd845))
* **workflows:** update JFrog CLI version and docker login action version ([19afa38](https://github.com/aerospike/shared-workflows/commit/19afa38d72b1802b7ebd9bcf91375b2aa2f91438))
* **workflows:** update repository URL format in reusable integration workflow ([0820609](https://github.com/aerospike/shared-workflows/commit/08206099d6b26d504537ec123f3d2d1c4c272ddf))

### Code Refactoring

* **workflows:** build info in build step [INFRA-189] ([#53](https://github.com/aerospike/shared-workflows/issues/53)) ([0da06cb](https://github.com/aerospike/shared-workflows/commit/0da06cb2182165b125dc219ca2fda09732ca0fa4))
* **workflows:** update reusable workflows to use consistent naming conventions ([#58](https://github.com/aerospike/shared-workflows/issues/58)) ([4d3239c](https://github.com/aerospike/shared-workflows/commit/4d3239c1ab01899af88e3dddca06cbd3736e53fe))
