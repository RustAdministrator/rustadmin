#include "my_application.h"

#include "bump_mouse.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#if defined(GDK_WINDOWING_WAYLAND) && defined(HAS_KEYBOARD_SHORTCUTS_INHIBIT)
#include "wayland_shortcuts_inhibit.h"
#endif

#include <desktop_multi_window/desktop_multi_window_plugin.h>

#include "flutter/generated_plugin_registrant.h"

#include <cstring>

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* host_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void host_channel_call_handler(FlMethodChannel* channel,
                                      FlMethodCall* method_call,
                                      gpointer user_data);

namespace {

constexpr char kHostChannelName[] = "org.rustdesk.rustdesk/host";
constexpr char kOriginalFocusOnMapKey[] =
    "rustadmin-original-focus-on-map";

struct HostChannelContext {
  GWeakRef view;
};

void DestroyHostChannelContext(gpointer user_data) {
  auto* context = static_cast<HostChannelContext*>(user_data);
  if (context == nullptr) {
    return;
  }
  g_weak_ref_clear(&context->view);
  g_free(context);
}

void RestoreFocusOnMap(GtkWindow* window) {
  if (window == nullptr || !GTK_IS_WINDOW(window)) {
    return;
  }

  gpointer original =
      g_object_get_data(G_OBJECT(window), kOriginalFocusOnMapKey);
  if (original != nullptr) {
    gtk_window_set_focus_on_map(window, GPOINTER_TO_INT(original) > 0);
  }
}

gboolean RestoreFocusOnMapOnFocusIn(GtkWidget* widget,
                                    GdkEventFocus* /*event*/,
                                    gpointer /*user_data*/) {
  if (GTK_IS_WINDOW(widget)) {
    RestoreFocusOnMap(GTK_WINDOW(widget));
  }
  return FALSE;
}

void PrepareFocusOnMap(GtkWindow* window) {
  if (window == nullptr || !GTK_IS_WINDOW(window)) {
    return;
  }

  GObject* object = G_OBJECT(window);
  if (g_object_get_data(object, kOriginalFocusOnMapKey) == nullptr) {
    const gboolean original = gtk_window_get_focus_on_map(window);
    g_object_set_data(object, kOriginalFocusOnMapKey,
                      GINT_TO_POINTER(original ? 1 : -1));
    g_signal_connect(window, "focus-in-event",
                     G_CALLBACK(RestoreFocusOnMapOnFocusIn), nullptr);
  }
  gtk_window_set_focus_on_map(window, FALSE);
}

GtkWindow* HostWindowForView(FlView* view) {
  if (view == nullptr || !FL_IS_VIEW(view)) {
    return nullptr;
  }

  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  return GTK_IS_WINDOW(toplevel) ? GTK_WINDOW(toplevel) : nullptr;
}

gboolean ParseFocusArgument(FlValue* arguments, gboolean* focus) {
  if (focus == nullptr) {
    return FALSE;
  }

  *focus = TRUE;
  if (arguments == nullptr ||
      fl_value_get_type(arguments) == FL_VALUE_TYPE_NULL) {
    return TRUE;
  }
  if (fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }

  FlValue* focus_value = fl_value_lookup_string(arguments, "focus");
  if (focus_value == nullptr) {
    return TRUE;
  }
  if (fl_value_get_type(focus_value) != FL_VALUE_TYPE_BOOL) {
    return FALSE;
  }

  *focus = fl_value_get_bool(focus_value);
  return TRUE;
}

gboolean ShowConnectionWindow(GtkWindow* window, gboolean focus) {
  if (window == nullptr || !GTK_IS_WINDOW(window)) {
    return FALSE;
  }

  if (focus) {
    RestoreFocusOnMap(window);
    gtk_window_deiconify(window);
    gtk_window_present(window);
    return TRUE;
  }

  PrepareFocusOnMap(window);
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_deiconify(window);
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr) {
    gdk_window_raise(gdk_window);
  }
  return TRUE;
}

