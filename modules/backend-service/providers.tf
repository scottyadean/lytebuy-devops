# The AWS provider is configured by the ROOT module (environments/<env>). This
# child module inherits it. We only declare the default tags contract here via a
# variable the root passes through, keeping the provider block in one place.
#
# (No provider block here on purpose - a reusable module should not pin the
# provider config; the calling environment owns region/account/tags.)
