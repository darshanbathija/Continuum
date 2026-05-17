#ifndef CLAWDMETER_C_AYATANA_APP_INDICATOR_SHIM_H
#define CLAWDMETER_C_AYATANA_APP_INDICATOR_SHIM_H

// Ayatana AppIndicator — system tray for GNOME / KDE / Cinnamon via the
// StatusNotifierItem D-Bus interface. The Canonical libappindicator3 is
// deprecated; Ubuntu 24.04+ / Zorin 17+ ship the Ayatana fork.
// pkg-config: ayatana-appindicator3-0.1
// Used by: AppIndicatorTray to create + update the menu bar gauge.
#include <libayatana-appindicator/app-indicator.h>

#endif
