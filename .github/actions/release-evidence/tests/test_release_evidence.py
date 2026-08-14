#!/usr/bin/env python3
"""Unit tests for release-evidence.py.

Run: python3 -m unittest discover -s .github/actions/release-evidence/tests

Transport is stubbed, so these cover the parts that decide what a document claims: where an
artifact sits in the pipeline, whether a gap is a skipped gate or work still to come, and
whether a claim has a record behind it.
"""
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "release-evidence.py"
spec = importlib.util.spec_from_file_location("release_evidence", SCRIPT)
rev = importlib.util.module_from_spec(spec)
sys.modules["release_evidence"] = rev
spec.loader.exec_module(rev)


class StageOfRepo(unittest.TestCase):
    def test_reads_the_stage_from_the_environment_segment(self):
        self.assertEqual(rev.stage_of_repo("clients-pypi-dev-local"), "DEV")
        self.assertEqual(rev.stage_of_repo("database-deb-test-local"), "TEST")
        self.assertEqual(rev.stage_of_repo("database-deb-stage-local"), "STAGE")

    def test_distinguishes_the_two_prod_repositories(self):
        self.assertEqual(rev.stage_of_repo("clients-maven-prod-public-local"), "PROD")
        self.assertEqual(rev.stage_of_repo("clients-maven-prod-internal-local"), "INTERNAL")

    def test_maps_both_preview_repositories_to_one_stage(self):
        self.assertEqual(rev.stage_of_repo("cloud-helm-preview-public-local"), "PREVIEW")
        self.assertEqual(rev.stage_of_repo("cloud-helm-preview-restricted-local"), "PREVIEW")

    def test_returns_none_for_a_repository_naming_no_stage(self):
        self.assertIsNone(rev.stage_of_repo("clients-release-bundles-v2"))
        self.assertIsNone(rev.stage_of_repo("maven-remote"))

    def test_a_project_named_after_a_stage_does_not_confuse_it(self):
        # The project segment leads, so only the trailing environment should be read.
        self.assertEqual(rev.stage_of_repo("stage-npm-dev-local"), "DEV")


class PackageTypeOfRepo(unittest.TestCase):
    def test_reads_the_type_segment(self):
        self.assertEqual(rev.package_type_of_repo("clients-pypi-dev-local"), "pypi")
        self.assertEqual(rev.package_type_of_repo("clients-maven-prod-public-local"), "maven")

    def test_maps_repository_type_names_onto_package_types(self):
        self.assertEqual(rev.package_type_of_repo("database-deb-dev-local"), "debian")
        self.assertEqual(rev.package_type_of_repo("database-rpm-dev-local"), "yum")
        self.assertEqual(rev.package_type_of_repo("cloud-container-dev-local"), "docker")


class Normalize(unittest.TestCase):
    def test_strips_a_full_artifactory_url(self):
        self.assertEqual(
            rev.normalize("https://aerospike.jfrog.io/artifactory/clients-pypi-dev-local/a.whl"),
            "clients-pypi-dev-local/a.whl")

    def test_strips_a_package_type_endpoint(self):
        self.assertEqual(rev.normalize("api/pypi/pypi/simple/aerospike"), "pypi/simple/aerospike")


