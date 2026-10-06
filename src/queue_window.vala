using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Printers {

    public class QueueWindow : Singularity.Widgets.Window {
        private string printer_name;
        private Print.PrinterBackend backend;
        private Print.Printer? printer;
        private Stack stack;
        private StatusPage missing;
        private Box header_box;
        private Print.PrinterCard? card;
        private Banner state_banner;
        private Banner error_banner;
        private PreferencesGroup supplies_group;
        private Print.InkLevels inks;
        private ListBoxRow inks_row;
        private ActionRow no_levels_row;
        private ActionRow low_row;
        private PreferencesGroup queue_group;
        private PreferencesGroup? history_group;
        private string queue_signature = "";
        private string history_signature = "";
        private Button? pause_bubble;
        private uint refresh_id;
        private bool loading;
        private Gee.HashMap<string, Gee.ArrayList<Print.Marker>> device_markers = new Gee.HashMap<string, Gee.ArrayList<Print.Marker>> ();
        private int64 markers_checked;
        private int64 reach_checked;
        private bool unreachable;
        private bool probing;

        public QueueWindow (PrintersApp app, string printer_name) {
            base (app);
            this.printer_name = printer_name;
            backend = Print.PrinterBackend.get_default ();
            set_default_size (520, 640);
            set_title (printer_name != "" ? printer_name.replace ("_", " ") : _("Printers"));

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;

            missing = new StatusPage ();
            missing.icon_name = "printer";
            missing.title = _("Printer Not Found");
            var settings_btn = new Button.with_label (_("Printer Settings"));
            settings_btn.add_css_class ("pill");
            settings_btn.halign = Align.CENTER;
            settings_btn.clicked.connect (() => open_settings ());
            missing.child = settings_btn;
            stack.add_named (missing, "missing");

            var column = new Box (Orientation.VERTICAL, 0);
            column.margin_start = 24;
            column.margin_end = 24;
            column.margin_top = 44;
            column.margin_bottom = 24;

            header_box = new Box (Orientation.HORIZONTAL, 0);
            header_box.margin_top = 12;
            header_box.margin_start = 12;
            header_box.margin_end = 12;
            column.append (header_box);

            error_banner = new Banner ("", BannerStyle.ERROR);
            error_banner.icon_name = "dialog-warning-symbolic";
            error_banner.secondary_label = _("Dismiss");
            error_banner.secondary_clicked.connect (() => error_banner.visible = false);
            error_banner.margin_top = 12;
            error_banner.visible = false;
            column.append (error_banner);

            state_banner = new Banner ("", BannerStyle.WARNING);
            state_banner.margin_top = 12;
            state_banner.visible = false;
            state_banner.button_clicked.connect (() => {
                if (printer != null && printer.status == Print.PrinterStatus.PAUSED) set_paused.begin (false);
                else refresh.begin ();
            });
            column.append (state_banner);

            queue_group = new PreferencesGroup (_("Waiting to Print"));
            queue_group.margin_top = 18;
            column.append (queue_group);

            supplies_group = new PreferencesGroup (_("Supplies"));
            supplies_group.margin_top = 12;
            var holder = new Box (Orientation.VERTICAL, 0);
            holder.margin_top = 12;
            holder.margin_bottom = 12;
            holder.margin_start = 14;
            holder.margin_end = 14;
            inks = new Print.InkLevels (true);
            holder.append (inks);
            inks_row = new ListBoxRow ();
            inks_row.activatable = false;
            inks_row.child = holder;
            supplies_group.add_row (inks_row);
            no_levels_row = new ActionRow (_("Levels Appear After the First Job"),
                _("The printer reports its ink or toner once it has printed something."), "printer-symbolic");
            no_levels_row.activatable = false;
            no_levels_row.visible = false;
            supplies_group.add_row (no_levels_row);
            low_row = new ActionRow ("", _("Replace it soon to keep printing."), "dialog-warning-symbolic");
            low_row.activatable = false;
            low_row.visible = false;
            supplies_group.add_row (low_row);
            column.append (supplies_group);

            if (backend.can (Print.BackendFeature.COMPLETED_JOBS)) {
                history_group = new PreferencesGroup (_("Recently Printed"));
                history_group.margin_top = 12;
                column.append (history_group);
            }

            var scroller = new ScrolledWindow ();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.child = new Clamp (column, 640);
            stack.add_named (scroller, "queue");
            stack.visible_child_name = "queue";
            set_content (stack);

            if (backend.can (Print.BackendFeature.PAUSE)) {
                pause_bubble = add_bubble_icon ("media-playback-pause-symbolic", _("Pause Printing"), () => {
                    if (printer != null) set_paused.begin (printer.status != Print.PrinterStatus.PAUSED);
                });
            }
            add_bubble_icon ("emblem-system-symbolic", _("Printer Settings"), () => open_settings ());

            map.connect (() => {
                refresh.begin ();
                if (refresh_id == 0) {
                    refresh_id = Timeout.add_seconds (2, () => {
                        refresh.begin ();
                        return Source.CONTINUE;
                    });
                }
            });
            unmap.connect (() => stop_refresh ());
            close_request.connect (() => {
                stop_refresh ();
                return false;
            });
        }

        private void stop_refresh () {
            if (refresh_id != 0) {
                Source.remove (refresh_id);
                refresh_id = 0;
            }
        }

        private void open_settings () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings ("printers");
            } catch (Error e) {
                show_error (e);
            }
        }

        private void show_error (Error e) {
            if (e is Print.PrintError.NOT_AUTHORIZED) {
                error_banner.title = _("Only administrators can change printers. %s").printf (e.message);
            } else {
                error_banner.title = e.message;
            }
            error_banner.visible = true;
        }

        private async void fill_markers (Print.Printer p) {
            if (p.markers.size > 0 || p.device_uri == "") return;
            int64 now = get_monotonic_time ();
            if (now - markers_checked < 60 * 1000000) {
                if (device_markers.has_key (p.device_uri)) p.markers = device_markers[p.device_uri];
                return;
            }
            markers_checked = now;
            yield backend.fill_markers (p);
            if (p.markers.size > 0) device_markers[p.device_uri] = p.markers;
        }

        private void mark_reachability (Print.Printer p) {
            string uri = p.device_uri;
            if (p.offline || !(uri.has_prefix ("ipp://") || uri.has_prefix ("ipps://"))) return;
            bool stuck = p.state == 4 && p.state_message != "";
            if (!stuck) return;
            if (unreachable) {
                string[] reasons = p.state_reasons;
                reasons += "offline-report";
                p.state_reasons = reasons;
            }
            int64 now = get_monotonic_time ();
            if (probing || now - reach_checked < 20 * 1000000) return;
            probing = true;
            reach_checked = now;
            backend.probe.begin (uri, (o, r) => {
                try {
                    backend.probe.end (r);
                    unreachable = false;
                } catch (Error e) {
                    unreachable = e is Print.PrintError.UNREACHABLE;
                }
                probing = false;
            });
        }

        private async void refresh () {
            if (loading) return;
            loading = true;
            Print.Printer? p = null;
            try {
                if (printer_name == "") {
                    var list = yield backend.list_printers ();
                    foreach (var candidate in list) {
                        if (candidate.is_default || p == null) p = candidate;
                        if (candidate.is_default) break;
                    }
                    if (p != null) printer_name = p.name;
                } else {
                    p = yield backend.get_printer (printer_name);
                }
            } catch (Error e) {
                loading = false;
                missing.description = e.message;
                stack.visible_child_name = "missing";
                return;
            }
            if (p == null) {
                loading = false;
                missing.description = printer_name != ""
                    ? _("“%s” is no longer set up on this computer.").printf (printer_name.replace ("_", " "))
                    : _("No printer is set up yet. Add one in Settings.");
                stack.visible_child_name = "missing";
                return;
            }
            yield fill_markers (p);
            mark_reachability (p);
            printer = p;
            stack.visible_child_name = "queue";
            update_printer ();
            yield update_jobs ();
            loading = false;
        }

        private void update_printer () {
            var p = printer;
            set_title (p.display_name);
            if (card == null) {
                card = new Print.PrinterCard (p, 64);
                card.hexpand = true;
                header_box.append (card);
            } else {
                card.update (p);
            }
            bool known = false;
            foreach (var m in p.markers) if (m.known) known = true;
            inks.set_markers (p.markers);
            inks_row.visible = p.markers.size > 0;
            no_levels_row.visible = !known;
            string low = p.low_supplies ? Print.PrintMonitor.low_supply_text (p) : "";
            low_row.title = low;
            low_row.visible = low != "";

            bool paused = p.status == Print.PrinterStatus.PAUSED;
            if (pause_bubble != null) {
                pause_bubble.icon_name = paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
                pause_bubble.tooltip_text = paused ? _("Resume Printing") : _("Pause Printing");
            }

            state_banner.button_label = null;
            if (p.offline) {
                state_banner.style = BannerStyle.WARNING;
                state_banner.icon_name = "network-offline-symbolic";
                state_banner.title = _("Printer offline. Nothing answers at %s. Check that it is turned on and connected; waiting documents print when it is back.").printf (p.device_uri);
                state_banner.button_label = _("Check Again");
                state_banner.visible = true;
            } else if (paused) {
                state_banner.style = BannerStyle.INFO;
                state_banner.icon_name = "media-playback-pause-symbolic";
                state_banner.title = _("Printing is paused. Documents wait in the queue until you resume.");
                if (backend.can (Print.BackendFeature.PAUSE)) state_banner.button_label = _("Resume");
                state_banner.visible = true;
            } else if (p.attention_reason () != null) {
                state_banner.style = BannerStyle.ERROR;
                state_banner.icon_name = "dialog-warning-symbolic";
                state_banner.title = _("%s. Fix it on the printer and printing continues by itself.").printf (p.attention_reason ());
                state_banner.visible = true;
            } else {
                state_banner.visible = false;
            }
        }

        private async void update_jobs () {
            Gee.List<Print.JobInfo> active;
            try {
                active = yield backend.list_jobs (printer_name, false);
            } catch (Error e) {
                active = new Gee.ArrayList<Print.JobInfo> ();
            }
            var unfinished = new Gee.ArrayList<Print.JobInfo> ();
            foreach (var j in active) if (!j.state.finished ()) unfinished.add (j);
            active = unfinished;
            string sig = "n%d;".printf (active.size);
            foreach (var j in active) sig += "%d:%d:%d:%d;".printf (j.id, (int) j.state, j.pages_done, j.pages_total);
            if (sig != queue_signature || queue_group.get_rows ().size == 0) {
                queue_signature = sig;
                queue_group.clear ();
                if (active.size == 0) {
                    var empty = new ActionRow (_("Nothing Waiting"),
                        _("Documents you print appear here until they are done"), "document-print-symbolic");
                    empty.activatable = false;
                    queue_group.add_row (empty);
                }
                foreach (var j in active) queue_group.add_row (job_row (j, true));
            }
            if (history_group == null) return;
            Gee.List<Print.JobInfo> done;
            try {
                done = yield backend.list_jobs (printer_name, true);
            } catch (Error e) {
                done = new Gee.ArrayList<Print.JobInfo> ();
            }
            string hsig = "n%d;".printf (done.size);
            int n = 0;
            foreach (var j in done) {
                if (n++ >= 20) break;
                hsig += "%d:%d;".printf (j.id, (int) j.state);
            }
            if (hsig == history_signature && history_group.get_rows ().size > 0) return;
            history_signature = hsig;
            history_group.clear ();
            if (done.size == 0) {
                var empty = new ActionRow (_("Nothing Printed Yet"),
                    _("Finished and cancelled documents are listed here"), "document-open-recent-symbolic");
                empty.activatable = false;
                history_group.add_row (empty);
                return;
            }
            n = 0;
            foreach (var j in done) {
                if (n++ >= 20) break;
                history_group.add_row (job_row (j, false));
            }
        }

        private static string job_time (int64 when) {
            if (when <= 0) return "";
            var t = new DateTime.from_unix_local (when);
            var now = new DateTime.now_local ();
            if (t.get_year () == now.get_year () && t.get_day_of_year () == now.get_day_of_year ())
                return t.format ("%H:%M");
            return t.format ("%x");
        }

        private static string summary (Print.JobInfo job) {
            string[] parts = {};
            if (job.state == Print.JobState.PROCESSING && job.pages_total > 0)
                parts += _("Printing page %d of %d").printf (int.max (1, job.pages_done), job.pages_total);
            else if (job.state == Print.JobState.ABORTED)
                parts += "%s: %s".printf (job.state.label (), PrintersApp.job_reason (job));
            else
                parts += job.state.label ();
            if (job.state == Print.JobState.COMPLETED && job.pages_done > 0)
                parts += ngettext ("%d page", "%d pages", job.pages_done).printf (job.pages_done);
            string when = job_time (job.state.finished () && job.completed > 0 ? job.completed : job.created);
            if (when != "") parts += when;
            if (job.user != "" && job.user != Environment.get_user_name ()) parts += job.user;
            return string.joinv (", ", parts);
        }

        private static string icon_for (Print.JobInfo job) {
            switch (job.state) {
                case Print.JobState.COMPLETED: return "emblem-ok-symbolic";
                case Print.JobState.ABORTED: return "dialog-error-symbolic";
                case Print.JobState.CANCELED: return "action-unavailable-symbolic";
                case Print.JobState.HELD: return "media-playback-pause-symbolic";
                case Print.JobState.STOPPED: return "dialog-warning-symbolic";
                default: return "document-print-symbolic";
            }
        }

        private static Button round_button (string icon_name, string tooltip) {
            var btn = new Button.from_icon_name (icon_name);
            btn.add_css_class ("flat");
            btn.add_css_class ("circular");
            btn.valign = Align.CENTER;
            btn.tooltip_text = tooltip;
            btn.update_property (AccessibleProperty.LABEL, tooltip, -1);
            return btn;
        }

        private Widget job_row (Print.JobInfo job, bool active) {
            var row = new ActionRow (job.title, summary (job), icon_for (job));
            row.activatable = false;
            if (!active) return row;
            int id = job.id;
            if (backend.can (Print.BackendFeature.HOLD_JOBS)) {
                bool held = job.state == Print.JobState.HELD;
                var hold = round_button (held ? "media-playback-start-symbolic" : "media-playback-pause-symbolic",
                                         held ? _("Resume Document") : _("Hold Document"));
                hold.clicked.connect (() => job_action.begin (id, held ? 2 : 1));
                row.add_suffix (hold);
            }
            var cancel = round_button ("process-stop-symbolic", _("Cancel Printing"));
            cancel.clicked.connect (() => job_action.begin (id, 0));
            row.add_suffix (cancel);
            return row;
        }

        private async void job_action (int id, int kind) {
            try {
                if (kind == 0) yield backend.cancel_job (id);
                else if (kind == 1) yield backend.hold_job (id);
                else yield backend.release_job (id);
            } catch (Error e) {
                show_error (e);
            }
            queue_signature = "";
            history_signature = "";
            yield refresh ();
        }

        private async void set_paused (bool paused) {
            try {
                yield backend.set_paused (printer_name, paused);
            } catch (Error e) {
                show_error (e);
            }
            yield refresh ();
        }
    }
}
