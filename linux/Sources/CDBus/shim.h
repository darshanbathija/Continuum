#ifndef CLAWDMETER_C_DBUS_SHIM_H
#define CLAWDMETER_C_DBUS_SHIM_H

// libdbus — for SNI watcher detection in SNIWatcherDetector.swift.
// We could use libsecret's higher-level wrapper for that one query, but
// libdbus gives us direct access to call ListNames on the session bus
// and grep for org.kde.StatusNotifierWatcher.
// pkg-config: dbus-1
#include <dbus/dbus.h>

#endif