class StageClassification(unittest.TestCase):
    """collect() with transport stubbed, which is where reached/pending/skipped are decided."""

    def build(self, promotion_stages, resident_repos, sealed=True):
        artifacts = [{"type": "pypi", "repos": resident_repos, "attestation": None,
                      "commit": None, "public": None, "published_build_linked": None}]
        promotions = [{"stage": s, "when": f"2026-08-0{i}", "by": "ci", "repos": [],
                       "mutable": False, "seals": "abc"}
                      for i, s in enumerate(promotion_stages, start=1)]
        return artifacts, promotions, sealed

    def derive(self, promotion_stages, resident_repos, sealed=True):
        # Mirrors the derivation in collect() so the classification can be tested without
        # standing up the whole transport layer.
        artifacts, promotions, sealed = self.build(promotion_stages, resident_repos, sealed)
        stages = [p["stage"] for p in promotions]
        resident = sorted({rev.stage_of_repo(r) for a in artifacts for r in a["repos"]} - {None},
                          key=lambda s: rev.STAGE_ORDER.index(s) if s in rev.STAGE_ORDER
                          else len(rev.STAGE_ORDER))
        reached = [s for s in rev.STAGE_ORDER if s in set(stages) | set(resident)]
        if "INTERNAL" in stages or "INTERNAL" in resident:
            reached.append("INTERNAL")
        expected = rev.STAGE_ORDER[:-1] if "INTERNAL" in reached else rev.STAGE_ORDER
        furthest = max((expected.index(s) for s in reached if s in expected), default=-1)
        return {
            "stages_reached": reached,
            "skipped_stages": [s for s in expected[:furthest + 1] if s not in reached],
            "pending_stages": list(expected[furthest + 1:]),
        }

    def test_an_artifact_only_in_dev_has_everything_pending_and_nothing_skipped(self):
        d = self.derive([], ["clients-pypi-dev-local"], sealed=False)
        self.assertEqual(d["stages_reached"], ["DEV"])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], ["TEST", "STAGE", "PREVIEW", "PROD"])

    def test_repository_residence_counts_when_no_promotion_record_exists(self):
        d = self.derive([], ["clients-pypi-dev-local", "clients-pypi-test-local"])
        self.assertEqual(d["stages_reached"], ["DEV", "TEST"])
        self.assertEqual(d["pending_stages"], ["STAGE", "PREVIEW", "PROD"])

    def test_a_gate_passed_over_is_reported_as_skipped(self):
        d = self.derive(["DEV", "TEST", "PROD"], ["clients-pypi-prod-public-local"])
        self.assertEqual(d["skipped_stages"], ["STAGE", "PREVIEW"])
        self.assertEqual(d["pending_stages"], [])

    def test_internal_is_terminal_so_prod_is_not_counted_against_it(self):
        d = self.derive(["DEV", "TEST", "STAGE", "INTERNAL"], [])
        self.assertNotIn("PROD", d["skipped_stages"])
        self.assertNotIn("PROD", d["pending_stages"])

    def test_nothing_anywhere_is_pending_rather_than_skipped(self):
        d = self.derive([], [])
        self.assertEqual(d["stages_reached"], [])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], rev.STAGE_ORDER)


