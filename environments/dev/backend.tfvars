env          = "dev"
account_id   = "329104270934"
region       = "us-west-2"
api_hostname = "dev-api.lytebuy.com"
app_hostname = "dev-app.lytebuy.com"

# Origins allowed to call the beta API.
#
# CORS IS A BROWSER RULE ONLY - it does not gate the mobile apps at all. A native
# iOS/Android request sends no Origin header, so the check never runs; the apps
# reach the API regardless of what is listed here. Widening this would not help
# them.
#
# And "*" is not an option even if we wanted it: main.py sets
# allow_credentials=True, and the CORS spec forbids a wildcard origin with
# credentials - browsers reject the response outright. Setting "*" would BREAK
# the web app rather than open it up.
#
# So this is exactly the browser origins that must work: the Expo web build.
cors_allowed_origins = "https://dev-app.lytebuy.com"

# image_tag defaults to "latest"; override per deploy if you tag images.
# db_bootstrap_password is NOT set here (secret) - pass via TF_VAR_db_bootstrap_password.
