using Gtk;

namespace Singularity.Apps.Printers {

    public class PrintersApp : Singularity.Application {
        private Print.PrintMonitor monitor;
        private Gee.HashMap<string, QueueWindow> windows = new Gee.HashMap<string, QueueWindow> ();
        private Gee.HashMap<string, Print.Printer> known = new Gee.HashMap<string, Print.Printer> ();
        private KeyFile notified = new KeyFile ();
        private string notified_path;
        private string? pending_queue;
        private bool background;
        private bool held_background;
        private bool held_jobs;

        public PrintersApp () {
            Object (application_id: "dev.sinty.Printers", flags: ApplicationFlags.FLAGS_NONE);
            inactivity_timeout = 30000;
            add_main_option ("queue", 'q', OptionFlags.NONE, OptionArg.STRING, _("Show the queue of a printer"), _("PRINTER"));
            add_main_option ("background", 0, OptionFlags.NONE, OptionArg.NONE,
                _("Watch printers and tell when one needs attention"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            string? queue = null;
            options.lookup ("queue", "s", out queue);
            bool bg = options.contains ("background");
            if (queue == null && !bg) return -1;
            try {
                register (null);
            } catch (Error e) {
                return 1;
            }
            if (get_is_remote ()) {
                if (queue != null) activate_action ("open-queue", new Variant.string (queue));
                return 0;
            }
            if (queue != null) pending_queue = queue;
            else background = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            notified_path = Path.build_filename (Environment.get_user_state_dir (), "singularity", "printers-notified.ini");
            try {
                notified.load_from_file (notified_path, KeyFileFlags.NONE);
            } catch (Error e) {
            }

            var watch = new SimpleAction ("watch-job", new VariantType ("(sis)"));
            watch.activate.connect ((a, param) => {
                string printer, title;
                int id;
                param.get ("(sis)", out printer, out id, out title);
                watch_job (printer, id, title);
            });
            add_action (watch);
            var open = new SimpleAction ("open-queue", VariantType.STRING);
            open.activate.connect ((a, param) => open_queue (param.get_string ()));
            add_action (open);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            set_accels_for_action ("app.quit", { "<Control>q" });

            monitor = new Print.PrintMonitor ();
            monitor.job_finished.connect (on_job_finished);
            monitor.printer_attention.connect (on_attention);
            monitor.printers_updated.connect (on_printers);
            monitor.start ();
        }

        protected override void shutdown () {
            if (monitor != null) monitor.stop ();
            base.shutdown ();
        }

        public override void activate () {
            if (background) {
                background = false;
                if (!held_background) {
                    hold ();
                    held_background = true;
                }
                return;
            }
            string name = pending_queue ?? "";
            pending_queue = null;
            open_queue (name);
        }

        private void watch_job (string printer, int id, string title) {
            if (id <= 0) return;
            monitor.watch (printer, id, title);
            if (!held_jobs) {
                hold ();
                held_jobs = true;
            }
        }

        public void open_queue (string name) {
            if (windows.has_key (name)) {
                windows[name].present ();
                return;
            }
            var w = new QueueWindow (this, name);
            windows[name] = w;
            w.close_request.connect (() => {
                windows.unset (name);
                return false;
            });
            w.present ();
        }

        private string display_name (string printer) {
            if (known.has_key (printer)) return known[printer].display_name;
            return printer.replace ("_", " ");
        }

        private string icon_for (string printer) {
            if (known.has_key (printer)) return known[printer].icon_name;
            return "printer";
        }

        private static string[] current_reasons (Print.Printer p) {
            string[] reasons = {};
            string? attention = p.attention_reason ();
            if (attention != null) reasons += attention;
            if (p.low_supplies) reasons += Print.PrintMonitor.low_supply_text (p);
            return reasons;
        }

        private string[] notified_reasons (string printer) {
            try {
                return notified.get_string_list ("attention", printer);
            } catch (Error e) {
                return {};
            }
        }

        private void on_printers (Gee.List<Print.Printer> list) {
            known.clear ();
            bool dirty = false;
            foreach (var p in list) {
                known[p.name] = p;
                var now = current_reasons (p);
                string[] kept = {};
                var before = notified_reasons (p.name);
                foreach (var r in before) if (r in now) kept += r;
                if (kept.length == before.length) continue;
                dirty = true;
                if (kept.length == 0) {
                    try {
                        notified.remove_key ("attention", p.name);
                    } catch (Error e) {
                    }
                    withdraw_notification ("printer-" + p.name);
                } else {
                    notified.set_string_list ("attention", p.name, kept);
                }
            }
            if (dirty) save_notified ();
        }

        private void save_notified () {
            try {
                DirUtils.create_with_parents (Path.get_dirname (notified_path), 0700);
                notified.save_to_file (notified_path);
            } catch (Error e) {
                warning ("printers: %s", e.message);
            }
        }

        private void on_attention (Print.Printer p, string reason) {
            known[p.name] = p;
            var before = notified_reasons (p.name);
            if (reason in before) return;
            before += reason;
            notified.set_string_list ("attention", p.name, before);
            save_notified ();
            bool urgent = p.attention_reason () != null;
            var n = new GLib.Notification (urgent ? _("%s Needs Attention").printf (p.display_name)
                                                  : _("%s Is Running Low").printf (p.display_name));
            n.set_body (urgent ? _("%s. Fix it on the printer and printing continues by itself.").printf (reason)
                               : _("%s. Replace it soon to keep printing.").printf (reason));
            n.set_icon (new ThemedIcon (p.icon_name));
            n.set_priority (urgent ? NotificationPriority.HIGH : NotificationPriority.NORMAL);
            n.set_default_action_and_target_value ("app.open-queue", new Variant.string (p.name));
            n.add_button_with_target_value (_("Open Queue"), "app.open-queue", new Variant.string (p.name));
            send_notification ("printer-" + p.name, n);
        }

        private void on_job_finished (Print.JobInfo job, string printer) {
            if (job.state == Print.JobState.COMPLETED) {
                var n = new GLib.Notification (_("Printed"));
                n.set_body (_("%s on %s").printf (job.title, display_name (printer)));
                n.set_icon (new ThemedIcon (icon_for (printer)));
                n.set_default_action_and_target_value ("app.open-queue", new Variant.string (printer));
                send_notification ("job-%d".printf (job.id), n);
            } else if (job.state == Print.JobState.ABORTED || job.state == Print.JobState.STOPPED) {
                var n = new GLib.Notification (_("Printing Failed"));
                n.set_body (_("%s on %s: %s").printf (job.title, display_name (printer), job_reason (job)));
                n.set_icon (new ThemedIcon (icon_for (printer)));
                n.set_priority (NotificationPriority.HIGH);
                n.set_default_action_and_target_value ("app.open-queue", new Variant.string (printer));
                n.add_button_with_target_value (_("Open Queue"), "app.open-queue", new Variant.string (printer));
                send_notification ("job-%d".printf (job.id), n);
            }
            if (!monitor.has_jobs && held_jobs) {
                held_jobs = false;
                release ();
            }
        }

        public static string job_reason (Print.JobInfo job) {
            if (job.state_message != "") return job.state_message;
            foreach (var r in job.reasons) {
                if (r == "none" || r == "job-completed-with-errors") continue;
                if (r.has_prefix ("document-format")) return _("The printer cannot print this kind of document");
                if (r.has_prefix ("document-password") || r.has_prefix ("document-access")) return _("The document is protected");
                if (r.has_prefix ("job-canceled-at-device")) return _("Cancelled on the printer");
                if (r.has_prefix ("aborted-by-system")) return _("The print service stopped the job");
                return Print.Options.humanize (r);
            }
            return _("The printer did not finish the document");
        }
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-printers", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-printers", "UTF-8");
        Intl.textdomain ("singularity-printers");
        Environment.set_application_name (_("Printers"));
        return new PrintersApp ().run (args);
    }
}
