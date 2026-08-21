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
        artifacts, promotions, _ = self.build(promotion_stages, resident_repos, sealed)
        resident = sorted({rev.stage_of_repo(r) for a in artifacts for r in a["repos"]} - {None},
                          key=lambda s: rev.STAGE_ORDER.index(s) if s in rev.STAGE_ORDER
                          else len(rev.STAGE_ORDER))
        return rev.classify_stages([p["stage"] for p in promotions], resident)

    def test_an_artifact_only_in_dev_has_everything_pending_and_nothing_skipped(self):
        d = self.derive([], ["clients-pypi-dev-local"], sealed=False)
        self.assertEqual(d["stages_reached"], ["DEV"])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], ["TEST", "STAGE", "PROD"])

    def test_repository_residence_counts_when_no_promotion_record_exists(self):
        d = self.derive([], ["clients-pypi-dev-local", "clients-pypi-test-local"])
        self.assertEqual(d["stages_reached"], ["DEV", "TEST"])
        self.assertEqual(d["pending_stages"], ["STAGE", "PROD"])

    def test_a_required_gate_passed_over_is_reported_as_skipped(self):
        d = self.derive(["DEV", "TEST", "PROD"], ["clients-pypi-prod-public-local"])
        self.assertEqual(d["skipped_stages"], ["STAGE"])
        self.assertEqual(d["pending_stages"], [])

    def test_preview_is_optional_so_passing_it_over_is_not_a_gap(self):
        d = self.derive(["TEST", "STAGE", "PROD"], ["clients-pypi-prod-public-local"])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], [])

    def test_dev_is_optional_so_starting_at_test_is_not_a_gap(self):
        d = self.derive(["TEST"], ["clients-pypi-test-local"])
        self.assertEqual(d["stages_reached"], ["TEST"])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], ["STAGE", "PROD"])

    def test_an_optional_stage_that_happened_is_still_named(self):
        # Optional means no error when absent, not invisible when present.
        d = self.derive(["DEV", "TEST", "STAGE", "PREVIEW", "PROD"],
                        ["clients-pypi-prod-public-local"])
        self.assertEqual(d["stages_reached"], ["DEV", "TEST", "STAGE", "PREVIEW", "PROD"])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], [])

    def test_dev_residence_is_still_named_while_the_rest_is_pending(self):
        d = self.derive([], ["clients-pypi-dev-local"])
        self.assertIn("DEV", d["stages_reached"])

    def test_internal_is_terminal_so_prod_is_not_counted_against_it(self):
        d = self.derive(["DEV", "TEST", "STAGE", "INTERNAL"], [])
        self.assertNotIn("PROD", d["skipped_stages"])
        self.assertNotIn("PROD", d["pending_stages"])

    def test_nothing_anywhere_is_pending_rather_than_skipped(self):
        d = self.derive([], [])
        self.assertEqual(d["stages_reached"], [])
        self.assertEqual(d["skipped_stages"], [])
        self.assertEqual(d["pending_stages"], ["TEST", "STAGE", "PROD"])


class BuildLinkFollowsTheDigest(unittest.TestCase):
    """Retagging on promotion strips build properties from the clean tag only.

    The timestamped tag beside it in the same public repository keeps them, and a consumer holding
    the clean tag holds the digest, so the link is intact and must not be reported as lost.
    """

    MANIFEST = "aerospike-graph-service/3.3.0/list.manifest.json"

    def setUp(self):
        self._real = rev.aql
        self.hits = []

        def fake_aql(_query):
            return {"results": self.hits}

        rev.aql = fake_aql

    def tearDown(self):
        rev.aql = self._real

    def hit(self, repo, path, props=None):
        return {"repo": repo, "path": path, "name": "list.manifest.json",
                "properties": [{"key": k, "value": v} for k, v in (props or {}).items()]}

    def test_a_build_link_on_the_timestamped_tag_counts_for_the_clean_one(self):
        self.hits = [
            self.hit("connect-docker-prod-public-local", "aerospike-graph-service/3.3.0"),
            self.hit("connect-docker-prod-public-local",
                     "aerospike-graph-service/3.3.0_20260811T222346Z",
                     {"build.name": "aerospike-graph-service", "build.number": "27"}),
        ]
        public, _repos, linked = rev.where_published("abc123", "docker")
        self.assertTrue(linked)
        # The consumer-facing path is still the clean tag.
        self.assertEqual(public, "docker/aerospike-graph-service/3.3.0/list.manifest.json")

    def test_no_build_link_anywhere_is_still_reported(self):
        self.hits = [
            self.hit("database-docker-prod-public-local", "aerospike-server-enterprise/8.1"),
            self.hit("database-docker-dev-local", "aerospike-server-enterprise/8.1.2.4"),
        ]
        _public, _repos, linked = rev.where_published("abc123", "docker")
        self.assertFalse(linked)


