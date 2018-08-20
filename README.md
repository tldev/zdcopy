# Zendesk Sandbox Copier

Zendesk does not currently support copying over settings such as triggers, macro, automations, or even custom fields into a sandbox.

This library attempts to provide tools for supporting copying over those settings. This is extremely beta, so use at your own risk

## Instructions

```
git clone https://github.com/tldev/zdcopy.git
cd zdcopy
bundle install
PROD_ZD_URL="https://youcompany.zendesk/api/v2" PROD_ZD_USER=test@gmail.com PROD_ZD_PASSWORD=pass \
SANDBOX_ZD_URL="https://sanbox.zendesk/api/v2" SANDBOX_ZD_USER=test@gmail.com SANDBOOX=_ZD_PASSWORD=pass \
./bin/copy
```

### Warning
The current copy script deletes what's on the sandbox prior to creating new entities. Only run this if you're willing to start on a fresh sandbox.