class ClaimsRequireRecords(unittest.TestCase):
    """No claim may appear without the record that backs it."""

    def evidence(self, release, promotions, sealed):
        return {
            "release": release, "promotions": promotions, "pr": None, "project": "clients",
            "artifacts": [{"type": "pypi", "path": "a.whl", "commit": None, "attestation": None,
                           "public": None, "repos": ["clients-pypi-dev-local"],
                           "published_build_linked": None, "sealed": False}],
            "source": None, "signatures": {}, "about": "",
            "derived": {"types": ["pypi"], "attested_types": [], "unattested_types": ["pypi"],
                        "stages": [], "terminal_stage": None, "sealed": sealed,
                        "stages_reached": ["DEV"], "resident_stages": ["DEV"],
                        "skipped_stages": [], "pending_stages": ["TEST", "STAGE", "PREVIEW", "PROD"],
                        "self_approved": False, "independently_approved": False,
                        "unlinked_published": [], "any_commit": False},
        }

    def test_an_unsealed_artifact_claims_nothing_about_custody(self):
        rows = rev.claim_rows(self.evidence(None, [], False))
        self.assertEqual(rows, [])

    def pr_evidence(self, approvers, merged_at):
        ev = self.evidence(None, [], False)
        ev["pr"] = {"number": 7, "title": "t", "author": "writer", "merged_at": merged_at,
                    "repo": "aerospike/shared-workflows", "approvers": approvers}
        ev["derived"]["independently_approved"] = any(a != "writer" for a in approvers)
        ev["derived"]["self_approved"] = "writer" in approvers
        ev["source"] = {"repo": "aerospike/shared-workflows", "commit": "abcdef1234567890",
                        "run": "https://github.com/aerospike/shared-workflows/actions/runs/1",
                        "env": 12}
        return ev

    def test_an_unapproved_pr_makes_no_approval_claim(self):
        rows = rev.claim_rows(self.pr_evidence([], None))
        self.assertEqual([r for r in rows if "approved by someone" in r[0]], [])

    def test_a_pr_approved_only_by_its_author_makes_no_approval_claim(self):
        rows = rev.claim_rows(self.pr_evidence(["writer"], "2026-01-01T00:00:00Z"))
        self.assertEqual([r for r in rows if "approved by someone" in r[0]], [])

    def test_an_independently_approved_merged_pr_makes_the_claim(self):
        rows = rev.claim_rows(self.pr_evidence(["reviewer"], "2026-01-01T00:00:00Z"))
        self.assertEqual(len([r for r in rows if "approved by someone" in r[0]]), 1)

    def test_a_missing_approval_is_named_as_a_gap_rather_than_left_silent(self):
        rows = rev.gap_rows(self.pr_evidence([], None))
        self.assertIn("An approving review on the authorizing pull request", [r[0] for r in rows])

    def test_an_approved_pr_raises_no_approval_gap(self):
        rows = rev.gap_rows(self.pr_evidence(["reviewer"], "2026-01-01T00:00:00Z"))
        self.assertNotIn("An approving review on the authorizing pull request", [r[0] for r in rows])

    def test_no_approvals_does_not_read_as_declining_to_self_approve(self):
        ev = self.pr_evidence([], None)
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertNotIn("could not approve their own change", out)

    def test_an_open_pr_is_described_as_open_rather_than_merged_at_no_date(self):
        rows = rev.custody_rows(self.pr_evidence([], None))
        review = next(r[1] for r in rows if r[0] == "Peer review")
        self.assertIn("not approved", review)
        self.assertIn("still open", review)
        self.assertNotIn("merged  UTC", review)

    def test_a_merged_pr_still_reports_its_merge_time(self):
        rows = rev.custody_rows(self.pr_evidence(["reviewer"], "2026-01-01T00:00:00Z"))
        review = next(r[1] for r in rows if r[0] == "Peer review")
        self.assertIn("approved by `reviewer`", review)
        self.assertIn("merged 2026-01-01 00:00:00 UTC", review)

    def test_an_unsealed_artifact_names_the_missing_bundle_as_the_root_gap(self):
        rows = rev.gap_rows(self.evidence(None, [], False))
        self.assertIn("A release bundle holding these bytes", [r[0] for r in rows])

    def test_the_document_renders_without_a_release(self):
        ev = self.evidence(None, [], False)
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("a.whl: artifact evidence", out)
        self.assertIn("Where this is", out)
        self.assertIn("has reached DEV", out)
        self.assertIn("not been promoted to TEST", out)
        # The claim that would be a lie if it appeared.
        self.assertNotIn("could not change after sealing", out)


class CollectUnbundled(unittest.TestCase):
    """collect() end to end against stubbed transport, for an artifact still in DEV.

    The classification tests above mirror the derivation; this one runs the real thing, so the
    two cannot drift apart without a failure here.
    """

    TARGET = "clients-pypi-dev-local/aerospike/16.0.1/aerospike-16.0.1.whl"

    def setUp(self):
        self.calls = []
        self._real = (rev.jf, rev.aql, rev.gh)

        def fake_jf(path):
            self.calls.append(path)
            if "api/storage/" in path and path.endswith("?properties"):
                return {"properties": {}}
            if "api/storage/" in path:
                return {"checksums": {"sha256": "abc123"}}
            return {}

        def fake_aql(_query):
            # In no release bundle, and present only in the dev repository.
            return {"results": [{"repo": "clients-pypi-dev-local",
                                 "path": "aerospike/16.0.1",
                                 "name": "aerospike-16.0.1.whl"}]}

        rev.jf, rev.aql, rev.gh = fake_jf, fake_aql, lambda _p: None

    def tearDown(self):
        rev.jf, rev.aql, rev.gh = self._real

    def test_reports_on_an_artifact_that_is_in_no_release_bundle(self):
        ev = rev.collect(self.TARGET, "")
        self.assertIsNone(ev["release"])
        self.assertEqual(ev["project"], "clients")
        self.assertEqual(len(ev["artifacts"]), 1)
        self.assertEqual(ev["artifacts"][0]["type"], "pypi")
        self.assertFalse(ev["artifacts"][0]["sealed"])

    def test_places_it_at_dev_with_the_rest_pending(self):
        derived = rev.collect(self.TARGET, "")["derived"]
        self.assertEqual(derived["stages_reached"], ["DEV"])
        self.assertEqual(derived["skipped_stages"], [])
        self.assertEqual(derived["pending_stages"], ["TEST", "STAGE", "PREVIEW", "PROD"])
        self.assertFalse(derived["sealed"])

    def test_renders_a_document_that_claims_nothing_it_cannot_back(self):
        ev = rev.collect(self.TARGET, "")
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("has reached DEV", out)
        self.assertIn("not been promoted to TEST, STAGE, PREVIEW and PROD", out)
        self.assertIn("A release bundle holding these bytes", out)
        for lie in ("could not change after sealing", "promotion attestation names the seal"):
            self.assertNotIn(lie, out)