class ContainersCollapseToTheImage(unittest.TestCase):
    """An image is one shipped thing, whether its repository is typed docker or oci."""

    def record(self, package_type):
        paths = [
            "img/1.0.0/manifest.json",
            "img/1.0.0/sha256__aaaa",
            "img/_uploads/manifest-sha256__bbbb.json",
            "img/_uploads/sha256__cccc",
            "img/sha256:dddd/manifest.json",
            "img/sha256:dddd/sha256__eeee",
        ]
        return {"artifacts": [{"path": p, "package_type": package_type} for p in paths]}

    def test_an_oci_image_collapses_to_its_tag_manifest(self):
        kept = [a["path"] for a in rev.primary_artifacts(self.record("oci"))]
        self.assertEqual(kept, ["img/1.0.0/manifest.json"])

    def test_a_docker_image_collapses_the_same_way(self):
        kept = [a["path"] for a in rev.primary_artifacts(self.record("docker"))]
        self.assertEqual(kept, ["img/1.0.0/manifest.json"])

    def test_a_multi_arch_list_manifest_is_kept(self):
        record = {"artifacts": [{"path": "img/1.0.0_20260101T000000Z/list.manifest.json",
                                 "package_type": "docker"}]}
        self.assertEqual(len(rev.primary_artifacts(record)), 1)

    def test_upload_staging_is_never_a_shipped_thing(self):
        kept = [a["path"] for a in rev.primary_artifacts(self.record("oci"))]
        self.assertFalse([p for p in kept if "_uploads" in p])

    def test_a_non_container_type_is_untouched(self):
        record = {"artifacts": [{"path": "a/b/c-1.0.jar", "package_type": "maven"}]}
        self.assertEqual(len(rev.primary_artifacts(record)), 1)


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
                        "skipped_stages": [], "pending_stages": ["TEST", "STAGE", "PROD"],
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

    def test_stages_not_yet_reached_are_not_reported_as_missing_evidence(self):
        # A release still working its way up the pipeline is not missing anything.
        titles = [r[0] for r in rev.gap_rows(self.evidence(None, [], False))]
        self.assertEqual([t for t in titles if "transition" in t], [])

    def test_a_gate_passed_over_below_a_customer_is_missing_evidence(self):
        ev = self.evidence(None, [], False)
        ev["derived"]["stages_reached"] = ["DEV", "STAGE"]
        ev["derived"]["pending_stages"] = ["PROD"]
        ev["derived"]["skipped_stages"] = ["TEST"]
        row = next(r for r in rev.gap_rows(ev) if "transition" in r[0])
        self.assertEqual(row[0], "A recorded TEST transition")
        self.assertEqual(rev.shipped_untested(ev), [])

    def test_a_gate_passed_over_on_the_way_to_customers_is_a_failure(self):
        ev = self.evidence(None, [], False)
        ev["derived"]["stages_reached"] = ["DEV", "PROD"]
        ev["derived"]["pending_stages"] = []
        ev["derived"]["skipped_stages"] = ["TEST", "STAGE"]
        self.assertEqual([f[0] for f in rev.shipped_untested(ev)],
                         ["Published to customers with no TEST and STAGE record"])
        # Reported once, as the failure, not also as missing paperwork.
        self.assertEqual([r for r in rev.gap_rows(ev) if "transition" in r[0]], [])

    def test_a_missing_approval_is_named_as_a_gap_once_it_has_been_vouched_for(self):
        ev = self.pr_evidence([], None)
        ev["derived"]["stages_reached"] = ["DEV", "TEST", "STAGE"]
        self.assertIn("An approving review on the authorizing pull request",
                      [r[0] for r in rev.gap_rows(ev)])

    def test_a_missing_approval_on_a_dev_build_is_not_yet_a_gap(self):
        # A candidate can be built from a branch before the merge, so nothing is late yet.
        rows = rev.gap_rows(self.pr_evidence([], None))
        self.assertNotIn("An approving review on the authorizing pull request",
                         [r[0] for r in rows])

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

    def test_an_unsealed_artifact_past_dev_names_the_missing_bundle_as_the_root_gap(self):
        ev = self.evidence(None, [], False)
        ev["derived"]["stages_reached"] = ["DEV", "TEST"]
        self.assertIn("A release bundle holding these bytes", [r[0] for r in rev.gap_rows(ev)])

    def test_an_unsealed_artifact_still_in_dev_is_not_missing_a_bundle(self):
        # The bundle is cut at the DEV to TEST gate, so nothing is late yet.
        rows = rev.gap_rows(self.evidence(None, [], False))
        self.assertNotIn("A release bundle holding these bytes", [r[0] for r in rows])

    def test_the_document_renders_without_a_release(self):
        ev = self.evidence(None, [], False)
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("a.whl: artifact evidence", out)
        self.assertIn("Where this is", out)
        self.assertIn("has reached DEV", out)
        self.assertIn("not been promoted to TEST", out)
        # The claim that would be a lie if it appeared.
        self.assertNotIn("could not change after sealing", out)

    def sealed_evidence(self, promotions):
        ev = self.evidence({"name": "r", "version": "1.0.0", "bundle": "r/1.0.0",
                            "repo": "clients-release-bundles-v2", "project": "clients",
                            "created": "2026-01-01T00:00:00Z", "created_by": "token:ci",
                            "files": 2,
                            "seal": {"statement": "https://in-toto.io/Statement/v1",
                                     "predicate": "https://jfrog.com/evidence/release-bundle/v1",
                                     "subjects": 2}},
                           promotions, True)
        ev["artifacts"][0]["sealed"] = True
        return ev

    def promotion(self, stage):
        return {"stage": stage, "when": "2026-01-02T00:00:00Z", "by": "releaser@aerospike.com",
                "repos": [f"clients-pypi-{stage.lower()}-local"], "mutable": False,
                "seals": "f" * 64}

    def test_a_sealed_bundle_with_no_promotion_names_no_attestation(self):
        ev = self.sealed_evidence([])
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("No promotion attestation names the seal yet", out)
        self.assertNotIn("attestation names the seal by its own digest", out)
        self.assertNotIn("terminal attestation", out)
        # A colon introducing an attestation block that does not exist.
        self.assertNotIn("in one action:", out)

    def test_immutability_cites_promotion_records_only_where_they_exist(self):
        unpromoted = rev.claim_rows(self.sealed_evidence([]))
        promoted = rev.claim_rows(self.sealed_evidence([self.promotion("DEV")]))
        title = "The contents could not change after sealing"
        self.assertNotIn("promotion records", next(r[1] for r in unpromoted if r[0] == title))
        self.assertIn("promotion records", next(r[1] for r in promoted if r[0] == title))

    def test_a_promoted_bundle_names_the_stage_that_authorized_it(self):
        ev = self.sealed_evidence([self.promotion("DEV")])
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("The DEV attestation names the seal by its own digest", out)
        self.assertNotIn("No promotion attestation", out)


