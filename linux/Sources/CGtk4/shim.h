#ifndef CLAWDMETER_C_GTK4_SHIM_H
#define CLAWDMETER_C_GTK4_SHIM_H

// GTK 4 — toolkit for the Linux UI. SwiftCrossUI uses it under the hood
// via its GtkBackend; complex Sessions IDE surfaces (NavigationSplitView
// equivalents, drag/drop, clipboard, WebView host) call CGtk4 directly
// per D14 hybrid approach.
// pkg-config: gtk4
#include <gtk/gtk.h>

#endif
