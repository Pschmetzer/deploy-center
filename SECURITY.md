# Security

Deploy Center has no server and no telemetry. It calls the Vercel CLI, the GitHub CLI and the Render API with your own logins.
The Render API key is stored in the macOS keychain (`deploy-center-render`) and is passed to `curl` on stdin, never as an argument.
Prefer an API key made only for this app.

Found a problem? Open a private security advisory on GitHub (Security tab) instead of a public issue.