class CollectUnbundled(unittest.TestCase):
    """collect() end to end against stubbed transport, for an artifact still in DEV.

    The classification tests above mirror the derivation; this one runs the real thing, so the
    two cannot drift apart without a failure here.
    """

    TARGET = "clients-pypi-dev-local/aerospike/16.0.1/aerospike-16.0.1.whl"

    def setUp(self):
        self.calls = []
        self._real = (rev.jfrog, rev.aql, rev.gh, rev.gh_graphql)

        def fake_jfrog(path):
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

        rev.jfrog, rev.aql, rev.gh = fake_jfrog, fake_aql, lambda _p: None
        rev.gh_graphql = lambda _q, **_v: None

    def tearDown(self):
        rev.jfrog, rev.aql, rev.gh, rev.gh_graphql = self._real

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
        self.assertEqual(derived["pending_stages"], ["TEST", "STAGE", "PROD"])
        self.assertFalse(derived["sealed"])

    def test_renders_a_document_that_claims_nothing_it_cannot_back(self):
        ev = rev.collect(self.TARGET, "")
        out = rev.render_markdown(ev, rev.document(ev))
        self.assertIn("has reached DEV", out)
        self.assertIn("not been promoted to TEST, STAGE and PROD", out)
        self.assertIn("A recorded source commit", out)
        for lie in ("could not change after sealing", "promotion attestation names the seal"):
            self.assertNotIn(lie, out)


class CollectBundled(unittest.TestCase):
    """The sealed, fully promoted path still produces the full document."""

    SEAL = {"_type": "https://in-toto.io/Statement/v1", "predicateType": "slsa",
            "subject": [{"digest": {"sha256": "abc123"}}]}

    def setUp(self):
        self._real = (rev.jfrog, rev.aql, rev.gh, rev.gh_graphql)

        def fake_jfrog(path):
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

        rev.jfrog = fake_jfrog
        rev.aql = lambda _q: {"results": [{"repo": "clients-pypi-prod-public-local",
                                           "path": "a", "name": "a.whl"}]}
        rev.gh = lambda _p: None

    def tearDown(self):
        rev.jfrog, rev.aql, rev.gh, rev.gh_graphql = self._real

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


