# Budgetify

Budgetify is a budgeting app under development. Its versioned API follows YNAB's response conventions and uses bearer authentication.
See [AGENT.md](AGENT.md) for the architecture, routes, authentication flow, local setup, and current implementation status.


## Authentication

`POST /loginUser` accepts email/password. Successful login establishes an app session; the browser loads the catalog before opening the budget selector. Signup and Google/Apple authentication are not implemented.

The public root serves the marketing site. The `app` subdomain is protected and redirects signed-out visitors to `/users/sign_in`.

The login response includes the user profile fields, with unavailable subscription/service fields set to `null` or `false`. It omits `user_budget` and `budget_version`.

## API

### `POST /loginUser`

Send JSON with `email` and `password`. Invalid credentials return:

```json
{
  "error": {
    "id": "user_not_found",
    "message": "Unauthorized: unknown username and/or password"
  }
}
```

On success, the response contains `error: null`, `session_token`, and `user`. The user ID is a UUID.

### `GET /v1/user`

Requires `Authorization: Bearer <session_token>` and returns the YNAB user envelope containing `data.user.id`.

### `GET /api/v1/catalog`

Requires a bearer token and returns the signed-in user's real budget catalog as `data.budgets`. It returns an empty list when that account has no budgets.

### `GET /users/budgets`

Requires a browser session and lists only the signed-in user's budgets. Select a budget to open `/users/budgets/:public_id`.

`DELETE /v1/session` revokes a session token.

## Development

```sh
bundle install
bin/rails db:prepare
bin/rails server
```
The marketing page is available at `http://localhost:3000/`; the app host is `http://app.localhost:3000/`. In deployment, point both the root domain and `app.<root-domain>` at this Rails service.

In `bin/rails console`, create a local account and a budget to test selection:

```ruby
user = User.create!(email_address: "you@example.com", password: "your-private-password", password_confirmation: "your-private-password")
user.budgets.create!(name: "Household")
```

Visit `http://app.localhost:3000/` to sign in; the app syncs the catalog and opens `/users/budgets`. Run the test suite with `bin/rails test`.