gboolean IsConnectionWindowFocused(GtkWindow* window) {
  return window != nullptr && GTK_IS_WINDOW(window) &&
         gtk_window_is_active(window);
}

HostChannelContext* CreateHostChannelContext(FlView* view) {
  auto* context = g_new0(HostChannelContext, 1);
  g_weak_ref_init(&context->view, G_OBJECT(view));
  return context;
}

void RespondBool(FlMethodCall* method_call, gboolean value) {
  g_autoptr(FlValue) response = fl_value_new_bool(value);
  fl_method_call_respond_success(method_call, response, nullptr);
}

FlMethodChannel* RegisterHostChannel(FlBinaryMessenger* messenger,
                                     FlView* view) {
  if (messenger == nullptr || view == nullptr || !FL_IS_VIEW(view)) {
    return nullptr;
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kHostChannelName, FL_METHOD_CODEC(codec));
  if (channel == nullptr) {
    return nullptr;
  }

  fl_method_channel_set_method_call_handler(
      channel, host_channel_call_handler, CreateHostChannelContext(view),
      DestroyHostChannelContext);
  return channel;
}

void SecondaryWindowCreatedCallback(FlPluginRegistry* registry) {
  if (registry == nullptr) {
    return;
  }

  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry,
                                                   "RustDeskHostChannel");
  if (registrar == nullptr) {
    return;
  }

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view == nullptr) {
    return;
  }

  PrepareFocusOnMap(HostWindowForView(view));

  g_autoptr(FlMethodChannel) channel = RegisterHostChannel(
      fl_plugin_registrar_get_messenger(registrar), view);
  (void)channel;

#if defined(GDK_WINDOWING_WAYLAND) && defined(HAS_KEYBOARD_SHORTCUTS_INHIBIT)
  wayland_shortcuts_inhibit_init_for_subwindow(view);
#endif
}

}  // namespace

GtkWidget *find_gl_area(GtkWidget *widget);
void try_set_transparent(GtkWindow* window, GdkScreen* screen, FlView* view);

extern bool gIsConnectionManager;

GtkWidget *find_gl_area(GtkWidget *widget);

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_decorated(window, FALSE);
  // Try setting the icon by the installed application name.
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  gint icons[4] = {256, 128, 64, 32};
  for (int i = 0; i < 4; i++) {
    GdkPixbuf* icon = gtk_icon_theme_load_icon(theme, "rustadmin", icons[i], GTK_ICON_LOOKUP_NO_SVG, NULL);
    if (icon != nullptr) {
      gtk_window_set_icon(window, icon);
    }
  }
  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
  GdkScreen* screen = NULL;
#ifdef GDK_WINDOWING_X11
  screen = gtk_window_get_screen(window);
  if (screen != NULL && GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "RustAdmin");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "RustAdmin");
  }

  // auto bdw = bitsdojo_window_from(window); // <--- add this line
  // bdw->setCustomFrame(true);               // <-- add this line
  int width = 800, height = 600;
  if (gIsConnectionManager) {
    width = 300;
    height = 490;
  }
  gtk_window_set_default_size(window, width, height);   // <-- comment this line
  // gtk_widget_show(GTK_WIDGET(window));
  gtk_widget_set_opacity(GTK_WIDGET(window), 0);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  try_set_transparent(window, gtk_window_get_screen(window), view);
  PrepareFocusOnMap(window);
  gtk_widget_show(GTK_WIDGET(window));
  gtk_widget_show(GTK_WIDGET(view));

  // Register the host channel and optional Wayland shortcut inhibition for
  // every sub-window engine created by desktop_multi_window.
  desktop_multi_window_plugin_set_window_created_callback(
      SecondaryWindowCreatedCallback);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  self->host_channel = RegisterHostChannel(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->host_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}