class Verdict(unittest.TestCase):
    """A release still climbing the pipeline is not failing for records it has not earned."""

    def evidence(self, reached, pending, gaps_from=None):
        pr = {"number": 1, "title": "t", "author": "writer", "approvers": ["reviewer"],
              "merged_at": "2026-01-01T00:00:00Z", "repo": "citrusleaf/a-repo"}
        ev = {"release": None, "pr": pr, "promotions": [], "artifacts": [],
              "duties": {"warnings": [], "violations": [], "unproven": []},
              "derived": {"stages_reached": reached, "pending_stages": pending,
                          "skipped_stages": [], "sealed": True, "any_commit": True,
                          "unlinked_published": [], "independently_approved": True}}
        if gaps_from:
            ev["derived"].update(gaps_from)
        return ev

    def test_a_clean_release_in_test_is_on_track_not_a_pass(self):
        call = rev.verdict(self.evidence(["DEV", "TEST"], ["STAGE", "PROD"]))
        self.assertEqual(call["status"], "ON TRACK")
        self.assertFalse(call["complete"])
        self.assertEqual(call["gaps"], 0)

    def test_a_retagged_container_warns_rather_than_fails(self):
        # Promotion retags the manifest, so every promoted container loses its build properties.
        # The join still works from the bundle record, so this cannot fail a release.
        ev = self.evidence(["DEV", "TEST", "STAGE", "PROD"], [],
                           {"unlinked_published": ["docker"], "types": ["docker"]})
        call = rev.verdict(ev)
        self.assertEqual(call["status"], "PASS WITH WARNING")
        self.assertEqual(call["gaps"], 0)
        self.assertIn("The public copy carries no build link",
                      [w[0] for w in rev.warning_rows(ev)])

    def test_a_clean_release_in_prod_passes(self):
        call = rev.verdict(self.evidence(["DEV", "TEST", "STAGE", "PROD"], []))
        self.assertEqual(call["status"], "PASS")
        self.assertTrue(call["complete"])

    def test_a_release_in_test_with_no_commit_already_fails(self):
        call = rev.verdict(self.evidence(["DEV", "TEST"], ["STAGE", "PROD"],
                                         {"any_commit": False}))
        self.assertEqual(call["status"], "FAIL")
        self.assertEqual(call["reason"], "evidence incomplete")
        self.assertEqual(call["finding"], "A recorded source commit")

    def test_the_on_track_line_says_what_is_still_ahead(self):
        ev = self.evidence(["DEV", "TEST"], ["STAGE", "PROD"])
        line = rev.verdict_block(ev, [], [])[-1]
        self.assertTrue(line.startswith("**ON TRACK.** Correct so far."), line)
        self.assertIn("STAGE and PROD lie ahead", line)

    def test_the_keys_the_action_publishes_as_outputs_all_exist(self):
        # action.yaml reads these by name, so a rename must break a test rather than silently
        # empty a gate's `if:`.
        call = rev.verdict(self.evidence(["DEV", "TEST"], ["STAGE", "PROD"]))
        self.assertEqual(set(call), {"status", "reason", "finding", "problems", "gaps",
                                     "warnings", "complete"})

    def test_the_verdict_travels_in_the_evidence_so_markdown_callers_can_gate(self):
        # The verdict has to live in the evidence, not in the renderer, for --verdict-path to
        # serve it under --format markdown.
        ev = self.evidence(["DEV", "TEST", "STAGE", "PROD"], [])
        ev["verdict"] = rev.verdict(ev)
        self.assertEqual(rev.verdict_block(ev, [], [])[1], "info")
        self.assertEqual(ev["verdict"]["status"], "PASS")


