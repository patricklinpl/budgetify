# Agent PR rules

Every pull request must carry proof that it works, posted on the PR itself (body or a comment), not just reported in chat.

## Required evidence on every PR

1. **The application boots.** Post a screenshot of the server log showing it is listening, taken on the PR's branch.
2. **Endpoints added or changed.** Exercise each one against the running server and attach request/response screenshots, including the error envelopes (e.g. 401 `not_authorized`, 404.2 `resource_not_found`, 429 `too_many_requests`) and the contract-test runs that pin YNAB parity.
3. **UI changes.** Post before-and-after screenshots, plus a screenshot or video demonstrating the feature end to end in the live application.
4. **Nothing mocked.** Seed real demo data when the app needs it to show the feature. Say so if a behavior cannot be exercised live and show the test run that covers it instead.

## Writer / verifier split

One agent implements; a separate, independent agent verifies. The writer never verifies its own PR.

- Every piece of work starts from a written spec of its requirements. For the YNAB API work, the spec is the GitHub issue plus the vendored OpenAPI spec at `test/fixtures/files/ynab_open_api_spec_v1.88.0.yaml`.
- The verifier reads the PR's code and the written spec itself, and verifies the implementation against the spec explicitly, requirement by requirement.
- The verifier posts its per-requirement verdict as a review on the pull request itself, so another agent can pick up the findings and work on them.
- A PR is not considered done until the independent verifier confirms every requirement in the spec.

No PR is complete until this evidence is on the PR and CI is green. A PR may then be merged without asking the user once the independent verifier's verdict on its exact head is VERIFIED, CI is green on that same head, and the required proof is posted on the PR. A push after the verdict, any unresolved finding, or a verdict other than VERIFIED blocks the merge until it is resolved and the new head is re-verified.
