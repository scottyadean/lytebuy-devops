env          = "prod"
account_id   = "329104270934"
region       = "us-west-2"
api_hostname = "api.lytebuy.com"
app_hostname = "app.lytebuy.com"

# Origins allowed to call the API.
#
# CORS IS A BROWSER RULE ONLY - it does not gate the mobile apps. A native
# request sends no Origin header, so the check never runs. And "*" is not an
# option: main.py sets allow_credentials=True, and the spec forbids a wildcard
# origin with credentials, so browsers would reject the response.
#
# Both the Expo web build and the marketing site, since lytebuy.com links into
# the app.
cors_allowed_origins = "https://app.lytebuy.com,https://lytebuy.com"

# SIZING: identical to dev on purpose (db.t4g.micro, 20 GiB, single-AZ, one
# task) - Scott's call, given no launch traffic. Instance class and storage are
# both IN-PLACE changes later: a resize costs a few minutes of downtime, storage
# needs none. Storage only ever grows, and AWS blocks a second storage change
# for ~6 hours after one. The thing that is genuinely hard to change later is the
# Postgres MAJOR version, which is why it is pinned at 16 in the module.
#
# db_bootstrap_password is NOT set here (secret) - pass via
# TF_VAR_db_bootstrap_password. It must differ from dev's.

# Transactional email ON in prod (LB-Client-6/7). lytebuy.com is a verified SES
# identity and the account is OUT of the sandbox (50k/day), so no-reply@ can mail
# any address. Dev leaves this at its false default - a dev build must not be one
# config slip away from mailing real customers.
email_enabled = true