class TheVerifyCommandRuns(unittest.TestCase):
    """Every printed command has to resolve, or the section invites a reader to prove nothing."""

    def art(self, **over):
        art = {"type": "generic", "public": None, "repos": [], "path": "x/1.0/x-1.0.zip"}
        art.update(over)
        return art

    def test_a_public_virtual_path_is_used_as_given(self):
        art = self.art(type="maven", public="maven/com/aerospike/x/1.0/x-1.0.jar",
                       repos=["database-maven-prod-public-local"],
                       path="com/aerospike/x/1.0/x-1.0.jar")
        self.assertEqual(rev.pasteable(art), "maven/com/aerospike/x/1.0/x-1.0.jar")

    def test_a_type_with_no_virtual_falls_back_to_the_most_public_repository(self):
        # generic is absent from VIRTUAL, so `public` is None.
        art = self.art(repos=["connect-generic-dev-local", "connect-generic-prod-public-local",
                              "connect-generic-stage-local", "connect-release-bundles-v2"],
                       path="aerospike-trino/4.7.4-483/aerospike-trino-4.7.4-483.zip")
        self.assertEqual(
            rev.pasteable(art),
            "connect-generic-prod-public-local/aerospike-trino/4.7.4-483/"
            "aerospike-trino-4.7.4-483.zip")

    def test_a_repository_naming_no_stage_is_still_named_rather_than_dropped(self):
        # ecosystem-container-prod-local is real and its key names no stage. Do not add `prod`
        # to REPO_ENV_STAGE to fix that: devops-containers-prod-local is labelled DEV.
        art = self.art(type="docker", repos=["ecosystem-container-dev-local",
                                             "ecosystem-container-prod-local",
                                             "ecosystem-release-bundles-v2"],
                       path="absctl/v1.1.1/list.manifest.json")
        chosen = rev.pasteable(art)
        self.assertTrue(chosen.split("/", 1)[0] in art["repos"], chosen)
        self.assertNotIn("release-bundles", chosen)
        self.assertTrue(chosen.endswith("/absctl/v1.1.1/list.manifest.json"), chosen)

    def test_an_unranked_key_sorts_behind_every_recognized_stage(self):
        self.assertEqual(rev.most_public(["ecosystem-container-prod-local",
                                          "ecosystem-container-dev-local"]),
                         "ecosystem-container-dev-local")

    def test_an_unbundled_path_already_carrying_its_repository_is_left_alone(self):
        art = self.art(repos=["clients-pypi-dev-local"],
                       path="clients-pypi-dev-local/aerospike/16.0.1/aerospike-16.0.1.whl")
        self.assertEqual(rev.pasteable(art),
                         "clients-pypi-dev-local/aerospike/16.0.1/aerospike-16.0.1.whl")

    def test_the_release_bundle_repository_is_never_the_answer(self):
        # It holds the record, not the artifact.
        self.assertEqual(rev.most_public(["database-release-bundles-v2",
                                          "database-deb-test-local"]),
                         "database-deb-test-local")
        self.assertIsNone(rev.most_public(["database-release-bundles-v2"]))

    def test_prod_outranks_internal_which_outranks_stage(self):
        self.assertEqual(rev.most_public(["x-deb-stage-local", "x-deb-prod-internal-local",
                                          "x-deb-prod-public-local"]),
                         "x-deb-prod-public-local")
        self.assertEqual(rev.most_public(["x-deb-stage-local", "x-deb-prod-internal-local"]),
                         "x-deb-prod-internal-local")


class TheTagTheReaderNamedWins(unittest.TestCase):
    """A floating tag is shorter than the release version, so length alone picks the wrong one."""

    def published(self, paths, version):
        # The three tag shapes aerospike-server 7.1.0.25 actually has in prod-public.
        hits = {"results": [{"repo": "database-docker-prod-public-local", "path": path,
                             "name": "list.manifest.json", "properties": []} for path in paths]}
        saved = rev.aql
        rev.aql = lambda query: hits
        try:
            return rev.where_published("deadbeef", "docker", version)[0]
        finally:
            rev.aql = saved

    def test_the_release_version_beats_a_floating_tag(self):
        self.assertEqual(
            self.published(["aerospike-server/7.1", "aerospike-server/7.1.0.25",
                            "aerospike-server/7.1.0.25-20260603181409"], "7.1.0.25"),
            "docker/aerospike-server/7.1.0.25/list.manifest.json")

    def test_the_clean_tag_beats_the_immutable_one_at_the_same_version(self):
        self.assertEqual(
            self.published(["aerospike-server/7.1.0.25-20260603181409",
                            "aerospike-server/7.1.0.25"], "7.1.0.25"),
            "docker/aerospike-server/7.1.0.25/list.manifest.json")

    def test_no_version_falls_back_to_the_shortest_clean_tag(self):
        self.assertEqual(
            self.published(["aerospike-server/7.1", "aerospike-server/7.1.0.25"], None),
            "docker/aerospike-server/7.1/list.manifest.json")

    def test_the_hint_comes_from_the_bundle_when_there_is_one(self):
        self.assertEqual(
            rev.version_hint("aerospike-trino/4.7.4-483", {"path": "x/y/z.zip"}), "4.7.4-483")

    def test_the_hint_comes_from_the_path_when_there_is_no_bundle(self):
        self.assertEqual(
            rev.version_hint(None, {"path": "docker/aerospike-server/7.1.0.25/"
                                            "list.manifest.json"}), "7.1.0.25")

    def test_a_path_too_short_to_carry_a_version_yields_no_hint(self):
        self.assertIsNone(rev.version_hint(None, {"path": "repo/file.zip"}))


class TheProjectComesFromARepositoryThatNamesOne(unittest.TestCase):
    """A public virtual carries no project, so the first path segment invents one."""

    def resolve(self, repo, holders):
        saved = rev.aql
        rev.aql = lambda query: {"results": [{"repo": h} for h in holders]}
        try:
            return rev.project_of(repo, "deadbeef")
        finally:
            rev.aql = saved

    def test_a_local_repository_names_its_own_project(self):
        self.assertEqual(self.resolve("database-deb-dev-local", []), "database")

    def test_a_virtual_target_resolves_through_the_bundle_repository(self):
        self.assertEqual(
            self.resolve("docker", ["database-docker-prod-public-local",
                                    "database-release-bundles-v2"]), "database")

    def test_a_virtual_target_with_no_bundle_falls_back_to_a_local_repository(self):
        self.assertEqual(self.resolve("docker", ["database-docker-prod-public-local"]), "database")


