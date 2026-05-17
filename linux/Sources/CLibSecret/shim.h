#ifndef CLAWDMETER_C_LIB_SECRET_SHIM_H
#define CLAWDMETER_C_LIB_SECRET_SHIM_H

// libsecret — freedesktop Secret Service D-Bus client. Stores OAuth tokens
// and the daemon bearer token in GNOME Keyring on Ubuntu / Zorin.
// pkg-config: libsecret-1
// Used by: LinuxSecretServiceTokenProvider, PairingTokenStore+SecretService.
// Fallback when no daemon: ~/.config/clawdmeter/.token chmod 0600.
#include <libsecret/secret.h>

#endif
