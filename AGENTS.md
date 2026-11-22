# Agent PR rules

Every pull request must carry proof that it works, posted on the PR itself (body or a comment), not just reported in chat.

## Required evidence on every PR

1. **The application boots.** Post a screenshot of the server log showing it is listening, taken on the PR's branch.
2. **Endpoints added or changed.** Exercise each one against the running server and attach request/response screenshots, including the error envelopes (e.g. 401 `not_authorized`, 404.2 `resource_not_found`, 429 `too_many_requests`) and the contract-test runs that pin YNAB parity.
3. **UI changes.** Post before-and-after screenshots, plus a screenshot or video demonstrating the feature end to end in the live application.
4. **Nothing mocked.** Seed real demo data when the app needs it to show the feature. Say so if a behavior cannot be exercised live and show the test run that covers it instead.

No PR is complete until this evidence is on the PR and CI is green. Agents never merge PRs; the user reviews and merges.