class TheImmutableTagIsRecognizedInBothForms(unittest.TestCase):
    """A promoted tag is timestamped two ways, and only one was matched."""

    def test_both_separators_count_as_timestamped(self):
        self.assertTrue(rev.TIMESTAMPED_TAG.search("aerospike-server/8.1.3.0_20260721T101500Z"))
        self.assertTrue(rev.TIMESTAMPED_TAG.search("aerospike-server/8.1.3.0-20260721101500"))

    def test_a_version_is_not_mistaken_for_a_timestamp(self):
        for path in ("aerospike-server/8.1.3.0", "aerospike-server/8.1",
                     "pool/x/aerospike-server-community_8.0.0.19-3debian12_amd64.deb",
                     "com/aerospike/x/6.2.0/x-6.2.0-javadoc.jar"):
            self.assertIsNone(rev.TIMESTAMPED_TAG.search(path), path)


class EveryTypeHasAReadableNoun(unittest.TestCase):
    """An absent key falls through to the raw type, which renders as "shipped as a generic"."""

    def test_every_type_the_pipeline_publishes_reads_as_a_thing(self):
        for pkg_type in list(rev.VIRTUAL) + ["generic", "oci", "cargo"]:
            self.assertIn(pkg_type, rev.NOUN, pkg_type)

    def test_a_generic_release_reads_as_files(self):
        evidence = {"artifacts": [{"type": "generic"}, {"type": "generic"}]}
        self.assertEqual(rev.nouns(evidence), "2 files")


class TimesComeFromTheRecords(unittest.TestCase):
    """Every time shown is the timestamp of the record that names the actor, not a guess."""

    def evidence(self):
        return {
            "release": {"created_by": "token:gh-citrusleaf/builder",
                        "created": "2026-08-07T16:36:27.000Z"},
            "pr": {"number": 7, "title": "t", "author": "writer", "approvers": ["reviewer"],
                   "merged_at": "2026-08-06T09:00:00Z", "opened_at": "2026-08-05T08:00:00Z",
                   "approved_at": {"reviewer": "2026-08-06T08:30:00Z"},
                   "repo": "citrusleaf/a-repo"},
            "promotions": [{"stage": "TEST", "when": "2026-08-07T16:42:02.000Z", "by": "ci",
                            "repos": [], "mutable": False, "seals": "f" * 64},
                           {"stage": "PROD", "when": "2026-08-17T17:52:22.000Z", "by": "releaser",
                            "repos": [], "mutable": False, "seals": "f" * 64}],
            "as_of": "2026-08-21", "artifacts": [], "duties": {"people": {}, "names": {}},
            "derived": {"stages_reached": ["TEST", "PROD"]},
        }

    def test_each_role_carries_the_time_of_its_own_record(self):
        times = {r[0]: r[2] for r in rev.duty_rows(self.evidence())}
        self.assertEqual(times["Wrote the change"], "2026-08-05 08:00:00")
        self.assertEqual(times["Approved the change"], "2026-08-06 08:30:00")
        self.assertEqual(times["Built and sealed"], "2026-08-07 16:36:27")
        self.assertEqual(times["Promoted to TEST"], "2026-08-07 16:42:02")
        self.assertEqual(times["Authorized the PROD publish"], "2026-08-17 17:52:22")

    def test_a_record_with_no_timestamp_says_so_rather_than_showing_blank(self):
        ev = self.evidence()
        ev["pr"]["approved_at"] = {}
        times = {r[0]: r[2] for r in rev.duty_rows(ev)}
        self.assertEqual(times["Approved the change"], "not recorded")

    def test_the_as_of_line_names_the_newest_record(self):
        line = rev.as_of_line(self.evidence())
        self.assertIn("Reported as of 2026-08-21", line)
        self.assertIn("the PROD promotion of 2026-08-17 17:52:22 UTC", line)

    def test_the_as_of_line_falls_back_to_the_seal_then_the_build(self):
        ev = self.evidence()
        ev["promotions"] = []
        self.assertIn("the bundle seal of 2026-08-07 16:36:27 UTC", rev.as_of_line(ev))
        ev["release"] = None
        self.assertIn("the build itself", rev.as_of_line(ev))


