# Budgetify

Budgetify is a budgeting app under development. Its versioned API follows YNAB's response conventions and uses bearer authentication.

## Authentication

Rails' authentication generator provides browser sign-in at `/session/new` and password-reset routes. To create the first account, run `bin/rails console` and create a `User` with an email address and private password.

For API clients, `POST /v1/session` accepts JSON credentials and returns a bearer access token. `DELETE /v1/session` revokes that token.

## API

### `GET /v1/user`

Requires `Authorization: Bearer <access-token>`. The response matches the YNAB user envelope:

```json
{
  "data": {
    "user": {
      "id": "<uuid>"
    }
  }
}
```

## Development

```sh
bundle install
bin/rails db:prepare
bin/rails server
```

Create a local account in `bin/rails console` with `User.create!(email_address: "you@example.com", password: "your-private-password", password_confirmation: "your-private-password")`.

Log in with `curl -X POST http://localhost:3000/v1/session -H 'Content-Type: application/json' -d '{"email_address":"you@example.com","password":"your-private-password"}'`, then use the returned `data.access_token` as the bearer token for `GET /v1/user`. Run the test suite with `bin/rails test`.
