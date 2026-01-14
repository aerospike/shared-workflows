# Security Policy

## Supported Versions

This repository contains reusable GitHub Actions workflows and composite actions. Security updates are provided for all actively maintained versions.

| Version | Supported |
| ------- | --------- |
| 3.x.x   | Yes       |
| 2.x.x   | No        |
| 1.x.x   | No        |

## Reporting a Vulnerability

The Aerospike team takes security bugs seriously. We appreciate your efforts to responsibly disclose your findings.

**Please do not report security vulnerabilities through public GitHub issues.**

<!-- trunk-ignore(markdownlint/MD034) --> Instead, please report them via email to **security@aerospike.com**.

You should receive a response within 48 hours. If for some reason you do not, please follow up via email to ensure we received your original message.

Please include the following information in your report:

- Type of issue (e.g., workflow injection, secret exposure, authentication bypass, privilege escalation, etc.)
- Affected workflow or action file(s) and their paths
- The location of the affected code (tag/branch/commit or direct URL)
- Any special configuration required to reproduce the issue
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue, including how an attacker might exploit it
- Potential severity assessment (if applicable)

This information will help us triage your report more quickly.

## Scope

### In Scope

Security vulnerabilities in the following areas are within scope for reporting:

- **Workflow security vulnerabilities** (injection flaws, privilege escalation, unauthorized access, etc.)
- **Action security vulnerabilities** (improper input validation, secret exposure, etc.)
- **Configuration vulnerabilities** (exposed sensitive information, insecure defaults, etc.)
- **Dependency vulnerabilities** in actively maintained workflows and actions
- **Secret management issues** (hardcoded secrets, improper secret handling, etc.)
- **Authentication/authorization flaws** in workflow execution contexts
- **Denial of service vulnerabilities** that significantly impact workflow execution

### Out of Scope

The following are not considered security vulnerabilities for the purposes of responsible disclosure:

- Physical security issues
- Social engineering attacks
- Denial of service attacks that require significant resources or are not exploitable through standard usage
- Issues requiring physical access to infrastructure
- Issues in third-party GitHub Actions that are outside of Aerospike's direct control
- Issues that require unlikely user interaction or configuration
- Issues in consuming repositories that misuse these workflows

## Security Response Process

Upon receiving a security vulnerability report, our security team will:

1. **Acknowledge receipt** within 72 hours
2. **Initial triage** within 5 business days to assess severity and validity
3. **Investigation** to confirm and understand the issue
4. **Remediation** development and testing
5. **Coordination** with reporter on disclosure timeline
6. **Security advisory** publication when appropriate

Critical vulnerabilities will receive expedited handling. We will provide regular updates to the reporter throughout the process.

## Security Practices

### Workflow Security

All workflow contributions are subject to security review. Contributors should:

- Follow secure coding practices and avoid common vulnerabilities (OWASP Top 10, CWE Top 25)
- Never hardcode sensitive information such as credentials, API keys, or tokens
- Use GitHub Secrets for all sensitive values
- Implement proper input validation in workflow inputs and action parameters
- Follow the principle of least privilege for workflow permissions
- Implement proper error handling that does not leak sensitive information
- Use pinned action versions (SHA) rather than tags for reproducibility and security

### Dependency Management

We actively monitor and update dependencies to address security vulnerabilities:

- GitHub Actions dependencies are regularly scanned for known vulnerabilities
- Security updates are prioritized and applied in a timely manner
- All dependency updates are tested before deployment
- Actions are pinned to specific SHAs for security and reproducibility

### Secret Management

- All secrets are stored in GitHub Secrets and never committed to the repository
- Secrets are only accessed through secure GitHub Actions mechanisms
- Workflows use minimal required permissions
- Secret values are never logged or exposed in workflow outputs

## Security Updates

Security updates will be released as part of our standard release process. Critical security vulnerabilities may result in out-of-cycle security releases. Security advisories will be published detailing the nature of the vulnerability and the remediation steps taken.

## Preferred Languages

We prefer all communications to be in English.

## Policy

Aerospike follows the principle of [Responsible Disclosure](https://en.wikipedia.org/wiki/Responsible_disclosure). We ask that security researchers:

- Act in good faith to avoid privacy violations, data destruction, and service interruption
- Keep vulnerability details confidential until we have resolved the issue and agreed upon disclosure timing
- Do not access or modify data that does not belong to you
- Provide us with a reasonable amount of time to address the issue before public disclosure

We will acknowledge researchers who responsibly disclose vulnerabilities, if they so desire, in our security advisories.
