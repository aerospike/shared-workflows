# Collect conformance report

Read every `conformance-report.json` under a directory, append a step summary, and fail the job for the two results that must not pass silently.

The report shape is `schema/report.schema.json` in [aerospike-client-conformance](https://github.com/aerospike/aerospike-client-conformance). Each client runner writes one report. Declarations live in the client repository as `<runtime>-declared.yaml`. The Java file is `java-declared.yaml`: a fixture path, then `result` and `reason` per case that is not an implicit pass.

## Gate

| Actual result | Declared result            | Job                                              |
| ------------- | -------------------------- | ------------------------------------------------ |
| `fail`        | `pass`, or no row          | Fails. This is a pass to fail regression.        |
| `unsupported` | anything but `unsupported` | Fails. The unsupported result was not declared.  |
| `unsupported` | `unsupported`              | Stays green. The reason is still in the summary. |
| `fail`        | `fail`                     | Stays green. The failure stays in the summary.   |
| `blocked`     | no row                     | Stays green. Blocked is copied from the fixture. |

A row that is not in the declaration file is declared `pass`, except an actual `blocked` row, which is treated as declared `blocked`. That matches the runner: an omitted row is pass, and an omitted blocked fixture row is blocked.

Other differences, such as a declared failure that now passes, are listed in the summary and do not fail this action. The runtime test is what forces the declaration to be updated.

Run this step with `if: always()` so the summary is written when the runner itself failed. The runner still owns row-by-row equality. This action is the cross-runtime view that keeps a declared unsupported result from looking like a skipped test.

## Inputs

| Input                    | Required | Default | Description                                                                                        |
| ------------------------ | -------- | ------- | -------------------------------------------------------------------------------------------------- |
| `reports-directory`      | Yes      | —       | Directory searched for `conformance-report.json`                                                   |
| `declarations-directory` | No       | `""`    | Directory searched for `<runtime>-declared.yaml`. Without it, every unsupported row is undeclared. |
| `fixture-set-version`    | No       | `""`    | When set, every report must name this fixture set version                                          |

## Outputs

| Output | Description                                                            |
| ------ | ---------------------------------------------------------------------- |
| `gate` | `success`, or `failure` when the gate trips or a report cannot be read |

## Example

```yaml
- name: Collect conformance reports
  if: always()
  uses: aerospike/shared-workflows/.github/actions/collect-conformance-report@<sha> # vX.Y.Z
  with:
    reports-directory: client/target
    declarations-directory: client/src/test/resources/conformance
    fixture-set-version: 0.1.0
```

`reports-directory` may contain one report per runtime, including after `actions/download-artifact` with `merge-multiple: false`. The runtime name comes from the report, and it must match the `<runtime>` in `<runtime>-declared.yaml`.