static void host_channel_call_handler(FlMethodChannel* channel,
                                      FlMethodCall* method_call,
                                      gpointer user_data) {
  auto* context = static_cast<HostChannelContext*>(user_data);
  g_autoptr(FlView) view = nullptr;
  if (context != nullptr) {
    view = FL_VIEW(g_weak_ref_get(&context->view));
  }

  if (strcmp(fl_method_call_get_name(method_call),
             "showConnectionWindow") == 0) {
    gboolean focus = TRUE;
    if (!ParseFocusArgument(fl_method_call_get_args(method_call), &focus)) {
      RespondBool(method_call, FALSE);
      return;
    }

    RespondBool(method_call, ShowConnectionWindow(HostWindowForView(view), focus));
    return;
  }

  if (strcmp(fl_method_call_get_name(method_call),
             "isConnectionWindowFocused") == 0) {
    RespondBool(method_call, IsConnectionWindowFocused(HostWindowForView(view)));
    return;
  }

  if (strcmp(fl_method_call_get_name(method_call), "bumpMouse") == 0) {
    FlValue *args = fl_method_call_get_args(method_call);

    FlValue *dxValue = nullptr;
    FlValue *dyValue = nullptr;

    if (args != nullptr) {
      switch (fl_value_get_type(args))
      {
        case FL_VALUE_TYPE_MAP:
        {
          dxValue = fl_value_lookup_string(args, "dx");
          dyValue = fl_value_lookup_string(args, "dy");

          break;
        }
        case FL_VALUE_TYPE_LIST:
        {
          int listSize = fl_value_get_length(args);

          dxValue = (listSize >= 1) ? fl_value_get_list_value(args, 0) : nullptr;
          dyValue = (listSize >= 2) ? fl_value_get_list_value(args, 1) : nullptr;

          break;
        }
        default: break;
      }
    }

    int dx = 0, dy = 0;

    if (dxValue && (fl_value_get_type(dxValue) == FL_VALUE_TYPE_INT)) {
      dx = fl_value_get_int(dxValue);
    }

    if (dyValue && (fl_value_get_type(dyValue) == FL_VALUE_TYPE_INT)) {
      dy = fl_value_get_int(dyValue);
    }

    bool result = bump_mouse(dx, dy);

    FlValue *result_value = fl_value_new_bool(result);

    GError *error = nullptr;

    if (!fl_method_call_respond_success(method_call, result_value, &error)) {
      g_warning("Failed to send Flutter Platform Channel response: %s", error->message);
      g_error_free(error);
    }

    fl_value_unref(result_value);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

GtkWidget *find_gl_area(GtkWidget *widget)
{
  if (GTK_IS_GL_AREA(widget)) {
    return widget;
  }

  if (GTK_IS_CONTAINER(widget)) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(widget));
    for (GList *iter = children; iter != NULL; iter = g_list_next(iter)) {
      GtkWidget *child = GTK_WIDGET(iter->data);
      GtkWidget *gl_area = find_gl_area(child);
      if (gl_area != NULL) {
        g_list_free(children);
        return gl_area;
      }
    }
    g_list_free(children);
  }

  return NULL;
}

// https://github.com/flutter/flutter/issues/152154
// Remove this workaround when flutter version is updated.
void try_set_transparent(GtkWindow* window, GdkScreen* screen, FlView* view)
{
  GtkWidget *gl_area = NULL;

  printf("Try setting transparent\n");

  gl_area = find_gl_area(GTK_WIDGET(view));
  if (gl_area != NULL) {
    gtk_gl_area_set_has_alpha(GTK_GL_AREA(gl_area), TRUE);
  }

  if (screen != NULL) {
    GdkVisual *visual = NULL;
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
    visual = gdk_screen_get_rgba_visual(screen);
    if (visual != NULL && gdk_screen_is_composited(screen)) {
      gtk_widget_set_visual(GTK_WIDGET(window), visual);
    }
  }
}