class SeparationOfDuties(unittest.TestCase):
    """A CI token and a user account can name one human, and only the identity map can tell.

    No string rule links a login to a person here: `Klaven` is mcounts@aerospike.com in the real
    directory, so every claim about who acted rests on the org SAML map.
    """

    DIRECTORY = {
        "pvinh-spike": {"email": "pvinh@aerospike.com", "name": "Phuc Vinh",
                        "emails": {"pvinh@aerospike.com"}},
        "mphanias": {"email": "pmokrala@aerospike.com", "name": "Phani Mokrala",
                     "emails": {"pmokrala@aerospike.com"}},
        "abhilashmandaliya": {"email": "abhilash@aerospike.com", "name": "Abhilash Mandaliya",
                              "emails": {"abhilash@aerospike.com"}},
        # Two verified company addresses, one person.
        "arrowplum": {"email": "jmartin@aerospike.com", "name": "Joe M.",
                      "emails": {"jmartin@aerospike.com", "joem@aerospike.com"}},
    }

    def setUp(self):
        self._real = rev.saml_identities
        rev.saml_identities = lambda _org: dict(self.DIRECTORY)

    def tearDown(self):
        rev.saml_identities = self._real

    def promotion(self, stage, by):
        return {"stage": stage, "when": "2026-01-01T00:00:00Z", "by": by, "repos": [],
                "mutable": False, "seals": "f" * 64}

    def pr(self, author, approvers):
        return {"number": 272, "title": "t", "author": author, "approvers": approvers,
                "merged_at": "2026-01-01T00:00:00Z", "repo": "citrusleaf/a-repo"}

    def evidence(self, pr=None, created_by=None, promotions=()):
        ev = {
            "release": {"created_by": created_by} if created_by else None,
            "pr": pr, "promotions": list(promotions), "artifacts": [],
            "derived": {"independently_approved": bool(pr and pr["approvers"]),
                        "sealed": bool(created_by), "any_commit": True,
                        "unlinked_published": [], "skipped_stages": [], "pending_stages": [],
                        "stages_reached": [p["stage"] for p in promotions]},
        }
        ev["duties"] = rev.duties(ev)
        return ev

    def test_a_token_and_a_user_account_for_one_human_count_as_one_person(self):
        ev = self.evidence(
            created_by="token:gh-citrusleaf/pvinh-spike",
            promotions=[self.promotion("TEST", "token:database-gh-citrusleaf/pvinh-spike"),
                        self.promotion("PROD", "pvinh@aerospike.com")])
        self.assertEqual(ev["duties"]["distinct"], 1)
        self.assertFalse(ev["duties"]["separated"])
        self.assertEqual([v[0] for v in ev["duties"]["violations"]],
                         ["One person took this from commit to publish"])

    def test_the_approver_who_publishes_is_a_note_not_a_failure(self):
        # The author neither approved nor published, so the control held and only depth was lost.
        ev = self.evidence(pr=self.pr("abhilashmandaliya", ["mphanias"]),
                           created_by="token:gh-citrusleaf/abhilashmandaliya",
                           promotions=[self.promotion("PROD", "pmokrala@aerospike.com")])
        self.assertEqual(ev["duties"]["violations"], [])
        self.assertIn("The person who approved the change also authorized the publish",
                      [w[0] for w in ev["duties"]["warnings"]])
        self.assertFalse(ev["duties"]["separated"])

    def test_a_warning_reaches_the_verdict_line(self):
        ev = self.evidence(pr=self.pr("abhilashmandaliya", ["mphanias"]),
                           created_by="token:gh-citrusleaf/abhilashmandaliya",
                           promotions=[self.promotion("PROD", "pmokrala@aerospike.com")])
        ev["derived"].update(sealed=True, types=["generic"], attested_types=[],
                             unattested_types=[], stages=["PROD"], terminal_stage="PROD",
                             resident_stages=["PROD"], any_commit=True, self_approved=False,
                             independently_approved=True)
        line = rev.verdict_block(ev, [], [])[-1]
        self.assertTrue(line.startswith("**PASS WITH WARNING."), line)
        self.assertIn("also authorized the publish", line)

    def test_a_second_company_address_is_the_same_person(self):
        # A promotion recorded against joem@ and a token resolving to jmartin@ are one human, so
        # the publish gate added nobody. Without this the chain reads as separated.
        ev = self.evidence(created_by="token:gh-citrusleaf/arrowplum",
                           promotions=[self.promotion("STAGE", "jmartin@aerospike.com"),
                                       self.promotion("PROD", "joem@aerospike.com")])
        self.assertEqual(ev["duties"]["distinct"], 1)
        self.assertFalse(ev["duties"]["separated"])
        self.assertEqual([v[0] for v in ev["duties"]["violations"]],
                         ["One person took this from commit to publish"])

    def test_a_finding_names_the_person_not_only_the_mailbox(self):
        ev = self.evidence(
            created_by="token:gh-citrusleaf/pvinh-spike",
            promotions=[self.promotion("PROD", "pvinh@aerospike.com")])
        self.assertIn("Phuc Vinh <pvinh@aerospike.com>", ev["duties"]["violations"][0][1])

    def test_distinct_people_at_every_step_read_as_separated(self):
        ev = self.evidence(pr=self.pr("abhilashmandaliya", ["mphanias"]),
                           created_by="token:gh-citrusleaf/abhilashmandaliya",
                           promotions=[self.promotion("PROD", "ramya@aerospike.com")])
        self.assertEqual(ev["duties"]["violations"], [])
        self.assertTrue(ev["duties"]["separated"])

    def test_an_unreadable_identity_map_withholds_the_separation_claim(self):
        rev.saml_identities = lambda _org: {}
        ev = self.evidence(created_by="token:gh-citrusleaf/pvinh-spike",
                           promotions=[self.promotion("PROD", "pvinh@aerospike.com")])
        self.assertEqual(ev["duties"]["unproven"], ["token:gh-citrusleaf/pvinh-spike"])
        self.assertFalse(ev["duties"]["separated"])
        self.assertEqual(ev["duties"]["violations"], [])

    def test_an_unreadable_map_warns_rather_than_failing_for_a_missing_record(self):
        # The records exist and name identities. Only the identity-to-person step is missing,
        # which is a reader capability, not evidence.
        rev.saml_identities = lambda _org: {}
        ev = self.evidence(pr=self.pr("abhilashmandaliya", ["mphanias"]),
                           created_by="token:gh-citrusleaf/pvinh-spike",
                           promotions=[self.promotion("PROD", "pvinh@aerospike.com")])
        self.assertNotIn("A person behind `token:gh-citrusleaf/pvinh-spike`",
                         [r[0] for r in rev.gap_rows(ev)])
        warning = next(r for r in rev.warning_rows(ev)
                       if r[0] == "Separation of duties could not be judged")
        self.assertIn("read:org", warning[1])
        self.assertEqual(rev.verdict(ev)["status"], "PASS WITH WARNING")

    def test_a_readable_map_missing_one_login_says_so_differently(self):
        # A login the directory lacks is a bot or ops account, not a missing scope, so the
        # warning must not send a reader hunting for a permission to grant.
        rev.saml_identities = lambda _org: {
            "mphanias": {"email": "pmokrala@aerospike.com", "emails": {"pmokrala@aerospike.com"},
                         "name": "Phaniram Mokrala"}}
        ev = self.evidence(pr=self.pr("abhilashmandaliya", ["mphanias"]),
                           created_by="token:gh-citrusleaf/some-bot",
                           promotions=[self.promotion("PROD", "pmokrala@aerospike.com")])
        warning = next(r for r in rev.warning_rows(ev)
                       if r[0] == "Separation of duties could not be judged")
        self.assertNotIn("read:org", warning[1])
        self.assertIn("ops account", warning[1])

    def test_ci_building_and_promoting_to_test_is_not_a_finding(self):
        # Every healthy release looks like this on its way up, so it cannot be a problem.
        ev = self.evidence(created_by="token:gh-citrusleaf/pvinh-spike",
                           promotions=[self.promotion("TEST",
                                                      "token:database-gh-citrusleaf/pvinh-spike")])
        self.assertEqual(ev["duties"]["violations"], [])
        self.assertFalse(ev["duties"]["separated"])

    def test_the_same_hand_at_stage_is_a_finding(self):
        ev = self.evidence(created_by="token:gh-citrusleaf/pvinh-spike",
                           promotions=[self.promotion("TEST", "token:gh-citrusleaf/pvinh-spike"),
                                       self.promotion("STAGE", "pvinh@aerospike.com")])
        self.assertEqual([v[0] for v in ev["duties"]["violations"]],
                         ["One person took this from commit to publish"])

    def test_a_self_approval_survives_a_second_login(self):
        # One human with two logins is still one approval, so the login comparison cannot stand.
        rev.saml_identities = lambda _org: {
            "writer": {"email": "one@aerospike.com", "name": "One Person",
                       "emails": {"one@aerospike.com"}},
            "writer-alt": {"email": "one@aerospike.com", "name": "One Person",
                           "emails": {"one@aerospike.com"}}}
        ev = self.evidence(pr=self.pr("writer", ["writer-alt"]),
                           promotions=[self.promotion("PROD", "other@aerospike.com")])
        self.assertIn("The author approved their own change",
                      [v[0] for v in ev["duties"]["violations"]])
        self.assertFalse(ev["derived"]["independently_approved"])
        self.assertIn("An approving review on the authorizing pull request",
                      [r[0] for r in rev.gap_rows(ev)])


if __name__ == "__main__":
    unittest.main()