class CollectBundled(unittest.TestCase):
    """The sealed, fully promoted path still produces the full document."""

    SEAL = {"_type": "https://in-toto.io/Statement/v1", "predicateType": "slsa",
            "subject": [{"digest": {"sha256": "abc123"}}]}

    def setUp(self):
        self._real = (rev.jf, rev.aql, rev.gh)

        def fake_jf(path):
            if "lifecycle/api/v2/release_bundle/records" in path:
                return {"created": "2026-08-01T10:00:00Z", "created_by": "ci",
                        "total_artifacts_count": 1,
                        "artifacts": [{"package_type": "pypi", "path": "a.whl",
                                       "checksum": "abc123", "properties": []}]}
            if path.endswith("release-bundle.json.evd"):
                return {"payload": rev.base64.b64encode(
                    rev.json.dumps(self.SEAL).encode()).decode()}
            if "api/storage/" in path and path.endswith("?properties"):
                return {"properties": {}}
            if "api/storage/" in path and "release-bundles-v2" in path:
                return {"children": [{"uri": "/promotion-PROD.evd"}]}
            if "api/storage/" in path:
                return {"checksums": {"sha256": "abc123"}}
            if path.endswith("promotion-PROD.evd"):
                return {}
            return {}

        rev.jf = fake_jf
        rev.aql = lambda _q: {"results": [{"repo": "clients-pypi-prod-public-local",
                                           "path": "a", "name": "a.whl"}]}
        rev.gh = lambda _p: None

    def tearDown(self):
        rev.jf, rev.aql, rev.gh = self._real

    def test_a_bundled_release_still_reports_its_release_block(self):
        ev = rev.collect("bundle:my-release/1.2.3@clients", "")
        self.assertIsNotNone(ev["release"])
        self.assertEqual(ev["release"]["name"], "my-release")
        self.assertEqual(ev["release"]["version"], "1.2.3")
        self.assertTrue(ev["derived"]["sealed"])

    def test_residence_in_a_public_repository_counts_as_reaching_prod(self):
        derived = rev.collect("bundle:my-release/1.2.3@clients", "")["derived"]
        self.assertIn("PROD", derived["stages_reached"])
        self.assertEqual(derived["pending_stages"], [])

    def test_the_full_document_renders(self):
        ev = rev.collect("bundle:my-release/1.2.3@clients", "")
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("my-release 1.2.3: release evidence", out)
        self.assertIn("Chain of custody", out)
        self.assertIn("could not change after sealing", out)

    def test_an_unattributable_promotion_stays_visible_without_counting_as_a_stage(self):
        # The stub's promotion attestation carries no target environment, which is what an
        # unreadable or malformed record looks like.
        ev = rev.collect("bundle:my-release/1.2.3@clients", "")
        self.assertEqual([p["stage"] for p in ev["promotions"]], ["UNKNOWN"])
        self.assertNotIn("UNKNOWN", ev["derived"]["stages_reached"])
        rev.render_markdown(ev, rev.document(ev))  # must not raise


if __name__ == "__main__":
    unittest.main()
